import Foundation

/// What a widget should draw, decided once from the App Group payload instead of by each view separately.
///
/// Every case that is not `.ready` carries a headline and a sentence. That is the whole point: a widget with
/// nothing to show must say so and say why — before this existed, a payload that decoded but happened to carry
/// no usable windows fell through every `if let` in the views and rendered an empty tile.
public enum WidgetContentState: Sendable, Equatable {
    /// No payload at all; the reason comes straight from the store.
    case unavailable(SharedStore.ReadFailure)
    /// A payload, but the app is not tracking any tool (Settings ▸ Track is empty, or nothing measured yet).
    case noTrackedTools
    /// A payload, but this widget's tool is not among the tracked ones.
    case toolNotTracked(ProviderID)
    /// A snapshot exists but carries no limit window this widget can draw.
    case noLimits(ProviderID?)
    /// There is something to draw.
    case ready

    public var isReady: Bool { self == .ready }

    public var headline: String {
        switch self {
        case .unavailable(let failure): failure.headline
        case .noTrackedTools: "No tools tracked"
        case .toolNotTracked(let provider): "\(provider.shortName) not tracked"
        case .noLimits: "No limits reported"
        case .ready: ""
        }
    }

    public var detail: String {
        switch self {
        case .unavailable(let failure): failure.detail
        case .noTrackedTools: "Turn a tool on in QuotaVadis ▸ Settings ▸ Track."
        case .toolNotTracked(let provider): "Turn \(provider.displayName) on in Settings ▸ Track, or pick another tool for this widget."
        case .noLimits(let provider): provider.map { "\($0.displayName) reported no usage limits on the last refresh." }
            ?? "The tracked tools reported no usage limits on the last refresh."
        case .ready: ""
        }
    }

    /// SF Symbol for the empty state; `flame` stays the "all good, just open the app" mark.
    public var symbol: String {
        switch self {
        case .unavailable(.neverWritten), .noTrackedTools: "flame"
        case .unavailable, .noLimits, .toolNotTracked: "exclamationmark.triangle"
        case .ready: "flame.fill"
        }
    }
}

public enum WidgetContent {
    /// Single-tool widgets (fixed, configurable and the switcher).
    public static func providerState(_ result: Result<DevicePayload, SharedStore.ReadFailure>, provider: ProviderID) -> WidgetContentState {
        switch result {
        case .failure(let failure): return .unavailable(failure)
        case .success(let payload):
            guard !payload.snapshots.isEmpty else { return .noTrackedTools }
            guard let snapshot = payload.snapshot(for: provider) else { return .toolNotTracked(provider) }
            // `worstWindow` is nil exactly when the snapshot has no windows at all, which is also when every
            // window list the views iterate over is empty — i.e. when they would draw an empty tile.
            return snapshot.worstWindow == nil ? .noLimits(provider) : .ready
        }
    }

    /// The all-tools overview.
    public static func overviewState(_ result: Result<DevicePayload, SharedStore.ReadFailure>) -> WidgetContentState {
        switch result {
        case .failure(let failure): return .unavailable(failure)
        case .success(let payload):
            guard !payload.snapshots.isEmpty else { return .noTrackedTools }
            return payload.snapshots.contains { $0.worstWindow != nil } ? .ready : .noLimits(nil)
        }
    }
}
