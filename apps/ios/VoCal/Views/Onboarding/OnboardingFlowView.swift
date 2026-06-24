import SwiftUI

/// The onboarding coordinator: Welcome → deep intake → protocol reveal → account gate, then
/// hands off to the app. Value-first ordering (DESIGN.md §Welcome): the protocol is shown
/// before any account step. Pure SwiftUI state machine; each screen calls back to advance.
struct OnboardingFlowView: View {
    /// Called once onboarding is complete (account created) so the shell can show the app.
    var onComplete: () -> Void

    @State private var step: Step = .welcome
    @State private var draft = IntakeDraft()
    /// Mirror the chosen meals/day into the preference Settings reads + lets the user edit.
    @AppStorage("vocal.mealsPerDay") private var storedMealsPerDay = 4

    enum Step: Equatable { case welcome, intake, protocolReveal, auth }

    var body: some View {
        content
            // Silent anonymous session before any account step (live only) so the protocol can
            // be generated server-side and the intake persisted during onboarding. No visible
            // login wall — "value before any account step" (DESIGN.md §Welcome) still holds.
            .task {
                guard !RuntimeMode.usesMockServices else { return }
                await AuthCoordinator.shared.ensureSession()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:
            WelcomeView(onStart: { step = .intake })
                .transition(.opacity)
        case .intake:
            IntakeFlowView(
                draft: $draft,
                onFinish: { finishIntake() },
                onCancel: { step = .welcome }
            )
        case .protocolReveal:
            ProtocolRevealView(intake: draft.profile, onContinue: { step = .auth })
        case .auth:
            AuthGateView(onSignedIn: onComplete)
        }
    }

    private func finishIntake() {
        storedMealsPerDay = draft.mealsPerDay
        // Persist the completed intake (F2). Fire-and-forget: it lands during the protocol-reveal
        // "building…" beat, and the protocol generation (also intake-derived) is the gating call.
        // Mock/sim path skips the network.
        if !RuntimeMode.usesMockServices {
            let profile = draft.profile
            Task { try? await APIClient().submitIntake(profile) }
        }
        step = .protocolReveal
    }
}

#Preview {
    OnboardingFlowView(onComplete: {})
}
