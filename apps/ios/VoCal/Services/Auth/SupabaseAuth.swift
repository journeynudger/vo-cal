import Foundation
import Supabase

/// Supabase project config for the iOS auth client. URL + the *publishable* (anon) key — both
/// safe to ship in the app — come from Info.plist keys set in project.yml. The secret key
/// never leaves the server (FastAPI). Empty config ⇒ no client ⇒ the mock path only.
enum SupabaseConfig {
    static var url: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "VOCAL_SUPABASE_URL") as? String)
            .flatMap { $0.isEmpty ? nil : URL(string: $0) }
    }

    static var publishableKey: String? {
        (Bundle.main.object(forInfoDictionaryKey: "VOCAL_SUPABASE_ANON_KEY") as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// Owns the Supabase auth client and keeps `AuthTokenStore` current so every API request
/// carries a fresh bearer. Sign in with Apple is the production method (decision #26);
/// anonymous sign-in is the interim path that yields a real JWT before the Apple provider is
/// provisioned. The SDK owns token refresh; we mirror the access token into the shared store
/// on every auth-state change.
@MainActor
final class AuthCoordinator {
    static let shared = AuthCoordinator()

    enum AuthError: LocalizedError {
        case notConfigured
        var errorDescription: String? { "auth_not_configured" }
    }

    private let client: SupabaseClient?
    private var observer: Task<Void, Never>?

    init(client: SupabaseClient? = AuthCoordinator.makeDefaultClient()) {
        self.client = client
        startObservingAuthState()
    }

    var isConfigured: Bool { client != nil }

    private static func makeDefaultClient() -> SupabaseClient? {
        guard let url = SupabaseConfig.url, let key = SupabaseConfig.publishableKey else {
            return nil
        }
        return SupabaseClient(supabaseURL: url, supabaseKey: key)
    }

    /// Production sign-in: native Apple sheet → Supabase `signInWithIdToken` (provider .apple).
    func signInWithApple() async throws {
        guard let client else { throw AuthError.notConfigured }
        let credential = try await AppleSignIn().signIn()
        let session = try await client.auth.signInWithIdToken(
            credentials: .init(
                provider: .apple,
                idToken: credential.idToken,
                nonce: credential.rawNonce
            )
        )
        AuthTokenStore.shared.accessToken = session.accessToken
    }

    /// Interim sign-in (before the Apple provider is configured): a real, anonymous JWT.
    func signInAnonymously() async throws {
        guard let client else { throw AuthError.notConfigured }
        let session = try await client.auth.signInAnonymously()
        AuthTokenStore.shared.accessToken = session.accessToken
    }

    func signOut() async {
        AuthTokenStore.shared.accessToken = nil
        try? await client?.auth.signOut()
    }

    private func startObservingAuthState() {
        guard let client else { return }
        // Mirror the access token on sign-in/refresh/sign-out so requests stay authenticated
        // across SDK-driven token refreshes without rebuilding the API client.
        observer = Task {
            for await change in client.auth.authStateChanges {
                AuthTokenStore.shared.accessToken = change.session?.accessToken
            }
        }
    }
}

/// `AuthService` backed by Supabase, used by the onboarding gate in live builds. The mock
/// (MockAuthService) still drives the sim path so onboarding stays fully sim-verifiable.
struct SupabaseAuthService: AuthService {
    @MainActor func signInWithApple() async throws {
        try await AuthCoordinator.shared.signInWithApple()
    }

    @MainActor func signInAnonymously() async throws {
        try await AuthCoordinator.shared.signInAnonymously()
    }
}
