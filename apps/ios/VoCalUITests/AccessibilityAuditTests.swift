import XCTest

/// The slow UI loop: the real app on the simulator in mock mode, every screen audited by
/// XCTest's accessibility audit (clipped text, contrast, hit regions, Dynamic Type, missing
/// descriptions), and the bottom bar's controls proven hittable and on screen. Nightly in
/// CI (docs/UI_VERIFICATION.md); `bin/ios-ui-audit` locally.
final class AccessibilityAuditTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments = ["-UITestMode"]
        app.launch()
    }

    func testTodayPassesTheAudit() throws {
        XCTAssertTrue(app.otherElements["today.screen"].waitForExistence(timeout: 10))
        try app.performAccessibilityAudit()
        assertBottomBarHittable()
    }

    func testSettingsPagesPassTheAudit() throws {
        app.buttons["Profile"].firstMatch.tap()
        XCTAssertTrue(app.otherElements["settings.screen"].waitForExistence(timeout: 10))
        try app.performAccessibilityAudit()
        for identifier in ["settings.my-foods", "settings.learned-names", "settings.recently-deleted"] {
            let row = app.buttons[identifier].firstMatch
            if row.exists { row.tap() } else { app.staticTexts[identifier].firstMatch.tap() }
            try app.performAccessibilityAudit()
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
    }

    private func assertBottomBarHittable() {
        for label in ["Home", "Profile"] {
            let button = app.buttons[label].firstMatch
            XCTAssertTrue(button.exists, "\(label) tab exists")
            XCTAssertTrue(button.isHittable, "\(label) tab is hittable (not covered)")
            XCTAssertTrue(app.windows.firstMatch.frame.contains(button.frame), "\(label) tab is on screen")
        }
    }
}
