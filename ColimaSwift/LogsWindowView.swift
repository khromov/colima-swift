import SwiftUI

struct LogsWindowView: View {
    @ObservedObject private var store = LogStore.shared
    @State private var followLog: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("\(store.entries.count) entries")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { store.clear() }
                Toggle("Follow log", isOn: $followLog)
                    .toggleStyle(.checkbox)
            }
            .padding(8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    // Non-lazy VStack so every row is realized — proxy.scrollTo
                    // can target any id without waiting for layout. The 1000-entry
                    // cap keeps this affordable.
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(store.entries) { entry in
                            row(entry).id(entry.id)
                        }
                        // Bottom visual gap, part of the scrollable content so the
                        // sentinel (below) includes it as the true "end of content".
                        Color.clear.frame(height: 8)
                        // Stable scroll target — always the end of the log.
                        Color.clear.frame(height: 1).id(Self.bottomID)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: store.entries.count) { _ in
                    guard followLog else { return }
                    // Defer one runloop tick so the new row is laid out before we
                    // ask the proxy to scroll to the sentinel past it.
                    DispatchQueue.main.async {
                        proxy.scrollTo(Self.bottomID, anchor: .bottom)
                    }
                }
                .onChange(of: followLog) { newValue in
                    if newValue {
                        proxy.scrollTo(Self.bottomID, anchor: .bottom)
                    }
                }
                .onAppear {
                    if followLog {
                        proxy.scrollTo(Self.bottomID, anchor: .bottom)
                    }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 240)
    }

    private func row(_ entry: LogEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Self.timeFormatter.string(from: entry.timestamp))
                .foregroundStyle(.secondary)
            Text(entry.source)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(entry.message)
                .foregroundStyle(color(for: entry.level))
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, design: .monospaced))
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .info:  return .primary
        case .warn:  return .orange
        case .error: return .red
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static let bottomID = "logs.bottom"
}
