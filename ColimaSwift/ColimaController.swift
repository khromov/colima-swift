import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class ColimaController {
    private(set) var status: ColimaStatus = .unknown
    private(set) var instance: ColimaInstance?
    private(set) var processMetrics: VMProcessMetrics?
    private(set) var dockerStats: DockerStats?
    private(set) var containers: [DockerContainer] = []
    private(set) var busy: Bool = false
    var lastError: String?

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
    /// Default profile uses "colima"; others use "colima-<name>".
    private var limaInstance: String {
        profile == "default" ? "colima" : "colima-\(profile)"
    }

    private var pollTask: Task<Void, Never>?
    private var eventsWatcher: DockerEventsWatcher?
    private var pendingEventRefresh: Task<Void, Never>?

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
                try? await Task.sleep(for: .seconds(seconds))
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
            self.processMetrics = await loadProcessMetrics()
            startEventsWatcherIfNeeded()
        } else {
            self.processMetrics = nil
            self.dockerStats = nil
            self.containers = []
            stopEventsWatcher()
        }
    }

    /// Fetches docker container stats + list in a single `docker ps -a` call.
    /// Called on watcher connect (to seed state) and on every debounced event
    /// burst.
    private func refreshDockerState() async {
        guard let dockerPath else {
            self.dockerStats = nil
            self.containers = []
            return
        }
        do {
            let out = try await Shell.run(dockerPath, [
                "--context", dockerContext,
                "ps", "-a",
                "--format", "{{.State}}\t{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}",
            ])

            var total = 0
            var running = 0
            var runningContainers: [DockerContainer] = []

            for line in out.split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: "\t", maxSplits: 4).map(String.init)
                guard parts.count >= 5 else { continue }
                total += 1
                let state = parts[0]
                if state == "running" {
                    running += 1
                    runningContainers.append(
                        DockerContainer(id: parts[1], name: parts[2], image: parts[3], status: parts[4])
                    )
                }
            }

            self.dockerStats = DockerStats(total: total, running: running)
            self.containers = runningContainers
        } catch {
            self.dockerStats = nil
            self.containers = []
        }
    }

    // MARK: - Docker events

    private func startEventsWatcherIfNeeded() {
        guard eventsWatcher == nil, let dockerPath else { return }
        let watcher = DockerEventsWatcher(
            dockerPath: dockerPath,
            dockerContext: dockerContext,
            profile: profile
        ) { [weak self] in
            self?.scheduleEventRefresh()
        }
        eventsWatcher = watcher
        watcher.start()
    }

    private func stopEventsWatcher() {
        eventsWatcher?.stop()
        eventsWatcher = nil
        pendingEventRefresh?.cancel()
        pendingEventRefresh = nil
    }

    /// Debounce rapid event bursts (e.g. `docker compose up`) into a single
    /// refresh. If a refresh is already pending, this is a no-op.
    private func scheduleEventRefresh() {
        if pendingEventRefresh != nil { return }
        pendingEventRefresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self, !Task.isCancelled else { return }
            self.pendingEventRefresh = nil
            guard self.status == .running else { return }
            await self.refreshDockerState()
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

}
