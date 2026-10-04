import SwiftUI
import UserNotifications

/// Settings → Notifications: how much Vo-Cal says, in the person's own three sentences (decision
/// 66, spec S3), plus the SYSTEM permission state, shown honestly. The level is the preference's
/// (`PUT /tracking`, where the engine reads it); the phone's value is a cache that follows the
/// server's echo, never the tap. The iOS permission governs what can actually land. Conflating
/// the two is how "notifications are broken" reports happen, so both are visible and each says
/// what it controls.
struct NotificationSettingsView: View {
    @Binding var nudgeLevel: NudgeLevel
    var service: any TrackingService = RuntimeMode.usesMockServices
        ? MockTrackingService() : LiveTrackingService()
    @Environment(\.openURL) private var openURL

    @State private var permission: UNAuthorizationStatus?
    @State private var saving = false
    /// Why the last change did not save; nil when it did.
    @State private var saveError: String?

    var body: some View {
        SettingsPageScaffold(title: "Notifications") {
            SettingsSectionLabel(title: "How much Vo-Cal says")
                .padding(.top, VoCalTheme.Spacing.s)
            SettingsCard {
                ForEach(Array(NudgeLevel.allCases.enumerated()), id: \.element) { index, level in
                    if index > 0 { SettingsDetailDivider() }
                    levelRow(level)
                }
            }
            .disabled(saving)

            // The footer restates the SELECTED level's delivery promise (the engine enforces it
            // server-side) so the setting never overpromises.
            Text(nudgeLevel.detail)
                .font(VoCalTheme.Fonts.formLabel)
                .foregroundStyle(VoCalTheme.Colors.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, VoCalTheme.Spacing.s)

            if let saveError {
                Text(saveError)
                    .font(VoCalTheme.Fonts.formLabel)
                    .foregroundStyle(VoCalTheme.Colors.alert)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, VoCalTheme.Spacing.s)
            }

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
            change(level)
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

    /// The preference is the owner: the row moves on the server's echo. A change that did not
    /// land says so and leaves the old row ticked (a false "changed" is a claim above proof).
    private func change(_ level: NudgeLevel) {
        guard level != nudgeLevel, !saving else { return }
        saving = true
        saveError = nil
        Task {
            do {
                let echo = try await service.update(TrackingUpdate(nudgeLevel: level))
                let landed = echo.nudgeLevel ?? level
                nudgeLevel = landed
                NudgeCenter.shared.level = landed
                VoCalHaptics.select()
            } catch {
                saveError = "That didn't reach the server. Check your connection and try again."
            }
            saving = false
        }
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
            // "Nothing" never shows the system prompt (spec S7); the row says so rather than
            // promising an ask that will not come.
            SettingsRow(
                icon: "bell", label: "Delivery",
                value: nudgeLevel == .off ? "Not asked" : "Asked after your first log",
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
