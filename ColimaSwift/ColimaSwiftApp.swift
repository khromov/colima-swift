import SwiftUI
import AppKit

@main
struct ColimaSwiftApp: App {
    @State private var manager = ProfileManager()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environment(manager)
                .task { await manager.refreshAll() }
        } label: {
            Image(nsImage: StatusIcon.image(
                color: StatusIcon.nsColor(for: manager.aggregateStatus),
                runningContainers: manager.totalRunningContainers
            ))
        }
        .menuBarExtraStyle(.window)

        Window("Colima Logs", id: "logs") {
            LogsWindowView()
        }
        .windowResizability(.contentSize)
    }
}

enum StatusIcon {
    static func nsColor(for status: ColimaStatus) -> NSColor {
        switch status {
        case .running:  return .systemGreen
        case .starting, .stopping: return .systemYellow
        case .stopped:  return .systemRed
        case .unknown:  return .systemGray
        }
    }

    /// Draws a colored circle with a white "C" sized for the menu bar.
    /// When `runningContainers > 0`, draws a tiny count badge in the bottom-right corner.
    static func image(color: NSColor, runningContainers: Int = 0) -> NSImage {
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
        let textWidth = text.size().width
        let baselineY = (size.height - font.capHeight) / 2
        let point = NSPoint(
            x: (size.width - textWidth) / 2,
            y: baselineY + font.descender
        )
        text.draw(at: point)

        if runningContainers > 0 {
            let badgeFont = NSFont.monospacedDigitSystemFont(ofSize: 6, weight: .bold)
            let badgeAttrs: [NSAttributedString.Key: Any] = [
                .font: badgeFont,
                .foregroundColor: NSColor.white
            ]
            let badgeStr = NSAttributedString(string: "\(runningContainers)", attributes: badgeAttrs)
            let badgeSize = badgeStr.size()
            let padding: CGFloat = 0.5
            let side = max(badgeSize.width, badgeSize.height) + padding * 2
            let badgeRect = NSRect(
                x: size.width - side + 3,
                y: -2,
                width: side,
                height: side
            )
            NSColor.black.setFill()
            NSBezierPath(rect: badgeRect).fill()
            let textX = badgeRect.midX - badgeSize.width / 2
            let textY = badgeRect.midY - badgeFont.capHeight / 2 + badgeFont.descender
            badgeStr.draw(at: NSPoint(x: textX, y: textY))
        }

        return image
    }
}
