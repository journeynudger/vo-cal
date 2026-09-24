import SwiftUI
import UIKit

// Port provenance: Serein apps/ios/SereinApp/Sources/OnboardingCoachKit.swift
// (ActionButtonSetupCard on CoachCard, and OnboardingCoachStore's Action Button flag). As in
// Serein the card sits on the page above the capture bar, on its own frosted glass, pointing
// at the real controls; a first port showed it as a card inside a sheet, a container in a
// container (Lorenzo, build 30). The copy names Vo-Cal's App Shortcut (VoCalIntents.swift);
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
/// voice log. One frosted card, a title, two lines and two answers; either answer marks the
/// card prompted, so it never comes back on its own, and the shell hides it in `onDone`.
struct ActionButtonSetupCard: View {
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: VoCalTheme.Spacing.m) {
            Text("Start from anywhere")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(VoCalTheme.Colors.ink)
                .accessibilityAddTraits(.isHeader)

            // The picker under Settings > Action Button > Shortcut lists App Shortcuts by their
            // short title, so the card names "Log a meal" (VoCalShortcuts), not the Siri phrase.
            // Settings resumes wherever it was last left, so the card says what to do then
            // (Serein, 2026-09-18).
            VStack(alignment: .leading, spacing: VoCalTheme.Spacing.s) {
                Text("In Settings, choose Action Button, then Shortcut, then Log a meal under Vo-Cal. One press and it is listening.")
                    .foregroundStyle(VoCalTheme.Colors.ink.opacity(0.78))
                Text("If Settings opens on another page, tap Back until you see its main list.")
                    .foregroundStyle(VoCalTheme.Colors.muted)
            }
            .font(.system(size: 15, weight: .regular))
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: VoCalTheme.Spacing.m) {
                Button {
                    openSettings()
                    finish()
                } label: {
                    Text("Open Settings")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(VoCalTheme.Colors.onCta)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 11)
                        .background(VoCalTheme.Colors.cta, in: Capsule())
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityIdentifier(A11y.ActionButtonCard.openSettingsButton)

                Spacer(minLength: 0)

                Button {
                    finish()
                } label: {
                    Text("Later")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(VoCalTheme.Colors.muted)
                        .padding(.vertical, 11)
                        .padding(.horizontal, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityIdentifier(A11y.ActionButtonCard.laterButton)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(
            in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.card, style: .continuous),
            tint: CaptureBar.frost
        )
        .shadow(color: VoCalTheme.Glass.lift, radius: 16, y: 6)
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
            .padding(.horizontal, VoCalTheme.Spacing.l)
    }
    .background(VoCalTheme.Colors.background)
}
