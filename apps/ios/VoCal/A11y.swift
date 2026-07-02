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
        // Water tile is the one interactive micro-tile (tap → add-water sheet); produce/fiber
        // are display-only (derived from logged food), so only water carries an identifier.
        static let waterTile = "today.water-tile"
        static let addWaterField = "today.add-water-field"
        static let addWaterConfirm = "today.add-water-confirm"
    }

    enum Intake {
        // The not-medical-advice disclaimer required on the intake flow (PROTOCOL_LOGIC §9 —
        // its presence is asserted, never the display string).
        static let disclaimer = "intake.disclaimer"
        // Editable basics that feed the engine (sex is a ChoiceList; these three are pickers).
        // Height drives ideal-bodyweight calories; weight drives protein/water/fat (engine.py).
        static let age = "intake.age"
        static let height = "intake.height"
        static let weight = "intake.weight"
    }
}
