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
    /// Apply per-item edits (refine answers) from the edit sheet.
    var onEditItem: (_ answers: [RefineAnswer]) -> Void
    /// Dismiss the sheet. The close control lives IN this view's header (not a floating
    /// overlay) so it never covers the title — same top-bar pattern as OnboardingStepScaffold.
    var onClose: () -> Void

    @State private var transcriptExpanded = false
    @State private var saveAsUsual = false
    @State private var editing: EditingItem?

    /// At/above this the meal reads as confirmed (93–100%); below it we guide the user to edit.
    private let highConfidence = 0.93

    private struct EditingItem: Identifiable {
        let id: Int
        let item: ParseResultItem
    }

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
                if needsEditGuidance {
                    Text("Tap a flagged item to add a detail and reach 100%.")
                        .font(VoCalTheme.Fonts.formLabel)
                        .foregroundStyle(VoCalTheme.Colors.gold)
                }
                itemList
            }
            .padding(VoCalTheme.Spacing.l)
            .padding(.bottom, 120) // room above the pinned CTA
        }
        .safeAreaInset(edge: .bottom) {
            confirmBar
        }
        .sheet(item: $editing) { target in
            MealItemEditSheet(index: target.id, item: target.item) { answers in
                onEditItem(answers)
            }
            .presentationDetents([.medium, .large])
        }
    }

    /// Below the high-confidence bar (or any open check) → guide the user to edit.
    private var needsEditGuidance: Bool {
        hasOpenChecks || context.result.mealConfidence < highConfidence
    }

    private var header: some View {
        HStack(spacing: VoCalTheme.Spacing.s) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(VoCalTheme.Colors.ink)
                    .frame(width: 36, height: 36)
                    .background(VoCalTheme.Colors.card, in: Circle())
            }
            .accessibilityIdentifier(A11y.VoiceLog.cancelButton)
            .accessibilityLabel("Close")
            Text(mealName)
                .font(VoCalTheme.Fonts.screenTitle)
                .foregroundStyle(VoCalTheme.Colors.ink)
            Spacer()
            if hasOpenChecks {
                Text("\(context.result.questions.count) check\(context.result.questions.count > 1 ? "s" : "") left")
                    .font(VoCalTheme.Fonts.formLabel.weight(.semibold))
                    .foregroundStyle(VoCalTheme.Colors.gold)
            }
            // Always show meal confidence so the 93–100% target is visible while editing.
            ConfidenceBadge(confidence: context.result.mealConfidence)
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
        GlassCard {
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
                    MealItemCard(
                        item: item,
                        onDelete: { onDelete(index) },
                        onEdit: { editing = EditingItem(id: index, item: item) }
                    )
                }
            }
        }
    }

    private var confirmBar: some View {
        VStack(spacing: VoCalTheme.Spacing.s) {
            if hasOpenChecks {
                VoCalButton(title: "Log anyway (typical values)", kind: .tertiary, isEnabled: !context.isRefining) {
                    onLogAnyway()
                }
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
