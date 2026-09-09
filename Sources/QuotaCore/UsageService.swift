import Foundation

/// Result of one refresh for one provider.
public enum ProviderState: Sendable, Hashable {
    case fresh(UsageSnapshot)
    case failed(ProviderError, last: UsageSnapshot?)
    case unavailable

    public var snapshot: UsageSnapshot? {
        switch self {
        case .fresh(let s): s
        case .failed(_, let last): last
        case .unavailable: nil
        }
    }
}

/// Runs every configured fetcher concurrently and keeps the last good snapshot when a refresh fails.
/// Results are keyed by instance id (`claude`, `claude:<suffix>`, `codex`, `cursor`).
public actor UsageService {
    public enum ClaudeSource: String, Sendable, CaseIterable { case automatic, claudeCode, web }

    /// Claude Code logins first; the claude.ai web session covers people without Claude Code (and, in automatic
    /// mode, organizations the Claude Code logins do not cover).
    public static func defaultFetchers(extraClaudeServices: [String] = [], claudeSource: ClaudeSource = .automatic,
                                       coveredOrganizations: Set<String> = []) -> [any UsageFetcher] {
        var claude: [any UsageFetcher] = []
        let oauth = ClaudeUsageFetcher()
        switch claudeSource {
        case .claudeCode:
            claude = [oauth] + extraClaudeServices.map { ClaudeUsageFetcher(keychainService: $0) }
        case .web:
            claude = [ClaudeWebUsageFetcher()]
        case .automatic:
            if oauth.isAvailable() {
                claude = [oauth] + extraClaudeServices.map { ClaudeUsageFetcher(keychainService: $0) }
                if ClaudeWebSession.isAvailable() { claude.append(ClaudeWebUsageFetcher(excludedOrganizationNames: coveredOrganizations)) }
            } else {
                claude = [ClaudeWebUsageFetcher()]
            }
        }
        return claude + [CodexUsageFetcher(), CursorUsageFetcher(), AntigravityUsageFetcher()]
    }

    private var fetchers: [any UsageFetcher]
    private var pending: [String: Task<[UsageSnapshot]?, Error>] = [:]
    private var last: [String: UsageSnapshot] = [:]
    private var lastByFetcher: [String: [UsageSnapshot]] = [:]
    private var lastSuccessAt: [String: Date] = [:]

    /// Providers whose usage API throttles aggressively are polled no more often than this, whatever the user's
    /// refresh interval. Anthropic's /api/oauth/usage answers 429 to sub-minute polling (claude-code #31021, #31637);
    /// CodexBar's default cadence there is 5 minutes.
    public static let minimumInterval: [ProviderID: TimeInterval] = [.claude: 300]

    public init(fetchers: [any UsageFetcher] = UsageService.defaultFetchers()) {
        self.fetchers = fetchers
    }

    public func setFetchers(_ fetchers: [any UsageFetcher]) { self.fetchers = fetchers }

    public func refresh(enabled: Set<ProviderID> = Set(ProviderID.allCases), timeout: Double = 45,
                        onResult: @escaping @Sendable (String, ProviderState) async -> Void = { _, _ in }) async -> [String: ProviderState] {
        await withTaskGroup(of: (String, [(String, ProviderState)]).self) { group in
            for fetcher in fetchers where enabled.contains(fetcher.provider) {
                let id = fetcher.instanceID
                // Too soon for this provider: hand back the last good snapshots without touching the network.
                if let floor = Self.minimumInterval[fetcher.provider], let at = lastSuccessAt[id],
                   let cached = lastByFetcher[id], !cached.isEmpty, Date.now.timeIntervalSince(at) < floor {
                    group.addTask { (id, cached.map { ($0.instanceID, .fresh($0)) }) }
                    continue
                }
                // Reuse a still-blocked system call rather than accumulate Keychain readers on each retry.
                let work: Task<[UsageSnapshot]?, Error>
                if let existing = pending[id] { work = existing }
                else {
                    // Task.detached starts a task with no parent, so it does not inherit this call's
                    // ProviderInteractionContext — read it here, on the caller's task, and re-establish it
                    // inside the detached task explicitly (plain closure capture survives detachment fine).
                    // `isAvailable()` touches the Keychain too, so it belongs inside the re-established scope.
                    let userInitiated = ProviderInteractionContext.userInitiated
                    work = Task.detached {
                        try await ProviderInteractionContext.$userInitiated.withValue(userInitiated) {
                            guard fetcher.isAvailable() else { return nil }
                            try Task.checkCancellation()
                            return try await fetcher.fetchAll()
                        }
                    }
                    pending[id] = work
                    Task {
                        _ = await work.result
                        pending[id] = nil
                    }
                }
                let previous = lastByFetcher[id] ?? []
                let lastSnapshots = last
                group.addTask {
                    // A timed-out waiter stops waiting; the shared fetch keeps running so the next refresh can
                    // pick up its result (a Keychain prompt answered late must not be thrown away).
                    func failed(_ error: ProviderError) -> [(String, ProviderState)] {
                        let ids = previous.isEmpty ? [id] : previous.map(\.instanceID)
                        return ids.map { ($0, .failed(error, last: lastSnapshots[$0])) }
                    }
                    do {
                        guard let snapshots = try await withTimeout(seconds: timeout, { try await work.value }) else { return (id, [(id, .unavailable)]) }
                        return (id, snapshots.map { ($0.instanceID, .fresh($0)) })
                    } catch is TimeoutError {
                        return (id, failed(.network("Timed out after \(Int(timeout)) s")))
                    } catch let error as ProviderError {
                        return (id, failed(error))
                    } catch {
                        return (id, failed(.network(error.localizedDescription)))
                    }
                }
            }
            var result: [String: ProviderState] = [:]
            for await (fetcherID, states) in group {
                var freshOnes: [UsageSnapshot] = []
                for (id, state) in states {
                    await onResult(id, state)
                    result[id] = state
                    if case .fresh(let s) = state { freshOnes.append(s); last[id] = s }
                }
                if !freshOnes.isEmpty {
                    lastByFetcher[fetcherID] = freshOnes
                    if lastSuccessAt[fetcherID] == nil || freshOnes.contains(where: { $0.fetchedAt > (lastSuccessAt[fetcherID] ?? .distantPast) }) {
                        lastSuccessAt[fetcherID] = freshOnes.map(\.fetchedAt).max()
                    }
                }
            }
            // Automatic mode: an organization already served by a Claude Code login is not shown twice via the web.
            let covered = Set(result.filter { $0.key == "claude" || $0.key.hasPrefix("claude:") }.compactMap { $0.value.snapshot?.organization })
            for (key, state) in result where key.hasPrefix("claude-web:") {
                if let org = state.snapshot?.organization, covered.contains(org) { result[key] = nil; last[key] = nil }
            }
            return result
        }
    }
}
