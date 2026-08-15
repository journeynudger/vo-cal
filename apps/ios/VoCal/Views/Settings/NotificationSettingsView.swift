import SwiftUI
import UserNotifications

/// Settings → Notifications: the smart-nudge toggle plus the SYSTEM permission
/// state, shown honestly. The toggle governs what Vo-Cal plans; the iOS permission
/// governs what can actually land — conflating the two is how "notifications are
/// broken" reports happen, so both are visible and each says what it controls.
struct NotificationSettingsView: View {
    @Binding var nudgesEnabled: Bool
    @Environment(\.openURL) private var openURL

    @State private var permission: UNAuthorizationStatus?

    var body: some View {
        SettingsPageScaffold(title: "Notifications") {
            SettingsSectionLabel(title: "Smart nudges")
                .padding(.top, VoCalTheme.Spacing.s)
            SettingsCard {
                HStack(spacing: VoCalTheme.Spacing.m) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(VoCalTheme.Colors.ink)
                        .frame(width: 34, height: 34)
                        .background(
                            VoCalTheme.Colors.background,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                    Text("Smart nudges")
                        .font(VoCalTheme.Fonts.primaryLabel)
                        .foregroundStyle(VoCalTheme.Colors.ink)
                    Spacer()
                    Toggle("", isOn: $nudgesEnabled)
                        .labelsHidden()
                        .tint(VoCalTheme.Colors.gold)
                        .accessibilityIdentifier("settings.smart-nudges")
                }
                .padding(.horizontal, VoCalTheme.Spacing.l)
                .padding(.vertical, VoCalTheme.Spacing.m)
            }
            .onChange(of: nudgesEnabled) { _, enabled in
                NudgeCenter.shared.isEnabled = enabled
            }

            Text("Timely, supportive tips based on your own logging — a gentle reminder if you go quiet, a heads-up when there's room for a treat. Never more than two a day.")
                .font(VoCalTheme.Fonts.formLabel)
                .foregroundStyle(VoCalTheme.Colors.muted)
                .padding(.horizontal, VoCalTheme.Spacing.s)

            SettingsSectionLabel(title: "iOS permission")
                .padding(.top, VoCalTheme.Spacing.l)
            SettingsCard {
                permissionRow
            }
            if permission == .denied {
                Text("Notifications are turned off for Vo-Cal in iOS Settings, so nudges can't be delivered even while smart nudges are on.")
                    .font(VoCalTheme.Fonts.formLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
                    .padding(.horizontal, VoCalTheme.Spacing.s)
            }
        }
        .task { permission = await NudgeNotificationService.shared.currentStatus() }
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
            SettingsRow(icon: "bell", label: "Delivery", value: "—", showsChevron: false)
        }
    }
}

#Preview {
    NavigationStack {
        NotificationSettingsView(nudgesEnabled: .constant(true))
    }
}
