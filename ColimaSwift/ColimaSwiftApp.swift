import SwiftUI
import AppKit
import Combine

@main
struct ColimaSwiftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // No window scenes — the menu bar item is owned by AppDelegate.
        // The Settings scene gives SwiftUI a valid Scene without showing UI.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    private var controller: ColimaController!
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var cancellable: AnyCancellable?
    private var logsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        controller = ColimaController()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 240, height: 320)
        popover.contentViewController = NSHostingController(
            rootView: MenuContentView().environmentObject(controller)
        )

        renderIcon(for: controller.status)
        cancellable = controller.objectWillChange.sink { [weak self] _ in
            // objectWillChange fires before the property updates; hop a tick.
            DispatchQueue.main.async {
                guard let self else { return }
                self.renderIcon(for: self.controller.status)
            }
        }
    }

    func showLogsWindow() {
        if logsWindow == nil {
            let host = NSHostingController(rootView: LogsWindowView())
            let win = NSWindow(contentViewController: host)
            win.title = "Colima Logs"
            win.setContentSize(NSSize(width: 640, height: 400))
            win.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            win.isReleasedWhenClosed = false
            win.center()
            logsWindow = win
        }
        // LSUIElement apps don't auto-focus their windows; activate explicitly.
        NSApp.activate(ignoringOtherApps: true)
        logsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            Task { await controller.refresh() }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func renderIcon(for status: ColimaStatus) {
        guard let button = statusItem.button else { return }
        let running = controller.dockerStats?.running ?? 0
        let image = Self.makeStatusImage(color: Self.nsColor(for: status), runningContainers: running)
        image.isTemplate = false
        button.image = image
        if running > 0 {
            button.toolTip = "Colima — \(status.label) (\(running) container\(running == 1 ? "" : "s"))"
        } else {
            button.toolTip = "Colima — \(status.label)"
        }
    }

    private static func nsColor(for status: ColimaStatus) -> NSColor {
        switch status {
        case .running:  return .systemGreen
        case .starting, .stopping: return .systemYellow
        case .stopped:  return .systemRed
        case .unknown:  return .systemGray
        }
    }

    /// Draws a colored circle with a white "C" sized for the menu bar,
    /// plus an optional running-container count badge to its right.
    private static func makeStatusImage(color: NSColor, runningContainers: Int = 0) -> NSImage {
        let circleSize: CGFloat = 18
        let badgeText: NSAttributedString?
        let badgeWidth: CGFloat

        if runningContainers > 0 {
            let badgeFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
            let badgeAttrs: [NSAttributedString.Key: Any] = [
                .font: badgeFont,
                .foregroundColor: NSColor.controlTextColor
            ]
            let bt = NSAttributedString(string: "\(runningContainers)", attributes: badgeAttrs)
            badgeText = bt
            badgeWidth = 2 + bt.size().width   // 2pt gap between circle and number
        } else {
            badgeText = nil
            badgeWidth = 0
        }

        let size = NSSize(width: circleSize + badgeWidth, height: circleSize)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        // --- Colored circle with "C" ---
        let circleRect = NSRect(x: 0, y: 0, width: circleSize, height: circleSize).insetBy(dx: 1, dy: 1)
        color.setFill()
        NSBezierPath(ovalIn: circleRect).fill()

        let font = NSFont.systemFont(ofSize: 13, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let cText = NSAttributedString(string: "C", attributes: attrs)
        let textWidth = cText.size().width
        let baselineY = (circleSize - font.capHeight) / 2
        let point = NSPoint(
            x: (circleSize - textWidth) / 2,
            y: baselineY + font.descender
        )
        cText.draw(at: point)

        // --- Badge number ---
        if let badgeText {
            let badgeFont = badgeText.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
            let badgeY = (circleSize - badgeFont.capHeight) / 2 + badgeFont.descender
            badgeText.draw(at: NSPoint(x: circleSize + 2, y: badgeY))
        }

        return image
    }
}
