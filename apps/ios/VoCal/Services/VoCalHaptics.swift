import CoreHaptics
import UIKit

// Port provenance: Serein apps/ios/SereinApp/Sources/SereinHaptics.swift. Renamed; the
// touches and the engine handling are Serein's, dogfood-hardened.

/// The app's touches, deliberately deeper and longer than a click: a rolling swell when a
/// capture starts or stops, a settled double-thump when a save is OBSERVED durable, and a
/// light tick when a pull arms. Custom Core Haptics patterns because the stock impact
/// generators only click; falls back to a heavy impact where the engine is unavailable (old
/// hardware, background, simulator). Haptics are texture, never a claim: `captureSaved` is
/// only called against a commit receipt (the coordinator's `.finalized`), never a deferred
/// commit (claim ladder, AGENTS.md #4).
@MainActor
enum VoCalHaptics {
    private static var engine: CHHapticEngine?

    /// Sustained pulse shared by the two swells: full-strength, low-sharpness body (heavier
    /// vibration, not a longer one) that decays smoothly instead of cutting off.
    private static let swellDuration: TimeInterval = 0.3

    private static func swell(at start: TimeInterval, settlingTo floor: Float) -> (CHHapticEvent, CHHapticParameterCurve) {
        let event = CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.15),
            ],
            relativeTime: start,
            duration: swellDuration
        )
        let curve = CHHapticParameterCurve(
            parameterID: .hapticIntensityControl,
            controlPoints: [
                CHHapticParameterCurve.ControlPoint(relativeTime: start, value: 1.0),
                CHHapticParameterCurve.ControlPoint(relativeTime: start + swellDuration * 0.4, value: 0.85),
                CHHapticParameterCurve.ControlPoint(relativeTime: start + swellDuration * 0.75, value: max(floor, 0.4)),
                CHHapticParameterCurve.ControlPoint(relativeTime: start + swellDuration, value: floor),
            ],
            relativeTime: 0
        )
        return (event, curve)
    }

    /// Capture toggled (start or stop): a firm strike that opens into a deep swell and dies
    /// away. The coordinator's own medium impact on confirmed listening stays separate: that
    /// one marks byte-flow proof, this one acknowledges the finger.
    static func captureToggle() {
        let (body, decay) = swell(at: 0.02, settlingTo: 0.0)
        play(
            events: [
                CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.2),
                    ],
                    relativeTime: 0
                ),
                body,
            ],
            curves: [decay],
            fallbackStyle: .heavy
        )
    }

    /// A pull reaching its threshold (the week strip): one light, short tick, the way
    /// iMessage's reply pull acknowledges the finger. The stock generator is right here.
    static func pullArmed() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred(intensity: 0.7)
    }

    /// Save observed durable: a deep roll that settles, then a firm landing. "It took",
    /// felt without looking.
    static func captureSaved() {
        let (body, decay) = swell(at: 0, settlingTo: 0.3)
        play(
            events: [
                body,
                CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.4),
                    ],
                    relativeTime: swellDuration
                ),
            ],
            curves: [decay],
            fallbackStyle: .heavy
        )
    }

    private static func play(
        events: [CHHapticEvent],
        curves: [CHHapticParameterCurve],
        fallbackStyle: UIImpactFeedbackGenerator.FeedbackStyle
    ) {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            UIImpactFeedbackGenerator(style: fallbackStyle).impactOccurred()
            return
        }
        do {
            if engine == nil {
                let created = try CHHapticEngine()
                // CoreHaptics invokes these on its own serial queue (CHHapticEngineDispatchQueue),
                // most reliably the instant the app backgrounds mid-capture and the audio
                // session pulls the engine out from under it. Formed inside this @MainActor
                // enum, a plain closure inherits main-actor isolation, and the Swift 6 runtime
                // asserts the executor on entry: dispatch_assert_queue, SIGTRAP, a crash sheet.
                // Serein paid three identical crashes on 2026-09-02 for this. @Sendable makes
                // the closures nonisolated; the hop back to the main actor is explicit.
                // TIDY-CONC-004 keeps it that way.
                created.resetHandler = { @Sendable in
                    Task { @MainActor in
                        VoCalHaptics.engine = nil
                    }
                }
                created.stoppedHandler = { @Sendable _ in
                    Task { @MainActor in
                        VoCalHaptics.engine = nil
                    }
                }
                engine = created
            }
            guard let engine else {
                UIImpactFeedbackGenerator(style: fallbackStyle).impactOccurred()
                return
            }
            try engine.start()
            let pattern = try CHHapticPattern(events: events, parameterCurves: curves)
            try engine.makePlayer(with: pattern).start(atTime: CHHapticTimeImmediate)
        } catch {
            // Backgrounded and interrupted engines land here; the click is better than
            // silence and never worth an error surface.
            UIImpactFeedbackGenerator(style: fallbackStyle).impactOccurred()
        }
    }
}
