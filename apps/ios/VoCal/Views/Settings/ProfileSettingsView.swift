import SwiftUI

/// Settings → Profile: the latest persisted intake, read-only. These answers shaped
/// the protocol; they are not casually editable here because nothing downstream
/// re-derives from a lone field edit (the dead-stepper lesson, audit 2026-07) — the
/// weekly check-in is the calibrated path for change, and the footer says so.
struct ProfileSettingsView: View {
    var api: APIClient = APIClient()

    private enum ViewState {
        case loading
        case loaded(IntakeProfile)
        case empty
        case failed
    }

    @State private var state: ViewState = .loading

    var body: some View {
        SettingsPageScaffold(title: "Profile") {
            switch state {
            case .loading:
                VoCalLoader(size: 40)
                    .frame(maxWidth: .infinity)
                    .padding(.top, VoCalTheme.Spacing.xxl)
            case let .loaded(profile):
                loaded(profile)
            case .empty:
                message(
                    "No profile yet",
                    "Finish onboarding and your answers will show up here."
                )
            case .failed:
                VStack(spacing: VoCalTheme.Spacing.l) {
                    message("Couldn't load your profile", "Check your connection and try again.")
                    PillButton(title: "Try again") {
                        state = .loading
                        Task { await load() }
                    }
                    .padding(.horizontal, VoCalTheme.Spacing.xxl)
                }
            }
        }
        .task { await load() }
    }

    @ViewBuilder
    private func loaded(_ profile: IntakeProfile) -> some View {
        SettingsSectionLabel(title: "The basics")
            .padding(.top, VoCalTheme.Spacing.s)
        SettingsCard {
            SettingsDetailRow(label: "Age", value: "\(profile.age)")
            SettingsDetailDivider()
            SettingsDetailRow(label: "Height", value: heightLabel(profile.heightIn))
            SettingsDetailDivider()
            SettingsDetailRow(label: "Weight", value: "\(Int(profile.weightLb.rounded())) lb")
            SettingsDetailDivider()
            SettingsDetailRow(label: "Sex", value: label(profile.sex, Self.sexLabels))
        }

        SettingsSectionLabel(title: "Goal & life")
            .padding(.top, VoCalTheme.Spacing.l)
        SettingsCard {
            SettingsDetailRow(label: "Goal", value: label(profile.goal, Self.goalLabels))
            SettingsDetailDivider()
            SettingsDetailRow(label: "Work", value: label(profile.work, Self.workLabels))
            SettingsDetailDivider()
            SettingsDetailRow(label: "Training", value: label(profile.train, Self.trainLabels))
            SettingsDetailDivider()
            SettingsDetailRow(label: "Young kids at home", value: profile.kids ? "Yes" : "No")
            SettingsDetailDivider()
            SettingsDetailRow(label: "Stress & sleep", value: label(profile.stress, Self.stressLabels))
            SettingsDetailDivider()
            SettingsDetailRow(label: "Appetite medication", value: label(profile.med, Self.medLabels))
            if let meals = profile.mealsPerDay {
                SettingsDetailDivider()
                SettingsDetailRow(label: "Meals per day", value: "\(meals)")
            }
        }

        Text("These answers built your protocol. As life changes, the weekly check-in is where Vo-Cal recalibrates — no need to edit numbers by hand.")
            .font(VoCalTheme.Fonts.formLabel)
            .foregroundStyle(VoCalTheme.Colors.muted)
            .padding(.horizontal, VoCalTheme.Spacing.s)
            .padding(.top, VoCalTheme.Spacing.s)
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

    private func load() async {
        if RuntimeMode.usesMockServices {
            var draft = IntakeDraft()
            draft.sex = "female"
            state = .loaded(draft.profile)
            return
        }
        do {
            let record = try await api.latestIntake()
            state = .loaded(record.intake)
        } catch let APIError.status(code, _) where code == 404 {
            state = .empty
        } catch {
            state = .failed
        }
    }

    // MARK: - Display labels (mirror the intake options verbatim)

    private func label(_ raw: String, _ table: [String: String]) -> String {
        table[raw] ?? raw.capitalized
    }

    private func heightLabel(_ inches: Double) -> String {
        let whole = Int(inches.rounded())
        return "\(whole / 12)′ \(whole % 12)″"
    }

    private static let sexLabels = ["female": "Female", "male": "Male"]
    private static let goalLabels = [
        "cut": "Lose fat, keep muscle",
        "maintain": "Maintain",
        "gain": "Build muscle / gain",
    ]
    private static let workLabels = [
        "desk": "Mostly at a desk",
        "on_feet": "On my feet all day",
        "manual": "Physical / manual work",
    ]
    private static let trainLabels = [
        "none": "Not much yet",
        "light": "Light (1–2 days a week)",
        "moderate": "Moderate (3–4 days a week)",
        "heavy": "Heavy (5+ days a week)",
    ]
    private static let stressLabels = [
        "low": "Pretty steady",
        "moderate": "Normal ups and downs",
        "high": "Stressed / rough sleep",
    ]
    private static let medLabels = [
        "none": "None",
        "hunger_suppressing": "Curbs appetite",
        "hunger_increasing": "Increases appetite",
    ]
}

#Preview {
    NavigationStack {
        ProfileSettingsView()
    }
}
