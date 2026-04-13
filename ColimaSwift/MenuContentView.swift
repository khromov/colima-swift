import SwiftUI

struct MenuContentView: View {
    @EnvironmentObject var controller: ColimaController
    @State private var showSettings: Bool = false
    @State private var showContainers: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Divider()
            metrics
            Divider()
            actions
            Divider()
            footer
            if showSettings {
                Divider()
                settingsPanel
            }
        }
        .padding(10)
        .frame(width: 230)
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
                HStack {
                    Text("Containers")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(d.running) running / \(d.total) total")
                        .monospacedDigit()
                    if !controller.containers.isEmpty {
                        Image(systemName: showContainers ? "chevron.up" : "chevron.down")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 9))
                    }
                }
                .font(.system(size: 12))
                .contentShape(Rectangle())
                .onTapGesture {
                    if !controller.containers.isEmpty {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showContainers.toggle()
                        }
                    }
                }

                if showContainers {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(controller.containers, id: \.id) { c in
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(.green)
                                    .frame(width: 6, height: 6)
                                Text(c.name)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .help(c.name)
                                    .onTapGesture { Self.copyToClipboard(c.name) }
                                Image(systemName: "terminal")
                                    .foregroundStyle(.secondary)
                                    .font(.system(size: 8))
                                    .help("Copy docker exec command")
                                    .onTapGesture { Self.copyToClipboard("docker exec -it \(c.id) sh") }
                                Spacer(minLength: 2)
                                Text(c.image)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: 80, alignment: .trailing)
                                    .help(c.image)
                                    .onTapGesture { Self.copyToClipboard(c.image) }
                            }
                        }
                    }
                    .font(.system(size: 10))
                    .padding(.leading, 4)
                }
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
        HStack(spacing: 12) {
            Text("Logs")
                .foregroundStyle(.secondary)
                .onTapGesture { AppDelegate.shared?.showLogsWindow() }
            Text("Settings")
                .foregroundStyle(.secondary)
                .onTapGesture { showSettings.toggle() }
            Spacer()
            Text("Quit")
                .foregroundStyle(.secondary)
                .onTapGesture { NSApplication.shared.terminate(nil) }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 6)
    }

    // MARK: - Settings Panel

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { controller.launchAtLogin },
                set: { controller.setLaunchAtLogin($0) }
            )) {
                Text("Start on boot")
                    .padding(.leading, 4)
            }
            .toggleStyle(.checkbox)
            .controlSize(.mini)

            HStack(spacing: 6) {
                Text("Refresh every")
                TextField("", value: $controller.pollIntervalSeconds, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.mini)
                    .frame(width: 40)
                Text("seconds")
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 6)
    }

    // MARK: - Helpers

    private static func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useGB, .useMB, .useKB]
        f.countStyle = .binary
        return f.string(fromByteCount: bytes)
    }
}
