import Foundation

/// Antigravity (Google's agentic IDE) exposes quota through the language server the app runs locally:
/// find the process, take its `--csrf_token`, find its listening port, call the Connect-RPC endpoints.
/// Only works while Antigravity.app is running; the last good snapshot is kept otherwise.
public struct AntigravityUsageFetcher: UsageFetcher {
    public let provider: ProviderID = .antigravity
    public init() {}

    static let appPaths = ["/Applications/Antigravity.app", "\(NSHomeDirectory())/Applications/Antigravity.app"]

    public func isAvailable() -> Bool {
        Self.appPaths.contains { FileManager.default.fileExists(atPath: $0) }
    }

    public func fetch() async throws -> UsageSnapshot {
        let (summaryData, statusData) = try await Self.fetchBoth()
        let summary = try HTTP.decode(AntigravityQuotaSummary.self, from: summaryData)
        let status = statusData.flatMap { try? JSONDecoder().decode(AntigravityUserStatus.self, from: $0) }
        return Self.snapshot(summary: summary, status: status)
    }

    public func fetchRaw() async throws -> Data { try await Self.fetchBoth().0 }

    static func snapshot(summary: AntigravityQuotaSummary, status: AntigravityUserStatus?) -> UsageSnapshot {
        var windows: [UsageWindow] = []
        for group in summary.response?.groups ?? [] {
            for bucket in group.buckets ?? [] {
                guard let remaining = bucket.remainingFraction else { continue }
                let kind = UsageWindow.Kind(rawValue: bucket.window ?? "") ?? .weekly
                let title = Self.groupTitle(group.displayName ?? bucket.displayName ?? bucket.bucketId ?? "Quota")
                windows.append(UsageWindow(id: bucket.bucketId ?? UUID().uuidString, kind: kind, title: title,
                                           usedPercent: (1 - remaining) * 100,
                                           resetsAt: ISO8601DateFormatter.parseAny(bucket.resetTime)))
            }
        }
        // `planInfo.planName` is legacy Windsurf/Codeium plan data ("Pro" even on a free Google account);
        // the Antigravity tier lives in `userTier`.
        let us = status?.userStatus
        return UsageSnapshot(provider: .antigravity, account: us?.email, plan: Self.tierLabel(us?.userTier), seat: nil, windows: windows)
    }

    static func tierLabel(_ tier: AntigravityUserStatus.Tier?) -> String? {
        guard let tier else { return nil }
        switch tier.id?.lowercased() {
        case "free-tier": return "Starter"
        case "pro-tier", "ai-pro": return "AI Pro"
        case "ultra-tier", "ai-ultra": return "AI Ultra"
        default:
            return tier.name?.replacingOccurrences(of: "Antigravity ", with: "").replacingOccurrences(of: " Quota", with: "") ?? tier.id
        }
    }

    /// "Gemini Models" → "Gemini models · weekly", "Claude and GPT models" → "Claude & GPT · weekly".
    static func groupTitle(_ name: String) -> String {
        switch name.lowercased() {
        case "gemini models": "Gemini models"
        case "claude and gpt models": "Claude & GPT models"
        default: name
        }
    }

    // MARK: - Local language server

    struct Server { let port: Int; let csrfToken: String }

    static func fetchBoth() async throws -> (Data, Data?) {
        #if os(macOS)
        guard let server = try await locateServer() else { throw ProviderError.appNotRunning }
        let summary = try await call(server, "RetrieveUserQuotaSummary")
        let status = try? await call(server, "GetUserStatus")
        return (summary, status)
        #else
        throw ProviderError.notInstalled
        #endif
    }

    #if os(macOS)
    /// Antigravity.app's language server (not the IDE's, not agy): pid + csrf token from `ps`, ports from `lsof`.
    static func locateServer() async throws -> Server? {
        let ps = try run("/bin/ps", ["-axo", "pid=,command="])
        var candidates: [(pid: Int, token: String)] = []
        for line in ps.split(separator: "\n") {
            let text = String(line)
            guard text.contains("language_server"), text.contains("--app_data_dir antigravity "),
                  text.contains("Antigravity.app") || text.contains("/antigravity/"),
                  let pid = Int(text.trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? ""),
                  let range = text.range(of: "--csrf_token ") else { continue }
            let token = text[range.upperBound...].split(separator: " ").first.map(String.init) ?? ""
            if !token.isEmpty { candidates.append((pid, token)) }
        }
        for candidate in candidates {
            let lsof = (try? run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", String(candidate.pid)])) ?? ""
            let ports = lsof.split(separator: "\n").dropFirst().compactMap { line -> Int? in
                let cols = line.split(separator: " ", omittingEmptySubsequences: true)
                guard cols.count >= 9, let portText = cols[8].split(separator: ":").last else { return nil }
                return Int(portText)
            }
            for port in Set(ports).sorted() {
                let server = Server(port: port, csrfToken: candidate.token)
                if (try? await call(server, "GetUnleashData")) != nil { return server }
            }
        }
        return nil
    }

    static func call(_ server: Server, _ method: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://127.0.0.1:\(server.port)/exa.language_server_pb.LanguageServerService/\(method)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(server.csrfToken, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        let (data, response) = try await LocalTLS.session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ProviderError.http((response as? HTTPURLResponse)?.statusCode ?? 0) }
        return data
    }

    static func run(_ path: String, _ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
    #endif
}

/// The language server uses a self-signed certificate; trust it for loopback only.
final class LocalTLS: NSObject, URLSessionDelegate, Sendable {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        return URLSession(configuration: config, delegate: LocalTLS(), delegateQueue: nil)
    }()

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.host == "127.0.0.1", let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }
}

struct AntigravityQuotaSummary: Decodable {
    struct Bucket: Decodable { let bucketId: String?; let displayName: String?; let window: String?; let remainingFraction: Double?; let resetTime: String? }
    struct Group: Decodable { let displayName: String?; let buckets: [Bucket]? }
    struct Response: Decodable { let groups: [Group]? }
    let response: Response?
}

struct AntigravityUserStatus: Decodable {
    struct PlanInfo: Decodable { let planName: String? }
    struct PlanStatus: Decodable { let planInfo: PlanInfo? }
    struct Tier: Decodable { let id: String?; let name: String? }
    struct UserStatus: Decodable { let email: String?; let planStatus: PlanStatus?; let userTier: Tier? }
    let userStatus: UserStatus?
}
