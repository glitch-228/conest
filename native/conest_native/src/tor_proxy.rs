//! A local entrance to Tor for this app's own web requests (link
//! previews): an HTTP CONNECT proxy on 127.0.0.1 that tunnels to the
//! requested host through Arti, so the site sees a Tor exit and this
//! device makes no DNS lookup of its own.
//!
//! Only this app may use it: every request must carry the user name and
//! password Dart chose (`Proxy-Authorization: Basic`). Only CONNECT, only
//! to the usual web ports, never to a private or local address; a bounded
//! number of tunnels, each with a time limit.

use std::{
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
    sync::Arc,
    time::Duration,
};

use anyhow::{Result, anyhow, bail};
use arti_client::TorClient;
use base64::Engine;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt, copy_bidirectional},
    net::{TcpListener, TcpStream},
    sync::Semaphore,
    task::JoinHandle,
    time::timeout,
};
use tor_rtcompat::PreferredRuntime;

/// Ports a tunnel may go to.
pub const WEB_PORTS: [u16; 4] = [80, 443, 8080, 8443];

/// Tunnels at a time.
const MAX_TUNNELS: usize = 8;

/// Time to send the request head; to reach the site through Tor; for a
/// whole tunnel.
const HEAD: Duration = Duration::from_secs(10);
const CONNECT: Duration = Duration::from_secs(30);
const TUNNEL: Duration = Duration::from_secs(60);

/// Largest request head read.
const MAX_HEAD: usize = 8 * 1024;

/// A running proxy: its port, and the task serving it.
pub struct WebProxy {
    pub port: u16,
    pub task: JoinHandle<()>,
}

/// Starts the proxy on 127.0.0.1 (a free port) for [client], answering
/// only requests with [user] and [password].
pub async fn start(
    client: Arc<TorClient<PreferredRuntime>>,
    user: String,
    password: String,
) -> Result<WebProxy> {
    if user.len() < 16 || password.len() < 16 {
        bail!("proxy credentials too short");
    }
    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await?;
    let port = listener.local_addr()?.port();
    let expected = format!(
        "Basic {}",
        base64::engine::general_purpose::STANDARD.encode(format!("{user}:{password}"))
    );
    let expected = Arc::new(expected);
    let slots = Arc::new(Semaphore::new(MAX_TUNNELS));
    let task = tokio::spawn(async move {
        loop {
            let Ok((stream, _)) = listener.accept().await else {
                continue;
            };
            let Ok(slot) = slots.clone().try_acquire_owned() else {
                // Busy: closed at once rather than queued.
                drop(stream);
                continue;
            };
            let client = client.clone();
            let expected = expected.clone();
            tokio::spawn(async move {
                let _ = serve(stream, &client, &expected).await;
                drop(slot);
            });
        }
    });
    Ok(WebProxy { port, task })
}

async fn serve(
    mut local: TcpStream,
    client: &TorClient<PreferredRuntime>,
    expected_auth: &str,
) -> Result<()> {
    let head = match timeout(HEAD, read_head(&mut local)).await {
        Ok(Ok(head)) => head,
        _ => {
            let _ = local
                .write_all(b"HTTP/1.1 408 Request Timeout\r\n\r\n")
                .await;
            return Ok(());
        }
    };
    let request = match parse_request(&head, expected_auth) {
        Ok(request) => request,
        Err(refusal) => {
            let _ = local.write_all(refusal.response().as_bytes()).await;
            return Ok(());
        }
    };
    let remote = match timeout(
        CONNECT,
        client.connect((request.host.as_str(), request.port)),
    )
    .await
    {
        Ok(Ok(remote)) => remote,
        _ => {
            let _ = local.write_all(b"HTTP/1.1 502 Bad Gateway\r\n\r\n").await;
            return Ok(());
        }
    };
    local
        .write_all(b"HTTP/1.1 200 Connection established\r\n\r\n")
        .await?;
    let mut remote = remote;
    let _ = timeout(TUNNEL, copy_bidirectional(&mut local, &mut remote)).await;
    Ok(())
}

/// The request head, up to and including the blank line.
async fn read_head(stream: &mut TcpStream) -> Result<Vec<u8>> {
    let mut head = Vec::with_capacity(512);
    let mut byte = [0u8; 1];
    while !head.ends_with(b"\r\n\r\n") {
        if head.len() >= MAX_HEAD {
            bail!("request head too long");
        }
        if stream.read(&mut byte).await? == 0 {
            bail!("closed before the request ended");
        }
        head.push(byte[0]);
    }
    Ok(head)
}

/// Where a tunnel goes.
#[derive(Debug, PartialEq, Eq)]
pub struct Tunnel {
    pub host: String,
    pub port: u16,
}

/// Why a request is refused.
#[derive(Debug, PartialEq, Eq)]
pub enum Refusal {
    BadRequest,
    NotAllowed,
    Unauthorized,
}

impl Refusal {
    fn response(&self) -> &'static str {
        match self {
            Refusal::BadRequest => "HTTP/1.1 400 Bad Request\r\n\r\n",
            Refusal::NotAllowed => "HTTP/1.1 403 Forbidden\r\n\r\n",
            Refusal::Unauthorized => {
                "HTTP/1.1 407 Proxy Authentication Required\r\n\
                 Proxy-Authenticate: Basic realm=\"conest\"\r\n\r\n"
            }
        }
    }
}

/// A CONNECT request with the right credentials to a web port of a public
/// host, or why not.
pub fn parse_request(head: &[u8], expected_auth: &str) -> Result<Tunnel, Refusal> {
    let text = std::str::from_utf8(head).map_err(|_| Refusal::BadRequest)?;
    let mut lines = text.split("\r\n");
    let first = lines.next().ok_or(Refusal::BadRequest)?;
    let mut parts = first.split(' ');
    let (Some(method), Some(target), Some(version), None) =
        (parts.next(), parts.next(), parts.next(), parts.next())
    else {
        return Err(Refusal::BadRequest);
    };
    if !version.starts_with("HTTP/1.") {
        return Err(Refusal::BadRequest);
    }
    let mut authorized = false;
    for line in lines {
        if let Some((name, value)) = line.split_once(':')
            && name.trim().eq_ignore_ascii_case("proxy-authorization")
        {
            authorized = constant_time_eq(value.trim().as_bytes(), expected_auth.as_bytes());
        }
    }
    if !authorized {
        return Err(Refusal::Unauthorized);
    }
    if method != "CONNECT" {
        return Err(Refusal::NotAllowed);
    }
    let tunnel = parse_target(target).map_err(|_| Refusal::BadRequest)?;
    if !WEB_PORTS.contains(&tunnel.port) {
        return Err(Refusal::NotAllowed);
    }
    if let Ok(address) = tunnel.host.trim_matches(['[', ']']).parse::<IpAddr>()
        && !is_public(address)
    {
        return Err(Refusal::NotAllowed);
    }
    Ok(tunnel)
}

/// `host:port` or `[v6]:port`.
fn parse_target(target: &str) -> Result<Tunnel> {
    let (host, port) = if let Some(rest) = target.strip_prefix('[') {
        let (host, port) = rest.split_once("]:").ok_or_else(|| anyhow!("bad target"))?;
        (host, port)
    } else {
        target
            .rsplit_once(':')
            .ok_or_else(|| anyhow!("bad target"))?
    };
    let port: u16 = port.parse()?;
    if host.is_empty()
        || host.len() > 253
        || !host
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | ':'))
    {
        bail!("bad host");
    }
    Ok(Tunnel {
        host: host.to_ascii_lowercase(),
        port,
    })
}

fn is_public(address: IpAddr) -> bool {
    match address {
        IpAddr::V4(v4) => public_v4(v4),
        IpAddr::V6(v6) => {
            if let Some(v4) = v6.to_ipv4_mapped() {
                return public_v4(v4);
            }
            let first = v6.segments()[0];
            !(v6.is_loopback()
                || v6.is_unspecified()
                || v6.is_multicast()
                || first & 0xfe00 == 0xfc00
                || first & 0xffc0 == 0xfe80)
                && first & 0xe000 == 0x2000
                && v6 != Ipv6Addr::UNSPECIFIED
        }
    }
}

fn public_v4(v4: Ipv4Addr) -> bool {
    let [a, b, ..] = v4.octets();
    !(v4.is_private()
        || v4.is_loopback()
        || v4.is_link_local()
        || v4.is_unspecified()
        || v4.is_broadcast()
        || v4.is_multicast()
        || v4.is_documentation()
        || a == 0
        || (a == 100 && (64..=127).contains(&b))
        || a >= 240)
}

fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    const AUTH: &str = "Basic dXNlcnVzZXJ1c2VydXNlcjpwYXNzcGFzc3Bhc3NwYXNz";

    fn head(lines: &[&str]) -> Vec<u8> {
        let mut text = lines.join("\r\n");
        text.push_str("\r\n\r\n");
        text.into_bytes()
    }

    #[test]
    fn a_connect_with_the_right_credentials_tunnels() {
        let request = head(&[
            "CONNECT site.example:443 HTTP/1.1",
            "Host: site.example:443",
            &format!("Proxy-Authorization: {AUTH}"),
        ]);
        assert_eq!(
            parse_request(&request, AUTH),
            Ok(Tunnel {
                host: "site.example".into(),
                port: 443
            })
        );
    }

    #[test]
    fn wrong_or_missing_credentials_are_refused() {
        let missing = head(&["CONNECT site.example:443 HTTP/1.1"]);
        assert_eq!(parse_request(&missing, AUTH), Err(Refusal::Unauthorized));
        let wrong = head(&[
            "CONNECT site.example:443 HTTP/1.1",
            "Proxy-Authorization: Basic d3Jvbmc6d3Jvbmc=",
        ]);
        assert_eq!(parse_request(&wrong, AUTH), Err(Refusal::Unauthorized));
    }

    #[test]
    fn only_connect_to_web_ports_of_public_hosts() {
        let with_auth = |line: &str| head(&[line, &format!("Proxy-Authorization: {AUTH}")]);
        assert_eq!(
            parse_request(&with_auth("GET http://site.example/ HTTP/1.1"), AUTH),
            Err(Refusal::NotAllowed)
        );
        assert_eq!(
            parse_request(&with_auth("CONNECT site.example:22 HTTP/1.1"), AUTH),
            Err(Refusal::NotAllowed)
        );
        for private in [
            "127.0.0.1:443",
            "10.1.2.3:443",
            "192.168.1.1:80",
            "[::1]:443",
            "[fd00::1]:443",
            "100.64.0.1:443",
        ] {
            assert_eq!(
                parse_request(&with_auth(&format!("CONNECT {private} HTTP/1.1")), AUTH),
                Err(Refusal::NotAllowed),
                "{private}"
            );
        }
        assert!(parse_request(&with_auth("CONNECT 8.8.8.8:443 HTTP/1.1"), AUTH).is_ok());
        assert_eq!(
            parse_request(&with_auth("CONNECT bad host:443 HTTP/1.1"), AUTH),
            Err(Refusal::BadRequest)
        );
    }
}
