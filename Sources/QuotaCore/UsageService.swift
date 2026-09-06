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

/// Runs every installed fetcher concurrently and keeps the last good snapshot when a refresh fails.
public actor UsageService {
    public static let allFetchers: [any UsageFetcher] = [ClaudeUsageFetcher(), CodexUsageFetcher(), CursorUsageFetcher()]

    private let fetchers: [any UsageFetcher]
    private var last: [ProviderID: UsageSnapshot] = [:]

    public init(fetchers: [any UsageFetcher] = UsageService.allFetchers) {
        self.fetchers = fetchers
    }

    public func refresh(enabled: Set<ProviderID> = Set(ProviderID.allCases)) async -> [ProviderID: ProviderState] {
        await withTaskGroup(of: (ProviderID, ProviderState).self) { group in
            for fetcher in fetchers where enabled.contains(fetcher.provider) {
                group.addTask { [last] in
                    guard fetcher.isAvailable() else { return (fetcher.provider, .unavailable) }
                    do {
                        return (fetcher.provider, .fresh(try await fetcher.fetch()))
                    } catch let error as ProviderError {
                        return (fetcher.provider, .failed(error, last: last[fetcher.provider]))
                    } catch {
                        return (fetcher.provider, .failed(.network(error.localizedDescription), last: last[fetcher.provider]))
                    }
                }
            }
            var result: [ProviderID: ProviderState] = [:]
            for await (id, state) in group {
                result[id] = state
                if case .fresh(let s) = state { last[id] = s }
            }
            return result
        }
    }
}
