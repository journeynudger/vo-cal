import PhotosUI
import SwiftUI
import VoCalCore

/// "Build it for me" (decision 73; Francesco, 2026-10-12): three steps in his words, then a draft
/// the server built from them. How the day looks (meals, snacks between them, a dessert after
/// dinner); which foods to include (from what the person logs, typed, or read off a grocery
/// receipt); whether the plan may add foods they did not name. The server drafts the day with
/// deterministic code against the protocol and prices it on the confirm path; nothing is stored
/// here. The draft goes back to the builder, where the person changes what they like and saves.
struct PlanGeneratorView: View {
    var service: any MealPlanService
    /// The meals per day the person told the intake; the first step starts there.
    var initialMeals: Int = 3
    /// The draft, once the server answered; the sheet closes after it.
    var onDraft: (GeneratedPlan) -> Void
    /// Renders and previews: start on this step with these answers (a sheet cannot be driven).
    struct Preloaded {
        var step = 0
        var snacks = 0
        var dessert = false
        var chosen: [String] = []
        var suggestions: [String] = []
        var mayAdd = ""
    }

    private let preloaded: Preloaded?

    @Environment(\.dismiss) private var dismiss

    private enum Step: Int, CaseIterable {
        case day, foods, additions
    }

    @State private var step: Step = .day
    @State private var meals: Int
    @State private var snacks = 0
    @State private var dessert = false
    @State private var chosen: [String] = []
    @State private var suggestions: [String] = []
    @State private var typed = ""
    /// "yes" or "no"; empty until the person answers (nothing is preselected).
    @State private var mayAdd = ""
    @State private var reading = false
    @State private var readNotice: String?
    @State private var building = false
    @State private var buildError: String?
    @State private var receiptItem: PhotosPickerItem?
    @State private var showCamera = false

    init(
        service: any MealPlanService,
        initialMeals: Int = 3,
        preloaded: Preloaded? = nil,
        onDraft: @escaping (GeneratedPlan) -> Void
    ) {
        self.service = service
        self.initialMeals = initialMeals
        self.onDraft = onDraft
        self.preloaded = preloaded
        _meals = State(initialValue: min(max(initialMeals, 2), 5))
        if let preloaded {
            _step = State(initialValue: Step(rawValue: preloaded.step) ?? .day)
            _snacks = State(initialValue: preloaded.snacks)
            _dessert = State(initialValue: preloaded.dessert)
            _chosen = State(initialValue: preloaded.chosen)
            _suggestions = State(initialValue: preloaded.suggestions)
            _mayAdd = State(initialValue: preloaded.mayAdd)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: VoCalTheme.Spacing.l) {
                        header
                        switch step {
                        case .day: dayStep
                        case .foods: foodsStep
                        case .additions: additionsStep
                        }
                    }
                    .padding(.horizontal, VoCalTheme.Spacing.l)
                    .padding(.bottom, VoCalTheme.Spacing.xl)
                }
                footer
            }
            .background(VoCalTheme.Colors.background.ignoresSafeArea())
            .navigationTitle("Build my plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(VoCalTheme.Colors.ink)
                }
            }
        }
        .task { if preloaded == nil { await loadSuggestions() } }
        .onChange(of: receiptItem) { _, item in
            guard let item else { return }
            Task { await readPicked(item) }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CaptureCameraView { data in
                Task { await read(data) }
            }
        }
        .accessibilityIdentifier(A11y.Plan.generatorScreen)
    }

    // MARK: - The three steps

    private var header: some View {
        VStack(alignment: .leading, spacing: VoCalTheme.Spacing.xs) {
            Text("Step \(step.rawValue + 1) of \(Step.allCases.count)").sectionHeader()
            Text(title)
                .font(.system(size: 27, weight: .semibold))
                .foregroundStyle(VoCalTheme.Colors.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle)
                    .font(VoCalTheme.Fonts.body)
                    .foregroundStyle(VoCalTheme.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, VoCalTheme.Spacing.l)
    }

    private var title: String {
        switch step {
        case .day: "How do you want your day to look?"
        case .foods: "What foods should it include?"
        case .additions: "Can the plan add foods you didn't name?"
        }
    }

    private var subtitle: String? {
        switch step {
        case .day: "Meals, snacks between them, and a dessert if you like one."
        case .foods: "Choose from what you eat, add your own, or scan a grocery receipt."
        case .additions: nil
        }
    }

    private var dayStep: some View {
        SettingsCard {
            VStack(spacing: 0) {
                HStack {
                    Text("Meals")
                        .font(VoCalTheme.Fonts.primaryLabel)
                        .foregroundStyle(VoCalTheme.Colors.ink)
                    Spacer()
                    countControl
                }
                .padding(VoCalTheme.Spacing.l)
                SettingsDetailDivider()
                VStack(alignment: .leading, spacing: VoCalTheme.Spacing.s) {
                    Text("Snacks between meals")
                        .font(VoCalTheme.Fonts.primaryLabel)
                        .foregroundStyle(VoCalTheme.Colors.ink)
                    Picker("Snacks between meals", selection: $snacks) {
                        Text("None").tag(0)
                        Text("One").tag(1)
                        Text("Two").tag(2)
                    }
                    .pickerStyle(.segmented)
                }
                .padding(VoCalTheme.Spacing.l)
                SettingsDetailDivider()
                Toggle(isOn: $dessert) {
                    Text("A dessert after dinner")
                        .font(VoCalTheme.Fonts.primaryLabel)
                        .foregroundStyle(VoCalTheme.Colors.ink)
                }
                .tint(VoCalTheme.Colors.gold)
                .padding(VoCalTheme.Spacing.l)
            }
        }
    }

    private var countControl: some View {
        HStack(spacing: VoCalTheme.Spacing.m) {
            stepButton("minus", enabled: meals > 2) { meals -= 1 }
            Text("\(meals)")
                .font(VoCalTheme.Fonts.primaryLabel)
                .monospacedDigit()
                .foregroundStyle(VoCalTheme.Colors.ink)
                .frame(minWidth: 20)
            stepButton("plus", enabled: meals < 5) { meals += 1 }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Meals")
        .accessibilityValue("\(meals)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: if meals < 5 { meals += 1 }
            case .decrement: if meals > 2 { meals -= 1 }
            @unknown default: break
            }
        }
    }

    private func stepButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(enabled ? VoCalTheme.Colors.ink : VoCalTheme.Colors.muted)
                .frame(width: 44, height: 44)
                .background(VoCalTheme.Colors.softFill, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private var foodsStep: some View {
        VStack(alignment: .leading, spacing: VoCalTheme.Spacing.l) {
            if !chosen.isEmpty {
                FlexibleChipLayout(spacing: VoCalTheme.Spacing.s) {
                    ForEach(chosen, id: \.self) { food in
                        Button {
                            chosen.removeAll { $0 == food }
                        } label: {
                            HStack(spacing: VoCalTheme.Spacing.xs) {
                                Text(food)
                                Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                            }
                            .font(VoCalTheme.Fonts.chipLabel.weight(.semibold))
                            .foregroundStyle(VoCalTheme.Colors.onCta)
                            .padding(.horizontal, VoCalTheme.Spacing.l)
                            .frame(minHeight: 44)
                            .background(VoCalTheme.Colors.cta, in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.chip, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(food)")
                    }
                }
            }

            HStack(spacing: VoCalTheme.Spacing.s) {
                TextField("Add a food, like salmon or oats", text: $typed)
                    .font(VoCalTheme.Fonts.primaryLabel)
                    .submitLabel(.done)
                    .onSubmit(addTyped)
                    .padding(VoCalTheme.Spacing.m)
                    .background(VoCalTheme.Colors.card, in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.chip, style: .continuous))
                    .accessibilityIdentifier(A11y.Plan.foodField)
                Button("Add", action: addTyped)
                    .font(VoCalTheme.Fonts.primaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.ink)
                    .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            HStack(spacing: VoCalTheme.Spacing.s) {
                Button {
                    showCamera = true
                } label: {
                    Self.receiptLabel("Scan a receipt", symbol: "doc.text.viewfinder")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(A11y.Plan.receiptScan)
                PhotosPicker(selection: $receiptItem, matching: .images) {
                    Self.receiptLabel("Receipt photo", symbol: "photo")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(A11y.Plan.receiptLibrary)
            }
            .disabled(reading)

            if reading {
                HStack(spacing: VoCalTheme.Spacing.s) {
                    ProgressView()
                    Text("Reading your receipt")
                        .font(VoCalTheme.Fonts.formLabel)
                        .foregroundStyle(VoCalTheme.Colors.muted)
                }
            } else if let readNotice {
                Text(readNotice)
                    .font(VoCalTheme.Fonts.formLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            let offered = suggestions.filter { food in !chosen.contains { $0.caseInsensitiveCompare(food) == .orderedSame } }
            if !offered.isEmpty {
                VStack(alignment: .leading, spacing: VoCalTheme.Spacing.s) {
                    Text("From what you log").sectionHeader()
                    FlowChips(options: offered) { food in add([food]) }
                }
            }
        }
    }

    /// Nonisolated: PhotosPicker builds its label outside the main actor (CaptureCameraKit's
    /// `pillLabel` met the same rule).
    private nonisolated static func receiptLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: VoCalTheme.Spacing.s) {
            Image(systemName: symbol)
            Text(title)
        }
        .font(VoCalTheme.Fonts.chipLabel.weight(.semibold))
        .foregroundStyle(VoCalTheme.Colors.ink)
        .padding(.horizontal, VoCalTheme.Spacing.l)
        .frame(minHeight: 44)
        .background(VoCalTheme.Colors.card, in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.chip, style: .continuous))
    }

    private var additionsStep: some View {
        VStack(alignment: .leading, spacing: VoCalTheme.Spacing.m) {
            ChoiceList(
                options: [
                    (value: "yes", label: "Yes, fill the gaps", sub: "It can add a protein, a vegetable or a fat so the day lands on your plan."),
                    (value: "no", label: "Only my foods", sub: "It uses what you named, even if the day lands short."),
                ],
                selection: $mayAdd
            )
            if chosen.isEmpty, mayAdd == "no" {
                Text("Name a few foods first, or let the plan add some.")
                    .font(VoCalTheme.Fonts.formLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
            }
            if let buildError {
                Text(buildError)
                    .font(VoCalTheme.Fonts.formLabel)
                    .foregroundStyle(VoCalTheme.Colors.alert)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: VoCalTheme.Spacing.m) {
            if step != .day {
                VoCalButton(title: "Back", kind: .tertiary, isEnabled: !building) {
                    step = Step(rawValue: step.rawValue - 1) ?? .day
                }
            }
            if step == .additions {
                PillButton(title: "Build my plan", isEnabled: canBuild, isLoading: building) { build() }
                    .accessibilityIdentifier(A11y.Plan.generatorBuild)
            } else {
                PillButton(title: "Next", isEnabled: !reading) {
                    if step == .foods { addTyped() }
                    step = Step(rawValue: step.rawValue + 1) ?? .additions
                }
                .accessibilityIdentifier(A11y.Plan.generatorNext)
            }
        }
        .padding(VoCalTheme.Spacing.l)
    }

    private var canBuild: Bool {
        !building && !mayAdd.isEmpty && (mayAdd == "yes" || !chosen.isEmpty)
    }

    // MARK: - Work

    private func addTyped() {
        let parts = typed.split(whereSeparator: { $0 == "," || $0 == "\n" }).map(String.init)
        add(parts)
        typed = ""
    }

    private func add(_ foods: [String]) {
        for raw in foods {
            let food = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !food.isEmpty, chosen.count < 40 else { continue }
            if !chosen.contains(where: { $0.caseInsensitiveCompare(food) == .orderedSame }) {
                chosen.append(food)
            }
        }
    }

    private func loadSuggestions() async {
        // A shortcut, never a gate: a failed list is no chips.
        suggestions = (try? await service.foodSuggestions()) ?? []
    }

    private func readPicked(_ item: PhotosPickerItem) async {
        defer { receiptItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            readNotice = "That photo couldn't be opened. Try another."
            return
        }
        await read(data)
    }

    private func read(_ data: Data) async {
        reading = true
        readNotice = nil
        let jpeg = await CapturePhotoEncoding.uploadJPEG(from: data)
        do {
            let foods = try await service.readReceipt(jpeg)
            let before = chosen.count
            add(foods)
            let found = chosen.count - before
            readNotice = found == 0
                ? "Everything on that receipt is already here."
                : "Added \(found == 1 ? "one food" : "\(found) foods") from your receipt. Remove any you won't eat."
        } catch {
            readNotice = "Couldn't read that receipt. Try a sharper photo, or add foods by hand."
        }
        reading = false
    }

    private func build() {
        building = true
        buildError = nil
        let request = GeneratePlanRequest(
            meals: meals, snacks: snacks, dessert: dessert, foods: chosen, mayAdd: mayAdd == "yes"
        )
        Task {
            do {
                let draft = try await service.generate(request)
                VoCalHaptics.select()
                onDraft(draft)
                dismiss()
            } catch let APIError.status(code, _) where code == 422 {
                buildError = "The plan needs a protocol and a few foods. Finish your setup, or let the plan add some."
            } catch {
                buildError = "Couldn't build the plan. Check your connection and try again."
            }
            building = false
        }
    }
}
