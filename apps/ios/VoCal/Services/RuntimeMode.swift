import Foundation

/// One place that decides whether the app runs the sim-verifiable mock path or the
/// live (network + on-device transcription) path. Phase D ships the mock path first so
/// every voice-log UI state is reachable on the simulator with zero network; the live
/// path is wired behind the same protocols and selected only in release builds.
///
/// Selection rule: Mock when `-UITestMode` is passed (UITest scheme) OR in any DEBUG
/// build by default. Live only in non-DEBUG builds without the flag. This keeps
/// `bin/ios-app-build`, the self-test, and a plain DEBUG run all on the canned path that
/// needs no backend or microphone (no mic exists on the sim).
enum RuntimeMode {
    static var isUITestMode: Bool {
        ProcessInfo.processInfo.arguments.contains("-UITestMode")
    }

    /// True when the mock services should back the voice-log loop.
    static var usesMockServices: Bool {
        if isUITestMode {
            return true
        }
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// The fixed test-user UUID sent as `X-Test-User` against the local backend's
    /// test-auth seam (services/api dependencies.py). Matches the API test suite's
    /// TEST_USER_ID so a local `make api-dev` accepts requests without real auth.
    /// Real Sign-in-with-Apple JWTs replace this in Phase F.
    static let testUserID = "11111111-1111-1111-1111-111111111111"
}
