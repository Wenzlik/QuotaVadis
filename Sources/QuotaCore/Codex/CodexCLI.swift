import Foundation

/// Talks to `codex app-server` over stdio JSON-RPC. Used only to make the Codex CLI refresh its own
/// credentials: the CLI owns `auth.json` and OpenAI rotates refresh tokens, so redeeming the refresh
/// token ourselves would strand the CLI with a dead token.
public enum CodexCLI {
    public static func binaryURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        var candidates = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "\(NSHomeDirectory())/.local/bin/codex", "\(NSHomeDirectory())/.npm-global/bin/codex"]
        for dir in (environment["PATH"] ?? "").split(separator: ":") { candidates.append("\(dir)/codex") }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// Runs one `account/rateLimits/read` round trip. Returns the raw result JSON, or nil when the CLI is missing.
    @discardableResult
    public static func readRateLimits(timeout: TimeInterval = 25) async throws -> Data? {
        guard let binary = binaryURL() else { return nil }
        #if os(macOS)
        let process = Process()
        process.executableURL = binary
        process.arguments = ["app-server"]
        var env = ProcessInfo.processInfo.environment
        env["NO_COLOR"] = "1"
        process.environment = env
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        let messages = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"quotavadis","title":"QuotaVadis","version":"0.1"}}}"#,
            #"{"jsonrpc":"2.0","method":"initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":{}}"#,
        ]
        stdin.fileHandleForWriting.write(Data((messages.joined(separator: "\n") + "\n").utf8))

        let reader = Task.detached { () -> Data? in
            var buffer = Data()
            while true {
                let chunk = stdout.fileHandleForReading.availableData
                if chunk.isEmpty { return nil }
                buffer.append(chunk)
                for line in buffer.split(separator: 0x0A) {
                    guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any], obj["id"] as? Int == 2 else { continue }
                    if let error = obj["error"] as? [String: Any] {
                        throw ProviderError.network(error["message"] as? String ?? "codex app-server error")
                    }
                    guard let result = obj["result"] else { return Data() }
                    return try? JSONSerialization.data(withJSONObject: result)
                }
            }
        }
        defer {
            try? stdin.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }
        return try await withThrowingTaskGroup(of: Data?.self) { group in
            group.addTask { try await reader.value }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                reader.cancel()
                throw ProviderError.network("codex app-server timed out")
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
        #else
        return nil
        #endif
    }
}
