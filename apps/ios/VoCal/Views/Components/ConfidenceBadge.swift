import SwiftUI

/// Per-item parse confidence, gold-scaled. Trust surface: the number must come
/// from the server's stated confidence — never invented client-side.
struct ConfidenceBadge: View {
    /// 0...1 confidence from the parse artifact.
    let confidence: Double

    private var percentText: String {
        "\(Int((confidence * 100).rounded()))%"
    }

    var body: some View {
        HStack(spacing: VoCalTheme.Spacing.xs) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 11, weight: .semibold))
            Text(percentText)
                .font(VoCalTheme.Fonts.formLabel.weight(.semibold))
        }
        .foregroundStyle(VoCalTheme.Colors.gold)
        .padding(.horizontal, VoCalTheme.Spacing.s)
        .padding(.vertical, VoCalTheme.Spacing.xs)
        .background(
            VoCalTheme.Colors.gold.opacity(0.12),
            in: Capsule()
        )
        .opacity(confidence < 0.5 ? 0.75 : 1)
    }
}

#Preview {
    HStack(spacing: VoCalTheme.Spacing.l) {
        ConfidenceBadge(confidence: 0.96)
        ConfidenceBadge(confidence: 0.71)
        ConfidenceBadge(confidence: 0.42)
    }
    .padding(VoCalTheme.Spacing.xl)
    .background(VoCalTheme.Colors.background)
}
