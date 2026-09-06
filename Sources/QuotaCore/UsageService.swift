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
    private var last: [String: UsageSnapshot] = [:]

    public init(fetchers: [any UsageFetcher] = UsageService.defaultFetchers()) {
        self.fetchers = fetchers
    }

    public func setFetchers(_ fetchers: [any UsageFetcher]) { self.fetchers = fetchers }

    public func refresh(enabled: Set<ProviderID> = Set(ProviderID.allCases)) async -> [String: ProviderState] {
        await withTaskGroup(of: (String, ProviderState).self) { group in
            for fetcher in fetchers where enabled.contains(fetcher.provider) {
                group.addTask { [last] in
                    let id = fetcher.instanceID
                    guard fetcher.isAvailable() else { return (id, .unavailable) }
                    do {
                        return (id, .fresh(try await fetcher.fetch()))
                    } catch let error as ProviderError {
                        return (id, .failed(error, last: last[id]))
                    } catch {
                        return (id, .failed(.network(error.localizedDescription), last: last[id]))
                    }
                }
            }
            var result: [String: ProviderState] = [:]
            for await (id, state) in group {
                result[id] = state
                if case .fresh(let s) = state { last[id] = s }
            }
            return result
        }
    }
}
