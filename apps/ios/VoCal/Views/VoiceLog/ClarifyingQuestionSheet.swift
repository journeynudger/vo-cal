import SwiftUI
import VoCalCore

/// The one clarifying question as a bottom sheet (D2): the highest-impact question with
/// quick-answer chips drawn from `MissingDetail.options`, a free-text fallback, and an
/// explicit Skip ("log as-is at ~N% confidence"). The inline IngredientCheckCard is the
/// primary surface in the result list; this sheet is the alternate presentation for a
/// single focused question. Skipping never blocks logging (PARSER_CONTRACT clarifying rule).
struct ClarifyingQuestionSheet: View {
    let question: MissingDetail
    let currentConfidence: Double
    var isAnswering: Bool
    var onAnswer: (String) -> Void
    var onSkip: () -> Void

    @State private var freeText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: VoCalTheme.Spacing.l) {
            Text("One quick check")
                .font(VoCalTheme.Fonts.formLabel.weight(.semibold))
                .tracking(0.5)
                .foregroundStyle(VoCalTheme.Colors.gold)
            Text(question.question)
                .font(VoCalTheme.Fonts.screenTitle)
                .foregroundStyle(VoCalTheme.Colors.ink)

            if let options = question.options, !options.isEmpty {
                FlowChips(options: options, isDisabled: isAnswering, onTap: onAnswer)
            }

            HStack(spacing: VoCalTheme.Spacing.s) {
                TextField("Or type an answer", text: $freeText)
                    .textFieldStyle(.plain)
                    .font(VoCalTheme.Fonts.body)
                    .padding(.horizontal, VoCalTheme.Spacing.m)
                    .frame(height: 44)
                    .background(
                        VoCalTheme.Colors.card,
                        in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.chip, style: .continuous)
                    )
                Button {
                    let trimmed = freeText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    onAnswer(trimmed)
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(VoCalTheme.Colors.cta)
                }
                .disabled(isAnswering || freeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Button(action: onSkip) {
                Text("Skip - log as-is at ~\(Int((currentConfidence * 100).rounded()))% confidence")
                    .font(VoCalTheme.Fonts.secondaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
            }
            .disabled(isAnswering)
        }
        .padding(VoCalTheme.Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VoCalTheme.Colors.background)
        .accessibilityIdentifier(A11y.VoiceLog.checkCard)
    }
}

#Preview {
    ClarifyingQuestionSheet(
        question: MissingDetail(
            field: "items[0].fat_ratio",
            importance: .high,
            question: "Fat ratio of the beef - like 80/20 or 93/7?",
            options: ["80/20", "85/15", "90/10", "93/7"]
        ),
        currentConfidence: 0.62,
        isAnswering: false,
        onAnswer: { _ in },
        onSkip: {}
    )
}
