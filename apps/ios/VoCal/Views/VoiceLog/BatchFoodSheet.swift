import SwiftUI
import VoCalCore

/// The items on the result are a batch the person cooked, not a meal they ate: name it and say
/// how many servings it makes, and the server keeps it as a recipe (the resolved ingredients
/// summed and divided; the serving weight follows). From then on "a serving of chili" logs
/// with those numbers. Two steps on one sheet: save, then log a serving now or not.
struct BatchFoodSheet: View {
    let itemCount: Int
    let totalKcal: Double
    var onSave: (_ name: String, _ servings: Double) async throws -> PersonalFood
    var onLogServing: (_ food: PersonalFood) -> Void
    /// The batch was saved and nothing is being logged: the voice sheet closes too.
    var onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var servings = ""
    @State private var saving = false
    @State private var failed = false
    @State private var saved: PersonalFood?

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && (Double(servings) ?? 0) > 0 && !saving
    }

    var body: some View {
        ZStack {
            VoCalTheme.Colors.background.ignoresSafeArea()
            if let saved {
                savedStep(saved)
            } else {
                entryStep
            }
        }
        .alert("Not saved", isPresented: $failed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("That didn't reach the server. Check your connection and try again.")
        }
    }

    private var entryStep: some View {
        VStack(alignment: .leading, spacing: VoCalTheme.Spacing.l) {
            VStack(alignment: .leading, spacing: 2) {
                Text("A batch you cooked").sectionHeader()
                Text("Save it as a recipe")
                    .font(VoCalTheme.Fonts.screenTitle)
                    .foregroundStyle(VoCalTheme.Colors.ink)
                Text("These \(itemCount) \(itemCount == 1 ? "item is" : "items are") the whole batch, \(Int(totalKcal.rounded())) cal. Each serving gets its share.")
                    .font(VoCalTheme.Fonts.secondaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, VoCalTheme.Spacing.xl)

            VStack(spacing: VoCalTheme.Spacing.s) {
                row("Name") {
                    TextField("Chili", text: $name)
                        .multilineTextAlignment(.trailing)
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(VoCalTheme.Colors.ink)
                }
                row("Servings it makes") {
                    TextField("8", text: $servings)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .font(.system(size: 17, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(VoCalTheme.Colors.ink)
                        .frame(width: 100)
                }
            }

            Spacer()

            PillButton(title: saving ? "Saving" : "Save recipe", isEnabled: canSave) {
                Task { await save() }
            }
            .accessibilityIdentifier(A11y.VoiceLog.saveRecipeConfirmButton)
            VoCalButton(title: "Cancel", kind: .tertiary) { dismiss() }
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, VoCalTheme.Spacing.l)
        .padding(.bottom, VoCalTheme.Spacing.s)
    }

    private func savedStep(_ food: PersonalFood) -> some View {
        VStack(alignment: .leading, spacing: VoCalTheme.Spacing.l) {
            VStack(alignment: .leading, spacing: 2) {
                // Not the claim word: the recipe is in Settings > My foods, and that is what it says.
                Text("In your foods").sectionHeader()
                Text(food.name)
                    .font(VoCalTheme.Fonts.screenTitle)
                    .foregroundStyle(VoCalTheme.Colors.ink)
                Text("\(Int(food.perServing.kcal.rounded())) cal a serving. Next time, say \u{201C}a serving of \(food.name)\u{201D} and it logs with these numbers.")
                    .font(VoCalTheme.Fonts.secondaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, VoCalTheme.Spacing.xl)

            Spacer()

            PillButton(title: "Log one serving now") {
                dismiss()
                onLogServing(food)
            }
            .accessibilityIdentifier(A11y.VoiceLog.logServingButton)
            VoCalButton(title: "Done, nothing eaten yet", kind: .tertiary) {
                dismiss()
                onDone()
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, VoCalTheme.Spacing.l)
        .padding(.bottom, VoCalTheme.Spacing.s)
    }

    private func save() async {
        guard let n = Double(servings), n > 0 else { return }
        saving = true
        defer { saving = false }
        do {
            saved = try await onSave(name.trimmingCharacters(in: .whitespaces), n)
        } catch {
            failed = true
        }
    }

    private func row<Field: View>(_ label: String, @ViewBuilder field: () -> Field) -> some View {
        HStack {
            Text(label)
                .font(VoCalTheme.Fonts.formLabel)
                .foregroundStyle(VoCalTheme.Colors.muted)
            Spacer(minLength: VoCalTheme.Spacing.s)
            field()
        }
        .padding(.horizontal, VoCalTheme.Spacing.l)
        .padding(.vertical, VoCalTheme.Spacing.m)
        .background(
            VoCalTheme.Colors.softFill,
            in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.chip, style: .continuous)
        )
    }
}
