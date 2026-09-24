import SwiftUI
import UIKit
import VoCalCore

/// Session-scoped frequency cap for the post-log coaching note (spec: max one note per
/// app session — repeated patterns belong in the weekly summary, not per-log nagging).
@MainActor
enum CoachingSession {
    static var noteShown = false
}

/// Full-screen voice-log sheet. Renders the claim-ladder-honest capture flow (centered mic
/// -> Listening -> Transcribing -> Enhancing sweep) and the parse result (calories card,
/// macro chips, transcript drawer, item cards + per-ingredient checks, Log meal). Black/gold,
/// VoCalTheme tokens only.
///
/// The view is a pure projection of `VoiceLogViewModel.state`: it never derives a stronger
/// claim than the state carries. Copy is gated on the state case — "Listening" only renders
/// in `.listening` (entered on byte-flow proof), "Saved" only in `.saved`/after, "Logged"
/// only in `.logged`.
struct VoiceLogView: View {
    @State private var model: VoiceLogViewModel
    @State private var didAutoStart = false
    @Environment(\.dismiss) private var dismiss
    var onLogged: (() -> Void)?
    /// Start listening on appear (the center mic opens straight into recording — one tap, no
    /// "tap to record" step). The capture path is unchanged; this just fires startCapture once.
    var autoStart: Bool
    /// Open on a saved recording (Today's Unfinished list): the derived pipeline runs from
    /// the committed audio, no capture step.
    var resumeCaptureID: String?
    /// Open on a typed text or a photo from the capture bar: straight to the parse, no
    /// recording (docs/CAPTURE_LIFECYCLE.md §9).
    var submission: CaptureSubmission?

    init(
        mealType: MealType = .unspecified,
        targetDate: Date = .now,
        appendTarget: VoiceLogViewModel.AppendTarget? = nil,
        autoStart: Bool = false,
        resumeCaptureID: String? = nil,
        submission: CaptureSubmission? = nil,
        model: VoiceLogViewModel? = nil,
        onLogged: (() -> Void)? = nil
    ) {
        _model = State(
            initialValue: model ?? VoiceLogViewModel(
                mealType: mealType, targetDate: targetDate, appendTarget: appendTarget
            )
        )
        self.autoStart = autoStart
        self.resumeCaptureID = resumeCaptureID
        self.submission = submission
        self.onLogged = onLogged
    }

    var body: some View {
        ZStack {
            VoCalTheme.Colors.background.ignoresSafeArea()
            content
        }
        .accessibilityIdentifier(A11y.VoiceLog.screen)
        // The server row landed: the system's success tick, from the state that proves it.
        .sensoryFeedback(.success, trigger: isLogged) { _, logged in logged }
        // The result screen renders its own close button inside its header (so it never covers
        // the title); every other surface is centered content where a floating top-left X is fine.
        .overlay(alignment: .topLeading) { if showsFloatingClose { closeButton } }
        // Backdated log: when the capture targets a day other than today, say so the
        // whole way through — a log silently landing on another day would read as
        // data loss on Today (facts-first surface, mirrored from the claim ladder).
        // On the result screen, the chip moves inside the calories card to avoid crowding
        // the header; it only floats during capture states.
        // The commit-status tag ("Saved"/"Saving…") shares this ONE top stack: it used to be
        // positioned independently inside each surface and collided with the date chip when
        // logging to a past day (field bug 2026-08-19, build 23 screenshot).
        .overlay(alignment: .top) {
            VStack(spacing: VoCalTheme.Spacing.s) {
                if showsFloatingTargetChip {
                    targetDayChip
                }
                commitStatusTag
            }
            // Clears the result header row (X · title · confidence) so the stack never
            // sits on the "Meal" title; on capture surfaces the top is empty anyway.
            .padding(.top, VoCalTheme.Spacing.l + VoCalTheme.Spacing.xxl)
        }
        // Keep the screen lit while recording/processing so an auto-lock can't suspend the app
        // mid-capture (the audio still survives a lock — the outbox is durable — but a tester
        // shouldn't have to fight the screen timeout to finish a meal). Reset whenever we leave
        // those states or the sheet closes, so we never hold the screen awake indefinitely.
        .onChange(of: keepsScreenAwake, initial: true) { _, awake in
            UIApplication.shared.isIdleTimerDisabled = awake
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .task {
            guard !didAutoStart else { return }
            if let resumeCaptureID {
                didAutoStart = true
                model.resume(captureID: resumeCaptureID)
            } else if let submission {
                didAutoStart = true
                switch submission {
                case let .text(text):
                    model.startTyped(text)
                case let .photo(data, note):
                    model.startPhoto(data, note: note)
                }
            } else if autoStart {
                didAutoStart = true
                if case .idle = model.state { model.startCapture() }
            }
        }
    }

    /// Pinned banner naming the day this log will land on (only during capture states,
    /// when the target isn't today; the result screen moves this to the calories card).
    private var targetDayChip: some View {
        HStack(spacing: VoCalTheme.Spacing.xs) {
            Image(systemName: "calendar")
                .font(.system(size: 12, weight: .semibold))
            Text(formattedTargetDayLabel())
                .font(VoCalTheme.Fonts.chipLabel)
        }
        .foregroundStyle(VoCalTheme.Colors.ink)
        .padding(.horizontal, VoCalTheme.Spacing.m)
        .padding(.vertical, 7)
        .background(VoCalTheme.Colors.gold.opacity(0.16), in: Capsule())
        .overlay(Capsule().strokeBorder(VoCalTheme.Colors.goldBorder, lineWidth: 1))
        .accessibilityIdentifier(A11y.VoiceLog.targetDayChip)
    }

    /// Commit-status tag for the top stack: "Saved" is licensed by the commit receipt only
    /// (claim ladder, AGENTS.md #4); a deferred commit shows honest "Saving…" while the
    /// outbox converges. Derived straight from the state cases so it can never outrun proof.
    @ViewBuilder
    private var commitStatusTag: some View {
        if !model.hasCapture {
            // A typed or photographed log has no recording to have saved: no claim, no tag.
            EmptyView()
        } else {
            capturedStatusTag
        }
    }

    @ViewBuilder
    private var capturedStatusTag: some View {
        switch model.state {
        case .saved:
            statusTag(icon: "checkmark.circle.fill", label: ClaimCopy.saved, proven: true)
        case let .transcribing(_, committed) where committed:
            statusTag(icon: "checkmark.circle.fill", label: ClaimCopy.saved, proven: true)
        case let .enhancing(_, committed):
            statusTag(
                icon: committed ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath",
                label: committed ? ClaimCopy.saved : ClaimCopy.saving,
                proven: committed
            )
        default:
            EmptyView()
        }
    }

    private func statusTag(icon: String, label: String, proven: Bool) -> some View {
        HStack(spacing: VoCalTheme.Spacing.xs) {
            Image(systemName: icon)
            Text(label)
        }
        .font(VoCalTheme.Fonts.formLabel.weight(.semibold))
        .foregroundStyle(proven ? VoCalTheme.Colors.gold : VoCalTheme.Colors.muted)
    }

    /// While recording or processing, the screen must not auto-lock (which suspends the app
    /// mid-capture). Off for idle/result/logged/failed so the device can sleep normally.
    private var keepsScreenAwake: Bool {
        switch model.state {
        case .arming, .listening, .stalled, .blocked, .sealing, .saved, .transcribing, .enhancing:
            return true
        case .idle, .result, .logged, .failed:
            return false
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            captureScaffold(mic: .idle, tapAction: { model.startCapture() })
        case .arming:
            captureScaffold(mic: .arming)
        case let .listening(elapsed, transcript):
            captureScaffold(mic: .listening, elapsed: elapsed, transcript: transcript)
        case .stalled:
            stalledSurface
        case let .blocked(reason, autoFinalizeIn):
            blockedSurface(reason: reason, autoFinalizeIn: autoFinalizeIn)
        case .sealing:
            // No commit receipt yet — "Saved" here was a claim-ladder violation (INVARIANTS §2:
            // "Saving…" is permitted during intermediate states; "Saved" is not).
            processingSurface(line: ClaimCopy.saving)
        case .saved:
            processingSurface(line: "\(ClaimCopy.saved) - analyzing\u{2026}")
        case .transcribing:
            // The "Saved"/"Saving…" tag renders in the top overlay stack (commitStatusTag).
            processingSurface(line: "Transcribing\u{2026}")
        case let .enhancing(rawText, _):
            enhancingSurface(rawText: rawText)
        case let .result(context):
            VoiceLogResultView(
                context: context,
                mealType: model.mealType,
                targetDayLabel: Calendar.current.isDateInToday(model.targetDate) ? nil : formattedTargetDayLabel(),
                appendingTo: model.appendTarget?.displayName,
                onAnswer: { field, option in model.answerQuestion(field: field, optionLabel: option) },
                onLogAnyway: { model.logAnyway() },
                onDelete: { index in model.deleteItem(at: index) },
                onConfirm: { saveAsUsual in
                    model.confirm(saveAsUsual: saveAsUsual) {
                        onLogged?()
                    }
                },
                onEditItem: { answers in model.applyEdits(answers) },
                onAddDetail: { model.addDetail() },
                onAcceptUsual: { model.acceptRecognized() },
                onDismissUsual: { model.dismissRecognized() },
                onLabelFood: { index, request, servingsEaten in
                    try await model.saveLabelFood(request, for: index, servingsEaten: servingsEaten)
                },
                onSaveBatch: { name, servings in try await model.saveBatch(name: name, servings: servings) },
                onLogServing: { food in model.logServing(of: food) { onLogged?() } },
                onClose: {
                    model.cancel()
                    dismiss()
                }
            )
        case let .logged(confirmation):
            loggedSurface(confirmation)
        case let .failed(message, retryable, _, transcript):
            failureSurface(message: message, retryable: retryable, transcript: transcript)
        }
    }

    private var mealNoun: String {
        switch model.mealType {
        case .breakfast: return "breakfast"
        case .lunch: return "lunch"
        case .dinner: return "dinner"
        case .snack: return "snack"
        case .unspecified: return "meal"
        }
    }

    /// Screen overline: "Log lunch" for a new meal, "Add to Meal 2" when appending.
    private var screenLabel: String {
        if let target = model.appendTarget { return "Add to \(target.displayName)" }
        return "Log \(mealNoun)"
    }

    /// Idle prompt under the mic — append mode asks for the addition, not a whole meal.
    private var idlePrompt: String {
        model.isAppending ? "Tap, then say what to add" : "Tap, then say your \(mealNoun)"
    }

    // MARK: - Chrome

    /// The result screen owns its close button (in its header); all other surfaces use the
    /// floating top-left X. Gating here is what stops the X from covering the result title.
    private var isLogged: Bool {
        if case .logged = model.state { return true }
        return false
    }

    private var showsFloatingClose: Bool {
        if case .result = model.state { return false }
        return true
    }

    /// The target-day chip floats only during capture states (mic/listening/processing).
    /// On the result screen, the chip lives inside the calories card instead, so the
    /// floating version would double up if shown here.
    private var showsFloatingTargetChip: Bool {
        if case .result = model.state { return false }
        return !Calendar.current.isDateInToday(model.targetDate)
    }

    /// Formatted display string for backdated logs: "Logging to Monday, August 16".
    /// Centralized to keep the floating overlay and result-screen chip in sync.
    private func formattedTargetDayLabel() -> String {
        "Logging to \(model.targetDate.formatted(.dateTime.weekday(.wide).month().day()))"
    }

    private var closeButton: some View {
        Button {
            model.cancel()
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(VoCalTheme.Colors.ink)
                .frame(width: 36, height: 36)
                .glassEffect(.regular, in: Circle())
        }
        .padding(VoCalTheme.Spacing.l)
        .accessibilityIdentifier(A11y.VoiceLog.cancelButton)
        .accessibilityLabel("Close")
    }

    // MARK: - Capture surface (idle / arming / listening share ONE layout)

    @State private var micPulse = false

    private enum CaptureMic { case idle, arming, listening }

    /// Idle, arming, and listening all render through this one scaffold so the mic stays
    /// ANCHORED in place across the transition. Bug (2026-07): the mic/indicator jumped DOWN
    /// when listening began, because the idle surface used `Spacer/mic/status/Spacer/Spacer`
    /// (mic pushed high) while the listening surface used `Spacer/mic/row/Spacer/Stop` (mic
    /// centered) — different Spacer counts moved the mic between states. Here the mic sits above
    /// a FIXED-HEIGHT status slot and a FIXED-HEIGHT action slot with exactly one Spacer above
    /// and one below in every state, so only the text/controls swap — the mic never moves.
    private func captureScaffold(
        mic: CaptureMic,
        elapsed: TimeInterval = 0,
        transcript: String = "",
        tapAction: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: 0) {
            Text(screenLabel)
                .font(VoCalTheme.Fonts.formLabel)
                .foregroundStyle(VoCalTheme.Colors.muted)
            Spacer()
            micButton(ring: mic != .idle, pulsing: mic == .arming, action: tapAction)
            captureStatus(mic: mic, elapsed: elapsed, transcript: transcript)
                // Constant height + top alignment: the live transcript growing (or "Listening"
                // replacing the idle prompt) must not push the mic above it.
                .frame(height: 116, alignment: .top)
                .frame(maxWidth: .infinity)
                .padding(.top, VoCalTheme.Spacing.l)
            Spacer()
            // Reserved action slot: Stop only while listening, but the height is always held so
            // the button appearing doesn't rebalance the Spacers and shift the mic.
            Group {
                if mic == .listening {
                    PillButton(title: "Stop") { model.stopCapture() }
                        .accessibilityIdentifier(A11y.VoiceLog.stopButton)
                }
            }
            .frame(height: 56)
            .padding(.horizontal, VoCalTheme.Spacing.xxl)
        }
        .padding(VoCalTheme.Spacing.xl)
    }

    /// State-dependent content that lives inside the fixed-height status slot below the mic.
    @ViewBuilder
    private func captureStatus(mic: CaptureMic, elapsed: TimeInterval, transcript: String) -> some View {
        switch mic {
        case .idle:
            Text(idlePrompt)
                .font(VoCalTheme.Fonts.primaryLabel)
                .foregroundStyle(VoCalTheme.Colors.ink)
                .accessibilityIdentifier(A11y.VoiceLog.stateLabel)
        case .arming:
            // "Starting…" not "Hold on…": the latter reads as a press-and-hold instruction
            // (a tester reported "it says press to hold"), but capture is one-tap auto-start.
            // Still claim-safe — strictly weaker than "Listening", shown only before byte-flow.
            Text("Starting\u{2026}")
                .font(VoCalTheme.Fonts.primaryLabel)
                .foregroundStyle(VoCalTheme.Colors.ink)
                .accessibilityIdentifier(A11y.VoiceLog.stateLabel)
        case .listening:
            VStack(spacing: VoCalTheme.Spacing.s) {
                HStack(spacing: VoCalTheme.Spacing.s) {
                    Circle()
                        .fill(VoCalTheme.Colors.gold)
                        .frame(width: 9, height: 9)
                    Text(ClaimCopy.listening)
                        .font(VoCalTheme.Fonts.primaryLabel)
                        .foregroundStyle(VoCalTheme.Colors.ink)
                    Text(timeString(elapsed))
                        .font(VoCalTheme.Fonts.secondaryLabel.monospacedDigit())
                        .foregroundStyle(VoCalTheme.Colors.muted)
                }
                .accessibilityIdentifier(A11y.VoiceLog.stateLabel)
                if !transcript.isEmpty {
                    Text("\u{201C}\(transcript)\u{201D}")
                        .font(VoCalTheme.Fonts.secondaryLabel)
                        .foregroundStyle(VoCalTheme.Colors.ink)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .padding(.horizontal, VoCalTheme.Spacing.xl)
                }
            }
        }
    }

    private func micButton(ring: Bool, pulsing: Bool, action: (() -> Void)?) -> some View {
        Button {
            action?()
        } label: {
            Image(systemName: "mic.fill")
                .font(.system(size: 46, weight: .semibold))
                .foregroundStyle(VoCalTheme.Colors.gold)
                .frame(width: 128, height: 128)
                // Interactive Liquid Glass — same language as the bottom-menu mic the user loves.
                .glassEffect(.regular.tint(VoCalTheme.Colors.gold.opacity(0.18)).interactive(), in: Circle())
                .overlay(
                    Circle().stroke(VoCalTheme.Colors.gold, lineWidth: ring ? 3 : 0)
                )
                .scaleEffect(pulsing && micPulse ? 1.04 : 1)
                .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
        }
        .disabled(action == nil)
        .accessibilityIdentifier(A11y.VoiceLog.micButton)
        .accessibilityLabel("Start recording")
        .onAppear {
            guard pulsing else { return }
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                micPulse = true
            }
        }
    }

    private var stalledSurface: some View {
        VStack(spacing: VoCalTheme.Spacing.l) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40, weight: .semibold))
                // Unmistakable escalation is required here (dead air mid-capture is the #1
                // trust failure, VOICE_CAPTURE.md) — but on the status `alert` token, not
                // the protein macro red (macro colors are semantic-only, DESIGN.md).
                .foregroundStyle(VoCalTheme.Colors.alert)
            Text("Can't hear you")
                .font(VoCalTheme.Fonts.screenTitle)
                .foregroundStyle(VoCalTheme.Colors.ink)
            Text("We stopped picking up audio. Your recording so far is safe.")
                .font(VoCalTheme.Fonts.secondaryLabel)
                .foregroundStyle(VoCalTheme.Colors.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, VoCalTheme.Spacing.xl)
            Spacer()
            PillButton(title: "Stop and save") { model.stopCapture() }
                .padding(.horizontal, VoCalTheme.Spacing.xxl)
        }
        .padding(VoCalTheme.Spacing.xl)
    }

    private func blockedSurface(reason: String, autoFinalizeIn: TimeInterval?) -> some View {
        VStack(spacing: VoCalTheme.Spacing.l) {
            Spacer()
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(VoCalTheme.Colors.gold)
            Text("Paused")
                .font(VoCalTheme.Fonts.screenTitle)
                .foregroundStyle(VoCalTheme.Colors.ink)
            Text(reason)
                .font(VoCalTheme.Fonts.secondaryLabel)
                .foregroundStyle(VoCalTheme.Colors.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, VoCalTheme.Spacing.xl)
            if let autoFinalizeIn {
                Text("We'll save automatically in \(Int(autoFinalizeIn))s.")
                    .font(VoCalTheme.Fonts.formLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
            }
            Spacer()
            PillButton(title: "Resume") { model.startCapture() }
                .padding(.horizontal, VoCalTheme.Spacing.xxl)
        }
        .padding(VoCalTheme.Spacing.xl)
    }

    // MARK: - Processing + enhancing

    private func processingSurface(line: String) -> some View {
        VStack(spacing: VoCalTheme.Spacing.l) {
            Spacer()
            VoCalLoader(size: 48)
            Text(line)
                .font(VoCalTheme.Fonts.secondaryLabel)
                .foregroundStyle(VoCalTheme.Colors.muted)
                .accessibilityIdentifier(A11y.VoiceLog.stateLabel)
            Text("You can switch apps - we'll keep working.")
                .font(VoCalTheme.Fonts.formLabel)
                .foregroundStyle(VoCalTheme.Colors.muted)
            Spacer()
        }
        .padding(VoCalTheme.Spacing.xl)
    }

    private func enhancingSurface(rawText: String) -> some View {
        VStack(spacing: VoCalTheme.Spacing.l) {
            Spacer()
            HStack(spacing: VoCalTheme.Spacing.s) {
                VoCalLoader(size: 22)
                Text("Working out the numbers\u{2026}")
                    .font(VoCalTheme.Fonts.secondaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
                    .accessibilityIdentifier(A11y.VoiceLog.stateLabel)
            }
            EnhancingText(text: rawText)
                .padding(.horizontal, VoCalTheme.Spacing.xl)
            Spacer()
        }
        .padding(VoCalTheme.Spacing.xl)
    }

    // MARK: - Terminal surfaces

    private func loggedSurface(_ confirmation: MealLogConfirmation) -> some View {
        // Detected water is acknowledged here: water-only shows just the hydration line (never a
        // "0 cal · Water" meal), and a meal-plus-water shows both the meal receipt and the oz added.
        let waterOz = model.lastLoggedWaterOz
        let waterOnly = model.lastLogWasWaterOnly
        // Post-log coaching (certainty layer): ONE small note per app session, only for
        // low/medium-certainty meals — log-first, coach after, never annoy. The dwell is
        // longer when the note shows so it's actually readable; Done skips it any time.
        let coaching = waterOnly ? nil : Self.coachingNote(model.lastCertainty)
        return VStack(spacing: VoCalTheme.Spacing.l) {
            Spacer()
            Image(systemName: waterOnly ? "drop.fill" : "checkmark.seal.fill")
                .font(.system(size: 56, weight: .semibold))
                .foregroundStyle(VoCalTheme.Colors.gold)
            Text(waterOnly
                ? "Water logged"
                : model.appendTarget.map { "Added to \($0.displayName)" } ?? ClaimCopy.logged)
                .font(VoCalTheme.Fonts.screenTitle)
                .foregroundStyle(VoCalTheme.Colors.ink)
            if waterOnly {
                Text("\(Int(waterOz.rounded())) oz added to your water log")
                    .font(VoCalTheme.Fonts.secondaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
            } else {
                Text("\(Int(confirmation.totals.kcal.rounded())) cal \u{00B7} \(confirmation.name ?? "Meal")")
                    .font(VoCalTheme.Fonts.secondaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
                if let certainty = model.lastCertainty {
                    Text("\(certainty.score)% certainty \u{00B7} \(certainty.displayLabel)")
                        .font(VoCalTheme.Fonts.formLabel)
                        .foregroundStyle(VoCalTheme.Colors.gold)
                }
                if waterOz > 0 {
                    Label("\(Int(waterOz.rounded())) oz added to your water log", systemImage: "drop.fill")
                        .font(VoCalTheme.Fonts.formLabel)
                        .foregroundStyle(VoCalTheme.Colors.gold)
                }
            }
            if let coaching {
                Text(coaching)
                    .font(VoCalTheme.Fonts.formLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(VoCalTheme.Spacing.m)
                    .background(
                        VoCalTheme.Colors.gold.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.chip, style: .continuous)
                    )
                    .padding(.horizontal, VoCalTheme.Spacing.l)
            }
            Spacer()
            PillButton(title: "Done") { dismiss() }
                .padding(.horizontal, VoCalTheme.Spacing.xxl)
        }
        .padding(VoCalTheme.Spacing.xl)
        .onAppear {
            // Celebratory pause, then auto-dismiss back to Today (longer when coaching shows).
            Task {
                try? await Task.sleep(for: .seconds(coaching == nil ? 1.4 : 5.0))
                dismiss()
            }
        }
    }

    /// The one-per-session coaching note. Category-aware tips come from the server; this
    /// only decides WHEN to speak (should_show_coaching + the session cap) — never blocks.
    @MainActor
    private static func coachingNote(_ certainty: MealCertainty?) -> String? {
        guard let certainty,
              certainty.shouldShowCoaching,
              let firstTip = certainty.tips.first,
              !CoachingSession.noteShown
        else { return nil }
        CoachingSession.noteShown = true
        return "Want a sharper estimate next time? Try to \(firstTip)."
    }

    /// Calm failure surface: an outcome, not a catastrophe. Muted glyph on a card circle —
    /// never a red alarm, because by this point the recording itself succeeded and only a
    /// derived step needs another try. The diagnostic code stays in `.failed` for logs but
    /// is not rendered (Lorenzo 2026-08-19: raw codes read as "the whole system broke").
    /// On parse failures the transcript is echoed so the user sees what we heard and can
    /// rephrase instead of retrying blind.
    private func failureSurface(message: String, retryable: Bool, transcript: String? = nil) -> some View {
        VStack(spacing: VoCalTheme.Spacing.l) {
            Spacer()
            ZStack {
                Circle()
                    .fill(VoCalTheme.Colors.card)
                    .frame(width: 88, height: 88)
                Image(systemName: "waveform.badge.exclamationmark")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(VoCalTheme.Colors.muted)
            }
            Text(message)
                .font(VoCalTheme.Fonts.primaryLabel)
                .foregroundStyle(VoCalTheme.Colors.ink)
                .multilineTextAlignment(.center)
                .padding(.horizontal, VoCalTheme.Spacing.xl)
                .accessibilityIdentifier(A11y.VoiceLog.stateLabel)
            if let transcript, !transcript.isEmpty {
                VStack(spacing: VoCalTheme.Spacing.xs) {
                    Text("You said")
                        .font(VoCalTheme.Fonts.formLabel)
                        .foregroundStyle(VoCalTheme.Colors.muted)
                    Text("\u{201C}\(transcript)\u{201D}")
                        .font(VoCalTheme.Fonts.secondaryLabel)
                        .foregroundStyle(VoCalTheme.Colors.ink)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                }
                .padding(VoCalTheme.Spacing.m)
                .frame(maxWidth: .infinity)
                .background(
                    VoCalTheme.Colors.card,
                    in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.chip, style: .continuous)
                )
                .padding(.horizontal, VoCalTheme.Spacing.xl)
            }
            Spacer()
            if retryable {
                PillButton(title: "Try again") { model.retry() }
                    .padding(.horizontal, VoCalTheme.Spacing.xxl)
            }
            VoCalButton(title: "Close", kind: .tertiary) {
                model.cancel()
                dismiss()
            }
        }
        .padding(VoCalTheme.Spacing.xl)
    }

    private func timeString(_ elapsed: TimeInterval) -> String {
        let total = Int(elapsed)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

#Preview("Idle") {
    VoiceLogView(mealType: .lunch)
}
