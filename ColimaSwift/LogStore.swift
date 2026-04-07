import Foundation
import SwiftUI

enum LogLevel {
    case info, warn, error
}

struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let level: LogLevel
    let source: String
    let message: String
}

@MainActor
final class LogStore: ObservableObject {
    static let shared = LogStore()

    @Published private(set) var entries: [LogEntry] = []
    private let cap = 1000

    func append(_ level: LogLevel, source: String, _ message: String) {
        entries.append(LogEntry(timestamp: Date(), level: level, source: source, message: message))
        if entries.count > cap {
            entries.removeFirst(entries.count - cap)
        }
    }

    func clear() {
        entries.removeAll()
    }

    /// Bridge for non-isolated callers (e.g. Process termination handlers on background threads).
    nonisolated static func log(_ level: LogLevel, source: String, _ message: String) {
        Task { @MainActor in
            LogStore.shared.append(level, source: source, message)
        }
    }
}
