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

    /// Interim sign-in that yields a real (anonymous) session — used for live testing before
    /// the Apple provider is provisioned. The mock no-ops it.
    func signInAnonymously() async throws
}

struct MockAuthService: AuthService {
    var latency: Duration = .milliseconds(500)

    func signInWithApple() async throws {
        try? await Task.sleep(for: latency)
    }

    func signInAnonymously() async throws {
        try? await Task.sleep(for: latency)
    }
}

/// The auth service for the current runtime: Supabase-backed in live builds, mock on the sim
/// path so onboarding stays fully sim-verifiable.
enum AuthServiceFactory {
    static func resolved() -> any AuthService {
        RuntimeMode.usesMockServices ? MockAuthService() : SupabaseAuthService()
    }
}
