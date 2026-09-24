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

    private static func resultView(_ context: ResultContext) -> some View {
        VoiceLogResultView(
            context: context,
            mealType: .lunch,
            targetDayLabel: nil,
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
        let image = try RenderHarness.render(TodayView(model: model), name: "today-populated", height: 1900)
        try assertGolden(image, named: "populated")
    }

    func testTodayEmptyAtAccessibilitySize() async throws {
        let model = TodayViewModel(service: MockTodayService(scenario: .empty), checkin: MockCheckinService(due: false), outcomes: MockCaptureOutcomes.shared, date: Self.fixedDay)
        await model.load()
        let image = try RenderHarness.render(TodayView(model: model), name: "today-empty-accessibility2", height: 2600, dynamicType: .accessibility2)
        try assertGolden(image, named: "empty-accessibility2")
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
