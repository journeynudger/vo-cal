import SnapshotTesting
import SwiftUI
import VoCalCore
import XCTest
@testable import VoCal

/// The fast UI loop: each screen and component rendered to a PNG (in /tmp/ui for reading)
/// and compared to its committed golden. Light appearance only (the product ships light),
/// 393 pt wide at 3x, animations off, fixed dates.
@MainActor
final class RenderTests: SnapshotPolicyTestCase {
    private static let fixedDay: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 23
        components.hour = 12
        return Calendar.current.date(from: components)!
    }()

    private func assertGolden(_ image: UIImage, named name: String, file: StaticString = #filePath, testName: String = #function, line: UInt = #line) throws {
        if !Self.isRecording, let reason = GoldenRuntime.mismatch() { throw XCTSkip(reason) }
        assertSnapshot(
            of: image,
            as: .image(precision: Self.precision, perceptualPrecision: Self.perceptualPrecision, scale: RenderHarness.scale),
            named: name,
            file: file,
            testName: testName,
            line: line
        )
    }

    // MARK: - Components

    func testMealItemCardStateMatrix() throws {
        let sizes: [(String, DynamicTypeSize)] = [("large", .large), ("xxxLarge", .xxxLarge), ("accessibility2", .accessibility2)]
        for (label, size) in sizes {
            let sheet = VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(Self.cardVariants.enumerated()), id: \.offset) { _, variant in
                    Text(variant.0).font(.caption).foregroundStyle(.secondary)
                    MealItemCard(item: variant.1, onDelete: {}, onEdit: {})
                }
            }
            .padding(16)
            let image = try RenderHarness.render(sheet, name: "contact-meal-item-card-\(label)", height: size == .large ? 1100 : 1700, dynamicType: size)
            try assertGolden(image, named: label)
        }
    }

    private static func item(
        _ name: String, amount: Double? = nil, unit: FoodUnit? = nil, state: FoodState = .unspecified, fatRatio: String? = nil,
        grams: Double, kcal: Double, protein: Double, carbs: Double, fat: Double, confidence: Double,
        pricedAs: String? = nil, personalFoodId: String? = nil, source: ResolutionSource = .dictionary
    ) -> ParseResultItem {
        ParseResultItem(
            name: name, amount: amount, unit: unit, state: state, fatRatio: fatRatio, grams: grams,
            macros: NutrientProfile(kcal: kcal, protein: protein, carbs: carbs, fat: fat, fiber: 0),
            confidence: confidence, source: source, matchScore: confidence, pricedAs: pricedAs, personalFoodId: personalFoodId
        )
    }

    private static let cardVariants: [(String, ParseResultItem)] = [
        ("confirmed", item("Ground beef 93/7", amount: 4, unit: .oz, state: .cooked, fatRatio: "93/7", grams: 113, kcal: 170, protein: 24, carbs: 0, fat: 8, confidence: 0.96)),
        ("needs attention", item("Chicken", grams: 120, kcal: 198, protein: 37, carbs: 0, fat: 4, confidence: 0.71)),
        ("counted as", item("Cosmic crisp apple", amount: 1, grams: 182, kcal: 95, protein: 0.5, carbs: 25, fat: 0.3, confidence: 0.9, pricedAs: "apple")),
        ("one of your foods", item("Street taco chicken", amount: 1, grams: 113, kcal: 153, protein: 24, carbs: 3, fat: 5, confidence: 1.0, personalFoodId: "f1", source: .manual)),
        ("long name", item("Vollkornbrötchen mit Räucherlachs und Frischkäse aus der Bäckerei", amount: 2, unit: .piece, grams: 180, kcal: 410, protein: 22, carbs: 44, fat: 15, confidence: 0.88)),
    ]

    func testWeekMiniBarsGeometry() throws {
        // Synthetic weeks with known answers, the way a waveform test feeds silence, a sine
        // and a clipped square: an empty week floors every bar; one day at the baseline
        // reaches the plot height over the headroom; an over day clips at the top.
        let baseline = 2000.0
        func week(_ consumed: [Double]) -> WeekBudget {
            WeekMiniBarsFixtures.week(consumed: consumed, target: Int(baseline), baseline: baseline, day: Self.fixedDay)
        }
        let silent = WeekMiniBars.geometry(for: week([0, 0, 0, 0, 0, 0, 0]))
        // Four logged past days and today at zero floor at the minimum (today draws what was
        // eaten so far); the two upcoming days are goal-framed and draw the target over the
        // headroom (WeekStatusStyle.drawsGoalFrame: notLogged and upcoming only).
        XCTAssertEqual(Array(silent.heights.prefix(5)), Array(repeating: WeekMiniBars.minimumHeight, count: 5))
        for height in silent.heights.suffix(2) {
            XCTAssertEqual(height, WeekMiniBars.plotHeight / WeekMiniBars.headroom, accuracy: 0.01)
        }
        let single = WeekMiniBars.geometry(for: week([0, baseline, 0, 0, 0, 0, 0]))
        XCTAssertEqual(single.heights[1], WeekMiniBars.plotHeight / WeekMiniBars.headroom, accuracy: 0.01)
        let clipped = WeekMiniBars.geometry(for: week([0, 0, 0, 9000, 0, 0, 0]))
        XCTAssertEqual(clipped.heights[3], WeekMiniBars.plotHeight / WeekMiniBars.headroom, accuracy: 0.01)
        XCTAssertTrue(clipped.heights[3] >= single.heights[1])
        XCTAssertEqual(single.goalFraction, 1 - 1 / WeekMiniBars.headroom, accuracy: 0.01)
    }

    func testWeekMiniBarsPixelsMatchGeometry() throws {
        // The round trip: numbers -> geometry -> pixels -> heights again. Each bar's column
        // is scanned for its filled run; the run's height must be the geometry's, within a
        // pixel of anti-aliasing.
        let budget = WeekMiniBarsFixtures.week(consumed: [600, 1200, 1800, 2400, 300, 0, 0], target: 2000, baseline: 2000, day: Self.fixedDay)
        let geometry = WeekMiniBars.geometry(for: budget)
        let barWidth: CGFloat = 12
        let plotWidth = barWidth * 7 + WeekMiniBars.spacing * 6
        let bars = HStack(alignment: .bottom, spacing: WeekMiniBars.spacing) {
            ForEach(Array(budget.days.enumerated()), id: \.element.id) { index, _ in
                Rectangle().fill(Color.black).frame(width: barWidth, height: geometry.heights[index])
            }
        }
        .frame(width: plotWidth, height: WeekMiniBars.plotHeight, alignment: .bottom)
        .background(Color.white)
        let renderer = ImageRenderer(content: bars)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        let measured = PixelProbe.filledHeights(in: image, columns: (0..<7).map { Int(CGFloat($0) * (barWidth + WeekMiniBars.spacing) + barWidth / 2) })
        for (index, expected) in geometry.heights.enumerated() {
            XCTAssertEqual(CGFloat(measured[index]), expected, accuracy: 1.5, "bar \(index)")
        }
        try image.pngWrite(to: RenderHarness.outputDirectory.appendingPathComponent("week-mini-bars-roundtrip.png"))
    }

    // MARK: - Screens

    func testVoiceLogResultConfirmed() throws {
        let context = ResultContext(captureID: "c1", transcript: MealCaptureFixtures.defaultTranscript, result: MealCaptureFixtures.beefAndRice(mealType: .lunch))
        let image = try RenderHarness.render(Self.resultView(context), name: "voice-log-result-confirmed", height: 1500)
        try assertGolden(image, named: "confirmed")
    }

    func testVoiceLogResultWithChecks() throws {
        let context = ResultContext(captureID: "c2", transcript: MealCaptureFixtures.transcript(for: .burger), result: MealCaptureFixtures.burger(mealType: .lunch))
        let image = try RenderHarness.render(Self.resultView(context), name: "voice-log-result-checks", height: 1700)
        try assertGolden(image, named: "checks")
    }

    private static func resultView(_ context: ResultContext, printsNumbers: Bool = true) -> some View {
        VoiceLogResultView(
            context: context,
            mealType: .lunch,
            targetDayLabel: nil,
            printsNumbers: printsNumbers,
            onAnswer: { _, _ in },
            onLogAnyway: {},
            onDelete: { _ in },
            onConfirm: { _ in },
            onEditItem: { _ in },
            onAddDetail: {},
            onLabelFood: { _, _, _ in },
            onSaveBatch: { _, _ in throw RenderFixtureError.unused },
            onLogServing: { _ in },
            onClose: {}
        )
    }

    func testLabelFoodSheet() throws {
        let unresolved = Self.item("Street taco chicken", grams: 0, kcal: 0, protein: 0, carbs: 0, fat: 0, confidence: 0.2, source: .unresolved)
        let image = try RenderHarness.render(LabelFoodSheet(item: unresolved) { _, _ in }, name: "label-food-sheet", height: 1100)
        try assertGolden(image, named: "empty")
    }

    func testBatchFoodSheet() throws {
        let image = try RenderHarness.render(BatchFoodSheet(itemCount: 2, totalKcal: 430, onSave: { _, _ in throw RenderFixtureError.unused }, onLogServing: { _ in }, onDone: {}), name: "batch-food-sheet", height: 800)
        try assertGolden(image, named: "entry")
    }

    func testPersonalFoodsList() throws {
        let foods = [
            PersonalFood(id: "1", name: "Street taco chicken", aliases: ["taco chicken"], perServing: NutrientProfile(kcal: 153, protein: 24, carbs: 3, fat: 5, fiber: 0), servingGrams: 113, servingsPerPackage: 2, source: "label", createdAt: Self.fixedDay),
            PersonalFood(id: "2", name: "Chili", aliases: [], perServing: NutrientProfile(kcal: 410, protein: 32, carbs: 38, fat: 14, fiber: 9), servingGrams: 320, servingsPerPackage: 8, source: "batch", createdAt: Self.fixedDay),
        ]
        let image = try RenderHarness.render(PersonalFoodsView(preloaded: foods), name: "personal-foods", height: 700)
        try assertGolden(image, named: "two")
        let empty = try RenderHarness.render(PersonalFoodsView(preloaded: []), name: "personal-foods-empty", height: 700)
        try assertGolden(empty, named: "empty")
    }

    func testTodayPopulated() async throws {
        let model = TodayViewModel(service: MockTodayService(scenario: .populated), checkin: MockCheckinService(due: false), outcomes: MockCaptureOutcomes.shared, date: Self.fixedDay)
        await model.load()
        let image = try RenderHarness.render(TodayView(model: model, onProfile: {}), name: "today-populated", height: 1900)
        try assertGolden(image, named: "populated")
    }

    func testTodayEmptyAtAccessibilitySize() async throws {
        let model = TodayViewModel(service: MockTodayService(scenario: .empty), checkin: MockCheckinService(due: false), outcomes: MockCaptureOutcomes.shared, date: Self.fixedDay)
        await model.load()
        let image = try RenderHarness.render(TodayView(model: model, onProfile: {}), name: "today-empty-accessibility2", height: 2600, dynamicType: .accessibility2)
        try assertGolden(image, named: "empty-accessibility2")
    }

    // MARK: - The modes (decision 57, 2026-10-04)

    func testTodayPerMode() async throws {
        // Beside the five (testTodayPopulated): habits prints no number anywhere on the page,
        // calories is the one card, macros is the card over three macro tiles.
        for (mode, name) in [(TrackingMode.habits, "habits"), (.calories, "calories"), (.macros, "macros")] {
            let model = TodayViewModel(service: MockTodayService(scenario: .populated, mode: mode), checkin: MockCheckinService(due: false), outcomes: MockCaptureOutcomes.shared, date: Self.fixedDay)
            await model.load()
            let image = try RenderHarness.render(TodayView(model: model, onProfile: {}), name: "today-\(name)", height: 1900)
            try assertGolden(image, named: name)
        }
    }

    func testTodayHabitsEmptyAndFocusWrap() async throws {
        // Habits at breakfast: three tiles at zero, no red (spec 6.9).
        let empty = TodayViewModel(service: MockTodayService(scenario: .empty, mode: .habits), checkin: MockCheckinService(due: false), outcomes: MockCaptureOutcomes.shared, date: Self.fixedDay)
        await empty.load()
        let emptyImage = try RenderHarness.render(TodayView(model: empty, onProfile: {}), name: "today-habits-empty", height: 1900)
        try assertGolden(emptyImage, named: "habits-empty")
        // The five with two focus tiles added: five tiles wrap to three and two (spec 6.4).
        let focus = TodayViewModel(service: MockTodayService(scenario: .populated, mode: .five, focus: [.carbs, .fat]), checkin: MockCheckinService(due: false), outcomes: MockCaptureOutcomes.shared, date: Self.fixedDay)
        await focus.load()
        let focusImage = try RenderHarness.render(TodayView(model: focus, onProfile: {}), name: "today-five-focus", height: 2100)
        try assertGolden(focusImage, named: "five-focus")
    }

    // MARK: - The hero's framing (decision 70, 2026-10-04)

    func testCaloriesHeroNamesTheSmallerDistance() throws {
        // Koo and Fishbach's small-area rule as the server applies it (PanelComposer.calories
        // is the mock's twin of meals/dashboard.py _calories): before the midpoint the hero is
        // what is eaten so far in ink with what is left as the line; from it, what is left in
        // gold. An empty day and a day over its target keep the to-go card.
        let targets = DayTotals(kcal: 2040, protein: 150, carbs: 200, fat: 60, fiber: 30, produce: 5, water: 96)
        func calories(_ kcal: Double) -> TodayPanel {
            var remaining = targets
            remaining.kcal = targets.kcal - kcal
            return PanelComposer.compose(mode: .calories, targets: targets, consumed: DayTotals(kcal: kcal), remaining: remaining, proteinBand: (135, 165), mealsToday: kcal > 0 ? 1 : 0)[0]
        }
        let early = calories(420)
        XCTAssertEqual(early.knownFraming, .toDate)
        XCTAssertEqual(early.title, "Calories so far")
        XCTAssertEqual(early.support, "1,620 left of 2,040 today")
        let later = calories(1980)
        XCTAssertEqual(later.knownFraming, .toGo)
        XCTAssertEqual(later.title, "Calories left")
        XCTAssertEqual(later.support, "of 2,040 today")
        XCTAssertEqual(calories(0).knownFraming, .toGo)
        XCTAssertEqual(calories(1020).knownFraming, .toGo)
        XCTAssertEqual(calories(2300).knownFraming, .toGo)
        // The wire word decides the card; a word this build does not know draws the to-go card,
        // and a panel without the field (an older server) does too.
        var wire = early
        wire.framing = "to_the_moon"
        XCTAssertEqual(wire.knownFraming, .toGo)
        XCTAssertEqual(TodayPanel(kind: "calories_left", metric: "kcal", title: "Calories left", consumed: 1, target: 2, remaining: 1).knownFraming, .toGo)
        // The card before the midpoint, with the phone's burned figure on the line.
        let image = try RenderHarness.render(
            PanelView(panel: early, size: .hero, supportSuffix: "310 burned").padding(VoCalTheme.Spacing.m),
            name: "calories-so-far", height: 220
        )
        try assertGolden(image, named: "so-far")
    }

    func testPanelRowsWrapAtFour() {
        // The tile rows are a pure function of the count (PanelLayout.rows): three to a row,
        // four or more over as few rows as possible, the fuller rows first.
        func tiles(_ count: Int) -> [TodayPanel] {
            (0..<count).map { TodayPanel(kind: "metric_tile", metric: "m\($0)", title: "", consumed: 0, target: 1, remaining: 1) }
        }
        XCTAssertTrue(PanelLayout.rows([]).isEmpty)
        XCTAssertEqual(PanelLayout.rows(tiles(1)).map(\.count), [1])
        XCTAssertEqual(PanelLayout.rows(tiles(3)).map(\.count), [3])
        XCTAssertEqual(PanelLayout.rows(tiles(4)).map(\.count), [2, 2])
        XCTAssertEqual(PanelLayout.rows(tiles(5)).map(\.count), [3, 2])
        XCTAssertEqual(PanelLayout.rows(tiles(7)).map(\.count), [3, 2, 2])
        // The five keeps calories and protein as twins; macros shows calories alone over tiles.
        let targets = DayTotals(kcal: 2000, protein: 150, carbs: 200, fat: 60, fiber: 30, produce: 5, water: 96)
        let five = PanelComposer.compose(mode: .five, targets: targets, consumed: DayTotals(), remaining: targets, proteinBand: (135, 165), mealsToday: 0)
        XCTAssertEqual(PanelLayout.arrange(five, mode: .five).heroes.map(\.metric), ["kcal", "protein"])
        let macros = PanelComposer.compose(mode: .macros, targets: targets, consumed: DayTotals(), remaining: targets, proteinBand: (135, 165), mealsToday: 0)
        XCTAssertEqual(PanelLayout.arrange(macros, mode: .macros).heroes.map(\.metric), ["kcal"])
        XCTAssertEqual(PanelLayout.arrange(macros, mode: .macros).tileRows.map { $0.map(\.metric) }, [["protein", "carbs", "fat"]])
        // A kind this build does not know is left out, never drawn blank.
        let unknown = [TodayPanel(kind: "future_kind", metric: "x", title: "Later", consumed: 0, target: 1, remaining: 1)]
        XCTAssertTrue(PanelLayout.arrange(unknown, mode: .five).tileRows.isEmpty)
        XCTAssertTrue(PanelLayout.arrange(unknown, mode: .five).fullWidth.isEmpty)
        // The plan card takes the full-width lane, first, with calories a hero beneath it.
        let planned = PanelComposer.compose(
            mode: .mealPlan, targets: targets, consumed: DayTotals(), remaining: targets, proteinBand: (135, 165), mealsToday: 0,
            planPanel: PlanComposer.panel(plan: MockMealPlanService.canned, meals: [])
        )
        let arranged = PanelLayout.arrange(planned, mode: .mealPlan)
        XCTAssertEqual(arranged.fullWidth.map(\.metric), ["plan"])
        XCTAssertEqual(arranged.heroes.map(\.metric), ["kcal"])
        XCTAssertTrue(arranged.tileRows.isEmpty)
    }

    // MARK: - The meal plan (decision 65, 2026-10-04)

    func testTodayMealPlan() async throws {
        // The plan card first, three of the day's four meals ticked by name and the shake with a
        // banana named under them as "also today"; the calories card beneath. A person with no
        // plan yet sees the card say so and lead to the builder.
        MockMealPlanService.reset()
        let model = TodayViewModel(service: MockTodayService(scenario: .populated, mode: .mealPlan), checkin: MockCheckinService(due: false), outcomes: MockCaptureOutcomes.shared, date: Self.fixedDay)
        await model.load()
        let image = try RenderHarness.render(TodayView(model: model, onProfile: {}), name: "today-meal-plan", height: 1900)
        try assertGolden(image, named: "populated")
        let none = TodayViewModel(service: MockTodayService(scenario: .empty, mode: .mealPlan, planSource: .absent), checkin: MockCheckinService(due: false), outcomes: MockCaptureOutcomes.shared, date: Self.fixedDay)
        await none.load()
        let noneImage = try RenderHarness.render(TodayView(model: none, onProfile: {}), name: "today-meal-plan-none", height: 1900)
        try assertGolden(noneImage, named: "no-plan-yet")
    }

    func testPlanBuilder() throws {
        // Settings → My meal plan with a saved plan: the rows, the server's calories, the
        // engine's line under them (this plan is 240 under, in ink). The onboarding step with the
        // three slots the person said they eat, nothing chosen, "Save plan" waiting.
        let page = NavigationStack {
            PlanBuilderView(presentation: .page(onClose: nil), preloaded: PlanBuilderView.Preloaded(plan: MockMealPlanService.canned, usuals: []))
        }
        let pageImage = try RenderHarness.render(page, name: "plan-builder-saved", height: 1100)
        try assertGolden(pageImage, named: "saved")
        let step = PlanBuilderView(presentation: .onboarding(onDone: { _ in }), initialSlotCount: 3, preloaded: PlanBuilderView.Preloaded(plan: nil, usuals: []))
        let stepImage = try RenderHarness.render(step, name: "plan-builder-onboarding", height: 900)
        try assertGolden(stepImage, named: "onboarding-empty")
    }

    func testPlanComposerTicksByName() {
        // The mock's twin of the server's matching and check (meals/plan.py), pinned so the sim
        // shows what the live path would: a slot ticks once, by name, in logged order; the rest
        // of the day is named as extras; the line states the facts without a verdict.
        let plan = MockMealPlanService.canned
        let meals = MockTodayService.populated(date: Self.fixedDay, mode: .mealPlan).meals
        let (statuses, extras) = PlanComposer.match(plan.slots, meals: meals)
        XCTAssertEqual(statuses.map(\.logged), [true, true, false, true])
        XCTAssertEqual(extras, ["Protein shake & a banana"])
        let panel = PlanComposer.panel(plan: plan, meals: meals)
        XCTAssertEqual(panel.support, "3 of 4 meals")
        XCTAssertFalse(panel.complete)
        XCTAssertEqual(PlanComposer.panel(plan: nil, meals: meals).support, "No plan yet")
        XCTAssertEqual(plan.check?.line, "240 calories under your protocol.")
        let landing = PlanComposer.check(plan.slots, targetKcal: 1850, proteinFloor: 135)
        XCTAssertEqual(landing.line, "On your protocol: 1,800 of 1,850 calories, protein covered.")
        XCTAssertTrue(landing.onProtocol)
        let short = PlanComposer.check(Array(plan.slots.prefix(2)), targetKcal: 2040, proteinFloor: 135)
        XCTAssertEqual(short.line, "980 calories under your protocol; protein 55 g under the band.")
        XCTAssertEqual(PlanComposer.autoName(plan.slots[2].items), "Whey protein")
    }

    func testProtocolRevealPerMode() throws {
        for mode in TrackingMode.offered {
            let generated = GeneratedProtocol(targets: .personaFixture, reveal: MockProtocolService.reveal(for: mode))
            let view = ProtocolRevealView(intake: IntakeDraft().profile, mode: mode, onContinue: {}, phase: .ready(generated))
            let image = try RenderHarness.render(view, name: "protocol-reveal-\(mode.rawValue)", height: 1500)
            try assertGolden(image, named: mode.rawValue)
        }
        // R12, variant b: the three habits with no counts (first seen on Today). Variant a is
        // the loop's habits render. Both drawn, so the decision is made from the screens.
        let withheld = GeneratedProtocol(targets: .personaFixture, reveal: MockProtocolService.reveal(for: .habits))
        let variantB = ProtocolRevealView(intake: IntakeDraft().profile, mode: .habits, onContinue: {}, phase: .ready(withheld), habitCounts: false)
        let bImage = try RenderHarness.render(variantB, name: "protocol-reveal-habits-b", height: 1500)
        try assertGolden(bImage, named: "habits-b")
    }

    func testTrackingModeChooserAndHowITrack() throws {
        let chooser = TrackingModeChooser(selection: .constant(nil)).padding(16)
        let chooserImage = try RenderHarness.render(chooser, name: "tracking-mode-chooser", height: 700)
        try assertGolden(chooserImage, named: "nothing-chosen")
        let preference = TrackingPreference(
            mode: .calories, focusMetrics: [.protein], declinedOffers: [],
            offerableFocus: PanelComposer.offerableFocus(for: .calories), source: "chosen", version: 2,
            nudgeLevel: .essential, frictions: [.eatingOut]
        )
        let page = NavigationStack { HowITrackView(preloaded: preference) }
        let pageImage = try RenderHarness.render(page, name: "how-i-track", height: 1700)
        try assertGolden(pageImage, named: "calories-plus-protein")
    }

    // MARK: - The onboarding that asks (decision 66, 2026-10-04)

    func testVoiceAndFrictionChoosers() throws {
        // The two new intake questions: nothing chosen on the voice; two frictions ticked.
        let voice = VoiceChooser(selection: .constant(nil)).padding(16)
        let voiceImage = try RenderHarness.render(voice, name: "voice-chooser", height: 520)
        try assertGolden(voiceImage, named: "nothing-chosen")
        let frictions = FrictionChooser(selection: .constant([.forgetting, .time])).padding(16)
        let frictionImage = try RenderHarness.render(frictions, name: "friction-chooser", height: 620)
        try assertGolden(frictionImage, named: "two-ticked")
        // When will you log (decision 69): the four moments, one chosen.
        let anchor = AnchorChooser(selection: .constant(.afterEating)).padding(16)
        let anchorImage = try RenderHarness.render(anchor, name: "anchor-chooser", height: 640)
        try assertGolden(anchorImage, named: "right-after-i-eat")
    }

    // MARK: - Behavior change end to end (decision 69, 2026-10-04)

    func testCheckInRemembersAndAsks() throws {
        // The check-in opens with last week's words, shows the phone's steps, asks what got in
        // the way and closes with a sentence to next week; and the same form with no note yet.
        let remembered = CheckInViewModel(service: MockCheckinService(), tracking: MockTrackingService())
        remembered.loadsOnAppear = false
        remembered.previousNote = CheckinNote(
            text: "Travelling Tuesday to Thursday. If I keep lunch simple the rest holds.",
            writtenAt: Date().addingTimeInterval(-7 * 86_400)
        )
        remembered.frictions = [.eatingOut]
        remembered.stepsPerDay = 6200
        let withNote = CheckInView(onComplete: { _ in }, model: remembered)
        let withNoteImage = try RenderHarness.render(withNote, name: "checkin-with-note", height: 1700)
        try assertGolden(withNoteImage, named: "with-last-weeks-note")
        XCTAssertEqual(remembered.previousNoteLabel, "You wrote last week")
        XCTAssertEqual(remembered.stepsLine, "About 6,200 steps a day this week, by your phone.")

        let first = CheckInViewModel(service: MockCheckinService(), tracking: MockTrackingService())
        first.loadsOnAppear = false
        let firstWeek = CheckInView(onComplete: { _ in }, model: first)
        let firstImage = try RenderHarness.render(firstWeek, name: "checkin-first-week", height: 1500)
        try assertGolden(firstImage, named: "first-week")
        XCTAssertNil(first.stepsLine)
    }

    func testAnchorTwinMirrorsTheServer() {
        // CheckSlots.composed is the mock's twin of tracking/projection.py check_slots_for.
        XCTAssertEqual(Experience.composed(level: nil, frictions: []).checkSlots, CheckSlots(lateMorning: "11:30", evening: "20:00"))
        XCTAssertEqual(Experience.composed(level: nil, frictions: [], anchor: .own).checkSlots, CheckSlots(lateMorning: "11:30", evening: "20:00"))
        XCTAssertEqual(Experience.composed(level: nil, frictions: [], anchor: .whenSeated).checkSlots, CheckSlots(lateMorning: "12:30", evening: "20:00"))
        let beforeBed = Experience.composed(level: nil, frictions: [], anchor: .beforeBed)
        XCTAssertEqual(beforeBed.checkSlots, CheckSlots(lateMorning: nil, evening: "20:30"))
        XCTAssertTrue(beforeBed.eveningReminder, "the before-bed logger's evening check exists without the forgetting friction")
        XCTAssertFalse(Experience.composed(level: nil, frictions: [], anchor: .afterEating).eveningReminder)
    }

    // MARK: - The bar answers (decision 71, 2026-10-04)

    private static func answerView(_ context: AnswerContext) -> some View {
        AssistReplyView(context: context, onUndo: {}, onSayMore: { _ in }, onSpeak: {}, onOpen: { _ in }, onClose: {})
    }

    func testTheBarAnswers() async throws {
        // The rules twin (MockAssistant: assist/llm.py read and assist/lines.py) applied to the
        // mock's store, so the row the answer shows is the row Settings would, and Undo puts it
        // back the same way. The pure checks run first, on every runtime; the three renders come
        // last, because a missing golden skips the rest of the method (XCTSkip). The store is
        // reset either way: the mode left behind here is the mode the UI tests would launch
        // into (CI run 37206771344: five flows waited for a calories card habits never draws).
        MockTrackingService.reset()
        defer { MockTrackingService.reset() }
        let changed = await MockAssistant.answer("switch to habits")
        XCTAssertEqual(changed.knownKind, .changed)
        XCTAssertEqual(changed.line, "You're following Build better habits now.")
        XCTAssertEqual(changed.change, AssistChange(icon: "slider.horizontal.3", title: "How I track", value: "Habits"))
        XCTAssertEqual(changed.undo?.tracking?.mode, .five)
        XCTAssertEqual(MockTrackingService.current.mode, .habits)
        let changedContext = AnswerContext(asked: "switch to habits", reply: changed)
        XCTAssertTrue(changedContext.canUndo)
        _ = try await MockTrackingService().update(changed.undo!.tracking!)
        XCTAssertEqual(MockTrackingService.current.mode, .five)
        var undone = changedContext
        undone.undone = true
        XCTAssertFalse(undone.canUndo)
        let shown = await MockAssistant.answer("how much protein do I have left")
        XCTAssertEqual(shown.knownKind, .shown)
        XCTAssertEqual(shown.line, "Your protein today.")
        XCTAssertEqual(shown.panel?.metric, "protein")
        XCTAssertNil(shown.undo)
        let shownContext = AnswerContext(asked: "how much protein do I have left", reply: shown)
        let told = await MockAssistant.answer("make me a sandwich")
        XCTAssertEqual(told.knownKind, .told)
        XCTAssertEqual(told.line, MockAssistant.other)
        XCTAssertNil(told.change)
        let toldContext = AnswerContext(asked: "make me a sandwich", reply: told)
        // The rest of the twin, by kind (the server's tests carry the same sentences).
        let five = await MockAssistant.answer("I want to follow the five")
        XCTAssertEqual(five.knownKind, .told)
        let sugarOn = await MockAssistant.answer("also show sugar")
        XCTAssertEqual(sugarOn.change?.value, "Sugar")
        XCTAssertEqual(MockTrackingService.current.focusMetrics, [.sugar])
        let sugarOff = await MockAssistant.answer("take sugar off today")
        XCTAssertEqual(sugarOff.change?.value, "Nothing extra")
        let level = await MockAssistant.answer("stop all reminders")
        XCTAssertEqual(level.change?.title, "Reminders")
        XCTAssertNil(level.undo, "never chosen before: nothing to put back to")
        XCTAssertEqual(MockTrackingService.current.nudgeLevel, .off)
        let coach = await MockAssistant.answer("actually, coach me along the way")
        XCTAssertEqual(coach.undo?.tracking?.nudgeLevel, .off)
        let mute = await MockAssistant.answer("stop the protein reminders")
        XCTAssertEqual(mute.line, "The protein reminders stay quiet until you turn them back on.")
        XCTAssertEqual(mute.change?.value, "Protein")
        let bed = await MockAssistant.answer("I'll log before bed")
        XCTAssertEqual(bed.line, "One check-in at 20:30 now, and nothing before the evening.")
        XCTAssertEqual(MockAssistant.anchorLine(.afterEating), "Your check-ins follow right after you eat now: 11:30 and 20:00.")
        let forget = await MockAssistant.answer("I forget")
        XCTAssertEqual(forget.line, "Noted: I forget. A reminder in the evening when a meal is still unlogged.")
        let week = await MockAssistant.answer("show me my week")
        XCTAssertEqual(week.pointer?.knownSurface, .week)
        let why = await MockAssistant.answer("why is my protein target 160")
        XCTAssertEqual(why.pointer?.knownSurface, .protocolPage)
        let bowl = await MockAssistant.answer("I had a big bowl of something")
        XCTAssertEqual(bowl.knownKind, .meal)
        _ = try await MockTrackingService().update(TrackingUpdate(mode: .habits))
        let habits = await MockAssistant.answer("how many calories so far")
        XCTAssertEqual(habits.line, MockAssistant.noNumbers)
        _ = try await MockTrackingService().update(TrackingUpdate(mode: .calories))
        let fiber = await MockAssistant.answer("how much fiber do I have left")
        XCTAssertEqual(fiber.line, "Fiber isn't on your Today. Say 'also show fiber' and it will be.")
        // The sim reaches the answer from the keyboard: the mock parse refuses a request the way
        // the live parser does (422), and keeps parsing what the rules cannot read as a meal.
        XCTAssertTrue(MockAssistant.isRequest("switch to habits"))
        XCTAssertTrue(MockAssistant.isRequest("how much protein do I have left"))
        XCTAssertFalse(MockAssistant.isRequest("I had a big bowl of something"))
        XCTAssertFalse(MockAssistant.isRequest("a burger with fries"))
        do {
            _ = try await MockMealCaptureService(latency: .zero).parseText("switch to habits")
            XCTFail("a request is not a meal")
        } catch {
            XCTAssertTrue(VoiceLogViewModel.isNoFood(error))
        }
        let burger = try await MockMealCaptureService(latency: .zero).parseText("a burger with fries")
        XCTAssertFalse(burger.items.isEmpty)
        // A kind from a newer server draws the line alone, never a blank; the undo decodes tolerantly.
        let wire = try VoCalJSON.decoder().decode(AssistReply.self, from: Data(#"{"kind":"sung","line":"La.","undo":{"tracking":{"mode":"five","source":"chosen"}}}"#.utf8))
        XCTAssertNil(wire.knownKind)
        XCTAssertEqual(wire.turn, .app("La."))
        XCTAssertEqual(wire.undo?.tracking?.mode, .five)
        XCTAssertTrue(AnswerContext(asked: "x", reply: wire).canUndo)
        // The three answers, rendered: a change with Undo, the protein card, the honest no.
        MockTrackingService.reset()
        let image = try RenderHarness.render(Self.answerView(changedContext), name: "answer-changed", height: 760)
        try assertGolden(image, named: "changed")
        let shownImage = try RenderHarness.render(Self.answerView(shownContext), name: "answer-shown", height: 760)
        try assertGolden(shownImage, named: "shown")
        let toldImage = try RenderHarness.render(Self.answerView(toldContext), name: "answer-told", height: 760)
        try assertGolden(toldImage, named: "told")
    }

    func testNotificationSettingsInThePersonsWords() throws {
        // Settings → Notifications: the three sentences of the intake, the promise under the
        // chosen one, the iOS permission row as a separate fact.
        let page = NavigationStack { NotificationSettingsView(nudgeLevel: .constant(.essential), service: MockTrackingService()) }
        let image = try RenderHarness.render(page, name: "notification-settings", height: 900)
        try assertGolden(image, named: "only-when-slipping")
    }

    // MARK: - Nudges that reach the person (decision 67, 2026-10-04)

    func testNudgeReasonsSheetAndPermissionCard() throws {
        let sheet = NudgeReasonsSheet(onPick: { _ in })
        let sheetImage = try RenderHarness.render(sheet, name: "nudge-reasons", height: 560)
        try assertGolden(sheetImage, named: "three-reasons")
        let card = NotificationPermissionCard(level: .essential, onAllow: {}, onNotNow: {}).padding(16)
        let cardImage = try RenderHarness.render(card, name: "notification-permission-card", height: 260)
        try assertGolden(cardImage, named: "only-when-slipping")
    }

    func testNotificationContentAndFireTiming() {
        // The notification's words and manners from the card alone (spec 6.2): the subject as
        // the title, active with sound only when essential, one thread, the category, no badge.
        let essential = NudgeCard(
            id: "gone_quiet", category: "consistency", message: "Welcome back.", proTip: "p",
            priority: 80, cooldownDays: 2, essential: true, title: "Your day"
        )
        let loud = NudgeNotificationService.content(for: essential)
        XCTAssertEqual(loud.title, "Your day")
        XCTAssertEqual(loud.body, "Welcome back.")
        XCTAssertEqual(loud.interruptionLevel, .active)
        XCTAssertNotNil(loud.sound)
        XCTAssertEqual(loud.threadIdentifier, NudgeNotificationService.threadID)
        XCTAssertEqual(loud.categoryIdentifier, NudgeNotificationService.categoryID)
        XCTAssertNil(loud.badge)
        let coaching = NudgeCard(id: "fiber_boost", category: "fiber", message: "m", proTip: "p", priority: 34, cooldownDays: 3)
        let quiet = NudgeNotificationService.content(for: coaching)
        XCTAssertEqual(quiet.title, "Fiber", "a server before the title falls back to the category's word")
        XCTAssertEqual(quiet.interruptionLevel, .passive)
        XCTAssertNil(quiet.sound)
        XCTAssertEqual(quiet.relevanceScore, 0.34, accuracy: 0.001)

        // One answer is one answer (decision 67): the queue is idempotent by nudge, kind and day.
        var queue = NudgeReactionQueue()
        XCTAssertTrue(queue.add(id: "fiber_boost", kind: .dismissed, day: "2026-10-04"))
        XCTAssertFalse(queue.add(id: "fiber_boost", kind: .dismissed, day: "2026-10-04"))
        XCTAssertTrue(queue.add(id: "fiber_boost", kind: .dismissed, day: "2026-10-05"), "a new day is a new answer")
        XCTAssertTrue(queue.add(id: "fiber_boost", kind: .notForMe, day: "2026-10-05"))
        XCTAssertEqual(queue.entries.count, 3)
        XCTAssertEqual(NudgeReactionQueue(queue.entries), queue, "round-trips through UserDefaults' shape")

        // The body as a clock (spec 6.5): later for a workout or a night, never earlier, never
        // into the night.
        let cal = Calendar.current
        func at(_ hour: Int, _ minute: Int) -> Date { cal.date(bySettingHour: hour, minute: minute, second: 0, of: Self.fixedDay)! }
        let noon = at(12, 0)
        let protein = NudgeContext(afterWorkout: true, afterWake: false)
        XCTAssertEqual(
            NudgeFireTiming.shifted(fire: at(17, 0), context: protein, clock: .init(lastWorkoutEnd: at(16, 40), sleepEnd: nil), now: noon),
            at(17, 25)
        )
        XCTAssertEqual(NudgeFireTiming.shifted(fire: at(17, 0), context: protein, clock: .unknown, now: noon), at(17, 0))
        XCTAssertEqual(
            NudgeFireTiming.shifted(fire: at(17, 0), context: protein, clock: .init(lastWorkoutEnd: at(10, 0), sleepEnd: nil), now: noon),
            at(17, 0),
            "a workout before the slot leaves the slot"
        )
        // The first hour after waking is silent for every fire (the behavior-change spec's 6.12).
        XCTAssertEqual(
            NudgeFireTiming.shifted(fire: at(9, 30), context: NudgeContext(afterWorkout: false, afterWake: true), clock: .init(lastWorkoutEnd: nil, sleepEnd: at(9, 40)), now: at(8, 0)),
            at(10, 40)
        )
        XCTAssertEqual(
            NudgeFireTiming.shifted(fire: at(15, 0), context: protein, clock: .init(lastWorkoutEnd: nil, sleepEnd: at(14, 30)), now: noon),
            at(15, 30),
            "a fire the engine did not mark still waits out the hour after waking"
        )
        // After a short night the coaching holds and the essentials keep their place.
        let shortNight = NudgeFireTiming.BodyClock(lastWorkoutEnd: nil, sleepEnd: at(6, 0), sleepDuration: 5 * 3600)
        XCTAssertTrue(NudgeFireTiming.holds(coaching, clock: shortNight))
        XCTAssertFalse(NudgeFireTiming.holds(essential, clock: shortNight))
        XCTAssertFalse(NudgeFireTiming.holds(coaching, clock: .unknown), "an unknown night holds nothing")
        XCTAssertFalse(NudgeFireTiming.holds(coaching, clock: .init(lastWorkoutEnd: nil, sleepEnd: at(7, 0), sleepDuration: 7 * 3600)))
        XCTAssertNil(
            NudgeFireTiming.shifted(fire: at(20, 30), context: protein, clock: .init(lastWorkoutEnd: at(20, 20), sleepEnd: nil), now: at(20, 0)),
            "pushed past quiet hours, dropped"
        )
        XCTAssertEqual(
            NudgeBackgroundRefresh.nextMorning(after: noon, calendar: cal),
            cal.date(bySettingHour: 8, minute: 30, second: 0, of: cal.date(byAdding: .day, value: 1, to: Self.fixedDay)!)
        )
    }

    func testExperienceComposerMirrorsTheServer() {
        // The mock's twin of tracking/projection.py experience_for, pinned: each friction moves
        // one thing; only "Coach me along the way" (or never asked) hears invitations.
        let none = Experience.composed(level: nil, frictions: [])
        XCTAssertTrue(none.offersInvitations)
        XCTAssertFalse(none.eveningReminder)
        XCTAssertEqual(none.amountChecks, "standard")
        XCTAssertFalse(none.showsPhotoHint)
        XCTAssertFalse(none.seedUsuals)
        let quiet = Experience.composed(level: .essential, frictions: [.forgetting, .portions, .eatingOut, .time])
        XCTAssertFalse(quiet.offersInvitations)
        XCTAssertTrue(quiet.eveningReminder)
        XCTAssertEqual(quiet.amountChecks, "eager")
        XCTAssertTrue(quiet.showsPhotoHint)
        XCTAssertTrue(quiet.seedUsuals)
        XCTAssertTrue(Experience.composed(level: .standard, frictions: []).offersInvitations)
        XCTAssertFalse(Experience.composed(level: .off, frictions: []).offersInvitations)
    }

    func testInvitationCard() throws {
        let card = NudgeCard(
            id: "invite:calories", category: "invitation",
            message: "You've logged 14 of the last 21 days. Want to see your calories too?",
            proTip: "Your habits stay where they are. Calories would sit above them.",
            priority: 10, cooldownDays: 14, kind: "invitation", offerMode: "calories", declineKey: "calories"
        )
        let view = NudgeCardView(card: card, onDismiss: {}, onAccept: {}, onDeclineForever: {}).padding(16)
        let image = try RenderHarness.render(view, name: "invitation-card", height: 420)
        try assertGolden(image, named: "calories")
    }

    func testVoiceLogResultHabits() throws {
        // Habits: the name, the items with their amounts, the badge; no calories, no macros,
        // and the pill says "Log it" (spec 6.5).
        var result = MealCaptureFixtures.beefAndRice(mealType: .lunch)
        result.mode = TrackingMode.habits.rawValue
        let context = ResultContext(captureID: "c3", transcript: MealCaptureFixtures.defaultTranscript, result: result)
        let image = try RenderHarness.render(Self.resultView(context, printsNumbers: false), name: "voice-log-result-habits", height: 1500)
        try assertGolden(image, named: "habits")
    }

    // MARK: - The tour, What's New, the Action button, Apple Health (2026-09-25)

    func testHelpTourOverlayOnToday() async throws {
        // The overlay reads the targets' frames from the model; a render has no scene pass to
        // register them, so the calories card's frame is seeded where the populated Today
        // draws it, and the tour is started on that step.
        let model = TodayViewModel(service: MockTodayService(scenario: .populated), checkin: MockCheckinService(due: false), outcomes: MockCaptureOutcomes.shared, date: Self.fixedDay)
        await model.load()
        let tour = HelpTourModel(steps: HelpTourStep.Home.steps.filter { $0.id == HelpTourStep.Home.calories })
        tour.frames[HelpTourStep.Home.calories] = CGRect(x: 16, y: 300, width: 174, height: 150)
        tour.start()
        let page = TodayView(model: model, tour: tour, onProfile: {})
            .overlay { HelpTourOverlay(model: tour) }
        let image = try RenderHarness.render(page, name: "help-tour-calories", height: 900)
        try assertGolden(image, named: "calories")
    }

    func testRecognizedMealCard() throws {
        let usual = RecognizedMeal(
            id: "u1", name: "Metal detox smoothie",
            items: [
                RecognizedMealItem(name: "banana", amount: 1, unit: .piece, grams: 118, macros: NutrientProfile(kcal: 105, protein: 1.3, carbs: 27, fat: 0.4, fiber: 3.1)),
                RecognizedMealItem(name: "spinach", amount: 2, unit: .cup, grams: 60, macros: NutrientProfile(kcal: 14, protein: 1.7, carbs: 2.2, fat: 0.2, fiber: 1.3)),
                RecognizedMealItem(name: "protein powder", amount: 1, unit: .scoop, grams: 31, macros: NutrientProfile(kcal: 120, protein: 24, carbs: 3, fat: 1.5, fiber: 0)),
            ],
            totals: NutrientProfile(kcal: 310, protein: 27, carbs: 32, fat: 2.1, fiber: 4.4),
            reason: "name"
        )
        let card = VStack(spacing: 12) {
            RecognizedMealCard(usual: usual, onYes: {}, onNo: {})
            RecognizedMealCard(usual: usual, isBusy: true, onYes: {}, onNo: {})
        }
        .padding(16)
        let image = try RenderHarness.render(card, name: "recognized-meal-card", height: 520)
        try assertGolden(image, named: "offered-and-busy")
    }

    func testWhatsNewSheet() throws {
        let image = try RenderHarness.render(WhatsNewSheet(content: .current, onContinue: {}), name: "whats-new", height: 900)
        try assertGolden(image, named: "current")
    }

    func testActionButtonAndHealthSteps() throws {
        let card = try RenderHarness.render(ActionButtonSetupCard(onDone: {}), name: "action-button-card", height: 520)
        try assertGolden(card, named: "action-button")
        let health = try RenderHarness.render(HealthPermissionStep(onDone: {}), name: "health-permission", height: 900)
        try assertGolden(health, named: "health")
    }
}

enum RenderFixtureError: Error {
    case unused
}

/// Synthetic weeks for the bar tests: four past days, today, two future days, one goal.
enum WeekMiniBarsFixtures {
    static func week(consumed: [Double], target: Int, baseline: Double, day: Date) -> WeekBudget {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        let monday = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: day))!
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "yyyy-MM-dd"
        let days = consumed.enumerated().map { index, kcal in
            WeekBudgetDay(
                date: formatter.string(from: calendar.date(byAdding: .day, value: index, to: monday)!),
                weekday: index,
                plannedKcal: Double(target),
                adjustedTargetKcal: target,
                consumedKcal: kcal,
                logged: true,
                state: index < 4 ? "past" : (index == 4 ? "today" : "future")
            )
        }
        let total = consumed.reduce(0, +)
        return WeekBudget(
            weekStart: days[0].date,
            weekEnd: days[6].date,
            baselineDailyKcal: baseline,
            weeklyTargetKcal: baseline * 7,
            carryKcal: 0,
            remainingKcal: baseline * 7 - total,
            fullyRebalanced: true,
            leftoverKcal: 0,
            targetsAreStub: false,
            days: days
        )
    }
}

/// Reads bar heights back out of a rendered image: for each x column, the length of the
/// run of non-white pixels measured up from the bottom edge.
enum PixelProbe {
    static func filledHeights(in image: CGImage, columns: [Int]) -> [Int] {
        let width = image.width
        let height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(
            data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return columns.map { x in
            var run = 0
            for y in stride(from: height - 1, through: 0, by: -1) {
                let offset = (y * width + x) * 4
                let dark = Int(data[offset]) + Int(data[offset + 1]) + Int(data[offset + 2]) < 3 * 128
                if dark { run += 1 } else { break }
            }
            return run
        }
    }
}

private extension CGImage {
    func pngWrite(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try UIImage(cgImage: self).pngData()?.write(to: url)
    }
}
