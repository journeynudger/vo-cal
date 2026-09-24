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
        // The recognized usual ("Is this your metal detox smoothie?") and its two answers.
        static let recognizedCard = "voicelog.recognized-card"
        static let recognizedYes = "voicelog.recognized-yes"
        static let recognizedNo = "voicelog.recognized-no"
        static let transcriptDrawer = "voicelog.transcript-drawer"
        static let certaintyBanner = "voicelog.certainty-banner"
        static let addDetailButton = "voicelog.add-detail-button"
        static let targetDayChip = "voicelog.target-day-chip"
        static let addToMealButton = "voicelog.add-to-meal-button"
        // Personal foods: the label sheet from an item's edit sheet, the recipe sheet from the result.
        static let labelFoodButton = "voicelog.label-food-button"
        static let labelFoodSaveButton = "voicelog.label-food-save-button"
        static let saveRecipeButton = "voicelog.save-recipe-button"
        static let saveRecipeConfirmButton = "voicelog.save-recipe-confirm-button"
        static let logServingButton = "voicelog.log-serving-button"
    }

    enum Today {
        static let screen = "today.screen"
        // The profile circle (top trailing) is the way to Settings since the tab bar went.
        static let profileButton = "today.profile"
        static let mealRow = "today.meal-row"
        static let renameField = "today.rename-field"
        static let caloriesLeft = "today.calories-left"
        // Water tile is the one interactive micro-tile (tap → add-water sheet); produce/fiber
        // are display-only (derived from logged food), so only water carries an identifier.
        static let waterTile = "today.water-tile"
        static let addWaterField = "today.add-water-field"
        static let addWaterConfirm = "today.add-water-confirm"
        static let weekCard = "today.week-card"
        static let starterTargetsBanner = "today.starter-targets-banner"
        // Usuals chips (R5: one-tap re-log of a saved meal). The row renders only when the
        // user HAS usuals, so its absence is a state, not a failure.
        static let usualsRow = "today.usuals-row"
        static let usualChip = "today.usual-chip"
        // Week-paging controls (R6 beta feedback: browse history further back than 7 days).
        static let weekBack = "today.week-back"
        static let weekForward = "today.week-forward"
        static let jumpToday = "today.jump-today"
        // An unfinished recording (R8): saved audio that never reached "Logged".
        static let unfinishedRow = "today.unfinished-row"
    }

    enum Week {
        static let screen = "week.screen"
        static let editButton = "week.edit-button"
        static let saveButton = "week.save-button"
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
        static let desiredWeight = "intake.desired-weight"
        // Benefit interstitials woven between the questions (BenefitInterstitials.swift) —
        // full steps in the flow, so UI tests can assert the sequence and back navigation.
        static let benefitRealisticPace = "intake.benefit.realistic-pace"
        static let benefitMomentum = "intake.benefit.momentum"
        static let benefitLongTermResults = "intake.benefit.long-term-results"
    }
}
