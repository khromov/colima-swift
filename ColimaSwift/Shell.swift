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
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
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
                if proc.terminationStatus == 0 {
                    cont.resume(returning: stdout)
                } else {
                    cont.resume(throwing: ShellError.nonZeroExit(code: proc.terminationStatus, stderr: stderr))
                }
            }

            do {
                try process.run()
            } catch {
                cont.resume(throwing: ShellError.launchFailed("\(error)"))
            }
        }
    }
}
