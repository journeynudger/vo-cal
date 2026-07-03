import Foundation

// The derived-pipeline error taxonomy. One generic "Couldn't analyze the meal" hid which of
// ~6 distinct failures actually happened (no readable audio, offline, provider 5xx, expired
// session, contract drift, …), making field reports undiagnosable — the is_estimate decode
// bug shipped invisible behind it. Every failure now maps to a specific, actionable message
// plus a short machine-stable diagnostic code shown small on the failure surface, so a beta
// report like "parse_decode" pinpoints the failing stage + class immediately.
//
// Lives in VoCalCore (not the app target) so the mapping is unit-testable — the app has no
// unit-test target. The app maps its APIError/TranscriptionError into PipelineFailureKind at
// the boundary (parse, don't validate); this module owns stage+kind → copy.

/// Which pipeline call failed. The stages mirror the derived claim ladder
/// (VOICE_CAPTURE.md): transcribe → parse → logged.
public enum PipelineStage: String, Sendable {
    case transcribe
    case parse
    case log
}

/// The failure class, normalized from the app's transport/HTTP/decode errors.
public enum PipelineFailureKind: Sendable, Equatable {
    /// The committed capture's audio bytes aren't readable yet (outbox commit still
    /// converging) or are missing. No server call was made.
    case noAudio
    /// Transport-level failure: offline, timeout, DNS, connection lost.
    case offline
    /// The server answered with a non-2xx status.
    case serverStatus(Int)
    /// A 2xx response the app could not decode — client/server contract drift.
    case contractMismatch
    /// Anything else (cancellation is handled before mapping).
    case unknown
}

public struct PipelineFailureCopy: Sendable, Equatable {
    /// User-facing message. Honest about what happened + what to do; never claims more
    /// than the facts (audio-is-safe framing only where the capture is already committed).
    public let message: String
    /// Short machine-stable diagnostic code (e.g. "parse_decode", "transcribe_502",
    /// "no_audio") surfaced small on the failure UI so reports pinpoint the failure.
    public let code: String
    /// Whether a retry can plausibly succeed (drives the "Try again" affordance).
    public let retryable: Bool

    public init(message: String, code: String, retryable: Bool) {
        self.message = message
        self.code = code
        self.retryable = retryable
    }
}

public func pipelineFailureCopy(stage: PipelineStage, kind: PipelineFailureKind) -> PipelineFailureCopy {
    switch kind {
    case .noAudio:
        return PipelineFailureCopy(
            message: "Still saving your audio — give it a second and tap Try again.",
            code: "no_audio",
            retryable: true
        )

    case .offline:
        return PipelineFailureCopy(
            message: "Can't reach the server — check your connection and try again. Your audio is safe.",
            code: "\(stage.rawValue)_offline",
            retryable: true
        )

    case let .serverStatus(code):
        switch code {
        case 401, 403:
            return PipelineFailureCopy(
                message: "Your session expired — sign out and back in, then try again. Your audio is safe.",
                code: "\(stage.rawValue)_auth_\(code)",
                retryable: false
            )
        case 404:
            // The server doesn't know the capture/transcript/parse we referenced.
            return PipelineFailureCopy(
                message: "The server couldn't find this recording — try again to re-upload it.",
                code: "\(stage.rawValue)_404",
                retryable: true
            )
        case 413:
            return PipelineFailureCopy(
                message: "This recording is too large to upload. Try a shorter one.",
                code: "\(stage.rawValue)_413",
                retryable: false
            )
        case 422:
            switch stage {
            case .transcribe:
                return PipelineFailureCopy(
                    message: "The recording couldn't be transcribed — try speaking your meal again.",
                    code: "transcribe_422",
                    retryable: true
                )
            case .parse:
                return PipelineFailureCopy(
                    message: "I couldn't make out any food in that — try describing the meal again.",
                    code: "parse_422",
                    retryable: true
                )
            case .log:
                return PipelineFailureCopy(
                    message: "The meal couldn't be saved as-is — adjust the items and try again.",
                    code: "log_422",
                    retryable: true
                )
            }
        case 500...599:
            let what: String
            switch stage {
            case .transcribe: what = "The transcription service is having trouble"
            case .parse: what = "The meal analyzer is having trouble"
            case .log: what = "The server is having trouble saving"
            }
            return PipelineFailureCopy(
                message: "\(what) — try again in a minute. Your audio is safe.",
                code: "\(stage.rawValue)_\(code)",
                retryable: true
            )
        default:
            return PipelineFailureCopy(
                message: "The server rejected the request (\(code)) — try again. Your audio is safe.",
                code: "\(stage.rawValue)_\(code)",
                retryable: true
            )
        }

    case .contractMismatch:
        // A 2xx the app couldn't decode: the app and server disagree about the response
        // shape (the is_estimate class). Retrying the identical request cannot help.
        return PipelineFailureCopy(
            message: "This app version can't read the server's reply — please update the app.",
            code: "\(stage.rawValue)_decode",
            retryable: false
        )

    case .unknown:
        let what: String
        switch stage {
        case .transcribe: what = "Couldn't transcribe the recording"
        case .parse: what = "Couldn't analyze the meal"
        case .log: what = "Couldn't log the meal"
        }
        return PipelineFailureCopy(
            message: "\(what) — try again. Your audio is safe.",
            code: "\(stage.rawValue)_unknown",
            retryable: true
        )
    }
}
