import Foundation
import Subprocess
import System

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
    }

    // MARK: - Private

    private func runLoop() async {
        var attempt = 0
        while wanted && !Task.isCancelled {
            let connectedAt = Date()
            do {
                try await runOnce()
            } catch is CancellationError {
                break
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

        let source = logSource
        let onEvent = onContainerEvent

        // Seed the callback once on (re)connect so consumers pick up the
        // current container state even if no events ever fire.
        onEvent()

        // `preferredBufferSize: 256` is a workaround for swift-subprocess 0.4.0
        // on Darwin: its DispatchIO-backed reader only resumes the async
        // continuation when the full `length` has been read (see
        // AsyncIO+Dispatch.swift). With the default ~16KB buffer, a
        // low-volume stream like `docker events` never fills the buffer and
        // lines never arrive. A small buffer size forces promptly-delivered
        // chunks; `lines()` reassembles them across reads.
        let outcome = try await Subprocess.run(
            .path(FilePath(dockerPath)),
            arguments: Arguments(args),
            environment: Shell.subprocessEnvironment,
            preferredBufferSize: 256
        ) { _, _, outputSequence, errorSequence in
            async let _: Void = Shell.streamLines(errorSequence, source: source)

            var sawFirstLine = false
            for try await line in outputSequence.lines(encoding: UTF8.self) {
                if !sawFirstLine {
                    sawFirstLine = true
                    await MainActor.run {
                        LogStore.shared.append(.info, source: source, "connected")
                    }
                }
                let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
                if !trimmed.isEmpty {
                    await MainActor.run {
                        LogStore.shared.append(.info, source: source, "  │ \(trimmed)")
                    }
                }
                await MainActor.run {
                    onEvent()
                }
                if Task.isCancelled { break }
            }
        }

        let code = Shell.exitCode(outcome.terminationStatus)
        if !outcome.terminationStatus.isSuccess && !Task.isCancelled {
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
