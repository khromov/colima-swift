import Foundation
import Subprocess
import System

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
            "/usr/bin", "/bin", "/usr/sbin", "/sbin"
        ]
    }()

    static var subprocessEnvironment: Environment {
        let extras = searchDirs.joined(separator: ":")
        let parent = ProcessInfo.processInfo.environment
        let merged = parent["PATH"].map { "\($0):\(extras)" } ?? extras
        return .inherit.updating(["PATH": merged])
    }

    static func resolveTool(_ name: String) -> String? {
        // Synchronous startup-time probe; keep the lightweight Process-based
        // implementation here rather than bouncing through async.
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
    @discardableResult
    static func run(_ tool: String, _ args: [String]) async throws -> String {
        let commandLine = ([tool] + args).joined(separator: " ")
        let started = Date()
        LogStore.log(.info, source: "shell", "→ \(commandLine)")

        do {
            let outcome = try await Subprocess.run(
                .path(FilePath(tool)),
                arguments: Arguments(args),
                environment: subprocessEnvironment,
                output: .string(limit: Int.max, encoding: UTF8.self),
                error: .string(limit: Int.max, encoding: UTF8.self)
            )
            let stdout = outcome.standardOutput ?? ""
            let stderr = outcome.standardError ?? ""
            let ms = Int(Date().timeIntervalSince(started) * 1000)

            if outcome.terminationStatus.isSuccess {
                let snippet = Self.firstLineSnippet(stdout, max: 200)
                let suffix = snippet.isEmpty ? "" : "  ·  \(snippet)"
                LogStore.log(.info, source: "shell", "✓ exit 0 (\(ms) ms)\(suffix)")
                return stdout
            } else {
                let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                let code = Self.exitCode(outcome.terminationStatus)
                LogStore.log(.error, source: "shell", "✗ exit \(code) (\(ms) ms)  ·  \(trimmed)")
                throw ShellError.nonZeroExit(code: code, stderr: stderr)
            }
        } catch let error as ShellError {
            throw error
        } catch {
            LogStore.log(.error, source: "shell", "✗ failed to launch \(tool): \(error)")
            throw ShellError.launchFailed("\(error)")
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

        do {
            let outcome = try await Subprocess.run(
                .path(FilePath(tool)),
                arguments: Arguments(args),
                environment: subprocessEnvironment
            ) { _, _, outputSequence, errorSequence in
                async let _: Void = Self.streamLines(outputSequence, source: source)
                let stderrString = await Self.streamAndCollectLines(errorSequence, source: source)
                return stderrString
            }

            let stderrString = outcome.value
            let code = Self.exitCode(outcome.terminationStatus)
            let ms = Int(Date().timeIntervalSince(started) * 1000)

            if outcome.terminationStatus.isSuccess {
                LogStore.log(.info, source: "shell", "✓ exit 0 (\(ms) ms)")
                return code
            } else {
                LogStore.log(.error, source: "shell", "✗ exit \(code) (\(ms) ms)")
                throw ShellError.nonZeroExit(code: code, stderr: stderrString)
            }
        } catch let error as ShellError {
            throw error
        } catch {
            LogStore.log(.error, source: "shell", "✗ failed to launch \(tool): \(error)")
            throw ShellError.launchFailed("\(error)")
        }
    }

    static func streamLines(_ sequence: AsyncBufferSequence, source: String) async {
        do {
            for try await line in sequence.lines(encoding: UTF8.self) {
                let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
                if !trimmed.isEmpty {
                    LogStore.log(.info, source: source, "  │ \(trimmed)")
                }
            }
        } catch {
            // Stream errors on process exit are expected; ignore.
        }
    }

    static func streamAndCollectLines(_ sequence: AsyncBufferSequence, source: String) async -> String {
        var collected = ""
        do {
            for try await line in sequence.lines(encoding: UTF8.self) {
                let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
                if !trimmed.isEmpty {
                    LogStore.log(.info, source: source, "  │ \(trimmed)")
                }
                collected += line + "\n"
            }
        } catch {
            // Stream errors on process exit are expected; ignore.
        }
        return collected
    }

    static func exitCode(_ status: TerminationStatus) -> Int32 {
        switch status {
        case .exited(let code): return Int32(code)
        case .signaled(let signal): return 128 + Int32(signal)
        }
    }

    private static func firstLineSnippet(_ s: String, max: Int) -> String {
        let line = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        if line.count <= max { return line }
        return String(line.prefix(max)) + "…"
    }
}
