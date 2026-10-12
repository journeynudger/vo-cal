import SwiftUI
import VoCalCore

/// Settings → My protocol: the ACTIVE protocol as the engine last computed it, the person's
/// mode first. The rows the mode reveals (server `reveal`, decision 59) lead, with their
/// tap-to-expand "whys"; everything else the engine computed sits under one disclosure, one
/// tap away and labelled as the engine's (spec 6.4, the joint pass). Same visual grammar as
/// the onboarding reveal so the protocol looks like one artifact everywhere; numbers are
/// engine-owned (AGENTS.md #6) and this page only renders them.
struct ProtocolSettingsView: View {
    var api: APIClient = APIClient()

    private enum ViewState {
        case loading
        case loaded(GeneratedProtocol)
        case empty
        case failed
    }

    @State private var state: ViewState = .loading
    @State private var expanded: Set<String> = []
    @State private var showsEverything = false

    var body: some View {
        SettingsPageScaffold(title: "My protocol") {
            switch state {
            case .loading:
                VoCalLoader(size: 40)
                    .frame(maxWidth: .infinity)
                    .padding(.top, VoCalTheme.Spacing.xxl)
            case let .loaded(generated):
                loaded(generated)
            case .empty:
                message(
                    "No protocol yet",
                    "Finish onboarding to build your protocol. It takes about three minutes."
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

    /// The five's keys, for a server that predates `reveal`.
    private static let fiveKeys = ["kcal", "protein", "water", "fiber", "produce"]
    /// Everything the engine computes, in the order the page lists what the mode left out.
    private static let allKeys = ["kcal", "protein", "carbs", "fat", "fiber", "water", "produce", "meals"]

    @ViewBuilder
    private func loaded(_ generated: GeneratedProtocol) -> some View {
        let t = generated.targets
        let reveal = generated.reveal.isEmpty ? Self.fiveKeys : generated.reveal
        let shown = reveal.filter { $0 != "kcal" && Self.allKeys.contains($0) }
        let rest = Self.allKeys.filter { !reveal.contains($0) }

        if reveal.contains("kcal") {
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
        }

        if !shown.isEmpty {
            SettingsSectionLabel(title: reveal.contains("kcal") ? "Daily targets" : "Every day")
            SettingsCard { rows(shown, t) }
        }

        if !rest.isEmpty {
            // The joint pass (spec 6.4): the number the person did not ask for is one tap away
            // and labelled as the engine's, never on the page they asked to keep quiet.
            DisclosureGroup(isExpanded: $showsEverything) {
                SettingsCard { rows(rest, t) }
                    .padding(.top, VoCalTheme.Spacing.s)
            } label: {
                Text("Everything else the engine computed")
                    .font(VoCalTheme.Fonts.secondaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
            }
            .tint(VoCalTheme.Colors.muted)
            .padding(.horizontal, VoCalTheme.Spacing.s)
            .accessibilityIdentifier(A11y.Settings.protocolEverythingElse)
        }

        // When D1 names the method, its name goes in this line and nowhere else (spec R5).
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

    @ViewBuilder
    private func rows(_ keys: [String], _ t: ProtocolTargets) -> some View {
        ForEach(Array(keys.enumerated()), id: \.element) { index, key in
            if index > 0 { SettingsDetailDivider() }
            row(key, t)
        }
    }

    @ViewBuilder
    private func row(_ key: String, _ t: ProtocolTargets) -> some View {
        switch key {
        case "kcal":
            targetRow("Calories", value: "\(t.kcal.formatted(.number.grouping(.automatic))) a day", color: VoCalTheme.Colors.gold, whyKey: key, whys: t.whys)
        case "protein":
            targetRow("Protein", value: proteinValue(t), color: VoCalTheme.Colors.protein, whyKey: key, whys: t.whys)
        case "carbs":
            targetRow("Carbs", value: "\(t.carbs) g", color: VoCalTheme.Colors.carbs, whyKey: key, whys: t.whys)
        case "fat":
            targetRow("Fat", value: "\(t.fat) g", color: VoCalTheme.Colors.fats, whyKey: key, whys: t.whys)
        case "water":
            targetRow("Water", value: "\(t.waterOz) oz", color: VoCalTheme.Colors.water, whyKey: key, whys: t.whys)
        case "fiber":
            targetRow("Fiber", value: "\(t.fiber) g", color: VoCalTheme.Colors.optimal, whyKey: key, whys: t.whys)
        case "produce":
            targetRow("Produce", value: "\(t.produceServings) a day", color: VoCalTheme.Colors.muted, whyKey: key, whys: t.whys)
        case "meals":
            targetRow("Meals", value: "\(t.mealsPerDay) a day", color: VoCalTheme.Colors.muted, whyKey: key, whys: t.whys)
        default:
            EmptyView()
        }
    }

    /// Protein renders its optimal band when the protocol carries one; the bare
    /// target otherwise (older protocols), never a fabricated 0 to 0 range.
    private func proteinValue(_ t: ProtocolTargets) -> String {
        if t.proteinMax > t.proteinMin, t.proteinMin > 0 {
            return "\(t.proteinMin) to \(t.proteinMax) g"
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
            .disabled(whys[whyKey] == nil)
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
            state = .loaded(GeneratedProtocol(
                targets: .personaFixture,
                reveal: MockProtocolService.reveal(for: MockTrackingService.current.mode)
            ))
            return
        }
        do {
            let response = try await api.activeProtocol()
            state = .loaded(GeneratedProtocol(targets: ProtocolTargets(response), reveal: response.reveal ?? []))
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
