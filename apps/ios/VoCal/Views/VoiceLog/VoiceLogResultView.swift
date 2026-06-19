import SwiftUI
import VoCalCore

/// The parse result screen: calories card with flame + numeral, P/C/F chip row, collapsible
/// transcript provenance drawer, per-item meal cards, inline per-ingredient checks, and the
/// black-pill confirm CTA. Layout follows the Create Meal screenshot + DESIGN.md §5.
struct VoiceLogResultView: View {
    let context: ResultContext
    let mealType: MealType

    var onAnswer: (_ field: String, _ option: String) -> Void
    var onLogAnyway: () -> Void
    var onDelete: (_ index: Int) -> Void
    var onConfirm: (_ saveAsUsual: Bool) -> Void

    @State private var transcriptExpanded = false
    @State private var saveAsUsual = false

    private var hasOpenChecks: Bool { context.hasOpenChecks }
    private var totals: NutrientProfile { context.result.totals }

    /// Map a question's field ("items[1].variant") back to its item index for inline checks.
    private func itemIndex(forField field: String) -> Int? {
        guard let open = field.firstIndex(of: "["),
              let close = field.firstIndex(of: "]"),
              open < close
        else { return nil }
        return Int(field[field.index(after: open)..<close])
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VoCalTheme.Spacing.m) {
                header
                caloriesCard
                macroChips
                transcriptDrawer
                Text("Meal items")
                    .font(VoCalTheme.Fonts.formLabel.weight(.semibold))
                    .foregroundStyle(VoCalTheme.Colors.muted)
                    .padding(.top, VoCalTheme.Spacing.s)
                itemList
            }
            .padding(VoCalTheme.Spacing.l)
            .padding(.bottom, 120) // room above the pinned CTA
        }
        .safeAreaInset(edge: .bottom) {
            confirmBar
        }
    }

    private var header: some View {
        HStack {
            Text(mealName)
                .font(VoCalTheme.Fonts.screenTitle)
                .foregroundStyle(VoCalTheme.Colors.ink)
            Spacer()
            if hasOpenChecks {
                Text("\(context.result.questions.count) check\(context.result.questions.count > 1 ? "s" : "") left")
                    .font(VoCalTheme.Fonts.formLabel.weight(.semibold))
                    .foregroundStyle(VoCalTheme.Colors.gold)
            } else {
                ConfidenceBadge(confidence: context.result.mealConfidence)
            }
        }
    }

    private var mealName: String {
        switch mealType {
        case .breakfast: return "Breakfast"
        case .lunch: return "Lunch"
        case .dinner: return "Dinner"
        case .snack: return "Snack"
        case .unspecified: return "Meal"
        }
    }

    private var caloriesCard: some View {
        StatCard {
            HStack(spacing: VoCalTheme.Spacing.m) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(VoCalTheme.Colors.gold)
                VStack(alignment: .leading, spacing: 0) {
                    Text(hasOpenChecks ? "Calories (so far)" : "Calories")
                        .font(VoCalTheme.Fonts.formLabel)
                        .foregroundStyle(VoCalTheme.Colors.muted)
                    Text("\(Int(totals.kcal.rounded()))\(hasOpenChecks ? "+" : "")")
                        .font(VoCalTheme.Fonts.numeral(48).monospacedDigit())
                        .foregroundStyle(VoCalTheme.Colors.ink)
                }
                Spacer()
            }
        }
        .accessibilityIdentifier(A11y.VoiceLog.caloriesCard)
    }

    private var macroChips: some View {
        HStack(spacing: VoCalTheme.Spacing.s) {
            macroChip("Protein", grams: totals.protein, color: VoCalTheme.Colors.protein)
            macroChip("Carbs", grams: totals.carbs, color: VoCalTheme.Colors.carbs)
            macroChip("Fats", grams: totals.fat, color: VoCalTheme.Colors.fats)
        }
    }

    private func macroChip(_ label: String, grams: Double, color: Color) -> some View {
        VStack(spacing: VoCalTheme.Spacing.xs) {
            Text(label)
                .font(VoCalTheme.Fonts.formLabel)
                .foregroundStyle(VoCalTheme.Colors.muted)
            Text("\(gramsText(grams))g\(hasOpenChecks ? "+" : "")")
                .font(VoCalTheme.Fonts.primaryLabel.monospacedDigit())
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, VoCalTheme.Spacing.m)
        .background(
            VoCalTheme.Colors.card,
            in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.chip, style: .continuous)
        )
    }

    private func gramsText(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    private var transcriptDrawer: some View {
        DisclosureGroup(isExpanded: $transcriptExpanded) {
            Text("\u{201C}\(context.transcript)\u{201D}")
                .font(VoCalTheme.Fonts.secondaryLabel)
                .foregroundStyle(VoCalTheme.Colors.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, VoCalTheme.Spacing.xs)
        } label: {
            Text("What you said")
                .font(VoCalTheme.Fonts.formLabel)
                .foregroundStyle(VoCalTheme.Colors.muted)
        }
        .tint(VoCalTheme.Colors.muted)
        .accessibilityIdentifier(A11y.VoiceLog.transcriptDrawer)
    }

    private var itemList: some View {
        VStack(spacing: VoCalTheme.Spacing.m) {
            ForEach(Array(context.result.items.enumerated()), id: \.offset) { index, item in
                if let question = context.result.questions.first(where: { itemIndex(forField: $0.field) == index }) {
                    IngredientCheckCard(
                        itemName: item.name,
                        question: question,
                        isAnswering: context.isRefining,
                        onAnswer: { option in onAnswer(question.field, option) }
                    )
                } else {
                    MealItemCard(item: item, onDelete: { onDelete(index) })
                }
            }
        }
    }

    private var confirmBar: some View {
        VStack(spacing: VoCalTheme.Spacing.s) {
            if hasOpenChecks {
                Button(action: onLogAnyway) {
                    Text("Log anyway (typical values)")
                        .font(VoCalTheme.Fonts.secondaryLabel.weight(.medium))
                        .foregroundStyle(VoCalTheme.Colors.muted)
                }
                .disabled(context.isRefining)
                .accessibilityIdentifier(A11y.VoiceLog.logAnywayButton)
            } else {
                Toggle(isOn: $saveAsUsual) {
                    Text("Save as usual")
                        .font(VoCalTheme.Fonts.secondaryLabel)
                        .foregroundStyle(VoCalTheme.Colors.muted)
                }
                .tint(VoCalTheme.Colors.gold)
                .padding(.horizontal, VoCalTheme.Spacing.xs)
            }

            PillButton(
                title: hasOpenChecks
                    ? "Log meal (\(Int(totals.kcal.rounded()))+ cal)"
                    : "Log meal (\(Int(totals.kcal.rounded())) cal)",
                isEnabled: !context.isRefining
            ) {
                onConfirm(saveAsUsual)
            }
            .accessibilityIdentifier(A11y.VoiceLog.confirmButton)
        }
        .padding(VoCalTheme.Spacing.l)
        .background(.ultraThinMaterial)
    }
}
