import SwiftUI

/// F0 — first-launch welcome. Locked positioning copy "Photos guess. Voice knows." with the
/// gold highlight word, the effort-thesis subline, and a single black pill into the intake.
/// No login wall: auth comes after the protocol value is shown (DESIGN.md §Welcome).
struct WelcomeView: View {
    var onStart: () -> Void

    var body: some View {
        ZStack {
            VoCalTheme.Colors.background.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: VoCalTheme.Spacing.s) {
                    Image(systemName: "waveform")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(VoCalTheme.Colors.onCta)
                        .frame(width: 34, height: 34)
                        .background(VoCalTheme.Colors.cta, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Text("Vo-Cal")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(VoCalTheme.Colors.ink)
                }
                .padding(.top, VoCalTheme.Spacing.xxl)

                Spacer()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Photos guess.")
                        .foregroundStyle(VoCalTheme.Colors.ink)
                    Text("Voice knows.")
                        .foregroundStyle(VoCalTheme.Colors.gold)
                }
                .font(.system(size: 44, weight: .semibold))

                Text("The voice-first nutrition tracker. For people willing to do the work - and nothing they don't need.")
                    .font(VoCalTheme.Fonts.body)
                    .foregroundStyle(VoCalTheme.Colors.muted)
                    .padding(.top, VoCalTheme.Spacing.l)
                    .frame(maxWidth: 320, alignment: .leading)

                Spacer()
                Spacer()

                PillButton(title: "Build my protocol", action: onStart)
                Text("About 3 minutes · no account needed yet")
                    .font(VoCalTheme.Fonts.formLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.top, VoCalTheme.Spacing.m)
            }
            .padding(VoCalTheme.Spacing.xl)
        }
    }
}

#Preview {
    WelcomeView(onStart: {})
}
