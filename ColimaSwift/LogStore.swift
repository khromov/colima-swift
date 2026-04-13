import Foundation
import Observation

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
@Observable
final class LogStore {
    static let shared = LogStore()

    private(set) var entries: [LogEntry] = []
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

    nonisolated static func log(_ level: LogLevel, source: String, _ message: String) {
        Task { @MainActor in
            LogStore.shared.append(level, source: source, message)
        }
    }
}
