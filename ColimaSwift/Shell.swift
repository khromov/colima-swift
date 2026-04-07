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
}
