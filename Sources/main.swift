import AppKit

// CLI mode: `NetworkFixer --diagnose` prints a diagnostics report to the terminal.
if CommandLine.arguments.contains("--diagnose") {
    Engine.diagnose { print($0) }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
