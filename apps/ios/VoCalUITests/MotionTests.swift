import XCTest

/// The motion loop (docs/UI_VERIFICATION.md, "Motion and latency"): what a still frame
/// cannot show. Scrolling Today, opening and closing the voice capture, typing into the
/// capture bar, each measured with XCTest's own metrics on the real app in mock mode:
///
///   - hitches while scrolling and while animating (`XCTOSSignpostMetric`, the frames the
///     display missed, in milliseconds per second of animation);
///   - the time from a tap to the first visible response (`XCTClockMetric`).
///
/// Baselines are XCTest's own (`.baseline` on the measure options, stored in the scheme's
/// plan); a run that is 10 percent worse than its baseline fails. Local and on demand
/// (`bin/ios-motion`), never on every push (Lorenzo, 2026-09-24: automate what is objective
/// and likely to break, not everything). The script also records the run as video and
/// tiles it into filmstrips for the outside critic.
@MainActor
final class MotionTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-UITestMode"]
        app.launch()
        // By identifier, never by label: a card title's spoken label carries its state
        // ("Calories left, goal met") and a label query missed it (2026-09-25).
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "today.calories-left").firstMatch.waitForExistence(timeout: 10), "Today is on screen")
    }

    /// A slow drag up and a fast flick down on Today: the glass cards and the week strip
    /// must not drop frames (finding: glass rows in a list dropped frames in Serein, which
    /// is why cards here are flat and only the chrome is glass).
    func testTodayScrollsWithoutHitches() throws {
        let page = app.descendants(matching: .any).matching(identifier: "today.screen").firstMatch
        XCTAssertTrue(page.exists)
        let options = XCTMeasureOptions()
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric, XCTOSSignpostMetric.scrollDecelerationMetric], options: options) {
            startMeasuring()
            page.swipeUp(velocity: .slow)
            page.swipeDown(velocity: .fast)
            page.swipeUp(velocity: .fast)
            page.swipeDown(velocity: .slow)
            stopMeasuring()
        }
    }

    /// Tap the mic, wait for the capture sheet, close it, back on Today: the transition
    /// must animate, not pop, and the first response must land within a frame or two.
    func testVoiceCaptureOpensAndClosesSmoothly() throws {
        let mic = app.buttons["Log a meal by voice"].firstMatch
        XCTAssertTrue(mic.waitForExistence(timeout: 5))
        let options = XCTMeasureOptions()
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        measure(metrics: [XCTClockMetric(), XCTOSSignpostMetric.navigationTransitionMetric], options: options) {
            startMeasuring()
            mic.tap()
            let screen = app.descendants(matching: .any).matching(identifier: "voicelog.screen").firstMatch
            XCTAssertTrue(screen.waitForExistence(timeout: 5), "the capture sheet opened")
            stopMeasuring()
            let cancel = app.buttons["voicelog.cancel-button"].firstMatch
            if cancel.waitForExistence(timeout: 3) {
                cancel.tap()
            } else {
                app.buttons["Close"].firstMatch.tap()
            }
            XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "today.calories-left").firstMatch.waitForExistence(timeout: 5), "back on Today")
        }
    }

    /// Typing into the bar: the field grows and the results panel rises with one spring;
    /// the keyboard's appearance is the transition measured.
    func testTypingIntoTheBarIsSmooth() throws {
        let field = app.descendants(matching: .any).matching(identifier: "capture.field").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let options = XCTMeasureOptions()
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        // The keyboard's rise has no signpost of its own; the clock from the tap to the results
        // panel is the number that moves when the bar's spring or the search debounce regresses.
        measure(metrics: [XCTClockMetric()], options: options) {
            startMeasuring()
            field.tap()
            field.typeText("chicken")
            let results = app.descendants(matching: .any).matching(identifier: "capture.search.results").firstMatch
            _ = results.waitForExistence(timeout: 3)
            stopMeasuring()
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 7))
            app.swipeDown()
        }
    }
}
