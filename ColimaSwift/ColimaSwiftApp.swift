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
        let image = Self.makeStatusImage(color: Self.nsColor(for: status))
        image.isTemplate = false
        button.image = image
        button.toolTip = "Colima — \(status.label)"
    }

    private static func nsColor(for status: ColimaStatus) -> NSColor {
        switch status {
        case .running:  return .systemGreen
        case .starting, .stopping: return .systemYellow
        case .stopped:  return .systemRed
        case .unknown:  return .systemGray
        }
    }

    /// Draws a colored circle with a white "C" sized for the menu bar.
    private static func makeStatusImage(color: NSColor) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        let rect = NSRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
        color.setFill()
        NSBezierPath(ovalIn: rect).fill()

        let font = NSFont.systemFont(ofSize: 13, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let text = NSAttributedString(string: "C", attributes: attrs)
        // Center on cap-height rather than line-height so the glyph sits visually
        // mid-circle. NSAttributedString.draw(at:) places the line box's bottom-left
        // at `point` in a Y-up context; the baseline sits at point.y + |descender|.
        let textWidth = text.size().width
        let baselineY = (size.height - font.capHeight) / 2
        let point = NSPoint(
            x: (size.width - textWidth) / 2,
            y: baselineY + font.descender
        )
        text.draw(at: point)
        return image
    }
}
