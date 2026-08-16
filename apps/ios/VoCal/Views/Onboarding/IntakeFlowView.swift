import SwiftUI

/// F2 — the deep intake. One question per screen (kept deliberately uncluttered), a thin
/// progress bar, big tappable options. Edits an `IntakeDraft` whose fields map 1:1 to the
/// engine's `IntakeProfile`. Activity is never asked — it's inferred from work + training +
/// obligations (decision #36). Pre-answered with persona defaults so Continue is always valid.
/// Three animated benefit interstitials (`BenefitInterstitials.swift`) are woven between the
/// questions as education beats; the progress bar and back chevron treat them as full steps.
struct IntakeFlowView: View {
    @Binding var draft: IntakeDraft
    var onFinish: () -> Void
    var onCancel: () -> Void

    /// One entry per screen. Back steps backward through the same list, benefit screens
    /// included, and the progress bar spans all of it.
    enum IntakeStep: Equatable {
        case question(Int)
        case desiredWeight
        case benefit(IntakeBenefit)
    }

    private static let steps: [IntakeStep] = [
        .question(0),               // basics
        .desiredWeight,             // pounds ruler, anchored to the basics weight
        .question(1),               // goal
        .benefit(.realisticPace),
        .question(2),               // real life
        .question(3),               // training
        .benefit(.momentum),
        .question(4),               // hunger
        .question(5),               // stress
        .question(6),               // meals per day
        .benefit(.longTermResults), // → "Build my protocol"
    ]

    @State private var index = 0

    private var current: IntakeStep { Self.steps[index] }
    private var isFirstStep: Bool { current == .question(0) }
    private var isLastStep: Bool { index == Self.steps.count - 1 }

    var body: some View {
        OnboardingStepScaffold(
            progress: Double(index + 1) / Double(Self.steps.count),
            onBack: back
        ) {
            switch current {
            case let .question(q):
                question(q)
            case .desiredWeight:
                DesiredWeightStep(draft: $draft)
            case .benefit(.realisticPace):
                RealisticPaceBenefitView(
                    currentLb: draft.weightLb, desiredLb: draft.desiredWeightLb
                )
            case .benefit(.momentum):
                MomentumBenefitView(goal: draft.goal)
            case .benefit(.longTermResults):
                LongTermResultsBenefitView()
            }
        } footer: {
            VStack(spacing: VoCalTheme.Spacing.s) {
                PillButton(title: isLastStep ? "Build my protocol" : "Continue") { advance() }
                    // Sex must be an explicit choice — it flips the IBW base + calorie floor,
                    // so a pre-selected value silently miscomputes half of all protocols
                    // (field bug 2026-07: the 1690-kcal complaint). Everything else keeps
                    // persona defaults; this one gate is the honesty-critical input.
                    .disabled(isFirstStep && draft.sex.isEmpty)
                    .opacity(isFirstStep && draft.sex.isEmpty ? 0.4 : 1)
                if isFirstStep {
                    // Required not-medical-advice disclaimer on the intake flow (PROTOCOL_LOGIC
                    // §9; App Review health posture). Canonical copy, shown on the first step.
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
            header("The basics", "Let's start with you.", "This sets the range. Everything after is what makes it yours.")
            ChoiceList(
                options: [("female", "Female", nil), ("male", "Male", nil)],
                selection: $draft.sex
            )
            // These three are NOT decoration — they drive the whole engine: height sets ideal
            // bodyweight (→ calories), weight sets protein/water/fat, sex sets the IBW base +
            // calorie floor (engine.py). They were previously static text, so every protocol was
            // computed for the 5′6″/172 lb/34 persona regardless of the user.
            BasicsEditor(age: $draft.age, heightIn: $draft.heightIn, weightLb: $draft.weightLb)
        case 1:
            header("Your goal", "What are we working toward?", nil)
            ChoiceList(
                options: [
                    ("cut", "Lose fat, keep muscle", nil),
                    ("maintain", "Maintain where I am", nil),
                    ("gain", "Build muscle / gain", nil),
                ],
                selection: $draft.goal
            )
            if draft.goal == "cut" { reassurance }
        case 2:
            header("Your real life", "What does a normal week look like?", "We infer how active you are from this - so you never rate yourself.")
            ChoiceList(
                options: [
                    ("desk", "Mostly at a desk", nil),
                    ("on_feet", "On my feet all day", nil),
                    ("manual", "Physical / manual work", nil),
                ],
                selection: $draft.work
            )
            Text("Young kids at home?")
                .font(VoCalTheme.Fonts.formLabel)
                .foregroundStyle(VoCalTheme.Colors.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, VoCalTheme.Spacing.s)
            ChoiceList(
                options: [("no", "No", nil), ("yes", "Yes", nil)],
                selection: kidsBinding
            )
        case 3:
            header("Training", "How much do you train?", "Paired with your work, this is how we read your real activity.")
            ChoiceList(
                options: [
                    ("none", "Not much yet", nil),
                    ("light", "Light", "1-2 days a week"),
                    ("moderate", "Moderate", "3-4 days a week"),
                    ("heavy", "Heavy", "5+ days a week"),
                ],
                selection: $draft.train
            )
        case 4:
            header("Hunger", "On any medication that affects appetite?", "It changes the math more than you'd think.")
            ChoiceList(
                options: [
                    ("none", "No", nil),
                    ("hunger_suppressing", "Yes - it curbs my appetite", nil),
                    ("hunger_increasing", "Yes - it increases my appetite", nil),
                ],
                selection: $draft.med
            )
        case 5:
            header("Life right now", "How's your stress and sleep?", "High-stress weeks earn a lighter, more livable deficit.")
            ChoiceList(
                options: [
                    ("low", "Pretty steady", nil),
                    ("moderate", "Normal ups and downs", nil),
                    ("high", "Stressed / sleep is rough", nil),
                ],
                selection: $draft.stress
            )
        default:
            header("Your day", "How many meals do you prefer?", "We'll structure your targets around it.")
            ChoiceList(
                options: [("2", "2", nil), ("3", "3", nil), ("4", "4", nil), ("5", "5", nil)],
                selection: mealsBinding
            )
        }
    }

    private var reassurance: some View {
        VStack(alignment: .leading, spacing: VoCalTheme.Spacing.xs) {
            Text("A steady, livable pace.")
                .font(VoCalTheme.Fonts.primaryLabel)
                .foregroundStyle(VoCalTheme.Colors.ink)
            Text("Fast enough to see it, slow enough to keep it. We won't crash your calories.")
                .font(VoCalTheme.Fonts.formLabel)
                .foregroundStyle(VoCalTheme.Colors.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(VoCalTheme.Spacing.m)
        .background(VoCalTheme.Colors.gold.opacity(0.12), in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.chip, style: .continuous))
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
