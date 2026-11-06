import SwiftUI

/// F0 — first-launch welcome, on the wash (2026-11-06). The headline is the fit, not the
/// method (decision 56): "Follow your nutrition your way." with the gold highlight on the
/// person's part, one line of what the choice is, and a single black pill into the intake,
/// whose first screen is the bubbles. No login wall: auth comes after the protocol value is
/// shown (DESIGN.md §Welcome). No superlative: a claim the person cannot check from inside
/// the app stays in the pitch (D9).
struct WelcomeView: View {
    var onStart: () -> Void

    var body: some View {
        ZStack {
            VoCalTheme.Colors.background.ignoresSafeArea()
            WashBackground()
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: VoCalTheme.Spacing.s) {
                    Image("AppLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Text("Vo-Cal")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(VoCalTheme.Colors.ink)
                }
                .padding(.top, VoCalTheme.Spacing.xxl)

                Spacer()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Follow your nutrition")
                        .foregroundStyle(VoCalTheme.Colors.ink)
                    Text("your way.")
                        .foregroundStyle(VoCalTheme.Colors.gold)
                }
                .font(.system(size: 44, weight: .semibold))
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)

                Text("Tell it what matters to you. It shows only that. Say what you ate, snap it, scan it or type it, and it logs.")
                    .font(VoCalTheme.Fonts.body)
                    .foregroundStyle(VoCalTheme.Colors.muted)
                    .padding(.top, VoCalTheme.Spacing.l)
                    .frame(maxWidth: 320, alignment: .leading)

                Spacer()
                Spacer()

                PillButton(title: "Let's begin", action: onStart)
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

/// The wash: two soft discs of the brand's own colours at low opacity, blurred into the cream,
/// fading out down the page. Decorative, never hit-testable, never over content that must be
/// read against it (the text sits on the cream below the fade). The one background every
/// first screen shares: the welcome, the home's greeting, the chat's empty state.
struct WashBackground: View {
    var height: CGFloat = VoCalTheme.Wash.height

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Circle()
                    .fill(VoCalTheme.Wash.gold)
                    .frame(width: geo.size.width * 0.9, height: geo.size.width * 0.9)
                    .blur(radius: 60)
                    .offset(x: -geo.size.width * 0.25, y: -geo.size.width * 0.35)
                Circle()
                    .fill(VoCalTheme.Wash.amber)
                    .frame(width: geo.size.width * 0.8, height: geo.size.width * 0.8)
                    .blur(radius: 70)
                    .offset(x: geo.size.width * 0.35, y: -geo.size.width * 0.15)
            }
            .frame(width: geo.size.width, height: height, alignment: .top)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: VoCalTheme.Colors.ink, location: 0),
                        .init(color: VoCalTheme.Colors.ink, location: 0.55),
                        .init(color: VoCalTheme.Colors.ink.opacity(0), location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

#Preview {
    WelcomeView(onStart: {})
}
