import SwiftUI

/// Settings (I2, redesigned 2026-08): a grouped, professional surface replacing the
/// original bare List — account identity up top, then navigable sections (My details /
/// My protocol / Weekly check-in / Notifications), version info, and the account
/// actions. Cream background + r24 cards, VoCalTheme tokens only.
///
/// Every row is REAL: it either navigates to live data (intake, active protocol),
/// opens a working flow (check-in), or performs an action (sign out / delete). No
/// dead controls — the "Meals per day" stepper lesson (audit 2026-07) stands: a
/// setting that silently does nothing is worse than no setting.
struct SettingsView: View {
    @AppStorage("vocal.onboarded") private var onboarded = false
    var api: APIClient = APIClient()

    @State private var confirmingDelete = false
    @State private var working = false
    @State private var errorMessage: String?
    @State private var nudgeLevel = NudgeCenter.shared.level
    @State private var accountEmail: String?
    @State private var anonymousAccount = false
    @State private var checkinDue = false
    @State private var showCheckIn = false
    @State private var path = NavigationPath()
    @State private var recalibration: RecalibrationPrompt?

    /// The seasonal rebuild prompt, present only while the server says the active
    /// protocol is past its recalibration age. `builtAt` is copy detail, not the
    /// trigger — the threshold is the server's (protocols/staleness.py).
    private struct RecalibrationPrompt {
        let builtAt: Date?
    }

    private enum Destination: String, Hashable {
        case progress
        case profile
        case protocolDetail = "protocol"
        case notifications
        case learnedNames = "learned-names"
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                VoCalTheme.Colors.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: VoCalTheme.Spacing.s) {
                        header
                        identityCard
                            .padding(.bottom, VoCalTheme.Spacing.m)

                        if let recalibration {
                            recalibrationCard(recalibration)
                                .padding(.bottom, VoCalTheme.Spacing.l)
                        }

                        SettingsSectionLabel(title: "Account")
                        accountCard
                            .padding(.bottom, VoCalTheme.Spacing.l)

                        SettingsSectionLabel(title: "Coaching")
                        coachingCard
                            .padding(.bottom, VoCalTheme.Spacing.l)

                        SettingsSectionLabel(title: "About")
                        aboutCard
                            .padding(.bottom, VoCalTheme.Spacing.l)

                        actionsCard
                        deleteFooter
                    }
                    .padding(.horizontal, VoCalTheme.Spacing.l)
                    .padding(.bottom, 120) // clear the floating bottom bar
                }
            }
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .progress: ProgressSettingsView(api: api)
                case .profile: ProfileSettingsView(api: api)
                case .protocolDetail: ProtocolSettingsView(api: api)
                case .notifications:
                    NotificationSettingsView(nudgeLevel: $nudgeLevel)
                case .learnedNames: LearnedNamesView(api: api)
                }
            }
            .sheet(isPresented: $showCheckIn) {
                CheckInView { _ in
                    showCheckIn = false
                    Task { await loadDynamicState() }
                }
            }
            .task { await loadDynamicState() }
            .onChange(of: path.count) { _, depth in
                // Back at the root: the Profile editor may have just rebuilt the protocol,
                // which retires the recalibration prompt. Without this the card survives
                // its own fix until the tab is re-entered — a claim the data no longer
                // supports. `.task` doesn't re-run on a pop, so re-read here.
                if depth == 0 { Task { await loadDynamicState() } }
            }
            .onAppear {
                // Headless-verification hook (DEBUG only, RuntimeMode): push a subpage
                // straight away so simctl screenshots can reach it without taps.
                if let raw = RuntimeMode.debugSettingsDestination,
                   let destination = Destination(rawValue: raw) {
                    path.append(destination)
                }
            }
            .disabled(working)
            .overlay {
                // Full-page BLOCKING overlay for sign-out / delete (bug 4): a scrim dims
                // and swallows touches instead of a spinner floating over live content.
                if working {
                    ZStack {
                        VoCalTheme.Colors.ink.opacity(0.45).ignoresSafeArea()
                        VoCalLoader(size: 40)
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: working)
            .alert("Delete account?", isPresented: $confirmingDelete) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) { Task { await deleteAccount() } }
            } message: {
                Text("This permanently deletes your account and all your data. This cannot be undone.")
            }
            .alert(
                "Couldn't delete account",
                isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
            ) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    // MARK: - Sections

    private var header: some View {
        Text("Profile")
            .font(.system(size: 30, weight: .semibold))
            .foregroundStyle(VoCalTheme.Colors.ink)
            .padding(.top, VoCalTheme.Spacing.s)
            .padding(.bottom, VoCalTheme.Spacing.m)
    }

    /// Who is signed in. Anonymous sessions and the mock path say so honestly
    /// rather than showing an empty pill.
    private var identityCard: some View {
        HStack(spacing: VoCalTheme.Spacing.m) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(VoCalTheme.Colors.gold)
            VStack(alignment: .leading, spacing: 1) {
                Text(identityTitle)
                    .font(VoCalTheme.Fonts.primaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle = identitySubtitle {
                    Text(subtitle)
                        .font(VoCalTheme.Fonts.formLabel)
                        .foregroundStyle(VoCalTheme.Colors.muted)
                }
            }
            Spacer()
        }
        .padding(VoCalTheme.Spacing.l)
        .background(
            VoCalTheme.Colors.card,
            in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.card, style: .continuous)
        )
    }

    private var identityTitle: String {
        if RuntimeMode.usesMockServices { return "Demo account" }
        if let accountEmail { return accountEmail }
        return anonymousAccount ? "Anonymous account" : "Signed in with Apple"
    }

    private var identitySubtitle: String? {
        if RuntimeMode.usesMockServices { return "Simulator mock data" }
        if anonymousAccount { return "Your data lives on this device's session" }
        return nil
    }

    /// Seasonal recalibration prompt (R7, decision #37 lightweight): the weekly check-in
    /// moves the numbers inside a protocol; after a quarter it's the ANSWERS that have
    /// aged (job, training, kids, stress). Tapping opens the Profile editor, where
    /// re-answering rebuilds the protocol. Deliberately not on Today and deliberately
    /// dismiss-free: Settings is a screen you come to rather than a feed, and the card
    /// clears itself the moment a rebuilt protocol exists — nothing to nag with.
    private func recalibrationCard(_ prompt: RecalibrationPrompt) -> some View {
        Button { path.append(Destination.profile) } label: {
            HStack(spacing: VoCalTheme.Spacing.m) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(VoCalTheme.Colors.gold)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Season's changed?")
                        .font(VoCalTheme.Fonts.primaryLabel)
                        .foregroundStyle(VoCalTheme.Colors.ink)
                    Text(Self.recalibrationBody(builtAt: prompt.builtAt))
                        .font(VoCalTheme.Fonts.formLabel)
                        .foregroundStyle(VoCalTheme.Colors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(VoCalTheme.Colors.muted)
            }
            .padding(VoCalTheme.Spacing.l)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            VoCalTheme.Colors.gold.opacity(0.12),
            in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.card, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: VoCalTheme.Radius.card, style: .continuous)
                .strokeBorder(VoCalTheme.Colors.gold.opacity(0.35), lineWidth: 1)
        )
        .accessibilityIdentifier("settings.recalibration-prompt")
    }

    /// Names the month the protocol was built when the server sent one, and stays
    /// honestly vague when it didn't.
    private static func recalibrationBody(builtAt: Date?) -> String {
        let age = builtAt.map { "from \($0.formatted(.dateTime.month(.wide).year()))" }
            ?? "a few months old"
        return "Your protocol is \(age). Life shifts, so rebuild it from today's you."
    }

    private var accountCard: some View {
        SettingsCard {
            NavigationLink(value: Destination.progress) {
                SettingsRow(icon: "chart.line.uptrend.xyaxis", label: "Progress")
            }
            .buttonStyle(.plain)
            SettingsDivider()
            NavigationLink(value: Destination.profile) {
                SettingsRow(icon: "person.text.rectangle", label: "My details")
            }
            .buttonStyle(.plain)
            SettingsDivider()
            NavigationLink(value: Destination.protocolDetail) {
                SettingsRow(icon: "target", label: "My protocol")
            }
            .buttonStyle(.plain)
            SettingsDivider()
            SettingsRow(
                icon: "calendar.badge.checkmark",
                label: "Weekly check-in",
                value: checkinDue ? "Ready" : nil,
                accessibilityID: "settings.weekly-checkin"
            ) { showCheckIn = true }
        }
    }

    private var coachingCard: some View {
        SettingsCard {
            NavigationLink(value: Destination.notifications) {
                SettingsRow(
                    icon: "bell.badge",
                    label: "Notifications",
                    value: nudgeLevel.label,
                    accessibilityID: "settings.notifications"
                )
            }
            .buttonStyle(.plain)
            SettingsDivider()
            // What the parser learned from renames (R9): visible, and forgettable.
            NavigationLink(value: Destination.learnedNames) {
                SettingsRow(
                    icon: "text.badge.checkmark",
                    label: "Learned names",
                    accessibilityID: "settings.learned-names"
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var aboutCard: some View {
        SettingsCard {
            SettingsRow(
                icon: "info.circle", label: "Version", value: Self.versionString,
                showsChevron: false
            )
            SettingsDivider()
            // Present only when the phone has written a crash or hang report
            // (CrashDiagnosticsRecorder): two taps to send it, invisible otherwise.
            let diagnostics = CrashDiagnosticsRecorder.shared.entries()
            if !diagnostics.isEmpty {
                ShareLink(items: diagnostics) {
                    SettingsRow(
                        icon: "square.and.arrow.up", label: "Share crash reports",
                        value: "\(diagnostics.count)", showsChevron: false
                    )
                }
                .buttonStyle(.plain)
                SettingsDivider()
            }
            // The I3 health-posture disclaimer, as a permanent, visible row body —
            // not a control, so no chevron and no action.
            Text("Vo-Cal provides nutrition information for educational purposes and is not medical advice.")
                .font(VoCalTheme.Fonts.formLabel)
                .foregroundStyle(VoCalTheme.Colors.muted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, VoCalTheme.Spacing.l)
                .padding(.vertical, VoCalTheme.Spacing.m)
        }
    }

    private var actionsCard: some View {
        SettingsCard {
            SettingsRow(
                icon: "rectangle.portrait.and.arrow.right",
                label: "Sign out",
                showsChevron: false
            ) { Task { await signOut() } }
            SettingsDivider()
            SettingsRow(
                icon: "trash",
                label: "Delete account",
                tint: VoCalTheme.Colors.alert,
                showsChevron: false,
                accessibilityID: "settings.delete-account"
            ) { confirmingDelete = true }
        }
    }

    private var deleteFooter: some View {
        Text("Deleting your account permanently removes your voice logs, meals, and protocol. This cannot be undone.")
            .font(VoCalTheme.Fonts.formLabel)
            .foregroundStyle(VoCalTheme.Colors.muted)
            .padding(.horizontal, VoCalTheme.Spacing.s)
            .padding(.top, VoCalTheme.Spacing.s)
    }

    private static var versionString: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (short, build) {
        case let (short?, build?): return "\(short) (\(build))"
        case let (short?, nil): return short
        default: return "unknown"
        }
    }

    // MARK: - State + actions

    /// Refresh the bits that can change under us: identity (session restore), the
    /// check-in due flag, and the notifications summary value (edited on the subpage).
    private func loadDynamicState() async {
        nudgeLevel = NudgeCenter.shared.level
        recalibration = await recalibrationPrompt()
        if RuntimeMode.usesMockServices {
            checkinDue = await MockCheckinService().isDue()
            return
        }
        accountEmail = AuthCoordinator.shared.accountEmail
        anonymousAccount = AuthCoordinator.shared.isAnonymousSession
        checkinDue = await LiveCheckinService(api: api).isDue()
    }

    /// Reads the active protocol's age from the server's flag. A stale protocol is a
    /// quiet fact, so an absent (404) or failed read simply shows no prompt — Settings
    /// never turns a background read into an error the user has to deal with.
    private func recalibrationPrompt() async -> RecalibrationPrompt? {
        if RuntimeMode.usesMockServices {
            // Mock path serves an aged protocol so the prompt is reachable with no
            // network (same posture as NudgeCenter's canned card).
            return RecalibrationPrompt(
                builtAt: Calendar.current.date(byAdding: .day, value: -120, to: Date())
            )
        }
        guard let response = try? await api.activeProtocol(),
              response.needsRecalibration == true else { return nil }
        return RecalibrationPrompt(builtAt: response.createdAt)
    }

    private func signOut() async {
        working = true
        if !RuntimeMode.usesMockServices { await AuthCoordinator.shared.signOut() }
        working = false
        onboarded = false
    }

    private func deleteAccount() async {
        working = true
        do {
            // Mock/sim path has no live account to delete — just reset local state.
            if !RuntimeMode.usesMockServices {
                try await api.deleteAccount()
                await AuthCoordinator.shared.signOut()
            }
            working = false
            onboarded = false
        } catch {
            working = false
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Please try again."
        }
    }
}

#Preview {
    SettingsView()
}
