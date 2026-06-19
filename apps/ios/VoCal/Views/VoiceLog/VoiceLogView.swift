import SwiftUI
import VoCalCore

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
    @Environment(\.dismiss) private var dismiss
    var onLogged: (() -> Void)?

    init(mealType: MealType = .lunch, model: VoiceLogViewModel? = nil, onLogged: (() -> Void)? = nil) {
        _model = State(initialValue: model ?? VoiceLogViewModel(mealType: mealType))
        self.onLogged = onLogged
    }

    var body: some View {
        ZStack {
            VoCalTheme.Colors.background.ignoresSafeArea()
            content
        }
        .accessibilityIdentifier(A11y.VoiceLog.screen)
        .overlay(alignment: .topLeading) { closeButton }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            captureSurface(ring: false, statusTitle: "Tap, then say your \(mealNoun)", active: false) {
                model.startCapture()
            }
        case .arming:
            captureSurface(ring: true, statusTitle: "Hold on\u{2026}", active: true, pulsing: true, action: nil)
        case let .listening(elapsed, transcript):
            listeningSurface(elapsed: elapsed, transcript: transcript)
        case .stalled:
            stalledSurface
        case let .blocked(reason, autoFinalizeIn):
            blockedSurface(reason: reason, autoFinalizeIn: autoFinalizeIn)
        case .sealing:
            processingSurface(savedChip: true, line: "Sealing\u{2026}")
        case .saved:
            processingSurface(savedChip: true, line: "Saved \u{2014} analyzing\u{2026}")
        case .transcribing:
            processingSurface(savedChip: true, line: "Transcribing\u{2026}")
        case let .enhancing(rawText):
            enhancingSurface(rawText: rawText)
        case let .result(context):
            VoiceLogResultView(
                context: context,
                mealType: model.mealType,
                onAnswer: { field, option in model.answerQuestion(field: field, optionLabel: option) },
                onLogAnyway: { model.logAnyway() },
                onDelete: { index in model.deleteItem(at: index) },
                onConfirm: { saveAsUsual in
                    model.confirm(saveAsUsual: saveAsUsual) {
                        onLogged?()
                    }
                }
            )
        case let .logged(confirmation):
            loggedSurface(confirmation)
        case let .failed(message, retryable):
            failureSurface(message: message, retryable: retryable)
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

    // MARK: - Chrome

    private var closeButton: some View {
        Button {
            model.cancel()
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(VoCalTheme.Colors.ink)
                .frame(width: 36, height: 36)
                .background(VoCalTheme.Colors.card, in: Circle())
        }
        .padding(VoCalTheme.Spacing.l)
        .accessibilityIdentifier(A11y.VoiceLog.cancelButton)
        .accessibilityLabel("Close")
    }

    // MARK: - Capture surfaces

    @State private var micPulse = false

    private func captureSurface(
        ring: Bool,
        statusTitle: String,
        active: Bool,
        pulsing: Bool = false,
        action: (() -> Void)?
    ) -> some View {
        VStack(spacing: VoCalTheme.Spacing.xl) {
            Text("Log \(mealNoun)")
                .font(VoCalTheme.Fonts.formLabel)
                .foregroundStyle(VoCalTheme.Colors.muted)
            Spacer()
            micButton(ring: ring, pulsing: pulsing, action: action)
            Text(statusTitle)
                .font(VoCalTheme.Fonts.primaryLabel)
                .foregroundStyle(VoCalTheme.Colors.ink)
                .accessibilityIdentifier(A11y.VoiceLog.stateLabel)
            Spacer()
            Spacer()
        }
        .padding(VoCalTheme.Spacing.xl)
    }

    private func micButton(ring: Bool, pulsing: Bool, action: (() -> Void)?) -> some View {
        Button {
            action?()
        } label: {
            Image(systemName: "mic.fill")
                .font(.system(size: 46, weight: .semibold))
                .foregroundStyle(VoCalTheme.Colors.onCta)
                .frame(width: 128, height: 128)
                .background(VoCalTheme.Colors.cta, in: Circle())
                .overlay(
                    Circle().stroke(VoCalTheme.Colors.gold, lineWidth: ring ? 3 : 0)
                )
                .scaleEffect(pulsing && micPulse ? 1.04 : 1)
                .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
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

    private func listeningSurface(elapsed: TimeInterval, transcript: String) -> some View {
        VStack(spacing: VoCalTheme.Spacing.xl) {
            Text("Log \(mealNoun)")
                .font(VoCalTheme.Fonts.formLabel)
                .foregroundStyle(VoCalTheme.Colors.muted)
            Spacer()
            ZStack {
                Image(systemName: "mic.fill")
                    .font(.system(size: 46, weight: .semibold))
                    .foregroundStyle(VoCalTheme.Colors.onCta)
                    .frame(width: 128, height: 128)
                    .background(VoCalTheme.Colors.cta, in: Circle())
                    .overlay(Circle().stroke(VoCalTheme.Colors.gold, lineWidth: 3))
            }
            HStack(spacing: VoCalTheme.Spacing.s) {
                Circle()
                    .fill(VoCalTheme.Colors.gold)
                    .frame(width: 9, height: 9)
                Text("Listening")
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
                    .padding(.horizontal, VoCalTheme.Spacing.xl)
                    .frame(minHeight: 48)
            }
            Spacer()
            PillButton(title: "Stop") { model.stopCapture() }
                .padding(.horizontal, VoCalTheme.Spacing.xxl)
                .accessibilityIdentifier(A11y.VoiceLog.stopButton)
        }
        .padding(VoCalTheme.Spacing.xl)
    }

    private var stalledSurface: some View {
        VStack(spacing: VoCalTheme.Spacing.l) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(VoCalTheme.Colors.protein)
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

    private func processingSurface(savedChip: Bool, line: String) -> some View {
        VStack(spacing: VoCalTheme.Spacing.l) {
            if savedChip {
                HStack(spacing: VoCalTheme.Spacing.xs) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Saved")
                }
                .font(VoCalTheme.Fonts.formLabel.weight(.semibold))
                .foregroundStyle(VoCalTheme.Colors.gold)
                .padding(.top, VoCalTheme.Spacing.xxl)
            }
            Spacer()
            ProgressView()
                .controlSize(.large)
                .tint(VoCalTheme.Colors.gold)
            Text(line)
                .font(VoCalTheme.Fonts.secondaryLabel)
                .foregroundStyle(VoCalTheme.Colors.muted)
                .accessibilityIdentifier(A11y.VoiceLog.stateLabel)
            Text("You can switch apps \u{2014} we'll keep working.")
                .font(VoCalTheme.Fonts.formLabel)
                .foregroundStyle(VoCalTheme.Colors.muted)
            Spacer()
        }
        .padding(VoCalTheme.Spacing.xl)
    }

    private func enhancingSurface(rawText: String) -> some View {
        VStack(spacing: VoCalTheme.Spacing.l) {
            HStack(spacing: VoCalTheme.Spacing.xs) {
                Image(systemName: "checkmark.circle.fill")
                Text("Saved")
            }
            .font(VoCalTheme.Fonts.formLabel.weight(.semibold))
            .foregroundStyle(VoCalTheme.Colors.gold)
            .padding(.top, VoCalTheme.Spacing.xxl)
            Spacer()
            HStack(spacing: VoCalTheme.Spacing.s) {
                ProgressView().controlSize(.small).tint(VoCalTheme.Colors.gold)
                Text("Enhancing log\u{2026}")
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
        VStack(spacing: VoCalTheme.Spacing.l) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56, weight: .semibold))
                .foregroundStyle(VoCalTheme.Colors.gold)
            Text("Logged")
                .font(VoCalTheme.Fonts.screenTitle)
                .foregroundStyle(VoCalTheme.Colors.ink)
            Text("\(Int(confirmation.totals.kcal.rounded())) cal \u{00B7} \(confirmation.name ?? "Meal")")
                .font(VoCalTheme.Fonts.secondaryLabel)
                .foregroundStyle(VoCalTheme.Colors.muted)
            Spacer()
            PillButton(title: "Done") { dismiss() }
                .padding(.horizontal, VoCalTheme.Spacing.xxl)
        }
        .padding(VoCalTheme.Spacing.xl)
        .onAppear {
            // Brief celebratory pause, then auto-dismiss back to Today.
            Task {
                try? await Task.sleep(for: .seconds(1.4))
                dismiss()
            }
        }
    }

    private func failureSurface(message: String, retryable: Bool) -> some View {
        VStack(spacing: VoCalTheme.Spacing.l) {
            Spacer()
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(VoCalTheme.Colors.protein)
            Text(message)
                .font(VoCalTheme.Fonts.primaryLabel)
                .foregroundStyle(VoCalTheme.Colors.ink)
                .multilineTextAlignment(.center)
                .padding(.horizontal, VoCalTheme.Spacing.xl)
                .accessibilityIdentifier(A11y.VoiceLog.stateLabel)
            Spacer()
            if retryable {
                PillButton(title: "Try again") { model.retry() }
                    .padding(.horizontal, VoCalTheme.Spacing.xxl)
            }
            Button("Close") {
                model.cancel()
                dismiss()
            }
            .font(VoCalTheme.Fonts.secondaryLabel)
            .foregroundStyle(VoCalTheme.Colors.muted)
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
