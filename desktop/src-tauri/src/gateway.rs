//! The default IPv4 gateway of the PC: the router a new profile starts with.

use std::net::Ipv4Addr;

#[cfg(target_os = "linux")]
pub fn default_gateway() -> Option<Ipv4Addr> {
    parse_proc_route(&std::fs::read_to_string("/proc/net/route").ok()?)
}

#[cfg(windows)]
pub fn default_gateway() -> Option<Ipv4Addr> {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    let out = std::process::Command::new("route")
        .args(["print", "-4", "0.0.0.0"])
        .creation_flags(CREATE_NO_WINDOW)
        .output()
        .ok()?;
    parse_route_print(&String::from_utf8_lossy(&out.stdout))
}

#[cfg(not(any(target_os = "linux", windows)))]
pub fn default_gateway() -> Option<Ipv4Addr> {
    None
}

/// /proc/net/route: Iface Destination Gateway Flags ... Metric; the addresses are the
/// network order bytes printed as a native u32;
/// the default route with the lowest metric
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
fn parse_proc_route(s: &str) -> Option<Ipv4Addr> {
    s.lines()
        .skip(1)
        .filter_map(|l| {
            let f: Vec<&str> = l.split_whitespace().collect();
            if f.len() < 7 || f[1] != "00000000" {
                return None;
            }
            let gw = u32::from_str_radix(f[2], 16).ok().filter(|g| *g != 0)?;
            let metric: u32 = f[6].parse().unwrap_or(u32::MAX);
            Some((metric, Ipv4Addr::from(gw.to_ne_bytes())))
        })
        .min_by_key(|(m, _)| *m)
        .map(|(_, ip)| ip)
}

/// `route print -4 0.0.0.0`: "0.0.0.0  0.0.0.0  <gateway>  <interface>  <metric>"
#[cfg_attr(not(windows), allow(dead_code))]
fn parse_route_print(s: &str) -> Option<Ipv4Addr> {
    s.lines()
        .filter_map(|l| {
            let f: Vec<&str> = l.split_whitespace().collect();
            if f.len() < 5 || f[0] != "0.0.0.0" || f[1] != "0.0.0.0" {
                return None;
            }
            let gw: Ipv4Addr = f[2].parse().ok()?;
            Some((f[4].parse::<u32>().unwrap_or(u32::MAX), gw))
        })
        .min_by_key(|(m, _)| *m)
        .map(|(_, ip)| ip)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn proc_route() {
        let s = "Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT\n\
                 wlan0\t00000000\t0101A8C0\t0003\t0\t0\t600\t00000000\t0\t0\t0\n\
                 eth0\t00000000\t0100000A\t0003\t0\t0\t100\t00000000\t0\t0\t0\n\
                 eth0\t0000000A\t00000000\t0001\t0\t0\t100\t00FFFFFF\t0\t0\t0\n";
        assert_eq!(parse_proc_route(s), Some(Ipv4Addr::new(10, 0, 0, 1)));
        assert_eq!(parse_proc_route("Iface\n"), None);
    }

    #[test]
    fn route_print() {
        let s = "IPv4 Route Table\n===\nActive Routes:\nNetwork Destination        Netmask          Gateway       Interface  Metric\n\
                 \x20         0.0.0.0          0.0.0.0      192.168.1.1    192.168.1.50     25\n";
        assert_eq!(parse_route_print(s), Some(Ipv4Addr::new(192, 168, 1, 1)));
    }
}
