import SwiftUI

struct MenuContentView: View {
    @EnvironmentObject var manager: ProfileManager
    @State private var showSettings: Bool = false
    @State private var copyToast: String?

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 0) {
                if manager.controllers.isEmpty {
                    Text("No Colima profiles found")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(10)
                } else {
                    ForEach(Array(manager.controllers.enumerated()), id: \.element.profile) { index, controller in
                        if index > 0 { Divider() }
                        ProfileCardView(
                            controller: controller,
                            isExpanded: manager.selectedProfile == controller.profile,
                            copyToast: $copyToast
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                if manager.selectedProfile == controller.profile {
                                    manager.selectedProfile = nil
                                } else {
                                    manager.selectedProfile = controller.profile
                                }
                            }
                        }
                    }
                }

                Divider()
                footer
                if showSettings {
                    Divider()
                    settingsPanel
                }
            }
            .padding(10)
            .frame(width: 230)

            if let toast = copyToast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(.black.opacity(0.75)))
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                        .padding(.bottom, 8)
                }
                .allowsHitTesting(false)
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
                get: { manager.launchAtLogin },
                set: { manager.setLaunchAtLogin($0) }
            )) {
                Text("Start on boot")
                    .padding(.leading, 4)
            }
            .toggleStyle(.checkbox)
            .controlSize(.mini)

            HStack(spacing: 6) {
                Text("Refresh every")
                TextField("", value: $manager.pollIntervalSeconds, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.mini)
                    .frame(width: 40)
                Text("seconds")
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 6)
    }
}

// MARK: - Profile Card

private struct ProfileCardView: View {
    @ObservedObject var controller: ColimaController
    let isExpanded: Bool
    @Binding var copyToast: String?
    @AppStorage("showContainers") private var showContainers: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Collapsed header — always visible
            HStack(spacing: 8) {
                Circle()
                    .fill(controller.status.color)
                    .frame(width: 10, height: 10)
                Text(controller.profile)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if let inst = controller.instance {
                    Text("\(inst.runtime) · \(inst.arch)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .foregroundStyle(.tertiary)
                    .font(.system(size: 9))
            }

            // Expanded detail
            if isExpanded {
                Divider()
                metrics
                Divider()
                actions
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Metrics

    private var metrics: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let inst = controller.instance {
                row("CPUs",   "\(inst.cpus)")
                row("Memory", formatBytes(inst.memory))
                row("Disk",   formatBytes(inst.disk))
            }
            if let m = controller.processMetrics {
                row("Host agent CPU", String(format: "%.1f %%", m.cpuPercent))
                row("Host agent RSS", formatBytes(m.residentBytes))
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
                                    .copyable { copy(c.name) }
                                Spacer(minLength: 2)
                                Text(c.image)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: 80, alignment: .trailing)
                                    .help(c.image)
                                    .copyable { copy(c.image) }
                                Image(systemName: "apple.terminal")
                                    .foregroundStyle(.secondary)
                                    .font(.system(size: 8))
                                    .help("Copy: docker exec -it \(c.id) sh")
                                    .copyable { copy("docker exec -it \(c.id) sh") }
                            }
                        }
                    }
                    .font(.system(size: 10))
                    .padding(.leading, 4)
                }
            }
            if controller.instance == nil && controller.processMetrics == nil {
                Text("Start this profile to see metrics.")
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

    // MARK: - Helpers

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let label = text.count > 30 ? String(text.prefix(30)) + "…" : text
        withAnimation(.easeInOut(duration: 0.15)) { copyToast = "Copied: \(label)" }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation(.easeInOut(duration: 0.2)) { copyToast = nil }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useGB, .useMB, .useKB]
        f.countStyle = .binary
        return f.string(fromByteCount: bytes)
    }
}

private extension View {
    /// Makes an element look and behave as a clickable copy target.
    func copyable(action: @escaping () -> Void) -> some View {
        self
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .onTapGesture(perform: action)
    }
}
