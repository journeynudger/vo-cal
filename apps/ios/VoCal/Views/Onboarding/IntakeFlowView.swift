import SwiftUI

/// F2 — the deep intake. One question per screen (kept deliberately uncluttered), a thin
/// progress bar, big tappable options. Edits an `IntakeDraft` whose fields map 1:1 to the
/// engine's `IntakeProfile`. Activity is never asked — it's inferred from work + training +
/// obligations (decision #36). Pre-answered with persona defaults so Continue is always valid.
struct IntakeFlowView: View {
    @Binding var draft: IntakeDraft
    var onFinish: () -> Void
    var onCancel: () -> Void

    @State private var step = 0
    private let total = 7

    var body: some View {
        OnboardingStepScaffold(
            progress: Double(step + 1) / Double(total),
            onBack: back
        ) {
            question
        } footer: {
            VStack(spacing: VoCalTheme.Spacing.s) {
                PillButton(title: step == total - 1 ? "Build my protocol" : "Continue") { advance() }
                if step == 0 {
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
    private var question: some View {
        switch step {
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
        if step == total - 1 {
            onFinish()
        } else {
            withAnimation(.easeInOut(duration: 0.2)) { step += 1 }
        }
    }

    private func back() {
        if step == 0 { onCancel() } else { withAnimation(.easeInOut(duration: 0.2)) { step -= 1 } }
    }
}

/// Single-select list of big tappable option rows (selected = ink border + check).
private struct ChoiceList: View {
    let options: [(value: String, label: String, sub: String?)]
    @Binding var selection: String

    var body: some View {
        VStack(spacing: VoCalTheme.Spacing.m) {
            ForEach(options, id: \.value) { opt in
                Button {
                    selection = opt.value
                } label: {
                    HStack(spacing: VoCalTheme.Spacing.m) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(opt.label)
                                .font(VoCalTheme.Fonts.primaryLabel)
                                .foregroundStyle(VoCalTheme.Colors.ink)
                            if let sub = opt.sub {
                                Text(sub)
                                    .font(VoCalTheme.Fonts.formLabel)
                                    .foregroundStyle(VoCalTheme.Colors.muted)
                            }
                        }
                        Spacer()
                        if selection == opt.value {
                            Image(systemName: "checkmark")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(VoCalTheme.Colors.gold)
                        }
                    }
                    .padding(VoCalTheme.Spacing.l)
                    .softSelectableCard(isSelected: selection == opt.value)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Age / Height / Weight editor for the first intake step. Tap a row to expand a native wheel
/// picker beneath it (one open at a time). Wheels are used deliberately: they make an invalid
/// value impossible and feel native, and the row stays compact when collapsed. Imperial units —
/// the intake model and engine are lb/inches (`IntakeProfile.heightIn`/`weightLb`).
private struct BasicsEditor: View {
    @Binding var age: Int
    @Binding var heightIn: Double
    @Binding var weightLb: Double

    @State private var expanded: Field?

    private enum Field { case age, height, weight }

    var body: some View {
        VStack(spacing: VoCalTheme.Spacing.s) {
            row(.age, label: "Age", value: "\(age)", id: A11y.Intake.age)
            row(.height, label: "Height", value: heightLabel, id: A11y.Intake.height)
            row(.weight, label: "Weight", value: "\(Int(weightLb.rounded())) lb", id: A11y.Intake.weight)
        }
    }

    private var heightLabel: String {
        let inches = Int(heightIn.rounded())
        return "\(inches / 12)′ \(inches % 12)″"
    }

    private func row(_ field: Field, label: String, value: String, id: String) -> some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    expanded = (expanded == field) ? nil : field
                }
            } label: {
                HStack {
                    Text(label)
                        .font(VoCalTheme.Fonts.secondaryLabel)
                        .foregroundStyle(VoCalTheme.Colors.muted)
                    Spacer()
                    Text(value)
                        .font(VoCalTheme.Fonts.primaryLabel)
                        .foregroundStyle(expanded == field ? VoCalTheme.Colors.gold : VoCalTheme.Colors.ink)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(VoCalTheme.Colors.muted)
                        .rotationEffect(.degrees(expanded == field ? 180 : 0))
                }
                .padding(VoCalTheme.Spacing.m)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded == field {
                picker(for: field)
                    .frame(height: 150)
                    .clipped()
                    .padding(.bottom, VoCalTheme.Spacing.s)
            }
        }
        .background(VoCalTheme.Colors.card, in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.chip, style: .continuous))
        .accessibilityIdentifier(id)
    }

    @ViewBuilder
    private func picker(for field: Field) -> some View {
        switch field {
        case .age:
            Picker("Age", selection: $age) {
                ForEach(14...90, id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.wheel)
            .labelsHidden()
        case .weight:
            Picker("Weight", selection: weightInt) {
                ForEach(70...500, id: \.self) { Text("\($0) lb").tag($0) }
            }
            .pickerStyle(.wheel)
            .labelsHidden()
        case .height:
            HStack(spacing: 0) {
                Picker("Feet", selection: feet) {
                    ForEach(3...7, id: \.self) { Text("\($0) ft").tag($0) }
                }
                .pickerStyle(.wheel)
                .labelsHidden()
                Picker("Inches", selection: inches) {
                    ForEach(0...11, id: \.self) { Text("\($0) in").tag($0) }
                }
                .pickerStyle(.wheel)
                .labelsHidden()
            }
        }
    }

    // Proxies: the draft stores weight as Double lb and height as Double inches; the wheels
    // pick whole numbers (feet/inches/lb), composed back into those fields.
    private var weightInt: Binding<Int> {
        Binding(get: { Int(weightLb.rounded()) }, set: { weightLb = Double($0) })
    }
    private var feet: Binding<Int> {
        Binding(
            get: { Int(heightIn.rounded()) / 12 },
            set: { heightIn = Double($0 * 12 + Int(heightIn.rounded()) % 12) }
        )
    }
    private var inches: Binding<Int> {
        Binding(
            get: { Int(heightIn.rounded()) % 12 },
            set: { heightIn = Double((Int(heightIn.rounded()) / 12) * 12 + $0) }
        )
    }
}

#Preview {
    struct Host: View {
        @State private var draft = IntakeDraft()
        var body: some View { IntakeFlowView(draft: $draft, onFinish: {}, onCancel: {}) }
    }
    return Host()
}
