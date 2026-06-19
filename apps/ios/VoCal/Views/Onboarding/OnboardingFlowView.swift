import SwiftUI

/// The onboarding coordinator: Welcome → deep intake → protocol reveal → account gate, then
/// hands off to the app. Value-first ordering (DESIGN.md §Welcome): the protocol is shown
/// before any account step. Pure SwiftUI state machine; each screen calls back to advance.
struct OnboardingFlowView: View {
    /// Called once onboarding is complete (account created) so the shell can show the app.
    var onComplete: () -> Void

    @State private var step: Step = .welcome
    @State private var draft = IntakeDraft()

    enum Step: Equatable { case welcome, intake, protocolReveal, auth }

    var body: some View {
        switch step {
        case .welcome:
            WelcomeView(onStart: { step = .intake })
                .transition(.opacity)
        case .intake:
            IntakeFlowView(
                draft: $draft,
                onFinish: { step = .protocolReveal },
                onCancel: { step = .welcome }
            )
        case .protocolReveal:
            ProtocolRevealView(intake: draft.profile, onContinue: { step = .auth })
        case .auth:
            AuthGateView(onSignedIn: onComplete)
        }
    }
}

#Preview {
    OnboardingFlowView(onComplete: {})
}
