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
        ZStack {
            VoCalTheme.Colors.background.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                topBar
                ScrollView {
                    VStack(alignment: .leading, spacing: VoCalTheme.Spacing.l) {
                        question
                    }
                    .padding(.horizontal, VoCalTheme.Spacing.l)
                    .padding(.top, VoCalTheme.Spacing.l)
                }
                PillButton(title: step == total - 1 ? "Build my protocol" : "Continue") {
                    advance()
                }
                .padding(VoCalTheme.Spacing.l)
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: VoCalTheme.Spacing.m) {
            Button(action: back) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(VoCalTheme.Colors.ink)
                    .frame(width: 38, height: 38)
                    .background(VoCalTheme.Colors.card, in: Circle())
            }
            ProgressView(value: Double(step + 1), total: Double(total))
                .tint(VoCalTheme.Colors.ink)
        }
        .padding(.horizontal, VoCalTheme.Spacing.l)
        .padding(.top, VoCalTheme.Spacing.l)
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
            infoRow("Age", "34"); infoRow("Height", "5′ 6″"); infoRow("Weight", "172 lb")
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
            header("Your real life", "What does a normal week look like?", "We infer how active you are from this — so you never rate yourself.")
            ChoiceList(
                options: [
                    ("desk", "Mostly at a desk", nil),
                    ("on_feet", "On my feet all day", nil),
                    ("manual", "Physical / manual work", nil),
                ],
                selection: $draft.work
            )
            ToggleChip(label: "I have young kids at home", isOn: $draft.kids)
                .padding(.top, VoCalTheme.Spacing.xs)
        case 3:
            header("Training", "How much do you train?", "Paired with your work, this is how we read your real activity.")
            ChoiceList(
                options: [
                    ("none", "Not much yet", nil),
                    ("light", "Light", "1–2 days a week"),
                    ("moderate", "Moderate", "3–4 days a week"),
                    ("heavy", "Heavy", "5+ days a week"),
                ],
                selection: $draft.train
            )
        case 4:
            header("Hunger", "On any medication that affects appetite?", "It changes the math more than you'd think.")
            ChoiceList(
                options: [
                    ("none", "No", nil),
                    ("hunger_suppressing", "Yes — it curbs my appetite", nil),
                    ("hunger_increasing", "Yes — it increases my appetite", nil),
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
            Text(eyebrow.uppercased())
                .font(VoCalTheme.Fonts.formLabel.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(VoCalTheme.Colors.gold)
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

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(VoCalTheme.Fonts.secondaryLabel).foregroundStyle(VoCalTheme.Colors.muted)
            Spacer()
            Text(value).font(VoCalTheme.Fonts.primaryLabel).foregroundStyle(VoCalTheme.Colors.ink)
        }
        .padding(VoCalTheme.Spacing.m)
        .background(VoCalTheme.Colors.card, in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.chip, style: .continuous))
    }

    private var mealsBinding: Binding<String> {
        Binding(get: { String(draft.mealsPerDay) }, set: { draft.mealsPerDay = Int($0) ?? 4 })
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
                                .foregroundStyle(VoCalTheme.Colors.ink)
                        }
                    }
                    .padding(VoCalTheme.Spacing.l)
                    .background(VoCalTheme.Colors.card, in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.card, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: VoCalTheme.Radius.card, style: .continuous)
                            .strokeBorder(selection == opt.value ? VoCalTheme.Colors.ink : .clear, lineWidth: 1.5)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// A single yes/no toggle styled as a selectable card row.
private struct ToggleChip: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: VoCalTheme.Spacing.m) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isOn ? VoCalTheme.Colors.ink : VoCalTheme.Colors.muted)
                Text(label)
                    .font(VoCalTheme.Fonts.primaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.ink)
                Spacer()
            }
            .padding(VoCalTheme.Spacing.l)
            .background(VoCalTheme.Colors.card, in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: VoCalTheme.Radius.card, style: .continuous)
                    .strokeBorder(isOn ? VoCalTheme.Colors.ink : .clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    struct Host: View {
        @State private var draft = IntakeDraft()
        var body: some View { IntakeFlowView(draft: $draft, onFinish: {}, onCancel: {}) }
    }
    return Host()
}
