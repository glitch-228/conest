//! The relay server on tokio: one task per connection, waiting fetches that
//! hold no thread, a semaphore for the connection cap. The protocol is told
//! by a connection's first bytes.

use std::io::{BufReader, Cursor};
use std::sync::Arc;
use std::time::Duration;

use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio::sync::Semaphore;
use tokio::time::{Instant, timeout, timeout_at};

use crate::config::RESPONSE_WRITE_DEADLINE;
use crate::http::{handle_http_request_async, write_http_response};
use crate::limits::peer_key;
use crate::storage::RelayState;
use crate::v1::handle_request_async;

/// What a connection's first bytes say it speaks.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Detected {
    /// One JSON request line.
    V1,
    /// An HTTP request.
    Http,
    /// A v2 session (`CNS2`).
    V2,
}

pub(crate) const V2_MAGIC: &[u8; 4] = b"CNS2";
const HTTP_METHODS: [&[u8]; 3] = [b"GET ", b"POST ", b"OPTIONS "];

/// The protocol [prefix] starts, or none while it could still be more than
/// one of them.
pub(crate) fn detect_protocol(prefix: &[u8], v2_enabled: bool) -> Option<Detected> {
    if v2_enabled {
        if prefix.len() >= V2_MAGIC.len() && &prefix[..V2_MAGIC.len()] == V2_MAGIC {
            return Some(Detected::V2);
        }
        if prefix.len() < V2_MAGIC.len() && V2_MAGIC.starts_with(prefix) {
            return None;
        }
    }
    for method in HTTP_METHODS {
        if prefix.len() >= method.len() && &prefix[..method.len()] == method {
            return Some(Detected::Http);
        }
        if prefix.len() < method.len() && method.starts_with(prefix) {
            return None;
        }
    }
    Some(Detected::V1)
}

/// Serves [listener] until it fails. UDP is served apart (see
/// [crate::legacy::serve_udp]: one thread, nothing there waits).
pub(crate) async fn serve(listener: TcpListener, state: RelayState) -> std::io::Result<()> {
    // Every connection holds a task and its buffers; past the cap,
    // connections get a best-effort error line and are dropped (clients
    // treat it like any other route failure).
    let permits = Arc::new(Semaphore::new(state.config.max_connections));
    loop {
        let (stream, address) = match listener.accept().await {
            Ok(accepted) => accepted,
            Err(error) => {
                eprintln!("relay accept error: {error}");
                // Out of file descriptors, say: not a busy loop.
                tokio::time::sleep(Duration::from_millis(20)).await;
                continue;
            }
        };
        let _ = stream.set_nodelay(true);
        let Ok(permit) = Arc::clone(&permits).try_acquire_owned() else {
            refuse(stream, b"{\"ok\":false,\"error\":\"relay at capacity\"}\n");
            continue;
        };
        let peer = peer_key(address.ip());
        // Behind a trusted proxy every client has its address.
        let peer_slot = if state.config.trust_forwarded_for {
            None
        } else {
            match state.connection_slot(&peer) {
                Some(slot) => Some(slot),
                None => {
                    drop(permit);
                    refuse(
                        stream,
                        b"{\"ok\":false,\"error\":\"too many connections\"}\n",
                    );
                    continue;
                }
            }
        };
        let state = state.clone();
        tokio::spawn(async move {
            let _permit = permit;
            let _peer_slot = peer_slot;
            if let Err(error) = handle_connection(stream, state, peer).await {
                eprintln!("relay connection error: {error}");
            }
        });
    }
}

/// Writes [line] to a refused connection, at most a second, and drops it.
fn refuse(mut stream: tokio::net::TcpStream, line: &'static [u8]) {
    tokio::spawn(async move {
        let _ = timeout(Duration::from_secs(1), stream.write_all(line)).await;
    });
}

fn timed_out(what: &str) -> std::io::Error {
    std::io::Error::new(std::io::ErrorKind::TimedOut, what.to_owned())
}

/// Reads more of a request into [buffer], by [deadline]; false at the end
/// of the stream.
async fn read_more<S: AsyncRead + Unpin>(
    stream: &mut S,
    buffer: &mut Vec<u8>,
    deadline: Instant,
) -> std::io::Result<bool> {
    let mut chunk = [0_u8; 8 * 1024];
    let read = timeout_at(deadline, stream.read(&mut chunk))
        .await
        .map_err(|_| timed_out("request took too long to arrive"))??;
    buffer.extend_from_slice(&chunk[..read]);
    Ok(read > 0)
}

/// One connection, whatever it speaks.
pub(crate) async fn handle_connection<S>(
    mut stream: S,
    state: RelayState,
    peer: String,
) -> std::io::Result<()>
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    let deadline = Instant::now() + state.config.ext.read_deadline;
    let mut buffer = Vec::with_capacity(8 * 1024);
    let detected = loop {
        if let Some(detected) = detect_protocol(&buffer, false) {
            break detected;
        }
        if !read_more(&mut stream, &mut buffer, deadline).await? {
            if buffer.is_empty() {
                return Ok(());
            }
            break Detected::V1;
        }
    };
    match detected {
        Detected::V1 => serve_v1_line(stream, state, peer, buffer, deadline).await,
        Detected::Http => serve_http(stream, state, peer, buffer, deadline).await,
        // Sessions come with phase B.
        Detected::V2 => serve_v1_line(stream, state, peer, buffer, deadline).await,
    }
}

/// A v1 request line (up to its newline or the end of the stream).
async fn serve_v1_line<S>(
    mut stream: S,
    state: RelayState,
    peer: String,
    mut buffer: Vec<u8>,
    deadline: Instant,
) -> std::io::Result<()>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    let max = state.config.max_line_bytes;
    loop {
        if let Some(newline) = buffer.iter().position(|byte| *byte == b'\n') {
            buffer.truncate(newline + 1);
            break;
        }
        if buffer.len() > max {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "request line too large",
            ));
        }
        if !read_more(&mut stream, &mut buffer, deadline).await? {
            break;
        }
    }
    if buffer.len() > max {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "request line too large",
        ));
    }
    if let Err(error) = std::str::from_utf8(&buffer) {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!("request line is not utf-8: {error}"),
        ));
    }
    let bytes_read = buffer.len();
    let response = handle_request_async(&buffer, bytes_read, &state, &peer).await;
    let mut out = serde_json::to_vec(&response)?;
    out.push(b'\n');
    write_response(&mut stream, &out).await
}

/// Writes a response that must be taken within the write deadline.
pub(crate) async fn write_response<S: AsyncWrite + Unpin>(
    stream: &mut S,
    bytes: &[u8],
) -> std::io::Result<()> {
    timeout(RESPONSE_WRITE_DEADLINE, async {
        stream.write_all(bytes).await?;
        stream.flush().await
    })
    .await
    .map_err(|_| timed_out("response took too long to be taken"))?
}

/// Where an HTTP request's headers end (the index after the blank line).
fn header_end(bytes: &[u8]) -> Option<usize> {
    if let Some(index) = bytes.windows(4).position(|window| window == b"\r\n\r\n") {
        return Some(index + 4);
    }
    bytes
        .windows(2)
        .position(|window| window == b"\n\n")
        .map(|index| index + 2)
}

/// The Content-Length an HTTP header block declares (0 when none or
/// unreadable: the parser answers those).
fn declared_length(headers: &[u8]) -> usize {
    let text = String::from_utf8_lossy(headers);
    for line in text.lines() {
        if let Some((name, value)) = line.split_once(':')
            && name.trim().eq_ignore_ascii_case("content-length")
        {
            return value.trim().parse().unwrap_or(0);
        }
    }
    0
}

/// An HTTP request: read whole (bounded), then answered as v1's HTTP form.
async fn serve_http<S>(
    mut stream: S,
    state: RelayState,
    peer: String,
    mut buffer: Vec<u8>,
    deadline: Instant,
) -> std::io::Result<()>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    let max = state.config.max_line_bytes;
    // The request line, then the headers (the parser bounds them again).
    let headers_end = loop {
        if let Some(end) = header_end(&buffer) {
            break Some(end);
        }
        if buffer.len() > max.saturating_mul(2) {
            break None;
        }
        if !read_more(&mut stream, &mut buffer, deadline).await? {
            break None;
        }
    };
    if let Some(end) = headers_end {
        let wanted = declared_length(&buffer[..end]);
        if wanted <= max {
            while buffer.len() < end + wanted {
                if !read_more(&mut stream, &mut buffer, deadline).await? {
                    break;
                }
            }
        }
    }
    let line_end = buffer
        .iter()
        .position(|byte| *byte == b'\n')
        .map_or(buffer.len(), |index| index + 1);
    if line_end > max {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "request line too large",
        ));
    }
    let request_line = std::str::from_utf8(&buffer[..line_end])
        .map_err(|error| {
            std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                format!("request line is not utf-8: {error}"),
            )
        })?
        .to_owned();
    let mut reader = BufReader::new(Cursor::new(buffer[line_end..].to_vec()));
    let (status, response) =
        handle_http_request_async(&request_line, &mut reader, &state, &peer).await;
    let mut out = Vec::new();
    write_http_response(&mut out, status, &response)?;
    write_response(&mut stream, &out).await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_first_bytes_tell_the_protocol() {
        assert_eq!(detect_protocol(b"{\"action\"", true), Some(Detected::V1));
        assert_eq!(detect_protocol(b"CNS2\x01", true), Some(Detected::V2));
        assert_eq!(
            detect_protocol(b"GET / HTTP/1.1", true),
            Some(Detected::Http)
        );
        assert_eq!(detect_protocol(b"POST /relay", true), Some(Detected::Http));
        assert_eq!(detect_protocol(b"OPTIONS /", true), Some(Detected::Http));
        // Still undecided.
        assert_eq!(detect_protocol(b"", true), None);
        assert_eq!(detect_protocol(b"CN", true), None);
        assert_eq!(detect_protocol(b"PO", true), None);
        assert_eq!(detect_protocol(b"OPTI", true), None);
        // Anything else is a v1 line (answered with its error, as before).
        assert_eq!(detect_protocol(b"CNX", true), Some(Detected::V1));
        assert_eq!(detect_protocol(b"hello", true), Some(Detected::V1));
        // With sessions off, CNS2 is just a (bad) v1 line.
        assert_eq!(detect_protocol(b"CNS2", false), Some(Detected::V1));
    }
}
