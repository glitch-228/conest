//! The old relay server: one thread per connection, long-polls parked on a
//! condvar. Kept behind `--legacy-threads` as a rollback.

use std::io::{BufReader, BufWriter, Write};
use std::net::{TcpListener, UdpSocket};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

use crate::config::{RESPONSE_WRITE_DEADLINE, RelayConfig};
use crate::http::{
    handle_http_request, is_http_request_line, read_line_bounded, write_http_response,
};
use crate::limits::peer_key;
use crate::storage::RelayState;
use crate::v1::handle_request_bytes;

/// Writes to a stream that must take the whole response by a deadline from
/// its first byte: a client reading a byte at a time cannot hold a worker.
pub(crate) struct DeadlineWriter {
    pub(crate) stream: std::net::TcpStream,
    pub(crate) limit: Duration,
    pub(crate) deadline: Option<std::time::Instant>,
}

impl Write for DeadlineWriter {
    fn write(&mut self, buffer: &[u8]) -> std::io::Result<usize> {
        let deadline = *self
            .deadline
            .get_or_insert_with(|| std::time::Instant::now() + self.limit);
        let left = deadline.saturating_duration_since(std::time::Instant::now());
        if left.is_zero() {
            return Err(std::io::Error::new(
                std::io::ErrorKind::TimedOut,
                "response took too long to be taken",
            ));
        }
        self.stream
            .set_write_timeout(Some(left.min(Duration::from_secs(10))))?;
        self.stream.write(buffer)
    }

    fn flush(&mut self) -> std::io::Result<()> {
        self.stream.flush()
    }
}

/// Reads from a stream that must deliver everything by a deadline, however
/// slowly its bytes come: a client trickling a byte at a time cannot hold a
/// worker past it.
pub(crate) struct DeadlineReader {
    pub(crate) stream: std::net::TcpStream,
    pub(crate) deadline: std::time::Instant,
}

impl std::io::Read for DeadlineReader {
    fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
        let left = self
            .deadline
            .saturating_duration_since(std::time::Instant::now());
        if left.is_zero() {
            return Err(std::io::Error::new(
                std::io::ErrorKind::TimedOut,
                "request took too long to arrive",
            ));
        }
        self.stream
            .set_read_timeout(Some(left.min(Duration::from_secs(5))))?;
        std::io::Read::read(&mut self.stream, buffer)
    }
}

/// The old server: one thread per connection. Kept as a rollback the
/// supervisor can choose with `--legacy-threads`.
pub(crate) fn run(listener: TcpListener, state: RelayState) -> std::io::Result<()> {
    let config = state.config.clone();
    // Every accepted connection holds a worker thread — a long-poll fetch
    // for up to ~25 s — so an unbounded accept loop is a cheap thread/memory
    // exhaustion vector. Past the cap, connections get a best-effort error
    // line and are dropped; clients treat it like any other route failure.
    let active_connections = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    for stream in listener.incoming() {
        match stream {
            Ok(mut stream) => {
                let active = Arc::clone(&active_connections);
                if active.fetch_add(1, std::sync::atomic::Ordering::AcqRel)
                    >= config.max_connections
                {
                    active.fetch_sub(1, std::sync::atomic::Ordering::AcqRel);
                    let _ = stream.set_write_timeout(Some(Duration::from_secs(1)));
                    let _ = stream.write_all(b"{\"ok\":false,\"error\":\"relay at capacity\"}\n");
                    continue;
                }
                let peer = stream
                    .peer_addr()
                    .map(|address| peer_key(address.ip()))
                    .unwrap_or_else(|_| "unknown".to_owned());
                // Behind a trusted proxy every client has its address.
                let peer_slot = if config.trust_forwarded_for {
                    None
                } else {
                    match state.connection_slot(&peer) {
                        Some(slot) => Some(slot),
                        None => {
                            active.fetch_sub(1, std::sync::atomic::Ordering::AcqRel);
                            let _ = stream.set_write_timeout(Some(Duration::from_secs(1)));
                            let _ = stream
                                .write_all(b"{\"ok\":false,\"error\":\"too many connections\"}\n");
                            continue;
                        }
                    }
                };
                let state = state.clone();
                thread::spawn(move || {
                    let _guard = ConnectionGuard(active);
                    let _peer_slot = peer_slot;
                    let deadline = state.config.ext.read_deadline;
                    if let Err(error) = handle_client(stream, state, peer, deadline) {
                        eprintln!("relay connection error: {error}");
                    }
                });
            }
            Err(error) => eprintln!("relay accept error: {error}"),
        }
    }

    Ok(())
}

/// Decrements the active-connection counter when a worker thread exits,
/// including on panic, so a wedged or crashed handler can never leak a
/// connection slot.
pub(crate) struct ConnectionGuard(Arc<std::sync::atomic::AtomicUsize>);

impl Drop for ConnectionGuard {
    fn drop(&mut self) {
        self.0.fetch_sub(1, std::sync::atomic::Ordering::AcqRel);
    }
}

pub(crate) fn handle_client(
    stream: std::net::TcpStream,
    state: RelayState,
    peer: String,
    read_deadline: Duration,
) -> std::io::Result<()> {
    let reader_stream = DeadlineReader {
        stream: stream.try_clone()?,
        deadline: std::time::Instant::now() + read_deadline,
    };
    // A slow or stuck client should not be able to wedge a relay worker thread
    // by accepting writes byte-by-byte. The 10-second write timeout covers the
    // worst-case response size with plenty of headroom.
    stream.set_write_timeout(Some(Duration::from_secs(10)))?;
    let mut reader = BufReader::new(reader_stream);
    let mut writer = BufWriter::new(DeadlineWriter {
        stream,
        limit: RESPONSE_WRITE_DEADLINE,
        deadline: None,
    });

    let mut line = String::new();
    let bytes_read = read_line_bounded(&mut reader, &mut line, state.config.max_line_bytes)?;
    if bytes_read == 0 {
        return Ok(());
    }
    if is_http_request_line(&line) {
        let (status, response) = handle_http_request(&line, &mut reader, &state, &peer);
        write_http_response(&mut writer, status, &response)?;
    } else {
        let response = handle_request_bytes(line.as_bytes(), bytes_read, &state, &peer);
        serde_json::to_writer(&mut writer, &response)?;
        writer.write_all(b"\n")?;
    }
    writer.flush()?;

    Ok(())
}

pub(crate) fn serve_udp(socket: UdpSocket, state: RelayState, config: RelayConfig) {
    let buffer_len = config.max_line_bytes.min(65_507);
    let mut buffer = vec![0_u8; buffer_len];
    loop {
        match socket.recv_from(&mut buffer) {
            Ok((bytes_read, peer)) => {
                // Sealed or cleartext, as the datagram came. Nothing goes
                // back for what is refused or invalid.
                let Some(response_bytes) =
                    crate::udp_sealed::answer_datagram(&buffer[..bytes_read], &state, peer)
                else {
                    continue;
                };
                if let Err(error) = socket.send_to(&response_bytes, peer) {
                    eprintln!("relay udp send error: {error}");
                }
            }
            Err(error) => eprintln!("relay udp receive error: {error}"),
        }
    }
}
