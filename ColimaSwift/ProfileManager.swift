import Foundation
import Observation
import ServiceManagement
import SwiftUI

@MainActor
@Observable
final class ProfileManager {
    private(set) var controllers: [ColimaController] = []
    var selectedProfile: String? = "default"
    var launchAtLogin: Bool = false
    var pollIntervalSeconds: Int = 5 {
        didSet {
            UserDefaults.standard.set(pollIntervalSeconds, forKey: pollIntervalDefaultsKey)
            restartAllPolling()
        }
    }
    var lastError: String?

    let colimaPath: String?
    let dockerPath: String?

    private let pollIntervalDefaultsKey = "pollIntervalSeconds"
    @ObservationIgnored private var discoveryTask: Task<Void, Never>?

    init() {
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

        discoveryTask = Task { [weak self] in
            guard let self else { return }
            await self.discoverProfiles()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                if Task.isCancelled { break }
                await self.discoverProfiles()
            }
        }
    }

    // MARK: - Aggregate status for menu bar icon

    var aggregateStatus: ColimaStatus {
        if controllers.contains(where: { $0.status == .running }) { return .running }
        if controllers.contains(where: { $0.status == .starting || $0.status == .stopping }) { return .starting }
        if controllers.contains(where: { $0.status == .stopped }) { return .stopped }
        return .unknown
    }

    var totalRunningContainers: Int {
        controllers.compactMap(\.dockerStats).reduce(0) { $0 + $1.running }
    }

    // MARK: - Profile discovery

    func discoverProfiles() async {
        guard let colimaPath else { return }
        do {
            let out = try await Shell.run(colimaPath, ["list", "--json"])
            let names: [String] = out.split(whereSeparator: \.isNewline).compactMap { line in
                guard let data = line.data(using: .utf8),
                      let inst = try? JSONDecoder().decode(ColimaInstance.self, from: data)
                else { return nil }
                return inst.name
            }

            let existingNames = Set(controllers.map(\.profile))
            let discoveredNames = Set(names)

            for name in names where !existingNames.contains(name) {
                let controller = ColimaController(profile: name, colimaPath: colimaPath, dockerPath: dockerPath)
                controllers.append(controller)
                controller.startPolling { [weak self] in self?.pollIntervalSeconds ?? 5 }
                LogStore.shared.append(.info, source: "app", "Discovered profile: \(name)")
            }

            for controller in controllers where !discoveredNames.contains(controller.profile) {
                controller.stopPolling()
                LogStore.shared.append(.info, source: "app", "Removed profile: \(controller.profile)")
            }
            controllers.removeAll { !discoveredNames.contains($0.profile) }

            controllers.sort { a, b in
                if a.profile == "default" { return true }
                if b.profile == "default" { return false }
                return a.profile < b.profile
            }
        } catch {
            // Discovery failure is non-fatal; existing controllers keep running
        }
    }

    func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for controller in controllers {
                group.addTask { await controller.refresh() }
            }
        }
    }

    // MARK: - Launch at login

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

    // MARK: - Private

    private func restartAllPolling() {
        for controller in controllers {
            controller.startPolling { [weak self] in self?.pollIntervalSeconds ?? 5 }
        }
    }
}
