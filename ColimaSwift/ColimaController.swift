import Foundation
import SwiftUI

@MainActor
final class ColimaController: ObservableObject {
    @Published private(set) var status: ColimaStatus = .unknown
    @Published private(set) var instance: ColimaInstance?
    @Published private(set) var processMetrics: VMProcessMetrics?
    @Published private(set) var dockerStats: DockerStats?
    @Published private(set) var containers: [DockerContainer] = []
    @Published private(set) var busy: Bool = false
    @Published var lastError: String?

    let profile: String
    let colimaPath: String?
    let dockerPath: String?
    private let psPath = "/bin/ps"

    /// The docker context name for this profile.
    /// Default profile uses "colima"; others use "colima-<name>".
    private var dockerContext: String {
        profile == "default" ? "colima" : "colima-\(profile)"
    }

    /// The Lima directory name for this profile.
    /// Default profile uses "default"; others use "colima-<name>".
    private var limaInstance: String {
        profile == "default" ? "default" : "colima-\(profile)"
    }

    private var pollTask: Task<Void, Never>?

    init(profile: String = "default", colimaPath: String?, dockerPath: String?) {
        self.profile = profile
        self.colimaPath = colimaPath
        self.dockerPath = dockerPath
        LogStore.shared.append(.info, source: "ctrl[\(profile)]", "ColimaController initialized for profile '\(profile)'")
    }

    func startPolling(intervalProvider: @escaping () -> Int) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            await self.refresh()
            while !Task.isCancelled {
                let seconds = max(1, intervalProvider())
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                if Task.isCancelled { break }
                if !self.busy {
                    await self.refresh()
                }
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    deinit {
        pollTask?.cancel()
    }

    // MARK: - Actions

    func start()   { perform(action: "start",   transient: .starting) }
    func stop()    { perform(action: "stop",    transient: .stopping) }
    func restart() { perform(action: "restart", transient: .starting) }

    private func perform(action: String, transient: ColimaStatus) {
        guard !busy else { return }
        guard let colimaPath else {
            lastError = "colima not found — cannot \(action). Install colima and relaunch."
            LogStore.shared.append(.error, source: "ctrl[\(profile)]", "Action \(action) aborted: colima not resolved")
            return
        }
        busy = true
        status = transient
        LogStore.shared.append(.info, source: "ctrl[\(profile)]", "User: \(action)")
        Task {
            defer {
                Task { @MainActor in
                    self.busy = false
                    await self.refresh()
                }
            }
            do {
                _ = try await Shell.runStreaming(colimaPath, [action, "--profile", profile], source: "colima[\(profile)]")
                lastError = nil
                LogStore.shared.append(.info, source: "ctrl[\(profile)]", "Action complete: \(action)")
            } catch ShellError.nonZeroExit(_, let stderr) {
                let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                lastError = trimmed
                LogStore.shared.append(.error, source: "ctrl[\(profile)]", "Action failed: \(action) — \(trimmed)")
            } catch {
                lastError = "\(error)"
                LogStore.shared.append(.error, source: "ctrl[\(profile)]", "Action failed: \(action) — \(error)")
            }
        }
    }

    // MARK: - Refresh

    func refresh() async {
        let inst = await loadInstance()
        let newStatus: ColimaStatus = inst.map { ColimaStatus(rawColimaStatus: $0.status) } ?? .stopped
        let oldStatus = self.status
        self.instance = inst
        self.status = newStatus
        if oldStatus != newStatus {
            LogStore.shared.append(.info, source: "ctrl[\(profile)]", "Status: \(oldStatus.label) → \(newStatus.label)")
        }

        if newStatus == .running {
            async let metrics = loadProcessMetrics()
            async let docker  = loadDockerStats()
            async let ctrs    = loadContainers()
            self.processMetrics = await metrics
            self.dockerStats    = await docker
            self.containers     = await ctrs
        } else {
            self.processMetrics = nil
            self.dockerStats = nil
            self.containers = []
        }
    }

    private func loadInstance() async -> ColimaInstance? {
        guard let colimaPath else { return nil }
        do {
            let out = try await Shell.run(colimaPath, ["list", "--json"])
            for line in out.split(whereSeparator: \.isNewline) {
                guard let data = line.data(using: .utf8) else { continue }
                if let inst = try? JSONDecoder().decode(ColimaInstance.self, from: data),
                   inst.name == profile {
                    return inst
                }
            }
            return nil
        } catch {
            return nil
        }
    }

    private func loadProcessMetrics() async -> VMProcessMetrics? {
        let pidPath = ("~/.colima/_lima/\(limaInstance)/vz.pid" as NSString).expandingTildeInPath
        guard let pidStr = try? String(contentsOfFile: pidPath, encoding: .utf8),
              let pid = Int(pidStr.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }

        do {
            let out = try await Shell.run(psPath, ["-o", "%cpu=,rss=", "-p", "\(pid)"])
            let parts = out.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2,
                  let cpu = Double(parts[0]),
                  let rssKb = Int64(parts[1])
            else { return nil }
            return VMProcessMetrics(cpuPercent: cpu, residentBytes: rssKb * 1024)
        } catch {
            return nil
        }
    }

    private func loadDockerStats() async -> DockerStats? {
        guard let dockerPath else { return nil }
        do {
            let out = try await Shell.run(dockerPath, ["--context", dockerContext, "ps", "-a", "--format", "{{.State}}"])
            let lines = out.split(whereSeparator: \.isNewline).map(String.init)
            let total = lines.count
            let running = lines.filter { $0 == "running" }.count
            return DockerStats(total: total, running: running)
        } catch {
            return nil
        }
    }

    private func loadContainers() async -> [DockerContainer] {
        guard let dockerPath else { return [] }
        do {
            let out = try await Shell.run(dockerPath, ["--context", dockerContext, "ps", "--format", "{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}"])
            return out.split(whereSeparator: \.isNewline).compactMap { line in
                let parts = line.split(separator: "\t", maxSplits: 3).map(String.init)
                guard parts.count >= 4 else { return nil }
                return DockerContainer(id: parts[0], name: parts[1], image: parts[2], status: parts[3])
            }
        } catch {
            return []
        }
    }
}
