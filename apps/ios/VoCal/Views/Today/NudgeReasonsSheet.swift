import SwiftUI

/// The long-press's answer (decision 67, Serein's "This wasn't right"): three reasons, each
/// naming the one thing the app changes, and nothing to type. The reasons are the design's; the
/// words are the person's to pick. None is about the person.
struct NudgeReasonsSheet: View {
    var onPick: (NudgeReaction) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            VoCalTheme.Colors.background.ignoresSafeArea()
            VStack(alignment: .leading, spacing: VoCalTheme.Spacing.l) {
                VStack(alignment: .leading, spacing: VoCalTheme.Spacing.s) {
                    Text("This wasn't right")
                        .font(.system(size: 27, weight: .semibold))
                        .foregroundStyle(VoCalTheme.Colors.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text("Say which, and that one thing changes.")
                        .font(VoCalTheme.Fonts.secondaryLabel)
                        .foregroundStyle(VoCalTheme.Colors.muted)
                }
                SettingsCard {
                    row(.wrongTime, "Wrong time", "Later in the day from now on.")
                    SettingsDetailDivider()
                    row(.notForMe, "Not for me", "This one stays quiet until you turn it back on.")
                    SettingsDetailDivider()
                    row(.tooOften, "Too often", "Half as often.")
                }
                VoCalButton(title: "Never mind", kind: .tertiary) { dismiss() }
                    .accessibilityIdentifier(A11y.Today.reasonsCancel)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, VoCalTheme.Spacing.l)
            .padding(.top, VoCalTheme.Spacing.xl)
        }
        .accessibilityIdentifier(A11y.Today.nudgeReasons)
    }

    private func row(_ kind: NudgeReaction, _ title: String, _ support: String) -> some View {
        Button {
            VoCalHaptics.select()
            onPick(kind)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(VoCalTheme.Fonts.primaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.ink)
                Text(support)
                    .font(VoCalTheme.Fonts.formLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, VoCalTheme.Spacing.l)
            .padding(.vertical, VoCalTheme.Spacing.m)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(A11y.Today.reasonRow(kind.rawValue))
    }
}

/// The permission, asked in the person's own sentence (decision 67, spec N8): after the first
/// log, once, for a level other than "Nothing". Allow shows the system sheet; Not now is
/// remembered, and Settings → Notifications keeps the door.
struct NotificationPermissionCard: View {
    let level: NudgeLevel
    var onAllow: () -> Void
    var onNotNow: () -> Void

    var body: some View {
        GlassCard(accent: VoCalTheme.Colors.gold) {
            VStack(alignment: .leading, spacing: VoCalTheme.Spacing.m) {
                Text(sentence)
                    .font(.system(size: 15))
                    .foregroundStyle(VoCalTheme.Colors.ink)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: VoCalTheme.Spacing.m) {
                    VoCalButton(title: "Allow notifications", kind: .secondary, action: onAllow)
                        .accessibilityIdentifier(A11y.Today.permissionAllow)
                    VoCalButton(title: "Not now", kind: .tertiary, action: onNotNow)
                        .accessibilityIdentifier(A11y.Today.permissionNotNow)
                    Spacer(minLength: 0)
                }
            }
        }
        .accessibilityIdentifier(A11y.Today.permissionCard)
    }

    /// The person's own sentence back to them (NudgeLevel.label), then what Allow does.
    private var sentence: String {
        switch level {
        case .essential: "You asked for a reminder only when a day goes quiet. Allow notifications to get it."
        case .standard: "You asked to be coached along the way. Allow notifications to get the tips."
        case .off: ""
        }
    }
}

#Preview("Reasons") {
    NudgeReasonsSheet(onPick: { _ in })
}

#Preview("Permission") {
    NotificationPermissionCard(level: .essential, onAllow: {}, onNotNow: {})
        .padding()
        .background(VoCalTheme.Colors.background)
}
