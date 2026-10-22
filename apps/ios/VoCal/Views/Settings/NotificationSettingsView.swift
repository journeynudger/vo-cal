import SwiftUI
import UserNotifications

/// Settings → Notifications: how much Vo-Cal says, in the person's own three sentences (decision
/// 66, spec S3), plus the SYSTEM permission state, shown honestly. The level is the preference's
/// (`PUT /tracking`, where the engine reads it); the phone's value is a cache that follows the
/// server's echo, never the tap. The iOS permission governs what can actually land. Conflating
/// the two is how "notifications are broken" reports happen, so both are visible and each says
/// what it controls.
///
/// It is also Apple Health's one door after onboarding (the behavior-change spec's 6.12): while
/// the Health sheet has a read the person never answered, "Sleep and workouts" under Delivery
/// asks it, in the reminders' own terms. An updater from build 30 or 31 answered for active
/// energy alone; a Not now at the onboarding step answered nothing.
struct NotificationSettingsView: View {
    /// What iOS answers when the page asks: the notification permission, and whether the Health
    /// sheet has a read left to ask. The live page reads both on appear; a render passes them, so
    /// the page draws exactly the state it built on any simulator.
    struct SystemAnswers {
        var permission: UNAuthorizationStatus
        var health: HealthKitService.ReadAccess?
    }

    @Binding var nudgeLevel: NudgeLevel
    private let service: any TrackingService
    private let readsSystemOnAppear: Bool
    @Environment(\.openURL) private var openURL

    @State private var permission: UNAuthorizationStatus?
    /// Nil until read, and where Health is unavailable or cannot say: no door either way.
    @State private var health: HealthKitService.ReadAccess?
    @State private var askingHealth = false
    @State private var saving = false
    /// Why the last change did not save; nil when it did.
    @State private var saveError: String?

    init(
        nudgeLevel: Binding<NudgeLevel>,
        service: any TrackingService = RuntimeMode.usesMockServices ? MockTrackingService() : LiveTrackingService(),
        system: SystemAnswers? = nil
    ) {
        _nudgeLevel = nudgeLevel
        self.service = service
        readsSystemOnAppear = system == nil
        _permission = State(initialValue: system?.permission)
        _health = State(initialValue: system?.health)
    }

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

            // What the person said was not for them (decision 67), each with its way back.
            // Shown only when there is one: an empty section would be a claim about nothing.
            if !NudgeCenter.shared.muted.isEmpty {
                SettingsSectionLabel(title: "Muted")
                    .padding(.top, VoCalTheme.Spacing.l)
                SettingsCard {
                    ForEach(Array(NudgeCenter.shared.muted.enumerated()), id: \.element.id) { index, muted in
                        if index > 0 { SettingsDetailDivider() }
                        mutedRow(muted)
                    }
                }
                Text("Nudges you said were not for you. Each stays quiet until you turn it back on.")
                    .font(VoCalTheme.Fonts.formLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, VoCalTheme.Spacing.s)
            }

            SettingsSectionLabel(title: "iOS permission")
                .padding(.top, VoCalTheme.Spacing.l)
            SettingsCard {
                permissionRow
                if offersHealth {
                    SettingsDivider()
                    healthRow
                }
            }
            if permission == .denied {
                Text("Notifications are turned off for Vo-Cal in iOS Settings, so nudges can't be delivered even while coaching is on.")
                    .font(VoCalTheme.Fonts.formLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
                    .padding(.horizontal, VoCalTheme.Spacing.s)
            }
            if offersHealth {
                Text("Use Apple Health to time reminders around your sleep and workouts. Read on your phone, never sent.")
                    .font(VoCalTheme.Fonts.formLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, VoCalTheme.Spacing.s)
            }
        }
        .task {
            guard readsSystemOnAppear else { return }
            permission = await NudgeNotificationService.shared.currentStatus()
            health = await HealthKitService.shared.readAccess()
        }
    }

    private var offersHealth: Bool {
        Self.offersHealth(health, level: nudgeLevel)
    }

    /// The door is open only while the sheet has a read left to ask (asked once: after the answer
    /// iOS would show nothing, so nothing offers it) and the person hears reminders at all
    /// ("Nothing" has nothing to time, and its Delivery row never asks either).
    static func offersHealth(_ health: HealthKitService.ReadAccess?, level: NudgeLevel) -> Bool {
        health == .unasked && level != .off
    }

    /// Named by what it adds, not "Apple Health": an updater already connected active energy, so
    /// "Apple Health, not asked yet" would be untrue for them. The value is the onboarding step's
    /// verb, not Delivery's "Not asked yet": beside that, this label wrapped to two lines on the
    /// render (2026-10-16: about 143 pt left for it on a 393 pt phone, 18 less on a 375 pt one;
    /// it needs 152). With "Connect" it holds one line at 375 pt (rendered 2026-10-22).
    private var healthRow: some View {
        SettingsRow(
            icon: "heart",
            label: "Sleep and workouts",
            value: "Connect",
            accessibilityID: A11y.Settings.healthAsk
        ) {
            askHealth()
        }
        .disabled(askingHealth)
    }

    /// The system's sheet comes from this tap and nothing else (the onboarding step's rule).
    /// After the answer the door closes, and the reminders re-plan so today's fires already move
    /// with the night and the day's training.
    private func askHealth() {
        guard !askingHealth else { return }
        askingHealth = true
        Task {
            _ = await HealthKitService.shared.requestAuthorization()
            health = await HealthKitService.shared.readAccess()
            askingHealth = false
            NudgeCenter.shared.refresh()
        }
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

    private func mutedRow(_ muted: MutedNudge) -> some View {
        HStack(spacing: VoCalTheme.Spacing.m) {
            Text(muted.title)
                .font(VoCalTheme.Fonts.primaryLabel)
                .foregroundStyle(VoCalTheme.Colors.ink)
            Spacer()
            Button("Turn back on") {
                NudgeCenter.shared.unmute(muted.id)
            }
            .font(VoCalTheme.Fonts.buttonLabel)
            .foregroundStyle(VoCalTheme.Colors.gold)
        }
        .padding(.horizontal, VoCalTheme.Spacing.l)
        .padding(.vertical, VoCalTheme.Spacing.m)
        .accessibilityIdentifier(A11y.Settings.mutedRow(muted.id))
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
        case .notDetermined where nudgeLevel == .off:
            // "Nothing" never shows the system prompt (spec S7); the row says so rather than
            // promising an ask that will not come.
            SettingsRow(icon: "bell", label: "Delivery", value: "Not asked", showsChevron: false)
        case .notDetermined:
            // The door the permission card leaves open (decision 67): a tap asks now, even after
            // a Not now on Today.
            SettingsRow(icon: "bell", label: "Delivery", value: "Not asked yet") {
                Task {
                    await NudgeCenter.shared.allowNotifications()
                    permission = await NudgeNotificationService.shared.currentStatus()
                }
            }
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
