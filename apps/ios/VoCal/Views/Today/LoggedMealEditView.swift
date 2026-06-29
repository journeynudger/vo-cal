import SwiftUI
import VoCalCore

/// Edit or delete an already-logged meal (opened by tapping a Today meal row).
///
/// Tapping an item opens a manual macro editor — the fix for an unknown / 0-cal food: the user
/// "just puts what it actually is", which the server then trusts verbatim (manual = true). Swipe
/// removes an item; Save PUTs the meal (the server recomputes totals); Delete soft-deletes it.
struct LoggedMealEditView: View {
    let mealID: String
    let model: TodayViewModel
    var onChange: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var name: String?
    @State private var items: [ConfirmedItem] = []
    @State private var phase: Phase = .loading
    @State private var editing: EditingItem?
    @State private var saving = false

    private enum Phase: Equatable { case loading, ready, failed }
    private struct EditingItem: Identifiable { let index: Int; var id: Int { index } }

    private var totalKcal: Int { Int(items.reduce(0) { $0 + $1.macros.kcal }.rounded()) }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loading:
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed:
                    ContentUnavailableView("Couldn't load this meal", systemImage: "exclamationmark.triangle")
                case .ready:
                    content
                }
            }
            .navigationTitle("Edit meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(saving || items.isEmpty)
                }
            }
            .sheet(item: $editing) { target in
                ItemMacroEditor(item: $items[target.index]).presentationDetents([.medium])
            }
        }
        .task { await load() }
    }

    private var content: some View {
        List {
            Section {
                ForEach(items.indices, id: \.self) { i in
                    Button { editing = EditingItem(index: i) } label: { itemRow(items[i]) }
                        .buttonStyle(.plain)
                }
                .onDelete { items.remove(atOffsets: $0) }
            } header: {
                Text("\(totalKcal) cal · \(items.count) item\(items.count == 1 ? "" : "s")")
            } footer: {
                Text("Tap an item to set its calories. Swipe to remove.")
            }
            Section {
                Button(role: .destructive) {
                    Task { await model.deleteMeal(mealID); onChange(); dismiss() }
                } label: {
                    Label("Delete meal", systemImage: "trash")
                }
            }
        }
    }

    private func itemRow(_ item: ConfirmedItem) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).foregroundStyle(VoCalTheme.Colors.ink)
                if item.source == .unresolved {
                    flag("Couldn't find this — tap to set calories", VoCalTheme.Colors.protein)
                } else if item.isEstimate {
                    flag("Estimate — tap to confirm", VoCalTheme.Colors.gold)
                } else if item.manual {
                    flag("Edited", VoCalTheme.Colors.muted)
                }
            }
            Spacer()
            Text("\(Int(item.macros.kcal.rounded())) cal")
                .foregroundStyle(VoCalTheme.Colors.muted)
                .monospacedDigit()
        }
    }

    private func flag(_ text: String, _ color: Color) -> some View {
        Text(text).font(VoCalTheme.Fonts.formLabel).foregroundStyle(color)
    }

    private func load() async {
        do {
            let meal = try await model.loadMeal(mealID)
            name = meal.name
            items = meal.items
            phase = .ready
        } catch {
            phase = .failed
        }
    }

    private func save() async {
        saving = true
        try? await model.saveMeal(mealID, name: name, items: items)
        saving = false
        onChange()
        dismiss()
    }
}

/// Manual macro entry — sets an item's calories/macros and marks it `manual`, so the server
/// trusts the user's own numbers instead of re-resolving (fixes an unknown / 0-cal food).
private struct ItemMacroEditor: View {
    @Binding var item: ConfirmedItem
    @Environment(\.dismiss) private var dismiss

    @State private var kcal = ""
    @State private var protein = ""
    @State private var carbs = ""
    @State private var fat = ""

    var body: some View {
        NavigationStack {
            Form {
                Section(item.name) {
                    field("Calories", $kcal)
                    field("Protein (g)", $protein)
                    field("Carbs (g)", $carbs)
                    field("Fat (g)", $fat)
                }
            }
            .navigationTitle("Set nutrition")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { apply(); dismiss() } }
            }
            .onAppear {
                kcal = trimmed(item.macros.kcal)
                protein = trimmed(item.macros.protein)
                carbs = trimmed(item.macros.carbs)
                fat = trimmed(item.macros.fat)
            }
        }
    }

    private func field(_ label: String, _ text: Binding<String>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("0", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 90)
        }
    }

    private func apply() {
        item.macros = NutrientProfile(
            kcal: Double(kcal) ?? 0,
            protein: Double(protein) ?? 0,
            carbs: Double(carbs) ?? 0,
            fat: Double(fat) ?? 0,
            fiber: item.macros.fiber
        )
        item.manual = true
        item.confidence = 1.0
    }

    private func trimmed(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(v) }
}
