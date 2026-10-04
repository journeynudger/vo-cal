import SwiftUI

/// Settings → How I track (spec 6.8): the mode, as the intake's own chooser; "Also show", the
/// metrics the mode does not already print; one line that says what changes. A change appends
/// a preference version server-side (`PUT /tracking`, source chosen) and Today reloads when
/// Settings closes. The page shows the server's echo, never the tap: a change that did not land
/// says so and leaves the old choice ticked (a false "changed" is a claim above proof).
struct HowITrackView: View {
    var service: any TrackingService = RuntimeMode.usesMockServices
        ? MockTrackingService() : LiveTrackingService()
    /// Renders and previews: start from this preference instead of loading one.
    var preloaded: TrackingPreference? = nil

    private enum Phase: Equatable {
        case loading
        case ready
        case failed
    }

    @State private var phase: Phase = .loading
    @State private var preference = TrackingPreference.unchosen
    @State private var saving = false
    /// Why the last change did not save; nil when it did.
    @State private var saveError: String?

    var body: some View {
        SettingsPageScaffold(title: "How I track") {
            switch phase {
            case .loading:
                VoCalLoader(size: 40)
                    .frame(maxWidth: .infinity)
                    .padding(.top, VoCalTheme.Spacing.xxl)
            case .failed:
                VStack(spacing: VoCalTheme.Spacing.l) {
                    VStack(spacing: VoCalTheme.Spacing.s) {
                        Text("Couldn't load how you track")
                            .font(VoCalTheme.Fonts.primaryLabel)
                            .foregroundStyle(VoCalTheme.Colors.ink)
                        Text("Check your connection and try again.")
                            .font(VoCalTheme.Fonts.secondaryLabel)
                            .foregroundStyle(VoCalTheme.Colors.muted)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, VoCalTheme.Spacing.xxl)
                    PillButton(title: "Try again") {
                        phase = .loading
                        Task { await load() }
                    }
                    .padding(.horizontal, VoCalTheme.Spacing.xxl)
                }
            case .ready:
                editor
            }
        }
        .task {
            if let preloaded {
                preference = preloaded
                phase = .ready
                return
            }
            await load()
        }
    }

    @ViewBuilder
    private var editor: some View {
        TrackingModeChooser(selection: modeBinding)
            .disabled(saving)
            .padding(.top, VoCalTheme.Spacing.s)
            .accessibilityIdentifier(A11y.Settings.howITrackMode)

        if !preference.offerableFocus.isEmpty {
            SettingsSectionLabel(title: "Also show")
                .padding(.top, VoCalTheme.Spacing.s)
            SettingsCard {
                ForEach(Array(preference.offerableFocus.enumerated()), id: \.element) { index, metric in
                    if index > 0 { SettingsDetailDivider() }
                    focusRow(metric)
                }
            }
            .disabled(saving)
        }

        // What gets in the way (decision 66): the intake's four answers, changeable here; each
        // appends a version and the one thing it names changes from the next parse, evening
        // or result.
        SettingsSectionLabel(title: "What gets in the way")
            .padding(.top, VoCalTheme.Spacing.s)
        SettingsCard {
            ForEach(Array(Friction.allCases.enumerated()), id: \.element) { index, friction in
                if index > 0 { SettingsDetailDivider() }
                frictionRow(friction)
            }
        }
        .disabled(saving)

        Text("Changing this changes what Today shows. Your record is unchanged.")
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
    }

    private func focusRow(_ metric: FocusMetric) -> some View {
        let isOn = preference.focusMetrics.contains(metric)
        return Button {
            var focus = preference.focusMetrics
            if isOn {
                focus.removeAll { $0 == metric }
            } else {
                focus.append(metric)
            }
            change(TrackingUpdate(focusMetrics: focus))
        } label: {
            HStack {
                Text(metric.label)
                    .font(VoCalTheme.Fonts.primaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.ink)
                Spacer()
                if isOn {
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
        .accessibilityIdentifier(A11y.Settings.focusRow(metric.rawValue))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func frictionRow(_ friction: Friction) -> some View {
        let isOn = preference.frictions.contains(friction)
        return Button {
            let frictions = Friction.allCases.filter { $0 == friction ? !isOn : preference.frictions.contains($0) }
            change(TrackingUpdate(frictions: frictions))
        } label: {
            HStack(spacing: VoCalTheme.Spacing.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(friction.title)
                        .font(VoCalTheme.Fonts.primaryLabel)
                        .foregroundStyle(VoCalTheme.Colors.ink)
                    Text(friction.support)
                        .font(VoCalTheme.Fonts.formLabel)
                        .foregroundStyle(VoCalTheme.Colors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if isOn {
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
        .accessibilityIdentifier(A11y.Settings.frictionRow(friction.rawValue))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var modeBinding: Binding<TrackingMode?> {
        Binding(
            get: { preference.mode },
            set: { newValue in
                guard let newValue, newValue != preference.mode else { return }
                change(TrackingUpdate(mode: newValue))
            }
        )
    }

    private func change(_ update: TrackingUpdate) {
        saving = true
        saveError = nil
        Task {
            do {
                preference = try await service.update(update)
                VoCalHaptics.select()
            } catch {
                saveError = "That didn't reach the server. Check your connection and try again."
            }
            saving = false
        }
    }

    private func load() async {
        do {
            preference = try await service.preference()
            phase = .ready
        } catch {
            phase = .failed
        }
    }
}

#Preview {
    NavigationStack {
        HowITrackView(preloaded: TrackingPreference(
            mode: .calories, focusMetrics: [.protein], declinedOffers: [],
            offerableFocus: PanelComposer.offerableFocus(for: .calories), source: "chosen", version: 2
        ))
    }
}
