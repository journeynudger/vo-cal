import SwiftUI
import VoCalCore

/// Edit or delete an already-logged meal (opened by tapping a Today meal row).
///
/// Tapping an item opens a manual macro editor — the fix for an unknown / 0-cal food: the user
/// "just puts what it actually is", which the server then trusts verbatim (manual = true). Swipe
/// removes an item; Save PUTs the meal (the server recomputes totals); Delete soft-deletes it.
struct LoggedMealEditView: View {
    let mealID: String
    /// What the Today list calls this meal ("Meal 2", or its given name) — drives the
    /// add-by-voice flow's header and receipt so the user knows exactly what they're
    /// adding to. Falls back to "this meal" when opened without one.
    var displayName: String = "this meal"
    let model: TodayViewModel
    var onChange: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var name: String?
    @State private var items: [ConfirmedItem] = []
    @State private var phase: Phase = .loading
    @State private var editing: EditingItem?
    /// The meal's own day, loaded with it: an append's detected water must land on the
    /// meal's day, not on "today" (the meal may be a backdated log).
    @State private var mealDay: Date = .now
    @State private var addingByVoice = false
    @State private var saving = false
    /// A failed save/delete keeps the sheet OPEN with this message — dismissing on failure
    /// read as success and silently lost the user's manual corrections (field-class bug:
    /// a false "Saved" claim violates the claim ladder, MUST-NOT #6).
    @State private var actionError: String?

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
            .alert("Couldn't save", isPresented: .init(
                get: { actionError != nil }, set: { if !$0 { actionError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(actionError ?? "")
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
                // The fix for one-by-one loggers (beta feedback 2026-08-19): forgot something,
                // or logging a meal in pieces? Speak it INTO this meal instead of minting
                // "Meal N+1" — the old alternative was delete-and-redo the whole meal.
                Button { addingByVoice = true } label: {
                    Label("Add more by voice", systemImage: "mic.fill")
                        .foregroundStyle(VoCalTheme.Colors.ink)
                }
                .accessibilityIdentifier(A11y.VoiceLog.addToMealButton)
            } footer: {
                Text("Say what to add and it joins this meal.")
            }
            Section {
                Button(role: .destructive) {
                    Task { await deleteMeal() }
                } label: {
                    Label("Delete meal", systemImage: "trash")
                }
            }
        }
        .fullScreenCover(isPresented: $addingByVoice) {
            VoiceLogView(
                targetDate: mealDay,
                appendTarget: .init(mealID: mealID, displayName: displayName),
                autoStart: true,
                onLogged: {
                    // The server row changed under us — reload this sheet's items and the
                    // dashboard totals (same beat as save/delete).
                    onChange()
                    Task {
                        await load()
                        await model.load()
                    }
                }
            )
        }
    }

    private func itemRow(_ item: ConfirmedItem) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).foregroundStyle(VoCalTheme.Colors.ink)
                if item.source == .unresolved {
                    flag("Couldn't find this. Tap to set calories", VoCalTheme.Colors.protein)
                } else if item.isEstimate {
                    flag("Estimate. Tap to confirm", VoCalTheme.Colors.gold)
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
            mealDay = meal.loggedAt
            phase = .ready
        } catch {
            phase = .failed
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            try await model.saveMeal(mealID, name: name, items: items)
            onChange()
            dismiss()
        } catch {
            actionError = "Your changes weren't saved. Check your connection and try again."
        }
    }

    private func deleteMeal() async {
        saving = true
        defer { saving = false }
        do {
            try await model.deleteMeal(mealID)
            onChange()
            dismiss()
        } catch {
            actionError = "The meal wasn't deleted. Check your connection and try again."
        }
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
