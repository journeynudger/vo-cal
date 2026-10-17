import SwiftUI

/// F2 — the deep intake. One question per screen (kept deliberately uncluttered), a thin
/// progress bar, big tappable options. Edits an `IntakeDraft` whose fields map 1:1 to the
/// engine's `IntakeProfile`. Activity is never asked — it's inferred from work + training +
/// obligations (decision #36). Pre-answered with persona defaults so Continue is always valid.
/// The first question is how the person wants to follow their nutrition (decision 57); the
/// screens after it depend on the answer (spec 6.3). The order follows mental contrasting
/// (decision 69, Oettingen: wish, outcome, obstacle, plan): the goal, then the realistic pace
/// in the person's own numbers, then what gets in the way and when they will log. How much the
/// app should say left the intake on 2026-10-16 (decision 77): it changes nothing until the
/// first log, so Today asks it then (`VoiceAskCard`). The three questions about the person and
/// the app are the mode, what gets in the way and when they log. One benefit screen remains
/// (`BenefitInterstitials.swift`), a full step for the progress bar and the back chevron.
struct IntakeFlowView: View {
    @Binding var draft: IntakeDraft
    var onFinish: () -> Void
    var onCancel: () -> Void

    /// `startAtEnd` opens on the last screen, with every answer kept: the reveal's "Back to my
    /// answers" after a build that failed (the 2026-10-16 audit, A12).
    init(draft: Binding<IntakeDraft>, startAtEnd: Bool = false, onFinish: @escaping () -> Void, onCancel: @escaping () -> Void) {
        _draft = draft
        self.onFinish = onFinish
        self.onCancel = onCancel
        _index = State(initialValue: startAtEnd ? max(0, Self.steps(for: draft.wrappedValue.mode).count - 1) : 0)
    }

    /// One entry per screen. Back steps backward through the same list, benefit screens
    /// included, and the progress bar spans all of it.
    enum IntakeStep: Equatable {
        case mode
        /// What makes tracking hard: any or none.
        case friction
        /// When the person will log (decision 69): a moment that already happens.
        case anchor
        case question(Int)
        case desiredWeight
        case benefit(IntakeBenefit)
    }

    /// The screens for a mode (spec 6.3; the order of the behavior-change spec's 6.5). Habits
    /// skips the ruler, the goal, the medication question and the benefit screen: nothing is
    /// prescribed, so there is no pace or deficit to explain. The basics stay in every mode
    /// (water scales with weight, and the engine computes the whole protocol regardless); real
    /// life, training and stress stay because the nudges read them. The obstacle (what gets in
    /// the way) is asked after the outcome (the realistic pace, in the person's numbers): named
    /// before it, an obstacle produces no commitment (Oettingen's MCII; Stadler 2010).
    static func steps(for mode: TrackingMode?) -> [IntakeStep] {
        switch mode {
        case nil:
            return [.mode]
        case .habits?:
            return [
                .mode,
                .question(0),               // basics
                .question(2),               // real life
                .friction,
                .anchor,
                .question(3),               // training
                .question(5),               // stress
                .question(6),               // meals per day → "Set up my habits"
            ]
        default:
            return [
                .mode,
                .question(0),               // basics
                .desiredWeight,             // pounds ruler, anchored to the basics weight
                .question(1),               // goal: the wish
                .benefit(.realisticPace),   // the outcome, in their own numbers
                .friction,                  // the obstacle
                .anchor,                    // the plan's cue
                .question(2),               // real life
                .question(3),               // training
                .question(4),               // hunger
                .question(5),               // stress
                .question(6),               // meals per day → "Build my protocol"
            ]
        }
    }

    @State private var index = 0

    private var steps: [IntakeStep] { Self.steps(for: draft.mode) }
    private var current: IntakeStep { steps[min(index, steps.count - 1)] }
    private var isFirstStep: Bool { index == 0 }
    private var isLastStep: Bool { index >= steps.count - 1 }

    /// Before a mode is chosen the bar measures against the full intake, so the first step
    /// never reads as the whole of it.
    private var progress: Double {
        let total = draft.mode == nil ? Self.steps(for: .method).count : steps.count
        return Double(index + 1) / Double(total)
    }

    /// Two gates, both honesty-critical: the mode, because nothing is preselected (decision
    /// 57); sex, because it flips the IBW base + calorie floor, so a pre-selected value
    /// silently miscomputes half of all protocols (field bug 2026-07: the 1690-kcal complaint).
    /// Everything else keeps persona defaults.
    private var canContinue: Bool {
        switch current {
        case .mode: return draft.mode != nil
        // Frictions need no answer: none ticked is an answer (decision 66).
        // The anchor moves two reminders; "I'll find my own moment" is one of its answers, so a
        // choice is asked for and none is made for the person (decision 69).
        case .anchor: return draft.logAnchor != nil
        case .question(0): return !draft.sex.isEmpty
        default: return true
        }
    }

    private var continueTitle: String {
        guard isLastStep else { return "Continue" }
        return draft.mode == .habits ? "Set up my habits" : "Build my protocol"
    }

    var body: some View {
        OnboardingStepScaffold(
            progress: progress,
            onBack: back
        ) {
            switch current {
            case .mode:
                header("How you track", "How do you want to follow your nutrition?", "You can change this any time.")
                TrackingModeChooser(selection: $draft.mode)
                    .accessibilityIdentifier(A11y.Intake.modeChooser)
            case .friction:
                header("What gets in the way", "What makes tracking hard for you?", "Pick what fits. Or nothing.")
                FrictionChooser(selection: $draft.frictions)
                    .accessibilityIdentifier(A11y.Intake.frictionChooser)
            case .anchor:
                header("When you log", "When will you log?", "Pick a moment that already happens. The reminders follow it.")
                AnchorChooser(selection: $draft.logAnchor)
                    .accessibilityIdentifier(A11y.Intake.anchorChooser)
            case let .question(q):
                question(q)
            case .desiredWeight:
                DesiredWeightStep(draft: $draft)
            case .benefit(.realisticPace):
                RealisticPaceBenefitView(
                    currentLb: draft.weightLb, desiredLb: draft.desiredWeightLb, goal: draft.goal
                )
            }
        } footer: {
            VStack(spacing: VoCalTheme.Spacing.s) {
                PillButton(title: continueTitle, isEnabled: canContinue) { advance() }
                if isFirstStep {
                    // Required not-medical-advice disclaimer on the intake flow (PROTOCOL_LOGIC
                    // §9; App Review health posture). Canonical copy, shown on the first step
                    // in every mode.
                    Text("Vo-Cal provides general nutrition information and is not medical advice. Consult a physician before changing your diet, especially if you are pregnant, nursing, under 18, or have a medical condition or history of disordered eating.")
                        .font(VoCalTheme.Fonts.formLabel)
                        .foregroundStyle(VoCalTheme.Colors.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(A11y.Intake.disclaimer)
                }
            }
        }
    }

    @ViewBuilder
    private func question(_ q: Int) -> some View {
        switch q {
        case 0:
            header("The basics", "Let's start with you.", "Height, weight and age set the range. The rest makes it yours.")
            ChoiceList(options: IntakeOptions.sex, selection: $draft.sex)
            // These three are NOT decoration — they drive the whole engine: height sets ideal
            // bodyweight (→ calories), weight sets protein/water/fat, sex sets the IBW base +
            // calorie floor (engine.py). They were previously static text, so every protocol was
            // computed for the 5′6″/172 lb/34 persona regardless of the user.
            BasicsEditor(age: $draft.age, heightIn: $draft.heightIn, weightLb: $draft.weightLb)
        case 1:
            // No card under the answer (spec 6.6 gives this screen no support): the pace screen
            // that follows says the one sentence, once, in the person's numbers (A5).
            header("Your goal", "What are we working toward?", nil)
            ChoiceList(options: IntakeOptions.goal, selection: $draft.goal)
        case 2:
            header("Your real life", "What does a normal week look like?", "Your activity comes from this. You never have to rate yourself.")
            ChoiceList(options: IntakeOptions.work, selection: $draft.work)
            Text("Young kids at home?")
                .font(VoCalTheme.Fonts.formLabel)
                .foregroundStyle(VoCalTheme.Colors.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, VoCalTheme.Spacing.s)
            ChoiceList(options: IntakeOptions.kids, selection: kidsBinding)
        case 3:
            header("Training", "How much do you train?", "With your work, this is how we read your real activity.")
            ChoiceList(options: IntakeOptions.train, selection: $draft.train)
        case 4:
            header("Hunger", "On any medication that affects appetite?", "It changes the math more than you would think.")
            ChoiceList(options: IntakeOptions.med, selection: $draft.med)
        case 5:
            // Only a cut's deficit is gentled by stress (engine.py); no reminder reads this
            // answer. The line says so only where it is true (the audit, A2).
            header("Life right now", "How are your stress and sleep?", draft.mode != .habits && draft.goal == "cut" ? "A stressful week earns a gentler deficit." : nil)
            ChoiceList(options: IntakeOptions.stress, selection: $draft.stress)
        default:
            header("Your day", "How many meals do you prefer?", mealsSupport)
            ChoiceList(options: IntakeOptions.meals, selection: mealsBinding)
        }
    }

    private func header(_ eyebrow: String, _ title: String, _ sub: String?) -> some View {
        VStack(alignment: .leading, spacing: VoCalTheme.Spacing.s) {
            Text(eyebrow).sectionHeader()
            Text(title)
                .font(.system(size: 27, weight: .semibold))
                .foregroundStyle(VoCalTheme.Colors.ink)
            if let sub {
                Text(sub)
                    .font(VoCalTheme.Fonts.secondaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
            }
        }
        .padding(.bottom, VoCalTheme.Spacing.s)
    }

    private var mealsBinding: Binding<String> {
        Binding(get: { String(draft.mealsPerDay) }, set: { draft.mealsPerDay = Int($0) ?? 4 })
    }

    /// What the count does in this mode: in habits it is the day's own measure, in the meal
    /// plan it sizes the plan the person builds next (spec 6.3), elsewhere it shapes the targets.
    private var mealsSupport: String {
        switch draft.mode {
        case .habits?: "So a day with every meal logged reads as one."
        case .mealPlan?: "Your plan starts with this many meals."
        default: "Your targets are shaped around it."
        }
    }

    /// Bridges the Bool `kids` to the string-keyed ChoiceList so the question is a selector
    /// like every other step (no lone checkbox).
    private var kidsBinding: Binding<String> {
        Binding(get: { draft.kids ? "yes" : "no" }, set: { draft.kids = ($0 == "yes") })
    }

    private func advance() {
        if isLastStep {
            onFinish()
        } else {
            withAnimation(.easeInOut(duration: 0.2)) { index += 1 }
        }
    }

    private func back() {
        if index == 0 { onCancel() } else { withAnimation(.easeInOut(duration: 0.2)) { index -= 1 } }
    }
}

#Preview {
    struct Host: View {
        @State private var draft = IntakeDraft()
        var body: some View { IntakeFlowView(draft: $draft, onFinish: {}, onCancel: {}) }
    }
    return Host()
}
