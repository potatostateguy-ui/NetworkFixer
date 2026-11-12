import Foundation
import CoreWLAN

struct NetService {
    let name: String
    let device: String
}

struct WiFiInfo {
    var powerOn: Bool
    var ssid: String?
    var rssi: Int
    var noise: Int
    var txRate: Double
    var channel: Int?
    var band: String?

    var quality: String {
        switch rssi {
        case let r where r >= -55: return "Excellent"
        case let r where r >= -67: return "Good"
        case let r where r >= -75: return "Fair"
        default: return "Poor"
        }
    }
}

struct NetSnapshot {
    var defaultInterface: String?
    var gateway: String?
    var service: NetService?          // primary physical service (e.g. Wi-Fi / Ethernet)
    var allServices: [NetService] = []
    var localIP: String?
    var ipv6: Bool = false
    var effectiveDNS: [String] = []
    var configuredDNS: [String] = []  // empty = automatic (DHCP)
    var wifiDevice: String?
    var wifi: WiFiInfo?
    var connectedVPNs: [String] = []
    var proxies: [String] = []
    var publicIP: String?

    var isWiFi: Bool { service?.device != nil && service?.device == wifiDevice }
    var selfAssigned: Bool { localIP?.hasPrefix("169.254.") ?? false }
    var viaTunnel: Bool {
        guard let i = defaultInterface else { return false }
        return i.hasPrefix("utun") || i.hasPrefix("ppp") || i.hasPrefix("ipsec")
    }
}

enum NetInfo {
    static func services() -> [NetService] {
        let out = Shell.run("/usr/sbin/networksetup", ["-listnetworkserviceorder"]).out
        var result: [NetService] = []
        var pendingName: String?
        for line in out.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("("), let close = t.firstIndex(of: ")"), t.dropFirst().first?.isNumber == true {
                var name = String(t[t.index(after: close)...]).trimmingCharacters(in: .whitespaces)
                if name.hasPrefix("*") { name = "" } // disabled service
                pendingName = name.isEmpty ? nil : name
            } else if t.hasPrefix("(Hardware Port:"), let name = pendingName {
                if let r = t.range(of: "Device: ") {
                    let dev = t[r.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: ") "))
                    if !dev.isEmpty { result.append(NetService(name: name, device: dev)) }
                }
                pendingName = nil
            }
        }
        return result
    }

    static func wifiDevice() -> String? {
        CWWiFiClient.shared().interface()?.interfaceName
    }

    static func ipv4(_ dev: String) -> String? {
        let r = Shell.run("/usr/sbin/ipconfig", ["getifaddr", dev], timeout: 5)
        return r.ok && !r.out.isEmpty ? r.out : nil
    }

    static func defaultRoute() -> (iface: String?, gateway: String?) {
        let out = Shell.run("/sbin/route", ["-n", "get", "default"], timeout: 5).out
        var iface: String?, gw: String?
        for line in out.components(separatedBy: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            if parts[0] == "interface" { iface = parts[1] }
            if parts[0] == "gateway" { gw = parts[1] }
        }
        return (iface, gw)
    }

    static func routerFor(_ dev: String) -> String? {
        let r = Shell.run("/usr/sbin/ipconfig", ["getoption", dev, "router"], timeout: 5)
        return r.ok && !r.out.isEmpty ? r.out : nil
    }

    static func configuredDNS(_ service: String) -> [String] {
        let out = Shell.run("/usr/sbin/networksetup", ["-getdnsservers", service]).out
        if out.contains("aren't any") || out.contains("Error") { return [] }
        return out.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func effectiveDNS() -> [String] {
        let out = Shell.run("/usr/sbin/scutil", ["--dns"], timeout: 5).out
        var servers: [String] = []
        var inFirst = false
        for line in out.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("resolver #1") { inFirst = true; continue }
            if t.hasPrefix("resolver #") || t.hasPrefix("DNS configuration (for scoped") {
                if inFirst { break }
            }
            if inFirst, t.hasPrefix("nameserver["), let r = t.range(of: ": ") {
                servers.append(String(t[r.upperBound...]))
            }
        }
        return servers
    }

    static func wifiInfo(_ dev: String?) -> WiFiInfo? {
        guard let iface = dev.flatMap({ CWWiFiClient.shared().interface(withName: $0) }) ?? CWWiFiClient.shared().interface() else { return nil }
        var band: String?
        switch iface.wlanChannel()?.channelBand {
        case .band2GHz: band = "2.4 GHz"
        case .band5GHz: band = "5 GHz"
        case .band6GHz: band = "6 GHz"
        default: band = nil
        }
        return WiFiInfo(powerOn: iface.powerOn(), ssid: iface.ssid(), rssi: iface.rssiValue(),
                        noise: iface.noiseMeasurement(), txRate: iface.transmitRate(),
                        channel: iface.wlanChannel()?.channelNumber, band: band)
    }

    static func connectedVPNs() -> [String] {
        let out = Shell.run("/usr/sbin/scutil", ["--nc", "list"], timeout: 5).out
        return out.components(separatedBy: "\n").compactMap { line in
            guard line.contains("(Connected)") else { return nil }
            let q = line.components(separatedBy: "\"")
            return q.count >= 2 ? q[1] : nil
        }
    }

    static func proxies() -> [String] {
        let out = Shell.run("/usr/sbin/scutil", ["--proxy"], timeout: 5).out
        var found: [String] = []
        let keys = ["HTTPEnable": "HTTP", "HTTPSEnable": "HTTPS", "SOCKSEnable": "SOCKS",
                    "ProxyAutoConfigEnable": "Auto-config (PAC)", "ProxyAutoDiscoveryEnable": "Auto-discovery (WPAD)"]
        for line in out.components(separatedBy: "\n") {
            let parts = line.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[1] == "1", let label = keys[parts[0]] { found.append(label) }
        }
        return found
    }

    static func publicIP() -> String? {
        let r = Shell.run("/usr/bin/curl", ["-s", "-m", "4", "https://api.ipify.org"], timeout: 6)
        let ip = r.out
        return r.ok && !ip.isEmpty && ip.count < 46 && !ip.contains("<") ? ip : nil
    }

    static func snapshot(includePublicIP: Bool = false) -> NetSnapshot {
        var s = NetSnapshot()
        let route = defaultRoute()
        s.defaultInterface = route.iface
        s.allServices = services()
        s.wifiDevice = wifiDevice()

        // Prefer the service owning the default route; if that's a VPN tunnel (or there's no route),
        // fall back to the first service in priority order that has an address.
        if let iface = route.iface, let svc = s.allServices.first(where: { $0.device == iface }) {
            s.service = svc
            s.gateway = route.gateway
        } else {
            s.service = s.allServices.first(where: { ipv4($0.device) != nil })
                ?? s.allServices.first(where: { $0.device == s.wifiDevice })
            s.gateway = s.service.flatMap { routerFor($0.device) } ?? route.gateway
        }
        if let svc = s.service {
            s.localIP = ipv4(svc.device)
            s.configuredDNS = configuredDNS(svc.name)
            let v6 = Shell.run("/sbin/ifconfig", [svc.device], timeout: 5).out
            s.ipv6 = v6.components(separatedBy: "\n").contains { $0.contains("inet6") && !$0.contains("fe80") }
        }
        s.effectiveDNS = effectiveDNS()
        if s.wifiDevice != nil { s.wifi = wifiInfo(s.wifiDevice) }
        s.connectedVPNs = connectedVPNs()
        s.proxies = proxies()
        if includePublicIP { s.publicIP = publicIP() }
        return s
    }

    static func summary(_ s: NetSnapshot) -> String {
        var lines: [String] = []
        lines.append("Network Fixer report — \(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .medium))")
        lines.append("Host: \(Host.current().localizedName ?? "?")  macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("Connection: \(s.service.map { "\($0.name) (\($0.device))" } ?? "none")")
        if s.isWiFi, let w = s.wifi {
            lines.append("Wi-Fi: \(w.ssid ?? "(name hidden)")  \(w.rssi) dBm \(w.quality), noise \(w.noise) dBm, \(Int(w.txRate)) Mbps, ch \(w.channel.map(String.init) ?? "?") \(w.band ?? "")")
        }
        lines.append("Local IP: \(s.localIP ?? "none")\(s.selfAssigned ? " (self-assigned — DHCP failed)" : "")  IPv6: \(s.ipv6 ? "yes" : "no")")
        lines.append("Gateway: \(s.gateway ?? "none")")
        lines.append("DNS in use: \(s.effectiveDNS.isEmpty ? "none" : s.effectiveDNS.joined(separator: ", "))")
        lines.append("DNS configured: \(s.configuredDNS.isEmpty ? "Automatic (DHCP)" : s.configuredDNS.joined(separator: ", "))")
        lines.append("Public IP: \(s.publicIP ?? "unknown")")
        lines.append("VPN: \(s.connectedVPNs.isEmpty ? (s.viaTunnel ? "tunnel active (\(s.defaultInterface ?? ""))" : "none") : s.connectedVPNs.joined(separator: ", "))")
        lines.append("Proxies: \(s.proxies.isEmpty ? "none" : s.proxies.joined(separator: ", "))")
        return lines.joined(separator: "\n")
    }
}
