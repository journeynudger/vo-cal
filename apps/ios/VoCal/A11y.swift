import Foundation

/// Accessibility identifier namespace (Beacon pattern). UI tests reference these,
/// never display strings.
enum A11y {
    enum Root {
        static let todayTab = "root.tab.today"
        static let settingsTab = "root.tab.settings"
        static let micButton = "root.mic-button"
    }

    enum VoiceLog {
        static let screen = "voicelog.screen"
        static let micButton = "voicelog.mic-button"
        static let stopButton = "voicelog.stop-button"
        static let stateLabel = "voicelog.state-label"
        static let confirmButton = "voicelog.confirm-button"
        static let cancelButton = "voicelog.cancel-button"
        static let caloriesCard = "voicelog.calories-card"
        static let checkCard = "voicelog.check-card"
        static let logAnywayButton = "voicelog.log-anyway-button"
        static let transcriptDrawer = "voicelog.transcript-drawer"
    }

    enum Today {
        static let screen = "today.screen"
        static let caloriesLeft = "today.calories-left"
    }
}
