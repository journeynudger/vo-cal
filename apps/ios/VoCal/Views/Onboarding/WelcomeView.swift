import SwiftUI

/// F0 — first-launch welcome. The headline is the fit, not the method (decision 56): "Follow
/// your nutrition your way." with the gold highlight on the person's part, the one-line of what
/// the choice is, and two doors (decision 76): the black pill into the intake, whose first
/// question is that choice, and a text door past the questions, to the method's six at starter
/// targets. Stated as two doors, neither sold; the time under the pill is the honest cost. No
/// login wall: auth comes after the protocol value is shown (DESIGN.md §Welcome). No
/// superlative: a claim the person cannot check from inside the app stays in the pitch (D9).
struct WelcomeView: View {
    var onStart: () -> Void
    /// Past the questions (decision 76): nothing is written for the person; the record says
    /// never chosen, which is true, and Today's banner is the door to the basics.
    var onSkip: () -> Void

    var body: some View {
        ZStack {
            VoCalTheme.Colors.background.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: VoCalTheme.Spacing.s) {
                    Image("AppLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .accessibilityHidden(true)
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

                Text("Habits, calories, the method, macros, or a meal plan. You choose; the app shows only that. Say what you ate and it logs.")
                    .font(VoCalTheme.Fonts.body)
                    .foregroundStyle(VoCalTheme.Colors.muted)
                    .padding(.top, VoCalTheme.Spacing.l)
                    .frame(maxWidth: 320, alignment: .leading)

                Spacer()
                Spacer()

                PillButton(title: "Make it mine", action: onStart)
                // A duration nobody measured is a claim above proof (A23): the order of time, not a number.
                Text("A few minutes · no account needed yet")
                    .font(VoCalTheme.Fonts.formLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.top, VoCalTheme.Spacing.m)
                // The second door. No line under it: what the skip leads to is taught by Today
                // and said once in the banner there (spec D7); a count of questions is refused.
                Button("Skip the questions", action: onSkip)
                    .font(VoCalTheme.Fonts.primaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.ink)
                    .frame(maxWidth: .infinity)
                    .padding(.top, VoCalTheme.Spacing.l)
                    .accessibilityIdentifier("onboarding.skip-questions")
            }
            .padding(VoCalTheme.Spacing.xl)
        }
    }
}

#Preview {
    WelcomeView(onStart: {}, onSkip: {})
}
