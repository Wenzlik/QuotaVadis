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
        return try await readRateLimits(binary: binary, timeout: timeout)
    }

    /// Injectable executable for lifecycle regression tests; never touches real credentials in tests.
    static func readRateLimits(binary: URL, timeout: TimeInterval) async throws -> Data? {
        #if os(macOS)
        let process = Process()
        process.executableURL = binary
        process.arguments = ["app-server"]
        var env = ProcessInfo.processInfo.environment
        env["NO_COLOR"] = "1"
        process.environment = env
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try Task.checkCancellation()
        try process.run()
        defer {
            try? stdin.fileHandleForWriting.close()
            // The helper must not survive a deadline, including helpers that ignore SIGTERM.
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            try? stdout.fileHandleForReading.close()
        }
        let messages = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"quotavadis","title":"QuotaVadis","version":"0.1"}}}"#,
            #"{"jsonrpc":"2.0","method":"initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":{}}"#,
        ]
        try stdin.fileHandleForWriting.write(contentsOf: Data((messages.joined(separator: "\n") + "\n").utf8))
        let fd = stdout.fileHandleForReading.fileDescriptor
        guard fcntl(fd, F_SETFL, O_NONBLOCK) != -1 else { throw ProviderError.network("Cannot read codex app-server") }
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        var buffer = Data()
        var bytes = [UInt8](repeating: 0, count: 8192)
        while true {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw TimeoutError() }
            let count = read(fd, &bytes, bytes.count)
            if count > 0 {
                buffer.append(contentsOf: bytes.prefix(count))
                guard buffer.count <= 4 * 1024 * 1024 else { throw ProviderError.decoding("Oversized app-server response") }
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[..<newline]
                    defer { buffer.removeSubrange(...newline) }
                    guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any], obj["id"] as? Int == 2 else { continue }
                    if let error = obj["error"] as? [String: Any] {
                        throw ProviderError.network(error["message"] as? String ?? "codex app-server error")
                    }
                    guard let result = obj["result"] else { throw ProviderError.decoding("Missing app-server result") }
                    return try JSONSerialization.data(withJSONObject: result)
                }
            } else if count == 0 {
                throw ProviderError.network("codex app-server closed before responding")
            } else if errno != EAGAIN && errno != EINTR {
                throw ProviderError.network("Cannot read codex app-server")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #else
        return nil
        #endif
    }
}
