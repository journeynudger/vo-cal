import SwiftUI
import UIKit

// Port provenance: Serein apps/ios/SereinApp/Sources/OnboardingCoachKit.swift
// (ActionButtonSetupCard and OnboardingCoachStore's Action Button flag). Serein's glass coach
// chrome becomes Vo-Cal's card; the copy names Vo-Cal's App Shortcut (VoCalIntents.swift);
// the flag is renamed and gated like the tour. Serein's Back Tap line is not ported.

// MARK: - Flag

/// Durable flag for the Action button card, so it shows once after the tour and a tour replay
/// can show it again.
enum ActionButtonCoachStore {
    static let promptedKey = "vocal.coach.action_button_prompted"

    static func hasPrompted(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.bool(forKey: promptedKey)
    }

    static func markPrompted(userDefaults: UserDefaults = .standard) {
        userDefaults.set(true, forKey: promptedKey)
    }

    static func reset(userDefaults: UserDefaults = .standard) {
        userDefaults.removeObject(forKey: promptedKey)
    }

    /// Whether the shell should show the card now. It follows the tour, so it takes the tour's
    /// gate: never on a harness launch unless `-ShowTour` is passed, which also clears this
    /// flag once per launch.
    static var shouldPrompt: Bool {
        _ = resetIfForced
        return HelpTourFlags.autoStartEnabled && !hasPrompted()
    }

    private static let resetIfForced: Void = {
        if FirstRunHarness.forces(FirstRunHarness.showTourArgument) {
            reset()
        }
    }()
}

// MARK: - Card

/// Invites the one setup that makes Vo-Cal ready at hand: a hardware press that opens the
/// voice log. Either answer marks the card prompted, so it never comes back on its own; the
/// shell only hides it in `onDone`.
struct ActionButtonSetupCard: View {
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: VoCalTheme.Spacing.m) {
            HStack(alignment: .firstTextBaseline, spacing: VoCalTheme.Spacing.s) {
                Image(systemName: "button.vertical.left.press")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(VoCalTheme.Colors.gold)
                    .accessibilityHidden(true)
                Text("Log with the Action button")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(VoCalTheme.Colors.ink)
                    .accessibilityAddTraits(.isHeader)
            }

            // The picker under Settings > Action Button > Shortcut lists App Shortcuts by their
            // short title, so the card names "Log a meal" (VoCalShortcuts), not the Siri phrase.
            VStack(alignment: .leading, spacing: VoCalTheme.Spacing.s) {
                Text("Settings > Action Button > Shortcut, then pick Log a meal under Vo-Cal. One press starts listening.")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(VoCalTheme.Colors.muted)
                // Settings resumes wherever it was last left, so the card says what to do then
                // (Serein, 2026-09-18).
                Text("If Settings opens on another page, tap Back until you see its main list.")
                    .font(VoCalTheme.Fonts.formLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
            }
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: VoCalTheme.Spacing.m) {
                PillButton(title: "Open Settings") {
                    openSettings()
                    finish()
                }
                .accessibilityIdentifier(A11y.ActionButtonCard.openSettingsButton)

                VoCalButton(title: "Later", kind: .tertiary) {
                    finish()
                }
                .accessibilityIdentifier(A11y.ActionButtonCard.laterButton)
            }
            .padding(.top, VoCalTheme.Spacing.xs)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            VoCalTheme.Colors.card,
            in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.card, style: .continuous)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(A11y.ActionButtonCard.card)
    }

    private func finish() {
        ActionButtonCoachStore.markPrompted()
        onDone()
    }

    /// Apple publishes no deep link into the Action Button pane, and iOS ignores every
    /// App-prefs root= path (Serein probe, 2026-09-02). "App-prefs:" opens the Settings app
    /// itself, whose main list is where Action Button lives; Vo-Cal's own page
    /// (openSettingsURLString) is only the fallback, because it is a sub page that left Lorenzo
    /// hunting for a way back in Serein (2026-09-18).
    private func openSettings() {
        Task { @MainActor in
            if let settingsApp = URL(string: "App-prefs:"), await UIApplication.shared.open(settingsApp) {
                return
            }
            guard let ownPage = URL(string: UIApplication.openSettingsURLString) else {
                return
            }
            _ = await UIApplication.shared.open(ownPage)
        }
    }
}

// MARK: - Accessibility identifiers

extension A11y {
    enum ActionButtonCard {
        static let card = "actionbutton.card"
        static let openSettingsButton = "actionbutton.open-settings-button"
        static let laterButton = "actionbutton.later-button"
    }
}

#Preview("Action button card") {
    VStack {
        Spacer()
        ActionButtonSetupCard {}
    }
    .padding(VoCalTheme.Spacing.l)
    .background(VoCalTheme.Colors.background)
}
