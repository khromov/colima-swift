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

    /// Launches a long-lived process and returns its stdout as an async stream
    /// of lines. Stderr is forwarded to the log store. The caller owns the
    /// returned `Process` and is responsible for calling `terminate()` when
    /// done; the stream finishes when the process exits.
    static func stream(_ tool: String, _ args: [String], source: String)
        -> (process: Process, lines: AsyncThrowingStream<String, Error>)
    {
        let commandLine = ([tool] + args).joined(separator: " ")
        LogStore.log(.info, source: "shell", "→ \(commandLine)")

        let (process, outPipe, errPipe) = makeProcess(tool, args)

        let stream = AsyncThrowingStream<String, Error> { continuation in
            // Forward stderr to the log store so failures are visible.
            Task.detached {
                do {
                    for try await line in errPipe.fileHandleForReading.bytes.lines {
                        let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
                        if !trimmed.isEmpty {
                            LogStore.log(.error, source: source, "  │ \(trimmed)")
                        }
                    }
                } catch {
                    // Pipe closed on termination; expected.
                }
            }

            // Read stdout line-by-line; each line becomes a stream element.
            Task.detached {
                do {
                    for try await line in outPipe.fileHandleForReading.bytes.lines {
                        continuation.yield(line)
                    }
                } catch {
                    continuation.finish(throwing: error)
                    return
                }
                // Stdout closed — process is exiting. Finish based on exit code.
                process.waitUntilExit()
                let code = process.terminationStatus
                if code == 0 {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: ShellError.nonZeroExit(code: code, stderr: ""))
                }
            }

            continuation.onTermination = { _ in
                if process.isRunning {
                    process.terminate()
                }
            }

            do {
                try process.run()
            } catch {
                LogStore.log(.error, source: "shell", "✗ failed to launch \(tool): \(error)")
                continuation.finish(throwing: ShellError.launchFailed("\(error)"))
            }
        }

        return (process, stream)
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
