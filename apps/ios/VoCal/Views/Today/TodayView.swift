import SwiftUI
import VoCalCore

/// Home dashboard (DESIGN.md §Today + decision #28): a split Calories-left | Protein card
/// over a produce/water/fiber micronutrient-minimum row, then the day's logged meals. Carbs
/// and fat are deliberately NOT here (they live on meal detail) — the home stays calm and
/// shows only the five pillars Francesco coaches to. Black/gold, VoCalTheme tokens only.
struct TodayView: View {
    @State private var model: TodayViewModel
    @State private var showCheckIn = false
    /// Presents the Profile editor from the starter-targets banner (stub targets showing).
    @State private var showProfileEditor = false
    /// Presents the manual water quick-add sheet (tapping the Water micro-tile).
    @State private var showAddWater = false
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
    /// A meal being renamed from its row (context menu or the edit swipe's menu).
    @State private var renaming: TodayMealRow?
    @State private var renameText = ""
    @State private var renameFailed = false

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
                        renameFailed = true
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Vo-Cal will offer it by this name from now on.")
        }
        .alert("Name not saved", isPresented: $renameFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The name didn't reach the server. Check your connection and try again.")
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
                // A tip belongs to an empty day; on a day with meals the numbers lead
                // (the populated page opened with "Nothing logged yet", critic 2026-09-24).
                if data.meals.isEmpty, let nudge = NudgeCenter.shared.currentCard {
                    NudgeCardView(card: nudge) { NudgeCenter.shared.dismissCurrent() }
                }
                if data.targetsAreStub { starterTargetsBanner }
                splitCard(data)
                microsRow(data)
                WeeklyBudgetCard(model: weekModel) { showWeekBudget = true }
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
            VStack(alignment: .leading, spacing: 2) {
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

    // Split top card: Calories left | Protein (optimal-range bar).
    private func splitCard(_ data: TodayDashboard) -> some View {
        HStack(spacing: VoCalTheme.Spacing.m) {
            StatCard(isComplete: caloriesComplete(data)) {
                CardHeader(
                    title: "Calories left",
                    isComplete: caloriesComplete(data),
                    support: burnedLine ?? "of \(intString(data.targets.kcal)) today"
                ) {
                    Text(intString(data.remaining.kcal))
                        .font(VoCalTheme.Fonts.numeral(42))
                        .monospacedDigit()
                        // Tighten the tabular-digit advance (monospacedDigit spaces digits wide);
                        // -1.5 shaves the gap without clipping the trailing digit's bearing the
                        // way -3 did (the -3 + no fit-guard was the "calories cut off" report).
                        .tracking(-1.5)
                        // The card is one half of a 50/50 split; a 4-digit value ("2,255") or a
                        // negative over-budget value ("-320") overran the width and truncated.
                        // Scale-to-fit on one line instead of clipping — the number always shows.
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .foregroundStyle(VoCalTheme.Colors.gold)
                        .accessibilityIdentifier(A11y.Today.caloriesLeft)
                }
            }
            .frame(maxHeight: .infinity)
            .helpTourTarget(HelpTourStep.Home.calories, in: tour)
            StatCard(isComplete: proteinComplete(data)) {
                let status = proteinStatus(data)
                CardHeader(title: "Protein", isComplete: proteinComplete(data)) {
                    VStack(alignment: .leading, spacing: VoCalTheme.Spacing.s) {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(intString(data.consumed.protein))
                                .font(VoCalTheme.Fonts.numeral(34))
                                .monospacedDigit()
                                // Same fit-guard as the calories numeral: a 3-digit gram value plus
                                // the "g" suffix in this half-card must scale, not truncate.
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                                .foregroundStyle(VoCalTheme.Colors.ink)
                            Text("g")
                                .font(VoCalTheme.Fonts.secondaryLabel)
                                .foregroundStyle(VoCalTheme.Colors.muted)
                        }
                        ProteinRangeBar(
                            consumed: data.consumed.protein,
                            low: proteinBandLow(data),
                            high: proteinBandHigh(data)
                        )
                        Text(status.text)
                            .font(VoCalTheme.Fonts.formLabel)
                            .foregroundStyle(status.color)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    /// "of 2,040 today · 320 burned": what Apple Health counted today, beside the target.
    /// Informational: the target already carries the person's inferred activity (decision
    /// 36), so burned calories never raise it.
    private var burnedLine: String? {
        guard let burnedToday, burnedToday > 0, let data = model.dashboard else { return nil }
        return "of \(intString(data.targets.kcal)) today · \(intString(burnedToday)) burned"
    }

    // Protein band, with a safe fallback to the target (a zero-width "point") when the active
    // protocol predates the band or is the pre-onboarding stub (server sends 0 → we show a goal,
    // not a misleading 0–0 range). The numbers themselves are engine-owned (AGENTS.md #6).
    private func proteinBandLow(_ d: TodayDashboard) -> Double {
        d.proteinMin > 0 ? d.proteinMin : d.targets.protein
    }

    private func proteinBandHigh(_ d: TodayDashboard) -> Double {
        d.proteinMax > 0 ? d.proteinMax : d.targets.protein
    }

    // Strength-based, non-nagging status (decision #28): under = "more to go" (neutral, not a
    // failure), in-range = the optimal green, over = a calm "over optimal" note. The bar carries
    // the color signal; the text stays calm.
    private func proteinStatus(_ d: TodayDashboard) -> (text: String, color: Color) {
        let consumed = d.consumed.protein
        let lo = proteinBandLow(d)
        let hi = proteinBandHigh(d)
        guard hi > lo else {
            return ("of \(intString(hi))g goal", VoCalTheme.Colors.muted)
        }
        if consumed < lo {
            return ("\(intString(lo - consumed))g to optimal", VoCalTheme.Colors.muted)
        }
        if consumed > hi {
            return ("\(intString(consumed - hi))g over optimal", VoCalTheme.Colors.muted)
        }
        return ("In your optimal range", VoCalTheme.Colors.optimal)
    }

    // "Complete" = the goal for this tile is met — the ring-close win that turns the box green.
    // Honest per-metric rules so it's a real win, not a participation trophy.

    // Protein (bounded band): met when consumed is INSIDE [min, max]; overshoot is not complete.
    private func proteinComplete(_ d: TodayDashboard) -> Bool {
        let lo = proteinBandLow(d), hi = proteinBandHigh(d)
        if hi > lo { return d.consumed.protein >= lo && d.consumed.protein <= hi }
        return d.targets.protein > 0 && d.consumed.protein >= d.targets.protein
    }

    // Calories are a BUDGET, not more-is-merrier: met when you land in the target zone
    // (~90–105% of target). Under = still fueling; well over = over budget — neither is the win.
    private func caloriesComplete(_ d: TodayDashboard) -> Bool {
        let target = d.targets.kcal
        return target > 0 && d.consumed.kcal >= target * 0.9 && d.consumed.kcal <= target * 1.05
    }

    // More-is-merrier minimums (produce/water/fiber): met when consumed reaches the target; staying
    // green past it (like a closed ring) is correct.
    private func microComplete(_ consumed: Double, _ target: Double) -> Bool {
        target > 0 && consumed >= target
    }

    // Produce · Water · Fiber — micronutrient-minimum cards with a neutral fill bar
    // (macro colors are reserved for macros, so these stay ink-neutral; decision #28).
    //
    // Only Water is interactive (tap → manual add). Water is a standalone hydration tally
    // (POST /meals/water) you fill without "eating", so a displayed target with no entry point
    // is a real gap. Produce + Fiber are DERIVED server-side from the food you log by voice —
    // there is no independent produce/fiber entry to make — so those tiles are display-only by
    // design, not a missing input. (Audit note, 2026-07: don't re-flag these as dead.)
    private func microsRow(_ data: TodayDashboard) -> some View {
        HStack(spacing: VoCalTheme.Spacing.s) {
            micro("Produce", consumed: data.consumed.produce, target: data.targets.produce, unit: "")
            micro("Water", consumed: data.consumed.water, target: data.targets.water, unit: " oz",
                  onAdd: { showAddWater = true })
            micro("Fiber", consumed: data.consumed.fiber, target: data.targets.fiber, unit: " g")
        }
    }

    private func micro(
        _ label: String, consumed: Double, target: Double, unit: String,
        onAdd: (() -> Void)? = nil
    ) -> some View {
        let done = microComplete(consumed, target)
        return StatCard(isComplete: done, radius: VoCalTheme.Radius.row, padding: VoCalTheme.Spacing.m) {
            CardHeader(title: label, isComplete: done) {
                VStack(alignment: .leading, spacing: VoCalTheme.Spacing.s) {
                    HStack(spacing: 0) {
                        Text(trimString(consumed)).foregroundStyle(done ? VoCalTheme.Colors.optimal : VoCalTheme.Colors.ink)
                        Text(" / \(trimString(target))\(unit)").foregroundStyle(VoCalTheme.Colors.muted)
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    MicroBar(fraction: target > 0 ? consumed / target : 0, complete: done)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if onAdd != nil, !done {
                // The "+" is the affordance that tells this tile apart from the display-only
                // ones — tap anywhere on the card to add.
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(VoCalTheme.Colors.gold)
                    .padding(VoCalTheme.Spacing.s)
            }
        }
        .contentShape(Rectangle())
        .modifier(MicroTapToAdd(onAdd: onAdd, label: label))
        .animation(.snappy(duration: 0.25), value: done)
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
                Text("Usuals").sectionHeader()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: VoCalTheme.Spacing.s) {
                        ForEach(model.usuals) { usual in
                            usualChip(usual)
                        }
                    }
                    // Room for PressableButtonStyle's scale so a pressed chip isn't clipped.
                    .padding(.vertical, 2)
                }
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
                    Text("· \(intString(usual.kcal)) cal")
                        .font(VoCalTheme.Fonts.chipLabel)
                        .monospacedDigit()
                        .foregroundStyle(VoCalTheme.Colors.muted)
                        .lineLimit(1)
                }
                .opacity(isLogging ? 0 : 1)
                if isLogging {
                    VoCalLoader(size: 18)
                }
            }
            .padding(.horizontal, VoCalTheme.Spacing.m)
            .frame(height: 40)
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
        .accessibilityLabel("Log \(usual.name), \(intString(usual.kcal)) calories")
        .contextMenu {
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
            Spacer()
            if !data.meals.isEmpty, data.avgConfidence > 0 {
                Text("avg \(Int((data.avgConfidence * 100).rounded()))% sure")
                    .font(.system(size: 11, weight: .bold))
                    // White on the gold fill (user ask 2026-08) — reads as a badge,
                    // not ink text that happens to sit on gold.
                    .foregroundStyle(VoCalTheme.Colors.onCta)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(VoCalTheme.Colors.gold, in: Capsule())
            }
        }
        .padding(.top, VoCalTheme.Spacing.s)

        if data.meals.isEmpty {
            emptyState
        } else {
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
                            renaming = meal
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
            Text(intString(meal.kcal))
                .font(.system(size: 16, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(VoCalTheme.Colors.ink)
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

    private var emptyState: some View {
        VStack(spacing: VoCalTheme.Spacing.s) {
            Image(systemName: "mic.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(VoCalTheme.Colors.gold)
            Text("No meals yet")
                .font(VoCalTheme.Fonts.primaryLabel)
                .foregroundStyle(VoCalTheme.Colors.ink)
            Text("Tap the mic and say what you had. Or type it, or snap a photo.")
                .font(VoCalTheme.Fonts.secondaryLabel)
                .foregroundStyle(VoCalTheme.Colors.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, VoCalTheme.Spacing.xxl)
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

    private func intString(_ value: Double) -> String {
        Int(value.rounded()).formatted(.number.grouping(.automatic))
    }

    /// Trims a trailing ".0" so "1.0" reads "1" but "2.5" stays "2.5".
    private func trimString(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        return String(format: "%.1f", rounded)
    }
}

/// Adds the tap-to-add gesture to a micro-tile only when it has an `onAdd` action (Water).
/// Display-only tiles (Produce/Fiber) pass `nil` and stay non-interactive — no dead tap, and
/// only the interactive tile advertises the button trait to VoiceOver.
private struct MicroTapToAdd: ViewModifier {
    let onAdd: (() -> Void)?
    let label: String

    func body(content: Content) -> some View {
        if let onAdd {
            content
                .onTapGesture(perform: onAdd)
                .accessibilityIdentifier(A11y.Today.waterTile)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Add \(label.lowercased())")
        } else {
            content
        }
    }
}

/// Thin progress bar for the micronutrient-minimum cards. Turns green once the minimum is met
/// (`complete`) to reinforce the goal-met win.
private struct MicroBar: View {
    var fraction: Double
    var complete: Bool = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(VoCalTheme.Colors.muted.opacity(0.18))
                Capsule()
                    .fill(complete ? VoCalTheme.Colors.optimal : VoCalTheme.Colors.ink.opacity(0.55))
                    .frame(width: max(4, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 5)
    }
}

/// Bounded-goal bar for protein: a centered green "optimal" band on a neutral track, with a
/// gold thumb that travels left→right as protein is logged. Unlike the micronutrient bars,
/// protein is NOT more-is-merrier — too little AND too much are both suboptimal — so the axis
/// leaves a lead-in below the band and overshoot room above it (band width on each side), which
/// keeps the green zone visually centered. The thumb clamps to the ends when off-scale; the
/// status line carries the exact gap. Numbers are engine-owned (AGENTS.md #6).
private struct ProteinRangeBar: View {
    var consumed: Double
    var low: Double
    var high: Double

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let band = max(high - low, 1)          // g; avoid divide-by-zero on a point band
            // Lead-in + overshoot are a QUARTER of the band each, so the green optimal zone spans
            // ~2/3 of the bar (slim ~1/6 lead-in, ~1/6 overshoot). A bigger green band makes being
            // in range feel achievable (user ask 2026-06) while still showing under/over room.
            let pad = band * 0.25
            let axisMin = max(0, low - pad)
            let axisMax = high + pad
            let span = max(axisMax - axisMin, 1)
            let bandStart = w * frac(low, axisMin, span)
            let bandEnd = w * frac(high, axisMin, span)
            let thumb = w * frac(consumed, axisMin, span)

            ZStack(alignment: .leading) {
                // Track + centered optimal band.
                ZStack(alignment: .leading) {
                    Capsule().fill(VoCalTheme.Colors.muted.opacity(0.16))
                    Capsule()
                        .fill(VoCalTheme.Colors.optimal.opacity(0.38))
                        .frame(width: max(0, bandEnd - bandStart))
                        .offset(x: bandStart)
                }
                .frame(height: 8)
                .frame(maxHeight: .infinity, alignment: .center)

                // Gold thumb at the consumed amount.
                Circle()
                    .fill(VoCalTheme.Colors.gold)
                    .overlay(Circle().stroke(VoCalTheme.Colors.background, lineWidth: 2))
                    .frame(width: 13, height: 13)
                    .offset(x: min(w - 13, max(0, thumb - 6.5)))
            }
        }
        .frame(height: 14)
        .accessibilityElement()
        .accessibilityLabel("Protein \(Int(consumed.rounded())) grams, optimal \(Int(low.rounded())) to \(Int(high.rounded()))")
    }

    private func frac(_ value: Double, _ axisMin: Double, _ span: Double) -> Double {
        min(1, max(0, (value - axisMin) / span))
    }
}

#Preview("Populated") {
    TodayView(model: TodayViewModel(service: MockTodayService(scenario: .populated)))
}

#Preview("Empty") {
    TodayView(model: TodayViewModel(service: MockTodayService(scenario: .empty)))
}
