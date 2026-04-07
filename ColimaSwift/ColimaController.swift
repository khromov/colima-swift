import Foundation
import SwiftUI

@MainActor
final class ColimaController: ObservableObject {
    @Published private(set) var status: ColimaStatus = .unknown
    @Published private(set) var instance: ColimaInstance?
    @Published private(set) var processMetrics: VMProcessMetrics?
    @Published private(set) var dockerStats: DockerStats?
    @Published private(set) var busy: Bool = false
    @Published private(set) var lastError: String?

    private let colimaPath = "/opt/homebrew/bin/colima"
    private let dockerPath = "/opt/homebrew/bin/docker"
    private let psPath     = "/bin/ps"
    private let profile    = "default"
    private let pollInterval: UInt64 = 5 * 1_000_000_000  // 5 s

    private var pollTask: Task<Void, Never>?

    init() {
        pollTask = Task { [weak self] in
            guard let self else { return }
            await self.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: self.pollInterval)
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

    private func perform(action: String, transient: ColimaStatus) {
        guard !busy else { return }
        busy = true
        status = transient
        Task {
            defer {
                Task { @MainActor in
                    self.busy = false
                    await self.refresh()
                }
            }
            do {
                _ = try await Shell.run(colimaPath, [action])
                lastError = nil
            } catch ShellError.nonZeroExit(_, let stderr) {
                lastError = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                lastError = "\(error)"
            }
        }
    }

    // MARK: - Refresh

    func refresh() async {
        let inst = await loadInstance()
        let newStatus: ColimaStatus = inst.map { ColimaStatus(rawColimaStatus: $0.status) } ?? .stopped
        self.instance = inst
        self.status = newStatus

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
