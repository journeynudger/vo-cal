import XCTest

/// The ways into the bar and the capture's first seconds, driven on the real app in mock
/// mode. Build 30 shipped with three of them broken, and each is objective and cheap to check
/// (Lorenzo, 2026-09-24: automate what is objective, important and likely to break again):
///   - a tap on the page puts the keyboard away (the field held focus with no way out);
///   - the mark with nothing to send puts it away too;
///   - the plus opens Camera and Photos, and a tap on the page closes them;
///   - a tap just above the plus goes nowhere (it opened the row behind the bar);
///   - the mic stays where it is while a capture starts, sampled frame by frame (it moved
///     between "Starting" and "Listening", twice now: 2026-07 and build 30).
/// `bin/ios-flow-tests` runs this class; CI's iOS job runs it after the render tests.
@MainActor
final class CaptureFlowTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // The slow mock pace gives the mic test a window to sample; the other flows never capture.
        app.launchArguments = ["-UITestMode", "-SlowMockCapture"]
        app.launch()
        // Inline, not through the main-actor helper: setUp is nonisolated in XCTest.
        let today = app.descendants(matching: .any).matching(identifier: "today.calories-left").firstMatch
        XCTAssertTrue(today.waitForExistence(timeout: 10), "Today is on screen")
    }

    // By identifier, never by label: labels carry state (audit, 2026-09-25).
    private func byID(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private var field: XCUIElement { byID("capture.field") }
    private var plus: XCUIElement { app.buttons.matching(identifier: "capture.plus").firstMatch }
    private var mic: XCUIElement { app.buttons.matching(identifier: "capture.mic").firstMatch }
    private var keyboard: XCUIElement { app.keyboards.firstMatch }

    /// A tap on the page, well away from the bar and every card's control: the title area.
    private func tapThePage() {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
    }

    /// A touch at a point in the app's coordinate space.
    private func tap(at point: CGPoint) {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x, dy: point.y)).tap()
    }

    private func gone(_ element: XCUIElement, within timeout: TimeInterval) -> Bool {
        let absent = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter().wait(for: [absent], timeout: timeout) == .completed
    }

    func testATapOnThePagePutsTheKeyboardAway() {
        field.tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 3), "the keyboard came up")
        tapThePage()
        XCTAssertTrue(gone(keyboard, within: 3), "the keyboard went away on a tap outside the bar")
        XCTAssertTrue(mic.waitForExistence(timeout: 3), "the bar is back at rest, mic in its droplet")
    }

    func testTheMarkWithNothingToSendPutsTheKeyboardAway() {
        field.tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 3), "the keyboard came up")
        let mark = app.buttons.matching(identifier: "capture.send").firstMatch
        XCTAssertTrue(mark.waitForExistence(timeout: 3), "the mark sits in the card")
        XCTAssertEqual(mark.label, "Done", "with nothing to send the mark is the way out")
        mark.tap()
        XCTAssertTrue(gone(keyboard, within: 3), "the keyboard went away")
        XCTAssertTrue(mic.waitForExistence(timeout: 3), "the mic is back")
    }

    func testThePlusOffersCameraAndPhotosAndThePageClosesThem() {
        XCTAssertTrue(plus.waitForExistence(timeout: 3))
        let plusFrame = plus.frame
        // By coordinate, the way a finger lands: a touch, never an accessibility activation.
        // The plus took activations and no touches for a whole build (2026-09-24), which is
        // the failure this test exists to catch.
        tap(at: CGPoint(x: plusFrame.midX, y: plusFrame.midY))
        let camera = app.buttons["Camera"].firstMatch
        XCTAssertTrue(camera.waitForExistence(timeout: 3), "the menu opened with Camera on a touch at \(plusFrame)")
        XCTAssertTrue(app.buttons["Photos"].firstMatch.exists, "and Photos")
        tapThePage()
        XCTAssertTrue(gone(camera, within: 3), "the menu closed on a tap outside it")
        XCTAssertTrue(field.waitForExistence(timeout: 3), "the field is back")
        XCTAssertFalse(byID("voicelog.screen").exists, "and nothing behind the bar opened")
    }

    func testANearMissAboveThePlusGoesNowhere() {
        XCTAssertTrue(plus.waitForExistence(timeout: 3))
        let frame = plus.frame
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX, dy: frame.minY - 14))
            .tap()
        // Neither the unfinished recording (a capture sheet) nor the week's budget opened.
        XCTAssertFalse(byID("voicelog.screen").waitForExistence(timeout: 1.5), "no capture sheet")
        XCTAssertFalse(byID("week.screen").exists, "no week sheet")
        XCTAssertTrue(byID("today.calories-left").isHittable, "Today is still the page")
    }

    func testTheMicStaysStillWhileACaptureStarts() {
        XCTAssertTrue(mic.waitForExistence(timeout: 3))
        let tapped = Date()
        mic.tap()
        XCTAssertTrue(byID("voicelog.screen").waitForExistence(timeout: 5), "the capture opened")
        let bigMic = byID("voicelog.mic-button")
        let stop = byID("voicelog.stop-button")
        XCTAssertTrue(bigMic.waitForExistence(timeout: 3), "the big mic is on the capture surface")
        // Sample the mic's centre from the arming words until Stop (listening only) has been
        // up for a second: the boundary between the two is the frame that used to jump.
        var beforeListening: [CGPoint] = []
        var whileListening: [CGPoint] = []
        var listeningSince: Date?
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            let frame = bigMic.frame
            let listening = stop.exists
            if listening, listeningSince == nil { listeningSince = Date() }
            if frame.width > 0 {
                let centre = CGPoint(x: frame.midX, y: frame.midY)
                if listening { whileListening.append(centre) } else { beforeListening.append(centre) }
            }
            if let since = listeningSince, Date().timeIntervalSince(since) > 1 { break }
            usleep(40_000)
        }
        XCTAssertNotNil(listeningSince, "listening was confirmed (Stop appeared)")
        XCTAssertGreaterThan(beforeListening.count, 2, "sampled the mic while arming (listening after \(listeningSince.map { $0.timeIntervalSince(tapped) } ?? -1) s)")
        XCTAssertGreaterThan(whileListening.count, 2, "sampled the mic while listening")
        let all = beforeListening + whileListening
        let xs = all.map(\.x)
        let ys = all.map(\.y)
        XCTAssertLessThan((xs.max() ?? 0) - (xs.min() ?? 0), 1, "the mic did not move sideways: \(all)")
        XCTAssertLessThan((ys.max() ?? 0) - (ys.min() ?? 0), 1, "the mic did not move up or down: \(all)")
    }

}

