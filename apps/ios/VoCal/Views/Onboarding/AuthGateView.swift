import SwiftUI

/// F1 (UI) — the account gate, shown AFTER the protocol value (DESIGN.md §Welcome). Sign in
/// with Apple is the P0 method (decision #26); the real Supabase-backed call is deferred to
/// provisioning, so this drives the `AuthService` mock, which succeeds instantly on the sim.
struct AuthGateView: View {
    var onSignedIn: () -> Void
    var service: any AuthService = AuthServiceFactory.resolved()

    @State private var signingIn = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            VoCalTheme.Colors.background.ignoresSafeArea()
            VStack(spacing: VoCalTheme.Spacing.l) {
                Spacer()
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(VoCalTheme.Colors.gold)
                    .frame(width: 64, height: 64)
                    .background(VoCalTheme.Colors.cta, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                Text("Save your protocol")
                    .font(VoCalTheme.Fonts.screenTitle)
                    .foregroundStyle(VoCalTheme.Colors.ink)
                Text("One tap. We ask for nothing else - no email lists, no password to forget.")
                    .font(VoCalTheme.Fonts.secondaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
                Spacer()
                Button { signIn() } label: {
                    HStack(spacing: VoCalTheme.Spacing.s) {
                        if signingIn {
                            ProgressView().tint(VoCalTheme.Colors.onCta)
                        } else {
                            Image(systemName: "apple.logo")
                                .font(.system(size: 17, weight: .semibold))
                            Text("Sign in with Apple")
                                .font(VoCalTheme.Fonts.primaryLabel)
                        }
                    }
                    .foregroundStyle(VoCalTheme.Colors.onCta)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(VoCalTheme.Colors.cta, in: Capsule())
                }
                .disabled(signingIn)
                .accessibilityIdentifier("onboarding.sign-in")
                // Interim live-testing affordance: a real anonymous session before the Apple
                // provider is provisioned. Only shown when explicitly running live services.
                if RuntimeMode.forcesLiveServices {
                    Button("Use a test account") { signIn(anonymous: true) }
                        .font(VoCalTheme.Fonts.formLabel.weight(.semibold))
                        .foregroundStyle(VoCalTheme.Colors.gold)
                        .disabled(signingIn)
                        .accessibilityIdentifier("onboarding.sign-in-anonymous")
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(VoCalTheme.Fonts.formLabel)
                        .foregroundStyle(VoCalTheme.Colors.protein)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                        .accessibilityIdentifier("onboarding.sign-in-error")
                }
                Text("Your food log and voice stay private to your account.")
                    .font(VoCalTheme.Fonts.formLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
                    .frame(maxWidth: .infinity)
            }
            .padding(VoCalTheme.Spacing.xl)
        }
    }

    private func signIn(anonymous: Bool = false) {
        guard !signingIn else { return }
        signingIn = true
        errorMessage = nil
        Task {
            do {
                if anonymous {
                    try await service.signInAnonymously()
                } else {
                    try await service.signInWithApple()
                }
                signingIn = false
                onSignedIn()
            } catch AppleSignIn.SignInError.cancelled {
                // User backed out of the Apple sheet — not a failure, show nothing.
                signingIn = false
            } catch {
                // A real failure (Apple provider not provisioned, network, Supabase): surface
                // it so a tester isn't stuck on a silent gate (the old behavior hid this).
                signingIn = false
                errorMessage = anonymous
                    ? "Couldn't start a test session. Check your connection and try again."
                    : "Couldn't sign in. Check your connection and try again."
            }
        }
    }
}

#Preview {
    AuthGateView(onSignedIn: {})
}
