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
        let commandLine = ([dockerPath] + args).joined(separator: " ")
        LogStore.shared.append(.info, source: logSource, "connecting")
        LogStore.shared.append(.info, source: "shell", "→ \(commandLine)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: dockerPath)
        process.arguments = args

        var env = ProcessInfo.processInfo.environment
        let extras = Shell.searchDirs.joined(separator: ":")
        env["PATH"] = env["PATH"].map { "\($0):\(extras)" } ?? extras
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        currentProcess = process
        defer {
            if process.isRunning { process.terminate() }
            currentProcess = nil
        }

        do {
            try process.run()
        } catch {
            throw ShellError.launchFailed("\(error)")
        }

        // Seed the callback once on (re)connect so consumers pick up the
        // current container state even if no events ever fire.
        onContainerEvent()

        let source = logSource
        async let _: Void = {
            for await line in AsyncLineReader(handle: errPipe.fileHandleForReading) {
                let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
                if !trimmed.isEmpty {
                    LogStore.log(.error, source: source, "  │ \(trimmed)")
                }
            }
        }()

        var sawFirstLine = false
        for await line in AsyncLineReader(handle: outPipe.fileHandleForReading) {
            if !sawFirstLine {
                sawFirstLine = true
                LogStore.shared.append(.info, source: logSource, "connected")
            }
            let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if !trimmed.isEmpty {
                LogStore.shared.append(.info, source: logSource, "  │ \(trimmed)")
            }
            onContainerEvent()
            if Task.isCancelled { break }
        }

        process.waitUntilExit()
        let code = process.terminationStatus
        if code != 0 && !Task.isCancelled {
            throw ShellError.nonZeroExit(code: code, stderr: "")
        }
    }

    /// Exponential backoff with ±20% jitter, capped at 30s.
    private func backoffDelay(attempt: Int) -> Double {
        let base = min(30.0, pow(2.0, Double(attempt)))
        let jitter = Double.random(in: 0.8...1.2)
        return base * jitter
    }
}
