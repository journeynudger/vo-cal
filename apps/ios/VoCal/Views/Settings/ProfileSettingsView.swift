import SwiftUI
import VoCalCore

/// Profile tab → My details: the intake answers, now EDITABLE. Numbers are never typed
/// into the protocol directly (the engine calculates, AGENTS.md #6): you change
/// the ANSWERS here and "Update my protocol" re-submits the intake and asks the
/// engine to rebuild, exactly the path onboarding used. Until you save, nothing
/// moves; after a save the new calorie target is shown as proof of the rebuild.
struct ProfileSettingsView: View {
    var api: APIClient = APIClient()

    private enum LoadState {
        case loading
        case ready
        case empty
        case failed
    }

    private enum SaveState: Equatable {
        case idle
        case saving
        case saved(kcal: Int, version: Int)
        case failed(String)
    }

    @State private var loadState: LoadState = .loading
    @State private var saveState: SaveState = .idle

    // Editable answers (mirrors IntakeDraft's fields; loaded from the server).
    @State private var age = 34
    @State private var sex = "female"
    @State private var heightIn = 66.0
    @State private var weightLb = 172.0
    @State private var desiredWeightLb = 172.0
    @State private var goal = "cut"
    @State private var work = "desk"
    @State private var train = "moderate"
    @State private var kids = false
    @State private var med = "none"
    @State private var stress = "moderate"
    @State private var mealsPerDay = 4

    /// The answers as loaded — the dirty check and the discard target.
    @State private var baseline: IntakeProfile?

    var body: some View {
        SettingsPageScaffold(title: "My details") {
            switch loadState {
            case .loading:
                VoCalLoader(size: 40)
                    .frame(maxWidth: .infinity)
                    .padding(.top, VoCalTheme.Spacing.xxl)
            case .ready:
                editor
            case .empty:
                message(
                    "No details yet",
                    "Finish onboarding and your answers will show up here."
                )
            case .failed:
                VStack(spacing: VoCalTheme.Spacing.l) {
                    message("Couldn't load your profile", "Check your connection and try again.")
                    PillButton(title: "Try again") {
                        loadState = .loading
                        Task { await load() }
                    }
                    .padding(.horizontal, VoCalTheme.Spacing.xxl)
                }
            }
        }
        .task { await load() }
    }

    // MARK: - Editor

    @ViewBuilder
    private var editor: some View {
        SettingsSectionLabel(title: "The basics")
            .padding(.top, VoCalTheme.Spacing.s)
        SettingsCard {
            menuRow("Sex", selection: $sex, options: Self.sexOptions)
            SettingsDetailDivider()
            BasicsEditor(age: $age, heightIn: $heightIn, weightLb: $weightLb)
                .padding(.horizontal, VoCalTheme.Spacing.xs)
            SettingsDetailDivider()
            DesiredWeightWheelRow(desiredWeightLb: $desiredWeightLb)
        }

        SettingsSectionLabel(title: "Goal & life")
            .padding(.top, VoCalTheme.Spacing.l)
        SettingsCard {
            menuRow("Goal", selection: $goal, options: Self.goalOptions)
            SettingsDetailDivider()
            menuRow("Work", selection: $work, options: Self.workOptions)
            SettingsDetailDivider()
            menuRow("Training", selection: $train, options: Self.trainOptions)
            SettingsDetailDivider()
            menuRow(
                "Young kids at home",
                selection: Binding(get: { kids ? "yes" : "no" }, set: { kids = ($0 == "yes") }),
                options: [("no", "No"), ("yes", "Yes")]
            )
            SettingsDetailDivider()
            menuRow("Stress & sleep", selection: $stress, options: Self.stressOptions)
            SettingsDetailDivider()
            menuRow("Appetite medication", selection: $med, options: Self.medOptions)
            SettingsDetailDivider()
            menuRow(
                "Meals per day",
                selection: Binding(get: { String(mealsPerDay) }, set: { mealsPerDay = Int($0) ?? 4 }),
                options: [("2", "2"), ("3", "3"), ("4", "4"), ("5", "5")]
            )
        }

        saveSection
            .padding(.top, VoCalTheme.Spacing.l)
    }

    @ViewBuilder
    private var saveSection: some View {
        switch saveState {
        case .saving:
            HStack(spacing: VoCalTheme.Spacing.m) {
                VoCalLoader(size: 22)
                Text("Rebuilding your protocol…")
                    .font(VoCalTheme.Fonts.secondaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, VoCalTheme.Spacing.m)
        case let .saved(kcal, version):
            // Proof of the rebuild: the engine's new number, not a bare "Saved".
            VStack(spacing: VoCalTheme.Spacing.xs) {
                HStack(spacing: VoCalTheme.Spacing.s) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(VoCalTheme.Colors.optimal)
                    Text("Protocol updated to v\(version)")
                        .font(VoCalTheme.Fonts.primaryLabel)
                        .foregroundStyle(VoCalTheme.Colors.ink)
                }
                Text("New daily target: \(kcal.formatted(.number.grouping(.automatic))) kcal")
                    .font(VoCalTheme.Fonts.secondaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
            }
            .frame(maxWidth: .infinity)
            .padding(VoCalTheme.Spacing.l)
            .background(
                VoCalTheme.Colors.optimal.opacity(0.10),
                in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.chip, style: .continuous)
            )
        case .idle, .failed:
            VStack(spacing: VoCalTheme.Spacing.s) {
                if case let .failed(reason) = saveState {
                    Text(reason)
                        .font(VoCalTheme.Fonts.formLabel)
                        .foregroundStyle(VoCalTheme.Colors.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, VoCalTheme.Spacing.s)
                }
                PillButton(title: "Update my protocol") {
                    Task { await save() }
                }
                .disabled(!isDirty)
                .opacity(isDirty ? 1 : 0.45)
                .accessibilityIdentifier("settings.profile.update-protocol")
                Text("Rebuilds your calorie and nutrient targets from these answers. Your logged meals and history stay exactly as they are.")
                    .font(VoCalTheme.Fonts.formLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func menuRow(
        _ label: String, selection: Binding<String>, options: [(value: String, label: String)]
    ) -> some View {
        Menu {
            Picker(label, selection: selection) {
                ForEach(options, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
        } label: {
            HStack {
                Text(label)
                    .font(VoCalTheme.Fonts.secondaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
                Spacer()
                Text(options.first { $0.value == selection.wrappedValue }?.label ?? "Choose")
                    .font(VoCalTheme.Fonts.primaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(VoCalTheme.Colors.muted)
            }
            .padding(.horizontal, VoCalTheme.Spacing.l)
            .padding(.vertical, VoCalTheme.Spacing.m)
            .contentShape(Rectangle())
        }
    }

    // MARK: - State

    private var currentProfile: IntakeProfile {
        IntakeProfile(
            age: age, sex: sex, heightIn: heightIn, weightLb: weightLb,
            desiredWeightLb: desiredWeightLb,
            goal: goal, work: work, train: train, kids: kids,
            med: med, stress: stress, mealsPerDay: mealsPerDay
        )
    }

    private var isDirty: Bool {
        guard let baseline else { return false }
        return currentProfile != baseline
    }

    private func apply(_ profile: IntakeProfile) {
        age = profile.age
        sex = profile.sex
        heightIn = profile.heightIn
        weightLb = profile.weightLb
        desiredWeightLb = profile.desiredWeightLb ?? profile.weightLb
        goal = profile.goal
        work = profile.work
        train = profile.train
        kids = profile.kids
        med = profile.med
        stress = profile.stress
        mealsPerDay = profile.mealsPerDay ?? 4
        baseline = currentProfile
    }

    private func load() async {
        if RuntimeMode.usesMockServices {
            var draft = IntakeDraft()
            draft.sex = "female"
            apply(draft.profile)
            loadState = .ready
            return
        }
        do {
            let record = try await api.latestIntake()
            apply(record.intake)
            loadState = .ready
        } catch let APIError.status(code, _) where code == 404 {
            loadState = .empty
        } catch {
            loadState = .failed
        }
    }

    /// The onboarding path, replayed: persist the intake, ask the engine to rebuild.
    /// The generate call is the one that must succeed for the "updated" claim.
    private func save() async {
        saveState = .saving
        let profile = currentProfile
        if RuntimeMode.usesMockServices {
            try? await Task.sleep(for: .milliseconds(500))
            baseline = profile
            saveState = .saved(kcal: ProtocolTargets.personaFixture.kcal, version: 2)
            return
        }
        do {
            _ = try? await api.submitIntake(profile)
            let response = try await api.generateProtocol(intake: profile)
            baseline = profile
            saveState = .saved(kcal: response.targets.kcal, version: response.targets.version)
        } catch {
            saveState = .failed("The update didn't reach the server. Check your connection and try again.")
        }
    }

    private func message(_ title: String, _ sub: String) -> some View {
        VStack(spacing: VoCalTheme.Spacing.s) {
            Text(title)
                .font(VoCalTheme.Fonts.primaryLabel)
                .foregroundStyle(VoCalTheme.Colors.ink)
            Text(sub)
                .font(VoCalTheme.Fonts.secondaryLabel)
                .foregroundStyle(VoCalTheme.Colors.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, VoCalTheme.Spacing.xxl)
    }

    // MARK: - Option tables (mirror the intake options verbatim)

    private static let sexOptions = [("female", "Female"), ("male", "Male")]
    private static let goalOptions = [
        ("cut", "Lose fat, keep muscle"),
        ("maintain", "Maintain where I am"),
        ("gain", "Build muscle / gain"),
    ]
    private static let workOptions = [
        ("desk", "Mostly at a desk"),
        ("on_feet", "On my feet all day"),
        ("manual", "Physical / manual work"),
    ]
    private static let trainOptions = [
        ("none", "Not much yet"),
        ("light", "Light (1-2 days a week)"),
        ("moderate", "Moderate (3-4 days a week)"),
        ("heavy", "Heavy (5+ days a week)"),
    ]
    private static let stressOptions = [
        ("low", "Pretty steady"),
        ("moderate", "Normal ups and downs"),
        ("high", "Stressed / rough sleep"),
    ]
    private static let medOptions = [
        ("none", "None"),
        ("hunger_suppressing", "Curbs appetite"),
        ("hunger_increasing", "Increases appetite"),
    ]
}

/// Desired-weight wheel in the BasicsEditor row style: collapsed value row, tap to
/// expand a native wheel (invalid values impossible, same as onboarding's basics).
private struct DesiredWeightWheelRow: View {
    @Binding var desiredWeightLb: Double
    @State private var expanded = false

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack {
                    Text("Desired weight")
                        .font(VoCalTheme.Fonts.secondaryLabel)
                        .foregroundStyle(VoCalTheme.Colors.muted)
                    Spacer()
                    Text("\(Int(desiredWeightLb.rounded())) lb")
                        .font(VoCalTheme.Fonts.primaryLabel)
                        .foregroundStyle(expanded ? VoCalTheme.Colors.gold : VoCalTheme.Colors.ink)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(VoCalTheme.Colors.muted)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .padding(.horizontal, VoCalTheme.Spacing.l)
                .padding(.vertical, VoCalTheme.Spacing.m)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                Picker("Desired weight", selection: Binding(
                    get: { Int(desiredWeightLb.rounded()) },
                    set: { desiredWeightLb = Double($0) }
                )) {
                    ForEach(70...500, id: \.self) { Text("\($0) lb").tag($0) }
                }
                .pickerStyle(.wheel)
                .labelsHidden()
                .frame(height: 150)
                .clipped()
                .padding(.bottom, VoCalTheme.Spacing.s)
            }
        }
    }
}

#Preview {
    NavigationStack {
        ProfileSettingsView()
    }
}
