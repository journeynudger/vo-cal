import SwiftUI

/// The onboarding coordinator: Welcome → deep intake → protocol reveal (→ the plan builder in
/// meal-plan mode) → account gate, then hands off to the app. Value-first ordering (DESIGN.md
/// §Welcome): the protocol is shown before any account step. The second door (decision 76):
/// Welcome → account gate → the app, past every question, with nothing written for the
/// person: the preference's version 0 ("never chosen") renders the method's six at the
/// starter targets, and Today's banner is the door to the basics. Pure SwiftUI state machine;
/// each screen calls back to advance.
struct OnboardingFlowView: View {
    /// Called once onboarding is complete (account created) so the shell can show the app.
    var onComplete: () -> Void

    @State private var step: Step = .welcome
    @State private var draft = IntakeDraft()
    /// The person skipped the questions (decision 76): the gate asks to keep their log, not a
    /// protocol nobody built, and nothing is re-submitted after sign-in.
    @State private var skipped = false
    /// The reveal's "Back to my answers" (a build that failed): the intake reopens on its last
    /// screen with every answer kept.
    @State private var resumeIntakeAtEnd = false
    /// The plan the person built before the account step (meal-plan mode), kept so it can be
    /// written again under the signed-in account (see `finalizeAfterAuth`). Nil when skipped.
    @State private var savedPlan: MealPlanUpdate?
    /// Mirror the chosen meals/day into the preference Settings reads + lets the user edit.
    @AppStorage("vocal.mealsPerDay") private var storedMealsPerDay = 4

    enum Step: Equatable { case welcome, intake, protocolReveal, planBuilder, auth, health }

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
            WelcomeView(
                onStart: { step = .intake },
                onSkip: {
                    skipped = true
                    step = .auth
                }
            )
            .transition(.opacity)
        case .intake:
            IntakeFlowView(
                draft: $draft,
                startAtEnd: resumeIntakeAtEnd,
                onFinish: { finishIntake() },
                onCancel: { step = .welcome }
            )
        case .protocolReveal:
            ProtocolRevealView(
                intake: draft.profile,
                mode: draft.mode ?? .method,
                onContinue: { step = draft.mode == .mealPlan ? .planBuilder : .auth },
                onBack: {
                    resumeIntakeAtEnd = true
                    step = .intake
                }
            )
        case .planBuilder:
            // The plan, sized by the meals the person said they eat (spec 6.3), built from typed
            // meals here (a new account has no usuals yet); "Not now" leaves the card saying so.
            PlanBuilderView(
                presentation: .onboarding(onDone: { update in
                    savedPlan = update
                    step = .auth
                }),
                initialSlotCount: draft.mealsPerDay
            )
        case .auth:
            AuthGateView(purpose: skipped ? .keepLog : .saveProtocol, onSignedIn: { finalizeAfterAuth() })
        case .health:
            // Read only, on the phone, never sent (decision 52): asked once, right after the
            // account, so the calories card can show what was burned from the first day.
            HealthPermissionStep(onDone: { onComplete() })
        }
    }

    /// After the account: Apple Health when the phone has it and it was never asked.
    private func completeOrAskHealth() {
        let health = HealthKitService.shared
        if health.isAvailable, !health.hasAsked {
            step = .health
        } else {
            onComplete()
        }
    }

    /// Sign-in changes the user_id from the pre-auth anonymous session, so the protocol generated
    /// for the reveal, the tracking preference written with the intake and the meal plan built
    /// before the gate live under the old (anonymous) account — Today would then fall back to
    /// the starter targets. Re-submit the intake, the preference, the protocol and the plan for
    /// the now-authenticated account from the retained draft before handing off. Best-effort: a
    /// failure still completes onboarding (never traps the user on the gate); the deterministic
    /// engine yields the same numbers the user just saw on the reveal. The plan goes after the
    /// protocol so its check has a protocol to run against. A skipper wrote nothing, so there is
    /// nothing to carry over: the record says never chosen, which is true (decision 76).
    private func finalizeAfterAuth() {
        guard !RuntimeMode.usesMockServices, !skipped else { completeOrAskHealth(); return }
        let profile = draft.profile
        let mode = draft.mode
        let plan = savedPlan
        let update = TrackingUpdate(mode: mode, frictions: draft.frictions, logAnchor: draft.logAnchor)
        Task {
            let api = APIClient()
            _ = try? await api.submitIntake(profile)
            if mode != nil {
                _ = try? await api.updateTracking(update)
            }
            _ = try? await api.generateProtocol(intake: profile, mode: mode)
            if let plan {
                _ = try? await api.saveMealPlan(plan)
            }
            await MainActor.run { completeOrAskHealth() }
        }
    }

    private func finishIntake() {
        resumeIntakeAtEnd = false
        storedMealsPerDay = draft.mealsPerDay
        // Persist the completed intake (F2) and the way the person chose to follow their
        // nutrition (decision 57), with what gets in the way and when they log (decisions 66
        // and 69). Fire-and-forget: both land during the reveal's "building…" beat, and the
        // protocol generation, which carries the mode itself, is the gating call. The sim path
        // keeps the mode locally so its Today follows the choice too. How much the app says is
        // asked on Today after the first log (decision 77), so nothing about it is written here.
        let mode = draft.mode
        let update = TrackingUpdate(mode: mode, frictions: draft.frictions, logAnchor: draft.logAnchor)
        if RuntimeMode.usesMockServices {
            if mode != nil {
                Task { _ = try? await MockTrackingService().update(update) }
            }
        } else {
            let profile = draft.profile
            Task {
                let api = APIClient()
                _ = try? await api.submitIntake(profile)
                if mode != nil {
                    _ = try? await api.updateTracking(update)
                }
            }
        }
        step = .protocolReveal
    }
}

#Preview {
    OnboardingFlowView(onComplete: {})
}
