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
                        // One stuck provider (Keychain prompt, hung local server) must not block the others or the sync.
                        let snapshot = try await withTimeout(seconds: 45) { try await fetcher.fetch() }
                        return (id, .fresh(snapshot))
                    } catch is TimeoutError {
                        return (id, .failed(.network("Timed out after 45 s"), last: last[id]))
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

public struct TimeoutError: Error {}

public func withTimeout<T: Sendable>(seconds: Double, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw TimeoutError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
