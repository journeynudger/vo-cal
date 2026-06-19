import SwiftUI
import VoCalCore

/// A per-ingredient check inline on the result list (decision #29): the unknown materially
/// moves the meal, so its item shows a gold-bordered card with the question and quick-answer
/// chips drawn from `MissingDetail.options`. Answering routes through refine; macros update
/// in place. Calories read "so far +" on the result header until every check is resolved.
struct IngredientCheckCard: View {
    let itemName: String
    let question: MissingDetail
    var isAnswering: Bool
    var onAnswer: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: VoCalTheme.Spacing.s) {
            HStack {
                HStack(spacing: VoCalTheme.Spacing.xs) {
                    Text("?")
                        .font(VoCalTheme.Fonts.primaryLabel.weight(.semibold))
                        .foregroundStyle(VoCalTheme.Colors.gold)
                    Text(itemName)
                        .font(VoCalTheme.Fonts.primaryLabel)
                        .foregroundStyle(VoCalTheme.Colors.ink)
                }
                Spacer()
                Text("CHECK")
                    .font(VoCalTheme.Fonts.formLabel.weight(.semibold))
                    .tracking(0.5)
                    .foregroundStyle(VoCalTheme.Colors.gold)
            }
            Text(question.question)
                .font(VoCalTheme.Fonts.secondaryLabel)
                .foregroundStyle(VoCalTheme.Colors.muted)

            if let options = question.options, !options.isEmpty {
                FlowChips(options: options, isDisabled: isAnswering, onTap: onAnswer)
            }
            if isAnswering {
                HStack(spacing: VoCalTheme.Spacing.s) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Updating…")
                        .font(VoCalTheme.Fonts.formLabel)
                        .foregroundStyle(VoCalTheme.Colors.muted)
                }
            }
        }
        .padding(VoCalTheme.Spacing.l)
        .background(
            VoCalTheme.Colors.onCta,
            in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.card, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: VoCalTheme.Radius.card, style: .continuous)
                .stroke(VoCalTheme.Colors.gold, lineWidth: 1.5)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(A11y.VoiceLog.checkCard)
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
                    onTap(option)
                } label: {
                    Text(option)
                        .font(VoCalTheme.Fonts.chipLabel.weight(.semibold))
                        .foregroundStyle(VoCalTheme.Colors.ink)
                        .padding(.horizontal, VoCalTheme.Spacing.m)
                        .padding(.vertical, VoCalTheme.Spacing.s)
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
