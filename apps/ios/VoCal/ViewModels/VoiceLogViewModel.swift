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

    /// Oz of water routed to the hydration tally on the last confirm (0 if none) — drives the
    /// "added to your water log" line on the logged screen so detected water is acknowledged.
    private(set) var lastLoggedWaterOz: Double = 0
    /// The last confirm was water-only (no food meal row) → the logged screen shows only the
    /// hydration line, never a misleading "0 cal · Water" meal receipt.
    private(set) var lastLogWasWaterOnly = false

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

    /// The result being amended when the user adds a spoken detail (certainty banner tap).
    /// The next capture's transcript is appended to this context's transcript and the
    /// COMBINED text is re-parsed — a new superseding parse record, never a mutation of
    /// the original (INVARIANTS §14: corrections are append-only records). Survives derived
    /// failures so retry stays an amend; cleared when the amended result lands or the user
    /// abandons the detail capture.
    private var amending: ResultContext?

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
                // Read-only audio source for the derived upload/transcribe step. The shared
                // coordinator owns the committed capture; transcription is server-side now.
                audioReader: VoiceCaptureCoordinator.shared,
                deviceName: nil
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
    /// Abandoning an add-detail capture returns to the result it was amending — the parsed
    /// meal must not be lost because a follow-up utterance was aborted.
    func cancel() {
        loopTask?.cancel()
        loopTask = nil
        if let prior = amending {
            amending = nil
            state = .result(prior)
        } else {
            state = .idle
        }
    }

    /// Add a spoken detail to the current result (certainty banner → "add detail" flow).
    /// Re-enters the capture flow; the new utterance is appended to the existing transcript
    /// and the combined text re-parses, so the estimate sharpens without re-logging the meal.
    func addDetail() {
        guard case let .result(context) = state else { return }
        amending = context
        state = .idle
        startCapture()
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

    /// Apply direct per-item edits (amount/unit/fat-ratio/state) as a refine round-trip — the
    /// server re-resolves and returns new macros + confidence, so an edit can push a flagged
    /// item to high confidence. Same mechanism as answering a check, just user-initiated fields.
    func applyEdits(_ answers: [RefineAnswer]) {
        guard case let .result(context) = state, !context.isRefining, !answers.isEmpty else { return }
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
    /// The confirmed meal's certainty annotation, kept for the logged surface's coaching
    /// note (the `.logged` state carries only the server confirmation).
    private(set) var lastCertainty: MealCertainty?

    func confirm(saveAsUsual: Bool = false, onLogged: (() -> Void)? = nil) {
        guard case let .result(context) = state, !context.isRefining else { return }
        // Nothing left to log (the user deleted every item) → discard, never confirm.
        // Confirming synthesized a "Water logged — 0 oz" receipt with NO server row of any
        // kind: a fabricated claim above proof (MUST-NOT #6). Cancel is the honest verb.
        guard !context.result.items.isEmpty else {
            cancel()
            return
        }
        lastCertainty = context.result.certainty
        // Water is hydration, not a meal (bugs 1/2): split water items out and log them to the
        // /meals/water tally the Today water card reads. The remaining FOOD items become the
        // meal_log. A water-only capture creates NO meal record (no calorie/nutrition row).
        let waterItems = context.result.items.filter { Self.isWater($0) }
        let foodItems = context.result.items.filter { !Self.isWater($0) }
        let hydrationOz = waterItems.reduce(0.0) { $0 + Self.ounces($1) }
        let mealRequest = foodItems.isEmpty ? nil : LogMealRequest(
            clientMealID: clientMealID,
            parseID: context.result.parseId,
            name: mealName,
            mealType: mealType,
            items: foodItems.map(ConfirmedItem.init(from:)),
            saveAsUsual: saveAsUsual
        )
        loopTask = Task { [weak self] in
            guard let self else { return }
            do {
                var loggedWaterOz = 0.0
                if hydrationOz > 0 {
                    // Stable client_water_id (derived from the capture's meal id) so a re-confirm
                    // after a partial failure dedups server-side instead of double-counting the
                    // water in /today (RT-13 idempotency — never mint a fresh id per attempt).
                    _ = try await self.service.logWater(
                        WaterLogRequest(clientWaterID: "water-\(self.clientMealID)", amountOz: hydrationOz)
                    )
                    loggedWaterOz = hydrationOz
                }
                self.lastLoggedWaterOz = loggedWaterOz
                self.lastLogWasWaterOnly = mealRequest == nil
                if let mealRequest {
                    self.state = .logged(try await self.service.logMeal(mealRequest))
                } else {
                    // Water-only: no meal row (no calorie/nutrition row). Synthesize a receipt so the
                    // reward beat still shows; the logged screen renders the hydration line (not a
                    // "0 cal · Water" meal), telling the user it went to the water log.
                    self.state = .logged(MealLogConfirmation(
                        id: "water-\(self.clientMealID)", name: "Water", mealType: .unspecified,
                        totals: NutrientProfile(kcal: 0, protein: 0, carbs: 0, fat: 0, fiber: 0),
                        confidence: 1, correctionsCount: 0
                    ))
                }
                onLogged?()
            } catch {
                // Confirm failed: keep the audio/result intact; surface the SPECIFIC failure
                // (offline vs server status vs contract drift) so retry guidance is honest.
                // (D5 queues this offline; here we stay honest.)
                self.state = Self.failedState(stage: .log, error: error)
            }
        }
    }

    // MARK: - Hydration classification (water is not a meal)

    /// Unambiguous water terms only — never "watermelon", "coconut water"/"tonic water" (have
    /// calories), etc. The classifier matches the FULL name (after stripping benign container
    /// words) against this set, so calorie-bearing "<x> water" drinks never qualify.
    private static let waterNames: Set<String> = [
        "water", "waters", "still water", "plain water", "tap water", "bottled water", "ice water",
        "sparkling water", "seltzer", "seltzer water", "carbonated water", "mineral water", "h2o",
    ]

    /// Leading quantity/container words that don't change what the drink IS, stripped before
    /// matching so "a glass of water", "bottle of sparkling water", "some cold water" classify as
    /// water. The REMAINDER must still be an exact `waterNames` match — so "coconut water",
    /// "tonic water", "watermelon" (all caloric) never qualify. (Bug 2026-07: the old exact-match
    /// missed every container phrasing, so spoken water was never routed to the hydration tally.)
    private static let waterQualifiers: Set<String> = [
        "a", "an", "one", "some", "my", "the", "of", "glass", "glasses", "bottle", "bottles",
        "cup", "cups", "cold", "iced", "ice", "cool", "warm", "large", "small", "big", "tall",
        "little", "quick", "another", "half",
    ]

    private static func isWater(_ item: ParseResultItem) -> Bool {
        let normalized = item.name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if waterNames.contains(normalized) { return true }
        // Drop leading benign qualifiers ("a glass of", "some cold"), then require the core to be
        // an exact water term. Substring matching is deliberately avoided (it would catch
        // "watermelon"); only a clean water remainder counts.
        var tokens = normalized.split(separator: " ").map(String.init)
        while let first = tokens.first, waterQualifiers.contains(first) { tokens.removeFirst() }
        return waterNames.contains(tokens.joined(separator: " "))
    }

    /// Ounces of water from the stated amount+unit; an unstated amount defaults to one 8 oz glass.
    private static func ounces(_ item: ParseResultItem) -> Double {
        let amount = item.amount ?? 1
        switch item.unit {
        case .oz: return amount
        case .ml: return amount / 29.5735
        case .cup: return amount * 8
        case .tbsp: return amount * 0.5
        case .tsp: return amount / 6
        case .g: return amount / 29.5735  // water ≈ 1 g/ml
        default: return amount * 8         // glass / piece / unstated serving ≈ 8 oz
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
                // Commit was DEFERRED — the audio is NOT yet confirmed durably committed, so we
                // must not claim "Saved" (which asserts a local commit receipt; AGENTS.md #4
                // claim ladder). Proceed to derive from the captured audio (transcribing is an
                // honest claim — we have the bytes); the outbox converges the durable commit.
                self.captureID = captureID
                await runDerivedPipeline(captureID: captureID, audioURL: nil)
            default:
                state = .failed(message: "Couldn't finish saving - your audio is safe.", retryable: true)
            }
        } catch {
            state = .failed(message: "Couldn't finish saving - your audio is safe.", retryable: true)
        }
    }

    // MARK: - Shared derived pipeline (transcribe -> enhance/parse -> result)

    private func runDerivedPipeline(captureID: String, audioURL: URL?) async {
        // Cold-launch auth race (the "fails once, then works on retry" the user hit): the FIRST
        // derived call after launch — uploadCapture → POST /captures — went out BEFORE the
        // persisted Supabase session was restored into the token store, so it 401'd and the
        // generic catch surfaced "couldn't analyze the meal"; the manual retry only worked
        // because the session had since restored. Await a ready session first (idempotent no-op
        // once one exists) — the same guard LiveTodayService already uses. Live-only; off the
        // capture hot path (this runs post-.saved/.deferred, never on startCapture).
        if !useMock { await AuthCoordinator.shared.ensureSession() }

        // Each stage catches SEPARATELY so the failure names what actually broke (the old
        // single catch collapsed 6+ distinct failures into "Couldn't analyze the meal",
        // which hid the is_estimate decode bug and the noAudio outbox race from every
        // field report). Messages + diagnostic codes live in VoCalCore.pipelineFailureCopy.
        state = .transcribing(captureID: captureID)
        let transcription: MealTranscription
        do {
            transcription = try await withTransientRetry {
                try await service.transcribe(captureID: captureID, audioURL: audioURL)
            }
        } catch {
            if !Task.isCancelled { state = Self.failedState(stage: .transcribe, error: error) }
            return
        }
        if Task.isCancelled { return }

        // No speech detected (silent/too-short recording): the server parser requires words
        // (ParseRequest.transcript min_length 1), so a blank transcript would 422 and surface
        // a parse error. Tell the user the real reason instead, and keep the audio — retry
        // stays available (the capture is already committed).
        guard !transcription.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            state = .failed(
                message: "I didn't catch any food - speak your meal and try again.",
                retryable: true,
                detail: "empty_transcript"
            )
            return
        }

        state = .enhancing(rawText: transcription.text)
        // Amend flow: the detail utterance joins the original transcript and the COMBINED
        // text re-parses — the server stores it as a new parse record, so preview, durable
        // row, and certainty re-score all see the full statement of the meal.
        let transcriptForParse: String
        if let amending {
            transcriptForParse = Self.combinedTranscript(amending.transcript, transcription.text)
        } else {
            transcriptForParse = transcription.text
        }
        // Parse with the SERVER capture UUID (not the local `voice_...` id, which 422s
        // against ParseRequest.capture_id: UUID | None). ResultContext keeps the local
        // capture id as the loop/display key.
        let parse: ParseResult
        do {
            parse = try await withTransientRetry {
                try await service.parse(transcript: transcriptForParse, captureID: transcription.serverCaptureID)
            }
        } catch {
            if !Task.isCancelled { state = Self.failedState(stage: .parse, error: error) }
            return
        }
        if Task.isCancelled { return }

        amending = nil
        state = .result(ResultContext(captureID: captureID, transcript: transcriptForParse, result: parse))
    }

    /// Map a pipeline error into the honest, specific failure state. Classification happens
    /// here at the boundary (parse, don't validate); the copy + codes live in VoCalCore so
    /// they are unit-tested (PipelineFailureTests).
    private static func failedState(stage: PipelineStage, error: any Error) -> VoiceLogState {
        let copy = pipelineFailureCopy(stage: stage, kind: classify(error))
        return .failed(message: copy.message, retryable: copy.retryable, detail: copy.code)
    }

    /// Join an original meal transcript and a follow-up detail utterance into the single
    /// statement the parser sees. Sentence-joined so the parser's side-phrase and linkage
    /// grammar ("with", "containing") reads the detail in context of the whole meal.
    static func combinedTranscript(_ original: String, _ detail: String) -> String {
        let base = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let extra = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !extra.isEmpty else { return base }
        guard !base.isEmpty else { return extra }
        let endsInPunctuation = ".!?".contains(base.suffix(1))
        return base + (endsInPunctuation ? " " : ". ") + extra
    }

    private static func classify(_ error: any Error) -> PipelineFailureKind {
        if case TranscriptionError.noAudio = error { return .noAudio }
        guard let api = error as? APIError else { return .unknown }
        switch api {
        case .transport: return .offline
        case let .status(code, _): return .serverStatus(code)
        case .decoding: return .contractMismatch
        case .badURL: return .unknown
        }
    }

    /// Retry the transient failure class that made the first meal attempt flaky: a tokenless
    /// request before the session restored (401), a Fly/ElevenLabs/LLM cold-start (5xx/timeout),
    /// or a just-deferred capture whose durable blob hasn't converged yet (noAudio). Bounded
    /// so it always converges (INVARIANTS §9); never retries a terminal error (422 bad
    /// transcript, 404 provenance) — those keep their specific handling. Re-establishes the session
    /// before each retry in case the first failure was the auth race. Only wraps the derived-rung
    /// network calls; the claim ladder is unchanged (state still flips only on real server proofs).
    ///
    /// noAudio gets its own, more patient ladder (~15s total): a commit DEFERRED at stop (locked
    /// device, transient outbox contention) converges via the outbox monitor on its own cadence,
    /// which routinely outlasts the ~4.6s network ladder — the dominant "couldn't analyze" report
    /// was this exact race timing out with zero server traffic. Still bounded; on exhaustion the
    /// taxonomy's no_audio copy tells the user the audio is still saving and to retry.
    private func withTransientRetry<T>(_ operation: () async throws -> T) async throws -> T {
        let networkBackoffs: [Duration] = [.milliseconds(400), .milliseconds(1200), .seconds(3)]
        let noAudioBackoffs: [Duration] = [
            .milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(8),
        ]
        var attempt = 0
        while true {
            do {
                return try await operation()
            } catch {
                let isNoAudio = if case TranscriptionError.noAudio = error { true } else { false }
                let backoffs = isNoAudio ? noAudioBackoffs : networkBackoffs
                guard !Task.isCancelled, attempt < backoffs.count, Self.isTransient(error) else { throw error }
                if !useMock, !isNoAudio { await AuthCoordinator.shared.ensureSession() }
                try? await Task.sleep(for: backoffs[attempt])
                attempt += 1
            }
        }
    }

    private static func isTransient(_ error: any Error) -> Bool {
        if let api = error as? APIError {
            switch api {
            case .transport: return true  // timeout / connection lost / cold-start wake
            case let .status(code, _): return code == 401 || code == 408 || code == 429 || (500...599).contains(code)
            case .badURL, .decoding: return false  // terminal — a retry can't fix these
            }
        }
        // A capture finalized as .deferred can be read before the outbox has populated its durable
        // blob; that surfaces as noAudio. Give the outbox a moment and retry rather than failing.
        if case TranscriptionError.noAudio = error { return true }
        return false
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
