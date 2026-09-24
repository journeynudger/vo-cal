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

    /// Launch arg to force the LIVE path (real backend + Supabase auth + server transcription)
    /// in a DEBUG/sim run, so the live loop is testable without an archive build. Pass
    /// `-LiveServices` in the scheme's arguments (or `xcrun simctl launch … -LiveServices`).
    static var forcesLiveServices: Bool {
        ProcessInfo.processInfo.arguments.contains("-LiveServices")
    }

    /// True when the mock services should back the voice-log loop.
    static var usesMockServices: Bool {
        if isUITestMode {
            return true
        }
        if forcesLiveServices {
            return false
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

    /// DEBUG-only navigation hooks so headless verification (simctl launch + screenshot)
    /// can reach non-default screens without touch injection — same self-gating posture
    /// as the voice self-test runtime: a no-op on every normal launch, never in Release,
    /// and never on the capture path.
    #if DEBUG
    /// `-StartOnSettingsTab` — open on the Settings tab instead of Today.
    static var startsOnSettingsTab: Bool {
        ProcessInfo.processInfo.arguments.contains("-StartOnSettingsTab")
    }

    /// `-SettingsDestination <profile|protocol|notifications>` — push a Settings
    /// subpage on appear. Nil (no push) when absent or unrecognized.
    static var debugSettingsDestination: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let flag = args.firstIndex(of: "-SettingsDestination"),
              args.indices.contains(flag + 1) else { return nil }
        return args[flag + 1]
    }

    /// `-ShowWeekBudget` — open the weekly-budget sheet on launch.
    static var showsWeekBudgetOnLaunch: Bool {
        ProcessInfo.processInfo.arguments.contains("-ShowWeekBudget")
    }

    /// `-SlowMockCapture` — the mock capture's rungs at a pace a UI test can sample (six
    /// seconds arming, a word every two) instead of the demo pace (450 ms, 150 ms). XCUI's
    /// first queries of a new screen cost seconds each, so the window has to be wide. The
    /// flow test that watches the mic through "Starting" and "Listening" needs the window;
    /// at the demo pace the capture was on its result before the test's first query.
    static var slowsMockCapture: Bool {
        ProcessInfo.processInfo.arguments.contains("-SlowMockCapture")
    }
    #else
    static var startsOnSettingsTab: Bool { false }
    static var debugSettingsDestination: String? { nil }
    static var showsWeekBudgetOnLaunch: Bool { false }
    static var slowsMockCapture: Bool { false }
    #endif

    /// The mock capture's beat: arming, sealing and the saved pause each take one tick, a
    /// streamed word a third of one.
    static var mockCaptureTick: Duration {
        slowsMockCapture ? .seconds(6) : .milliseconds(450)
    }
}
