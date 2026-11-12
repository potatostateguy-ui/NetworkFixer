import AppKit

/// A simple live-log window used for diagnostics, fixes, speed tests and benchmarks.
final class ReportWindow: NSObject, NSWindowDelegate {
    static let shared = ReportWindow()

    private var window: NSWindow?
    private var textView: NSTextView!
    private var spinner: NSProgressIndicator!
    private var statusLabel: NSTextField!

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.minSize = NSSize(width: 480, height: 300)

        let scroll = NSTextView.scrollableTextView()
        textView = (scroll.documentView as! NSTextView)
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        scroll.translatesAutoresizingMaskIntoConstraints = false

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let copy = NSButton(title: "Copy Report", target: self, action: #selector(copyReport))
        let close = NSButton(title: "Close", target: self, action: #selector(closeWindow))
        close.keyEquivalent = "\u{1b}"
        for b in [copy, close] { b.translatesAutoresizingMaskIntoConstraints = false }

        let content = w.contentView!
        [scroll, spinner, statusLabel, copy, close].forEach { content.addSubview($0) }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: copy.topAnchor, constant: -10),
            spinner.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            spinner.centerYAnchor.constraint(equalTo: copy.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 8),
            statusLabel.centerYAnchor.constraint(equalTo: copy.centerYAnchor),
            close.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            close.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            copy.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -8),
            copy.centerYAnchor.constraint(equalTo: close.centerYAnchor),
        ])
        window = w
    }

    func start(_ title: String) {
        if window == nil { build() }
        window!.title = "Network Fixer — \(title)"
        textView.string = ""
        statusLabel.stringValue = "Working…"
        spinner.startAnimation(nil)
        if !window!.isVisible { window!.center() }
        NSApp.activate(ignoringOtherApps: true)
        window!.makeKeyAndOrderFront(nil)
    }

    /// Thread-safe append.
    func log(_ line: String) {
        DispatchQueue.main.async {
            guard let tv = self.textView else { return }
            tv.textStorage?.append(NSAttributedString(string: line + "\n", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.labelColor,
            ]))
            tv.scrollToEndOfDocument(nil)
        }
    }

    func finish(_ status: String = "Done") {
        DispatchQueue.main.async {
            self.spinner?.stopAnimation(nil)
            self.statusLabel?.stringValue = status
        }
    }

    @objc private func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textView.string, forType: .string)
        statusLabel.stringValue = "Copied to clipboard"
    }

    @objc private func closeWindow() { window?.close() }
}
