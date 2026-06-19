import SwiftUI
import VoCalCore

/// A resolved parse item row on the result screen: name, amount + unit + state, per-item
/// kcal, ConfidenceBadge, and a trash affordance. Card surface + radius from DESIGN.md.
struct MealItemCard: View {
    let item: ParseResultItem
    var onDelete: (() -> Void)?

    private var amountLine: String {
        var parts: [String] = []
        if let amount = item.amount {
            let amountText = amount == amount.rounded()
                ? String(Int(amount))
                : String(format: "%.1f", amount)
            if let unit = item.unit {
                parts.append("\(amountText) \(unit.rawValue)")
            } else {
                parts.append(amountText)
            }
        }
        if item.state != .unspecified {
            parts.append(item.state.rawValue)
        }
        if let fatRatio = item.fatRatio {
            parts.append(fatRatio)
        }
        if let variant = item.variant {
            parts.append(variant)
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        StatCard {
            VStack(alignment: .leading, spacing: VoCalTheme.Spacing.xs) {
                HStack(alignment: .firstTextBaseline, spacing: VoCalTheme.Spacing.s) {
                    Text(item.name)
                        .font(VoCalTheme.Fonts.primaryLabel)
                        .foregroundStyle(VoCalTheme.Colors.ink)
                    Spacer(minLength: VoCalTheme.Spacing.s)
                    ConfidenceBadge(confidence: item.confidence)
                }
                if !amountLine.isEmpty {
                    Text(amountLine)
                        .font(VoCalTheme.Fonts.secondaryLabel)
                        .foregroundStyle(VoCalTheme.Colors.muted)
                }
                HStack(spacing: VoCalTheme.Spacing.m) {
                    Text("\(Int(item.macros.kcal.rounded())) cal")
                        .font(VoCalTheme.Fonts.secondaryLabel)
                        .foregroundStyle(VoCalTheme.Colors.muted)
                    Text("\(macroText(item.macros.protein))P  \(macroText(item.macros.carbs))C  \(macroText(item.macros.fat))F")
                        .font(VoCalTheme.Fonts.formLabel)
                        .foregroundStyle(VoCalTheme.Colors.muted)
                    Spacer()
                    if let onDelete {
                        Button(role: .destructive, action: onDelete) {
                            Image(systemName: "trash")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(VoCalTheme.Colors.muted)
                        }
                        .accessibilityLabel("Delete \(item.name)")
                    }
                }
            }
        }
    }

    private func macroText(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}

#Preview {
    VStack(spacing: VoCalTheme.Spacing.m) {
        MealItemCard(
            item: ParseResultItem(
                name: "Ground beef 93/7", amount: 4, unit: .oz, state: .cooked, fatRatio: "93/7",
                grams: 113, macros: NutrientProfile(kcal: 170, protein: 24, carbs: 0, fat: 8, fiber: 0),
                confidence: 0.96, source: .dictionary, matchScore: 0.96
            ),
            onDelete: {}
        )
    }
    .padding(VoCalTheme.Spacing.l)
    .background(VoCalTheme.Colors.background)
}
