//! JSON-lines wire format between the host app and this helper.

use std::io::Write;

use serde::{Deserialize, Serialize};

/// host -> helper (stdin).
#[derive(Debug, PartialEq, Eq, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum HostLine {
    Port {
        index: usize,
        on: bool,
        voltage_mv: u32,
        current_ma: u32,
        power_mw: u32,
    },
    Shutdown,
}

pub fn parse_host_line(line: &str) -> Result<HostLine, serde_json::Error> {
    serde_json::from_str(line)
}

/// helper -> host (stdout).
#[derive(Debug, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Event<'a> {
    Onboarding { qr: &'a str, manual_code: &'a str },
    Fabrics { count: usize },
    Command { index: usize, on: bool },
    Mdns { ok: bool },
    Error { code: &'a str, message: &'a str },
}

/// The only stdout writer: one whole line per event under the stdout lock
/// (reentrant, so the panic hook can still write), then flushed.
pub fn emit(event: &Event) {
    let Ok(mut line) = serde_json::to_string(event) else {
        return;
    };
    line.push('\n');
    let mut out = std::io::stdout().lock();
    // EPIPE means the host is gone; stdin EOF will end us shortly.
    let _ = out.write_all(line.as_bytes()).and_then(|_| out.flush());
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_port_line() {
        let l = r#"{"type":"port","index":0,"on":true,"voltage_mv":20000,"current_ma":1500,"power_mw":30000}"#;
        assert_eq!(
            parse_host_line(l).unwrap(),
            HostLine::Port {
                index: 0,
                on: true,
                voltage_mv: 20000,
                current_ma: 1500,
                power_mw: 30000
            }
        );
    }

    #[test]
    fn parses_shutdown_and_ignores_extra_fields() {
        assert_eq!(
            parse_host_line(r#"{"type":"shutdown"}"#).unwrap(),
            HostLine::Shutdown
        );
        let l = r#"{"type":"port","index":2,"on":false,"voltage_mv":0,"current_ma":0,"power_mw":0,"x":1}"#;
        assert!(matches!(
            parse_host_line(l).unwrap(),
            HostLine::Port {
                index: 2,
                on: false,
                ..
            }
        ));
    }

    #[test]
    fn rejects_malformed_lines() {
        for l in [
            "",
            "garbage",
            r#"{"type":"reboot"}"#,
            r#"{"index":0}"#,
            r#"{"type":"port","index":0,"on":true,"voltage_mv":-1,"current_ma":0,"power_mw":0}"#,
            r#"{"type":"port","index":0,"on":true,"voltage_mv":5000,"current_ma":0}"#,
            r#"{"type":"port","index":0,"on":1,"voltage_mv":0,"current_ma":0,"power_mw":0}"#,
        ] {
            assert!(parse_host_line(l).is_err(), "{l}");
        }
    }

    #[test]
    fn serializes_events() {
        let j = |e: &Event| serde_json::to_string(e).unwrap();
        assert_eq!(
            j(&Event::Onboarding {
                qr: "MT:ABC",
                manual_code: "34970112332"
            }),
            r#"{"type":"onboarding","qr":"MT:ABC","manual_code":"34970112332"}"#
        );
        assert_eq!(
            j(&Event::Fabrics { count: 2 }),
            r#"{"type":"fabrics","count":2}"#
        );
        assert_eq!(
            j(&Event::Command {
                index: 0,
                on: false
            }),
            r#"{"type":"command","index":0,"on":false}"#
        );
        assert_eq!(
            j(&Event::Mdns { ok: false }),
            r#"{"type":"mdns","ok":false}"#
        );
        assert_eq!(
            j(&Event::Error {
                code: "storage",
                message: "a \"b\"\nc"
            }),
            r#"{"type":"error","code":"storage","message":"a \"b\"\nc"}"#
        );
    }
}
