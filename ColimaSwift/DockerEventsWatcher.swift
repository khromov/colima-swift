import Foundation

/// Subscribes to `docker events` for a given colima profile and invokes a
/// callback whenever a container event occurs. Reconnects automatically with
/// exponential backoff if the stream drops (daemon hiccup, colima restart,
/// context unavailable, etc.).
@MainActor
final class DockerEventsWatcher {
    private let dockerPath: String
    private let dockerContext: String
    private let profile: String
    private let onContainerEvent: @MainActor () -> Void

    private var runTask: Task<Void, Never>?
    private var currentProcess: Process?

    /// `true` once `start()` has been called; `stop()` clears it and aborts
    /// any pending reconnect.
    private var wanted: Bool = false

    private var logSource: String { "events[\(profile)]" }

    init(dockerPath: String,
         dockerContext: String,
         profile: String,
         onContainerEvent: @MainActor @escaping () -> Void)
    {
        self.dockerPath = dockerPath
        self.dockerContext = dockerContext
        self.profile = profile
        self.onContainerEvent = onContainerEvent
    }

    func start() {
        guard !wanted else { return }
        wanted = true
        LogStore.shared.append(.info, source: logSource, "starting")
        runTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    func stop() {
        guard wanted else { return }
        wanted = false
        LogStore.shared.append(.info, source: logSource, "stopped")
        runTask?.cancel()
        runTask = nil
        if let p = currentProcess, p.isRunning {
            p.terminate()
        }
        currentProcess = nil
    }

    // MARK: - Private

    private func runLoop() async {
        var attempt = 0
        while wanted && !Task.isCancelled {
            let connectedAt = Date()
            do {
                try await runOnce()
                // Stream ended cleanly (non-error). Fall through to backoff
                // because `docker events` is expected to be long-lived —
                // clean exit usually means the daemon went away.
            } catch {
                LogStore.shared.append(.error, source: logSource,
                                       "stream error: \(error)")
            }

            guard wanted && !Task.isCancelled else { break }

            // Reset attempt counter if the connection was "good" (≥10s).
            let held = Date().timeIntervalSince(connectedAt)
            if held >= 10 {
                attempt = 0
            }

            let delay = backoffDelay(attempt: attempt)
            attempt += 1
            LogStore.shared.append(.info, source: logSource,
                                   String(format: "reconnecting in %.1fs (attempt %d)", delay, attempt))
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    /// Runs one `docker events` subscription until it terminates. Returns
    /// normally on clean exit; throws on stream error.
    private func runOnce() async throws {
        let args = [
            "--context", dockerContext,
            "events",
            "--filter", "type=container",
            "--format", "{{json .}}",
        ]
        LogStore.shared.append(.info, source: logSource, "connecting")
        let (process, lines) = Shell.stream(dockerPath, args, source: logSource)
        currentProcess = process
        defer {
            if process.isRunning { process.terminate() }
            currentProcess = nil
        }

        // Seed the callback once on (re)connect so consumers pick up the
        // current container state even if no events ever fire.
        onContainerEvent()

        var sawFirstLine = false
        for try await _ in lines {
            if !sawFirstLine {
                sawFirstLine = true
                LogStore.shared.append(.info, source: logSource, "connected")
            }
            onContainerEvent()
            if Task.isCancelled { break }
        }
    }

    /// Exponential backoff with ±20% jitter, capped at 30s.
    private func backoffDelay(attempt: Int) -> Double {
        let base = min(30.0, pow(2.0, Double(attempt)))
        let jitter = Double.random(in: 0.8...1.2)
        return base * jitter
    }
}
