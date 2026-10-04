import SwiftUI

/// The onboarding coordinator: Welcome → deep intake → protocol reveal (→ the plan builder in
/// meal-plan mode) → account gate, then hands off to the app. Value-first ordering (DESIGN.md
/// §Welcome): the protocol is shown before any account step. Pure SwiftUI state machine; each
/// screen calls back to advance.
struct OnboardingFlowView: View {
    /// Called once onboarding is complete (account created) so the shell can show the app.
    var onComplete: () -> Void

    @State private var step: Step = .welcome
    @State private var draft = IntakeDraft()
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
            WelcomeView(onStart: { step = .intake })
                .transition(.opacity)
        case .intake:
            IntakeFlowView(
                draft: $draft,
                onFinish: { finishIntake() },
                onCancel: { step = .welcome }
            )
        case .protocolReveal:
            ProtocolRevealView(
                intake: draft.profile,
                mode: draft.mode ?? .five,
                onContinue: { step = draft.mode == .mealPlan ? .planBuilder : .auth }
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
            AuthGateView(onSignedIn: { finalizeAfterAuth() })
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
    /// the 2000-kcal stub in the five. Re-submit the intake, the preference, the protocol and the
    /// plan for the now-authenticated account from the retained draft before handing off.
    /// Best-effort: a failure still completes onboarding (never traps the user on the gate); the
    /// deterministic engine yields the same numbers the user just saw on the reveal. The plan
    /// goes after the protocol so its check has a protocol to run against.
    private func finalizeAfterAuth() {
        guard !RuntimeMode.usesMockServices else { completeOrAskHealth(); return }
        let profile = draft.profile
        let mode = draft.mode
        let plan = savedPlan
        let update = TrackingUpdate(mode: mode, nudgeLevel: draft.nudgeLevel, frictions: draft.frictions)
        Task {
            let api = APIClient()
            _ = try? await api.submitIntake(profile)
            if mode != nil || update.nudgeLevel != nil {
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
        storedMealsPerDay = draft.mealsPerDay
        // Persist the completed intake (F2) and the way the person chose to follow their
        // nutrition (decision 57). Fire-and-forget: both land during the reveal's "building…"
        // beat, and the protocol generation, which carries the mode itself, is the gating call.
        // The sim path keeps the mode locally so its Today follows the choice too.
        let mode = draft.mode
        // How much the app says takes effect on the phone at once (decision 66): the first log's
        // permission ask reads it, so "Nothing" never shows the system prompt. The preference
        // is the owner; this is its cache.
        if let level = draft.nudgeLevel {
            NudgeCenter.shared.level = level
        }
        let update = TrackingUpdate(mode: mode, nudgeLevel: draft.nudgeLevel, frictions: draft.frictions)
        if RuntimeMode.usesMockServices {
            if mode != nil || update.nudgeLevel != nil {
                Task { _ = try? await MockTrackingService().update(update) }
            }
        } else {
            let profile = draft.profile
            Task {
                let api = APIClient()
                _ = try? await api.submitIntake(profile)
                if mode != nil || update.nudgeLevel != nil {
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
