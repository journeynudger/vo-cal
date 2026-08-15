import SwiftUI
import VoCalCore

/// Settings → My protocol: the ACTIVE protocol as the engine last computed it —
/// kcal hero, the home pillars with their tap-to-expand "whys", and the version
/// line. Same visual grammar as the onboarding reveal so the protocol looks like
/// one artifact everywhere; numbers are engine-owned (AGENTS.md #6) and this page
/// only renders them.
struct ProtocolSettingsView: View {
    var api: APIClient = APIClient()

    private enum ViewState {
        case loading
        case loaded(ProtocolTargets)
        case empty
        case failed
    }

    @State private var state: ViewState = .loading
    @State private var expanded: Set<String> = []

    var body: some View {
        SettingsPageScaffold(title: "My protocol") {
            switch state {
            case .loading:
                VoCalLoader(size: 40)
                    .frame(maxWidth: .infinity)
                    .padding(.top, VoCalTheme.Spacing.xxl)
            case let .loaded(targets):
                loaded(targets)
            case .empty:
                message(
                    "No protocol yet",
                    "Finish onboarding to build your protocol — it takes about three minutes."
                )
            case .failed:
                VStack(spacing: VoCalTheme.Spacing.l) {
                    message("Couldn't load your protocol", "Check your connection and try again.")
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
    private func loaded(_ t: ProtocolTargets) -> some View {
        // Calorie hero — the number the whole day is budgeted around.
        VStack(spacing: VoCalTheme.Spacing.xs) {
            Text("Daily calories")
                .font(VoCalTheme.Fonts.formLabel)
                .foregroundStyle(VoCalTheme.Colors.muted)
            Text(t.kcal.formatted(.number.grouping(.automatic)))
                .font(VoCalTheme.Fonts.numeral(56))
                .monospacedDigit()
                .foregroundStyle(VoCalTheme.Colors.gold)
            if let why = t.whys["kcal"] {
                Text(why)
                    .font(VoCalTheme.Fonts.formLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, VoCalTheme.Spacing.m)

        SettingsSectionLabel(title: "Daily targets")
        SettingsCard {
            targetRow("Protein", value: proteinValue(t), color: VoCalTheme.Colors.protein, whyKey: "protein", whys: t.whys)
            SettingsDetailDivider()
            targetRow("Water", value: "\(t.waterOz) oz", color: VoCalTheme.Colors.water, whyKey: "water", whys: t.whys)
            SettingsDetailDivider()
            targetRow("Fiber", value: "\(t.fiber) g", color: VoCalTheme.Colors.optimal, whyKey: "fiber", whys: t.whys)
            SettingsDetailDivider()
            targetRow("Produce", value: "\(t.produceServings) / day", color: VoCalTheme.Colors.muted, whyKey: "produce", whys: t.whys)
            SettingsDetailDivider()
            targetRow("Meals", value: "\(t.mealsPerDay) / day", color: VoCalTheme.Colors.muted, whyKey: "meals", whys: t.whys)
        }

        Text("Protocol v\(t.version) · recalibrated by your weekly check-in")
            .font(VoCalTheme.Fonts.formLabel)
            .foregroundStyle(VoCalTheme.Colors.muted)
            .frame(maxWidth: .infinity)
            .padding(.top, VoCalTheme.Spacing.s)

        Text("Not medical advice. These targets are a starting point from your inputs, not a clinical recommendation.")
            .font(VoCalTheme.Fonts.formLabel)
            .foregroundStyle(VoCalTheme.Colors.muted)
            .padding(VoCalTheme.Spacing.m)
            .background(
                VoCalTheme.Colors.card,
                in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.chip, style: .continuous)
            )
            .padding(.top, VoCalTheme.Spacing.m)
    }

    /// Protein renders its optimal band when the protocol carries one; the bare
    /// target otherwise (older protocols) — never a fabricated 0–0 range.
    private func proteinValue(_ t: ProtocolTargets) -> String {
        if t.proteinMax > t.proteinMin, t.proteinMin > 0 {
            return "\(t.proteinMin)–\(t.proteinMax) g"
        }
        return "\(t.protein) g"
    }

    private func targetRow(
        _ label: String, value: String, color: Color, whyKey: String, whys: [String: String]
    ) -> some View {
        let isOpen = expanded.contains(whyKey)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isOpen { expanded.remove(whyKey) } else { expanded.insert(whyKey) }
                }
            } label: {
                HStack(spacing: VoCalTheme.Spacing.m) {
                    Circle().fill(color).frame(width: 9, height: 9)
                    Text(label)
                        .font(VoCalTheme.Fonts.primaryLabel)
                        .foregroundStyle(VoCalTheme.Colors.ink)
                    Spacer()
                    Text(value)
                        .font(.system(size: 15, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(VoCalTheme.Colors.ink)
                    if whys[whyKey] != nil {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(VoCalTheme.Colors.muted)
                            .rotationEffect(.degrees(isOpen ? 180 : 0))
                    }
                }
                .padding(.horizontal, VoCalTheme.Spacing.l)
                .padding(.vertical, VoCalTheme.Spacing.m)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen, let why = whys[whyKey] {
                Text(why)
                    .font(VoCalTheme.Fonts.secondaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
                    .padding(.horizontal, VoCalTheme.Spacing.l)
                    .padding(.bottom, VoCalTheme.Spacing.m)
            }
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

    private func load() async {
        if RuntimeMode.usesMockServices {
            state = .loaded(.personaFixture)
            return
        }
        do {
            let response = try await api.activeProtocol()
            let t = response.targets
            state = .loaded(
                ProtocolTargets(
                    protocolId: response.protocolId,
                    version: t.version,
                    kcal: t.kcal,
                    protein: t.protein,
                    proteinMin: t.proteinMin ?? 0,
                    proteinMax: t.proteinMax ?? 0,
                    carbs: t.carbs,
                    fat: t.fat,
                    fiber: t.fiber,
                    produceServings: t.produceServings,
                    waterOz: t.waterOz,
                    mealsPerDay: t.mealsPerDay,
                    whys: t.whys
                )
            )
        } catch let APIError.status(code, _) where code == 404 {
            state = .empty
        } catch {
            state = .failed
        }
    }
}

#Preview {
    NavigationStack {
        ProtocolSettingsView()
    }
}
