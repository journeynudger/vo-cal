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
    /// `committed` is whether the local durable commit is PROVEN (a deferred commit
    /// reaches this state too) — the "Saved" chip is licensed by it, per the claim
    /// ladder (AGENTS.md #4): "Saving…" is honest mid-flight; "Saved" needs the receipt.
    case transcribing(captureID: String, committed: Bool)

    /// "Enhancing" — the multi-color gradient sweep plays over the raw words while the
    /// parse computes. `rawText` is the verbatim transcript being enhanced. `committed`
    /// as in `.transcribing` — a deferred commit must not render "Saved" here either.
    case enhancing(rawText: String, committed: Bool)

    /// The parsed meal: calories card, macro chips, per-item cards, checks. `transcript`
    /// is retained for the provenance drawer; `result` is the (possibly refined) parse.
    case result(ResultContext)

    /// Confirmed into a durable log (server row exists). Only this state may say "Logged".
    case logged(MealLogConfirmation)

    /// Honest failure surface. Audio is safe; `retryable` offers a retry affordance.
    /// `detail` is the short machine-stable diagnostic code (e.g. "transcribe_502",
    /// "parse_decode") rendered small on the surface so a beta report pinpoints the
    /// failing stage + failure class without a debugger.
    case failed(message: String, retryable: Bool, detail: String? = nil)
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
