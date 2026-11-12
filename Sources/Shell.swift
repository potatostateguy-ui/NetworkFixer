import Foundation

struct CmdResult {
    let status: Int32
    let out: String
    var ok: Bool { status == 0 }
}

enum Shell {
    /// Runs a command and returns combined stdout/stderr. Safe to call from any background queue.
    @discardableResult
    static func run(_ path: String, _ args: [String] = [], timeout: TimeInterval = 30) -> CmdResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return CmdResult(status: -1, out: "\(error.localizedDescription)") }

        var data = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(30_000) }
        if p.isRunning { p.terminate() }
        p.waitUntilExit()
        _ = group.wait(timeout: .now() + 2)
        let out = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return CmdResult(status: p.terminationStatus, out: out)
    }

    static func shq(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Privileged commands

    static let sudoersPath = "/etc/sudoers.d/networkfixer"
    static var passwordFreeInstalled: Bool { FileManager.default.fileExists(atPath: sudoersPath) }

    /// Runs commands as root. Uses the password-free sudoers rule when installed,
    /// otherwise shows one macOS admin prompt for the whole batch (only if `interactive`).
    @discardableResult
    static func runPrivileged(_ cmds: [[String]], interactive: Bool = true) -> CmdResult {
        if passwordFreeInstalled {
            var out: [String] = []
            var allOK = true
            for c in cmds {
                let r = run("/usr/bin/sudo", ["-n"] + c)
                if !r.out.isEmpty { out.append(r.out) }
                if !r.ok { allOK = false }
            }
            if allOK || !interactive { return CmdResult(status: allOK ? 0 : 1, out: out.joined(separator: "\n")) }
        }
        guard interactive else { return CmdResult(status: 1, out: "Needs admin rights (enable Password-Free Fixes for background repairs)") }
        let script = cmds.map { $0.map(shq).joined(separator: " ") }.joined(separator: " ; ")
        return runAsAdmin(script)
    }

    static func runAsAdmin(_ script: String) -> CmdResult {
        let escaped = script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let apple = "do shell script \"\(escaped)\" with administrator privileges with prompt \"Network Fixer needs administrator access to change network settings.\""
        return run("/usr/bin/osascript", ["-e", apple], timeout: 180)
    }

    /// Installs a narrowly-scoped sudoers rule so fixes can run without a password prompt
    /// (needed for background auto-fix).
    static func installPasswordFree() -> CmdResult {
        let user = NSUserName()
        let rule = """
        # Installed by Network Fixer - allows these network repair commands without a password.
        \(user) ALL=(root) NOPASSWD: /usr/sbin/networksetup, /usr/bin/dscacheutil -flushcache, /usr/bin/killall -HUP mDNSResponder, /usr/sbin/ipconfig set * DHCP, /usr/sbin/ipconfig set * BOOTP, /usr/sbin/arp -a -d

        """
        let tmp = NSTemporaryDirectory() + "networkfixer.sudoers"
        do { try rule.write(toFile: tmp, atomically: true, encoding: .utf8) } catch {
            return CmdResult(status: 1, out: error.localizedDescription)
        }
        let script = "/usr/sbin/visudo -cf \(shq(tmp)) && /usr/bin/install -m 0440 -o root -g wheel \(shq(tmp)) \(shq(sudoersPath))"
        let r = runAsAdmin(script)
        try? FileManager.default.removeItem(atPath: tmp)
        return r
    }

    static func removePasswordFree() -> CmdResult {
        runAsAdmin("/bin/rm -f \(shq(sudoersPath))")
    }
}
