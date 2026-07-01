import Foundation
import Testing
import VoCalCapture
@testable import VoCalVoice

/// Focused reducer tests for two convergence fixes the gated DST harness can't reach:
/// the DST world only advances time forward, so it never exercises a BACKWARD clock
/// correction, and it asserts coverage properties rather than these specific transitions.
struct VoiceKernelBlockedDeadlineTests {
    private let kernel = VoiceCoordinatorKernel(constants: VoiceCaptureConstants())
    private let cleared = Date(timeIntervalSince1970: 1_000_000)
    private var deadline: Date { cleared.addingTimeInterval(300) }  // blockedAutoFinalizeInterval

    private func blockedClearedState() -> VoiceKernelState {
        let snapshot = VoiceSessionSnapshot(
            sessionID: "s1",
            captureID: "voice_x",
            phase: .blocked,
            sourceSurface: CaptureSourceSurface.nativeRecorder.rawValue,
            createdAt: cleared,
            updatedAt: cleared,
            heartbeatAt: cleared,
            recoveryCount: 0,
            blockedReason: .interruption,
            blockerClearedAt: cleared,
            blockedAutoFinalizeAt: deadline
        )
        let managed = VoiceKernelManagedSession(
            snapshot: snapshot, generation: 1, mixWithOthers: false, toggleRequestIDs: []
        )
        return VoiceKernelState(current: managed, nextGeneration: 2)
    }

    @Test("Backward clock skew finalizes a blocked capture instead of wedging it")
    func backwardSkewFinalizes() {
        var state = blockedClearedState()
        // NTP/manual correction moves the clock back past the clear instant. A plain
        // observed >= deadline would never fire and the partial would wedge in .blocked.
        _ = kernel.step(
            state: &state,
            event: .blockedDeadlineObservedExpired(observedAt: cleared.addingTimeInterval(-100))
        )
        #expect(state.current?.snapshot.phase == .finalizing)
    }

    @Test("An observation within the window does not finalize early")
    func withinWindowStaysBlocked() {
        var state = blockedClearedState()
        _ = kernel.step(
            state: &state,
            event: .blockedDeadlineObservedExpired(observedAt: cleared.addingTimeInterval(10))
        )
        #expect(state.current?.snapshot.phase == .blocked)
    }

    @Test("Tiny benign backward slew does not finalize a still-resumable session")
    func tinyBackwardSlewIsToleratedWithinSlack() {
        var state = blockedClearedState()
        _ = kernel.step(
            state: &state,
            event: .blockedDeadlineObservedExpired(observedAt: cleared.addingTimeInterval(-1))
        )
        #expect(state.current?.snapshot.phase == .blocked)
    }

    @Test("Normal forward expiry still finalizes")
    func forwardPastDeadlineFinalizes() {
        var state = blockedClearedState()
        _ = kernel.step(
            state: &state,
            event: .blockedDeadlineObservedExpired(observedAt: deadline.addingTimeInterval(1))
        )
        #expect(state.current?.snapshot.phase == .finalizing)
    }

    @Test("recoverySucceeded clears recoveryMode like every other terminal handler")
    func recoverySucceededClearsRecoveryMode() {
        let snapshot = VoiceSessionSnapshot(
            sessionID: "s1",
            captureID: "voice_x",
            phase: .recovering,
            sourceSurface: CaptureSourceSurface.nativeRecorder.rawValue,
            createdAt: cleared,
            updatedAt: cleared,
            heartbeatAt: cleared,
            recoveryCount: 1
        )
        let managed = VoiceKernelManagedSession(
            snapshot: snapshot,
            generation: 3,
            mixWithOthers: false,
            toggleRequestIDs: [],
            recoveryMode: .nominalInputFormatChange
        )
        var state = VoiceKernelState(current: managed, nextGeneration: 4)
        let recovered = VoiceSessionSnapshot(
            sessionID: "s1",
            captureID: "voice_x",
            phase: .recordingLive,
            sourceSurface: CaptureSourceSurface.nativeRecorder.rawValue,
            createdAt: cleared,
            updatedAt: cleared,
            heartbeatAt: cleared,
            recoveryCount: 1
        )
        _ = kernel.step(state: &state, event: .recoverySucceeded(generation: 3, session: recovered))
        #expect(state.current?.recoveryMode == nil)
    }
}
