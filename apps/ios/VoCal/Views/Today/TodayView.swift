import SwiftUI
import VoCalCore

/// Home dashboard (DESIGN.md §Today; decisions 28 and 60): the cards the server composed for
/// the person's mode (`PanelView`, one progress language), then the day's logged meals. The
/// five is the method's dashboard (calories beside protein, over produce, water and fiber);
/// habits prints no number anywhere on the page; macros shows protein, carbs and fat as tiles.
/// The mode governs every printed number here: the cards, the rows, the chips, the week card
/// and the Health line (the Rams review, R8). Black/gold, VoCalTheme tokens only.
struct TodayView: View {
    @State private var model: TodayViewModel
    @State private var showCheckIn = false
    /// Presents the Profile editor from the starter-targets banner (stub targets showing).
    @State private var showProfileEditor = false
    /// Presents the manual water quick-add sheet (tapping the Water micro-tile).
    @State private var showAddWater = false
    /// The plan builder, from the plan card (meal-plan mode, decision 65).
    @State private var showPlanBuilder = false
    /// A water add that did NOT land — the sheet dismisses optimistically, so this alert is the
    /// only honest signal (field bug 2026-07: failed adds were silent and read as "water logging
    /// is broken"). Holds the honest reason (server rejection vs transport), not a blanket
    /// "check your connection" — non-nil presents the alert.
    @State private var waterAddError: String?
    /// A context-menu meal delete the server rejected — same honesty rule as water.
    @State private var deleteFailed = false
    /// A one-tap re-log that did NOT land. There is no optimistic row for it (the meal appears
    /// only once the server's row comes back), so this alert is the only signal the tap failed.
    /// Carries the honest reason, not a blanket "check your connection".
    @State private var usualLogError: String?
    /// A "Remove from usuals" the server rejected — the chip stays, so say why.
    @State private var usualRemoveFailed = false
    /// An invitation's answer that did not land (the preference write failed): the card stays
    /// and this says why, instead of a silent no-op that reads as a broken button.
    @State private var invitationError: String?
    /// The logged meal currently being edited (tapping a meal row). String wrapped so it can
    /// drive `.sheet(item:)`.
    @State private var editingMeal: EditingMeal?
    /// The unfinished recording being resumed (drives the resume `.fullScreenCover(item:)`).
    @State private var resuming: ResumeCapture?
    /// The week strip's displacement while a horizontal pull is in progress (snaps back).
    @State private var weekPullOffset: CGFloat = 0
    @State private var weekPullArmed = false
    /// The weekly budget (shared by the compact card and the full sheet so both stay
    /// in sync). Off the capture path: purely a Today-surface concern.
    @State private var weekModel = WeekBudgetViewModel()
    @State private var showWeekBudget = RuntimeMode.showsWeekBudgetOnLaunch
    /// Pages the WeekStrip's trailing 7-day window back through history; 0 = the window ending
    /// today, -1 = the 7 days before that, etc. (R6 beta feedback: history was hard-capped at 7
    /// days even though the server and TodayViewModel already accept any date.) Paging never
    /// touches `model.selectedDate` on its own — a selection outside the visible window just
    /// scrolls off the strip, same as iOS's own calendar-strip behavior.
    @State private var weekOffset = 0

    /// `displayName` is what the row shows ("Meal 2" or the meal's name) — the edit sheet's
    /// add-by-voice flow says exactly what the items will join.
    private struct EditingMeal: Identifiable { let id: String; let displayName: String }
    private struct ResumeCapture: Identifiable { let id: String }
    /// Bumped by the app shell after a meal is logged so Today refreshes with the new meal.
    var refreshToken: Int
    /// A meal was logged from a sheet Today presented itself (resuming an unfinished
    /// recording): the shell's post-log beat, same as the mic button's.
    var onLogged: (() -> Void)?

    init(
        model: TodayViewModel? = nil,
        refreshToken: Int = 0,
        onLogged: (() -> Void)? = nil,
        tour: HelpTourModel? = nil,
        onProfile: (() -> Void)? = nil
    ) {
        _model = State(initialValue: model ?? TodayViewModel())
        self.refreshToken = refreshToken
        self.onLogged = onLogged
        self.tour = tour
        self.onProfile = onProfile
    }

    /// The first-run tour points at the profile circle, the calories card and the week strip.
    var tour: HelpTourModel?
    /// The profile circle opens Settings (the tab bar is gone, 2026-09-25).
    var onProfile: (() -> Void)?
    /// Apple Health's active energy for the day on screen, when connected (read on the
    /// phone, never sent anywhere); nil hides the line.
    @State private var burnedToday: Double?
    /// What the rename alert is naming: a logged meal from its row, or a usual from its chip
    /// (Lorenzo, 2026-09-24: usuals are named the same way as the meals logged today).
    private enum RenameTarget: Identifiable {
        case meal(TodayMealRow)
        case usual(SavedMeal)

        var id: String {
            switch self {
            case let .meal(meal): "meal-\(meal.id)"
            case let .usual(usual): "usual-\(usual.id)"
            }
        }

        var title: String {
            switch self {
            case .meal: "Name this meal"
            case .usual: "Rename this usual"
            }
        }

        var message: String {
            switch self {
            case .meal: "Vo-Cal will offer it by this name from now on."
            case .usual: "The chip and the offer will use this name from now on."
            }
        }
    }

    @State private var renaming: RenameTarget?
    @State private var renameText = ""
    /// Why the last rename did not save; nil when it did.
    @State private var renameError: String?

    var body: some View {
        ZStack {
            VoCalTheme.Colors.background.ignoresSafeArea()
            content
        }
        .accessibilityIdentifier(A11y.Today.screen)
        .task(id: refreshToken) {
            await model.load()
            burnedToday = isToday ? await HealthKitService.shared.activeEnergyToday() : nil
            // Smart nudges re-plan whenever Today gains fresh context (open / post-log).
            // Off the capture path: purely a Today-surface concern.
            NudgeCenter.shared.refresh()
            // The weekly budget shifts with every log (carry moves) — same refresh beat.
            await weekModel.load()
        }
        .sheet(isPresented: $showWeekBudget) {
            WeekBudgetView(model: weekModel)
        }
        .sheet(isPresented: $showCheckIn) {
            CheckInView { applied in
                model.dismissCheckin()
                if applied { Task { await model.load() } }
            }
        }
        .sheet(item: $editingMeal) { editing in
            LoggedMealEditView(mealID: editing.id, displayName: editing.displayName, model: model)
        }
        .fullScreenCover(item: $resuming, onDismiss: {
            // Logged, discarded or closed again: the list is re-derived either way.
            Task { await model.loadUnfinished() }
        }) { capture in
            VoiceLogView(
                targetDate: model.selectedDate,
                resumeCaptureID: capture.id,
                onLogged: { onLogged?() }
            )
        }
        .sheet(isPresented: $showProfileEditor, onDismiss: {
            // The editor may have just rebuilt the protocol — pull the real targets
            // immediately so the starter banner clears without an app restart.
            Task { await model.load() }
        }) {
            NavigationStack { ProfileSettingsView() }
        }
        .sheet(isPresented: $showPlanBuilder, onDismiss: {
            // The plan may have changed; the card's ticks are the server's, so reload the day.
            Task { await model.load() }
        }) {
            NavigationStack {
                PlanBuilderView(presentation: .page(onClose: { showPlanBuilder = false }))
            }
        }
        .sheet(isPresented: $showAddWater) {
            AddWaterSheet { oz in
                Task {
                    if let failure = await model.addWater(oz: oz) {
                        waterAddError = failure
                    } else {
                        // Water is a nudge signal too (hydration patterns) — re-plan on it.
                        NudgeCenter.shared.logCompleted()
                    }
                }
            }
                .presentationDetents([.medium])
        }
        .alert(
            "Water not logged",
            isPresented: Binding(get: { waterAddError != nil }, set: { if !$0 { waterAddError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(waterAddError ?? "")
        }
        .alert(renaming?.title ?? "Name this meal", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { target in
            TextField("Metal detox smoothie", text: $renameText)
                .accessibilityIdentifier(A11y.Today.renameField)
            Button("Save") {
                let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                Task {
                    do {
                        switch target {
                        case let .meal(meal): try await model.renameMeal(meal.id, name: name)
                        case let .usual(usual): try await model.renameUsual(usual.id, name: name)
                        }
                        VoCalHaptics.success()
                    } catch {
                        renameError = TodayViewModel.renameFailureMessage(for: error)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { target in
            Text(target.message)
        }
        .alert(
            "Name not saved",
            isPresented: Binding(get: { renameError != nil }, set: { if !$0 { renameError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(renameError ?? "")
        }
        .alert("Meal not deleted", isPresented: $deleteFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The delete didn't reach the server. Check your connection and try again.")
        }
        .alert(
            "Meal not logged",
            isPresented: Binding(get: { usualLogError != nil }, set: { if !$0 { usualLogError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(usualLogError ?? "")
        }
        .alert("Usual not removed", isPresented: $usualRemoveFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The remove didn't reach the server. Check your connection and try again.")
        }
        .alert(
            "Not changed",
            isPresented: Binding(get: { invitationError != nil }, set: { if !$0 { invitationError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(invitationError ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading where model.dashboard == nil:
            VoCalLoader(size: 48)
        case let .failed(message):
            failure(message)
        default:
            dashboard(model.dashboard ?? MockTodayService.empty(date: model.selectedDate))
        }
    }

    // MARK: - Dashboard

    private func dashboard(_ data: TodayDashboard) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VoCalTheme.Spacing.l) {
                header
                weekStripSection
                    .helpTourTarget(HelpTourStep.Home.week, in: tour)
                if model.checkinDue { checkinBanner }
                // The permission, once, in the person's own sentence (decision 67): after the
                // first log, so it sits above a day with meals; never for "Nothing".
                if NudgeCenter.shared.permissionAskPending, NudgeCenter.shared.level != .off {
                    NotificationPermissionCard(
                        level: NudgeCenter.shared.level,
                        onAllow: { Task { await NudgeCenter.shared.allowNotifications() } },
                        onNotNow: { NudgeCenter.shared.declineNotificationAsk() }
                    )
                }
                // A tip belongs to an empty day; on a day with meals the numbers lead
                // (the populated page opened with "Nothing logged yet", critic 2026-09-24).
                if data.meals.isEmpty, let nudge = NudgeCenter.shared.currentCard {
                    NudgeCardView(
                        card: nudge,
                        onDismiss: { NudgeCenter.shared.dismissCurrent() },
                        onAccept: { answerInvitation(nudge, accept: true) },
                        onDeclineForever: { answerInvitation(nudge, accept: false) },
                        onReport: { kind in NudgeCenter.shared.report(nudge, kind) }
                    )
                }
                if data.targetsAreStub { starterTargetsBanner }
                panelsSection(data)
                // Habits has no budget to show; the strip's dots are its record (spec 6.4).
                if data.showsWeekCard {
                    WeeklyBudgetCard(model: weekModel) { showWeekBudget = true }
                }
                usualsRow
                if !model.unfinished.isEmpty { unfinishedSection }
                loggedSection(data)
            }
            .padding(.horizontal, VoCalTheme.Spacing.l)
            .padding(.top, VoCalTheme.Spacing.m)
            .padding(.bottom, VoCalTheme.Spacing.xl) // the capture bar is a safe-area inset
        }
        .frostedStatusBar()
        // The day's numbers on demand, the way every list on the phone refreshes.
        .refreshable {
            await model.load()
            await model.loadUnfinished()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: VoCalTheme.Spacing.m) {
            VStack(alignment: .leading, spacing: VoCalTheme.Spacing.xs) {
                Text(model.selectedDate.formatted(.dateTime.weekday(.wide).month().day()))
                    .font(VoCalTheme.Fonts.formLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
                // Another day is named by its weekday, never "That day" (a placeholder word).
                Text(isToday ? "Today" : model.selectedDate.formatted(.dateTime.weekday(.wide)))
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(VoCalTheme.Colors.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
            if let onProfile {
                ProfileCircleButton(action: onProfile)
                    .helpTourTarget(HelpTourStep.Home.profile, in: tour)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Flanks WeekStrip with paging chevrons (R6: browse history further back). The strip
    // itself always renders a 7-day window — weekOffset only slides which window that is.
    // Left has no lower bound for the beta (server/TodayViewModel already accept any date);
    // right stops once the window reaches today, since paging past it would need future days
    // WeekStrip already refuses to select.
    private var weekStripSection: some View {
        VStack(alignment: .trailing, spacing: VoCalTheme.Spacing.xs) {
            HStack(spacing: VoCalTheme.Spacing.s) {
                weekChevronButton(
                    "chevron.left", identifier: A11y.Today.weekBack, label: "Previous week"
                ) {
                    withAnimation(.snappy(duration: 0.25)) { weekOffset -= 1 }
                }
                WeekStrip(days: weekDays, selected: dateBinding)
                weekChevronButton(
                    "chevron.right", identifier: A11y.Today.weekForward, label: "Next week",
                    isEnabled: weekOffset < 0
                ) {
                    withAnimation(.snappy(duration: 0.25)) { weekOffset += 1 }
                }
            }
            .offset(x: weekPullOffset)
            // A horizontal pull on the strip pages the week, the chevrons' gesture twin:
            // rightward pulls the previous week in, leftward the next while there is one.
            // HorizontalPull decides at the first movement, so the page's vertical scroll
            // never waits on it (Serein's lesson, in the type's comment).
            .gesture(HorizontalPull(direction: .forward) { phase, pulled in
                weekPull(phase, pulled, direction: .forward)
            })
            .gesture(HorizontalPull(direction: .backward, isEnabled: weekOffset < 0) { phase, pulled in
                weekPull(phase, pulled, direction: .backward)
            })
            if weekOffset != 0 {
                // The way home besides paging forward repeatedly — resets the window AND the
                // selection, so picking a day deep in the past doesn't strand the user there.
                VoCalButton(title: "Today", kind: .tertiary) {
                    withAnimation(.snappy(duration: 0.25)) { weekOffset = 0 }
                    Task { await model.select(.now) }
                }
                .accessibilityIdentifier(A11y.Today.jumpToday)
                .accessibilityLabel("Jump to today")
            }
        }
        .padding(.top, VoCalTheme.Spacing.xs)
    }

    /// Past this pull the page turns on release; the strip follows the finger with tanh
    /// damping up to the rail and snaps back either way. A light tick marks the arming.
    private static let weekPullThreshold: CGFloat = 56
    private static let weekPullRail: CGFloat = 72

    private func weekPull(_ phase: HorizontalPull.Phase, _ pulled: CGFloat, direction: HorizontalPull.Direction) {
        let sign: CGFloat = direction == .forward ? 1 : -1
        switch phase {
        case .began, .moved:
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                weekPullOffset = sign * Self.weekPullRail * tanh(pulled / Self.weekPullRail)
            }
            let armed = pulled >= Self.weekPullThreshold
            if armed != weekPullArmed {
                weekPullArmed = armed
                if armed { VoCalHaptics.pullArmed() }
            }
        case .ended:
            let turns = pulled >= Self.weekPullThreshold
            withAnimation(.snappy(duration: 0.25)) {
                weekPullOffset = 0
                if turns { weekOffset += direction == .forward ? -1 : 1 }
            }
            weekPullArmed = false
        }
    }

    // Icon-only paging control: muted (secondary to the strip itself), same press feedback
    // (PressableButtonStyle) the rest of the button system uses.
    private func weekChevronButton(
        _ systemName: String, identifier: String, label: String, isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(VoCalTheme.Colors.muted)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(label)
    }

    // Weekly check-in banner (G1) — shown only when due, on the current day. Two
    // separate buttons (open / snooze), NOT a nested control inside one Button:
    // the outer button would swallow the snooze tap. "Later" mutes the banner for
    // two days without losing the check-in (it stays due server-side).
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

    /// Shown while /meals/today serves stub targets (no active protocol). Presenting the
    /// placeholder 2000 kcal / 120 g as if it were a prescription was the 2026-08-19 field
    /// incident ("suspiciously round numbers") — the one screen that most needed the
    /// targets_are_stub flag never read it. Facts-first: name the state, offer the fix.
    /// No dismiss on purpose: it clears itself the moment a real protocol exists.
    private var starterTargetsBanner: some View {
        Button { showProfileEditor = true } label: {
            HStack(spacing: VoCalTheme.Spacing.m) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(VoCalTheme.Colors.gold)
                VStack(alignment: .leading, spacing: 1) {
                    Text("You're on starter targets")
                        .font(VoCalTheme.Fonts.primaryLabel)
                        .foregroundStyle(VoCalTheme.Colors.ink)
                    Text("These numbers aren't yours yet. Build your protocol from your own stats.")
                        .font(VoCalTheme.Fonts.formLabel)
                        .foregroundStyle(VoCalTheme.Colors.muted)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(VoCalTheme.Colors.muted)
            }
            .padding(VoCalTheme.Spacing.l)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            VoCalTheme.Colors.gold.opacity(0.12),
            in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.card, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: VoCalTheme.Radius.card, style: .continuous)
                .strokeBorder(VoCalTheme.Colors.gold.opacity(0.35), lineWidth: 1)
        )
        .accessibilityIdentifier(A11y.Today.starterTargetsBanner)
    }

    // MARK: - Panels

    /// The cards the server composed for the mode (decision 60): the heroes first (the
    /// calories card, with protein beside it in the five), then the tiles, three to a row,
    /// wrapping at four. The calories card carries the tour's "Your day" step; in a mode
    /// without one the step is skipped, since the tour shows only the controls on screen.
    @ViewBuilder
    private func panelsSection(_ data: TodayDashboard) -> some View {
        let arrangement = PanelLayout.arrange(data.panelsToDraw, mode: data.mode)
        // The plan card (meal-plan mode): full width, first, the one card with a tap.
        ForEach(arrangement.fullWidth) { panel in
            PanelView(panel: panel, size: .hero, onOpenPlan: { showPlanBuilder = true })
        }
        if !arrangement.heroes.isEmpty {
            // Two heroes of one structure and one height: `fixedSize` gives the row the
            // taller card's height and both fill it (Lorenzo, build 30).
            HStack(alignment: .top, spacing: VoCalTheme.Spacing.m) {
                ForEach(arrangement.heroes) { panel in
                    PanelView(
                        panel: panel,
                        size: .hero,
                        supportSuffix: panel.knownKind == .caloriesLeft ? burnedSuffix(data) : nil
                    )
                    .frame(maxHeight: .infinity, alignment: .top)
                    .helpTourTarget(HelpTourStep.Home.calories, in: panel.knownKind == .caloriesLeft ? tour : nil)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        ForEach(Array(arrangement.tileRows.enumerated()), id: \.offset) { _, row in
            HStack(alignment: .top, spacing: VoCalTheme.Spacing.s) {
                ForEach(row) { panel in
                    // The tap lands only on the tile the server marked `can_add` (water);
                    // PanelView attaches it nowhere else.
                    PanelView(panel: panel, onAdd: { showAddWater = true })
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "320 burned": what Apple Health counted today, appended to the calories card's line.
    /// Informational: the target already carries the person's inferred activity (decision
    /// 36), so burned calories never raise it. Hidden with every other number in habits mode.
    private func burnedSuffix(_ data: TodayDashboard) -> String? {
        guard data.printsNumbers, let burnedToday, burnedToday > 0 else { return nil }
        return "\(DashboardNumber.whole(burnedToday)) burned"
    }

    /// Yes or "Don't offer this again" on an invitation (decision 62). The card goes only once
    /// the preference write landed; a yes reloads the day in its new mode.
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

    // MARK: - Usuals

    /// Saved meals as chips: tap re-logs one onto the selected day, long-press forgets it.
    /// Renders ONLY when usuals exist — an empty row plus a header would be clutter on a home
    /// screen whose job is to stay calm (decision #28), and the save-as-usual toggle on the
    /// voice-log result is the only way this row comes into being.
    @ViewBuilder
    private var usualsRow: some View {
        if !model.usuals.isEmpty {
            VStack(alignment: .leading, spacing: VoCalTheme.Spacing.s) {
                // The same title face as "Logged today": one section language on the page.
                Text("Usuals")
                    .font(VoCalTheme.Fonts.primaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.ink)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: VoCalTheme.Spacing.s) {
                        ForEach(model.usuals) { usual in
                            usualChip(usual)
                        }
                    }
                    // Room for PressableButtonStyle's scale so a pressed chip isn't clipped.
                    .padding(.vertical, 2)
                    .padding(.horizontal, VoCalTheme.Spacing.l)
                }
                // Edge to edge: a chip cut at the content margin read as broken (critic,
                // 2026-09-25); the row now runs under the margins and clips at the screen.
                .padding(.horizontal, -VoCalTheme.Spacing.l)
            }
            .accessibilityIdentifier(A11y.Today.usualsRow)
        }
    }

    private func usualChip(_ usual: SavedMeal) -> some View {
        let isLogging = model.loggingUsualID == usual.id
        let isBlocked = model.loggingUsualID != nil && !isLogging
        return Button {
            Task {
                if let failure = await model.logUsual(usual) {
                    usualLogError = failure
                } else {
                    // A re-log is a log: the nudge planner re-plans on it like any other.
                    NudgeCenter.shared.logCompleted()
                }
            }
        } label: {
            ZStack {
                // Keep the label in the layout while logging so the chip doesn't resize
                // mid-flight (VoCalButton's loading recipe).
                HStack(spacing: VoCalTheme.Spacing.xs) {
                    Text(usual.name)
                        .font(VoCalTheme.Fonts.chipLabel)
                        .foregroundStyle(VoCalTheme.Colors.ink)
                        .lineLimit(1)
                    if printsNumbers {
                        Text("· \(DashboardNumber.whole(usual.kcal)) cal")
                            .font(VoCalTheme.Fonts.chipLabel)
                            .monospacedDigit()
                            .foregroundStyle(VoCalTheme.Colors.muted)
                            .lineLimit(1)
                    }
                }
                .opacity(isLogging ? 0 : 1)
                if isLogging {
                    VoCalLoader(size: 18)
                }
            }
            .padding(.horizontal, VoCalTheme.Spacing.l)
            .frame(height: 44)
            .background(
                VoCalTheme.Colors.card,
                in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.chip, style: .continuous)
            )
            .contentShape(
                RoundedRectangle(cornerRadius: VoCalTheme.Radius.chip, style: .continuous)
            )
        }
        .buttonStyle(PressableButtonStyle())
        // One re-log at a time: the others dim rather than queueing a second POST.
        .disabled(model.loggingUsualID != nil)
        .opacity(isBlocked ? 0.45 : 1)
        .accessibilityIdentifier(A11y.Today.usualChip)
        .accessibilityLabel(printsNumbers ? "Log \(usual.name), \(DashboardNumber.whole(usual.kcal)) calories" : "Log \(usual.name)")
        // Press and hold: rename it the way a logged meal is named, or forget it.
        .contextMenu {
            Button {
                renameText = usual.name
                renaming = .usual(usual)
            } label: {
                Label("Rename", systemImage: "character.cursor.ibeam")
            }
            Button(role: .destructive) {
                Task {
                    do { try await model.deleteUsual(usual.id) } catch { usualRemoveFailed = true }
                }
            } label: {
                Label("Remove from usuals", systemImage: "trash")
            }
        }
    }

    // MARK: - Logged today

    @ViewBuilder
    private func loggedSection(_ data: TodayDashboard) -> some View {
        HStack {
            Text("Logged today")
                .font(VoCalTheme.Fonts.primaryLabel)
                .foregroundStyle(VoCalTheme.Colors.ink)
            // The "avg N% sure" badge that sat here went with decision 68 (the Rams review's
            // F6): the system grading its own confidence in the person's day, in the person's
            // slot. The per-meal badge stays on the result, where it is acted on.
            Spacer()
        }
        .padding(.top, VoCalTheme.Spacing.s)

        if data.meals.isEmpty {
            emptyState
        } else {
            VStack(spacing: VoCalTheme.Spacing.m) {
            ForEach(data.meals) { meal in
                let rowName = meal.name ?? "Meal"
                mealRow(meal)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        VoCalHaptics.tap()
                        editingMeal = EditingMeal(id: meal.id, displayName: rowName)
                    }
                    // Right to edit, left to delete; press and hold for the menu (2026-09-24).
                    .swipeable(
                        onEdit: { editingMeal = EditingMeal(id: meal.id, displayName: rowName) },
                        onDelete: {
                            Task {
                                do { try await model.deleteMeal(meal.id) } catch { deleteFailed = true }
                            }
                        }
                    )
                    .contextMenu {
                        Button { editingMeal = EditingMeal(id: meal.id, displayName: rowName) } label: {
                            Label("Edit meal", systemImage: "pencil")
                        }
                        Button {
                            renameText = meal.name ?? ""
                            renaming = .meal(meal)
                        } label: {
                            Label("Name this meal", systemImage: "character.cursor.ibeam")
                        }
                        Button(role: .destructive) {
                            Task {
                                do { try await model.deleteMeal(meal.id) } catch { deleteFailed = true }
                            }
                        } label: {
                            Label("Delete meal", systemImage: "trash")
                        }
                    }
                    .accessibilityIdentifier(A11y.Today.mealRow)
            }
            }
        }
    }

    /// Recordings saved on this day that never reached "Logged" (the sheet was closed, the
    /// network was gone). Tap resumes the derived pipeline from the committed audio; discard
    /// is a mark, the audio stays. Nothing here is a claim above proof: "saved" is the
    /// outbox row, "not logged" is the absence of an outcome.
    private var unfinishedSection: some View {
        VStack(alignment: .leading, spacing: VoCalTheme.Spacing.s) {
            Text("Unfinished")
                .font(VoCalTheme.Fonts.primaryLabel)
                .foregroundStyle(VoCalTheme.Colors.ink)
                .padding(.top, VoCalTheme.Spacing.s)
            ForEach(model.unfinished) { capture in
                unfinishedRow(capture)
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

    private func unfinishedRow(_ capture: UnfinishedCapture) -> some View {
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
    }

    /// A logged meal: its name (the server names every meal after what was eaten), the meal
    /// slot and time, the calories. No glyph: four forks in a row said nothing (critic,
    /// 2026-09-24).
    private func mealRow(_ meal: TodayMealRow) -> some View {
        HStack(alignment: .center, spacing: VoCalTheme.Spacing.m) {
            VStack(alignment: .leading, spacing: 3) {
                Text(meal.name ?? "Meal")
                    .font(VoCalTheme.Fonts.primaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.ink)
                    .lineLimit(1)
                Text(Self.mealSubtitle(meal))
                    .font(VoCalTheme.Fonts.formLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
            }
            Spacer(minLength: VoCalTheme.Spacing.m)
            // In habits mode the row is the meal, its slot and its time; no number (spec 6.4).
            if printsNumbers {
                Text(DashboardNumber.whole(meal.kcal))
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(VoCalTheme.Colors.ink)
            }
        }
        .padding(.horizontal, VoCalTheme.Spacing.l)
        .padding(.vertical, VoCalTheme.Spacing.m)
        .frame(minHeight: 64)
        .background(VoCalTheme.Colors.card, in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.row, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: VoCalTheme.Radius.row, style: .continuous))
    }

    /// "Lunch · 12:40 PM", or just the time when the slot was never named.
    private static func mealSubtitle(_ meal: TodayMealRow) -> String {
        let time = meal.loggedAt.formatted(date: .omitted, time: .shortened)
        let slot: String?
        switch meal.mealType {
        case "breakfast": slot = "Breakfast"
        case "lunch": slot = "Lunch"
        case "dinner": slot = "Dinner"
        case "snack": slot = "Snack"
        default: slot = nil
        }
        return slot.map { "\($0) · \(time)" } ?? time
    }

    /// No glyph: the mic is right there in the bar, and a second one competed with it.
    private var emptyState: some View {
        VStack(spacing: VoCalTheme.Spacing.xs) {
            Text("No meals yet")
                .font(VoCalTheme.Fonts.primaryLabel)
                .foregroundStyle(VoCalTheme.Colors.ink)
            Text("Say what you had, or type it.")
                .font(VoCalTheme.Fonts.secondaryLabel)
                .foregroundStyle(VoCalTheme.Colors.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, VoCalTheme.Spacing.xl)
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: VoCalTheme.Spacing.l) {
            Text(message)
                .font(VoCalTheme.Fonts.primaryLabel)
                .foregroundStyle(VoCalTheme.Colors.ink)
            PillButton(title: "Try again") { Task { await model.load() } }
                .padding(.horizontal, VoCalTheme.Spacing.xxl)
        }
        .padding(VoCalTheme.Spacing.xl)
    }

    // MARK: - Helpers

    private var isToday: Bool { Calendar.current.isDateInToday(model.selectedDate) }

    /// Whether the page prints calories and macros: the server's answer for the loaded day
    /// (false only in habits mode); a day not yet loaded prints them.
    private var printsNumbers: Bool { model.dashboard?.printsNumbers ?? true }

    private var weekDays: [Date] {
        let cal = Calendar.current
        // weekOffset slides the trailing 7-day window in whole-week jumps; the window itself
        // is still "the 7 days ending at the anchor" so day-of-week alignment never shifts.
        let anchor = cal.date(byAdding: .day, value: weekOffset * 7, to: .now) ?? .now
        return (-6...0).compactMap { cal.date(byAdding: .day, value: $0, to: anchor) }
    }

    private var dateBinding: Binding<Date> {
        Binding(
            get: { model.selectedDate },
            set: { newValue in Task { await model.select(newValue) } }
        )
    }

}

#Preview("Populated") {
    TodayView(model: TodayViewModel(service: MockTodayService(scenario: .populated)))
}

#Preview("Empty") {
    TodayView(model: TodayViewModel(service: MockTodayService(scenario: .empty)))
}
