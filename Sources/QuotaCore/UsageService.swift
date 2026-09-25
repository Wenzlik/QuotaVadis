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
    /// Bumped when a provider's login changes; work started under an older value belongs to the old account.
    private var epochs: [ProviderID: Int] = [:]

    /// Providers whose usage API throttles aggressively are polled no more often than this, whatever the user's
    /// refresh interval. Anthropic's /api/oauth/usage answers 429 to sub-minute polling (claude-code #31021, #31637);
    /// CodexBar's default cadence there is 5 minutes.
    public static let minimumInterval: [ProviderID: TimeInterval] = [.claude: 300]

    public init(fetchers: [any UsageFetcher] = UsageService.defaultFetchers()) {
        self.fetchers = fetchers
    }

    /// `invalidating`: providers whose account just changed (a new sign-in, a sign-out). Their cached
    /// snapshots, throttle floor and still-running fetches belong to the previous login, so none of it may be
    /// handed out as the new one's — including results of a refresh that is in flight right now.
    public func setFetchers(_ fetchers: [any UsageFetcher], invalidating: Set<ProviderID> = []) {
        self.fetchers = fetchers
        guard !invalidating.isEmpty else { return }
        func affected(_ id: String) -> Bool { invalidating.contains { id == $0.rawValue || id.hasPrefix($0.rawValue + ":") || id.hasPrefix($0.rawValue + "-") } }
        for provider in invalidating { epochs[provider, default: 0] += 1 }
        for id in pending.keys where affected(id) { pending[id] = nil }
        last = last.filter { !affected($0.key) }
        lastByFetcher = lastByFetcher.filter { !affected($0.key) }
        lastSuccessAt = lastSuccessAt.filter { !affected($0.key) }
    }

    public func refresh(enabled: Set<ProviderID> = Set(ProviderID.allCases), timeout: Double = 45,
                        onResult: @escaping @Sendable (String, ProviderState) async -> Void = { _, _ in }) async -> [String: ProviderState] {
        await withTaskGroup(of: (String, ProviderID, Int, [(String, ProviderState)]).self) { group in
            for fetcher in fetchers where enabled.contains(fetcher.provider) {
                let id = fetcher.instanceID
                let epoch = epochs[fetcher.provider, default: 0]
                let provider = fetcher.provider
                // Too soon for this provider: hand back the last good snapshots without touching the network.
                if let floor = Self.minimumInterval[fetcher.provider], let at = lastSuccessAt[id],
                   let cached = lastByFetcher[id], !cached.isEmpty, Date.now.timeIntervalSince(at) < floor {
                    group.addTask { (id, provider, epoch, cached.map { ($0.instanceID, .fresh($0)) }) }
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
                        // Only clear our own entry: an invalidation may already have put a new fetch here.
                        if epochs[provider, default: 0] == epoch { pending[id] = nil }
                    }
                }
                let previous = lastByFetcher[id] ?? []
                let lastSnapshots = last
                group.addTask {
                    (id, provider, epoch, await Self.wait(for: work, id: id, previous: previous, last: lastSnapshots, timeout: timeout))
                }
            }
            var result: [String: ProviderState] = [:]
            for await (fetcherID, provider, epoch, states) in group {
                // The login changed while this fetch ran: its answer is about the previous account.
                guard epoch == epochs[provider, default: 0] else { continue }
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

    private static func wait(for work: Task<[UsageSnapshot]?, Error>, id: String, previous: [UsageSnapshot],
                             last lastSnapshots: [String: UsageSnapshot], timeout: Double) async -> [(String, ProviderState)] {
        // A timed-out waiter stops waiting; the shared fetch keeps running so the next refresh can
        // pick up its result (a Keychain prompt answered late must not be thrown away).
        func failed(_ error: ProviderError) -> [(String, ProviderState)] {
            let ids = previous.isEmpty ? [id] : previous.map(\.instanceID)
            return ids.map { ($0, .failed(error, last: lastSnapshots[$0])) }
        }
        do {
            guard let snapshots = try await withTimeout(seconds: timeout, { try await work.value }) else { return [(id, .unavailable)] }
            return snapshots.map { ($0.instanceID, .fresh($0)) }
        } catch is TimeoutError {
            return failed(.network("Timed out after \(Int(timeout)) s"))
        } catch let error as ProviderError {
            return failed(error)
        } catch {
            return failed(.network(error.localizedDescription))
        }
    }
}
