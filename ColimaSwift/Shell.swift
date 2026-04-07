import Foundation

enum ShellError: Error {
    case nonZeroExit(code: Int32, stderr: String)
    case launchFailed(String)
}

/// Mutable buffers for `Shell.runStreaming`. A class so the readability and
/// termination handlers can capture it by reference without tripping Swift 6's
/// "captured var in concurrent code" diagnostics. The lock serializes the
/// pipe handlers (which fire on background threads).
private final class StreamState: @unchecked Sendable {
    private let lock = NSLock()
    private var outBuf = Data()
    private var errBuf = Data()
    private var stderrCollected = Data()
    private let source: String

    init(source: String) { self.source = source }

    func appendStdout(_ data: Data) {
        if data.isEmpty { return }
        lock.lock(); defer { lock.unlock() }
        outBuf.append(data)
        flushLines(&outBuf)
    }

    func appendStderr(_ data: Data) {
        if data.isEmpty { return }
        lock.lock(); defer { lock.unlock() }
        errBuf.append(data)
        stderrCollected.append(data)
        flushLines(&errBuf)
    }

    /// Flush any trailing partial line and return collected stderr as a string.
    func finalize() -> String {
        lock.lock(); defer { lock.unlock() }
        flushLines(&outBuf)
        flushLines(&errBuf)
        flushTail(&outBuf)
        flushTail(&errBuf)
        return String(data: stderrCollected, encoding: .utf8) ?? ""
    }

    private func flushLines(_ buffer: inout Data) {
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if !trimmed.isEmpty {
                LogStore.log(.info, source: source, "  │ \(trimmed)")
            }
        }
    }

    private func flushTail(_ buf: inout Data) {
        if buf.isEmpty { return }
        if let s = String(data: buf, encoding: .utf8) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { LogStore.log(.info, source: source, "  │ \(t)") }
        }
        buf.removeAll()
    }
}

enum Shell {
    /// Runs an external tool and returns its stdout. Throws on non-zero exit.
    /// Tool must be an absolute path; the app may be unsandboxed and $PATH is unreliable.
    @discardableResult
    static func run(_ tool: String, _ args: [String], timeout: TimeInterval = 120) async throws -> String {
        let commandLine = ([tool] + args).joined(separator: " ")
        let started = Date()
        LogStore.log(.info, source: "shell", "→ \(commandLine)")

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = args

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            // Inherit a sane PATH so colima can find docker/limactl in subprocess invocations.
            var env = ProcessInfo.processInfo.environment
            let extras = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            env["PATH"] = (env["PATH"].map { "\($0):\(extras)" }) ?? extras
            process.environment = env

            process.terminationHandler = { proc in
                let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
                let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
                let stdout = String(data: outData, encoding: .utf8) ?? ""
                let stderr = String(data: errData, encoding: .utf8) ?? ""
                let ms = Int(Date().timeIntervalSince(started) * 1000)

                if proc.terminationStatus == 0 {
                    let snippet = Self.firstLineSnippet(stdout, max: 200)
                    let suffix = snippet.isEmpty ? "" : "  ·  \(snippet)"
                    LogStore.log(.info, source: "shell", "✓ exit 0 (\(ms) ms)\(suffix)")
                    cont.resume(returning: stdout)
                } else {
                    let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    LogStore.log(.error, source: "shell", "✗ exit \(proc.terminationStatus) (\(ms) ms)  ·  \(trimmed)")
                    cont.resume(throwing: ShellError.nonZeroExit(code: proc.terminationStatus, stderr: stderr))
                }
            }

            do {
                try process.run()
            } catch {
                LogStore.log(.error, source: "shell", "✗ failed to launch \(tool): \(error)")
                cont.resume(throwing: ShellError.launchFailed("\(error)"))
            }
        }
    }

    private static func firstLineSnippet(_ s: String, max: Int) -> String {
        let line = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        if line.count <= max { return line }
        return String(line.prefix(max)) + "…"
    }

    /// Like `run` but pipes stdout/stderr into the log store line-by-line as the
    /// process produces them. Use for user-invoked commands so the UI can show
    /// progress in real time. Throws on non-zero exit.
    @discardableResult
    static func runStreaming(_ tool: String, _ args: [String], source: String) async throws -> Int32 {
        let commandLine = ([tool] + args).joined(separator: " ")
        let started = Date()
        LogStore.log(.info, source: "shell", "→ \(commandLine)")

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = args

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            var env = ProcessInfo.processInfo.environment
            let extras = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            env["PATH"] = (env["PATH"].map { "\($0):\(extras)" }) ?? extras
            process.environment = env

            // Background pipe handlers can fire concurrently; box mutable state in
            // a class so the closures capture by reference and Swift 6 concurrency
            // is happy. The internal lock serializes mutation across threads.
            let state = StreamState(source: source)

            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty { state.appendStdout(data) }
            }
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty { state.appendStderr(data) }
            }

            process.terminationHandler = { proc in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                state.appendStdout(outPipe.fileHandleForReading.availableData)
                state.appendStderr(errPipe.fileHandleForReading.availableData)
                let stderrString = state.finalize()

                let ms = Int(Date().timeIntervalSince(started) * 1000)
                let code = proc.terminationStatus
                if code == 0 {
                    LogStore.log(.info, source: "shell", "✓ exit 0 (\(ms) ms)")
                    cont.resume(returning: code)
                } else {
                    LogStore.log(.error, source: "shell", "✗ exit \(code) (\(ms) ms)")
                    cont.resume(throwing: ShellError.nonZeroExit(code: code, stderr: stderrString))
                }
            }

            do {
                try process.run()
            } catch {
                LogStore.log(.error, source: "shell", "✗ failed to launch \(tool): \(error)")
                cont.resume(throwing: ShellError.launchFailed("\(error)"))
            }
        }
    }
}
