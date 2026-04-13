import Foundation

enum ShellError: Error {
    case nonZeroExit(code: Int32, stderr: String)
    case launchFailed(String)
}

enum Shell {
    /// Directories to probe when locating external tools, and to prepend to
    /// child processes' `PATH` so colima can find its own helpers (docker,
    /// limactl, qemu, …). Order matters — earlier entries win.
    static let searchDirs: [String] = {
        let nix = NSString(string: "~/.nix-profile/bin").expandingTildeInPath
        return [
            "/opt/homebrew/bin",        // Homebrew (Apple Silicon)
            "/usr/local/bin",           // Homebrew (Intel) / manual installs
            "/opt/local/bin",           // MacPorts
            nix,                        // Nix single-user profile
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
    }()

    static func resolveTool(_ name: String) -> String? {
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = [name]

        var env = ProcessInfo.processInfo.environment
        let extras = searchDirs.joined(separator: ":")
        env["PATH"] = env["PATH"].map { "\($0):\(extras)" } ?? extras
        which.environment = env

        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = Pipe()
        do {
            try which.run()
            which.waitUntilExit()
            guard which.terminationStatus == 0,
                  let data = try? pipe.fileHandleForReading.readToEnd(),
                  let raw = String(data: data, encoding: .utf8)
            else { return nil }
            let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : path
        } catch {
            return nil
        }
    }

    /// Runs an external tool and returns its stdout. Throws on non-zero exit.
    /// Tool must be an absolute path; the app may be unsandboxed and $PATH is unreliable.
    @discardableResult
    static func run(_ tool: String, _ args: [String], timeout: TimeInterval = 120) async throws -> String {
        let commandLine = ([tool] + args).joined(separator: " ")
        let started = Date()
        LogStore.log(.info, source: "shell", "→ \(commandLine)")

        let (process, outPipe, errPipe) = makeProcess(tool, args)

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
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

    /// Like `run` but pipes stdout/stderr into the log store line-by-line as the
    /// process produces them. Use for user-invoked commands so the UI can show
    /// progress in real time. Throws on non-zero exit.
    @discardableResult
    static func runStreaming(_ tool: String, _ args: [String], source: String) async throws -> Int32 {
        let commandLine = ([tool] + args).joined(separator: " ")
        let started = Date()
        LogStore.log(.info, source: "shell", "→ \(commandLine)")

        let (process, outPipe, errPipe) = makeProcess(tool, args)

        do {
            try process.run()
        } catch {
            LogStore.log(.error, source: "shell", "✗ failed to launch \(tool): \(error)")
            throw ShellError.launchFailed("\(error)")
        }

        // Drain both pipes concurrently; FileHandle.AsyncBytes handles line
        // splitting and UTF-8 decoding for us. The tasks finish when the child
        // closes its pipes (i.e. when it exits).
        async let _: Void = logLines(from: outPipe.fileHandleForReading, source: source)
        async let stderrCollected: String = collectAndLogLines(from: errPipe.fileHandleForReading, source: source)

        let stderrString = await stderrCollected
        process.waitUntilExit()

        let ms = Int(Date().timeIntervalSince(started) * 1000)
        let code = process.terminationStatus
        if code == 0 {
            LogStore.log(.info, source: "shell", "✓ exit 0 (\(ms) ms)")
            return code
        } else {
            LogStore.log(.error, source: "shell", "✗ exit \(code) (\(ms) ms)")
            throw ShellError.nonZeroExit(code: code, stderr: stderrString)
        }
    }

    private static func makeProcess(_ tool: String, _ args: [String]) -> (Process, Pipe, Pipe) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args

        // Inherit a sane PATH so colima can find docker/limactl in subprocess invocations.
        var env = ProcessInfo.processInfo.environment
        let extras = searchDirs.joined(separator: ":")
        env["PATH"] = env["PATH"].map { "\($0):\(extras)" } ?? extras
        p.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        return (p, outPipe, errPipe)
    }

    private static func logLines(from handle: FileHandle, source: String) async {
        do {
            for try await line in handle.bytes.lines {
                let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
                if !trimmed.isEmpty {
                    LogStore.log(.info, source: source, "  │ \(trimmed)")
                }
            }
        } catch {
            // Pipe read errors on termination are expected; ignore.
        }
    }

    private static func collectAndLogLines(from handle: FileHandle, source: String) async -> String {
        var collected = ""
        do {
            for try await line in handle.bytes.lines {
                let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
                if !trimmed.isEmpty {
                    LogStore.log(.info, source: source, "  │ \(trimmed)")
                }
                collected += line + "\n"
            }
        } catch {
            // Pipe read errors on termination are expected; ignore.
        }
        return collected
    }

    private static func firstLineSnippet(_ s: String, max: Int) -> String {
        let line = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        if line.count <= max { return line }
        return String(line.prefix(max)) + "…"
    }
}

/// Reads lines from a FileHandle using `readabilityHandler` — more reliable for
/// long-lived pipes than `FileHandle.bytes.lines`, which can stall on streams
/// like `docker events` where lines arrive sporadically. Terminates when the
/// pipe is closed by the writer (process exit).
struct AsyncLineReader: AsyncSequence {
    typealias Element = String
    let handle: FileHandle

    func makeAsyncIterator() -> AsyncStream<String>.Iterator {
        let handle = self.handle
        let buffer = LineBuffer()
        let stream = AsyncStream<String> { continuation in
            handle.readabilityHandler = { fh in
                let chunk = fh.availableData
                if chunk.isEmpty {
                    if let tail = buffer.flushTail() {
                        continuation.yield(tail)
                    }
                    fh.readabilityHandler = nil
                    continuation.finish()
                    return
                }
                for line in buffer.append(chunk) {
                    continuation.yield(line)
                }
            }
            continuation.onTermination = { _ in
                handle.readabilityHandler = nil
            }
        }
        return stream.makeAsyncIterator()
    }
}

private final class LineBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
        var lines: [String] = []
        while let nl = data.firstIndex(of: 0x0A) {
            let lineData = data.subdata(in: 0..<nl)
            data.removeSubrange(0...nl)
            if let line = String(data: lineData, encoding: .utf8) {
                lines.append(line)
            }
        }
        return lines
    }

    func flushTail() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else {
            data.removeAll()
            return nil
        }
        data.removeAll()
        return s
    }
}
