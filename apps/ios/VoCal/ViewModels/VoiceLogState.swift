import Foundation
import VoCalCore

/// The single typed projection of the voice-log loop — no boolean soup. Each case is a
/// coherent state with exactly the data that state needs. The capture rungs
/// (idle…listening…sealing…saved) project the VoiceCaptureCoordinator's claim ladder; the
/// derived rungs (transcribing…enhancing…result) project the MealCaptureService.
///
/// Claim-ladder honesty (AGENTS.md MUST-NOT #6, VOICE_CAPTURE.md):
/// - `.listening` is entered only on confirmed-listening (the coordinator's `.started`
///   result, which the kernel emits only after a byte-flow liveness verdict).
/// - `.saved` carries the commit receipt — the proof that licenses the "Saved" copy.
/// - `.logged` carries the server confirmation — the only proof for the "Logged" copy.
enum VoiceLogState: Equatable {
    /// Centered mic, not yet recording. Copy: "Tap, then say your <meal>".
    case idle

    /// Request accepted, mic activating — calm acknowledgement, not yet a "Listening"
    /// claim (no byte-flow proof yet). Copy collapses startup churn: "Hold on…".
    case arming

    /// Confirmed listening (byte-flow proven). `elapsed` drives the timer; `transcript`
    /// is the live partial transcript shown beneath the mic (empty until words arrive).
    case listening(elapsed: TimeInterval, transcript: String)

    /// Liveness lapsed mid-capture — escalate from peripheral hint to centered warning
    /// (Serein failure-priority doctrine). Audio is still being recovered.
    case stalled

    /// Capture paused by an interruption/route loss; explicit resume affordance and the
    /// honest auto-finalize countdown. `autoFinalizeIn` is seconds remaining (nil if none).
    case blocked(reason: String, autoFinalizeIn: TimeInterval?)

    /// User stopped; sealing + committing the audio. Not yet "Saved".
    case sealing

    /// Audio durably committed locally. `receipt` is the proof. Transcription begins next.
    case saved(captureID: String)

    /// Turning saved audio into a transcript (on-device on the device path).
    case transcribing(captureID: String)

    /// "Enhancing" — the multi-color gradient sweep plays over the raw words while the
    /// parse computes. `rawText` is the verbatim transcript being enhanced.
    case enhancing(rawText: String)

    /// The parsed meal: calories card, macro chips, per-item cards, checks. `transcript`
    /// is retained for the provenance drawer; `result` is the (possibly refined) parse.
    case result(ResultContext)

    /// Confirmed into a durable log (server row exists). Only this state may say "Logged".
    case logged(MealLogConfirmation)

    /// Honest failure surface. Audio is safe; `retryable` offers a retry affordance.
    case failed(message: String, retryable: Bool)
}

/// Everything the result screen needs, bundled so it travels as one coherent value.
struct ResultContext: Equatable {
    var captureID: String?
    var transcript: String
    var result: ParseResult
    /// True while a refine round-trip is in flight (chips disabled, spinner on the item).
    var isRefining: Bool = false

    /// Items whose clarifying check is still unresolved (a question targets them).
    var unresolvedQuestionFields: [String] {
        result.questions.map(\.field)
    }

    var hasOpenChecks: Bool {
        !result.questions.isEmpty
    }
}
