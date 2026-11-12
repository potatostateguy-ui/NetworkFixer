import Foundation
import CoreWLAN

enum Connectivity: Equatable {
    case online
    case captive(URL?)
    case dnsFailure
    case offline
    case unknown
}

struct DNSPreset {
    let name: String
    let servers: [String]
}

let dnsPresets: [DNSPreset] = [
    DNSPreset(name: "Cloudflare", servers: ["1.1.1.1", "1.0.0.1"]),
    DNSPreset(name: "Google", servers: ["8.8.8.8", "8.8.4.4"]),
    DNSPreset(name: "Cloudflare + Google", servers: ["1.1.1.1", "8.8.8.8"]),
    DNSPreset(name: "Quad9 (malware blocking)", servers: ["9.9.9.9", "149.112.112.112"]),
    DNSPreset(name: "OpenDNS", servers: ["208.67.222.222", "208.67.220.220"]),
    DNSPreset(name: "Cloudflare Family (blocks malware + adult)", servers: ["1.1.1.3", "1.0.0.3"]),
]

// MARK: - Low-level probes

private final class RedirectCatcher: NSObject, URLSessionTaskDelegate {
    var location: URL?
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        location = request.url
        completionHandler(nil)
    }
}

struct HTTPResult {
    var status: Int?
    var body: String = ""
    var redirect: URL?
    var error: URLError?
    var elapsed: TimeInterval = 0
}

struct PingResult {
    var sent = 0
    var received = 0
    var avg: Double?
    var loss: Double { sent == 0 ? 100 : Double(sent - received) / Double(sent) * 100 }
    var ok: Bool { received > 0 }
}

struct DigResult {
    var ok: Bool
    var ms: Int?
}

enum Probe {
    static func http(_ urlString: String, timeout: TimeInterval = 6) -> HTTPResult {
        guard let url = URL(string: urlString) else { return HTTPResult() }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout
        cfg.waitsForConnectivity = false
        let catcher = RedirectCatcher()
        let session = URLSession(configuration: cfg, delegate: catcher, delegateQueue: nil)
        var result = HTTPResult()
        let sem = DispatchSemaphore(value: 0)
        let start = Date()
        session.dataTask(with: url) { data, resp, err in
            result.status = (resp as? HTTPURLResponse)?.statusCode
            result.body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            result.error = err as? URLError
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 2)
        result.elapsed = Date().timeIntervalSince(start)
        result.redirect = catcher.location
        session.invalidateAndCancel()
        return result
    }

    /// Fast connectivity classification used by the background monitor and the fixer.
    static func connectivity(timeout: TimeInterval = 6) -> Connectivity {
        let apple = http("http://captive.apple.com/hotspot-detect.html", timeout: timeout)
        if let r = apple.redirect { return .captive(r) }
        if apple.status == 200 {
            return apple.body.contains("Success") ? .online : .captive(nil)
        }
        if apple.status != nil { return .captive(nil) }

        // Second opinion from Google before declaring anything
        let g = http("http://connectivitycheck.gstatic.com/generate_204", timeout: timeout)
        if g.status == 204 { return .online }
        if let r = g.redirect { return .captive(r) }
        if g.status != nil { return .captive(nil) }

        // Names didn't resolve or connect — can we reach the internet by raw IP?
        let ip = http("http://1.1.1.1/", timeout: 4)
        if let r = ip.redirect, let host = r.host, host != "1.1.1.1", !host.contains("one.one.one.one") { return .captive(r) }
        if ip.status != nil || ip.redirect != nil { return .dnsFailure }
        return .offline
    }

    static func ping(_ host: String, count: Int = 3, interval: Double = 0.3) -> PingResult {
        let r = Shell.run("/sbin/ping", ["-c", "\(count)", "-i", "\(interval)", "-t", "\(Int(Double(count) * interval) + 3)", "-W", "1500", host],
                          timeout: Double(count) * interval + 6)
        var p = PingResult()
        for line in r.out.components(separatedBy: "\n") {
            if line.contains("packets transmitted") {
                let nums = line.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap { Int($0) }
                if nums.count >= 2 { p.sent = nums[0]; p.received = nums[1] }
            }
            if line.contains("round-trip"), let eq = line.range(of: "= ") {
                let vals = line[eq.upperBound...].split(separator: "/")
                if vals.count >= 2 { p.avg = Double(vals[1]) }
            }
        }
        return p
    }

    static func dig(_ server: String, _ domain: String = "www.apple.com") -> DigResult {
        let r = Shell.run("/usr/bin/dig", ["@\(server)", domain, "A", "+time=2", "+tries=1"], timeout: 5)
        let ok = r.out.contains("status: NOERROR") && r.out.contains("ANSWER SECTION")
        var ms: Int?
        if let line = r.out.components(separatedBy: "\n").first(where: { $0.contains("Query time:") }) {
            ms = line.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap { Int($0) }.first
        }
        return DigResult(ok: ok, ms: ms)
    }

    /// Resolves through the macOS system resolver (what apps actually use).
    static func systemResolves(_ host: String = "www.apple.com", timeout: TimeInterval = 5) -> Bool {
        var ok = false
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            var res: UnsafeMutablePointer<addrinfo>?
            ok = getaddrinfo(host, nil, &hints, &res) == 0
            if res != nil { freeaddrinfo(res) }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + timeout)
        return ok
    }
}

// MARK: - Fixes

enum Fixes {
    static let prefs = UserDefaults.standard

    @discardableResult
    static func flushDNS(interactive: Bool = true) -> CmdResult {
        Shell.runPrivileged([["/usr/bin/dscacheutil", "-flushcache"], ["/usr/bin/killall", "-HUP", "mDNSResponder"]], interactive: interactive)
    }

    @discardableResult
    static func renewDHCP(_ device: String, interactive: Bool = true) -> CmdResult {
        Shell.runPrivileged([["/usr/sbin/ipconfig", "set", device, "DHCP"]], interactive: interactive)
    }

    /// Sets DNS on the given services (empty servers = automatic/DHCP) and flushes the cache, in one admin prompt.
    @discardableResult
    static func setDNS(_ servers: [String], services: [String], interactive: Bool = true, rememberPrevious: Bool = true) -> CmdResult {
        if rememberPrevious, let first = services.first {
            let current = NetInfo.configuredDNS(first)
            if current != servers { prefs.set(current, forKey: "previousDNS") }
        }
        var cmds: [[String]] = services.map { ["/usr/sbin/networksetup", "-setdnsservers", $0] + (servers.isEmpty ? ["Empty"] : servers) }
        cmds.append(["/usr/bin/dscacheutil", "-flushcache"])
        cmds.append(["/usr/bin/killall", "-HUP", "mDNSResponder"])
        return Shell.runPrivileged(cmds, interactive: interactive)
    }

    static var previousDNS: [String]? { prefs.stringArray(forKey: "previousDNS") }

    static func setWiFiPower(_ on: Bool) -> Bool {
        guard let iface = CWWiFiClient.shared().interface() else { return false }
        do { try iface.setPower(on); return true } catch {
            if let dev = iface.interfaceName {
                return Shell.run("/usr/sbin/networksetup", ["-setairportpower", dev, on ? "on" : "off"]).ok
            }
            return false
        }
    }

    /// Turns Wi-Fi off and on, then waits (up to `wait` seconds) for an IP address.
    static func cycleWiFi(wait: TimeInterval = 20) -> Bool {
        guard setWiFiPower(false) else { return false }
        sleep(3)
        guard setWiFiPower(true) else { return false }
        return waitForIP(NetInfo.wifiDevice(), wait: wait)
    }

    static func waitForIP(_ device: String?, wait: TimeInterval) -> Bool {
        guard let device else { return false }
        let deadline = Date().addingTimeInterval(wait)
        while Date() < deadline {
            if let ip = NetInfo.ipv4(device), !ip.hasPrefix("169.254.") { return true }
            sleep(1)
        }
        return false
    }

    static func disconnectVPNs() -> [String] {
        let vpns = NetInfo.connectedVPNs()
        for v in vpns { Shell.run("/usr/sbin/scutil", ["--nc", "stop", v]) }
        return vpns
    }

    static func fullReset(_ device: String, interactive: Bool = true) -> CmdResult {
        Shell.runPrivileged([
            ["/usr/bin/dscacheutil", "-flushcache"],
            ["/usr/bin/killall", "-HUP", "mDNSResponder"],
            ["/usr/sbin/arp", "-a", "-d"],
            ["/usr/sbin/ipconfig", "set", device, "DHCP"],
        ], interactive: interactive)
    }
}

// MARK: - Diagnose & auto-fix

typealias Logger = (String) -> Void

enum Engine {
    static func describe(_ c: Connectivity) -> String {
        switch c {
        case .online: return "Online"
        case .captive: return "Captive portal (login required)"
        case .dnsFailure: return "DNS not working"
        case .offline: return "No internet"
        case .unknown: return "Checking…"
        }
    }

    /// Hardware services we should apply DNS to.
    static func dnsTargets(_ s: NetSnapshot) -> [String] {
        if UserDefaults.standard.object(forKey: "dnsAllServices") == nil || UserDefaults.standard.bool(forKey: "dnsAllServices") {
            let names = s.allServices.map(\.name)
            if !names.isEmpty { return names }
        }
        return s.service.map { [$0.name] } ?? []
    }

    // MARK: Full diagnostics report

    static func diagnose(log: Logger) {
        log("Gathering network information…\n")
        let s = NetInfo.snapshot(includePublicIP: true)
        log(NetInfo.summary(s))
        log("\n— Tests —")
        var advice: [String] = []

        // Link + address
        if s.service == nil {
            log("❌ No active network connection (Wi-Fi off or cable unplugged)")
            if let w = s.wifi, !w.powerOn { advice.append("Wi-Fi is turned off — use Quick Fixes ▸ Turn Wi-Fi Off & On, or Fix My Connection.") }
        } else if s.localIP == nil {
            log("❌ No IP address on \(s.service!.name)")
            advice.append("No IP address — try Renew DHCP Lease, or reconnect to the network.")
        } else if s.selfAssigned {
            log("❌ Self-assigned IP \(s.localIP!) — the router's DHCP didn't answer")
            advice.append("Router didn't hand out an address — Renew DHCP Lease, then restart the router if it persists.")
        } else {
            log("✅ IP address \(s.localIP!)")
        }

        // Wi-Fi signal
        if s.isWiFi, let w = s.wifi {
            let snr = w.rssi - w.noise
            let mark = w.rssi >= -67 ? "✅" : (w.rssi >= -75 ? "⚠️" : "❌")
            log("\(mark) Wi-Fi signal \(w.rssi) dBm (\(w.quality)), SNR \(snr) dB, link \(Int(w.txRate)) Mbps\(w.band.map { ", \($0)" } ?? "")")
            if w.rssi < -72 { advice.append("Weak Wi-Fi signal — move closer to the access point or use 5 GHz/Ethernet.") }
            if snr < 20 { advice.append("High interference (low SNR) — try a different channel/band on the router.") }
        }

        // Gateway
        var gwOK = false
        if let gw = s.gateway {
            let p = Probe.ping(gw, count: 5, interval: 0.2)
            gwOK = p.ok
            if p.ok {
                log("\(p.loss > 0 ? "⚠️" : "✅") Router \(gw): \(fmt(p.avg)) ms, \(Int(p.loss))% loss")
                if p.loss >= 20 { advice.append("Packet loss to your router — local Wi-Fi/cable problem.") }
            } else {
                log("❌ Router \(gw) is not responding to ping (some routers block ping)")
            }
        } else {
            log("❌ No default gateway / router")
        }

        // Internet by IP
        let inet = Probe.ping("1.1.1.1", count: 10, interval: 0.2)
        if inet.ok {
            log("\(inet.loss > 0 ? "⚠️" : "✅") Internet (1.1.1.1): \(fmt(inet.avg)) ms, \(Int(inet.loss))% loss")
            if (inet.avg ?? 0) > 150 { advice.append("High latency to the internet (\(fmt(inet.avg)) ms) — network is congested or the ISP is having issues.") }
            if inet.loss >= 10 { advice.append("Packet loss to the internet — expect choppy calls. Restart the router/modem; contact ISP if it continues.") }
        } else {
            log("❌ Cannot reach the internet by IP (1.1.1.1)")
            if gwOK { advice.append("Router is reachable but the internet isn't — the modem/ISP is down, or a captive portal is blocking traffic.") }
        }

        // DNS
        let sysDNS = Probe.systemResolves()
        log("\(sysDNS ? "✅" : "❌") System DNS lookup (www.apple.com)")
        for server in s.effectiveDNS.prefix(3) {
            let d = Probe.dig(server)
            log("   \(d.ok ? "✅" : "❌") DNS server \(server)\(d.ms.map { " — \($0) ms" } ?? "")")
        }
        let pub = Probe.dig("1.1.1.1")
        log("   \(pub.ok ? "✅" : "❌") Public DNS 1.1.1.1\(pub.ms.map { " — \($0) ms" } ?? "")")
        if !sysDNS && pub.ok { advice.append("Your DNS servers are failing but public DNS works — switch DNS to Cloudflare/Google (Fix My Connection will do this).") }

        // Captive / HTTP
        let c = Probe.connectivity()
        switch c {
        case .online: log("✅ No captive portal; internet check passed")
        case .captive(let url):
            log("⚠️ Captive portal detected\(url.map { " → \($0.absoluteString)" } ?? "")")
            advice.append("Login page required — use Captive Portal ▸ Open Login Page (or Portal Mode if you use custom DNS).")
        case .dnsFailure: log("❌ Websites unreachable by name — DNS failure")
        case .offline, .unknown: log("❌ Internet connectivity check failed")
        }
        let https = Shell.run("/usr/bin/curl", ["-s", "-o", "/dev/null", "-m", "8", "-w", "%{http_code} %{time_total}", "https://www.google.com/generate_204"], timeout: 10)
        let parts = https.out.split(separator: " ")
        if parts.first == "204", parts.count == 2, let t = Double(parts[1]) {
            log("✅ HTTPS to google.com in \(Int(t * 1000)) ms")
        } else {
            log("❌ HTTPS to google.com failed")
        }

        // Environment
        if !s.connectedVPNs.isEmpty || s.viaTunnel {
            log("ℹ️ VPN active: \(s.connectedVPNs.isEmpty ? s.defaultInterface ?? "tunnel" : s.connectedVPNs.joined(separator: ", "))")
            if c != .online { advice.append("A VPN is connected — disconnect it to rule it out (Quick Fixes ▸ Disconnect VPNs).") }
        }
        if !s.proxies.isEmpty {
            log("ℹ️ Proxy enabled: \(s.proxies.joined(separator: ", "))")
            if c != .online { advice.append("A proxy is configured — if you're not on the corporate network it may block browsing.") }
        }
        if !s.configuredDNS.isEmpty, case .captive = c {
            advice.append("Custom DNS often breaks hotel/airport logins — use Captive Portal ▸ Portal Mode.")
        }

        log("\n— Result —")
        if advice.isEmpty {
            log("✅ Everything looks healthy.")
        } else {
            for a in advice { log("• \(a)") }
        }
    }

    // MARK: Auto-fix

    /// Walks the network stack bottom-up, applying fixes until the connection works.
    /// Returns the final connectivity state.
    @discardableResult
    static func autoFix(interactive: Bool, openPortal: (URL?) -> Void, log: Logger) -> Connectivity {
        var s = NetInfo.snapshot()
        var cycledWiFi = false
        var renewed = false

        log("Connection: \(s.service.map { "\($0.name) (\($0.device))" } ?? "none")")

        // 1. Wi-Fi radio off?
        if let w = s.wifi, !w.powerOn, s.localIP == nil {
            log("→ Wi-Fi is off — turning it on…")
            _ = Fixes.setWiFiPower(true)
            _ = Fixes.waitForIP(s.wifiDevice, wait: 20)
            s = NetInfo.snapshot()
        }

        // 2. No address / DHCP failure
        if s.localIP == nil || s.selfAssigned, let svc = s.service {
            log("→ No valid IP address — renewing DHCP lease…")
            let r = Fixes.renewDHCP(svc.device, interactive: interactive)
            renewed = r.ok
            if !r.ok { log("   ⚠️ \(r.out.isEmpty ? "Could not renew lease" : r.out)") }
            if Fixes.waitForIP(svc.device, wait: 12) { log("   ✅ Got an address") }
            s = NetInfo.snapshot()
            if (s.localIP == nil || s.selfAssigned) && s.isWiFi {
                log("→ Still no address — turning Wi-Fi off and on…")
                cycledWiFi = true
                log(Fixes.cycleWiFi() ? "   ✅ Reconnected" : "   ❌ Wi-Fi did not get an address")
                s = NetInfo.snapshot()
            }
            if s.localIP == nil || s.selfAssigned {
                log("❌ Still no IP address. The router isn't giving out addresses — restart the router, or check the cable / Wi-Fi password.")
                return .offline
            }
        }

        // 3. Classify
        log("→ Testing internet connectivity…")
        var c = Probe.connectivity()
        log("   \(describe(c))")

        if c == .offline {
            let gwOK = s.gateway.map { Probe.ping($0, count: 3).ok } ?? false
            if !gwOK, let svc = s.service {
                if s.isWiFi && !cycledWiFi {
                    log("→ Router not responding — reconnecting Wi-Fi…")
                    cycledWiFi = true
                    _ = Fixes.cycleWiFi()
                } else if !renewed {
                    log("→ Router not responding — renewing DHCP lease…")
                    Fixes.renewDHCP(svc.device, interactive: interactive)
                    _ = Fixes.waitForIP(svc.device, wait: 12)
                }
                s = NetInfo.snapshot()
                c = Probe.connectivity()
                log("   \(describe(c))")
            }
            if c == .offline {
                if Probe.ping("1.1.1.1", count: 3).ok {
                    // IP works but HTTP doesn't: treat as DNS / proxy problem below
                    c = .dnsFailure
                } else {
                    if !s.connectedVPNs.isEmpty || s.viaTunnel {
                        log("⚠️ A VPN is active and the internet is unreachable — try Quick Fixes ▸ Disconnect VPNs.")
                    }
                    log("❌ Your router is reachable but there's no internet. This is usually the modem/ISP — restart the modem and router, or check your ISP's outage page.")
                    return .offline
                }
            }
        }

        // 4. DNS
        if c == .dnsFailure {
            log("→ DNS problem — flushing DNS cache…")
            Fixes.flushDNS(interactive: interactive)
            sleep(1)
            c = Probe.connectivity()
            if c == .dnsFailure || c == .offline {
                log("→ Still failing — switching DNS to Cloudflare + Google (1.1.1.1, 8.8.8.8)…")
                let r = Fixes.setDNS(["1.1.1.1", "8.8.8.8"], services: dnsTargets(s), interactive: interactive)
                if !r.ok { log("   ⚠️ \(r.out)") }
                sleep(2)
                c = Probe.connectivity()
            }
            log("   \(describe(c))")
            if case .captive = c {
                // handled below
            } else if c != .online {
                if !s.proxies.isEmpty { log("⚠️ A proxy (\(s.proxies.joined(separator: ", "))) is configured and may be blocking traffic.") }
                log("❌ Couldn't fix DNS automatically. Run Full Diagnostics for details.")
                return c
            }
        }

        // 5. Captive portal
        if case .captive(let url) = c {
            if !s.configuredDNS.isEmpty {
                log("→ Captive portal + custom DNS detected — temporarily switching to automatic DNS so the login page loads…")
                UserDefaults.standard.set(s.configuredDNS, forKey: "portalSavedDNS")
                Fixes.setDNS([], services: dnsTargets(s), interactive: interactive, rememberPrevious: false)
                sleep(2)
            }
            log("→ Opening login page\(url.map { ": \($0.absoluteString)" } ?? "")…")
            openPortal(url)
            log("ℹ️ Log in on the page that opened. Your custom DNS will be restored automatically once you're online.")
            return c
        }

        if c == .online {
            log("✅ You're online.")
        }
        return c
    }

    // MARK: DNS benchmark

    static func benchmarkDNS(current: [String], log: Logger) -> [(name: String, servers: [String], ms: Int)] {
        let domains = ["www.google.com", "www.apple.com", "www.amazon.com", "www.microsoft.com", "www.cloudflare.com"]
        var candidates: [(String, [String])] = dnsPresets.map { ($0.name, $0.servers) }
        if let first = current.first, !dnsPresets.contains(where: { $0.servers.contains(first) }) {
            candidates.insert(("Current (\(first))", current), at: 0)
        }
        var results: [(name: String, servers: [String], ms: Int)] = []
        for (name, servers) in candidates {
            var times: [Int] = []
            var failures = 0
            for d in domains {
                let r = Probe.dig(servers[0], d)
                if r.ok, let ms = r.ms { times.append(ms) } else { failures += 1 }
            }
            if times.isEmpty {
                log("❌ \(name) — no response")
                continue
            }
            let avg = times.reduce(0, +) / times.count + failures * 2000 / domains.count
            log("   \(name) (\(servers[0])): avg \(avg) ms\(failures > 0 ? ", \(failures) failed" : "")")
            results.append((name, servers, avg))
        }
        return results.sorted { $0.ms < $1.ms }
    }

    private static func fmt(_ d: Double?) -> String {
        d.map { String(format: "%.1f", $0) } ?? "?"
    }
}
