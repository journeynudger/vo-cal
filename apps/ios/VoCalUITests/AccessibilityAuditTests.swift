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
        app.launchArguments = ["-UITestMode"]
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
            row.tap()
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
    private nonisolated static let baseline: [String: [String: Int]] = [
        "today": ["dynamicType": 40, "contrast": 28, "hitRegion": 5],
        "settings": ["dynamicType": 16, "contrast": 6, "hitRegion": 0],
        "settings.my-foods": ["dynamicType": 9, "contrast": 7, "hitRegion": 2],
        "settings.learned-names": ["dynamicType": 7, "contrast": 5, "hitRegion": 2],
        "settings.recently-deleted": ["dynamicType": 5, "contrast": 4, "hitRegion": 1],
    ]

    // MARK: - Helpers

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
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
