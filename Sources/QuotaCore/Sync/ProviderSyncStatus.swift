import Foundation

/// Safe codes only: raw network responses, account identifiers and credentials are never error text in sync.
public enum ProviderFailureCode: String, Codable, Sendable {
    case loginRequired, keychainDenied, rateLimited, offline, invalidResponse, unavailable

    public init(_ error: ProviderError) {
        switch error {
        case .notLoggedIn, .tokenExpired, .unauthorized: self = .loginRequired
        case .keychainDenied: self = .keychainDenied
        case .rateLimited: self = .rateLimited
        case .decoding: self = .invalidResponse
        case .notInstalled, .appNotRunning: self = .unavailable
        case .http, .network: self = .offline
        }
    }

    public var nextStep: String {
        switch self {
        case .loginRequired: "Open the tool on your Mac, sign in, then refresh."
        case .keychainDenied: "Refresh on your Mac and allow QuotaVadis to read the tool's login in Keychain."
        case .rateLimited: "The provider is limiting requests. Wait a few minutes, then refresh."
        case .offline: "Check the connection on your Mac, then refresh."
        case .invalidResponse: "The provider returned an unrecognized response. Retry or check for an app update."
        case .unavailable: "Install or open the tool on your Mac, then refresh."
        }
    }
}

public enum MeasurementFreshness: String, Sendable {
    case fresh = "Fresh", stale = "Stale", error = "Error", unavailable = "No data"
}

public struct ProviderSyncStatus: Codable, Sendable, Hashable, Identifiable {
    public var instanceID: String
    public var provider: ProviderID
    public var lastAttemptAt: Date?
    public var lastSuccessAt: Date?
    public var errorCode: ProviderFailureCode?
    public var id: String { instanceID }
    public static let staleAfter: TimeInterval = 15 * 60

    public init(instanceID: String, provider: ProviderID, state: ProviderState, lastAttemptAt: Date?) {
        self.instanceID = instanceID
        self.provider = provider
        self.lastAttemptAt = lastAttemptAt
        lastSuccessAt = state.snapshot?.fetchedAt
        if case .failed(let error, _) = state { errorCode = ProviderFailureCode(error) }
        else if case .unavailable = state { errorCode = .unavailable }
    }

    public func freshness(now: Date = .now) -> MeasurementFreshness {
        if errorCode != nil { return lastSuccessAt == nil ? .error : .stale }
        guard let lastSuccessAt else { return .unavailable }
        return now.timeIntervalSince(lastSuccessAt) > Self.staleAfter ? .stale : .fresh
    }

    public func label(now: Date = .now) -> String {
        let state = freshness(now: now).rawValue
        guard let lastSuccessAt else { return state }
        return "\(state) · measured \(lastSuccessAt.formatted(.relative(presentation: .named)))"
    }
}
