import SwiftUI
import UserNotifications

/// Settings → Notifications: the coaching delivery level plus the SYSTEM permission
/// state, shown honestly. The level governs what Vo-Cal plans (server-enforced);
/// the iOS permission governs what can actually land. Conflating the two is how
/// "notifications are broken" reports happen, so both are visible and each says
/// what it controls.
struct NotificationSettingsView: View {
    @Binding var nudgeLevel: NudgeLevel
    @Environment(\.openURL) private var openURL

    @State private var permission: UNAuthorizationStatus?

    var body: some View {
        SettingsPageScaffold(title: "Notifications") {
            SettingsSectionLabel(title: "Coaching level")
                .padding(.top, VoCalTheme.Spacing.s)
            SettingsCard {
                ForEach(Array(NudgeLevel.allCases.enumerated()), id: \.element) { index, level in
                    if index > 0 { SettingsDetailDivider() }
                    levelRow(level)
                }
            }

            // The footer restates the SELECTED level's delivery promise (the engine
            // enforces it server-side) so the setting never overpromises.
            Text(nudgeLevel.detail)
                .font(VoCalTheme.Fonts.formLabel)
                .foregroundStyle(VoCalTheme.Colors.muted)
                .padding(.horizontal, VoCalTheme.Spacing.s)

            SettingsSectionLabel(title: "iOS permission")
                .padding(.top, VoCalTheme.Spacing.l)
            SettingsCard {
                permissionRow
            }
            if permission == .denied {
                Text("Notifications are turned off for Vo-Cal in iOS Settings, so nudges can't be delivered even while coaching is on.")
                    .font(VoCalTheme.Fonts.formLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
                    .padding(.horizontal, VoCalTheme.Spacing.s)
            }
        }
        .task { permission = await NudgeNotificationService.shared.currentStatus() }
    }

    private func levelRow(_ level: NudgeLevel) -> some View {
        Button {
            nudgeLevel = level
            NudgeCenter.shared.level = level
        } label: {
            HStack(spacing: VoCalTheme.Spacing.m) {
                Text(level.label)
                    .font(VoCalTheme.Fonts.primaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.ink)
                Spacer()
                if nudgeLevel == level {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(VoCalTheme.Colors.gold)
                }
            }
            .padding(.horizontal, VoCalTheme.Spacing.l)
            .padding(.vertical, VoCalTheme.Spacing.m)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.coaching-level.\(level.rawValue)")
        .accessibilityAddTraits(nudgeLevel == level ? [.isSelected] : [])
    }

    @ViewBuilder
    private var permissionRow: some View {
        switch permission {
        case .denied:
            SettingsRow(
                icon: "bell.slash",
                label: "Delivery",
                value: "Off in iOS Settings"
            ) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            }
        case .authorized, .provisional, .ephemeral:
            SettingsRow(
                icon: "bell", label: "Delivery", value: "Allowed", showsChevron: false
            )
        case .notDetermined:
            SettingsRow(
                icon: "bell", label: "Delivery", value: "Asked after your first log",
                showsChevron: false
            )
        case nil, .some:
            SettingsRow(icon: "bell", label: "Delivery", value: "…", showsChevron: false)
        }
    }
}

#Preview {
    NavigationStack {
        NotificationSettingsView(nudgeLevel: .constant(.essential))
    }
}
