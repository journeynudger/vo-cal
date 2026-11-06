import PhotosUI
import SwiftUI
import VoCalCore

/// The one chat (decision 75, 2026-11-06): the thread of turns, the capture bar as its mouth,
/// the voice capture over it when the mic is tapped. A turn is one of the things the capture
/// sheet already drew: the person's words, the parsed meal as a card with Log and Edit, the
/// receipt once the row landed, the bar's answer with its Undo, or the honest failure with
/// Try again. Nothing here speaks for itself: every line is the server's or the catalog's,
/// and every claim is the model's state (MUST-NOT #6).
struct ChatView: View {
    @Bindable var model: ChatThreadModel
    var printsNumbers = true
    var saveAsUsualDefault = false
    var photoHint = false
    var onClose: () -> Void = {}
    /// A pointer from an answer (decision 71): the shell opens the surface named.
    var onOpen: (AssistPointer.Surface) -> Void = { _ in }
    var barcode: any BarcodeService = RuntimeMode.usesMockServices ? MockBarcodeService.shared : LiveBarcodeService(api: APIClient())
    var personalFoods: any PersonalFoodsService = RuntimeMode.usesMockServices ? MockPersonalFoodsService.shared : LivePersonalFoodsService(api: APIClient())

    @State private var composer = CaptureComposerModel()
    @State private var search = CaptureSearchModel(provider: ServiceCaptureSearchProvider())
    @State private var menuOpen = false
    @State private var cameraPresented = false
    @State private var libraryPresented = false
    @State private var librarySelection: PhotosPickerItem?
    @State private var editingResult = false
    @State private var saveAsUsual: Bool?
    /// The scanner over the chat, what it found, and why a scan came to nothing.
    @State private var scanning = false
    @State private var scannedFood: BarcodeFood?
    @State private var isLoggingScanned = false
    @State private var scanError: String?

    private static let bottomAnchor = "chat.bottom"

    var body: some View {
        ZStack {
            VoCalTheme.Colors.background.ignoresSafeArea()
            if model.turns.isEmpty, model.current == nil {
                WashBackground()
            }
            thread
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(A11y.Chat.screen)
        .overlay { catchers }
        .safeAreaInset(edge: .bottom) {
            CaptureBar(
                composer: composer,
                search: search,
                menuOpen: $menuOpen,
                onVoice: { model.speak() },
                onSend: { submission in
                    switch submission {
                    case let .text(text): model.send(text)
                    case let .photo(data, note): model.sendPhoto(data, note: note)
                    }
                },
                onPickHit: { hit in model.send(hit.name) },
                onCamera: { cameraPresented = true },
                onLibrary: { libraryPresented = true },
                onScan: { scanning = true },
                photoHint: photoHint
            )
        }
        .overlay(alignment: .top) { topBar }
        .fullScreenCover(isPresented: $cameraPresented) {
            CaptureCameraView { data in
                Task { composer.stagedPhoto = await StagedPhoto.prepare(data) }
            }
        }
        .photosPicker(isPresented: $libraryPresented, selection: $librarySelection, matching: .images)
        .onChange(of: librarySelection) { _, item in
            guard let item else { return }
            librarySelection = nil
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else {
                    composer.notice = "That photo did not load. Try another one."
                    return
                }
                composer.stagedPhoto = await StagedPhoto.prepare(data)
            }
        }
        .fullScreenCover(isPresented: $model.presentsVoice, onDismiss: { model.absorbVoice() }) {
            if let current = model.current {
                VoiceLogView(autoStart: true, model: current, saveAsUsualDefault: saveAsUsualDefault, onOpen: { surface in onOpen(surface) }, keepsOutcomeOnClose: true)
            }
        }
        .sheet(isPresented: $editingResult) {
            if let current = model.current {
                VoiceLogView(model: current, saveAsUsualDefault: saveAsUsualDefault, onOpen: { surface in onOpen(surface) }, keepsOutcomeOnClose: true)
            }
        }
        .fullScreenCover(isPresented: $scanning) {
            BarcodeScannerView(
                onFound: { code in
                    scanning = false
                    Task { await lookUp(code) }
                },
                onClose: { scanning = false }
            )
        }
        .sheet(item: $scannedFood) { food in
            ScannedFoodSheet(
                food: food,
                printsNumbers: printsNumbers,
                onLog: { servings in
                    Task {
                        isLoggingScanned = true
                        scannedFood = nil
                        await model.logScanned(food, servings: servings, personalFoods: personalFoods)
                        isLoggingScanned = false
                    }
                },
                onClose: { scannedFood = nil },
                isLogging: isLoggingScanned
            )
            .presentationDetents([.fraction(0.8), .large])
        }
        .alert("Nothing found", isPresented: Binding(get: { scanError != nil }, set: { if !$0 { scanError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(scanError ?? "")
        }
        .onChange(of: model.current?.state) { _, state in
            if case .logged = state { editingResult = false }
            model.observe(state)
        }
    }

    /// The scanned code, looked up; the sheet shows what was found, or the alert says nothing was.
    private func lookUp(_ code: String) async {
        try? await Task.sleep(for: .milliseconds(420))
        do {
            scannedFood = try await barcode.lookup(code: code)
        } catch BarcodeLookupError.notFound {
            scanError = "No food found for that barcode. Say it or type it instead."
        } catch BarcodeLookupError.invalidCode {
            scanError = "That did not read as a barcode. Try again, or type the number."
        } catch {
            scanError = "Couldn't look that up. Check your connection and try again."
        }
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack(spacing: VoCalTheme.Spacing.m) {
            Button(action: onClose) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(VoCalTheme.Colors.ink)
                    .frame(width: 44, height: 44)
                    .liquidGlass(in: Circle(), tint: CaptureBar.dropletFace, interactive: true)
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel("Close")
            .accessibilityIdentifier(A11y.Chat.close)
            Spacer()
            Text(dayLabel)
                .font(VoCalTheme.Fonts.formLabel.weight(.semibold))
                .foregroundStyle(VoCalTheme.Colors.muted)
                .padding(.horizontal, VoCalTheme.Spacing.m)
                .frame(height: 32)
                .liquidGlass(in: Capsule())
        }
        .padding(.horizontal, VoCalTheme.Spacing.l)
        .padding(.top, VoCalTheme.Spacing.s)
    }

    private var dayLabel: String {
        Calendar.current.isDateInToday(model.targetDate)
            ? "Today"
            : model.targetDate.formatted(.dateTime.weekday(.wide).month().day())
    }

    /// Serein's catchers, under the bar (as the shell laid them under Today's): a tap anywhere
    /// else closes the menu, or puts the keyboard away.
    @ViewBuilder
    private var catchers: some View {
        if menuOpen {
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .onTapGesture { withAnimation(CaptureBar.composeMotion) { menuOpen = false } }
                .accessibilityHidden(true)
        } else if composer.isFieldFocused {
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .onTapGesture { composer.dismissKeyboard() }
                .accessibilityHidden(true)
        }
    }

    // MARK: - The thread

    private var thread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: VoCalTheme.Spacing.m) {
                    if model.turns.isEmpty, model.current == nil {
                        emptyState
                    }
                    ForEach(model.turns) { turn in
                        turnView(turn)
                    }
                    if let current = model.current {
                        liveTurn(current)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .padding(.horizontal, VoCalTheme.Spacing.l)
                .padding(.top, 72)
                .padding(.bottom, VoCalTheme.Spacing.xl)
            }
            .frostedStatusBar()
            .accessibilityIdentifier(A11y.Chat.thread)
            .onChange(of: model.turns.count) { _, _ in
                withAnimation(.snappy(duration: 0.3)) { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
            }
            .onChange(of: model.current?.state) { _, _ in
                withAnimation(.snappy(duration: 0.3)) { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
            }
        }
    }

    /// The first screen: one question, three doors. No sparkle, no name (decision 71's
    /// refusals stand): the chips are sentences the thread already understands.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: VoCalTheme.Spacing.l) {
            Spacer(minLength: 120)
            Text("What did you eat?")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(VoCalTheme.Colors.ink)
            Text("Say it, type it, snap it or scan it. Ask for a number, or change how you track, in the same place.")
                .font(VoCalTheme.Fonts.body)
                .foregroundStyle(VoCalTheme.Colors.muted)
                .fixedSize(horizontal: false, vertical: true)
            FlowLayout(spacing: VoCalTheme.Spacing.s) {
                ForEach(Self.suggestions, id: \.self) { line in
                    Button {
                        model.send(line)
                    } label: {
                        Text(line)
                            .font(VoCalTheme.Fonts.chipLabel)
                            .foregroundStyle(VoCalTheme.Colors.ink)
                            .padding(.horizontal, VoCalTheme.Spacing.m)
                            .frame(height: 38)
                            .background(VoCalTheme.Colors.softFill, in: Capsule())
                            .overlay(Capsule().strokeBorder(VoCalTheme.Colors.goldBorder, lineWidth: 1.5))
                    }
                    .buttonStyle(PressableButtonStyle())
                }
            }
            .padding(.top, VoCalTheme.Spacing.s)
        }
    }

    private static let suggestions = [
        "How much protein so far?",
        "Show my calories",
        "Only remind me when I'm slipping",
        "Two eggs and a slice of toast",
    ]

    @ViewBuilder
    private func turnView(_ turn: ChatTurn) -> some View {
        switch turn.kind {
        case let .person(text):
            personBubble(text)
        case let .receipt(name, kcal, prints, waterOz, waterOnly):
            ReceiptCard(name: name, kcal: kcal, printsNumbers: prints, waterOz: waterOz, waterOnly: waterOnly)
        case let .answer(asked, reply, undone):
            ChatAnswerCard(asked: asked, reply: reply, undone: undone, canUndo: false, isUndoing: false, onUndo: {}, onOpen: onOpen)
        case let .failure(message, transcript):
            FailureCard(message: message, transcript: transcript, retryable: false, onRetry: {})
        }
    }

    /// The turn under way, drawn from the model's state: the working line while the parse
    /// runs, the meal card once it is parsed, the answer, the failure. The capture rungs never
    /// draw here (the voice sheet draws them); a model still in them shows the working line.
    @ViewBuilder
    private func liveTurn(_ current: VoiceLogViewModel) -> some View {
        switch current.state {
        case let .result(context):
            MealResultCard(
                context: context,
                mealType: current.mealType,
                printsNumbers: context.result.printsNumbers,
                saveAsUsual: Binding(get: { saveAsUsual ?? saveAsUsualDefault }, set: { saveAsUsual = $0 }),
                showsUsualToggle: context.result.items.count > 0 && !context.hasOpenChecks,
                onLog: { model.log(saveAsUsual: saveAsUsual ?? saveAsUsualDefault) },
                onEdit: { editingResult = true },
                onAcceptUsual: { current.acceptRecognized() },
                onDismissUsual: { current.dismissRecognized() }
            )
        case let .answered(context):
            ChatAnswerCard(
                asked: context.asked, reply: context.reply, undone: context.undone,
                canUndo: context.canUndo, isUndoing: context.isUndoing,
                onUndo: { model.undo() }, onOpen: onOpen
            )
        case let .failed(message, retryable, _, transcript):
            FailureCard(message: message, transcript: transcript, retryable: retryable || !current.hasCapture, onRetry: { model.retry() })
        case .logged:
            EmptyView()
        default:
            thinking(current)
        }
    }

    private func thinking(_ current: VoiceLogViewModel) -> some View {
        HStack(spacing: VoCalTheme.Spacing.s) {
            VoCalLoader(size: 20)
            Text(workingLine(current.state))
                .font(VoCalTheme.Fonts.secondaryLabel)
                .foregroundStyle(VoCalTheme.Colors.muted)
        }
        .padding(.horizontal, VoCalTheme.Spacing.l)
        .padding(.vertical, VoCalTheme.Spacing.m)
        .background(VoCalTheme.Colors.card, in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.row, style: .continuous))
        .accessibilityIdentifier(A11y.Chat.thinking)
    }

    private func workingLine(_ state: VoiceLogState) -> String {
        switch state {
        case .transcribing: "Transcribing\u{2026}"
        case .enhancing: "Working out the numbers\u{2026}"
        default: "One moment\u{2026}"
        }
    }

    private func personBubble(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 48)
            Text(text)
                .font(VoCalTheme.Fonts.body)
                .foregroundStyle(VoCalTheme.Colors.onCta)
                .padding(.horizontal, VoCalTheme.Spacing.l)
                .padding(.vertical, VoCalTheme.Spacing.m)
                .background(VoCalTheme.Colors.cta, in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.row, style: .continuous))
                .accessibilityIdentifier(A11y.Chat.personTurn)
        }
    }
}

// MARK: - The turns

/// The parsed meal as a card in the thread: the name the server will give it, the calories and
/// the items, the checks left, Log and Edit. Edit opens the full result sheet on the same
/// model, where the checks, the amounts and the person's foods are answered as before.
struct MealResultCard: View {
    let context: ResultContext
    let mealType: MealType
    var printsNumbers = true
    @Binding var saveAsUsual: Bool
    var showsUsualToggle = true
    var onLog: () -> Void = {}
    var onEdit: () -> Void = {}
    var onAcceptUsual: () -> Void = {}
    var onDismissUsual: () -> Void = {}

    private var items: [ParseResultItem] { context.result.items }
    private var name: String {
        context.acceptedUsual?.name ?? PlanComposer.autoName(items.map(ConfirmedItem.init(from:)))
    }
    private var kcal: Int { Int(context.result.totals.kcal.rounded()) }
    private var checks: Int { context.result.questions.count }
    private var isRough: Bool { (context.result.certainty?.score ?? 100) < 50 }

    var body: some View {
        VStack(alignment: .leading, spacing: VoCalTheme.Spacing.m) {
            if let usual = context.offeredUsual {
                RecognizedMealCard(usual: usual, isBusy: context.isRefining, showsNumbers: printsNumbers, onYes: onAcceptUsual, onNo: onDismissUsual)
            }
            HStack(alignment: .top, spacing: VoCalTheme.Spacing.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(slotWord).sectionHeader()
                    Text(name)
                        .font(VoCalTheme.Fonts.primaryLabel)
                        .foregroundStyle(VoCalTheme.Colors.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                ConfidenceBadge(confidence: context.result.mealConfidence)
            }
            if printsNumbers {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(isRough ? "~" : "")\(kcal)")
                        .font(VoCalTheme.Fonts.numeral(36).monospacedDigit())
                        .foregroundStyle(VoCalTheme.Colors.ink)
                    Text(checks > 0 ? "cal so far" : "cal")
                        .font(VoCalTheme.Fonts.secondaryLabel)
                        .foregroundStyle(VoCalTheme.Colors.muted)
                    Spacer()
                    macro("P", context.result.totals.protein, VoCalTheme.Colors.protein)
                    macro("C", context.result.totals.carbs, VoCalTheme.Colors.carbs)
                    macro("F", context.result.totals.fat, VoCalTheme.Colors.fats)
                }
            }
            VStack(alignment: .leading, spacing: VoCalTheme.Spacing.xs) {
                ForEach(Array(items.prefix(5).enumerated()), id: \.offset) { _, item in
                    HStack(spacing: VoCalTheme.Spacing.s) {
                        Text(itemLine(item))
                            .font(VoCalTheme.Fonts.secondaryLabel)
                            .foregroundStyle(VoCalTheme.Colors.ink)
                            .lineLimit(1)
                        Spacer(minLength: VoCalTheme.Spacing.s)
                        if printsNumbers {
                            Text("\(Int(item.macros.kcal.rounded()))")
                                .font(VoCalTheme.Fonts.secondaryLabel.monospacedDigit())
                                .foregroundStyle(VoCalTheme.Colors.muted)
                        }
                    }
                }
                if items.count > 5 {
                    Text("and \(items.count - 5) more")
                        .font(VoCalTheme.Fonts.formLabel)
                        .foregroundStyle(VoCalTheme.Colors.muted)
                }
            }
            if checks > 0, printsNumbers {
                Button(action: onEdit) {
                    HStack(spacing: VoCalTheme.Spacing.s) {
                        Image(systemName: "questionmark.circle")
                            .font(.system(size: 14, weight: .semibold))
                        Text("\(checks) check\(checks > 1 ? "s" : "") left. Answer them to sharpen the numbers.")
                            .font(VoCalTheme.Fonts.formLabel.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(VoCalTheme.Colors.gold)
                    .padding(VoCalTheme.Spacing.m)
                    .background(VoCalTheme.Colors.gold.opacity(0.12), in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.chip, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
            }
            if showsUsualToggle {
                Toggle(isOn: $saveAsUsual) {
                    Text("Save as a usual")
                        .font(VoCalTheme.Fonts.secondaryLabel)
                        .foregroundStyle(VoCalTheme.Colors.ink)
                }
                .tint(VoCalTheme.Colors.gold)
            }
            HStack(spacing: VoCalTheme.Spacing.m) {
                VoCalButton(title: "Edit", kind: .secondary, isEnabled: !context.isRefining, action: onEdit)
                    .frame(maxWidth: 120)
                    .accessibilityIdentifier(A11y.Chat.resultEdit)
                PillButton(title: logTitle, isEnabled: !context.isRefining && !items.isEmpty, action: onLog)
                    .accessibilityIdentifier(A11y.Chat.resultLog)
            }
        }
        .padding(VoCalTheme.Spacing.l)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: VoCalTheme.Radius.card, style: .continuous).strokeBorder(VoCalTheme.Colors.white.opacity(0.6), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.07), radius: 14, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(A11y.Chat.resultCard)
    }

    private var slotWord: String {
        switch mealType {
        case .breakfast: "Breakfast"
        case .lunch: "Lunch"
        case .dinner: "Dinner"
        case .snack: "Snack"
        case .unspecified: "Meal"
        }
    }

    private var logTitle: String {
        guard !items.isEmpty else { return "Nothing to log" }
        guard printsNumbers else { return "Log it" }
        return checks > 0 ? "Log anyway (\(kcal) cal)" : "Log meal (\(kcal) cal)"
    }

    private func itemLine(_ item: ParseResultItem) -> String {
        var parts: [String] = []
        if let amount = item.amount {
            let number = amount == amount.rounded() ? String(Int(amount)) : String(format: "%.1f", amount)
            parts.append(item.unit.map { "\(number) \($0.rawValue)" } ?? number)
        }
        parts.append(item.name)
        return parts.joined(separator: " · ")
    }

    private func macro(_ letter: String, _ grams: Double, _ color: Color) -> some View {
        HStack(spacing: 2) {
            Text("\(Int(grams.rounded()))")
                .font(VoCalTheme.Fonts.formLabel.weight(.semibold).monospacedDigit())
                .foregroundStyle(color)
            Text(letter)
                .font(VoCalTheme.Fonts.formLabel)
                .foregroundStyle(VoCalTheme.Colors.muted)
        }
    }
}

/// The server's row landed: the one word the state licenses, the meal's name, its calories
/// where the mode prints them, and the water that went to the tally.
struct ReceiptCard: View {
    let name: String
    let kcal: Double
    var printsNumbers = true
    var waterOz: Double = 0
    var waterOnly = false

    var body: some View {
        HStack(spacing: VoCalTheme.Spacing.m) {
            Image(systemName: waterOnly ? "drop.fill" : "checkmark.seal.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(VoCalTheme.Colors.gold)
            VStack(alignment: .leading, spacing: 2) {
                Text(waterOnly ? "Water logged" : ClaimCopy.logged)
                    .font(VoCalTheme.Fonts.primaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.ink)
                Text(line)
                    .font(VoCalTheme.Fonts.formLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(VoCalTheme.Spacing.l)
        .background(VoCalTheme.Colors.card, in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.row, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: VoCalTheme.Radius.row, style: .continuous).strokeBorder(VoCalTheme.Colors.optimal.opacity(0.45), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(A11y.Chat.receipt)
    }

    private var line: String {
        if waterOnly { return "\(Int(waterOz.rounded())) oz added to your water log" }
        var parts = [printsNumbers ? "\(Int(kcal.rounded())) cal \u{00B7} \(name)" : name]
        if waterOz > 0 { parts.append("\(Int(waterOz.rounded())) oz of water added") }
        return parts.joined(separator: " \u{00B7} ")
    }
}

/// The bar's answer as a turn (decision 71's anatomy, unchanged): the line, then exactly one of
/// the changed row as Settings draws it, the Today card as Today draws it, or the pointer row;
/// Undo while the change that landed can still be put back.
struct ChatAnswerCard: View {
    let asked: String
    let reply: AssistReply
    var undone = false
    var canUndo = false
    var isUndoing = false
    var onUndo: () -> Void = {}
    var onOpen: (AssistPointer.Surface) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: VoCalTheme.Spacing.m) {
            Text(undone ? AssistReplyView.undoneLine : reply.line)
                .font(VoCalTheme.Fonts.body)
                .foregroundStyle(VoCalTheme.Colors.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(A11y.VoiceLog.answerLine)
            if !undone {
                if let change = reply.change {
                    SettingsCard {
                        SettingsRow(icon: change.icon, label: change.title, value: change.value, showsChevron: false, accessibilityID: A11y.VoiceLog.answerChange)
                    }
                } else if let panel = reply.panel {
                    PanelView(panel: panel, size: .hero)
                        .accessibilityIdentifier(A11y.VoiceLog.answerPanel)
                } else if let pointer = reply.pointer {
                    SettingsCard {
                        SettingsRow(icon: "arrow.up.right", label: pointer.title, showsChevron: true, accessibilityID: A11y.VoiceLog.answerPointer) {
                            if let surface = pointer.knownSurface { onOpen(surface) }
                        }
                    }
                }
            }
            if canUndo {
                VoCalButton(title: "Undo", kind: .secondary, isLoading: isUndoing, action: onUndo)
                    .frame(maxWidth: 140)
                    .accessibilityIdentifier(A11y.VoiceLog.answerUndo)
            }
        }
        .padding(VoCalTheme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VoCalTheme.Colors.card, in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.card, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(A11y.Chat.answer)
    }
}

/// A derived step that did not finish, as the sheet says it: calm, the words echoed so the
/// person can rephrase, Try again where a retry can help.
struct FailureCard: View {
    let message: String
    var transcript: String?
    var retryable = true
    var onRetry: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: VoCalTheme.Spacing.m) {
            HStack(spacing: VoCalTheme.Spacing.m) {
                Image(systemName: "waveform.badge.exclamationmark")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(VoCalTheme.Colors.muted)
                Text(message)
                    .font(VoCalTheme.Fonts.secondaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if retryable {
                VoCalButton(title: "Try again", kind: .secondary, action: onRetry)
                    .frame(maxWidth: 160)
            }
        }
        .padding(VoCalTheme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VoCalTheme.Colors.card, in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.card, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(A11y.Chat.failure)
    }
}

#Preview("Empty") {
    ChatView(model: ChatThreadModel())
}
