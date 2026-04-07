import Foundation

enum ShellError: Error {
    case nonZeroExit(code: Int32, stderr: String)
    case launchFailed(String)
}

enum Shell {
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
        let extras = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
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
