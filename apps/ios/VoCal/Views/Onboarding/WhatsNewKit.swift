import SwiftUI

// Port provenance: Serein apps/ios/SereinApp/Sources/HowToUseKit.swift (HowToUseGate,
// HowToUseSheet). The gate is Serein's, key renamed. The sheet keeps Serein's shape (icon
// rows that scroll, one Continue that stays put) on Vo-Cal's cream with the black pill.
// Not ported: Serein's brand crest, its privacy footer and PrivacyDetailsView (Vo-Cal's
// privacy copy lives in Settings), and the seascape backdrop.

// MARK: - Gate

/// Tracks which build last showed the sheet, so an update explains itself once and stays quiet
/// after. Keyed by marketing version and build ("0.1.0-29"), Serein's key, so every new build
/// shows it once.
enum WhatsNewGate {
    static let lastSeenVersionKey = "vocal.whatsnew.last_seen_version"

    static var currentVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(short)-\(build)"
    }

    /// False on harness launches (UI tests, the accessibility audit, the voice self-test)
    /// unless `-ShowWhatsNew` is passed: a surprise sheet would cover the screen under test.
    static func shouldShow(userDefaults: UserDefaults = .standard) -> Bool {
        _ = resetIfForced
        if FirstRunHarness.isHarnessLaunch, !FirstRunHarness.forces(FirstRunHarness.showWhatsNewArgument) {
            return false
        }
        return userDefaults.string(forKey: lastSeenVersionKey) != currentVersion
    }

    static func markSeen(userDefaults: UserDefaults = .standard) {
        userDefaults.set(currentVersion, forKey: lastSeenVersionKey)
    }

    static func reset(userDefaults: UserDefaults = .standard) {
        userDefaults.removeObject(forKey: lastSeenVersionKey)
    }

    /// `-ShowWhatsNew` clears the seen version once per launch, so the sheet shows once and
    /// then honors `markSeen()` like any other launch.
    private static let resetIfForced: Void = {
        if FirstRunHarness.forces(FirstRunHarness.showWhatsNewArgument) {
            reset()
        }
    }()
}

// MARK: - Content

/// What the sheet says. `current` describes this release; the next release edits its rows.
struct WhatsNewContent: Equatable, Sendable {
    struct Row: Identifiable, Equatable, Sendable {
        /// SF Symbol name.
        let symbol: String
        let title: String
        let body: String

        var id: String {
            title
        }
    }

    /// The marketing version the rows describe, shown under the title when non-empty.
    let version: String
    let rows: [Row]

    static var current: WhatsNewContent {
        WhatsNewContent(
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            rows: [
                // The calm home (decision 75, 2026-11-06). An update is the only time a tester
                // who already onboarded hears about it: the bubbles never reach them, so each
                // row says where the thing lives, and the rows before this release stay in the
                // git history, not here (a sheet is for what changed).
                Row(
                    symbol: "fork.knife",
                    title: "Your day, meal by meal",
                    body: "Breakfast, lunch, dinner and snacks, each with what went in it and its own Add. One line at the top says where the day stands."
                ),
                Row(
                    symbol: "mic",
                    title: "One button: Log a meal",
                    body: "Say it, type it, snap it or scan it, into the meal you choose. Your usuals are one tap, water too."
                ),
                Row(
                    symbol: "barcode.viewfinder",
                    title: "Scan a barcode",
                    body: "Point the camera at a package. Vo-Cal reads the label, shows the serving and logs it as one of your foods."
                ),
                Row(
                    symbol: "bubble.left.and.text.bubble.right",
                    title: "One chat for everything",
                    body: "Ask for a number, change how you track, or log a meal, in the same place. What you say is shown as you said it, then what it became."
                ),
                Row(
                    symbol: "chart.bar",
                    title: "Progress",
                    body: "Your cards, your week and your check-in, behind the Today card on the home."
                ),
            ]
        )
    }
}

// MARK: - Sheet

/// The update sheet: a title, icon rows that scroll, one black Continue that stays put. Present
/// it with `.sheet`; it sets its own cream background and 34 pt corners. The shell marks the
/// gate seen in the sheet's `onDismiss`, so a swipe down counts the same as Continue.
struct WhatsNewSheet: View {
    let content: WhatsNewContent
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: VoCalTheme.Spacing.xs) {
                Text("What's new in Vo-Cal")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(VoCalTheme.Colors.ink)
                    .accessibilityAddTraits(.isHeader)
                if !content.version.isEmpty {
                    Text("Version \(content.version)")
                        .font(VoCalTheme.Fonts.secondaryLabel)
                        .foregroundStyle(VoCalTheme.Colors.muted)
                }
            }
            .padding(.top, 34)
            .padding(.bottom, VoCalTheme.Spacing.xl)

            // The rows scroll; Continue stays put beneath them. Serein's seven rows pushed
            // Continue off the bottom of the sheet ("the continue button is not even
            // appearing"; Lorenzo, 2026-09-19).
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(content.rows) { row in
                        rowView(row)
                    }
                }
                .padding(.bottom, VoCalTheme.Spacing.s)
            }
            .scrollBounceBehavior(.basedOnSize)

            PillButton(title: "Continue", action: onContinue)
                .accessibilityIdentifier(A11y.WhatsNew.continueButton)
                .padding(.top, VoCalTheme.Spacing.l)
                .padding(.bottom, VoCalTheme.Spacing.m)
        }
        .padding(.horizontal, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(VoCalTheme.Colors.background.ignoresSafeArea())
        .presentationCornerRadius(34)
        .presentationBackground(VoCalTheme.Colors.background)
        .accessibilityIdentifier(A11y.WhatsNew.sheet)
    }

    private func rowView(_ row: WhatsNewContent.Row) -> some View {
        HStack(alignment: .top, spacing: VoCalTheme.Spacing.l) {
            Image(systemName: row.symbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(VoCalTheme.Colors.gold)
                .frame(width: 36, alignment: .center)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(row.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(VoCalTheme.Colors.ink)
                Text(row.body)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(VoCalTheme.Colors.muted)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Accessibility identifiers

extension A11y {
    enum WhatsNew {
        static let sheet = "whatsnew.sheet"
        static let continueButton = "whatsnew.continue-button"
    }
}

#Preview("What's new") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            WhatsNewSheet(content: .current) {}
        }
}
