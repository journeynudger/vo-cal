import SwiftUI
import VoCalCore

/// Edit a parsed item's details (amount/unit/fat ratio/state) to fill in what lowered its
/// confidence. On Save it emits refine answers for ONLY the changed fields; the server
/// re-resolves and the result's macros + confidence update — so an edit can push a flagged
/// item to high confidence. The client never invents numbers; it only restates the fields.
struct MealItemEditSheet: View {
    let index: Int
    let item: ParseResultItem
    var onSave: ([RefineAnswer]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var amountText: String
    @State private var unit: FoodUnit?
    @State private var fatRatio: String
    @State private var state: FoodState

    init(index: Int, item: ParseResultItem, onSave: @escaping ([RefineAnswer]) -> Void) {
        self.index = index
        self.item = item
        self.onSave = onSave
        _amountText = State(initialValue: item.amount.map(Self.numberText) ?? "")
        _unit = State(initialValue: item.unit)
        _fatRatio = State(initialValue: item.fatRatio ?? "")
        _state = State(initialValue: item.state)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Amount") {
                    TextField("Amount", text: $amountText)
                        .keyboardType(.decimalPad)
                        .accessibilityIdentifier("edit.amount")
                    Picker("Unit", selection: $unit) {
                        Text("—").tag(FoodUnit?.none)
                        ForEach(FoodUnit.allCases, id: \.self) { unit in
                            Text(unit.rawValue).tag(FoodUnit?.some(unit))
                        }
                    }
                }
                Section("Details") {
                    TextField("Fat ratio (e.g. 93/7)", text: $fatRatio)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("edit.fat-ratio")
                    Picker("State", selection: $state) {
                        ForEach(FoodState.allCases, id: \.self) { value in
                            Text(value.rawValue.capitalized).tag(value)
                        }
                    }
                }
            }
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.accessibilityIdentifier("edit.save")
                }
            }
        }
    }

    private func save() {
        var answers: [RefineAnswer] = []
        let prefix = "items[\(index)]"
        // amount + unit are coupled in the backend's amount field; send them together as one
        // "<amount> <unit>" answer whenever either changed (a bare amount would clear the unit).
        let newAmount = Double(amountText.trimmingCharacters(in: .whitespaces))
        if (newAmount != item.amount || unit != item.unit), let amount = newAmount {
            let value = unit.map { "\(Self.numberText(amount)) \($0.rawValue)" } ?? Self.numberText(amount)
            answers.append(RefineAnswer(field: "\(prefix).amount", value: .string(value)))
        }
        let ratio = fatRatio.trimmingCharacters(in: .whitespaces)
        if ratio != (item.fatRatio ?? ""), !ratio.isEmpty {
            answers.append(RefineAnswer(field: "\(prefix).fat_ratio", value: .string(ratio)))
        }
        if state != item.state {
            answers.append(RefineAnswer(field: "\(prefix).state", value: .string(state.rawValue)))
        }
        dismiss()
        if !answers.isEmpty { onSave(answers) }
    }

    private static func numberText(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}
