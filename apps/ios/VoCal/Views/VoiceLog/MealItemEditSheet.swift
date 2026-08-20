import SwiftUI
import VoCalCore

/// Edit a parsed item's details (amount/unit/fat ratio/state) to fill in what lowered its
/// confidence. On Save it emits refine answers for ONLY the changed fields; the server
/// re-resolves and the result's macros + confidence update — so an edit can push a flagged
/// item to high confidence. The client never invents numbers; it only restates the fields.
struct MealItemEditSheet: View {
    let index: Int
    let item: ParseResultItem
    var onSave: ([RefineAnswer]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var amountText: String
    @State private var unit: FoodUnit?
    @State private var fatRatio: String
    @State private var state: FoodState

    init(index: Int, item: ParseResultItem, onSave: @escaping ([RefineAnswer]) -> Void) {
        self.index = index
        self.item = item
        self.onSave = onSave
        _amountText = State(initialValue: item.amount.map(Self.numberText) ?? "")
        _unit = State(initialValue: item.unit)
        _fatRatio = State(initialValue: item.fatRatio ?? "")
        _state = State(initialValue: item.state)
    }

    var body: some View {
        ZStack {
            VoCalTheme.Colors.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: VoCalTheme.Spacing.xl) {
                    header
                    amountCard
                    unitSection
                    fatRatioCard
                    stateSection
                }
                .padding(.horizontal, VoCalTheme.Spacing.l)
                .padding(.top, VoCalTheme.Spacing.xl)
                .padding(.bottom, VoCalTheme.Spacing.xxl)
            }
        }
        .safeAreaInset(edge: .bottom) { footer }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: VoCalTheme.Spacing.xs) {
            Text("Fill in the details").sectionHeader()
            Text(item.name)
                .font(VoCalTheme.Fonts.screenTitle)
                .foregroundStyle(VoCalTheme.Colors.ink)
        }
    }

    // MARK: - Amount / Unit

    private var amountCard: some View {
        fieldCard(label: "Amount") {
            TextField("0", text: $amountText)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 17, weight: .medium, design: .monospaced))
                .foregroundStyle(VoCalTheme.Colors.ink)
                .accessibilityIdentifier("edit.amount")
        }
    }

    private var unitSection: some View {
        VStack(alignment: .leading, spacing: VoCalTheme.Spacing.s) {
            Text("Unit")
                .font(VoCalTheme.Fonts.formLabel)
                .foregroundStyle(VoCalTheme.Colors.muted)
            FlexibleChipLayout(spacing: VoCalTheme.Spacing.s) {
                EditChip(label: "None", isSelected: unit == nil) { unit = nil }
                ForEach(FoodUnit.allCases, id: \.self) { value in
                    EditChip(label: value.rawValue, isSelected: unit == value) { unit = value }
                }
            }
        }
    }

    // MARK: - Fat ratio

    private var fatRatioCard: some View {
        fieldCard(label: "Fat ratio") {
            TextField("e.g. 93/7", text: $fatRatio)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 17, weight: .medium, design: .monospaced))
                .foregroundStyle(VoCalTheme.Colors.ink)
                .autocorrectionDisabled()
                .accessibilityIdentifier("edit.fat-ratio")
        }
    }

    // MARK: - State

    private var stateSection: some View {
        VStack(alignment: .leading, spacing: VoCalTheme.Spacing.s) {
            Text("State")
                .font(VoCalTheme.Fonts.formLabel)
                .foregroundStyle(VoCalTheme.Colors.muted)
            FlexibleChipLayout(spacing: VoCalTheme.Spacing.s) {
                ForEach(FoodState.allCases, id: \.self) { value in
                    EditChip(label: value.rawValue.capitalized, isSelected: state == value) { state = value }
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: VoCalTheme.Spacing.s) {
            PillButton(title: "Save") { save() }
                .accessibilityIdentifier("edit.save")
            VoCalButton(title: "Cancel", kind: .tertiary) { dismiss() }
        }
        .padding(VoCalTheme.Spacing.l)
        // This pinned bar floats over the scrolling detail fields — same glass-over-scroll
        // treatment as the result screen's own confirm bar (VoiceLogResultView.confirmBar).
        .glassEffect(.regular, in: Rectangle())
    }

    /// Shared shell for the Amount / Fat ratio rows: a `vcWhite` elevated card, muted label
    /// left, the field filling and right-aligning the remaining width.
    private func fieldCard<Content: View>(label: String, @ViewBuilder field: () -> Content) -> some View {
        HStack(spacing: VoCalTheme.Spacing.m) {
            Text(label)
                .font(VoCalTheme.Fonts.formLabel)
                .foregroundStyle(VoCalTheme.Colors.muted)
            field()
        }
        .padding(VoCalTheme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            VoCalTheme.Colors.white,
            in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.chip, style: .continuous)
        )
    }

    private func save() {
        var answers: [RefineAnswer] = []
        let prefix = "items[\(index)]"
        // amount + unit are coupled in the backend's amount field; send them together as one
        // "<amount> <unit>" answer whenever either changed (a bare amount would clear the unit).
        let newAmount = Double(amountText.trimmingCharacters(in: .whitespaces))
        if (newAmount != item.amount || unit != item.unit), let amount = newAmount {
            let value = unit.map { "\(Self.numberText(amount)) \($0.rawValue)" } ?? Self.numberText(amount)
            answers.append(RefineAnswer(field: "\(prefix).amount", value: .string(value)))
        }
        let ratio = fatRatio.trimmingCharacters(in: .whitespaces)
        if ratio != (item.fatRatio ?? ""), !ratio.isEmpty {
            answers.append(RefineAnswer(field: "\(prefix).fat_ratio", value: .string(ratio)))
        }
        if state != item.state {
            answers.append(RefineAnswer(field: "\(prefix).state", value: .string(state.rawValue)))
        }
        dismiss()
        if !answers.isEmpty { onSave(answers) }
    }

    private static func numberText(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}

/// A single selectable chip (unit / state rows): `vcCard` fill throughout — selected adds an
/// ink border and bumps the label to semibold so the active choice reads at a glance without
/// reaching for gold (gold stays reserved for brand accent per docs/DESIGN.md).
private struct EditChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(isSelected ? VoCalTheme.Fonts.chipLabel.weight(.semibold) : VoCalTheme.Fonts.chipLabel)
                .foregroundStyle(isSelected ? VoCalTheme.Colors.ink : VoCalTheme.Colors.muted)
                .padding(.horizontal, VoCalTheme.Spacing.m)
                .padding(.vertical, VoCalTheme.Spacing.s)
                .background(
                    VoCalTheme.Colors.card,
                    in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.chip, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: VoCalTheme.Radius.chip, style: .continuous)
                        .strokeBorder(isSelected ? VoCalTheme.Colors.ink : .clear, lineWidth: 1.5)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
