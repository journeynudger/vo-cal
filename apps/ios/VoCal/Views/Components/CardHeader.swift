import SwiftUI

/// The one header every card starts with (Rams pass, 2026-09-25): a 13 pt muted title, an
/// optional completion tick beside it, then the card's value, then one supporting line.
/// The spacings are fixed here (8 pt under the title, 4 pt under the value) so every card's
/// title, number and support sit on the same rhythm; before this each card chose its own
/// (2, 4, 8 and 12 pt were all in use and the page read as uneven).
struct CardHeader<Value: View>: View {
    let title: String
    var isComplete = false
    var support: String?
    @ViewBuilder var value: Value

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(title)
                    .font(VoCalTheme.Fonts.formLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
                    .lineLimit(1)
                if isComplete {
                    // Completion is a mark by the title, never a tinted card: the fill stays
                    // the one card colour and state reads as an accent.
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(VoCalTheme.Colors.optimal)
                        .accessibilityLabel("Goal met")
                }
                Spacer(minLength: 0)
            }
            value
                .padding(.top, VoCalTheme.Spacing.s)
            if let support {
                Text(support)
                    .font(VoCalTheme.Fonts.formLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.top, VoCalTheme.Spacing.xs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    VStack(spacing: 16) {
        StatCard {
            CardHeader(title: "Calories left", support: "of 2,040 today") {
                Text("1,180").font(VoCalTheme.Fonts.numeral(42)).foregroundStyle(VoCalTheme.Colors.gold)
            }
        }
        StatCard(isComplete: true) {
            CardHeader(title: "Protein", isComplete: true, support: "In your optimal range") {
                Text("152 g").font(VoCalTheme.Fonts.numeral(34)).foregroundStyle(VoCalTheme.Colors.ink)
            }
        }
    }
    .padding()
    .background(VoCalTheme.Colors.background)
}
