import SwiftUI
import VoCalCore

/// "Is this your metal detox smoothie?" (decision 51): the usual this parse looks like, asked
/// above the result, never assumed. Yes logs the usual's items under its name; No hides the
/// card and the parse stands as it is. The first time a person sees this, one line says how
/// it came to be, so they know naming a meal once is what makes it offered from then on.
struct RecognizedMealCard: View {
    let usual: RecognizedMeal
    var isBusy = false
    let onYes: () -> Void
    let onNo: () -> Void

    @AppStorage("vocal.recognition.hinted") private var hinted = false

    var body: some View {
        GlassCard(accent: VoCalTheme.Colors.gold) {
            VStack(alignment: .leading, spacing: VoCalTheme.Spacing.s) {
                Text("Is this your \(usual.name)?")
                    .font(VoCalTheme.Fonts.primaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(Int(usual.totals.kcal.rounded())) cal · \(usual.items.count) item\(usual.items.count == 1 ? "" : "s"), as you logged it before")
                    .font(VoCalTheme.Fonts.formLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
                HStack(spacing: VoCalTheme.Spacing.s) {
                    PillButton(title: "Yes, that one", isEnabled: !isBusy) {
                        hinted = true
                        VoCalHaptics.success()
                        onYes()
                    }
                    .accessibilityIdentifier(A11y.VoiceLog.recognizedYes)
                    VoCalButton(title: "No", kind: .tertiary, isEnabled: !isBusy) {
                        hinted = true
                        onNo()
                    }
                    .accessibilityIdentifier(A11y.VoiceLog.recognizedNo)
                }
                .padding(.top, VoCalTheme.Spacing.xs)
                if !hinted {
                    Text("Name a meal once and Vo-Cal offers it by name from then on.")
                        .font(VoCalTheme.Fonts.formLabel)
                        .foregroundStyle(VoCalTheme.Colors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(A11y.VoiceLog.recognizedCard)
    }
}

#Preview {
    RecognizedMealCard(
        usual: RecognizedMeal(
            id: "u1", name: "Metal detox smoothie",
            items: [RecognizedMealItem(name: "banana", grams: 118, macros: NutrientProfile(kcal: 105, protein: 1, carbs: 27, fat: 0, fiber: 3))],
            totals: NutrientProfile(kcal: 310, protein: 24, carbs: 40, fat: 6, fiber: 7),
            reason: "name"
        ),
        onYes: {}, onNo: {}
    )
    .padding()
    .background(VoCalTheme.Colors.background)
}
