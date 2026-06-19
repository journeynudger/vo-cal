import Foundation

/// Account creation/sign-in. P0 auth is Sign in with Apple via Supabase (decision #26), but
/// that needs a provisioned Apple account + Supabase keys — deferred. Until then the mock
/// path succeeds instantly so the onboarding flow is complete and sim-verifiable end to end;
/// the real Supabase-backed implementation slots in behind this protocol at provisioning time
/// without touching any caller. (Auth comes AFTER the protocol value is shown — DESIGN.md
/// §Welcome: no login wall.)
protocol AuthService: Sendable {
    /// Completes a Sign-in-with-Apple session, returning when the account is ready.
    func signInWithApple() async throws
}

struct MockAuthService: AuthService {
    var latency: Duration = .milliseconds(500)

    func signInWithApple() async throws {
        try? await Task.sleep(for: latency)
    }
}
