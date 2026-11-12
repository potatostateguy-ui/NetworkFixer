import AppKit
import Network
import UserNotifications
import ServiceManagement
import CoreLocation

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate, CLLocationManagerDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var menuOpen = false

    private var connectivity: Connectivity = .unknown
    private var snapshot: NetSnapshot?
    private var publicIP: String?
    private var busy = false
    private var checking = false
    private var pendingFailures = 0
    private var lastAutoFix = Date.distantPast
    private var lastAutoFixLog = ""

    private var timer: Timer?
    private let pathMonitor = NWPathMonitor()
    private var pathDebounce: DispatchWorkItem?
    private let locationManager = CLLocationManager()
    private let prefs = UserDefaults.standard

    // MARK: - Preferences

    private func pref(_ key: String, default def: Bool) -> Bool {
        prefs.object(forKey: key) == nil ? def : prefs.bool(forKey: key)
    }
    private var monitorOn: Bool { pref("monitor", default: true) }
    private var autoFixOn: Bool { pref("autoFix", default: true) }
    private var autoPortalOn: Bool { pref("autoPortal", default: true) }
    private var notifyOn: Bool { pref("notify", default: true) }
    private var dnsAllServices: Bool { pref("dnsAllServices", default: true) }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.toolTip = "Network Fixer"
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        updateIcon()
        rebuildMenu()

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // Wi-Fi network names (SSID) require Location permission on modern macOS.
        locationManager.delegate = self
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }

        pathMonitor.pathUpdateHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.scheduleCheck(after: 3) }
        }
        pathMonitor.start(queue: .global(qos: .utility))

        restartTimer()
        checkNow()
    }

    private func restartTimer() {
        timer?.invalidate()
        guard monitorOn else { return }
        let interval: TimeInterval = connectivity == .online ? 30 : 10
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.checkNow() }
    }

    private func scheduleCheck(after seconds: TimeInterval) {
        pathDebounce?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.checkNow() }
        pathDebounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    // MARK: - Monitoring

    func checkNow(withPublicIP: Bool = false) {
        guard !checking else { return }
        checking = true
        DispatchQueue.global(qos: .utility).async {
            let c = Probe.connectivity(timeout: 5)
            let snap = NetInfo.snapshot(includePublicIP: withPublicIP && c == .online)
            DispatchQueue.main.async {
                self.checking = false
                self.snapshot = snap
                if let ip = snap.publicIP { self.publicIP = ip }
                self.handle(c)
            }
        }
    }

    private func handle(_ new: Connectivity) {
        let old = connectivity
        let isBad = new == .offline || new == .dnsFailure

        // Require two failed checks in a row before declaring an outage (avoids flapping).
        if isBad && (old == .online || old == .unknown) && pendingFailures < 1 && !busy {
            pendingFailures += 1
            scheduleCheck(after: 4)
            return
        }
        pendingFailures = 0
        connectivity = new

        if new != old {
            onTransition(from: old, to: new)
            restartTimer()
        }
        updateIcon()
        if menuOpen { rebuildMenu() }
    }

    private func onTransition(from old: Connectivity, to new: Connectivity) {
        switch new {
        case .captive(let url):
            if case .captive = old { return }
            if autoPortalOn {
                notify("Wi-Fi login required", "Opening the captive portal login page…")
                openPortal(url)
            } else {
                notify("Wi-Fi login required", "Click to open the login page.", portal: url)
            }
        case .offline, .dnsFailure:
            guard old == .online || old == .unknown else { return }
            if autoFixOn && !busy && Date().timeIntervalSince(lastAutoFix) > 180 {
                lastAutoFix = Date()
                runBackgroundAutoFix(reason: new == .dnsFailure ? "DNS stopped working" : "Connection lost")
            } else if old == .online {
                notify(new == .dnsFailure ? "DNS stopped working" : "Internet connection lost", "Click Network Fixer ▸ Fix My Connection.")
            }
        case .online:
            if let saved = prefs.stringArray(forKey: "portalSavedDNS") {
                prefs.removeObject(forKey: "portalSavedDNS")
                let targets = snapshot.map(Engine.dnsTargets) ?? []
                DispatchQueue.global().async {
                    let r = Fixes.setDNS(saved, services: targets, rememberPrevious: false)
                    self.notify("Portal login complete", r.ok ? "Restored your DNS (\(saved.joined(separator: ", ")))." : "Couldn't restore DNS: \(r.out)")
                }
            } else if old == .offline || old == .dnsFailure {
                notify("Back online", Engine.describe(new))
            }
        case .unknown:
            break
        }
    }

    private func runBackgroundAutoFix(reason: String) {
        busy = true
        updateIcon()
        var lines = ["Auto-fix started (\(reason)) at \(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium))"]
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Engine.autoFix(interactive: false, openPortal: { url in
                DispatchQueue.main.async { self.openPortal(url) }
            }, log: { lines.append($0) })
            DispatchQueue.main.async {
                self.busy = false
                self.lastAutoFixLog = lines.joined(separator: "\n")
                if result == .online {
                    self.notify("Network fixed automatically", "\(reason) — you're back online.")
                } else if case .captive = result {
                    // portal page was opened; user needs to log in
                } else {
                    self.notify("\(reason)", "Auto-fix couldn't restore the connection. Open Network Fixer for details.")
                }
                self.checkNow()
            }
        }
    }

    // MARK: - Icon

    private func updateIcon() {
        let isEthernet = snapshot.map { !$0.isWiFi && $0.service != nil } ?? false
        let name: String
        switch (busy, connectivity) {
        case (true, _): name = "arrow.triangle.2.circlepath"
        case (_, .online): name = isEthernet ? "network" : "wifi"
        case (_, .captive): name = "wifi.exclamationmark"
        case (_, .dnsFailure): name = "exclamationmark.triangle"
        case (_, .offline): name = "wifi.slash"
        case (_, .unknown): name = "wifi"
        }
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Network Fixer") ?? NSImage(systemSymbolName: "wifi", accessibilityDescription: nil)
        img?.isTemplate = true
        statusItem.button?.image = img
        statusItem.button?.toolTip = "Network Fixer — \(busy ? "Fixing…" : Engine.describe(connectivity))"
    }

    // MARK: - Menu

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        rebuildMenu()
        checkNow(withPublicIP: true)
    }

    func menuDidClose(_ menu: NSMenu) { menuOpen = false }

    private func symbol(_ name: String, color: NSColor? = nil) -> NSImage? {
        var img = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        if let color {
            img = img?.withSymbolConfiguration(.init(paletteColors: [color]))
        }
        return img
    }

    @discardableResult
    private func add(_ m: NSMenu, _ title: String, _ action: Selector?, icon: String? = nil, key: String = "", obj: Any? = nil, enabled: Bool = true, state: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.representedObject = obj
        item.isEnabled = enabled && (action != nil)
        item.state = state ? .on : .off
        if let icon { item.image = symbol(icon) }
        m.addItem(item)
        return item
    }

    private func info(_ m: NSMenu, _ title: String, copy: String? = nil) {
        let item = add(m, title, copy == nil ? nil : #selector(copyValue(_:)), obj: copy)
        item.isEnabled = copy != nil
        item.indentationLevel = 1
        if copy != nil { item.toolTip = "Click to copy" }
    }

    private func submenu(_ parent: NSMenu, _ title: String, icon: String) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = symbol(icon)
        let sub = NSMenu(title: title)
        sub.autoenablesItems = false
        item.submenu = sub
        parent.addItem(item)
        return sub
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        let s = snapshot

        // Status header
        let color: NSColor
        switch connectivity {
        case .online: color = .systemGreen
        case .captive, .dnsFailure: color = .systemOrange
        case .offline: color = .systemRed
        case .unknown: color = .systemGray
        }
        var header = busy ? "Fixing…" : Engine.describe(connectivity)
        if let svc = s?.service {
            header += " — \(svc.name)"
            if s?.isWiFi == true, let ssid = s?.wifi?.ssid { header += " “\(ssid)”" }
        }
        let h = add(menu, header, nil)
        h.image = symbol("circle.fill", color: color)
        h.isEnabled = true

        if let s {
            if let ip = s.localIP {
                info(menu, "IP \(ip)\(s.selfAssigned ? " (self-assigned!)" : "")", copy: ip)
            }
            if let gw = s.gateway { info(menu, "Router \(gw)", copy: gw) }
            let dns = s.effectiveDNS.prefix(2).joined(separator: ", ")
            info(menu, "DNS \(dns.isEmpty ? "none" : dns) (\(s.configuredDNS.isEmpty ? "Automatic" : "Manual"))", copy: dns)
            if s.isWiFi, let w = s.wifi, w.powerOn {
                info(menu, "Signal \(w.rssi) dBm \(w.quality) · \(Int(w.txRate)) Mbps\(w.band.map { " · \($0)" } ?? "")")
            }
            if let pub = publicIP { info(menu, "Public IP \(pub)", copy: pub) }
            if !s.connectedVPNs.isEmpty { info(menu, "VPN: \(s.connectedVPNs.joined(separator: ", "))") }
        }
        menu.addItem(.separator())

        add(menu, "Fix My Connection", #selector(fixConnection), icon: "wand.and.stars", key: "f", enabled: !busy)
        add(menu, "Run Full Diagnostics…", #selector(runDiagnostics), icon: "stethoscope", key: "d", enabled: !busy)
        menu.addItem(.separator())

        // DNS
        let dnsMenu = submenu(menu, "DNS", icon: "server.rack")
        let current = s?.configuredDNS ?? []
        for p in dnsPresets {
            add(dnsMenu, "\(p.name)  —  \(p.servers.joined(separator: ", "))", #selector(setDNSPreset(_:)), obj: p.servers,
                state: !current.isEmpty && current == p.servers)
        }
        dnsMenu.addItem(.separator())
        add(dnsMenu, "Automatic (from router / DHCP)", #selector(setDNSPreset(_:)), obj: [String](), state: s != nil && current.isEmpty)
        let isCustom = !current.isEmpty && !dnsPresets.contains { $0.servers == current }
        add(dnsMenu, isCustom ? "Custom (\(current.joined(separator: ", ")))…" : "Custom…", #selector(customDNS), state: isCustom)
        if let prev = Fixes.previousDNS, prev != current {
            add(dnsMenu, "Restore Previous (\(prev.isEmpty ? "Automatic" : prev.joined(separator: ", ")))", #selector(setDNSPreset(_:)), icon: "arrow.uturn.backward", obj: prev)
        }
        dnsMenu.addItem(.separator())
        add(dnsMenu, "Find Fastest DNS…", #selector(benchmarkDNS), icon: "speedometer", enabled: !busy)
        add(dnsMenu, "Flush DNS Cache", #selector(flushDNS), icon: "arrow.clockwise")
        add(dnsMenu, "Apply to All Network Services", #selector(toggleDNSAll), state: dnsAllServices)
            .toolTip = "When on, DNS changes apply to Wi-Fi and Ethernet so it follows you between connections."

        // Captive portal
        let cap = submenu(menu, "Captive Portal / Wi-Fi Login", icon: "person.badge.key")
        if case .captive(let url) = connectivity, let url {
            add(cap, "Open Detected Login Page (\(url.host ?? ""))", #selector(openURLItem(_:)), icon: "star", obj: url)
        }
        add(cap, "Open Login Page (default browser)", #selector(openURLItem(_:)), icon: "safari",
            obj: URL(string: "http://captive.apple.com/hotspot-detect.html")!)
        add(cap, "Open Login Page in Safari", #selector(openInSafari), icon: "safari.fill")
            .toolTip = "Chrome/Firefox 'Secure DNS' can stop portals from appearing — Safari avoids that."
        add(cap, "Open neverssl.com", #selector(openURLItem(_:)), icon: "globe", obj: URL(string: "http://neverssl.com")!)
        add(cap, "Open Gateway Page\(s?.gateway.map { " (\($0))" } ?? "")", #selector(openURLItem(_:)), icon: "house",
            obj: s?.gateway.flatMap { URL(string: "http://\($0)") }, enabled: s?.gateway != nil)
        add(cap, "Launch Apple Captive Network Assistant", #selector(launchCNA), icon: "macwindow")
        cap.addItem(.separator())
        add(cap, "Portal Mode: Automatic DNS + Open Login", #selector(portalMode), icon: "key.horizontal")
            .toolTip = "Custom DNS (1.1.1.1/8.8.8.8) breaks most hotel/airport logins. This switches to the network's DNS, opens the login page, and restores your DNS once you're online."
        if let saved = prefs.stringArray(forKey: "portalSavedDNS") {
            add(cap, "Restore My DNS Now (\(saved.joined(separator: ", ")))", #selector(restorePortalDNS), icon: "arrow.uturn.backward")
        }

        // Quick fixes
        let fixes = submenu(menu, "Quick Fixes", icon: "wrench.and.screwdriver")
        add(fixes, "Renew DHCP Lease", #selector(renewDHCP), icon: "arrow.triangle.2.circlepath", enabled: !busy && s?.service != nil)
        if s?.wifiDevice != nil {
            add(fixes, "Turn Wi-Fi Off & On", #selector(cycleWiFi), icon: "power", enabled: !busy)
        }
        add(fixes, "Flush DNS Cache", #selector(flushDNS), icon: "arrow.clockwise")
        add(fixes, "Disconnect VPNs\(s.map { $0.connectedVPNs.isEmpty ? "" : " (\($0.connectedVPNs.count))" } ?? "")",
            #selector(disconnectVPNs), icon: "lock.slash", enabled: !(s?.connectedVPNs.isEmpty ?? true))
        add(fixes, "Full Network Reset", #selector(fullReset), icon: "exclamationmark.arrow.circlepath", enabled: !busy && s?.service != nil)
            .toolTip = "Flushes DNS and ARP caches, renews DHCP and reconnects Wi-Fi."

        // Tools
        let tools = submenu(menu, "Tools", icon: "hammer")
        add(tools, "Speed Test", #selector(speedTest), icon: "gauge.with.dots.needle.67percent", enabled: !busy)
        add(tools, "Copy Network Info (for support tickets)", #selector(copyNetworkInfo), icon: "doc.on.doc")
        if !lastAutoFixLog.isEmpty {
            add(tools, "Show Last Auto-Fix Log", #selector(showAutoFixLog), icon: "list.bullet.rectangle")
        }
        tools.addItem(.separator())
        add(tools, "Open Wireless Diagnostics", #selector(openWirelessDiagnostics), icon: "waveform.path.ecg")
        add(tools, "Open Network Settings", #selector(openNetworkSettings), icon: "gearshape")

        menu.addItem(.separator())

        // Settings
        let settings = submenu(menu, "Settings", icon: "slider.horizontal.3")
        add(settings, "Monitor Connection", #selector(togglePref(_:)), obj: "monitor", state: monitorOn)
        add(settings, "Auto-Fix When Connection Drops", #selector(togglePref(_:)), obj: "autoFix", state: autoFixOn)
            .toolTip = "Background fixes that need admin rights only run when Password-Free Fixes is enabled."
        add(settings, "Auto-Open Captive Portals", #selector(togglePref(_:)), obj: "autoPortal", state: autoPortalOn)
        add(settings, "Notifications", #selector(togglePref(_:)), obj: "notify", state: notifyOn)
        settings.addItem(.separator())
        add(settings, "Launch at Login", #selector(toggleLoginItem), state: SMAppService.mainApp.status == .enabled)
        add(settings, "Password-Free Fixes", #selector(togglePasswordFree), state: Shell.passwordFreeInstalled)
            .toolTip = "Installs a sudoers rule allowing only Network Fixer's repair commands without a password, so auto-fix can work in the background."

        menu.addItem(.separator())
        add(menu, "Quit Network Fixer", #selector(NSApplication.terminate(_:)), key: "q").target = NSApp
    }

    // MARK: - Helpers

    private func notify(_ title: String, _ body: String, portal: URL? = nil) {
        guard notifyOn else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let portal { content.userInfo = ["portal": portal.absoluteString] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        DispatchQueue.main.async {
            if let p = info["portal"] as? String, let url = URL(string: p) {
                self.openPortal(url)
            } else if case .captive(let url) = self.connectivity {
                self.openPortal(url)
            }
        }
        completionHandler()
    }

    private func openPortal(_ url: URL?) {
        NSWorkspace.shared.open(url ?? URL(string: "http://captive.apple.com/hotspot-detect.html")!)
    }

    /// Runs work off the main thread, optionally streaming its log to the report window.
    private func runTask(_ title: String, window: Bool = true, _ work: @escaping (@escaping Logger) -> String?) {
        guard !busy else { NSSound.beep(); return }
        busy = true
        updateIcon()
        if window { ReportWindow.shared.start(title) }
        DispatchQueue.global(qos: .userInitiated).async {
            let status = work { line in if window { ReportWindow.shared.log(line) } }
            DispatchQueue.main.async {
                self.busy = false
                if window { ReportWindow.shared.finish(status ?? "Done") }
                else if let status { self.notify(title, status) }
                self.updateIcon()
                self.checkNow()
            }
        }
    }

    // MARK: - Actions

    @objc private func copyValue(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(v, forType: .string)
    }

    @objc private func fixConnection() {
        runTask("Fix My Connection") { log in
            let r = Engine.autoFix(interactive: true, openPortal: { url in
                DispatchQueue.main.async { self.openPortal(url) }
            }, log: log)
            return r == .online ? "Fixed — you're online" : "Finished: \(Engine.describe(r))"
        }
    }

    @objc private func runDiagnostics() {
        runTask("Diagnostics") { log in
            Engine.diagnose(log: log)
            return "Diagnostics complete"
        }
    }

    @objc private func setDNSPreset(_ sender: NSMenuItem) {
        guard let servers = sender.representedObject as? [String], let s = snapshot else { return }
        applyDNS(servers, snapshot: s)
    }

    private func applyDNS(_ servers: [String], snapshot s: NetSnapshot) {
        let targets = Engine.dnsTargets(s)
        let label = servers.isEmpty ? "Automatic" : servers.joined(separator: ", ")
        runTask("DNS", window: false) { _ in
            let r = Fixes.setDNS(servers, services: targets)
            return r.ok ? "DNS set to \(label) on \(targets.joined(separator: ", "))" : "Couldn't change DNS: \(r.out)"
        }
    }

    @objc private func customDNS() {
        guard let s = snapshot else { return }
        let alert = NSAlert()
        alert.messageText = "Custom DNS Servers"
        alert.informativeText = "Enter one or more DNS server IPs, separated by spaces or commas."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "e.g. 1.1.1.1, 8.8.8.8"
        field.stringValue = s.configuredDNS.joined(separator: ", ")
        alert.accessoryView = field
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let servers = field.stringValue.components(separatedBy: CharacterSet(charactersIn: ", ")).filter { !$0.isEmpty }
        let valid = servers.filter { addr in
            var v4 = in_addr(), v6 = in6_addr()
            return inet_pton(AF_INET, addr, &v4) == 1 || inet_pton(AF_INET6, addr, &v6) == 1
        }
        guard !valid.isEmpty, valid.count == servers.count else {
            let err = NSAlert()
            err.messageText = "Invalid IP address"
            err.informativeText = "Please enter valid IPv4 or IPv6 addresses."
            err.runModal()
            return
        }
        applyDNS(valid, snapshot: s)
    }

    @objc private func toggleDNSAll() { prefs.set(!dnsAllServices, forKey: "dnsAllServices") }

    @objc private func flushDNS() {
        runTask("Flush DNS Cache", window: false) { _ in
            let r = Fixes.flushDNS()
            return r.ok ? "DNS cache flushed" : "Couldn't flush DNS: \(r.out)"
        }
    }

    @objc private func benchmarkDNS() {
        let current = snapshot?.effectiveDNS ?? []
        guard let s = snapshot else { return }
        runTask("Find Fastest DNS") { log in
            log("Timing 5 lookups against each DNS provider…\n")
            let results = Engine.benchmarkDNS(current: current, log: log)
            guard let best = results.first else {
                log("\n❌ No DNS server responded.")
                return "No DNS server responded"
            }
            log("\n🏆 Fastest: \(best.name) — \(best.ms) ms average")
            DispatchQueue.main.async {
                guard !(s.configuredDNS == best.servers) else { return }
                let a = NSAlert()
                a.messageText = "Switch to \(best.name)?"
                a.informativeText = "\(best.servers.joined(separator: ", ")) was fastest at \(best.ms) ms average."
                a.addButton(withTitle: "Switch")
                a.addButton(withTitle: "Not Now")
                NSApp.activate(ignoringOtherApps: true)
                if a.runModal() == .alertFirstButtonReturn { self.applyDNS(best.servers, snapshot: s) }
            }
            return "Benchmark complete"
        }
    }

    @objc private func openURLItem(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { NSWorkspace.shared.open(url) }
    }

    @objc private func openInSafari() {
        let url = URL(string: "http://captive.apple.com/hotspot-detect.html")!
        let safari = URL(fileURLWithPath: "/Applications/Safari.app")
        NSWorkspace.shared.open([url], withApplicationAt: safari, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func launchCNA() {
        let cna = URL(fileURLWithPath: "/System/Library/CoreServices/Captive Network Assistant.app")
        NSWorkspace.shared.openApplication(at: cna, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if error != nil { DispatchQueue.main.async { self.openPortal(nil) } }
        }
    }

    @objc private func portalMode() {
        guard let s = snapshot else { return }
        let targets = Engine.dnsTargets(s)
        let saved = s.configuredDNS
        runTask("Portal Mode", window: false) { _ in
            if !saved.isEmpty {
                self.prefs.set(saved, forKey: "portalSavedDNS")
                let r = Fixes.setDNS([], services: targets, rememberPrevious: false)
                if !r.ok {
                    self.prefs.removeObject(forKey: "portalSavedDNS")
                    return "Couldn't switch DNS: \(r.out)"
                }
                sleep(2)
            } else {
                Fixes.flushDNS()
            }
            let c = Probe.connectivity()
            DispatchQueue.main.async {
                if case .captive(let url) = c { self.openPortal(url) } else { self.openPortal(nil) }
            }
            return saved.isEmpty ? "Opened the login page" : "Using the network's DNS — your DNS will be restored once you're online"
        }
    }

    @objc private func restorePortalDNS() {
        guard let saved = prefs.stringArray(forKey: "portalSavedDNS"), let s = snapshot else { return }
        prefs.removeObject(forKey: "portalSavedDNS")
        applyDNS(saved, snapshot: s)
    }

    @objc private func renewDHCP() {
        guard let dev = snapshot?.service?.device else { return }
        runTask("Renew DHCP Lease", window: false) { _ in
            let r = Fixes.renewDHCP(dev)
            guard r.ok else { return "Couldn't renew: \(r.out)" }
            return Fixes.waitForIP(dev, wait: 15) ? "Lease renewed — IP \(NetInfo.ipv4(dev) ?? "?")" : "Renewed, but no address yet"
        }
    }

    @objc private func cycleWiFi() {
        runTask("Wi-Fi", window: false) { _ in
            Fixes.cycleWiFi() ? "Wi-Fi reconnected" : "Wi-Fi restarted but hasn't got an address yet"
        }
    }

    @objc private func disconnectVPNs() {
        runTask("VPN", window: false) { _ in
            let v = Fixes.disconnectVPNs()
            return v.isEmpty ? "No VPNs were connected" : "Disconnected \(v.joined(separator: ", "))"
        }
    }

    @objc private func fullReset() {
        guard let s = snapshot, let svc = s.service else { return }
        runTask("Full Network Reset") { log in
            log("→ Flushing DNS + ARP caches and renewing DHCP on \(svc.name)…")
            let r = Fixes.fullReset(svc.device)
            log(r.ok ? "   ✅ Done" : "   ⚠️ \(r.out)")
            if s.isWiFi {
                log("→ Turning Wi-Fi off and on…")
                log(Fixes.cycleWiFi() ? "   ✅ Reconnected" : "   ⚠️ No address yet")
            } else {
                _ = Fixes.waitForIP(svc.device, wait: 15)
            }
            log("→ Testing…")
            let c = Probe.connectivity()
            log("   \(Engine.describe(c))")
            return Engine.describe(c)
        }
    }

    @objc private func speedTest() {
        runTask("Speed Test") { log in
            log("Running Apple's networkQuality test (about 20 seconds)…\n")
            let r = Shell.run("/usr/bin/networkQuality", [], timeout: 120)
            log(r.out.isEmpty ? "Speed test failed." : r.out)
            return r.ok ? "Speed test complete" : "Speed test failed"
        }
    }

    @objc private func copyNetworkInfo() {
        DispatchQueue.global().async {
            let s = NetInfo.snapshot(includePublicIP: true)
            var text = NetInfo.summary(s)
            text += "\nStatus: \(Engine.describe(Probe.connectivity()))"
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                self.notify("Network info copied", "Paste it into your ticket or chat.")
            }
        }
    }

    @objc private func showAutoFixLog() {
        ReportWindow.shared.start("Last Auto-Fix")
        ReportWindow.shared.log(lastAutoFixLog)
        ReportWindow.shared.finish()
    }

    @objc private func openWirelessDiagnostics() {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Library/CoreServices/Wireless Diagnostics.app"),
                                           configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func openNetworkSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension")!)
    }

    @objc private func togglePref(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        let defaults: [String: Bool] = ["monitor": true, "autoFix": true, "autoPortal": true, "notify": true]
        prefs.set(!pref(key, default: defaults[key] ?? true), forKey: key)
        if key == "monitor" { restartTimer() }
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let a = NSAlert()
            a.messageText = "Couldn't change Launch at Login"
            a.informativeText = "\(error.localizedDescription)\n\nYou can add Network Fixer manually in System Settings ▸ General ▸ Login Items."
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
        }
    }

    @objc private func togglePasswordFree() {
        let installed = Shell.passwordFreeInstalled
        let a = NSAlert()
        if installed {
            a.messageText = "Turn off Password-Free Fixes?"
            a.informativeText = "Network Fixer will ask for your password again for DNS/DHCP changes, and background auto-fix will be limited to non-admin fixes."
            a.addButton(withTitle: "Turn Off")
        } else {
            a.messageText = "Enable Password-Free Fixes?"
            a.informativeText = """
            This installs /etc/sudoers.d/networkfixer allowing your account to run only these commands without a password:

            • networksetup (DNS / network settings)
            • dscacheutil -flushcache, killall -HUP mDNSResponder
            • ipconfig set <interface> DHCP
            • arp -a -d

            This lets auto-fix repair your connection in the background. You'll be asked for your password once.
            """
            a.addButton(withTitle: "Enable")
        }
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        DispatchQueue.global().async {
            let r = installed ? Shell.removePasswordFree() : Shell.installPasswordFree()
            self.notify("Password-Free Fixes", r.ok ? (installed ? "Turned off." : "Enabled.") : "Failed: \(r.out)")
        }
    }

    // MARK: - Location (for SSID)

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        checkNow()
    }
}
