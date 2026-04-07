import SwiftUI

struct MenuContentView: View {
    @EnvironmentObject var controller: ColimaController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Divider()
            metrics
            Divider()
            actions
            Divider()
            footer
        }
        .padding(10)
        .frame(width: 270)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(controller.status.color)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.status.label)
                    .font(.headline)
                if let inst = controller.instance {
                    Text("\(inst.name) · \(inst.runtime) · \(inst.arch)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No instance")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    // MARK: - Metrics

    private var metrics: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let inst = controller.instance {
                row("CPUs",   "\(inst.cpus)")
                row("Memory", Self.formatBytes(inst.memory))
                row("Disk",   Self.formatBytes(inst.disk))
            }
            if let m = controller.processMetrics {
                row("Host agent CPU", String(format: "%.1f %%", m.cpuPercent))
                row("Host agent RSS", Self.formatBytes(m.residentBytes))
            }
            if let d = controller.dockerStats {
                row("Containers", "\(d.running) running / \(d.total) total")
            }
            if controller.instance == nil && controller.processMetrics == nil {
                Text("Start Colima to see metrics.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
        }
        .font(.system(size: 12))
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Button("Start") { controller.start() }
                    .disabled(controller.busy || controller.status == .running)
                    .frame(maxWidth: .infinity)
                Button("Stop") { controller.stop() }
                    .disabled(controller.busy || controller.status != .running)
                    .frame(maxWidth: .infinity)
                Button("Restart") { controller.restart() }
                    .disabled(controller.busy || controller.status != .running)
                    .frame(maxWidth: .infinity)
            }

            if let err = controller.lastError, !err.isEmpty {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Launch at login", isOn: Binding(
                get: { controller.launchAtLogin },
                set: { controller.setLaunchAtLogin($0) }
            ))
            .toggleStyle(.checkbox)
            .font(.system(size: 11))

            HStack(spacing: 12) {
                Text("Refresh")
                    .foregroundStyle(controller.busy ? Color.secondary.opacity(0.5) : .secondary)
                    .onTapGesture {
                        guard !controller.busy else { return }
                        Task { await controller.refresh() }
                    }
                Text("Logs")
                    .foregroundStyle(.secondary)
                    .onTapGesture { AppDelegate.shared?.showLogsWindow() }
                Spacer()
                Text("Quit")
                    .foregroundStyle(.secondary)
                    .onTapGesture { NSApplication.shared.terminate(nil) }
            }
            .font(.system(size: 11))
        }
        .padding(.horizontal, 6)
    }

    // MARK: - Helpers

    private static func formatBytes(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useGB, .useMB, .useKB]
        f.countStyle = .binary
        return f.string(fromByteCount: bytes)
    }
}
