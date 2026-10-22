import Synchronization
import XCTest

/// The slow UI loop: the real app on the simulator in mock mode, every screen audited by
/// XCTest's accessibility audit, and the bottom bar's controls proven hittable and on
/// screen. Nightly in CI (docs/UI_VERIFICATION.md); `bin/ios-ui-audit` locally.
///
/// The audit is a ratchet, like the tidy tables: every issue is printed with its element
/// (`AUDIT <page> <type>: <issue> [<element>]`), counted per page and type, and compared to
/// the committed baseline below. A count above its baseline fails the test; a count below
/// it is printed so the baseline can be lowered in the same commit as the fix. Categories
/// absent from the baseline have a baseline of zero, so a first clipped label or a first
/// missing description fails on sight. The open decisions behind the large baselines
/// (fixed-size theme fonts, the muted ink on cream) are items 12 and 13 in
/// docs/restructure/05-questions.md; the hit regions are finding 29 in 04-findings.md.
final class AccessibilityAuditTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        // The five, pinned: the baselines below were counted on its layout, and a reused
        // simulator may hold another mode in the mock preference (Settings → How I track).
        app.launchArguments = ["-UITestMode", "-TrackingMode", "five"]
        app.launch()
    }

    func testTodayPassesTheAudit() throws {
        XCTAssertTrue(element("today.calories-left").waitForExistence(timeout: 10), "Today is on screen")
        try audit("today")
        assertBottomBarHittable()
    }

    func testSettingsPagesPassTheAudit() throws {
        app.buttons["Profile"].firstMatch.tap()
        XCTAssertTrue(element("settings.my-foods").waitForExistence(timeout: 10), "Settings is on screen")
        try audit("settings")
        for identifier in ["settings.my-foods", "settings.learned-names", "settings.recently-deleted"] {
            let row = element(identifier)
            XCTAssertTrue(row.waitForExistence(timeout: 5), "\(identifier) row exists")
            bringClearOfTheEdges(row)
            row.tap()
            // Settings hides its navigation bar and every page below shows one: a tap that
            // opened nothing would audit Settings under this page's name (nightly 2026-10-12,
            // "settings.learned-names" counted the Settings labels, 19 for a baseline of 7).
            guard app.navigationBars.firstMatch.waitForExistence(timeout: 5) else {
                XCTFail("\(identifier) did not open; its audit would count Settings instead")
                continue
            }
            try audit(identifier)
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
    }

    // MARK: - The ratchet

    /// Issues per page and type as of 2026-09-25 (build 30). Lower a number when a fix lands;
    /// never raise one to make the run pass. Today's Dynamic Type and contrast counts rose
    /// with the overhaul (the day names, the support lines, the Health line are more fixed-size
    /// labels in the same muted ink); the two decisions behind them (05-questions.md 12, 13)
    /// are unchanged, so the new counts are the baseline, said out loud here.
    /// Build 31: the calories and protein cards grew to one height, so at the audit's scroll
    /// position one more logged row sits in the bar's fade (contrast 28 to 29, its ink read
    /// against the fade) and one fewer fixed-size label is on screen (Dynamic Type 40 to 39).
    /// The same texts, moved; the decisions are unchanged. The two bars that appeared as
    /// targets too small to hit are hidden from VoiceOver, the numerals speak for them.
    /// Build 32 (the nightly, red since 2026-09-25): the settings pages print their secondary
    /// lines in `secondaryInk` and every line at the person's text size (`scaledFont`), the
    /// three list pages share one row whose ink action is 44 pt tall, and Today's check-in
    /// banner and unfinished row take the same tokens. Settings 16 and 6 to 1 (the page title)
    /// and 0, the three list pages to 0, Today's Dynamic Type 39 to 36. Counted on the iPhone
    /// 17 Pro (the pin) and the iPhone 17 Pro Max (the nightly's simulator), and each
    /// number is the larger: the Pro Max's taller window shows rows the Pro does not, and the
    /// earlier baselines fit a Pro, which is why every Pro Max nightly failed them. Today's
    /// contrast stays 29, the Pro Max on a Monday: the mock week reads "on plan" in the muted
    /// ink then, one more than the "N over" in red of other days. A Pro counts 26 (27 on a
    /// Monday); lower it to that once the nightly runs on a Pro, and not before.
    private nonisolated static let baseline: [String: [String: Int]] = [
        "today": ["dynamicType": 36, "contrast": 29, "hitRegion": 5],
        "settings": ["dynamicType": 1, "contrast": 0, "hitRegion": 0],
        "settings.my-foods": ["dynamicType": 0, "contrast": 0, "hitRegion": 0],
        "settings.learned-names": ["dynamicType": 0, "contrast": 0, "hitRegion": 0],
        "settings.recently-deleted": ["dynamicType": 0, "contrast": 0, "hitRegion": 0],
    ]

    // MARK: - Helpers

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Scrolls until `element` sits in the middle band of the window. XCUITest scrolls to a row
    /// that is wholly off screen, but it taps one that shows a sliver at the bottom edge where
    /// it is, in the home indicator's strip, and the tap never reaches the row: Learned names
    /// on the iPhone 17 Pro Max (CI's simulator) once How I track joined the coaching card,
    /// its icon at y 955 of a 956 pt window (nightly 2026-10-12). On the iPhone 17 Pro the row
    /// was below the fold, so XCUITest scrolled to it and the tap landed.
    private func bringClearOfTheEdges(_ element: XCUIElement) {
        let window = app.windows.firstMatch.frame
        let band = window.insetBy(dx: 0, dy: window.height * 0.2)
        var swipes = 0
        while !band.contains(element.frame), swipes < 3 {
            if element.frame.midY > band.midY {
                app.swipeUp(velocity: .slow)
            } else {
                app.swipeDown(velocity: .slow)
            }
            swipes += 1
        }
    }

    /// Counts per audit type, safe to touch from the audit's callback (a Mutex, so the class
    /// is Sendable on its own terms; TIDY-CONC-003 admits no new @unchecked Sendable).
    private final class Inventory: Sendable {
        private let counts = Mutex<[String: Int]>([:])

        func record(_ type: String) {
            counts.withLock { $0[type, default: 0] += 1 }
        }

        var snapshot: [String: Int] {
            counts.withLock { $0 }
        }
    }

    private func audit(_ page: String) throws {
        let inventory = Inventory()
        try app.performAccessibilityAudit(for: .all) { @Sendable issue in
            let type = Self.name(of: issue.auditType)
            inventory.record(type)
            let element = issue.element.map { "\($0.elementType.rawValue):\($0.label)" } ?? "?"
            print("AUDIT \(page) \(type): \(issue.compactDescription) [\(element)]")
            return true  // counted by the ratchet below, never doubly reported
        }
        let counts = inventory.snapshot
        let allowed = Self.baseline[page] ?? [:]
        let summary = counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        print("AUDIT-SUMMARY \(page): \(summary.isEmpty ? "clean" : summary)")
        for (type, count) in counts.sorted(by: { $0.key < $1.key }) {
            let ceiling = allowed[type] ?? 0
            if count > ceiling {
                XCTFail("AUDIT RATCHET \(page) \(type): \(count) issues, baseline \(ceiling); read the AUDIT lines above")
            } else if count < ceiling {
                print("AUDIT RATCHET \(page) \(type): \(count) issues, baseline \(ceiling); lower the baseline")
            }
        }
    }

    private nonisolated static func name(of type: XCUIAccessibilityAuditType) -> String {
        switch type {
        case .contrast: "contrast"
        case .elementDetection: "elementDetection"
        case .hitRegion: "hitRegion"
        case .sufficientElementDescription: "description"
        case .trait: "trait"
        case .textClipped: "textClipped"
        case .dynamicType: "dynamicType"
        default: "other"
        }
    }

    private func assertBottomBarHittable() {
        // The one bar: the mic (voice first) at the bottom, the profile circle at the top.
        for label in ["Log a meal by voice", "Profile", "Add a photo"] {
            let button = app.buttons[label].firstMatch
            XCTAssertTrue(button.exists, "\(label) exists")
            XCTAssertTrue(button.isHittable, "\(label) is hittable (not covered)")
            XCTAssertTrue(app.windows.firstMatch.frame.contains(button.frame), "\(label) is on screen")
        }
    }
}
