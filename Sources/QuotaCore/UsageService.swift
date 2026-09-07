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
    public static func defaultFetchers(extraClaudeServices: [String] = []) -> [any UsageFetcher] {
        [ClaudeUsageFetcher()] + extraClaudeServices.map { ClaudeUsageFetcher(keychainService: $0) } + [CodexUsageFetcher(), CursorUsageFetcher(), AntigravityUsageFetcher()]
    }

    private var fetchers: [any UsageFetcher]
    private var pending: [String: Task<UsageSnapshot?, Error>] = [:]
    private var last: [String: UsageSnapshot] = [:]
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
        await withTaskGroup(of: (String, ProviderState).self) { group in
            for fetcher in fetchers where enabled.contains(fetcher.provider) {
                let id = fetcher.instanceID
                // Too soon for this provider: hand back the last good snapshot without touching the network.
                if let floor = Self.minimumInterval[fetcher.provider], let at = lastSuccessAt[id], let cached = last[id],
                   Date.now.timeIntervalSince(at) < floor {
                    group.addTask { (id, .fresh(cached)) }
                    continue
                }
                // Reuse a still-blocked system call rather than accumulate Keychain readers on each retry.
                let work: Task<UsageSnapshot?, Error>
                if let existing = pending[id] { work = existing }
                else {
                    work = Task.detached {
                        guard fetcher.isAvailable() else { return nil }
                        try Task.checkCancellation()
                        return try await fetcher.fetch()
                    }
                    pending[id] = work
                    Task {
                        _ = await work.result
                        pending[id] = nil
                    }
                }
                group.addTask { [last] in
                    do {
                        // One stuck provider (Keychain prompt, hung local server) must not block the others or the sync.
                        // A timed-out waiter stops waiting; the shared fetch keeps running so the next refresh can
                        // pick up its result (a Keychain prompt answered late must not be thrown away).
                        let snapshot = try await withTimeout(seconds: timeout) { try await work.value }
                        return (id, snapshot.map(ProviderState.fresh) ?? .unavailable)
                    } catch is TimeoutError {
                        return (id, .failed(.network("Timed out after \(Int(timeout)) s"), last: last[id]))
                    } catch let error as ProviderError {
                        return (id, .failed(error, last: last[id]))
                    } catch {
                        return (id, .failed(.network(error.localizedDescription), last: last[id]))
                    }
                }
            }
            var result: [String: ProviderState] = [:]
            for await (id, state) in group {
                await onResult(id, state)
                result[id] = state
                if case .fresh(let s) = state, last[id] != s || lastSuccessAt[id] == nil {
                    last[id] = s
                    lastSuccessAt[id] = s.fetchedAt
                }
            }
            return result
        }
    }
}
