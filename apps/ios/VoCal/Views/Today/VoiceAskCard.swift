import SwiftUI

/// "How much should Vo-Cal say?", asked where it first acts (decision 77, spec D3): on Today,
/// once the person has logged, for a person never asked. The three sentences with the engine's
/// promise under each (`NudgeLevel.label`, `.detail`), nothing preselected, no close and no
/// "Not now": every answer is a setting and one of them is "Nothing", so the card waits until it
/// is answered. A tap writes the preference and the card leaves on the echo, never the tap; the
/// system permission sheet follows the echo for any answer but "Nothing" (decision 67: the
/// sentence is the ask). The one surface that speaks first about the person's setup, once.
struct VoiceAskCard: View {
    /// The tap, carried to the preference (`NudgeCenter.chooseLevel`); throws what the write
    /// threw, so the line under the rows can say the honest reason.
    var onChoose: (NudgeLevel) async throws -> Void

    /// The row tapped, ticked while the write is in flight; back to nothing if it did not land.
    @State private var tapped: NudgeLevel?
    @State private var saving = false
    /// Why the last tap did not land; nil when it did.
    @State private var saveError: String?

    var body: some View {
        GlassCard(accent: VoCalTheme.Colors.gold) {
            VStack(alignment: .leading, spacing: VoCalTheme.Spacing.m) {
                Text("How much should Vo-Cal say?")
                    .font(VoCalTheme.Fonts.primaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.ink)
                    .accessibilityAddTraits(.isHeader)
                VStack(spacing: 0) {
                    ForEach(Array(NudgeLevel.allCases.enumerated()), id: \.element) { index, level in
                        if index > 0 { SettingsDetailDivider() }
                        row(level)
                    }
                }
                .disabled(saving)
                if let saveError {
                    Text(saveError)
                        .font(VoCalTheme.Fonts.formLabel)
                        .foregroundStyle(VoCalTheme.Colors.alert)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityIdentifier(A11y.Today.voiceCard)
    }

    private func row(_ level: NudgeLevel) -> some View {
        let isOn = tapped == level
        return Button {
            choose(level)
        } label: {
            HStack(spacing: VoCalTheme.Spacing.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(level.label)
                        .font(VoCalTheme.Fonts.primaryLabel)
                        .foregroundStyle(VoCalTheme.Colors.ink)
                    Text(level.detail)
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
            .padding(.vertical, VoCalTheme.Spacing.m)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(A11y.Today.voiceRow(level.rawValue))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    /// The tick shows the tap while the write is in flight and goes back if it did not land:
    /// the card leaves on the echo (its owner removes it), so a false "chosen" never stands.
    private func choose(_ level: NudgeLevel) {
        guard !saving else { return }
        saving = true
        saveError = nil
        tapped = level
        Task {
            do {
                try await onChoose(level)
                VoCalHaptics.select()
            } catch {
                tapped = nil
                saveError = TodayViewModel.settingFailureMessage(for: error)
            }
            saving = false
        }
    }
}

#Preview {
    VoiceAskCard(onChoose: { _ in })
        .padding()
        .background(VoCalTheme.Colors.background)
}
