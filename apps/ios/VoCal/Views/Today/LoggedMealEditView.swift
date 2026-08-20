import SwiftUI
import VoCalCore

/// Edit or delete an already-logged meal (opened by tapping a Today meal row).
///
/// Tapping an item opens a manual macro editor — the fix for an unknown / 0-cal food: the user
/// "just puts what it actually is", which the server then trusts verbatim (manual = true). The
/// trash glyph removes an item; Save PUTs the meal (the server recomputes totals); Delete
/// soft-deletes it.
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
        ZStack {
            VoCalTheme.Colors.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                switch phase {
                case .loading:
                    Spacer()
                    VoCalLoader(size: 40)
                    Spacer()
                case .failed:
                    failedSurface
                case .ready:
                    content
                }
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
        .task { await load() }
    }

    // MARK: - Chrome

    private var header: some View {
        ZStack {
            Text("Edit meal")
                .font(VoCalTheme.Fonts.screenTitle)
                .foregroundStyle(VoCalTheme.Colors.ink)
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(VoCalTheme.Colors.ink)
                        .frame(width: 36, height: 36)
                        .glassEffect(.regular, in: Circle())
                }
                Spacer()
                Button {
                    Task { await save() }
                } label: {
                    Text("Save")
                        .font(VoCalTheme.Fonts.buttonLabel)
                        .foregroundStyle(
                            saving || items.isEmpty
                                ? VoCalTheme.Colors.muted
                                : VoCalTheme.Colors.gold
                        )
                }
                .disabled(saving || items.isEmpty)
            }
        }
        .padding(.horizontal, VoCalTheme.Spacing.l)
        .padding(.vertical, VoCalTheme.Spacing.m)
    }

    // MARK: - Content

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VoCalTheme.Spacing.l) {
                HStack(alignment: .firstTextBaseline, spacing: VoCalTheme.Spacing.xs) {
                    Text("\(totalKcal)")
                        .font(VoCalTheme.Fonts.numeral(28))
                        .monospacedDigit()
                        .foregroundStyle(VoCalTheme.Colors.ink)
                    Text("cal · \(items.count) item\(items.count == 1 ? "" : "s")")
                        .font(VoCalTheme.Fonts.secondaryLabel)
                        .foregroundStyle(VoCalTheme.Colors.muted)
                }
                .padding(.top, VoCalTheme.Spacing.s)

                VStack(spacing: VoCalTheme.Spacing.m) {
                    ForEach(items.indices, id: \.self) { i in
                        itemCard(i)
                    }
                }
                Text("Tap an item to set its calories.")
                    .font(VoCalTheme.Fonts.formLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
                    .padding(.horizontal, VoCalTheme.Spacing.xs)

                // The fix for one-by-one loggers (beta feedback 2026-08-19): forgot something,
                // or logging a meal in pieces? Speak it INTO this meal instead of minting
                // "Meal N+1" — the old alternative was delete-and-redo the whole meal.
                addByVoiceCard

                deleteCard
            }
            .padding(.horizontal, VoCalTheme.Spacing.l)
            .padding(.bottom, VoCalTheme.Spacing.xxl)
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

    private func itemCard(_ index: Int) -> some View {
        let item = items[index]
        return HStack(spacing: VoCalTheme.Spacing.m) {
            Button {
                editing = EditingItem(index: index)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .font(VoCalTheme.Fonts.primaryLabel)
                            .foregroundStyle(VoCalTheme.Colors.ink)
                        if item.source == .unresolved {
                            // Gold, not red: this is an attention prompt ("finish this one"),
                            // not a failure — and macro colors are semantic-only (DESIGN.md),
                            // so the old `protein` tint here was a token misuse.
                            flag("Couldn't find this. Tap to set calories", VoCalTheme.Colors.gold)
                        } else if item.isEstimate {
                            flag("Estimate. Tap to confirm", VoCalTheme.Colors.gold)
                        } else if item.manual {
                            flag("Edited", VoCalTheme.Colors.muted)
                        }
                    }
                    Spacer()
                    Text("\(Int(item.macros.kcal.rounded())) cal")
                        .font(VoCalTheme.Fonts.secondaryLabel)
                        .foregroundStyle(VoCalTheme.Colors.muted)
                        .monospacedDigit()
                }
            }
            .buttonStyle(.plain)
            Button {
                _ = withAnimation { items.remove(at: index) }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(VoCalTheme.Colors.muted)
            }
            .buttonStyle(.plain)
        }
        .padding(VoCalTheme.Spacing.l)
        .background(
            VoCalTheme.Colors.card,
            in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.card, style: .continuous)
        )
    }

    private var addByVoiceCard: some View {
        Button {
            addingByVoice = true
        } label: {
            HStack(spacing: VoCalTheme.Spacing.m) {
                ZStack {
                    Circle()
                        .fill(VoCalTheme.Colors.gold.opacity(0.16))
                        .frame(width: 36, height: 36)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(VoCalTheme.Colors.gold)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add more by voice")
                        .font(VoCalTheme.Fonts.primaryLabel)
                        .foregroundStyle(VoCalTheme.Colors.ink)
                    Text("Say what to add and it joins this meal.")
                        .font(VoCalTheme.Fonts.formLabel)
                        .foregroundStyle(VoCalTheme.Colors.muted)
                }
                Spacer()
            }
            .padding(VoCalTheme.Spacing.l)
            .background(
                VoCalTheme.Colors.card,
                in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.card, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(A11y.VoiceLog.addToMealButton)
    }

    private var deleteCard: some View {
        Button {
            Task { await deleteMeal() }
        } label: {
            HStack(spacing: VoCalTheme.Spacing.s) {
                Image(systemName: "trash")
                    .font(.system(size: 15, weight: .medium))
                Text("Delete meal")
                    .font(VoCalTheme.Fonts.buttonLabel)
            }
            // Status red (the one non-macro red) — never the system red, never `protein`.
            .foregroundStyle(VoCalTheme.Colors.alert)
            .frame(maxWidth: .infinity)
            .padding(VoCalTheme.Spacing.l)
            .background(
                VoCalTheme.Colors.card,
                in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.card, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(saving)
    }

    private var failedSurface: some View {
        VStack(spacing: VoCalTheme.Spacing.l) {
            Spacer()
            ZStack {
                Circle()
                    .fill(VoCalTheme.Colors.card)
                    .frame(width: 88, height: 88)
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(VoCalTheme.Colors.muted)
            }
            Text("Couldn't load this meal")
                .font(VoCalTheme.Fonts.primaryLabel)
                .foregroundStyle(VoCalTheme.Colors.ink)
            Spacer()
            VoCalButton(title: "Close", kind: .tertiary) { dismiss() }
        }
        .padding(VoCalTheme.Spacing.xl)
    }

    private func flag(_ text: String, _ color: Color) -> some View {
        Text(text).font(VoCalTheme.Fonts.formLabel).foregroundStyle(color)
    }

    // MARK: - Effects

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
        ZStack {
            VoCalTheme.Colors.background.ignoresSafeArea()
            VStack(alignment: .leading, spacing: VoCalTheme.Spacing.l) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).sectionHeader()
                    Text("Set nutrition")
                        .font(VoCalTheme.Fonts.screenTitle)
                        .foregroundStyle(VoCalTheme.Colors.ink)
                }
                .padding(.top, VoCalTheme.Spacing.xl)

                VStack(spacing: VoCalTheme.Spacing.s) {
                    field("Calories", $kcal)
                    field("Protein (g)", $protein)
                    field("Carbs (g)", $carbs)
                    field("Fat (g)", $fat)
                }

                Spacer()

                PillButton(title: "Done") {
                    apply()
                    dismiss()
                }
                VoCalButton(title: "Cancel", kind: .tertiary) { dismiss() }
            }
            .padding(.horizontal, VoCalTheme.Spacing.l)
            .padding(.bottom, VoCalTheme.Spacing.s)
        }
        .onAppear {
            kcal = trimmed(item.macros.kcal)
            protein = trimmed(item.macros.protein)
            carbs = trimmed(item.macros.carbs)
            fat = trimmed(item.macros.fat)
        }
    }

    private func field(_ label: String, _ text: Binding<String>) -> some View {
        HStack {
            Text(label)
                .font(VoCalTheme.Fonts.formLabel)
                .foregroundStyle(VoCalTheme.Colors.muted)
            Spacer()
            TextField("0", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 17, weight: .regular))
                .monospacedDigit()
                .foregroundStyle(VoCalTheme.Colors.ink)
                .frame(width: 90)
        }
        .padding(.horizontal, VoCalTheme.Spacing.l)
        .padding(.vertical, VoCalTheme.Spacing.m)
        .background(
            VoCalTheme.Colors.softFill,
            in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.chip, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: VoCalTheme.Radius.chip, style: .continuous)
                .strokeBorder(VoCalTheme.Colors.goldBorder, lineWidth: 1)
        )
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
