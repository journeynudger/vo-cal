import SwiftUI
import VoCalCore

/// The plan builder (decision 65, D5 a): the meals of a day, chosen by the person from their
/// usuals or typed through the parse, saved as one plan the engine checks against the protocol
/// and reports in one line. Three places show it: after the reveal in meal-plan mode, Settings →
/// My meal plan, and the plan card on Today. The engine never writes a diet; this view arranges
/// the person's own meals, and every number it prints is the server's (AGENTS.md #6). It shows
/// the server's echo, never the tap: a save that did not land says so and keeps the drafts.
struct PlanBuilderView: View {
    enum Presentation {
        /// The onboarding step: a title, "Not now", and `onDone` with the saved plan (nil when
        /// skipped) so the flow can write it again under the signed-in account.
        case onboarding(onDone: (MealPlanUpdate?) -> Void)
        /// A pushed Settings page, or Today's sheet when `onClose` is given (the Done button).
        case page(onClose: (() -> Void)?)
    }

    /// Renders and previews: start from this plan and these usuals instead of loading them.
    struct Preloaded {
        var plan: MealPlan?
        var usuals: [SavedMeal]
    }

    var presentation: Presentation
    var service: any MealPlanService = RuntimeMode.usesMockServices ? MockMealPlanService() : LiveMealPlanService()
    /// The usuals the picker offers; Today's own service, since they are Today's chips.
    var usualsService: any TodayService = RuntimeMode.usesMockServices ? MockTodayService() : LiveTodayService()
    /// Slots to show before any plan exists: the meals per day the person said (spec 6.3).
    var initialSlotCount: Int = 4
    var preloaded: Preloaded? = nil

    /// A day has at most this many planned meals (the server's MAX_SLOTS).
    static let maxSlots = 8

    private enum Phase: Equatable {
        case loading
        case ready
        case failed
    }

    @State private var phase: Phase = .loading
    @State private var slots: [DraftSlot] = []
    @State private var usuals: [SavedMeal] = []
    /// The server's last echo: the plan as stored, with the engine's check.
    @State private var saved: MealPlan?
    /// What the last save sent, so a change since reads as unsaved (the check line stands only
    /// for the plan the engine checked).
    @State private var lastSavedInputs: [PlanSlotInput] = []
    @State private var saving = false
    /// Why the last save did not land; nil when it did.
    @State private var saveError: String?
    /// The slot whose picker is open (its id is what the pick writes back to).
    @State private var picking: DraftSlot?

    var body: some View {
        switch presentation {
        case let .onboarding(onDone):
            onboardingStep(onDone: onDone)
        case let .page(onClose):
            page(onClose: onClose)
        }
    }

    // MARK: - The two frames

    private func onboardingStep(onDone: @escaping (MealPlanUpdate?) -> Void) -> some View {
        OnboardingStepScaffold(progress: nil, onBack: nil) {
            VStack(alignment: .leading, spacing: VoCalTheme.Spacing.m) {
                Text("Your meal plan")
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(VoCalTheme.Colors.ink)
                    .accessibilityAddTraits(.isHeader)
                Text("Type each meal the way you would say it. Logging one later ticks it off.")
                    .font(VoCalTheme.Fonts.body)
                    .foregroundStyle(VoCalTheme.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
        } footer: {
            VStack(spacing: VoCalTheme.Spacing.m) {
                if isSavedAndClean {
                    PillButton(title: "Continue") { onDone(MealPlanUpdate(slots: lastSavedInputs)) }
                        .accessibilityIdentifier(A11y.Plan.save)
                } else {
                    PillButton(title: "Save plan", isEnabled: canSave, isLoading: saving) { save() }
                        .accessibilityIdentifier(A11y.Plan.save)
                    if saved == nil {
                        // Skipping is allowed and remembered as nothing: Today's card says "No
                        // plan yet" and leads here. Never a default plan written for the person.
                        VoCalButton(title: "Not now", kind: .tertiary, isEnabled: !saving) { onDone(nil) }
                            .accessibilityIdentifier(A11y.Plan.skip)
                    }
                }
            }
        }
        .task { await start() }
        .accessibilityIdentifier(A11y.Plan.screen)
        .sheet(item: $picking) { slot in picker(for: slot.id) }
    }

    private func page(onClose: (() -> Void)?) -> some View {
        SettingsPageScaffold(title: "My meal plan") {
            Text("The meals of your day. Logging one ticks it off.")
                .font(VoCalTheme.Fonts.formLabel)
                .foregroundStyle(VoCalTheme.Colors.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, VoCalTheme.Spacing.s)
            content
            if phase == .ready {
                PillButton(title: "Save plan", isEnabled: canSave && !isSavedAndClean, isLoading: saving) { save() }
                    .accessibilityIdentifier(A11y.Plan.save)
                    .padding(.top, VoCalTheme.Spacing.s)
            }
        }
        .toolbar {
            if let onClose {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onClose)
                        .foregroundStyle(VoCalTheme.Colors.ink)
                }
            }
        }
        .task { await start() }
        .accessibilityIdentifier(A11y.Plan.screen)
        .sheet(item: $picking) { slot in picker(for: slot.id) }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            VoCalLoader(size: 40)
                .frame(maxWidth: .infinity)
                .padding(.top, VoCalTheme.Spacing.xxl)
        case .failed:
            VStack(spacing: VoCalTheme.Spacing.l) {
                VStack(spacing: VoCalTheme.Spacing.s) {
                    Text("Couldn't load your plan")
                        .font(VoCalTheme.Fonts.primaryLabel)
                        .foregroundStyle(VoCalTheme.Colors.ink)
                    Text("Check your connection and try again.")
                        .font(VoCalTheme.Fonts.secondaryLabel)
                        .foregroundStyle(VoCalTheme.Colors.muted)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, VoCalTheme.Spacing.xxl)
                PillButton(title: "Try again") {
                    phase = .loading
                    Task { await load() }
                }
                .padding(.horizontal, VoCalTheme.Spacing.xxl)
            }
        case .ready:
            slotsCard
            statusLine
            if let saveError {
                Text(saveError)
                    .font(VoCalTheme.Fonts.formLabel)
                    .foregroundStyle(VoCalTheme.Colors.alert)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, VoCalTheme.Spacing.s)
            }
        }
    }

    private var slotsCard: some View {
        SettingsCard {
            ForEach(Array(slots.enumerated()), id: \.element.id) { index, slot in
                if index > 0 { SettingsDetailDivider() }
                slotRow(slot, index: index)
            }
            if slots.count < Self.maxSlots {
                SettingsDetailDivider()
                addRow
            }
        }
        .disabled(saving)
    }

    /// A filled slot: the meal's name and the server's calories. An empty one: "Choose a meal".
    /// Both open the picker; nothing on the row claims more than the fill.
    private func slotRow(_ slot: DraftSlot, index: Int) -> some View {
        Button {
            picking = slot
        } label: {
            HStack(spacing: VoCalTheme.Spacing.m) {
                if let fill = slot.fill {
                    Text(fill.name)
                        .font(VoCalTheme.Fonts.primaryLabel)
                        .foregroundStyle(VoCalTheme.Colors.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Spacer(minLength: VoCalTheme.Spacing.s)
                    Text("\(DashboardNumber.whole(fill.kcal)) cal")
                        .font(VoCalTheme.Fonts.secondaryLabel)
                        .monospacedDigit()
                        .foregroundStyle(VoCalTheme.Colors.muted)
                } else {
                    Text("Choose a meal")
                        .font(VoCalTheme.Fonts.primaryLabel)
                        .foregroundStyle(VoCalTheme.Colors.muted)
                    Spacer(minLength: VoCalTheme.Spacing.s)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(VoCalTheme.Colors.muted)
            }
            .padding(.horizontal, VoCalTheme.Spacing.l)
            .padding(.vertical, VoCalTheme.Spacing.m)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(A11y.Plan.slotRow(index))
        .accessibilityLabel(slot.fill.map { "\($0.name), \(DashboardNumber.whole($0.kcal)) calories" } ?? "Choose a meal")
    }

    private var addRow: some View {
        Button {
            slots.append(DraftSlot(fill: nil))
            picking = slots.last
        } label: {
            HStack(spacing: VoCalTheme.Spacing.m) {
                Text("Add a meal")
                    .font(VoCalTheme.Fonts.primaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.ink)
                Spacer(minLength: VoCalTheme.Spacing.s)
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(VoCalTheme.Colors.gold)
            }
            .padding(.horizontal, VoCalTheme.Spacing.l)
            .padding(.vertical, VoCalTheme.Spacing.m)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(A11y.Plan.addSlot)
    }

    /// Under the card: the engine's line for the plan as saved, in the completion green when it
    /// lands and in ink otherwise (a plan off the protocol is a fact, never an alert); before a
    /// save, or after a change, the planned calories, which are the server's totals added up.
    @ViewBuilder
    private var statusLine: some View {
        if isSavedAndClean, let saved {
            if let check = saved.check {
                Text(check.line)
                    .font(VoCalTheme.Fonts.secondaryLabel)
                    .foregroundStyle(check.onProtocol ? VoCalTheme.Colors.optimal : VoCalTheme.Colors.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, VoCalTheme.Spacing.s)
                    .accessibilityIdentifier(A11y.Plan.checkLine)
            } else {
                Text("Saved.")
                    .font(VoCalTheme.Fonts.secondaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
                    .padding(.horizontal, VoCalTheme.Spacing.s)
                    .accessibilityIdentifier(A11y.Plan.checkLine)
            }
        } else if plannedKcal > 0 {
            Text("\(DashboardNumber.whole(plannedKcal)) calories planned")
                .font(VoCalTheme.Fonts.secondaryLabel)
                .monospacedDigit()
                .foregroundStyle(VoCalTheme.Colors.muted)
                .padding(.horizontal, VoCalTheme.Spacing.s)
        }
    }

    // MARK: - The picker

    private func picker(for id: DraftSlot.ID) -> some View {
        let filled = slots.first(where: { $0.id == id })?.fill != nil
        return PlanSlotPicker(usuals: usuals, canRemove: filled, service: service) { fill in
            guard let index = slots.firstIndex(where: { $0.id == id }) else { return }
            // A pick fills the slot; a remove clears it. The row stays either way: the count
            // of slots is the person's (the meals they said they eat), not the plan's.
            slots[index].fill = fill
            saveError = nil
        }
    }

    // MARK: - State

    private var currentInputs: [PlanSlotInput] { slots.compactMap(\.input) }
    private var canSave: Bool { !currentInputs.isEmpty && !saving }
    /// The drafts are exactly what the server last stored.
    private var isSavedAndClean: Bool { saved != nil && currentInputs == lastSavedInputs }
    private var plannedKcal: Double { slots.reduce(0) { $0 + ($1.fill?.kcal ?? 0) } }

    private func start() async {
        if let preloaded {
            usuals = preloaded.usuals
            apply(preloaded.plan)
            phase = .ready
            return
        }
        await load()
    }

    private func load() async {
        do {
            let plan = try await service.plan()
            // The usuals are a shortcut: a failed list is an empty picker, never a failed page.
            usuals = (try? await usualsService.usuals()) ?? []
            apply(plan)
            phase = .ready
        } catch {
            phase = .failed
        }
    }

    private func apply(_ plan: MealPlan?) {
        saved = plan
        if let plan, !plan.slots.isEmpty {
            slots = plan.slots.map { DraftSlot(fill: .saved($0)) }
        } else {
            slots = (0..<max(1, min(initialSlotCount, Self.maxSlots))).map { _ in DraftSlot(fill: nil) }
        }
        lastSavedInputs = slots.compactMap(\.input)
    }

    private func save() {
        let inputs = currentInputs
        guard !inputs.isEmpty else { return }
        saving = true
        saveError = nil
        Task {
            do {
                let plan = try await service.save(MealPlanUpdate(slots: inputs))
                saved = plan
                // The echo replaces the drafts: the names and calories are now the server's.
                slots = plan.slots.map { DraftSlot(fill: .saved($0)) }
                lastSavedInputs = slots.compactMap(\.input)
                VoCalHaptics.select()
            } catch {
                saveError = Self.saveFailureMessage(for: error)
            }
            saving = false
        }
    }

    /// Honest failure copy (TodayViewModel.logFailureMessage's rule): only a transport error
    /// blames the connection; a 404 is the one rejection the person can act on.
    static func saveFailureMessage(for error: Error) -> String {
        let connection = "That didn't reach the server. Check your connection and try again."
        if let apiError = error as? APIError {
            switch apiError {
            case .transport:
                return connection
            case let .status(code, _):
                if code == 404 { return "One of these meals is no longer among your usuals. Choose it again." }
                return "The server couldn't save the plan (error \(code)). Please try again in a moment."
            case .badURL, .decoding:
                break
            }
        }
        if error is URLError { return connection }
        return "The plan didn't save. Please try again in a moment."
    }
}

/// One slot while the plan is built: empty, the person's pick before the server stored it, or a
/// slot of the saved plan as the server returned it.
struct DraftSlot: Identifiable, Equatable {
    let id = UUID()
    var fill: Fill?

    enum Fill: Equatable {
        case usual(SavedMeal)
        /// A typed meal: what was typed (the row's label until the server names it), the parse's
        /// items as the plan sends them, and the parse's totals for the planned-calories line.
        case typed(text: String, items: [ConfirmedItem], totals: NutrientProfile)
        case saved(PlanSlot)

        var name: String {
            switch self {
            case let .usual(usual): usual.name
            case let .typed(text, _, _): text.prefix(1).uppercased() + text.dropFirst()
            case let .saved(slot): slot.name
            }
        }

        var kcal: Double {
            switch self {
            case let .usual(usual): usual.totals.kcal
            case let .typed(_, _, totals): totals.kcal
            case let .saved(slot): slot.totals.kcal
            }
        }
    }

    /// What `PUT /meals/plan` gets for this slot. A fresh typed slot sends no name, so the server
    /// names it from the items the way it names a typed log (the tick matches by name); a saved
    /// slot sends the server's own name back with its usual or its items.
    var input: PlanSlotInput? {
        switch fill {
        case nil:
            return nil
        case let .usual(usual)?:
            return PlanSlotInput(usualId: usual.id)
        case let .typed(_, items, _)?:
            return items.isEmpty ? nil : PlanSlotInput(items: items)
        case let .saved(slot)?:
            if let usualId = slot.usualId { return PlanSlotInput(name: slot.name, usualId: usualId) }
            return slot.items.isEmpty ? nil : PlanSlotInput(name: slot.name, items: slot.items)
        }
    }
}

/// The picker for one slot: the person's usuals, or a meal typed the way they would say it and
/// parsed by the server (the same parse a typed log takes). "Remove this meal" clears a filled
/// slot. Nothing is preselected; the sheet closes on the pick.
private struct PlanSlotPicker: View {
    let usuals: [SavedMeal]
    let canRemove: Bool
    let service: any MealPlanService
    /// The pick, or nil to clear the slot.
    let onPick: (DraftSlot.Fill?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var parsing = false
    @State private var parseError: String?
    @FocusState private var typing: Bool

    init(usuals: [SavedMeal], canRemove: Bool, service: any MealPlanService, onPick: @escaping (DraftSlot.Fill?) -> Void) {
        self.usuals = usuals
        self.canRemove = canRemove
        self.service = service
        self.onPick = onPick
    }

    var body: some View {
        NavigationStack {
            ZStack {
                VoCalTheme.Colors.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: VoCalTheme.Spacing.l) {
                        if !usuals.isEmpty {
                            SettingsSectionLabel(title: "Your usuals")
                            SettingsCard {
                                ForEach(Array(usuals.enumerated()), id: \.element.id) { index, usual in
                                    if index > 0 { SettingsDetailDivider() }
                                    usualRow(usual)
                                }
                            }
                        }
                        SettingsSectionLabel(title: usuals.isEmpty ? "Type a meal" : "Or type a meal")
                        SettingsCard {
                            HStack(spacing: VoCalTheme.Spacing.m) {
                                TextField("Two eggs on toast and a coffee", text: $text)
                                    .font(VoCalTheme.Fonts.primaryLabel)
                                    .foregroundStyle(VoCalTheme.Colors.ink)
                                    .textInputAutocapitalization(.never)
                                    .submitLabel(.done)
                                    .focused($typing)
                                    .onSubmit { add() }
                                    .disabled(parsing)
                                    .accessibilityIdentifier(A11y.Plan.typedField)
                                if parsing {
                                    VoCalLoader(size: 20)
                                } else {
                                    Button("Add") { add() }
                                        .font(VoCalTheme.Fonts.buttonLabel)
                                        .foregroundStyle(canAdd ? VoCalTheme.Colors.ink : VoCalTheme.Colors.muted)
                                        .disabled(!canAdd)
                                        .accessibilityIdentifier(A11y.Plan.typedAdd)
                                }
                            }
                            .padding(.horizontal, VoCalTheme.Spacing.l)
                            .padding(.vertical, VoCalTheme.Spacing.m)
                        }
                        if usuals.isEmpty {
                            Text("Meals you save as usuals will be offered here.")
                                .font(VoCalTheme.Fonts.formLabel)
                                .foregroundStyle(VoCalTheme.Colors.muted)
                                .padding(.horizontal, VoCalTheme.Spacing.s)
                        }
                        if let parseError {
                            Text(parseError)
                                .font(VoCalTheme.Fonts.formLabel)
                                .foregroundStyle(VoCalTheme.Colors.alert)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, VoCalTheme.Spacing.s)
                        }
                        if canRemove {
                            VoCalButton(title: "Remove this meal", kind: .tertiary, isEnabled: !parsing) {
                                onPick(nil)
                                dismiss()
                            }
                            .accessibilityIdentifier(A11y.Plan.removeMeal)
                            .padding(.top, VoCalTheme.Spacing.s)
                        }
                    }
                    .padding(.horizontal, VoCalTheme.Spacing.l)
                    .padding(.top, VoCalTheme.Spacing.s)
                    .padding(.bottom, VoCalTheme.Spacing.xxl)
                }
            }
            .navigationTitle("Choose a meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(VoCalTheme.Colors.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(VoCalTheme.Colors.ink)
                        .disabled(parsing)
                }
            }
        }
        .onAppear { if usuals.isEmpty { typing = true } }
    }

    private func usualRow(_ usual: SavedMeal) -> some View {
        Button {
            onPick(.usual(usual))
            dismiss()
        } label: {
            HStack(spacing: VoCalTheme.Spacing.m) {
                Text(usual.name)
                    .font(VoCalTheme.Fonts.primaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.ink)
                    .lineLimit(1)
                Spacer(minLength: VoCalTheme.Spacing.s)
                Text("\(DashboardNumber.whole(usual.kcal)) cal")
                    .font(VoCalTheme.Fonts.secondaryLabel)
                    .monospacedDigit()
                    .foregroundStyle(VoCalTheme.Colors.muted)
            }
            .padding(.horizontal, VoCalTheme.Spacing.l)
            .padding(.vertical, VoCalTheme.Spacing.m)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(parsing)
        .accessibilityIdentifier(A11y.Plan.usualOption)
        .accessibilityLabel("\(usual.name), \(DashboardNumber.whole(usual.kcal)) calories")
    }

    private var canAdd: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !parsing
    }

    /// Parse the typed meal; the pick carries the parse's items so the server re-prices them
    /// when the plan is saved. The sheet closes only on a parse that came back.
    private func add() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !parsing else { return }
        parsing = true
        parseError = nil
        Task {
            do {
                let result = try await service.parseTyped(trimmed)
                let items = result.items.map(ConfirmedItem.init(from:))
                guard !items.isEmpty else {
                    parseError = "No food was recognized in that. Try naming what you would eat."
                    parsing = false
                    return
                }
                onPick(.typed(text: trimmed, items: items, totals: result.totals))
                parsing = false
                dismiss()
            } catch {
                parseError = Self.parseFailureMessage(for: error)
                parsing = false
            }
        }
    }

    static func parseFailureMessage(for error: Error) -> String {
        let connection = "That didn't reach the server. Check your connection and try again."
        if let apiError = error as? APIError {
            switch apiError {
            case .transport:
                return connection
            case let .status(code, _):
                return "The server couldn't read that meal (error \(code)). Try other words."
            case .badURL, .decoding:
                break
            }
        }
        if error is URLError { return connection }
        return "That meal didn't parse. Please try again in a moment."
    }
}

#Preview("Settings page") {
    NavigationStack {
        PlanBuilderView(
            presentation: .page(onClose: nil),
            preloaded: PlanBuilderView.Preloaded(plan: MockMealPlanService.canned, usuals: [])
        )
    }
}

#Preview("Onboarding step") {
    PlanBuilderView(presentation: .onboarding(onDone: { _ in }), initialSlotCount: 3, preloaded: PlanBuilderView.Preloaded(plan: nil, usuals: []))
}
