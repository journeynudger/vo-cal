import OSLog
import SwiftUI

/// F1 (UI) — the account gate, shown AFTER the protocol value (DESIGN.md §Welcome). Sign in
/// with Apple is the P0 method (decision #26); the real Supabase-backed call is deferred to
/// provisioning, so this drives the `AuthService` mock, which succeeds instantly on the sim.
struct AuthGateView: View {
    /// Why the account is asked for (decision 76): after the questions, to keep the protocol
    /// the person just saw built; after the skip, to keep the meals they are about to say. A
    /// title naming a protocol nobody built is a claim above the state.
    enum Purpose {
        case saveProtocol
        case keepLog
    }

    var purpose: Purpose = .saveProtocol
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
                    .accessibilityHidden(true)
                Text(purpose == .keepLog ? "Keep your log" : "Save your protocol")
                    .font(VoCalTheme.Fonts.screenTitle)
                    .foregroundStyle(VoCalTheme.Colors.ink)
                Text(purpose == .keepLog
                     ? "One tap, and every meal you say is yours to keep. No email lists, no password to forget."
                     // Not "nothing else": Apple Health is asked on the next screen (A10).
                     : "One tap. No email list, no password to forget.")
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
                // Anonymous session — a real Supabase JWT without the Apple provider. Shown on
                // ANY live build (Release/TestFlight + -LiveServices), so the concierge beta can
                // onboard with a single Supabase "anonymous sign-ins" toggle instead of the full
                // Apple-provider setup. Hidden on the mock path (DEBUG/UITest). Pre-public, decide
                // whether to keep it for external/App-Review builds.
                if !RuntimeMode.usesMockServices {
                    Button("Continue without an account") { signIn(anonymous: true) }
                        .font(VoCalTheme.Fonts.formLabel.weight(.semibold))
                        .foregroundStyle(VoCalTheme.Colors.gold)
                        .disabled(signingIn)
                        .accessibilityIdentifier("onboarding.sign-in-anonymous")
                }
                if let errorMessage {
                    // The alert red, never the protein red: a macro colour carries no other
                    // meaning (DESIGN.md; the 2026-10-16 audit, A1).
                    Text(errorMessage)
                        .font(VoCalTheme.Fonts.formLabel)
                        .foregroundStyle(VoCalTheme.Colors.alert)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                        .accessibilityIdentifier("onboarding.sign-in-error")
                }
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
                signingIn = false
                errorMessage = Self.message(for: error, anonymous: anonymous)
            }
        }
    }

    private static let log = Logger(subsystem: "com.vo-cal.app", category: "auth")

    /// Map the real failure to an honest message — never the blanket "check your connection"
    /// that masked everything before. The actual error is logged (Console.app, category "auth")
    /// so a failure is diagnosable, and only a genuine transport error blames the network.
    static func message(for error: Error, anonymous: Bool) -> String {
        log.error("sign-in failed (anonymous=\(anonymous, privacy: .public)): \(String(describing: error), privacy: .public)")
        if error is URLError {
            return "Check your connection and try again."
        }
        if case AuthCoordinator.AuthError.notConfigured = error {
            return "Sign-in isn't configured in this build."
        }
        if case AppleSignIn.SignInError.missingIdentityToken = error {
            return "Apple didn't return a sign-in token. Please try again."
        }
        if case AppleSignIn.SignInError.failed(let reason) = error {
            return "Apple sign-in failed: \(reason)"
        }
        // Supabase rejects the token when the Apple provider isn't enabled for the project
        // (the confirmed beta cause). Detect it and route to the path that DOES work today.
        let desc = String(describing: error).lowercased() + " " + error.localizedDescription.lowercased()
        if !anonymous, desc.contains("provider") || desc.contains("not enabled") || desc.contains("disabled") {
            return "Apple sign-in isn't enabled yet. Tap \u{201C}Continue without an account\u{201D} to start."
        }
        return anonymous
            ? "Couldn't start a session: \(error.localizedDescription)"
            : "Couldn't sign in: \(error.localizedDescription)"
    }
}

#Preview {
    AuthGateView(onSignedIn: {})
}
