import Foundation
import ServiceManagement
import SwiftUI

@MainActor
final class ColimaController: ObservableObject {
    @Published private(set) var status: ColimaStatus = .unknown
    @Published private(set) var instance: ColimaInstance?
    @Published private(set) var processMetrics: VMProcessMetrics?
    @Published private(set) var dockerStats: DockerStats?
    @Published private(set) var busy: Bool = false
    @Published var lastError: String?
    @Published var launchAtLogin: Bool = false
    @Published var pollIntervalSeconds: Int = 5 {
        didSet { UserDefaults.standard.set(pollIntervalSeconds, forKey: pollIntervalDefaultsKey) }
    }

    private let colimaPath: String?
    private let dockerPath: String?
    private let psPath     = "/bin/ps"
    private let profile    = "default"
    private let pollIntervalDefaultsKey = "pollIntervalSeconds"

    private var pollTask: Task<Void, Never>?

    init() {
        LogStore.shared.append(.info, source: "app", "ColimaController initialized")

        // Resolve external tools once at startup. `ps` is POSIX and always
        // at /bin/ps, but colima and docker may live in any of several
        // Homebrew / MacPorts / Nix / custom locations.
        let resolvedColima = Shell.resolveTool("colima")
        let resolvedDocker = Shell.resolveTool("docker")
        self.colimaPath = resolvedColima
        self.dockerPath = resolvedDocker

        if let resolvedColima {
            LogStore.shared.append(.info, source: "app", "Resolved colima → \(resolvedColima)")
        } else {
            let msg = "colima not found. Install it (e.g. `brew install colima`) or add its directory to your PATH, then relaunch ColimaSwift."
            self.lastError = msg
            LogStore.shared.append(.error, source: "app", msg)
        }
        if let resolvedDocker {
            LogStore.shared.append(.info, source: "app", "Resolved docker → \(resolvedDocker)")
        } else {
            LogStore.shared.append(.warn, source: "app", "docker not found in known locations; container counts will be unavailable")
        }

        self.launchAtLogin = (SMAppService.mainApp.status == .enabled)
        if let saved = UserDefaults.standard.object(forKey: pollIntervalDefaultsKey) as? Int {
            self.pollIntervalSeconds = max(1, saved)
        }
        pollTask = Task { [weak self] in
            guard let self else { return }
            await self.refresh()
            while !Task.isCancelled {
                let seconds = max(1, self.pollIntervalSeconds)
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                if Task.isCancelled { break }
                if !self.busy {
                    await self.refresh()
                }
            }
        }
    }

    deinit {
        pollTask?.cancel()
    }

    // MARK: - Actions

    func start()   { perform(action: "start",   transient: .starting) }
    func stop()    { perform(action: "stop",    transient: .stopping) }
    func restart() { perform(action: "restart", transient: .starting) }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status != .notRegistered {
                    try SMAppService.mainApp.unregister()
                }
            }
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
            LogStore.shared.append(.info, source: "app", "Launch at login: \(launchAtLogin)")
        } catch {
            lastError = "Launch at login failed: \(error.localizedDescription)"
            LogStore.shared.append(.error, source: "app", "Launch at login error: \(error)")
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        }
    }

    private func perform(action: String, transient: ColimaStatus) {
        guard !busy else { return }
        guard let colimaPath else {
            lastError = "colima not found — cannot \(action). Install colima and relaunch."
            LogStore.shared.append(.error, source: "controller", "Action \(action) aborted: colima not resolved")
            return
        }
        busy = true
        status = transient
        LogStore.shared.append(.info, source: "controller", "User: \(action)")
        Task {
            defer {
                Task { @MainActor in
                    self.busy = false
                    await self.refresh()
                }
            }
            do {
                _ = try await Shell.runStreaming(colimaPath, [action], source: "colima")
                lastError = nil
                LogStore.shared.append(.info, source: "controller", "Action complete: \(action)")
            } catch ShellError.nonZeroExit(_, let stderr) {
                let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                lastError = trimmed
                LogStore.shared.append(.error, source: "controller", "Action failed: \(action) — \(trimmed)")
            } catch {
                lastError = "\(error)"
                LogStore.shared.append(.error, source: "controller", "Action failed: \(action) — \(error)")
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
            LogStore.shared.append(.info, source: "controller", "Status: \(oldStatus.label) → \(newStatus.label)")
        }

        if newStatus == .running {
            async let metrics = loadProcessMetrics()
            async let docker  = loadDockerStats()
            self.processMetrics = await metrics
            self.dockerStats    = await docker
        } else {
            self.processMetrics = nil
            self.dockerStats = nil
        }
    }

    private func loadInstance() async -> ColimaInstance? {
        guard let colimaPath else { return nil }
        do {
            let out = try await Shell.run(colimaPath, ["list", "--json"])
            // `colima list --json` emits one JSON object per line.
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
        // Lima writes the VM host-agent pid to ~/.colima/_lima/<profile>/vz.pid
        let pidPath = ("~/.colima/_lima/\(profile)/vz.pid" as NSString).expandingTildeInPath
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
            let out = try await Shell.run(dockerPath, ["ps", "-a", "--format", "{{.State}}"])
            let lines = out.split(whereSeparator: \.isNewline).map(String.init)
            let total = lines.count
            let running = lines.filter { $0 == "running" }.count
            return DockerStats(total: total, running: running)
        } catch {
            return nil
        }
    }
}
