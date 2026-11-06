//! Endpoint DNS diagnosis for failed provider requests.
//!
//! `courierust` resolves through the platform stub resolver, so a poisoned or
//! filtered answer is indistinguishable from a dead server: both surface as a
//! connect timeout. This module compares two answers to the same question —
//! what the device was told, and what the delegation chain actually says — and
//! reports the difference.
//!
//! The walk is best-effort by design. Iterative resolution needs outbound
//! UDP/53 to the root servers, which captive portals and some networks drop, so
//! a failed walk degrades the verdict instead of turning into an accusation.

use std::net::{IpAddr, ToSocketAddrs};
use std::time::{Duration, Instant};

use courierust::courierust_http::uri::Url;
use recurse_x::qtype::RrType;
use recurse_x::rdata::RData;
use recurse_x::{Name, Resolver, ResolverConfig};

/// Upper bound for the whole probe. The connection test already waited for the
/// failing request, so the diagnosis must not multiply that wait.
const PROBE_TIMEOUT: Duration = Duration::from_secs(6);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum DnsVerdict {
    /// The walk resolved the name and the device agrees (or the device had
    /// nothing to compare).
    Resolved,
    /// Only the device resolver answered. Reported as-is: an unverified answer
    /// is not evidence of anything.
    Unverified,
    /// Both answered, both look public, but they share no address. Real for a
    /// broken resolver, also real for a CDN handing different edges to
    /// different resolvers, hence reported as a difference rather than a
    /// hijack.
    Disagreement,
    /// Address space that cannot be the real host: loopback, RFC 1918,
    /// link-local, unique-local. This is what a poisoned response or a local
    /// `hosts` override looks like.
    Suspicious,
    /// `NOERROR` with no address records.
    EmptyAnswer,
    /// `NXDOMAIN`: the name does not exist in the tree we walked.
    NxDomain,
    /// Nothing usable: neither resolver produced an address and the walk did
    /// not complete. Says nothing about the endpoint.
    Inconclusive,
}

#[derive(Debug, Clone)]
pub(crate) struct EndpointDiagnosis {
    pub(crate) host: String,
    pub(crate) device_addresses: Vec<String>,
    pub(crate) walk_addresses: Vec<String>,
    pub(crate) dnssec_validated: bool,
    pub(crate) elapsed_ms: i64,
    pub(crate) verdict: DnsVerdict,
}

impl EndpointDiagnosis {
    /// One line for an error message. Returns `None` when the probe learned
    /// nothing, so callers never blame the network for our own blind spot.
    pub(crate) fn into_hint(self) -> Option<String> {
        let spent = self.elapsed_ms;
        let device = rendered(&self.device_addresses);
        let walk = rendered(&self.walk_addresses);
        let validated = if self.dnssec_validated {
            "，DNSSEC 验证通过"
        } else {
            ""
        };
        Some(match self.verdict {
            DnsVerdict::Resolved => format!(
                "递归解析 {} → {walk}{validated}（{spent}ms），域名解析正常，问题在连接到该地址的链路上",
                self.host
            ),
            DnsVerdict::Unverified => format!(
                "设备解析器把 {} 解析为 {device}（{spent}ms），但独立递归解析未能完成，无法排除本地 DNS 篡改",
                self.host
            ),
            DnsVerdict::Disagreement => format!(
                "{} 的解析结果不一致：设备解析器 {device}，独立递归解析 {walk}（{spent}ms）；可能是 DNS 劫持，也可能是 CDN 就近调度，建议切换网络复测",
                self.host
            ),
            DnsVerdict::Suspicious => format!(
                "{} 被解析到 {device}{}（{spent}ms），这是内网/回环地址，公网域名不应如此，疑似 DNS 劫持或本地 hosts 干预",
                self.host,
                if self.walk_addresses.is_empty() {
                    String::new()
                } else {
                    format!("，独立递归解析为 {walk}")
                }
            ),
            DnsVerdict::EmptyAnswer => format!(
                "独立递归解析 {} 没有地址记录（{spent}ms），域名可能被上游过滤",
                self.host
            ),
            DnsVerdict::NxDomain => format!(
                "独立递归解析 {} 返回 NXDOMAIN（{spent}ms），域名不存在",
                self.host
            ),
            DnsVerdict::Inconclusive => return None,
        })
    }
}

fn rendered(addresses: &[String]) -> String {
    if addresses.is_empty() {
        "无地址".to_string()
    } else {
        addresses.join(", ")
    }
}

/// Whether an answer can only be the product of interference.
fn is_suspicious(address: &IpAddr) -> bool {
    match address {
        IpAddr::V4(v4) => {
            let octets = v4.octets();
            v4.is_private()
                || v4.is_loopback()
                || v4.is_link_local()
                || v4.is_unspecified()
                || v4.is_broadcast()
                || octets[0] == 0
        }
        IpAddr::V6(v6) => {
            v6.is_loopback() || v6.is_unspecified() || (v6.segments()[0] & 0xfe00) == 0xfc00
        }
    }
}

/// Pure classification, so the policy is testable without touching a socket.
///
/// `walk` is `None` when the delegation chain could not be walked at all.
fn classify(device: &[IpAddr], walk: Option<&[IpAddr]>, rcode: u8) -> DnsVerdict {
    let walk = match walk {
        Some(walk) => walk,
        None if device.is_empty() => return DnsVerdict::Inconclusive,
        None => {
            return if device.iter().any(is_suspicious) {
                DnsVerdict::Suspicious
            } else {
                DnsVerdict::Unverified
            }
        }
    };
    if device.iter().chain(walk.iter()).any(is_suspicious) {
        return DnsVerdict::Suspicious;
    }
    if walk.is_empty() {
        return if rcode == 3 {
            DnsVerdict::NxDomain
        } else {
            DnsVerdict::EmptyAnswer
        };
    }
    if !device.is_empty() && !device.iter().any(|address| walk.contains(address)) {
        return DnsVerdict::Disagreement;
    }
    DnsVerdict::Resolved
}

/// Host from a validated provider URL, or `None` when it is already an IP
/// literal (there is nothing to resolve) or the URL is unusable.
fn probe_host(api_url: &str) -> Option<String> {
    let url = Url::parse(api_url.trim()).ok()?;
    let host = url.host.trim_matches(['[', ']']).to_ascii_lowercase();
    if host.is_empty() || host.parse::<IpAddr>().is_ok() {
        return None;
    }
    Some(host)
}

pub(crate) async fn diagnose(api_url: &str) -> Option<EndpointDiagnosis> {
    let host = probe_host(api_url)?;
    let probe = tokio::task::spawn_blocking(move || probe_blocking(&host));
    match tokio::time::timeout(PROBE_TIMEOUT, probe).await {
        Ok(Ok(diagnosis)) => Some(diagnosis),
        // Blocking pool panicked or the probe outlived its budget: both mean
        // "we do not know", and the caller must not claim otherwise.
        _ => None,
    }
}

fn probe_blocking(host: &str) -> EndpointDiagnosis {
    let started = Instant::now();
    let device = device_addresses(host);
    let (walk, rcode, validated, walk_ran) = walk_addresses(host);
    let verdict = classify(&device, walk_ran.then_some(walk.as_slice()), rcode);
    EndpointDiagnosis {
        host: host.to_string(),
        device_addresses: device.iter().map(ToString::to_string).collect(),
        walk_addresses: walk.iter().map(ToString::to_string).collect(),
        dnssec_validated: validated,
        elapsed_ms: i64::try_from(started.elapsed().as_millis()).unwrap_or(i64::MAX),
        verdict,
    }
}

/// What the device was told. This is the path the transport actually uses, so
/// it is the answer that has to be explained, not the one to verify against.
fn device_addresses(host: &str) -> Vec<IpAddr> {
    let mut addresses: Vec<IpAddr> = match (host, 0u16).to_socket_addrs() {
        Ok(iter) => iter.map(|socket| socket.ip()).collect(),
        Err(_) => Vec::new(),
    };
    addresses.sort_unstable();
    addresses.dedup();
    addresses
}

/// What the delegation chain says, plus `(rcode, validated, ran)`.
fn walk_addresses(host: &str) -> (Vec<IpAddr>, u8, bool, bool) {
    let Ok(name) = Name::from_ascii(host) else {
        return (Vec::new(), 0, false, false);
    };
    let resolver = Resolver::new(ResolverConfig::default());
    let mut addresses: Vec<IpAddr> = Vec::new();
    let mut rcode = 0u8;
    let mut validated = true;
    let mut ran = false;

    for rr_type in [RrType::A, RrType::AAAA] {
        match resolver.resolve(&name, rr_type) {
            Ok(resolution) => {
                ran = true;
                rcode = resolution.rcode.to_u8();
                validated &= resolution.validated;
                addresses.extend(resolution.answers.iter().filter_map(|record| {
                    match record.rdata {
                        RData::A(v4) => Some(IpAddr::V4(v4)),
                        RData::Aaaa(v6) => Some(IpAddr::V6(v6)),
                        _ => None,
                    }
                }));
            }
            // One family failing does not invalidate the other; validation is
            // only claimed when every answered family was covered.
            Err(_) => validated = false,
        }
    }
    resolver.shutdown();
    addresses.sort_unstable();
    addresses.dedup();
    (addresses, rcode, validated && ran, ran)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ip(text: &str) -> IpAddr {
        text.parse().unwrap()
    }

    #[test]
    fn matching_public_answers_are_resolved() {
        let device = [ip("120.232.48.61")];
        let walk = [ip("120.232.48.61"), ip("2408:8000::1")];
        assert_eq!(classify(&device, Some(&walk), 0), DnsVerdict::Resolved);
    }

    #[test]
    fn a_walk_without_a_device_answer_still_counts_as_resolved() {
        let walk = [ip("120.232.48.61")];
        assert_eq!(classify(&[], Some(&walk), 0), DnsVerdict::Resolved);
    }

    #[test]
    fn disjoint_public_answers_are_a_disagreement_not_a_verdict() {
        let device = [ip("120.232.48.61")];
        let walk = [ip("120.232.48.62")];
        assert_eq!(
            classify(&device, Some(&walk), 0),
            DnsVerdict::Disagreement
        );
    }

    #[test]
    fn a_private_device_answer_outranks_an_agreeing_walk() {
        let device = [ip("10.0.0.1")];
        let walk = [ip("120.232.48.61")];
        assert_eq!(classify(&device, Some(&walk), 0), DnsVerdict::Suspicious);
    }

    #[test]
    fn loopback_and_private_answers_are_suspicious() {
        for address in ["127.0.0.1", "10.1.2.3", "192.168.1.1", "169.254.1.1", "0.0.0.0"] {
            assert_eq!(
                classify(&[ip(address)], Some(&[]), 0),
                DnsVerdict::Suspicious,
                "{address} should be suspicious"
            );
        }
        for address in ["::1", "fc00::1", "fd12:3456::1", "::"] {
            assert_eq!(
                classify(&[], Some(&[ip(address)]), 0),
                DnsVerdict::Suspicious,
                "{address} should be suspicious"
            );
        }
    }

    #[test]
    fn a_failed_walk_never_turns_into_an_accusation() {
        let device = [ip("120.232.48.61")];
        assert_eq!(classify(&device, None, 0), DnsVerdict::Unverified);
        assert_eq!(classify(&[], None, 0), DnsVerdict::Inconclusive);
        // ...but a private device answer is suspicious with or without a walk.
        assert_eq!(
            classify(&[ip("127.0.0.1")], None, 0),
            DnsVerdict::Suspicious
        );
    }

    #[test]
    fn empty_answers_are_split_by_rcode() {
        assert_eq!(classify(&[], Some(&[]), 3), DnsVerdict::NxDomain);
        assert_eq!(classify(&[], Some(&[]), 0), DnsVerdict::EmptyAnswer);
        assert_eq!(classify(&[], Some(&[]), 2), DnsVerdict::EmptyAnswer);
    }

    #[test]
    fn inconclusive_probes_produce_no_hint() {
        let diagnosis = EndpointDiagnosis {
            host: "open.bigmodel.cn".into(),
            device_addresses: Vec::new(),
            walk_addresses: Vec::new(),
            dnssec_validated: false,
            elapsed_ms: 1,
            verdict: DnsVerdict::Inconclusive,
        };
        assert!(diagnosis.into_hint().is_none());
    }

    #[test]
    fn hijack_hint_names_the_addresses_it_found() {
        let diagnosis = EndpointDiagnosis {
            host: "open.bigmodel.cn".into(),
            device_addresses: vec!["127.0.0.1".into()],
            walk_addresses: Vec::new(),
            dnssec_validated: false,
            elapsed_ms: 4,
            verdict: DnsVerdict::Suspicious,
        };
        let hint = diagnosis.into_hint().unwrap();
        assert!(hint.contains("open.bigmodel.cn"));
        assert!(hint.contains("127.0.0.1"));
        assert!(hint.contains("劫持"));
    }

    #[test]
    fn disagreement_hint_shows_both_sides() {
        let diagnosis = EndpointDiagnosis {
            host: "open.bigmodel.cn".into(),
            device_addresses: vec!["120.232.48.61".into()],
            walk_addresses: vec!["120.232.48.62".into()],
            dnssec_validated: false,
            elapsed_ms: 9,
            verdict: DnsVerdict::Disagreement,
        };
        let hint = diagnosis.into_hint().unwrap();
        assert!(hint.contains("120.232.48.61"));
        assert!(hint.contains("120.232.48.62"));
    }

    #[test]
    fn ip_literals_and_garbage_urls_are_not_probed() {
        assert_eq!(probe_host("http://127.0.0.1:8000/v1/chat"), None);
        assert_eq!(probe_host("http://[::1]:8000/v1/chat"), None);
        assert_eq!(probe_host("not a url"), None);
        assert_eq!(
            probe_host("https://Open.BigModel.CN/api/paas/v4/chat/completions"),
            Some("open.bigmodel.cn".to_string())
        );
    }

    #[test]
    fn the_device_resolver_answers_a_real_name() {
        // Host resolver only, so this works without root-server access.
        let addresses = device_addresses("localhost");
        assert!(
            addresses.contains(&ip("127.0.0.1")) || addresses.contains(&ip("::1")),
            "localhost resolved to {addresses:?}"
        );
    }

    /// Needs outbound UDP/53 to the root servers, so it is opt-in:
    /// `cargo test --lib -- --ignored dns_walk_reaches_the_delegation_chain`
    #[test]
    #[ignore]
    fn dns_walk_reaches_the_delegation_chain() {
        let (addresses, _, validated, ran) = walk_addresses("open.bigmodel.cn");
        println!("walk addresses={addresses:?} validated={validated} ran={ran}");
        assert!(ran, "the delegation walk did not complete on this network");
        assert!(!addresses.is_empty(), "walk returned no address");
    }
}
