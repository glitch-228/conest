//! The HTTP form of protocol v1: GET for health, POST with a v1 request.

use std::io::{BufRead, Write};

use serde_json::Value;

use crate::limits::forwarded_peer;
use crate::storage::RelayState;
use crate::v1::{
    RelayRequest, RelayResponse, handle_request, handle_request_async, handle_request_bytes,
    to_wire,
};

pub(crate) fn read_line_bounded<R: BufRead>(
    reader: &mut R,
    output: &mut String,
    max_bytes: usize,
) -> std::io::Result<usize> {
    let mut bytes = Vec::with_capacity(max_bytes.min(8 * 1024));
    loop {
        let available = reader.fill_buf()?;
        if available.is_empty() {
            break;
        }
        let take = available
            .iter()
            .position(|byte| *byte == b'\n')
            .map_or(available.len(), |index| index + 1);
        if bytes.len().saturating_add(take) > max_bytes {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "request line too large",
            ));
        }
        bytes.extend_from_slice(&available[..take]);
        reader.consume(take);
        if bytes.last() == Some(&b'\n') {
            break;
        }
    }
    let text = std::str::from_utf8(&bytes).map_err(|error| {
        std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!("request line is not utf-8: {error}"),
        )
    })?;
    output.push_str(text);
    Ok(bytes.len())
}

pub(crate) fn is_http_request_line(line: &str) -> bool {
    line.starts_with("GET ") || line.starts_with("POST ") || line.starts_with("OPTIONS ")
}

/// What an HTTP request asks for, once its headers (and body) are read.
pub(crate) enum HttpWork {
    /// Answered already (an error, or a refusal).
    Respond(u16, Value),
    /// GET or OPTIONS: the relay's health.
    Health,
    /// POST: a v1 request in the body.
    Post { body: Vec<u8> },
}

/// One HTTP request from [peer] (or the address a trusted proxy names),
/// answered as v1 does.
pub(crate) fn handle_http_request<R: BufRead>(
    request_line: &str,
    reader: &mut R,
    state: &RelayState,
    peer: &str,
) -> (u16, Value) {
    let (work, effective_peer) = parse_http_request(request_line, reader, state, peer);
    match work {
        HttpWork::Respond(status, value) => (status, value),
        HttpWork::Health => (200, to_wire(handle_request(RelayRequest::Health, state))),
        HttpWork::Post { body } => (
            200,
            handle_request_bytes(&body, body.len(), state, &effective_peer),
        ),
    }
}

/// [handle_http_request] for the tokio server; [reader] holds the whole
/// request already.
pub(crate) async fn handle_http_request_async<R: BufRead>(
    request_line: &str,
    reader: &mut R,
    state: &RelayState,
    peer: &str,
) -> (u16, Value) {
    let (work, effective_peer) = parse_http_request(request_line, reader, state, peer);
    match work {
        HttpWork::Respond(status, value) => (status, value),
        HttpWork::Health => {
            let response = state
                .blocking(|state| handle_request(RelayRequest::Health, state))
                .await
                .unwrap_or_else(|error| RelayResponse::error(error));
            (200, to_wire(response))
        }
        HttpWork::Post { body } => (
            200,
            handle_request_async(&body, body.len(), state, &effective_peer).await,
        ),
    }
}

/// Reads an HTTP request's headers and body and applies the general
/// budget; returns the work and the address it counts to.
pub(crate) fn parse_http_request<R: BufRead>(
    request_line: &str,
    reader: &mut R,
    state: &RelayState,
    peer: &str,
) -> (HttpWork, String) {
    let (status, value) = match parse_http_inner(request_line, reader, state, peer) {
        Ok(work) => return work,
        Err(answer) => answer,
    };
    (HttpWork::Respond(status, value), peer.to_owned())
}

fn parse_http_inner<R: BufRead>(
    request_line: &str,
    reader: &mut R,
    state: &RelayState,
    peer: &str,
) -> Result<(HttpWork, String), (u16, Value)> {
    let mut parts = request_line.split_whitespace();
    let method = parts.next().unwrap_or_default();
    let path = parts.next().unwrap_or("/");
    let path_without_query = match path.split_once('?') {
        Some((head, _)) => head,
        None => path,
    };
    if path_without_query != "/"
        && path_without_query != "/health"
        && path_without_query != "/relay"
    {
        return Err((
            404,
            to_wire(RelayResponse::error("unknown HTTP relay path")),
        ));
    }

    let mut headers = Vec::new();
    let mut content_length: Option<usize> = None;
    let mut forwarded_for: Option<String> = None;
    let mut header_count = 0_usize;
    loop {
        let mut line = String::new();
        let remaining = state.config.max_line_bytes.saturating_sub(headers.len());
        match read_line_bounded(reader, &mut line, remaining) {
            Ok(0) => {
                return Err((
                    400,
                    to_wire(RelayResponse::error("incomplete HTTP headers")),
                ));
            }
            Ok(_) => {
                if line == "\r\n" || line == "\n" {
                    break;
                }
                if headers.len() + line.len() > state.config.max_line_bytes {
                    return Err((413, to_wire(RelayResponse::error("HTTP headers too large"))));
                }
                header_count += 1;
                if header_count > 100 {
                    return Err((413, to_wire(RelayResponse::error("too many HTTP headers"))));
                }
                if let Some((name, value)) = line.split_once(':') {
                    let name = name.trim();
                    if name.eq_ignore_ascii_case("content-length") {
                        let parsed = match value.trim().parse::<usize>() {
                            Ok(value) => value,
                            Err(_) => {
                                return Err((
                                    400,
                                    to_wire(RelayResponse::error("invalid Content-Length")),
                                ));
                            }
                        };
                        if content_length.is_some_and(|existing| existing != parsed) {
                            return Err((
                                400,
                                to_wire(RelayResponse::error("conflicting Content-Length")),
                            ));
                        }
                        content_length = Some(parsed);
                    } else if state.config.trust_forwarded_for
                        && name.eq_ignore_ascii_case("x-forwarded-for")
                    {
                        // The last address of the last line: the one the
                        // trusted proxy saw (it appends a line or an entry).
                        // Earlier ones come from the client.
                        if let Some(peer) = forwarded_peer(value) {
                            forwarded_for = Some(peer);
                        }
                    }
                }
                headers.extend_from_slice(line.as_bytes());
            }
            Err(error) => {
                let status = if error.kind() == std::io::ErrorKind::InvalidData {
                    413
                } else {
                    400
                };
                return Err((
                    status,
                    to_wire(RelayResponse::error(format!(
                        "HTTP header read failed: {error}"
                    ))),
                ));
            }
        }
    }

    let effective_peer = forwarded_for.as_deref().unwrap_or(peer);

    match method {
        "GET" | "OPTIONS" => {
            if !state.allow_request(effective_peer) {
                return Err((429, to_wire(RelayResponse::error("rate limit exceeded"))));
            }
            Ok((HttpWork::Health, effective_peer.to_owned()))
        }
        "POST" => {
            let content_length = content_length.unwrap_or(0);
            if content_length == 0 {
                return Err((
                    400,
                    to_wire(RelayResponse::error("HTTP relay POST body is empty")),
                ));
            }
            if content_length > state.config.max_line_bytes {
                return Err((
                    413,
                    to_wire(RelayResponse::error("HTTP relay POST body too large")),
                ));
            }
            let mut body = vec![0_u8; content_length];
            if let Err(error) = reader.read_exact(&mut body) {
                return Err((
                    400,
                    to_wire(RelayResponse::error(format!(
                        "HTTP body read failed: {error}"
                    ))),
                ));
            }
            Ok((HttpWork::Post { body }, effective_peer.to_owned()))
        }
        _ => Err((
            405,
            to_wire(RelayResponse::error("unsupported HTTP method")),
        )),
    }
}

pub(crate) fn write_http_response<W: Write>(
    writer: &mut W,
    status: u16,
    response: &Value,
) -> std::io::Result<()> {
    let body = serde_json::to_vec(response)?;
    let status_text = match status {
        200 => "OK",
        400 => "Bad Request",
        404 => "Not Found",
        405 => "Method Not Allowed",
        413 => "Payload Too Large",
        _ => "Relay Response",
    };
    write!(
        writer,
        "HTTP/1.1 {status} {status_text}\r\n\
         Content-Type: application/json\r\n\
         Content-Length: {}\r\n\
         Cache-Control: no-store\r\n\
         Access-Control-Allow-Origin: *\r\n\
         Access-Control-Allow-Headers: content-type\r\n\
         Connection: close\r\n\
         \r\n",
        body.len()
    )?;
    writer.write_all(&body)
}
