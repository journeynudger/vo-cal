import SwiftUI
import VoCalCore

/// A per-ingredient check inline on the result list (decision #29): the unknown materially
/// moves the meal, so its item shows a gold-bordered card with the question and quick-answer
/// chips drawn from `MissingDetail.options`. Answering routes through refine; macros update
/// in place. Calories read "so far +" on the result header until every check is resolved.
struct IngredientCheckCard: View {
    let itemName: String
    let question: MissingDetail
    /// The item as it stands, so the card shows what is being priced (amount, calories,
    /// macros) beside the question; a card with only a question hid the numbers the
    /// question moves (critic, 2026-09-24).
    var item: ParseResultItem?
    var isAnswering: Bool
    var onAnswer: (String) -> Void

    var body: some View {
        GlassCard(accent: VoCalTheme.Colors.gold) {
            VStack(alignment: .leading, spacing: VoCalTheme.Spacing.s) {
                HStack(alignment: .firstTextBaseline, spacing: VoCalTheme.Spacing.xs) {
                    // The gold hairline and the question say "check"; a floating "?" read as
                    // an error marker (critic, 2026-09-25).
                    Text(itemName)
                        .font(VoCalTheme.Fonts.primaryLabel)
                        .foregroundStyle(VoCalTheme.Colors.ink)
                    Spacer(minLength: VoCalTheme.Spacing.s)
                    if let item {
                        Text("\(Int(item.macros.kcal.rounded())) cal")
                            .font(VoCalTheme.Fonts.secondaryLabel)
                            .monospacedDigit()
                            .foregroundStyle(VoCalTheme.Colors.muted)
                    }
                }
                if let item, let line = Self.numbersLine(item) {
                    Text(line)
                        .font(VoCalTheme.Fonts.formLabel)
                        .foregroundStyle(VoCalTheme.Colors.muted)
                }
                Text(question.question)
                    .font(VoCalTheme.Fonts.secondaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.ink)
                    .fixedSize(horizontal: false, vertical: true)

                if let options = question.options, !options.isEmpty {
                    FlowChips(options: options, isDisabled: isAnswering, onTap: onAnswer)
                }
                if isAnswering {
                    HStack(spacing: VoCalTheme.Spacing.s) {
                        VoCalLoader(size: 18)
                        Text("Updating\u{2026}")
                            .font(VoCalTheme.Fonts.formLabel)
                            .foregroundStyle(VoCalTheme.Colors.muted)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(A11y.VoiceLog.checkCard)
    }

    /// "1 tbsp · 5P 26C 2F": the amount as parsed and the macros as priced.
    static func numbersLine(_ item: ParseResultItem) -> String? {
        var parts: [String] = []
        if let amount = item.amount {
            let amountText = amount == amount.rounded() ? String(Int(amount)) : String(format: "%.1f", amount)
            parts.append(item.unit.map { "\(amountText) \($0.rawValue)" } ?? amountText)
        }
        if item.state != .unspecified { parts.append(item.state.rawValue) }
        let macros = "\(Int(item.macros.protein.rounded()))P  \(Int(item.macros.carbs.rounded()))C  \(Int(item.macros.fat.rounded()))F"
        parts.append(macros)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Wrapping row of quick-answer chips. Small, self-sizing; wraps to new lines as needed.
struct FlowChips: View {
    let options: [String]
    var isDisabled: Bool = false
    var onTap: (String) -> Void

    var body: some View {
        // A simple wrapping layout via a flexible grid keeps this dependency-free and
        // compiles clean under strict concurrency (no PreferenceKey gymnastics).
        FlexibleChipLayout(spacing: VoCalTheme.Spacing.s) {
            ForEach(options, id: \.self) { option in
                Button {
                    // The RAW option string is the answer contract (variant keys like
                    // "sugar_free" round-trip through /parse/refine) — only the LABEL
                    // below is humanized. Never send the prettified text.
                    VoCalHaptics.select()
                    onTap(option)
                } label: {
                    Text(option.replacingOccurrences(of: "_", with: " "))
                        .font(VoCalTheme.Fonts.chipLabel.weight(.semibold))
                        .foregroundStyle(VoCalTheme.Colors.ink)
                        .padding(.horizontal, VoCalTheme.Spacing.l)
                        // 44 pt tall: the touch target the audit asks for (the 32 pt chips
                        // were the smallest controls on the result, 2026-09-24).
                        .frame(minHeight: 44)
                        .background(
                            VoCalTheme.Colors.card,
                            in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.chip, style: .continuous)
                        )
                }
                .disabled(isDisabled)
            }
        }
        .opacity(isDisabled ? 0.5 : 1)
    }
}

/// A minimal flow (wrapping HStack) layout — places subviews left to right, wrapping to the
/// next row when the line is full. Used for chip rows.
struct FlexibleChipLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth, rowWidth > 0 {
                totalHeight += rowHeight + spacing
                totalWidth = max(totalWidth, rowWidth - spacing)
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        totalWidth = max(totalWidth, rowWidth - spacing)
        return CGSize(width: min(totalWidth, maxWidth), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let maxWidth = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + maxWidth, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
