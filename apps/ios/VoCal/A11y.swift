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
        // The same hero numeral when the server frames it to-date (decision 70): the figure is
        // what was eaten so far, so the id says so. The UI tests find Today by the to-go id on
        // the populated mock day, which sits past the midpoint.
        static let caloriesSoFar = "today.calories-so-far"
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
        // An invitation's three answers (decision 62), on the nudge card.
        static let inviteYes = "today.invite-yes"
        static let inviteNotNow = "today.invite-not-now"
        static let inviteNever = "today.invite-never"
        // The plan card (meal-plan mode, decision 65): the one card with a tap, to the builder.
        static let planCard = "today.plan-card"
        // Nudges that reach the person (decision 67): the permission card and the reasons sheet.
        static let permissionCard = "today.permission-card"
        static let permissionAllow = "today.permission-allow"
        static let permissionNotNow = "today.permission-not-now"
        static let nudgeReasons = "today.nudge-reasons"
        static func reasonRow(_ kind: String) -> String { "today.nudge-reasons.\(kind)" }
        static let reasonsCancel = "today.nudge-reasons.cancel"
    }

    /// The plan builder (decision 65): one row per slot, the picker's parts, the save.
    enum Plan {
        static let screen = "plan.screen"
        static func slotRow(_ index: Int) -> String { "plan.slot.\(index)" }
        static let addSlot = "plan.add-slot"
        static let save = "plan.save"
        static let skip = "plan.skip"
        static let checkLine = "plan.check-line"
        static let usualOption = "plan.usual-option"
        static let typedField = "plan.typed-field"
        static let typedAdd = "plan.typed-add"
        static let removeMeal = "plan.remove-meal"
    }

    enum Settings {
        // How I track (spec 6.8): the row, the chooser on its page, and one row per focus metric.
        static let howITrack = "settings.how-i-track"
        static let howITrackMode = "settings.how-i-track.mode"
        static func focusRow(_ metric: String) -> String { "settings.how-i-track.focus.\(metric)" }
        static func frictionRow(_ friction: String) -> String { "settings.how-i-track.friction.\(friction)" }
        static func anchorRow(_ anchor: String) -> String { "settings.how-i-track.anchor.\(anchor)" }
        // My protocol: the disclosure over what the mode did not ask for.
        static let protocolEverythingElse = "settings.protocol.everything-else"
        static let exportRecord = "settings.export-record"
        // My meal plan: shown only in meal-plan mode (an option that does nothing is clutter).
        static let mealPlan = "settings.meal-plan"
        // Notifications → Muted: one row per nudge the person said was not for them.
        static func mutedRow(_ id: String) -> String { "settings.notifications.muted.\(id)" }
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
        // The one benefit screen (BenefitInterstitials.swift; decision 68 cut the other two), a
        // full step in the flow, so UI tests can assert the sequence and back navigation.
        static let benefitRealisticPace = "intake.benefit.realistic-pace"
        // The first question: how the person wants to follow their nutrition (decision 57).
        static let modeChooser = "intake.mode"
        // Decision 66: how much the app says, what gets in the way. Decision 69: when they log.
        static let voiceChooser = "intake.voice"
        static let frictionChooser = "intake.friction"
        static let anchorChooser = "intake.anchor"
        // The reveal's one line (decision 69, spec 6.7): the habit the plan rests on.
        static let revealHabitLine = "intake.reveal.habit-line"
    }

    /// The weekly check-in (decision 69): the mirror, the lapse question, the week's steps.
    enum CheckIn {
        static let previousNote = "checkin.previous-note"
        static let lapseChooser = "checkin.lapse"
        static let stepsLine = "checkin.steps"
    }
}
