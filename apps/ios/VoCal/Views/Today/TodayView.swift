import SwiftUI
import VoCalCore

/// Progress (DESIGN.md §Today; decisions 28 and 60; since 2026-11-06 the page behind the
/// home's summary card, decision 75): the week strip, the cards the server composed for the
/// person's mode (`PanelView`, one progress language), the week's budget and the one thing to
/// add. The day's meals live on the home's diary now; this page is the numbers. The five is
/// the method's dashboard (calories beside protein, over produce, water and fiber); habits
/// prints no number anywhere on the page; macros shows protein, carbs and fat as tiles. The
/// mode governs every printed number here (the Rams review, R8). Black/gold, VoCalTheme only.
struct TodayView: View {
    @State private var model: TodayViewModel
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
        onProfile: (() -> Void)? = nil,
        onClose: (() -> Void)? = nil
    ) {
        _model = State(initialValue: model ?? TodayViewModel())
        self.refreshToken = refreshToken
        self.onLogged = onLogged
        self.tour = tour
        self.onProfile = onProfile
        self.onClose = onClose
    }

    /// Present as a cover from the home's summary card: the header's close.
    var onClose: (() -> Void)?

    /// The first-run tour points at the profile circle, the calories card and the week strip.
    var tour: HelpTourModel?
    /// The profile circle opens Settings (the tab bar is gone, 2026-09-25).
    var onProfile: (() -> Void)?
    /// Apple Health's active energy for the day on screen, when connected (read on the
    /// phone, never sent anywhere); nil hides the line.
    @State private var burnedToday: Double?
    var body: some View {
        ZStack {
            VoCalTheme.Colors.background.ignoresSafeArea()
            content
        }
        .accessibilityIdentifier(A11y.Today.screen)
        .task(id: refreshToken) {
            await model.load()
            burnedToday = isToday ? await HealthKitService.shared.activeEnergyToday() : nil
            // The weekly budget shifts with every log (carry moves) — same refresh beat.
            await weekModel.load()
        }
        .sheet(isPresented: $showWeekBudget) {
            WeekBudgetView(model: weekModel)
        }
        .sheet(isPresented: $showProfileEditor, onDismiss: {
            // The editor may have just rebuilt the protocol — pull the real targets
            // immediately so the starter banner clears without an app restart.
            Task { await model.load() }
        }) {
            NavigationStack { ProfileSettingsView(printsNumbers: printsNumbers) }
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
                if data.targetsAreStub { starterTargetsBanner }
                panelsSection(data)
                if let guidance = data.guidance {
                    GuidanceCard(guidance: guidance)
                }
                // Habits has no budget to show; the strip's dots are its record (spec 6.4).
                if data.showsWeekCard {
                    WeeklyBudgetCard(model: weekModel) { showWeekBudget = true }
                }
                // The day's meals are the home's diary (2026-11-06); here the day is its numbers.
                // Without them the page says what it is for.
                if data.meals.isEmpty, data.printsNumbers {
                    Text("Nothing logged \(isToday ? "yet today" : "that day").")
                        .font(VoCalTheme.Fonts.secondaryLabel)
                        .foregroundStyle(VoCalTheme.Colors.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, VoCalTheme.Spacing.m)
                }
            }
            .padding(.horizontal, VoCalTheme.Spacing.l)
            .padding(.top, VoCalTheme.Spacing.m)
            .padding(.bottom, VoCalTheme.Spacing.xxl)
        }
        .frostedStatusBar()
        // The day's numbers on demand, the way every list on the phone refreshes.
        .refreshable {
            await model.load()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: VoCalTheme.Spacing.m) {
            VStack(alignment: .leading, spacing: VoCalTheme.Spacing.xs) {
                // Another day is named by its date, never "That day" (a placeholder word).
                Text(isToday ? "Today, \(model.selectedDate.formatted(.dateTime.month().day()))" : model.selectedDate.formatted(.dateTime.weekday(.wide).month().day()))
                    .font(VoCalTheme.Fonts.formLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
                Text("Progress")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(VoCalTheme.Colors.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(VoCalTheme.Colors.ink)
                        .frame(width: 44, height: 44)
                        .liquidGlass(in: Circle(), tint: CaptureBar.dropletFace, interactive: true)
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel("Close")
                .accessibilityIdentifier("progress.close")
            } else if let onProfile {
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
