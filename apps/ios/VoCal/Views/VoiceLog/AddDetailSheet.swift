import SwiftUI
import VoCalCore

/// The certainty banner's action surface: shows what would sharpen this estimate (the
/// certainty layer's own coaching tips as suggested questions) and a single mic CTA that
/// re-enters the capture flow. The spoken detail is appended to the meal's transcript and
/// re-parsed — the user never re-logs the whole meal to fix one missing detail.
struct AddDetailSheet: View {
    let certainty: MealCertainty
    /// Dismisses the sheet and starts the add-detail capture (VoiceLogViewModel.addDetail).
    var onSpeak: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: VoCalTheme.Spacing.l) {
            header

            Text("Say one more detail and the estimate recalculates — no need to log the meal again.")
                .font(VoCalTheme.Fonts.body)
                .foregroundStyle(VoCalTheme.Colors.muted)
                .fixedSize(horizontal: false, vertical: true)

            if !certainty.tips.isEmpty {
                VStack(alignment: .leading, spacing: VoCalTheme.Spacing.s) {
                    Text("Worth mentioning")
                        .sectionHeader()
                    ForEach(certainty.tips, id: \.self) { tip in
                        HStack(alignment: .top, spacing: VoCalTheme.Spacing.m) {
                            Image(systemName: "quote.bubble")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(VoCalTheme.Colors.gold)
                                .padding(.top, 2)
                            Text(tip)
                                .font(VoCalTheme.Fonts.secondaryLabel)
                                .foregroundStyle(VoCalTheme.Colors.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(VoCalTheme.Spacing.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            VoCalTheme.Colors.card,
                            in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.chip, style: .continuous)
                        )
                    }
                }
            }

            Spacer(minLength: 0)

            PillButton(title: "Add detail by voice", isEnabled: true) {
                dismiss()
                onSpeak()
            }
            .accessibilityIdentifier(A11y.VoiceLog.addDetailButton)
        }
        .padding(VoCalTheme.Spacing.l)
        .background(VoCalTheme.Colors.background)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Sharpen this estimate")
                    .font(VoCalTheme.Fonts.screenTitle)
                    .foregroundStyle(VoCalTheme.Colors.ink)
                Text("\(certainty.score)% certainty · \(certainty.displayLabel)")
                    .font(VoCalTheme.Fonts.formLabel)
                    .foregroundStyle(VoCalTheme.Colors.gold)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(VoCalTheme.Colors.muted)
                    .frame(width: 30, height: 30)
                    .background(VoCalTheme.Colors.card, in: Circle())
            }
            .accessibilityLabel("Close")
        }
    }
}
