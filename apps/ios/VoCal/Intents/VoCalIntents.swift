import AppIntents

// Port provenance: Serein apps/ios/SereinApp/Sources/SiriCaptureIntents.swift (StartCaptureIntent)
// and CaptureIntents.swift (SereinCaptureShortcuts). Adapted, not copied: Serein's intents are
// AudioRecordingIntents that record with the app closed; Vo-Cal's opens the app and leaves a
// request for the shell. Serein's finish, bookmark, store-capture and self-test intents are not
// ported: there is no background take to finish or mark, and the self-test has its launch flag.

/// "Log in Vo-Cal": opens Vo-Cal into the voice log.
///
/// Why the app opens instead of recording in the background as Serein's intent does.
/// Requirement: capture is foreground-only (decision 2, .claude/memory/decisions.md), and the
/// capture path must not be reachable from a subsystem serving another concern (AGENTS.md
/// capture-path isolation). Failure mode avoided: an AudioRecordingIntent must keep a Live
/// Activity running while it records, and on a cold background start ActivityKit rejects that
/// request with target_is_not_foreground; Serein also lost its microphone authorization window
/// to eager intent-time startup (Serein AGENTS.md, April 2026). Evidence:
/// https://developer.apple.com/forums/thread/815725, and the seam-cut notes in
/// AppRuntimeCoordinator.swift and VoiceCaptureCoordinator.swift. So `perform` only records a
/// request; the system brings the app forward (`supportedModes = .foreground`, iOS 26's
/// replacement for `openAppWhenRun = true`, which the SDK deprecates), and the shell opens the
/// voice log, whose mic door runs exactly as if the person had tapped it.
///
/// No dialog: Serein found a reply dialog shows as a system alert on every Action Button press
/// (CaptureIntents.swift), and a spoken reply talked over, and paused, the take it announced
/// (SiriCaptureIntents.swift, 2026-09-21).
struct LogMealIntent: AppIntent {
    static let title: LocalizedStringResource = "Log a meal"
    static let description: IntentDescription? = IntentDescription("Opens Vo-Cal ready to log a meal by voice.")
    static let supportedModes: IntentModes = .foreground

    @MainActor
    func perform() async throws -> some IntentResult {
        PendingLaunchAction.shared.request(.startVoiceLog)
        return .result()
    }
}

/// What Siri knows to say, and what Settings > Action Button > Shortcut lists (by its short
/// title, "Log a meal"). Every phrase carries the app's name; Siri requires it.
struct VoCalShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LogMealIntent(),
            phrases: [
                "Log in \(.applicationName)",
                "Log a meal in \(.applicationName)",
                "Log food in \(.applicationName)",
                "Log what I ate in \(.applicationName)",
            ],
            shortTitle: "Log a meal",
            systemImageName: "mic.fill"
        )
    }
}
