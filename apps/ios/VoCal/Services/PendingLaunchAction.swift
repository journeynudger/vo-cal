import Foundation

// Port provenance: new for Vo-Cal, in answer to Serein apps/ios/SereinApp/Sources/
// SiriCaptureIntents.swift, where the intent drives the capture coordinator itself from the
// background. Vo-Cal's capture is foreground-only (decision 2), so the intent leaves a request
// here and the shell acts on it (the why is in Intents/VoCalIntents.swift).

/// A request made from outside the app (Siri, the Action button, a Shortcut) for the shell to
/// act on once it can: today only "open the voice log and start listening". A store: it holds
/// what was asked and when. The shell decides when it can act (Today on screen, no capture
/// running) and the voice log's own door does the capture, so nothing here is on the capture
/// path.
@MainActor
@Observable
final class PendingLaunchAction {
    enum Action: String, Equatable, Sendable {
        case startVoiceLog = "start_voice_log"
    }

    static let shared = PendingLaunchAction()

    /// A request older than this is dropped by `take`, never honored late. Requirement: the mic
    /// goes hot only on a fresh ask. Failure mode: a press during onboarding or at the sign-in
    /// gate would otherwise sit here and open the mic minutes later, on a screen the person did
    /// not ask for. A minute covers a cold launch, the auth restore and a What's New sheet.
    nonisolated static let maxAge: TimeInterval = 60

    private(set) var pending: Action?
    @ObservationIgnored private var requestedAt: Date?

    /// Records the ask. A second ask before the shell takes the first replaces it.
    func request(_ action: Action, now: Date = .now) {
        pending = action
        requestedAt = now
    }

    /// Consumes the request: returns it when it is fresh, nil when there is none or it went
    /// stale, and clears it either way so it is acted on at most once.
    func take(now: Date = .now) -> Action? {
        let action = pending
        let askedAt = requestedAt
        pending = nil
        requestedAt = nil
        guard let action, let askedAt, now.timeIntervalSince(askedAt) <= Self.maxAge else {
            return nil
        }
        return action
    }
}
