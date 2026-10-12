import Foundation

/// Reads and writes how the person follows their nutrition (`GET /tracking`, `PUT /tracking`).
/// A protocol so the sim path keeps a preference with zero network and Settings → How I track
/// changes what the mock Today draws. Off the capture path: delete this type and voice logging
/// still works (AGENTS.md capture-path isolation).
protocol TrackingService: Sendable {
    func preference() async throws -> TrackingPreference
    /// Append the next version. Fields left nil keep their value server-side, so one thing
    /// changes at a time. The echo is the merged preference, the only proof the change landed.
    func update(_ update: TrackingUpdate) async throws -> TrackingPreference
}

struct LiveTrackingService: TrackingService {
    let api: APIClient
    init(api: APIClient = APIClient()) { self.api = api }

    func preference() async throws -> TrackingPreference {
        // Cold-launch auth guard, as LiveTodayService: a tokenless GET 401s and would read as
        // "never chose", showing the five to a person who chose habits.
        await AuthCoordinator.shared.ensureSession()
        return try await api.tracking()
    }

    func update(_ update: TrackingUpdate) async throws -> TrackingPreference {
        await AuthCoordinator.shared.ensureSession()
        return try await api.updateTracking(update)
    }
}

/// Sim path: the preference lives in UserDefaults, so Settings → How I track changes what the
/// canned Today draws and the change survives a relaunch. `-TrackingMode <mode>` wins over the
/// stored value for that launch (a screenshot or a render of one mode needs no taps).
struct MockTrackingService: TrackingService {
    private static let modeKey = "vocal.mock.tracking.mode"
    private static let focusKey = "vocal.mock.tracking.focus"
    private static let declinedKey = "vocal.mock.tracking.declined"
    private static let versionKey = "vocal.mock.tracking.version"
    private static let levelKey = "vocal.mock.tracking.level"
    private static let frictionsKey = "vocal.mock.tracking.frictions"
    private static let anchorKey = "vocal.mock.tracking.anchor"

    /// The sim's preference right now, readable without an await by the other mocks.
    static var current: TrackingPreference {
        let defaults = UserDefaults.standard
        let stored = defaults.string(forKey: modeKey).flatMap(TrackingMode.init(rawValue:))
        let forced = RuntimeMode.debugTrackingMode.flatMap(TrackingMode.init(rawValue:))
        let mode = forced ?? stored ?? .five
        let focus = (defaults.stringArray(forKey: focusKey) ?? []).compactMap(FocusMetric.init(rawValue:))
        let level = defaults.string(forKey: levelKey).flatMap(NudgeLevel.init(rawValue:))
        let frictions = (defaults.stringArray(forKey: frictionsKey) ?? []).compactMap(Friction.init(rawValue:))
        let anchor = defaults.string(forKey: anchorKey).flatMap(LogAnchor.init(rawValue:))
        return TrackingPreference(
            mode: mode,
            focusMetrics: focus,
            declinedOffers: defaults.stringArray(forKey: declinedKey) ?? [],
            offerableFocus: PanelComposer.offerableFocus(for: mode),
            source: stored == nil && forced == nil ? "default" : "chosen",
            version: defaults.integer(forKey: versionKey),
            nudgeLevel: level,
            frictions: frictions,
            experience: Experience.composed(level: level, frictions: frictions, anchor: anchor),
            logAnchor: anchor
        )
    }

    func preference() async throws -> TrackingPreference {
        Self.current
    }

    func update(_ update: TrackingUpdate) async throws -> TrackingPreference {
        let defaults = UserDefaults.standard
        let current = Self.current
        let mode = update.mode ?? current.mode
        let focus = update.focusMetrics ?? current.focusMetrics
        var declined = current.declinedOffers
        if let key = update.declineOffer, !declined.contains(key) {
            declined.append(key)
        }
        // Choosing by hand clears the decline, as the server does (tracking/router.py).
        let taken = [mode.rawValue] + focus.map { "focus:\($0.rawValue)" }
        declined.removeAll { taken.contains($0) }
        defaults.set(mode.rawValue, forKey: Self.modeKey)
        defaults.set(focus.map(\.rawValue), forKey: Self.focusKey)
        defaults.set(declined, forKey: Self.declinedKey)
        if let level = update.nudgeLevel {
            defaults.set(level.rawValue, forKey: Self.levelKey)
        }
        if let frictions = update.frictions {
            defaults.set(frictions.map(\.rawValue), forKey: Self.frictionsKey)
        }
        if let anchor = update.logAnchor {
            defaults.set(anchor.rawValue, forKey: Self.anchorKey)
        }
        defaults.set(current.version + 1, forKey: Self.versionKey)
        return Self.current
    }

    /// Back to never chosen (the five, version 0): the render tests start each answer here.
    static func reset() {
        let defaults = UserDefaults.standard
        for key in [modeKey, focusKey, declinedKey, versionKey, levelKey, frictionsKey, anchorKey] {
            defaults.removeObject(forKey: key)
        }
    }
}
