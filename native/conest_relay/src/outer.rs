//! The outer layer: what a relay's traffic looks like on the wire.
//!
//! An [OuterLayer] turns an accepted TCP connection into the byte stream
//! the relay protocols run over (detected by their first bytes, as on port
//! 7667), or serves the connection itself. Two layers so far:
//! - [PlainLayer]: the connection as it is (port 7667);
//! - [TlsLayer]: TLS (rustls, the operator's certificate) on 443 or any
//!   port. Inside, a WebSocket upgrade on a secret path carries the relay's
//!   bytes (v2 sessions, and v1 lines); every other request is the decoy's:
//!   a built-in page, a directory, or a reverse proxy to a real site. A
//!   probe without the secret path sees an ordinary web server.
//!
//! M38 adds Reality-like, QUIC and SSH layers on the same trait.

use std::future::Future;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64_STANDARD;
use rustls_pki_types::pem::PemObject;
use rustls_pki_types::{CertificateDer, PrivateKeyDer};
use sha1::{Digest, Sha1};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, DuplexStream};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{Semaphore, mpsc};
use tokio::time::{Instant, timeout, timeout_at};

use crate::limits::peer_key;
use crate::storage::RelayState;

/// A byte stream the relay protocols run over.
pub(crate) trait OuterStream: AsyncRead + AsyncWrite + Unpin + Send + 'static {}
impl<T: AsyncRead + AsyncWrite + Unpin + Send + 'static> OuterStream for T {}

pub(crate) type BoxedStream = Box<dyn OuterStream>;
pub(crate) type Opened = Pin<Box<dyn Future<Output = std::io::Result<Option<BoxedStream>>> + Send>>;

/// One way traffic is wrapped on the wire.
pub(crate) trait OuterLayer: Send + Sync + 'static {
    /// The relay's byte stream inside [stream], or none when the layer
    /// served the connection itself (a decoy).
    fn open(&self, stream: TcpStream, deadline: Duration) -> Opened;
}

/// Port 7667: the connection as it is (served by `server::serve` today;
/// here for layers that wrap others).
#[allow(dead_code)]
pub(crate) struct PlainLayer;

impl OuterLayer for PlainLayer {
    fn open(&self, stream: TcpStream, _deadline: Duration) -> Opened {
        Box::pin(async move { Ok(Some(Box::new(stream) as BoxedStream)) })
    }
}

/// What a probe (or any request off the secret path) is served.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Decoy {
    /// A plain web server's welcome page.
    Builtin,
    /// Static files from a directory.
    Dir(PathBuf),
    /// A reverse proxy to a real site (`host:port`, plain HTTP): the
    /// request goes there as it came.
    Proxy(String),
}

/// TLS with a WebSocket on a secret path, and a decoy for the rest.
pub(crate) struct TlsLayer {
    acceptor: tokio_rustls::TlsAcceptor,
    path: String,
    decoy: Decoy,
}

pub(crate) const TLS_CERT_LABEL: &[u8] = b"conest-relay-tls-cert-v2";
/// How long a signed certificate hash is good for.
const TLS_CERT_VALID_MILLIS: u64 = 24 * 60 * 60 * 1000;

/// What the identity signs for a certificate: the name it is served under,
/// when the statement ends, and the certificate's SHA-256.
pub(crate) fn tls_cert_message(host: &str, expires_millis: u64, hash: &[u8]) -> Vec<u8> {
    let mut message = TLS_CERT_LABEL.to_vec();
    message.extend_from_slice(&(host.len() as u16).to_be_bytes());
    message.extend_from_slice(host.as_bytes());
    message.extend_from_slice(&expires_millis.to_be_bytes());
    message.extend_from_slice(hash);
    message
}
const MAX_HEAD: usize = 16 * 1024;
const MAX_WS_FRAME: usize = 2 * 1024 * 1024;
const WS_GUID: &str = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
/// A decoy connection (proxied) lasts at most this long.
const DECOY_LIMIT: Duration = Duration::from_secs(300);
const MAX_DECOY_FILE: u64 = 8 * 1024 * 1024;
/// nginx's defaults: 100 requests on a connection, 75 s idle.
const DECOY_KEEPALIVE_REQUESTS: usize = 100;
const DECOY_KEEPALIVE_IDLE: Duration = Duration::from_secs(75);
/// ...and a connection never lasts longer than this in all.
const DECOY_KEEPALIVE_TOTAL: Duration = Duration::from_secs(600);

/// The length of the request head at the start of [bytes], if complete.
fn head_len(bytes: &[u8]) -> Option<usize> {
    bytes
        .windows(4)
        .position(|window| window == b"\r\n\r\n")
        .map(|end| end + 4)
}

/// When this relay's decoy "was last modified" (its start), for
/// Last-Modified and ETag.
fn decoy_epoch() -> u64 {
    static START: std::sync::OnceLock<u64> = std::sync::OnceLock::new();
    *START.get_or_init(|| {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs()
    })
}

fn invalid(what: impl Into<String>) -> std::io::Error {
    std::io::Error::new(std::io::ErrorKind::InvalidData, what.into())
}

/// The rustls server configuration for [cert] and [key] (PEM files).
pub(crate) fn tls_config(cert: &Path, key: &Path) -> Result<rustls::ServerConfig, String> {
    let certs: Vec<CertificateDer<'static>> = CertificateDer::pem_file_iter(cert)
        .map_err(|error| format!("reading {}: {error}", cert.display()))?
        .collect::<Result<_, _>>()
        .map_err(|error| format!("reading {}: {error}", cert.display()))?;
    if certs.is_empty() {
        return Err(format!("no certificate in {}", cert.display()));
    }
    let key = PrivateKeyDer::from_pem_file(key)
        .map_err(|error| format!("reading {}: {error}", key.display()))?;
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let mut config = rustls::ServerConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .map_err(|error| format!("TLS versions: {error}"))?
        .with_no_client_auth()
        .with_single_cert(certs, key)
        .map_err(|error| format!("TLS certificate: {error}"))?;
    config.alpn_protocols = vec![b"http/1.1".to_vec()];
    Ok(config)
}

impl TlsLayer {
    pub(crate) fn new(config: rustls::ServerConfig, path: String, decoy: Decoy) -> Self {
        Self {
            acceptor: tokio_rustls::TlsAcceptor::from(Arc::new(config)),
            path,
            decoy,
        }
    }
}

/// A parsed HTTP request head.
#[derive(Clone)]
pub(crate) struct Head {
    pub(crate) method: String,
    pub(crate) path: String,
    pub(crate) headers: Vec<(String, String)>,
}

impl Head {
    fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(key, _)| key.eq_ignore_ascii_case(name))
            .map(|(_, value)| value.as_str())
    }
}

pub(crate) fn parse_head(bytes: &[u8]) -> Option<Head> {
    let text = std::str::from_utf8(bytes).ok()?;
    let mut lines = text.split("\r\n");
    let mut request = lines.next()?.split(' ');
    let method = request.next()?.to_owned();
    let path = request.next()?.to_owned();
    if !request.next()?.starts_with("HTTP/1.") {
        return None;
    }
    let mut headers = Vec::new();
    for line in lines {
        if line.is_empty() {
            break;
        }
        let (name, value) = line.split_once(':')?;
        headers.push((name.trim().to_owned(), value.trim().to_owned()));
        if headers.len() > 100 {
            return None;
        }
    }
    Some(Head {
        method,
        path,
        headers,
    })
}

/// Reads a request head (to its blank line) by [deadline]: the head's
/// length when one came, and everything read.
async fn read_head<S: AsyncRead + Unpin>(
    stream: &mut S,
    deadline: Instant,
) -> (Option<usize>, Vec<u8>) {
    read_head_from(stream, deadline, Vec::with_capacity(4096)).await
}

/// [read_head] continuing from bytes already read (a pipelined request).
async fn read_head_from<S: AsyncRead + Unpin>(
    stream: &mut S,
    deadline: Instant,
    mut buffer: Vec<u8>,
) -> (Option<usize>, Vec<u8>) {
    let mut chunk = [0_u8; 4096];
    loop {
        if let Some(end) = buffer.windows(4).position(|window| window == b"\r\n\r\n") {
            return (Some(end + 4), buffer);
        }
        if buffer.len() > MAX_HEAD {
            return (None, buffer);
        }
        match timeout_at(deadline, stream.read(&mut chunk)).await {
            Ok(Ok(read)) if read > 0 => buffer.extend_from_slice(&chunk[..read]),
            _ => return (None, buffer),
        }
    }
}

fn websocket_accept(key: &str) -> String {
    let mut hasher = Sha1::new();
    hasher.update(key.as_bytes());
    hasher.update(WS_GUID.as_bytes());
    BASE64_STANDARD.encode(hasher.finalize())
}

impl OuterLayer for TlsLayer {
    fn open(&self, stream: TcpStream, deadline: Duration) -> Opened {
        let acceptor = self.acceptor.clone();
        let path = self.path.clone();
        let decoy = self.decoy.clone();
        Box::pin(async move {
            let until = Instant::now() + deadline;
            let mut tls = timeout_at(until, acceptor.accept(stream))
                .await
                .map_err(|_| invalid("TLS handshake took too long"))??;
            let (end, read) = read_head(&mut tls, until).await;
            let head = end.and_then(|end| parse_head(&read[..end]).map(|head| (head, end)));
            if let Some((head, end)) = &head {
                let upgrade = head
                    .header("upgrade")
                    .is_some_and(|value| value.eq_ignore_ascii_case("websocket"));
                let version = head.header("sec-websocket-version") == Some("13");
                if head.method == "GET"
                    && head.path == path
                    && upgrade
                    && version
                    && let Some(key) = head.header("sec-websocket-key")
                    && key.len() <= 64
                {
                    let reply = format!(
                        "HTTP/1.1 101 Switching Protocols\r\n\
                         Upgrade: websocket\r\n\
                         Connection: Upgrade\r\n\
                         Sec-WebSocket-Accept: {}\r\n\r\n",
                        websocket_accept(key)
                    );
                    timeout_at(until, tls.write_all(reply.as_bytes()))
                        .await
                        .map_err(|_| invalid("upgrade not taken"))??;
                    let initial = read[*end..].to_vec();
                    return Ok(Some(Box::new(websocket_bridge(tls, initial)) as BoxedStream));
                }
            }
            serve_decoy(tls, head.map(|(head, _)| head), read, &decoy).await;
            Ok(None)
        })
    }
}

/// A WebSocket frame from the client: (opcode, payload).
fn take_ws_frame(buffer: &mut Vec<u8>) -> Result<Option<(u8, Vec<u8>)>, String> {
    if buffer.len() < 2 {
        return Ok(None);
    }
    let opcode = buffer[0] & 0x0f;
    if buffer[1] & 0x80 == 0 {
        return Err("client frames must be masked".to_owned());
    }
    let short = (buffer[1] & 0x7f) as usize;
    let (length, offset) = match short {
        126 => {
            if buffer.len() < 4 {
                return Ok(None);
            }
            (u16::from_be_bytes([buffer[2], buffer[3]]) as usize, 4)
        }
        127 => {
            if buffer.len() < 10 {
                return Ok(None);
            }
            let mut bytes = [0_u8; 8];
            bytes.copy_from_slice(&buffer[2..10]);
            let length = u64::from_be_bytes(bytes);
            if length > MAX_WS_FRAME as u64 {
                return Err("websocket frame too large".to_owned());
            }
            (length as usize, 10)
        }
        length => (length, 2),
    };
    if length > MAX_WS_FRAME {
        return Err("websocket frame too large".to_owned());
    }
    if buffer.len() < offset + 4 + length {
        return Ok(None);
    }
    let mask = [
        buffer[offset],
        buffer[offset + 1],
        buffer[offset + 2],
        buffer[offset + 3],
    ];
    let start = offset + 4;
    let payload: Vec<u8> = buffer[start..start + length]
        .iter()
        .enumerate()
        .map(|(index, byte)| byte ^ mask[index % 4])
        .collect();
    buffer.drain(..start + length);
    Ok(Some((opcode, payload)))
}

/// A server frame (unmasked).
pub(crate) fn ws_frame(opcode: u8, payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(payload.len() + 10);
    out.push(0x80 | opcode);
    match payload.len() {
        length if length < 126 => out.push(length as u8),
        length if length <= u16::MAX as usize => {
            out.push(126);
            out.extend_from_slice(&(length as u16).to_be_bytes());
        }
        length => {
            out.push(127);
            out.extend_from_slice(&(length as u64).to_be_bytes());
        }
    }
    out.extend_from_slice(payload);
    out
}

/// The relay's byte stream inside a WebSocket: binary frames in and out.
/// [initial] is what came after the upgrade request.
fn websocket_bridge<S>(stream: S, initial: Vec<u8>) -> DuplexStream
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    let (relay_side, bridge_side) = tokio::io::duplex(256 * 1024);
    let (mut from_net, mut to_net) = tokio::io::split(stream);
    let (mut bridge_read, mut bridge_write) = tokio::io::split(bridge_side);
    let (control, mut controls) = mpsc::channel::<Vec<u8>>(8);
    let incoming = tokio::spawn(async move {
        let mut buffer = initial;
        let mut chunk = vec![0_u8; 16 * 1024];
        loop {
            loop {
                match take_ws_frame(&mut buffer) {
                    Ok(Some((0x0..=0x2, payload))) => {
                        if bridge_write.write_all(&payload).await.is_err() {
                            return;
                        }
                    }
                    Ok(Some((0x8, _))) => {
                        let _ = control.send(ws_frame(0x8, &[])).await;
                        return;
                    }
                    Ok(Some((0x9, payload))) => {
                        if payload.len() <= 125 {
                            let _ = control.send(ws_frame(0xa, &payload)).await;
                        }
                    }
                    Ok(Some(_)) => {}
                    Ok(None) => break,
                    Err(_) => return,
                }
            }
            match from_net.read(&mut chunk).await {
                Ok(read) if read > 0 => buffer.extend_from_slice(&chunk[..read]),
                _ => return,
            }
            if buffer.len() > MAX_WS_FRAME + 16 {
                return;
            }
        }
    });
    tokio::spawn(async move {
        let mut chunk = vec![0_u8; 64 * 1024];
        loop {
            tokio::select! {
                read = bridge_read.read(&mut chunk) => {
                    match read {
                        Ok(read) if read > 0 => {
                            if to_net.write_all(&ws_frame(0x2, &chunk[..read])).await.is_err()
                                || to_net.flush().await.is_err()
                            {
                                break;
                            }
                        }
                        _ => {
                            let _ = to_net.write_all(&ws_frame(0x8, &[])).await;
                            let _ = to_net.flush().await;
                            break;
                        }
                    }
                }
                frame = controls.recv() => {
                    match frame {
                        Some(frame) => {
                            let close = frame.first() == Some(&0x88);
                            if to_net.write_all(&frame).await.is_err()
                                || to_net.flush().await.is_err()
                                || close
                            {
                                break;
                            }
                        }
                        None => break,
                    }
                }
            }
        }
        // Either side gone: the other ends too.
        incoming.abort();
        let _ = to_net.shutdown().await;
    });
    relay_side
}

/// An HTTP date (RFC 9110), as web servers send it.
pub(crate) fn http_date(time: SystemTime) -> String {
    let seconds = time
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let days = seconds / 86_400;
    let rest = seconds % 86_400;
    let weekday = ["Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed"][(days % 7) as usize];
    // Days to a civil date (Howard Hinnant's algorithm).
    let z = days as i64 + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    let month_name = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ][(month - 1) as usize];
    format!(
        "{weekday}, {day:02} {month_name} {year} {:02}:{:02}:{:02} GMT",
        rest / 3600,
        rest % 3600 / 60,
        rest % 60
    )
}

const BUILTIN_PAGE: &str = "<!DOCTYPE html>\n<html>\n<head>\n<title>Welcome to nginx!</title>\n<style>\nhtml { color-scheme: light dark; }\nbody { width: 35em; margin: 0 auto;\nfont-family: Tahoma, Verdana, Arial, sans-serif; }\n</style>\n</head>\n<body>\n<h1>Welcome to nginx!</h1>\n<p>If you see this page, the nginx web server is successfully installed and\nworking. Further configuration is required.</p>\n\n<p>For online documentation and support please refer to\n<a href=\"http://nginx.org/\">nginx.org</a>.<br/>\nCommercial support is available at\n<a href=\"http://nginx.com/\">nginx.com</a>.</p>\n\n<p><em>Thank you for using nginx.</em></p>\n</body>\n</html>\n";

fn error_page(status: u16, reason: &str) -> String {
    format!(
        "<html>\r\n<head><title>{status} {reason}</title></head>\r\n<body>\r\n<center><h1>{status} {reason}</h1></center>\r\n<hr><center>nginx</center>\r\n</body>\r\n</html>\r\n"
    )
}

fn content_type(path: &Path) -> &'static str {
    match path.extension().and_then(|extension| extension.to_str()) {
        Some("html" | "htm") => "text/html",
        Some("css") => "text/css",
        Some("js") => "application/javascript",
        Some("json") => "application/json",
        Some("png") => "image/png",
        Some("jpg" | "jpeg") => "image/jpeg",
        Some("gif") => "image/gif",
        Some("svg") => "image/svg+xml",
        Some("ico") => "image/x-icon",
        Some("txt") => "text/plain",
        Some("woff2") => "font/woff2",
        _ => "application/octet-stream",
    }
}

/// The decoy's answer to [head] (none: not HTTP), from the built-in page
/// or [dir]: status, content type, body.
pub(crate) fn static_answer(
    head: Option<&Head>,
    dir: Option<&Path>,
) -> (u16, &'static str, Vec<u8>) {
    let Some(head) = head else {
        return (
            400,
            "text/html",
            error_page(400, "Bad Request").into_bytes(),
        );
    };
    if head.method != "GET" && head.method != "HEAD" {
        return (
            405,
            "text/html",
            error_page(405, "Not Allowed").into_bytes(),
        );
    }
    let path = head.path.split(['?', '#']).next().unwrap_or("/");
    let Some(dir) = dir else {
        return if path == "/" || path == "/index.html" {
            (200, "text/html", BUILTIN_PAGE.as_bytes().to_vec())
        } else {
            (404, "text/html", error_page(404, "Not Found").into_bytes())
        };
    };
    let relative = path.trim_start_matches('/');
    let relative = if relative.is_empty() || relative.ends_with('/') {
        format!("{relative}index.html")
    } else {
        relative.to_owned()
    };
    let safe = !relative
        .split('/')
        .any(|part| part.is_empty() || part == ".." || part.starts_with('.'))
        && !relative.contains('\\');
    let file = dir.join(&relative);
    if safe
        && let Ok(metadata) = std::fs::metadata(&file)
        && metadata.is_file()
        && metadata.len() <= MAX_DECOY_FILE
        && let Ok(body) = std::fs::read(&file)
    {
        return (200, content_type(&file), body);
    }
    (404, "text/html", error_page(404, "Not Found").into_bytes())
}

fn reason(status: u16) -> &'static str {
    match status {
        200 => "OK",
        400 => "Bad Request",
        404 => "Not Found",
        405 => "Not Allowed",
        _ => "Error",
    }
}

async fn serve_decoy<S>(mut stream: S, head: Option<Head>, read: Vec<u8>, decoy: &Decoy)
where
    S: AsyncRead + AsyncWrite + Unpin + Send,
{
    match decoy {
        Decoy::Proxy(target) => {
            // What came goes to the real site as it came; its answer comes
            // back as it is.
            let Ok(Ok(mut upstream)) =
                timeout(Duration::from_secs(10), TcpStream::connect(target)).await
            else {
                return;
            };
            if upstream.write_all(&read).await.is_err() {
                return;
            }
            let _ = timeout(
                DECOY_LIMIT,
                tokio::io::copy_bidirectional(&mut stream, &mut upstream),
            )
            .await;
        }
        Decoy::Builtin | Decoy::Dir(_) => {
            let dir = match decoy {
                Decoy::Dir(dir) => Some(dir.clone()),
                _ => None,
            };
            let mut head = head;
            let mut pipelined: Vec<u8> = read
                .get(head_len(&read).unwrap_or(read.len())..)
                .map(<[u8]>::to_vec)
                .unwrap_or_default();
            let connection_ends = Instant::now() + DECOY_KEEPALIVE_TOTAL;
            // As nginx does: keep the connection for more requests (75 s
            // idle, 100 requests), unless the client or the request ends it.
            for served in 1..=DECOY_KEEPALIVE_REQUESTS {
                // Files are read off the async threads.
                let (shown, wanted) = (head.clone(), dir.clone());
                let Ok((status, kind, body)) = tokio::task::spawn_blocking(move || {
                    static_answer(shown.as_ref(), wanted.as_deref())
                })
                .await
                else {
                    return;
                };
                let is_head = head.as_ref().is_some_and(|head| head.method == "HEAD");
                let keep = served < DECOY_KEEPALIVE_REQUESTS
                    && Instant::now() < connection_ends
                    && head.as_ref().is_some_and(|head| {
                        (head.method == "GET" || head.method == "HEAD")
                            && !head
                                .header("connection")
                                .is_some_and(|value| value.eq_ignore_ascii_case("close"))
                    });
                let validators = if status == 200 {
                    let start = decoy_epoch();
                    format!(
                        "Last-Modified: {}\r\nETag: \"{:x}-{:x}\"\r\nAccept-Ranges: bytes\r\n",
                        http_date(UNIX_EPOCH + Duration::from_secs(start)),
                        start,
                        body.len()
                    )
                } else {
                    String::new()
                };
                let mut answer = format!(
                    "HTTP/1.1 {status} {}\r\nServer: nginx\r\nDate: {}\r\nContent-Type: {kind}\r\nContent-Length: {}\r\n{validators}Connection: {}\r\n\r\n",
                    reason(status),
                    http_date(SystemTime::now()),
                    body.len(),
                    if keep { "keep-alive" } else { "close" }
                )
                .into_bytes();
                if !is_head {
                    answer.extend_from_slice(&body);
                }
                let written = timeout(Duration::from_secs(30), async {
                    stream.write_all(&answer).await?;
                    stream.flush().await
                })
                .await;
                if !keep || !matches!(written, Ok(Ok(()))) {
                    let _ = timeout(Duration::from_secs(5), stream.shutdown()).await;
                    return;
                }
                let idle_until = (Instant::now() + DECOY_KEEPALIVE_IDLE).min(connection_ends);
                let (end, next) =
                    read_head_from(&mut stream, idle_until, std::mem::take(&mut pipelined))
                        .await;
                head = end.and_then(|end| parse_head(&next[..end]));
                pipelined = end.map(|end| next[end..].to_vec()).unwrap_or_default();
                if head.is_none() {
                    let _ = timeout(Duration::from_secs(5), stream.shutdown()).await;
                    return;
                }
            }
        }
    }
}

/// Serves [listener] through [layer], with the same caps as port 7667:
/// the relay-wide connection cap and the per-address one.
pub(crate) async fn serve_outer(
    listener: TcpListener,
    layer: Arc<dyn OuterLayer>,
    state: RelayState,
) -> std::io::Result<()> {
    let permits = Arc::new(Semaphore::new(state.config.max_connections));
    loop {
        let (stream, address) = match listener.accept().await {
            Ok(accepted) => accepted,
            Err(error) => {
                eprintln!("relay accept error: {error}");
                tokio::time::sleep(Duration::from_millis(20)).await;
                continue;
            }
        };
        let _ = stream.set_nodelay(true);
        // Past a cap, the connection is just closed (as a busy web server
        // would): nothing relay-like goes back.
        let Ok(permit) = Arc::clone(&permits).try_acquire_owned() else {
            continue;
        };
        let peer = peer_key(address.ip());
        let Some(slot) = state.connection_slot(&peer) else {
            continue;
        };
        // Whatever arrives through a tunnel (TLS, a WebSocket, a borrowed
        // handshake) was written by the client itself: its X-Forwarded-For
        // is no proxy's word.
        let mut state = state.clone();
        state.config.trust_forwarded_for = false;
        let layer = Arc::clone(&layer);
        tokio::spawn(async move {
            let _permit = permit;
            let _slot = slot;
            let deadline = state.config.ext.read_deadline;
            match layer.open(stream, deadline).await {
                Ok(Some(inner)) => {
                    if let Err(error) = crate::server::handle_connection(inner, state, peer).await {
                        eprintln!("relay connection error: {error}");
                    }
                }
                Ok(None) => {}
                Err(_) => {
                    // Failed TLS handshakes are what scanners do: not logged.
                }
            }
        });
    }
}

/// Builds the TLS layer from the configuration, when TLS is on.
pub(crate) fn tls_layer(state: &RelayState) -> Result<Option<TlsLayer>, String> {
    let ext = &state.config.ext;
    let (Some(cert), Some(key)) = (&ext.tls_cert, &ext.tls_key) else {
        return Ok(None);
    };
    let config = tls_config(cert, key)?;
    let decoy = match (&ext.decoy_dir, &ext.decoy_proxy) {
        (_, Some(proxy)) => Decoy::Proxy(proxy.clone()),
        (Some(dir), None) => Decoy::Dir(dir.clone()),
        (None, None) => Decoy::Builtin,
    };
    Ok(Some(TlsLayer::new(config, state.ws_path()?, decoy)))
}

impl RelayState {
    /// The TLS certificate's SHA-256 and the identity's signature over it
    /// (label, then the hash), told to trusted sessions so a client can
    /// accept a self-signed certificate on the hidden address only when it
    /// is this very one, before it sends the secret path.
    pub(crate) fn tls_cert_info(&self) -> Option<serde_json::Value> {
        use sha2::Digest;
        let path = self.config.ext.tls_cert.as_ref()?;
        let leaf = CertificateDer::pem_file_iter(path).ok()?.next()?.ok()?;
        let hash: [u8; 32] = sha2::Sha256::digest(leaf.as_ref()).into();
        let host = self.config.ext.public_host.clone()?;
        let expires = crate::config::now_millis() + TLS_CERT_VALID_MILLIS;
        let message = tls_cert_message(&host, expires, &hash);
        Some(serde_json::json!({
            "sha256": BASE64_STANDARD.encode(hash),
            "host": host,
            "expires": expires,
            "sig": BASE64_STANDARD.encode(self.identity.sign(&message)),
        }))
    }

    /// Where and how to reach the borrowed-handshake layer, when it is on
    /// and a public host is set: told to clients inside sessions only.
    pub(crate) fn borrowed_info(&self) -> Option<serde_json::Value> {
        let ext = &self.config.ext;
        let host = ext.public_host.as_deref()?;
        let port = ext.borrow_bind.as_deref()?.rsplit(':').next()?.parse::<u16>().ok()?;
        let site = ext.borrow_site.as_deref()?;
        let sni = ext
            .borrow_sni
            .clone()
            .unwrap_or_else(|| site.rsplit_once(':').map_or(site, |(host, _)| host).to_owned());
        Some(serde_json::json!({"host": host, "port": port, "sni": sni}))
    }

    /// The relay's hidden address, when TLS and a public host are set:
    /// told to clients inside sessions only.
    pub(crate) fn hidden_address(&self) -> Option<String> {
        let ext = &self.config.ext;
        let host = ext.public_host.as_deref()?;
        let bind = ext.tls_bind.as_deref()?;
        let port = bind.rsplit(':').next()?.parse::<u16>().ok()?;
        let path = self.ws_path().ok()?;
        Some(if port == 443 {
            format!("wss://{host}{path}")
        } else {
            format!("wss://{host}:{port}{path}")
        })
    }

    /// The secret WebSocket path: the configured one, or one made once and
    /// kept in the database.
    pub(crate) fn ws_path(&self) -> Result<String, String> {
        if let Some(path) = &self.config.ext.ws_path {
            return Ok(format!("/{}", path.trim_start_matches('/')));
        }
        let database = self
            .database
            .lock()
            .expect("relay database lock should not poison");
        let stored: Option<Vec<u8>> = rusqlite::OptionalExtension::optional(database.query_row(
            "SELECT value FROM relay_settings WHERE name = 'ws_path'",
            [],
            |row| row.get(0),
        ))
        .map_err(|error| format!("reading the WebSocket path: {error}"))?;
        if let Some(path) = stored.and_then(|bytes| String::from_utf8(bytes).ok()) {
            return Ok(path);
        }
        use rand::RngCore;
        let mut bytes = [0_u8; 18];
        rand::rngs::OsRng.fill_bytes(&mut bytes);
        let path = format!(
            "/{}",
            base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes)
        );
        database
            .execute(
                "INSERT OR REPLACE INTO relay_settings (name, value) VALUES ('ws_path', ?1)",
                rusqlite::params![path.as_bytes()],
            )
            .map_err(|error| format!("storing the WebSocket path: {error}"))?;
        Ok(path)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parity_tests::parity_config;
    use std::io::{Read, Write};
    use std::net::SocketAddr;

    const SECRET: &str = "/s3cret-path-for-tests";
    const UPSTREAM: &[u8] =
        b"HTTP/1.1 200 OK\r\nServer: Apache\r\nContent-Length: 11\r\n\r\nhello world";

    fn fixture(name: &str) -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../test/fixtures/relay_v2/tls")
            .join(name)
    }

    fn start_tls(decoy: Decoy) -> (SocketAddr, RelayState) {
        let state = RelayState::new(
            parity_config(),
            crate::identity::RelayIdentity::from_seed_bytes([7_u8; 32]),
        );
        let config = tls_config(&fixture("cert.pem"), &fixture("key.pem")).expect("tls config");
        let layer: Arc<dyn OuterLayer> = Arc::new(TlsLayer::new(config, SECRET.to_owned(), decoy));
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
        let address = listener.local_addr().expect("address");
        listener.set_nonblocking(true).expect("nonblocking");
        let serving = state.clone();
        std::thread::spawn(move || {
            let runtime = tokio::runtime::Builder::new_multi_thread()
                .worker_threads(2)
                .enable_all()
                .build()
                .expect("runtime");
            runtime.block_on(async move {
                let listener = TcpListener::from_std(listener).expect("listener");
                let _ = serve_outer(listener, layer, serving).await;
            });
        });
        (address, state)
    }

    /// A fake real site: answers anything with [UPSTREAM], and remembers
    /// what it was sent.
    fn start_upstream() -> String {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
        let address = listener.local_addr().expect("address");
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut stream) = stream else { continue };
                std::thread::spawn(move || {
                    stream
                        .set_read_timeout(Some(std::time::Duration::from_millis(300)))
                        .ok();
                    let mut buffer = [0_u8; 4096];
                    let _ = stream.read(&mut buffer);
                    let _ = stream.write_all(UPSTREAM);
                });
            }
        });
        address.to_string()
    }

    fn tls_client(
        address: SocketAddr,
    ) -> rustls::StreamOwned<rustls::ClientConnection, std::net::TcpStream> {
        let mut roots = rustls::RootCertStore::empty();
        roots
            .add(CertificateDer::from_pem_file(fixture("ca.pem")).expect("ca"))
            .expect("root");
        let config = rustls::ClientConfig::builder_with_provider(Arc::new(
            rustls::crypto::ring::default_provider(),
        ))
        .with_safe_default_protocol_versions()
        .expect("versions")
        .with_root_certificates(roots)
        .with_no_client_auth();
        let name = rustls_pki_types::ServerName::try_from("localhost").expect("name");
        let connection = rustls::ClientConnection::new(Arc::new(config), name).expect("client");
        let tcp = std::net::TcpStream::connect(address).expect("connect");
        tcp.set_read_timeout(Some(std::time::Duration::from_secs(5)))
            .expect("timeout");
        rustls::StreamOwned::new(connection, tcp)
    }

    fn exchange(address: SocketAddr, request: &[u8]) -> Vec<u8> {
        let mut tls = tls_client(address);
        tls.write_all(request).expect("send");
        let mut answer = Vec::new();
        let _ = tls.read_to_end(&mut answer);
        answer
    }

    fn without_date(answer: &[u8]) -> String {
        String::from_utf8_lossy(answer)
            .lines()
            .filter(|line| !line.starts_with("Date:"))
            .collect::<Vec<_>>()
            .join("\n")
    }

    fn masked(opcode: u8, payload: &[u8]) -> Vec<u8> {
        let mask = [0x11_u8, 0x22, 0x33, 0x44];
        let mut out = vec![0x80 | opcode];
        if payload.len() < 126 {
            out.push(0x80 | payload.len() as u8);
        } else {
            out.push(0x80 | 126);
            out.extend_from_slice(&(payload.len() as u16).to_be_bytes());
        }
        out.extend_from_slice(&mask);
        out.extend(
            payload
                .iter()
                .enumerate()
                .map(|(index, byte)| byte ^ mask[index % 4]),
        );
        out
    }

    #[test]
    fn the_secret_path_carries_relay_requests_inside_tls_and_a_websocket() {
        let (address, _) = start_tls(Decoy::Builtin);
        let mut tls = tls_client(address);
        let key = "dGhlIHNhbXBsZSBub25jZQ==";
        tls.write_all(
            format!(
                "GET {SECRET} HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
            )
            .as_bytes(),
        )
        .expect("upgrade");
        let mut head = Vec::new();
        let mut byte = [0_u8; 1];
        while !head.ends_with(b"\r\n\r\n") {
            tls.read_exact(&mut byte).expect("head");
            head.push(byte[0]);
        }
        let head = String::from_utf8(head).expect("utf8");
        assert!(head.starts_with("HTTP/1.1 101"), "{head}");
        // RFC 6455's example key and answer.
        assert!(head.contains("s3pPLMBiTxaQ9kYGzzhZRbK+xOo="), "{head}");
        // A v1 line, split over two frames, and its answer in binary frames.
        let line = b"{\"action\":\"health\"}\n";
        tls.write_all(&masked(0x2, &line[..5])).expect("frame");
        tls.write_all(&masked(0x0, &line[5..])).expect("frame");
        let mut answer = Vec::new();
        while !answer.ends_with(b"\n") {
            let mut header = [0_u8; 2];
            tls.read_exact(&mut header).expect("frame header");
            assert_eq!(header[0] & 0x0f, 0x2, "binary frames");
            let length = match header[1] & 0x7f {
                126 => {
                    let mut bytes = [0_u8; 2];
                    tls.read_exact(&mut bytes).expect("length");
                    u16::from_be_bytes(bytes) as usize
                }
                length => length as usize,
            };
            let mut payload = vec![0_u8; length];
            tls.read_exact(&mut payload).expect("payload");
            answer.extend_from_slice(&payload);
        }
        let answer: serde_json::Value = serde_json::from_slice(&answer).expect("json");
        assert_eq!(answer["ok"], true, "{answer}");
        assert_eq!(answer["stats"]["v2"]["sessions"], 1);
    }

    #[test]
    fn probes_get_the_decoy_byte_for_byte() {
        let upstream = start_upstream();
        let (address, _) = start_tls(Decoy::Proxy(upstream));
        for probe in [
            "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n".to_owned(),
            "GET /nope HTTP/1.1\r\nHost: localhost\r\n\r\n".to_owned(),
            // The secret path without an upgrade: the decoy's, too.
            format!("GET {SECRET} HTTP/1.1\r\nHost: localhost\r\n\r\n"),
            format!("POST {SECRET} HTTP/1.1\r\nContent-Length: 2\r\n\r\nhi"),
            // Relay bytes are not answered as a relay would.
            "{\"action\":\"health\"}\n\r\n\r\n".to_owned(),
            "CNS2\u{1}\r\n\r\n".to_owned(),
        ] {
            assert_eq!(exchange(address, probe.as_bytes()), UPSTREAM, "{probe:?}");
        }
        // The built-in decoy: the secret path without an upgrade gets what
        // any unknown path gets.
        let (address, _) = start_tls(Decoy::Builtin);
        let unknown = exchange(
            address,
            b"GET /nope HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
        );
        let secret = exchange(
            address,
            format!("GET {SECRET} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n").as_bytes(),
        );
        assert!(String::from_utf8_lossy(&unknown).starts_with("HTTP/1.1 404 Not Found"));
        assert_eq!(without_date(&unknown), without_date(&secret));
        let front = exchange(
            address,
            b"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
        );
        assert!(String::from_utf8_lossy(&front).contains("Welcome to nginx!"));
    }

    #[test]
    fn the_builtin_decoy_keeps_the_connection_like_nginx_and_closes_when_asked() {
        let (address, _) = start_tls(Decoy::Builtin);
        let mut tls = tls_client(address);
        let mut answers = Vec::new();
        for _ in 0..2 {
            tls.write_all(b"GET / HTTP/1.1\r\nHost: x\r\n\r\n")
                .expect("send");
            // Read one answer by its Content-Length.
            let mut head = Vec::new();
            let mut byte = [0_u8; 1];
            while !head.ends_with(b"\r\n\r\n") {
                tls.read_exact(&mut byte).expect("head");
                head.push(byte[0]);
            }
            let text = String::from_utf8(head).expect("utf8");
            let length: usize = text
                .lines()
                .find_map(|line| line.strip_prefix("Content-Length: "))
                .expect("length")
                .parse()
                .expect("number");
            let mut body = vec![0_u8; length];
            tls.read_exact(&mut body).expect("body");
            answers.push(text);
        }
        for text in &answers {
            assert!(text.contains("Connection: keep-alive"), "{text}");
            assert!(text.contains("ETag: \""), "{text}");
            assert!(text.contains("Accept-Ranges: bytes"), "{text}");
        }
        tls.write_all(b"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
            .expect("send");
        let mut rest = Vec::new();
        let _ = tls.read_to_end(&mut rest);
        assert!(String::from_utf8_lossy(&rest).contains("Connection: close"));
    }

    #[test]
    fn pipelined_requests_to_the_decoy_are_all_answered() {
        let (address, _) = start_tls(Decoy::Builtin);
        let mut tls = tls_client(address);
        tls.write_all(
            b"GET / HTTP/1.1\r\nHost: x\r\n\r\nGET /nope HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
        )
        .expect("send");
        let mut all = Vec::new();
        let _ = tls.read_to_end(&mut all);
        let text = String::from_utf8_lossy(&all);
        assert!(text.contains("200 OK"), "{text}");
        assert!(text.contains("404 Not Found"), "the second request was dropped: {text}");
    }

    #[test]
    fn a_decoy_directory_serves_its_files_and_nothing_outside() {
        let dir =
            std::env::temp_dir().join(format!("conest-decoy-{}", crate::config::now_millis()));
        std::fs::create_dir_all(dir.join("css")).expect("dir");
        std::fs::write(dir.join("index.html"), b"<h1>Bakery</h1>").expect("index");
        std::fs::write(dir.join("css/site.css"), b"h1{}").expect("css");
        std::fs::write(dir.join(".secret"), b"no").expect("dotfile");
        let head = |path: &str| parse_head(format!("GET {path} HTTP/1.1\r\n\r\n").as_bytes());
        let answer = |path: &str| static_answer(head(path).as_ref(), Some(&dir));
        assert_eq!(answer("/"), (200, "text/html", b"<h1>Bakery</h1>".to_vec()));
        assert_eq!(answer("/css/site.css").0, 200);
        assert_eq!(answer("/css/site.css").1, "text/css");
        for hidden in ["/.secret", "/../etc/passwd", "/css/../../x", "/nope"] {
            assert_eq!(answer(hidden).0, 404, "{hidden}");
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_hidden_address_is_told_inside_sessions_only() {
        let mut config = parity_config();
        config.ext.tls_bind = Some("127.0.0.1:8443".to_owned());
        config.ext.tls_cert = Some(fixture("cert.pem"));
        config.ext.tls_key = Some(fixture("key.pem"));
        config.ext.ws_path = Some("hidden-path-123".to_owned());
        config.ext.public_host = Some("relay.test".to_owned());
        let relay = crate::parity_tests::start_tokio(config);
        assert_eq!(
            relay.state.hidden_address().as_deref(),
            Some("wss://relay.test:8443/hidden-path-123")
        );
        let mut client = crate::session::tests::TestClient::connect(
            relay.tcp,
            &crate::session::tests::relay_public(&relay.state),
        );
        // An anonymous session is not told.
        client.request(1, &serde_json::json!({"action": "health"}));
        let (_, anonymous) = client.next_json();
        assert!(anonymous["stats"]["v2"].get("hidden").is_none(), "{anonymous}");
        // Claiming a fresh id with a throwaway key proves nothing.
        let hash = client.handshake_hash.clone();
        let fresh = crate::owners::tests::prove(
            &mut client,
            3,
            "dev-fresh",
            &crate::owners::tests::owner_key(6),
            &hash,
        );
        assert_eq!(fresh["ok"], true, "{fresh}");
        client.request(5, &serde_json::json!({"action": "health"}));
        let (_, still) = client.next_json();
        assert!(still["stats"]["v2"].get("hidden").is_none(), "{still}");
        // One that proves a mailbox claimed days ago is told (a claim of
        // minutes ago is not enough).
        relay
            .state
            .claim_mailbox(
                "dev-user",
                crate::owners::tests::owner_key(5).verifying_key().to_bytes(),
                "198.51.100.9",
            )
            .expect("claimed earlier");
        let young = crate::owners::tests::prove(
            &mut client,
            6,
            "dev-user",
            &crate::owners::tests::owner_key(5),
            &hash,
        );
        assert_eq!(young["ok"], true, "{young}");
        client.request(8, &serde_json::json!({"action": "health"}));
        let (_, untrusted) = client.next_json();
        assert!(untrusted["stats"]["v2"].get("hidden").is_none(), "{untrusted}");
        relay
            .state
            .owners
            .lock()
            .unwrap()
            .by_mailbox
            .get_mut("dev-user")
            .unwrap()
            .claimed_millis -= 4 * 24 * 60 * 60 * 1000;
        let proof = crate::owners::tests::prove(
            &mut client,
            7,
            "dev-user",
            &crate::owners::tests::owner_key(5),
            &hash,
        );
        assert_eq!(proof["ok"], true, "{proof}");
        client.request(9, &serde_json::json!({"action": "health"}));
        let (_, health) = client.next_json();
        assert_eq!(
            health["stats"]["v2"]["hidden"],
            "wss://relay.test:8443/hidden-path-123"
        );
        // ...with the certificate's hash, signed by the identity.
        let cert = &health["stats"]["v2"]["tls_cert"];
        let hash = BASE64_STANDARD
            .decode(cert["sha256"].as_str().expect("hash"))
            .expect("base64");
        let message = tls_cert_message(
            cert["host"].as_str().expect("host"),
            cert["expires"].as_u64().expect("expires"),
            &hash,
        );
        assert_eq!(cert["host"], "relay.test");
        assert!(cert["expires"].as_u64().unwrap() > crate::config::now_millis());
        let signature: [u8; 64] = BASE64_STANDARD
            .decode(cert["sig"].as_str().expect("sig"))
            .expect("base64")
            .try_into()
            .expect("64 bytes");
        use ed25519_dalek::Verifier;
        relay
            .state
            .identity
            .signing_key
            .verifying_key()
            .verify(&message, &ed25519_dalek::Signature::from_bytes(&signature))
            .expect("signed by the identity");
        assert_eq!(
            hash,
            sha2::Sha256::digest(
                CertificateDer::pem_file_iter(fixture("cert.pem"))
                    .unwrap()
                    .next()
                    .unwrap()
                    .unwrap()
                    .as_ref()
            )
            .to_vec()
        );
        // An anonymous session gets none of it.
        assert!(anonymous["stats"]["v2"].get("tls_cert").is_none());
        let line = r#"{"action":"health"}"#;
        let v1 =
            crate::v1::handle_request_bytes(line.as_bytes(), line.len(), &relay.state, "127.0.0.1");
        assert!(v1["stats"]["v2"].get("hidden").is_none(), "{v1}");
    }

    #[test]
    fn http_dates_are_what_web_servers_send() {
        assert_eq!(http_date(UNIX_EPOCH), "Thu, 01 Jan 1970 00:00:00 GMT");
        assert_eq!(
            http_date(UNIX_EPOCH + Duration::from_secs(1_793_000_000)),
            "Mon, 26 Oct 2026 07:33:20 GMT"
        );
    }

    #[test]
    fn websocket_frames_are_bounded_and_must_be_masked() {
        let mut buffer = masked(0x2, b"hello");
        assert_eq!(
            take_ws_frame(&mut buffer),
            Ok(Some((0x2, b"hello".to_vec())))
        );
        assert!(buffer.is_empty());
        let mut unmasked = ws_frame(0x2, b"hi");
        assert!(take_ws_frame(&mut unmasked).is_err());
        let mut huge = vec![0x82, 0x80 | 127];
        huge.extend_from_slice(&(u64::MAX).to_be_bytes());
        assert!(take_ws_frame(&mut huge).is_err());
    }
}
