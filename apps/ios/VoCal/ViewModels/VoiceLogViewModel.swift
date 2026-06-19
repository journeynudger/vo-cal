import Foundation
import Observation
import SwiftUI
import VoCalCore
import VoCalVoice

/// Drives the voice-log screen. Owns the typed `VoiceLogState` and the loop transitions.
/// It is a planner/presenter: it asks the coordinator to capture and the service to derive,
/// then projects their proofs into states — it never invents a stronger claim than the
/// proof it holds (AGENTS.md MUST-NOT #6).
///
/// Two paths, one state machine:
/// - Mock path (sim/UITestMode + DEBUG default): drives the capture rungs on a timer so the
///   full flow is visible with no microphone, then runs the canned service.
/// - Live path: toggles the VoiceCaptureCoordinator (start -> confirmed_listening -> stop ->
///   committed receipt), then runs the live service.
@MainActor
@Observable
final class VoiceLogViewModel {
    private(set) var state: VoiceLogState = .idle

    let mealType: MealType
    var mealName: String

    private let service: any MealCaptureService
    private let coordinator: VoiceCaptureCoordinator?
    private let useMock: Bool
    /// Cadence the mock uses to advance capture rungs (kept short so the demo flows).
    private let mockTick: Duration

    /// The capture id the loop is keyed on. Mock mints a synthetic one; live uses the
    /// coordinator's reserved capture id from the start result.
    private var captureID: String?
    private var clientMealID = UUID().uuidString.lowercased()
    private var loopTask: Task<Void, Never>?

    init(
        mealType: MealType = .lunch,
        mealName: String? = nil,
        service: (any MealCaptureService)? = nil,
        coordinator: VoiceCaptureCoordinator? = nil,
        useMock: Bool = RuntimeMode.usesMockServices,
        mockScenario: MockCaptureScenario = .beefAndRice,
        mockTick: Duration = .milliseconds(450)
    ) {
        self.mealType = mealType
        self.mealName = mealName ?? Self.defaultName(for: mealType)
        self.useMock = useMock
        self.mockTick = mockTick
        if let service {
            self.service = service
        } else if useMock {
            self.service = MockMealCaptureService(scenario: mockScenario)
        } else {
            self.service = LiveMealCaptureService(
                api: APIClient(),
                transcriber: AppleVoiceTranscriber()
            )
        }
        self.coordinator = useMock ? nil : (coordinator ?? .shared)
    }

    // No deinit cancel: loopTask is main-actor state (unreachable from nonisolated deinit),
    // and every loop closure captures `[weak self]`, so a torn-down model's tasks become
    // no-ops rather than leaking. The view (`@State`-owned) is the model's lifetime anchor.

    // MARK: - Capture lifecycle

    /// Begin a capture. Mock animates the capture rungs; live toggles the coordinator.
    func startCapture() {
        guard case .idle = state else { return }
        clientMealID = UUID().uuidString.lowercased()
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            guard let self else { return }
            if self.useMock {
                await self.runMockCapture()
            } else {
                await self.runLiveCapture()
            }
        }
    }

    /// User tapped stop. Mock seals on its own timeline; live toggles the coordinator to
    /// finalize the in-flight session. Only valid while actively listening.
    func stopCapture() {
        guard case .listening = state else { return }
        if useMock {
            // The mock capture task auto-advances; explicit stop just hurries it by
            // letting the running loop observe the request via the state.
            state = .sealing
        } else {
            loopTask?.cancel()
            loopTask = Task { [weak self] in
                await self?.finalizeLiveCapture()
            }
        }
    }

    /// Cancel and reset to idle (the X / Cancel affordance). Audio already committed is not
    /// destroyed — this only abandons the in-progress UI, never the saved capture.
    func cancel() {
        loopTask?.cancel()
        loopTask = nil
        state = .idle
    }

    // MARK: - Result actions

    /// Answer one clarifying question via the service refine round-trip; macros update in
    /// place. Disabled while another refine is in flight.
    func answerQuestion(field: String, optionLabel: String) {
        guard case let .result(context) = state, !context.isRefining else { return }
        var refreshing = context
        refreshing.isRefining = true
        state = .result(refreshing)

        loopTask = Task { [weak self] in
            guard let self else { return }
            do {
                let updated = try await self.service.refine(
                    parseID: context.result.parseId,
                    answers: [RefineAnswer(field: field, value: Self.answerValue(for: field, optionLabel: optionLabel))]
                )
                var next = context
                next.result = updated
                next.isRefining = false
                self.state = .result(next)
            } catch {
                // A refine failure must not lose the result — keep showing it, drop the
                // spinner. The user can retry or log anyway.
                var reverted = context
                reverted.isRefining = false
                self.state = .result(reverted)
            }
        }
    }

    /// "Log anyway" — accept the engine's typical-value defaults for every open check by
    /// answering each with its first option, then proceed to confirm without more prompts.
    func logAnyway() {
        guard case let .result(context) = state, !context.isRefining else { return }
        let answers: [RefineAnswer] = context.result.questions.compactMap { question in
            guard let first = question.options?.first else { return nil }
            return RefineAnswer(field: question.field, value: Self.answerValue(for: question.field, optionLabel: first))
        }
        guard !answers.isEmpty else { return }
        var refreshing = context
        refreshing.isRefining = true
        state = .result(refreshing)
        loopTask = Task { [weak self] in
            guard let self else { return }
            do {
                let updated = try await self.service.refine(parseID: context.result.parseId, answers: answers)
                var next = context
                next.result = updated
                next.isRefining = false
                self.state = .result(next)
            } catch {
                var reverted = context
                reverted.isRefining = false
                self.state = .result(reverted)
            }
        }
    }

    /// Delete an item from the result (user authority). Recomputes totals client-side for
    /// display; the server recomputes authoritatively at confirm.
    func deleteItem(at index: Int) {
        guard case var .result(context) = state, index < context.result.items.count else { return }
        var result = context.result
        result.items.remove(at: index)
        result.totals = result.items.map(\.macros).reduce(.zero, +)
        context.result = result
        state = .result(context)
    }

    /// Confirm the (possibly edited) meal into a durable log. Builds the confirmed items
    /// from the current result and calls the service. Only the returned server confirmation
    /// flips the state to `.logged` (no optimistic "Logged").
    func confirm(saveAsUsual: Bool = false, onLogged: (() -> Void)? = nil) {
        guard case let .result(context) = state, !context.isRefining else { return }
        let request = LogMealRequest(
            clientMealID: clientMealID,
            parseID: context.result.parseId,
            name: mealName,
            mealType: mealType,
            items: context.result.items.map(ConfirmedItem.init(from:)),
            saveAsUsual: saveAsUsual
        )
        loopTask = Task { [weak self] in
            guard let self else { return }
            do {
                let confirmation = try await self.service.logMeal(request)
                self.state = .logged(confirmation)
                onLogged?()
            } catch {
                // Confirm failed: keep the result on screen so nothing is lost; surface a
                // retryable failure banner. (D5 queues this offline; here we stay honest.)
                self.state = .failed(message: "Couldn't log the meal — try again.", retryable: true)
            }
        }
    }

    /// Retry the post-capture pipeline from the saved audio (after a transcribe/parse fail).
    func retry() {
        guard let captureID else {
            cancel()
            return
        }
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            await self?.runDerivedPipeline(captureID: captureID, audioURL: nil)
        }
    }

    // MARK: - Mock path

    private func runMockCapture() async {
        // accepted -> arming (calm acknowledgement, no claim yet)
        state = .arming
        try? await Task.sleep(for: mockTick)
        if Task.isCancelled { return }

        // confirmed_listening: the only point we are allowed to say "Listening".
        let synthetic = "voice_mock_\(UUID().uuidString.lowercased().prefix(6))"
        captureID = synthetic
        let fullTranscript = MealCaptureFixtures.transcript(for: .beefAndRice)
        let start = Date()
        // Stream the partial transcript like a live dictation; stop when the user taps stop
        // (state flips to .sealing) or the utterance completes.
        var shown = ""
        var i = 0
        let words = fullTranscript.split(separator: " ").map(String.init)
        while i < words.count {
            if Task.isCancelled { return }
            if case .sealing = state { break }
            shown += (shown.isEmpty ? "" : " ") + words[i]
            i += 1
            state = .listening(elapsed: Date().timeIntervalSince(start), transcript: shown)
            try? await Task.sleep(for: .milliseconds(140))
        }
        if Task.isCancelled { return }

        // Seal + commit (auto, since the mock has no real recorder).
        if case .sealing = state {} else { state = .sealing }
        try? await Task.sleep(for: mockTick)
        if Task.isCancelled { return }

        state = .saved(captureID: synthetic)
        try? await Task.sleep(for: .milliseconds(250))
        if Task.isCancelled { return }
        await runDerivedPipeline(captureID: synthetic, audioURL: nil)
    }

    // MARK: - Live path

    private func runLiveCapture() async {
        guard let coordinator else { state = .failed(message: "Voice unavailable.", retryable: false); return }
        guard await coordinator.requestMicrophonePermission() else {
            state = .blocked(reason: "Microphone access is off. Turn it on in Settings.", autoFinalizeIn: nil)
            return
        }
        state = .arming
        do {
            let result = try await coordinator.toggle(reason: "voice_log", executionMode: .foregroundApp)
            switch result.action {
            case let .started(captureID):
                // The coordinator returns `.started` only after the liveness kernel confirms
                // byte flow — this is the byte-flow proof that licenses "Listening".
                self.captureID = captureID
                state = .listening(elapsed: 0, transcript: "")
                await pollLiveElapsed(captureID: captureID, start: Date())
            case let .blocked(captureID):
                self.captureID = captureID
                state = .blocked(reason: "Couldn't confirm the mic is live.", autoFinalizeIn: nil)
            default:
                state = .failed(message: "Couldn't start recording.", retryable: true)
            }
        } catch {
            state = .failed(message: "Couldn't start recording.", retryable: true)
        }
    }

    private func pollLiveElapsed(captureID: String, start: Date) async {
        // Lightweight elapsed-timer tick while listening; the coordinator owns liveness.
        while !Task.isCancelled {
            guard case .listening = state else { return }
            state = .listening(elapsed: Date().timeIntervalSince(start), transcript: "")
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private func finalizeLiveCapture() async {
        guard let coordinator else { return }
        state = .sealing
        do {
            let result = try await coordinator.toggle(reason: "voice_log_stop", executionMode: .foregroundApp)
            switch result.action {
            case let .finalized(captureID):
                // `.finalized` means the final artifact is durably committed — the receipt
                // that licenses "Saved".
                self.captureID = captureID
                state = .saved(captureID: captureID)
                await runDerivedPipeline(captureID: captureID, audioURL: nil)
            case let .deferred(captureID):
                state = .saved(captureID: captureID)
                await runDerivedPipeline(captureID: captureID, audioURL: nil)
            default:
                state = .failed(message: "Couldn't finish saving — your audio is safe.", retryable: true)
            }
        } catch {
            state = .failed(message: "Couldn't finish saving — your audio is safe.", retryable: true)
        }
    }

    // MARK: - Shared derived pipeline (transcribe -> enhance/parse -> result)

    private func runDerivedPipeline(captureID: String, audioURL: URL?) async {
        do {
            state = .transcribing(captureID: captureID)
            let transcript = try await service.transcribe(captureID: captureID, audioURL: audioURL)
            if Task.isCancelled { return }

            state = .enhancing(rawText: transcript)
            let parse = try await service.parse(transcript: transcript, captureID: captureID)
            if Task.isCancelled { return }

            state = .result(ResultContext(captureID: captureID, transcript: transcript, result: parse))
        } catch {
            state = .failed(message: "Couldn't analyze the meal — your audio is safe.", retryable: true)
        }
    }

    // MARK: - Helpers

    private static func defaultName(for mealType: MealType) -> String {
        switch mealType {
        case .breakfast: return "Breakfast"
        case .lunch: return "Lunch"
        case .dinner: return "Dinner"
        case .snack: return "Snack"
        case .unspecified: return "Meal"
        }
    }

    /// Amount-field answers go as numbers; everything else (fat ratio, variant) as strings.
    private static func answerValue(for field: String, optionLabel: String) -> RefineAnswer.AnswerValue {
        if field.hasSuffix(".amount"), let number = Double(optionLabel) {
            return .number(number)
        }
        return .string(optionLabel)
    }
}
