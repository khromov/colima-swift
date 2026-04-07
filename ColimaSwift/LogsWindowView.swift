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
                    }
                    .padding(8)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: store.entries.count) { _ in
                    guard followLog, let last = store.entries.last else { return }
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
                .onChange(of: followLog) { newValue in
                    if newValue, let last = store.entries.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .onAppear {
                    if followLog, let last = store.entries.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
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
}
