import SwiftUI
import VoCalCore

/// A food no database has (a meal-prep container, a product not out yet): the person types
/// the label once, per serving, and says how much they had. The server keeps the food under
/// its name and prices it from then on, so next time saying the name is enough. Calories
/// fill in from the macros (4, 4, 9) unless the label's own figure is typed; nothing is
/// summed on the phone. The keyboard's own microphone makes every field speakable.
struct LabelFoodSheet: View {
    let item: ParseResultItem
    var onSave: (_ request: SaveLabelFoodRequest, _ servingsEaten: Double) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var protein = ""
    @State private var carbs = ""
    @State private var fat = ""
    @State private var fiber = ""
    @State private var kcal = ""
    @State private var servingGrams = ""
    @State private var servingsInPackage = ""
    @State private var servingsEaten: String
    @State private var saving = false
    @State private var failed = false

    init(item: ParseResultItem, onSave: @escaping (_ request: SaveLabelFoodRequest, _ servingsEaten: Double) async throws -> Void) {
        self.item = item
        self.onSave = onSave
        _name = State(initialValue: item.name)
        // A count with no unit ("two taco chickens") is already a number of servings.
        let eaten = item.unit == nil ? (item.amount ?? 1) : 1
        _servingsEaten = State(initialValue: RefineAmountAnswer.text(amount: eaten, unit: nil))
    }

    private var macrosGiven: Bool {
        Double(protein) != nil && Double(carbs) != nil && Double(fat) != nil
    }

    /// The calorie identity, shown while the calorie field is blank.
    private var computedKcal: Double? {
        guard let p = Double(protein), let c = Double(carbs), let f = Double(fat) else { return nil }
        return (p * 4 + c * 4 + f * 9).rounded()
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && macrosGiven && (Double(servingsEaten) ?? 0) > 0 && !saving
    }

    var body: some View {
        ZStack {
            VoCalTheme.Colors.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: VoCalTheme.Spacing.l) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("From its label").sectionHeader()
                        Text("Enter its nutrition")
                            .font(VoCalTheme.Fonts.screenTitle)
                            .foregroundStyle(VoCalTheme.Colors.ink)
                        Text("Per serving, as printed. Vo-Cal remembers it, so next time saying its name is enough.")
                            .font(VoCalTheme.Fonts.secondaryLabel)
                            .foregroundStyle(VoCalTheme.Colors.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, VoCalTheme.Spacing.xl)

                    VStack(spacing: VoCalTheme.Spacing.s) {
                        textField("Name", $name)
                        numberField("Protein (g)", $protein)
                        numberField("Carbs (g)", $carbs)
                        numberField("Fat (g)", $fat)
                        numberField("Fiber (g), if listed", $fiber)
                        numberField("Calories", $kcal, placeholder: computedKcal.map { String(Int($0)) } ?? "from macros", width: 150)
                        numberField("Serving size (g), if listed", $servingGrams)
                        numberField("Servings in the package, if listed", $servingsInPackage)
                    }

                    VStack(spacing: VoCalTheme.Spacing.s) {
                        numberField("Servings I had", $servingsEaten, emphasized: true)
                    }
                }
                .padding(.horizontal, VoCalTheme.Spacing.l)
                .padding(.bottom, VoCalTheme.Spacing.xxl)
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: VoCalTheme.Spacing.s) {
                PillButton(title: saving ? "Saving" : "Save and use it", isEnabled: canSave) {
                    Task { await save() }
                }
                .accessibilityIdentifier(A11y.VoiceLog.labelFoodSaveButton)
                VoCalButton(title: "Cancel", kind: .tertiary) { dismiss() }
                    .frame(maxWidth: .infinity)
            }
            .padding(VoCalTheme.Spacing.l)
            .glassEffect(.regular, in: Rectangle())
        }
        .alert("Not saved", isPresented: $failed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("That didn't reach the server. Check your connection and try again.")
        }
    }

    private func save() async {
        guard let p = Double(protein), let c = Double(carbs), let f = Double(fat),
              let eaten = Double(servingsEaten), eaten > 0 else { return }
        saving = true
        defer { saving = false }
        let request = SaveLabelFoodRequest(
            name: name.trimmingCharacters(in: .whitespaces),
            perServing: DeclaredServing(kcal: Double(kcal), protein: p, carbs: c, fat: f, fiber: Double(fiber) ?? 0),
            servingGrams: Double(servingGrams),
            servingsPerPackage: Double(servingsInPackage),
            aliases: name.lowercased() == item.name.lowercased() ? [] : [item.name]
        )
        do {
            try await onSave(request, eaten)
            dismiss()
        } catch {
            failed = true
        }
    }

    private func textField(_ label: String, _ text: Binding<String>) -> some View {
        row(label) {
            TextField("", text: text)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(VoCalTheme.Colors.ink)
        }
    }

    private func numberField(_ label: String, _ text: Binding<String>, placeholder: String = "0", emphasized: Bool = false, width: CGFloat = 120) -> some View {
        row(label, emphasized: emphasized) {
            TextField(placeholder, text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 17, weight: emphasized ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(VoCalTheme.Colors.ink)
                .frame(width: width)
        }
    }

    private func row<Field: View>(_ label: String, emphasized: Bool = false, @ViewBuilder field: () -> Field) -> some View {
        HStack {
            Text(label)
                .font(VoCalTheme.Fonts.formLabel)
                .foregroundStyle(emphasized ? VoCalTheme.Colors.ink : VoCalTheme.Colors.muted)
            Spacer(minLength: VoCalTheme.Spacing.s)
            field()
        }
        .padding(.horizontal, VoCalTheme.Spacing.l)
        .padding(.vertical, VoCalTheme.Spacing.m)
        .background(
            VoCalTheme.Colors.softFill,
            in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.chip, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: VoCalTheme.Radius.chip, style: .continuous)
                .strokeBorder(emphasized ? VoCalTheme.Colors.goldBorder : .clear, lineWidth: 1)
        )
    }
}
