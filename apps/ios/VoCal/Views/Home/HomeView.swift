import SwiftUI
import VoCalCore

/// The home (2026-11-06): calm, one page. The greeting on the wash, the day's one line, the
/// summary card into Progress, then the diary by meal (breakfast, lunch, dinner, snacks, each
/// with its meals and its own Add), and the way into the chat. The one pill at the bottom,
/// "Log a meal", is the shell's. Numbers here are the server's rows and panels; the page
/// arranges them. The mode governs every printed number (decision 59): habits prints none.
struct HomeView: View {
    let model: TodayViewModel
    /// Bumped by the shell after a log so the day reloads.
    var refreshToken: Int = 0
    var tour: HelpTourModel? = nil
    var onProfile: () -> Void = {}
    /// Add to a section, or log into whatever the clock suggests (nil).
    var onLog: (DiarySlot?) -> Void = { _ in }
    var onAsk: () -> Void = {}
    var onProgress: () -> Void = {}
    /// A meal was logged or discarded from a sheet this page presented (an unfinished
    /// recording finished): the shell's post-log beat.
    var onLogged: () -> Void = {}

    @State private var editingMeal: EditingMeal?
    @State private var resuming: ResumeCapture?
    @State private var showCheckIn = false
    @State private var renaming: TodayMealRow?
    @State private var renameText = ""
    @State private var renameError: String?
    @State private var deleteFailed = false
    @State private var invitationError: String?
    /// Cached so the greeting's subline can name what the person said matters.
    @State private var priorities = GoalPriorities.load()

    private struct EditingMeal: Identifiable { let id: String; let displayName: String }
    private struct ResumeCapture: Identifiable { let id: String }

    var body: some View {
        ZStack {
            VoCalTheme.Colors.background.ignoresSafeArea()
            WashBackground()
            content
        }
        .accessibilityIdentifier(A11y.Home.screen)
        .task(id: refreshToken) {
            await model.load()
            NudgeCenter.shared.refresh()
        }
        .sheet(item: $editingMeal) { editing in
            LoggedMealEditView(mealID: editing.id, displayName: editing.displayName, model: model)
        }
        .fullScreenCover(item: $resuming, onDismiss: {
            Task { await model.loadUnfinished() }
        }) { capture in
            VoiceLogView(targetDate: model.selectedDate, resumeCaptureID: capture.id, onLogged: { onLogged() })
        }
        .sheet(isPresented: $showCheckIn) {
            CheckInView(printsNumbers: printsNumbers) { applied in
                model.dismissCheckin()
                if applied { Task { await model.load() } }
            }
        }
        .alert("Name this meal", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { meal in
            TextField("Metal detox smoothie", text: $renameText)
                .accessibilityIdentifier(A11y.Today.renameField)
            Button("Save") {
                let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                Task {
                    do {
                        try await model.renameMeal(meal.id, name: name)
                        VoCalHaptics.success()
                    } catch {
                        renameError = TodayViewModel.renameFailureMessage(for: error)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Vo-Cal will offer it by this name from now on.")
        }
        .alert("Name not saved", isPresented: Binding(get: { renameError != nil }, set: { if !$0 { renameError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(renameError ?? "")
        }
        .alert("Meal not deleted", isPresented: $deleteFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The delete didn't reach the server. Check your connection and try again.")
        }
        .alert("Not changed", isPresented: Binding(get: { invitationError != nil }, set: { if !$0 { invitationError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(invitationError ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading where model.dashboard == nil:
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, VoCalTheme.Spacing.l)
                    .padding(.top, VoCalTheme.Spacing.m)
                Spacer()
                VoCalLoader(size: 44)
                Spacer()
            }
        case let .failed(message):
            VStack(spacing: VoCalTheme.Spacing.l) {
                header
                Spacer()
                Text(message)
                    .font(VoCalTheme.Fonts.primaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.ink)
                PillButton(title: "Try again") { Task { await model.load() } }
                    .padding(.horizontal, VoCalTheme.Spacing.xxl)
                Spacer()
            }
            .padding(VoCalTheme.Spacing.l)
        default:
            page(model.dashboard ?? MockTodayService.empty(date: model.selectedDate))
        }
    }

    // MARK: - The page

    private func page(_ data: TodayDashboard) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VoCalTheme.Spacing.l) {
                header
                focusLine(data)
                if model.checkinDue { checkinBanner }
                if NudgeCenter.shared.permissionAskPending, NudgeCenter.shared.level != .off {
                    NotificationPermissionCard(
                        level: NudgeCenter.shared.level,
                        onAllow: { Task { await NudgeCenter.shared.allowNotifications() } },
                        onNotNow: { NudgeCenter.shared.declineNotificationAsk() }
                    )
                }
                if data.meals.isEmpty, let nudge = NudgeCenter.shared.currentCard {
                    NudgeCardView(
                        card: nudge,
                        onDismiss: { NudgeCenter.shared.dismissCurrent() },
                        onAccept: { answerInvitation(nudge, accept: true) },
                        onDeclineForever: { answerInvitation(nudge, accept: false) },
                        onReport: { kind in NudgeCenter.shared.report(nudge, kind) }
                    )
                }
                TodaySummaryCard(dashboard: data, onOpen: onProgress)
                    .helpTourTarget(HelpTourStep.Home.calories, in: tour)
                if let guidance = data.guidance {
                    GuidanceCard(guidance: guidance)
                }
                if !model.unfinished.isEmpty { unfinishedSection }
                diary(data)
                askRow
            }
            .padding(.horizontal, VoCalTheme.Spacing.l)
            .padding(.top, VoCalTheme.Spacing.m)
            // The pill is a safe-area inset in the shell; a breath above it.
            .padding(.bottom, VoCalTheme.Spacing.xl)
        }
        .frostedStatusBar()
        .refreshable {
            await model.load()
            await model.loadUnfinished()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: VoCalTheme.Spacing.m) {
            HStack(alignment: .top, spacing: VoCalTheme.Spacing.m) {
                VStack(alignment: .leading, spacing: VoCalTheme.Spacing.xs) {
                    Text(greeting)
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(VoCalTheme.Colors.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if let sentence = priorities.sentence, isToday {
                        Text(sentence)
                            .font(VoCalTheme.Fonts.secondaryLabel)
                            .foregroundStyle(VoCalTheme.Colors.muted)
                    }
                }
                Spacer(minLength: 0)
                ProfileCircleButton(action: onProfile)
                    .helpTourTarget(HelpTourStep.Home.profile, in: tour)
            }
            dayRow
        }
    }

    /// "Good morning" by the clock on the day on screen; another day is named by its weekday.
    private var greeting: String {
        guard isToday else { return model.selectedDate.formatted(.dateTime.weekday(.wide)) }
        let hour = Calendar.current.component(.hour, from: .now)
        switch hour {
        case ..<5: return "Good evening"
        case ..<12: return "Good morning"
        case ..<17: return "Good afternoon"
        default: return "Good evening"
        }
    }

    /// The day on screen, with a step either way: the diary is a day's page, and the next
    /// page is tomorrow's only once it exists.
    private var dayRow: some View {
        HStack(spacing: VoCalTheme.Spacing.s) {
            dayButton("chevron.left", id: A11y.Home.dayBack, label: "Previous day", enabled: true) { shift(-1) }
            Text(isToday ? "Today, \(model.selectedDate.formatted(.dateTime.month().day()))" : model.selectedDate.formatted(.dateTime.weekday(.wide).month().day()))
                .font(VoCalTheme.Fonts.formLabel.weight(.semibold))
                .foregroundStyle(VoCalTheme.Colors.muted)
                .frame(maxWidth: .infinity)
                .contentTransition(.numericText())
            dayButton("chevron.right", id: A11y.Home.dayForward, label: "Next day", enabled: !isToday) { shift(1) }
        }
    }

    private func dayButton(_ symbol: String, id: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(VoCalTheme.Colors.muted)
                .frame(width: 44, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    private func shift(_ days: Int) {
        guard let next = Calendar.current.date(byAdding: .day, value: days, to: model.selectedDate), next <= .now else { return }
        VoCalHaptics.select()
        Task { await model.select(next) }
    }

    // MARK: - The one line

    /// The day in one sentence, from the server's calories card (decision 70's framing), or
    /// the plan's line, or, without numbers, the one habit. Never a number the mode hides.
    private func focusLine(_ data: TodayDashboard) -> some View {
        Text(Self.focusSentence(data))
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(VoCalTheme.Colors.ink)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(A11y.Home.focusLine)
    }

    static func focusSentence(_ data: TodayDashboard) -> String {
        guard data.printsNumbers else {
            if data.meals.isEmpty { return "Say what you eat and it counts itself." }
            return data.meals.count == 1 ? "One meal logged. The day is on the page." : "\(data.meals.count) meals logged. The day is on the page."
        }
        let panels = data.panelsToDraw
        if let plan = panels.first(where: { $0.knownKind == .mealPlanSlots }), !plan.slots.isEmpty {
            return "Your plan: \(plan.support)."
        }
        guard let calories = panels.first(where: { $0.knownKind == .caloriesLeft }) else {
            return "Say what you eat and it logs."
        }
        if calories.over {
            return "\(DashboardNumber.whole(calories.consumed - calories.target)) over your \(DashboardNumber.whole(calories.target)) today."
        }
        if calories.knownFraming == .toDate {
            return "\(DashboardNumber.whole(calories.consumed)) so far. \(DashboardNumber.whole(calories.remaining)) left of \(DashboardNumber.whole(calories.target)) today."
        }
        if calories.consumed == 0 {
            return "\(DashboardNumber.whole(calories.target)) for today. Nothing logged yet."
        }
        return "\(DashboardNumber.whole(calories.remaining)) left of \(DashboardNumber.whole(calories.target)) today."
    }

    // MARK: - The diary

    private func diary(_ data: TodayDashboard) -> some View {
        VStack(alignment: .leading, spacing: VoCalTheme.Spacing.m) {
            ForEach(MealDiary.sections(data.meals)) { section in
                diarySection(section)
            }
        }
    }

    private func diarySection(_ section: DiarySection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: VoCalTheme.Spacing.s) {
                Text(section.slot.title)
                    .font(VoCalTheme.Fonts.primaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.ink)
                if printsNumbers, !section.meals.isEmpty {
                    Text("\(DashboardNumber.whole(section.kcal)) cal")
                        .font(VoCalTheme.Fonts.formLabel)
                        .monospacedDigit()
                        .foregroundStyle(VoCalTheme.Colors.muted)
                }
                Spacer(minLength: 0)
                Button {
                    onLog(section.slot)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .bold))
                        Text("Add")
                            .font(VoCalTheme.Fonts.formLabel.weight(.semibold))
                    }
                    .foregroundStyle(VoCalTheme.Colors.gold)
                    .padding(.horizontal, VoCalTheme.Spacing.m)
                    .frame(height: 34)
                    .background(VoCalTheme.Colors.gold.opacity(0.12), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel("Add to \(section.slot.title.lowercased())")
                .accessibilityIdentifier(A11y.Home.add(section.slot.rawValue))
            }
            .padding(.horizontal, VoCalTheme.Spacing.l)
            .padding(.top, VoCalTheme.Spacing.m)
            .padding(.bottom, section.meals.isEmpty ? VoCalTheme.Spacing.m : VoCalTheme.Spacing.s)

            if section.meals.isEmpty {
                EmptyView()
            } else {
                VStack(spacing: 0) {
                    ForEach(section.meals) { meal in
                        mealRow(meal)
                        if meal.id != section.meals.last?.id {
                            Rectangle().fill(VoCalTheme.Colors.ink.opacity(0.06)).frame(height: 1)
                                .padding(.leading, VoCalTheme.Spacing.l)
                        }
                    }
                }
                .padding(.bottom, VoCalTheme.Spacing.xs)
            }
        }
        .background(VoCalTheme.Colors.card, in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.card, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(A11y.Home.section(section.slot.rawValue))
    }

    /// A logged meal: its name (the server names every meal after what was eaten), its time,
    /// the calories. Tap to edit; right to edit, left to delete; press and hold for the menu.
    private func mealRow(_ meal: TodayMealRow) -> some View {
        let rowName = meal.name ?? "Meal"
        return HStack(alignment: .center, spacing: VoCalTheme.Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(rowName)
                    .font(VoCalTheme.Fonts.body)
                    .foregroundStyle(VoCalTheme.Colors.ink)
                    .lineLimit(2)
                Text(meal.loggedAt.formatted(date: .omitted, time: .shortened))
                    .font(VoCalTheme.Fonts.formLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
            }
            Spacer(minLength: VoCalTheme.Spacing.m)
            if printsNumbers {
                Text(DashboardNumber.whole(meal.kcal))
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(VoCalTheme.Colors.ink)
            }
        }
        .padding(.horizontal, VoCalTheme.Spacing.l)
        .padding(.vertical, VoCalTheme.Spacing.m)
        .frame(minHeight: 56)
        .background(VoCalTheme.Colors.card)
        .contentShape(Rectangle())
        .onTapGesture {
            VoCalHaptics.tap()
            editingMeal = EditingMeal(id: meal.id, displayName: rowName)
        }
        .swipeable(
            onEdit: { editingMeal = EditingMeal(id: meal.id, displayName: rowName) },
            onDelete: { delete(meal) }
        )
        .contextMenu {
            Button { editingMeal = EditingMeal(id: meal.id, displayName: rowName) } label: {
                Label("Edit meal", systemImage: "pencil")
            }
            Button {
                renameText = meal.name ?? ""
                renaming = meal
            } label: {
                Label("Name this meal", systemImage: "character.cursor.ibeam")
            }
            Button(role: .destructive) { delete(meal) } label: {
                Label("Delete meal", systemImage: "trash")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(printsNumbers ? "\(rowName), \(DashboardNumber.whole(meal.kcal)) calories" : rowName)
        .accessibilityIdentifier(A11y.Home.mealRow)
    }

    private func delete(_ meal: TodayMealRow) {
        Task {
            do { try await model.deleteMeal(meal.id) } catch { deleteFailed = true }
        }
    }

    // MARK: - The way into the chat

    private var askRow: some View {
        Button(action: onAsk) {
            HStack(spacing: VoCalTheme.Spacing.m) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(VoCalTheme.Colors.gold)
                Text("Ask Vo-Cal anything")
                    .font(VoCalTheme.Fonts.body)
                    .foregroundStyle(VoCalTheme.Colors.muted)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(VoCalTheme.Colors.muted)
            }
            .padding(.horizontal, VoCalTheme.Spacing.l)
            .frame(height: 56)
            .background(VoCalTheme.Colors.softFill, in: Capsule())
            .overlay(Capsule().strokeBorder(VoCalTheme.Colors.goldBorder, lineWidth: 1.5))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("Ask Vo-Cal anything")
        .accessibilityIdentifier(A11y.Home.askRow)
        .helpTourTarget(HelpTourStep.Home.ask, in: tour)
    }

    // MARK: - Banners

    private var checkinBanner: some View {
        HStack(spacing: VoCalTheme.Spacing.m) {
            Button { showCheckIn = true } label: {
                HStack(spacing: VoCalTheme.Spacing.m) {
                    Image(systemName: "calendar.badge.checkmark")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(VoCalTheme.Colors.gold)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Weekly check-in ready")
                            .font(VoCalTheme.Fonts.primaryLabel)
                            .foregroundStyle(VoCalTheme.Colors.ink)
                        Text("See how the week went")
                            .font(VoCalTheme.Fonts.formLabel)
                            .foregroundStyle(VoCalTheme.Colors.muted)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                withAnimation(.snappy(duration: 0.25)) { model.snoozeCheckin() }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(VoCalTheme.Colors.muted)
                    .frame(width: 30, height: 30)
                    .background(VoCalTheme.Colors.background.opacity(0.7), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Snooze check-in for two days")
        }
        .padding(VoCalTheme.Spacing.l)
        .background(VoCalTheme.Colors.gold.opacity(0.12), in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: VoCalTheme.Radius.card, style: .continuous)
                .strokeBorder(VoCalTheme.Colors.gold.opacity(0.35), lineWidth: 1)
        )
    }

    private var unfinishedSection: some View {
        VStack(alignment: .leading, spacing: VoCalTheme.Spacing.s) {
            Text("Unfinished")
                .font(VoCalTheme.Fonts.primaryLabel)
                .foregroundStyle(VoCalTheme.Colors.ink)
            ForEach(model.unfinished) { capture in
                HStack(spacing: VoCalTheme.Spacing.m) {
                    Image(systemName: "waveform")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(VoCalTheme.Colors.gold)
                        .frame(width: 38, height: 38)
                        .background(VoCalTheme.Colors.background, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Recording saved")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(VoCalTheme.Colors.ink)
                        Text("\(capture.capturedAt.formatted(date: .omitted, time: .shortened)) · Not logged yet")
                            .font(VoCalTheme.Fonts.formLabel)
                            .foregroundStyle(VoCalTheme.Colors.muted)
                    }
                    Spacer()
                    Text("Finish")
                        .font(VoCalTheme.Fonts.formLabel.weight(.semibold))
                        .foregroundStyle(VoCalTheme.Colors.gold)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(VoCalTheme.Colors.muted)
                }
                .padding(VoCalTheme.Spacing.m)
                .background(VoCalTheme.Colors.card, in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.chip, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: VoCalTheme.Radius.chip, style: .continuous)
                        .strokeBorder(VoCalTheme.Colors.goldBorder, lineWidth: 1)
                )
                .contentShape(Rectangle())
                .onTapGesture { resuming = ResumeCapture(id: capture.captureID) }
                .contextMenu {
                    Button { resuming = ResumeCapture(id: capture.captureID) } label: {
                        Label("Finish logging", systemImage: "waveform")
                    }
                    Button(role: .destructive) {
                        Task { await model.discardUnfinished(capture.captureID) }
                    } label: {
                        Label("Discard recording", systemImage: "trash")
                    }
                }
                .accessibilityIdentifier(A11y.Today.unfinishedRow)
            }
        }
    }

    private func answerInvitation(_ card: NudgeCard, accept: Bool) {
        Task {
            let landed = accept
                ? await NudgeCenter.shared.acceptInvitation(card)
                : await NudgeCenter.shared.declineInvitation(card)
            if landed {
                if accept { await model.load() }
            } else {
                invitationError = "That didn't reach the server. Check your connection and try again."
            }
        }
    }

    // MARK: - Helpers

    private var isToday: Bool { Calendar.current.isDateInToday(model.selectedDate) }
    private var printsNumbers: Bool { model.dashboard?.printsNumbers ?? true }
}

/// The day at a glance, in one card: each of the mode's panels as a row (title, the value,
/// a thin bar), the plan's line in meal-plan mode, the habit's state in habits. The card is
/// the door to Progress, where the full cards, the week and the check-in live.
struct TodaySummaryCard: View {
    let dashboard: TodayDashboard
    var onOpen: () -> Void = {}

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: VoCalTheme.Spacing.m) {
                HStack {
                    Text("Today").sectionHeader()
                    Spacer()
                    HStack(spacing: 4) {
                        Text("Progress")
                            .font(VoCalTheme.Fonts.formLabel.weight(.semibold))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(VoCalTheme.Colors.muted)
                }
                let panels = dashboard.panelsToDraw.filter { $0.knownKind != nil }
                if panels.isEmpty {
                    Text("Nothing to show yet.")
                        .font(VoCalTheme.Fonts.secondaryLabel)
                        .foregroundStyle(VoCalTheme.Colors.muted)
                } else {
                    ForEach(panels.prefix(6)) { panel in
                        row(panel)
                    }
                }
            }
            .padding(VoCalTheme.Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(VoCalTheme.Colors.card, in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.card, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: VoCalTheme.Radius.card, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityIdentifier(A11y.Home.progressCard)
        .accessibilityLabel("Today's progress")
        .accessibilityHint("Opens Progress")
    }

    @ViewBuilder
    private func row(_ panel: TodayPanel) -> some View {
        switch panel.knownKind {
        case .caloriesLeft?:
            metricRow(
                title: panel.title,
                value: DashboardNumber.whole(panel.knownFraming == .toDate ? panel.consumed : panel.remaining),
                unit: "cal",
                detail: panel.support,
                fraction: panel.target > 0 ? panel.consumed / panel.target : 0,
                fill: panel.over ? VoCalTheme.Colors.alert : (panel.complete ? VoCalTheme.Colors.optimal : VoCalTheme.Colors.gold),
                valueColor: panel.knownFraming == .toDate ? VoCalTheme.Colors.ink : VoCalTheme.Colors.gold
            )
        case .metricTile?:
            metricRow(
                title: panel.title,
                value: DashboardNumber.trimmed(panel.consumed),
                unit: "/ \(DashboardNumber.trimmed(panel.target))\(panel.unit.isEmpty ? "" : " \(panel.unit)")",
                detail: panel.support,
                fraction: panel.target > 0 ? panel.consumed / panel.target : 0,
                fill: barFill(panel),
                valueColor: panel.complete ? VoCalTheme.Colors.optimal : VoCalTheme.Colors.ink
            )
        case .habitTile?:
            HStack {
                Text(panel.title)
                    .font(VoCalTheme.Fonts.secondaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
                Spacer()
                Text(panel.support.isEmpty ? DashboardNumber.trimmed(panel.consumed) : panel.support)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(panel.complete ? VoCalTheme.Colors.optimal : VoCalTheme.Colors.ink)
            }
        case .mealPlanSlots?:
            HStack {
                Text(panel.title)
                    .font(VoCalTheme.Fonts.secondaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
                Spacer()
                Text(panel.slots.isEmpty ? "No plan yet" : panel.support)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(panel.complete && !panel.slots.isEmpty ? VoCalTheme.Colors.optimal : VoCalTheme.Colors.ink)
            }
        case nil:
            EmptyView()
        }
    }

    private func metricRow(title: String, value: String, unit: String, detail: String, fraction: Double, fill: Color, valueColor: Color) -> some View {
        VStack(alignment: .leading, spacing: VoCalTheme.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: VoCalTheme.Spacing.s) {
                Text(title)
                    .font(VoCalTheme.Fonts.secondaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
                Spacer(minLength: 0)
                Text(value)
                    .font(.system(size: 17, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(valueColor)
                Text(unit)
                    .font(VoCalTheme.Fonts.formLabel)
                    .monospacedDigit()
                    .foregroundStyle(VoCalTheme.Colors.muted)
            }
            MicroBar(fraction: fraction, fill: fill)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value) \(unit). \(detail)")
    }

    private func barFill(_ panel: TodayPanel) -> Color {
        if panel.knownDirection == .stayUnder { return panel.over ? VoCalTheme.Colors.alert : VoCalTheme.Colors.ink.opacity(0.55) }
        if panel.complete { return VoCalTheme.Colors.optimal }
        switch panel.metric {
        case "protein": return VoCalTheme.Colors.protein
        case "carbs": return VoCalTheme.Colors.carbs
        case "fat": return VoCalTheme.Colors.fats
        default: return VoCalTheme.Colors.ink.opacity(0.55)
        }
    }
}

#Preview("Populated") {
    HomeView(model: TodayViewModel(service: MockTodayService(scenario: .populated)))
}

#Preview("Empty") {
    HomeView(model: TodayViewModel(service: MockTodayService(scenario: .empty)))
}
