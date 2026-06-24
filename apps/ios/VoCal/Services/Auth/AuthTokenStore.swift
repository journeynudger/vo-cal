import Foundation

/// The one place the current Supabase access token lives, shared between the auth layer
/// (writer) and `APIClient` (reader). A lock-boxed value rather than threading the token
/// through every call site: requests run off the main actor, the `AuthCoordinator` updates
/// the token on the main actor when the session changes, and both need a safe hand-off.
///
/// Holding only the access token (never the refresh token) keeps the blast radius small —
/// the SDK owns refresh; this is just the bearer the next request should send.
final class AuthTokenStore: @unchecked Sendable {
    static let shared = AuthTokenStore()

    private let lock = NSLock()
    private var _accessToken: String?

    var accessToken: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _accessToken
        }
        set {
            lock.lock()
            _accessToken = newValue
            lock.unlock()
        }
    }
}
