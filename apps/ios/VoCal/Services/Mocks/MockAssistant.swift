import Foundation

/// The sim's reader and answerer (decision 71): the keyword rules of `assist/llm.py` and the
/// lines of `assist/lines.py`, applied to `MockTrackingService` so Settings and Today follow on
/// the sim as they do live. Where the mock speaks, its words are the catalog's, line for line
/// (`testTheBarAnswers` pins the ones the renders show). The sim has no reactions store, so a
/// mute answers without Undo.
enum MockAssistant {
    static let meal = "I couldn't make out any food in that. Try describing the meal again."
    static let other = "That's not something Vo-Cal does. Say what you ate, or ask about your day and how you track."
    static let noNumbers = "Your way shows no numbers. Say 'watch my calories' and it will."

    private static let levelLines: [NudgeLevel: String] = [
        .essential: "Vo-Cal will say something only when you're slipping.",
        .standard: "Vo-Cal will coach you along the way. Never more than two a day.",
        .off: "Vo-Cal will say nothing. Your weekly check-in still shows when it's due.",
    ]
    private static let anchorPhrases: [LogAnchor: String] = [
        .afterEating: "right after you eat", .whenSeated: "when you sit back down",
        .beforeBed: "before bed", .own: "your own moment",
    ]
    private static let anchorShort: [LogAnchor: String] = [
        .afterEating: "Right after I eat", .whenSeated: "When I sit back down",
        .beforeBed: "Before bed", .own: "My own moment",
    ]
    private static let subjectWords: [String: String] = [
        "consistency": "daily", "calories": "calorie", "protein": "protein", "water": "water",
        "produce": "produce", "fiber": "fiber", "plan": "meal plan",
    ]
    private static let subjectTitles: [String: String] = [
        "consistency": "Your day", "calories": "Calories", "protein": "Protein", "water": "Water",
        "produce": "Produce", "fiber": "Fiber", "plan": "Your plan",
    ]
    private static let pointerLines: [AssistPointer.Surface: String] = [
        .today: "It's on Today.",
        .week: "Your week is on Today, under your meals.",
        .protocolPage: "Your targets and their whys are in My protocol.",
        .plan: "Your plan is in Settings, under Meal plan.",
        .settings: "How you track lives in Settings.",
        .notifications: "Reminders live in Settings, under Notifications.",
        .profile: "Your details and your goal are in Settings, under My details.",
    ]
    private static let pointerTitles: [AssistPointer.Surface: String] = [
        .today: "Today", .week: "Today", .protocolPage: "My protocol", .plan: "Meal plan",
        .settings: "Settings", .notifications: "Notifications", .profile: "My details",
    ]
    /// What the person asks for, by the word they use, to the panel's metric and its label.
    private static let metrics: [(pattern: String, key: String, metric: String, label: String)] = [
        ("\\bprotein\\b", "protein", "protein", "Protein"),
        ("\\b(calorie\\w*|kcal)\\b", "calories", "kcal", "Calories"),
        ("\\bcarb\\w*\\b", "carbs", "carbs", "Carbs"),
        ("\\bfats?\\b", "fat", "fat", "Fat"),
        ("\\b(fiber|fibre)\\b", "fiber", "fiber", "Fiber"),
        ("\\b(water|hydrat\\w*)\\b", "water", "water", "Water"),
        ("\\b(produce|vegetable\\w*|veg|veggies|fruit\\w*)\\b", "produce", "produce", "Produce"),
        ("\\bsugar\\w*\\b", "sugar", "sugar", "Sugar"),
        ("\\b(sodium|salt)\\b", "sodium", "sodium", "Sodium"),
    ]
    private static let surfaces: [(pattern: String, surface: AssistPointer.Surface)] = [
        ("\\bweek\\b", .week), ("\\b(protocol|targets?|why)\\b", .protocolPage), ("\\b(meal plan|plan)\\b", .plan),
        ("\\b(notification\\w*|reminder\\w*)\\b", .notifications), ("\\b(weight|goal|details?|height|age)\\b", .profile),
        ("\\bsettings?\\b", .settings), ("\\btoday\\b", .today),
    ]
    private static let modes: [(pattern: String, mode: TrackingMode)] = [
        ("\\bhabits?\\b", .habits), ("\\bmacros?\\b", .macros), ("\\bmeal plan\\b", .mealPlan),
        ("\\b(the five|five things)\\b", .five), ("\\bcalorie\\w*\\b", .calories),
    ]
    private static let anchors: [(pattern: String, anchor: LogAnchor)] = [
        ("\\b(before bed|at night|end of the day|all at once|before i sleep)\\b", .beforeBed),
        ("\\b(right after|after i eat|after eating|as i eat|after each meal|after every meal)\\b", .afterEating),
        ("\\b(sit back down|at my desk|when i sit|back at my desk)\\b", .whenSeated),
        ("\\b(my own moment|whenever|own time|my own time)\\b", .own),
    ]
    private static let frictions: [(pattern: String, friction: Friction)] = [
        ("\\bforget\\w*\\b", .forgetting), ("\\b(portion\\w*|amounts?)\\b", .portions),
        ("\\b(eat out|eating out|restaurant\\w*)\\b", .eatingOut), ("\\b(too long|no time|takes long|takes forever)\\b", .time),
    ]
    private static let subjects: [(pattern: String, subject: String)] = [
        ("\\bprotein\\b", "protein"), ("\\b(water|hydrat\\w*)\\b", "water"),
        ("\\b(produce|vegetable\\w*|veg|veggies|fruit\\w*)\\b", "produce"), ("\\b(fiber|fibre)\\b", "fiber"),
        ("\\b(calorie\\w*|kcal|treat\\w*)\\b", "calories"), ("\\b(plan|meal plan)\\b", "plan"),
        ("\\b(day|daily|quiet days|consistency)\\b", "consistency"),
    ]
    private static let showPattern = "\\b(how much|how many|how far|how am i|how'?s|how is|what'?s left|left|so far|show|where|see|open|remaining|why|what are)\\b"

    // MARK: - The reading (assist/llm.py read, in the same order)

    static func answer(_ text: String) async -> AssistReply {  // swiftlint:disable:this cyclomatic_complexity function_body_length
        let t = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        func has(_ pattern: String, in subject: String? = nil) -> Bool {
            (subject ?? t).range(of: pattern, options: .regularExpression) != nil
        }
        func first<T>(_ table: [(pattern: String, value: T)]) -> T? {
            table.first { has($0.pattern) }?.value
        }
        let current = MockTrackingService.current
        let store = MockTrackingService()
        let logging = has("\\b(log|logging|check[- ]?ins?|remind\\w*|track)\\b")
        let stop = has("\\b(stop|mute|turn off|no more|quiet|silence|enough|don'?t remind|don'?t send|fewer|without)\\b")
        let start = has("\\b(turn .* on|turn on|unmute|bring .* back|back on|resume|wake)\\b")
        let reminder = has("\\b(remind\\w*|nudge\\w*|tip\\w*|notification\\w*|alert\\w*|ones|them|messages|pings?)\\b")
        let show = has(showPattern)
        let subject = first(subjects.map { (pattern: $0.pattern, value: $0.subject) })
        let metric = metrics.first { has($0.pattern) }
        let surface = first(surfaces.map { (pattern: $0.pattern, value: $0.surface) })

        if let anchor = first(anchors.map { (pattern: $0.pattern, value: $0.anchor) }), logging, !stop {
            return await setAnchor(anchor, current: current, store: store)
        }
        if start, reminder {
            if let subject { return mute(subject, quiet: false) }
            return await setLevel(.standard, current: current, store: store)
        }
        if stop, reminder {
            if let subject, !has("\\b(all|every|everything|any|notifications|alerts)\\b") { return mute(subject, quiet: true) }
            return await setLevel(.off, current: current, store: store)
        }
        if (has("\\b(nothing|no reminders|no tips|leave me alone|check in myself|say nothing)\\b") && reminder)
            || has("\\b(leave me alone|check in myself)\\b") {
            return await setLevel(.off, current: current, store: store)
        }
        if has("\\b(coach me|coach|more tips|along the way|more often)\\b") {
            return await setLevel(.standard, current: current, store: store)
        }
        if has("\\b(only when|slipping|essential|less often|fewer|less)\\b"), reminder || t.contains("slipping") {
            return await setLevel(.essential, current: current, store: store)
        }
        if let friction = first(frictions.map { (pattern: $0.pattern, value: $0.friction) }), !show {
            let remove = has("\\b(don'?t|no longer|not anymore|anymore|stop|never)\\b")
            return await setFriction(friction, remove: remove, current: current, store: store)
        }
        let tile = metric.flatMap { FocusMetric(rawValue: $0.key) }
        if let tile, has("\\b(take .* off|remove|hide|drop|don'?t show|stop showing|off today)\\b") {
            return await setFocus(tile, remove: true, current: current, store: store)
        }
        if let tile, has("\\b(also show|also track|add|include|put .* on|show .* too|bring .* on)\\b"),
           !has(showPattern, in: t.replacingOccurrences(of: "also show", with: "")) {
            return await setFocus(tile, remove: false, current: current, store: store)
        }
        if show {
            if let surface, [.protocolPage, .week, .plan, .profile, .notifications, .settings].contains(surface) {
                return pointed(surface)
            }
            if let metric { return shown(metric: metric.metric, label: metric.label, current: current) }
            if let surface { return pointed(surface) }
        }
        if let mode = first(modes.map { (pattern: $0.pattern, value: $0.mode) }),
           has("\\b(switch|follow|track|watch|change|use|go back|go to|set|put me|move me|start|i want to|i'?d like to|just|only|mode)\\b") {
            return await setMode(mode, current: current, store: store)
        }
        let mealLike = has("\\b(i had|i ate|ate|had a|had some|had an|for (breakfast|lunch|dinner)|a bowl|a plate|a cup of|and some|snack|drank|eating)\\b")
        if let surface, has("\\b(my|the)\\b"), !mealLike, [.week, .protocolPage, .plan, .profile].contains(surface) {
            return pointed(surface)
        }
        if mealLike { return reply(.meal, meal) }
        return reply(.told, other)
    }

    // MARK: - The effects (assist/apply.py), on the mock's store

    private static func reply(
        _ kind: AssistReply.Kind, _ line: String, change: AssistChange? = nil, panel: TodayPanel? = nil,
        pointer: AssistPointer? = nil, undo: AssistUndo? = nil
    ) -> AssistReply {
        AssistReply(kind: kind.rawValue, line: line, change: change, panel: panel, pointer: pointer, undo: undo, turn: .app(line))
    }

    private static func setMode(_ mode: TrackingMode, current: TrackingPreference, store: MockTrackingService) async -> AssistReply {
        let row = AssistChange(icon: "slider.horizontal.3", title: "How I track", value: mode.shortLabel)
        if mode == current.mode { return reply(.told, "You're already following \(mode.title).", change: row) }
        _ = try? await store.update(TrackingUpdate(mode: mode))
        return reply(.changed, "You're following \(mode.title) now.", change: row, undo: AssistUndo(tracking: TrackingUpdate(mode: current.mode)))
    }

    private static func setFocus(_ tile: FocusMetric, remove: Bool, current: TrackingPreference, store: MockTrackingService) async -> AssistReply {
        var focus = current.focusMetrics.filter { !remove || $0 != tile }
        if !remove, !focus.contains(tile) { focus.append(tile) }
        let row = AssistChange(icon: "plus.circle", title: "Also show", value: focus.map(\.label).joined(separator: ", ").nilIfEmpty ?? "Nothing extra")
        if focus == current.focusMetrics {
            return reply(.told, remove ? "\(tile.label) isn't on Today." : "\(tile.label) is already on Today.", change: row)
        }
        _ = try? await store.update(TrackingUpdate(focusMetrics: focus))
        return reply(
            .changed, remove ? "\(tile.label) is off Today now." : "\(tile.label) is on Today now.", change: row,
            undo: AssistUndo(tracking: TrackingUpdate(focusMetrics: current.focusMetrics))
        )
    }

    private static func setLevel(_ level: NudgeLevel, current: TrackingPreference, store: MockTrackingService) async -> AssistReply {
        let row = AssistChange(icon: "bell", title: "Reminders", value: level.shortLabel)
        let line = levelLines[level] ?? other
        if level == current.nudgeLevel { return reply(.told, line, change: row) }
        _ = try? await store.update(TrackingUpdate(nudgeLevel: level))
        let undo = current.nudgeLevel.map { AssistUndo(tracking: TrackingUpdate(nudgeLevel: $0)) }
        return reply(.changed, line, change: row, undo: undo)
    }

    private static func setAnchor(_ anchor: LogAnchor, current: TrackingPreference, store: MockTrackingService) async -> AssistReply {
        let row = AssistChange(icon: "clock", title: "When you log", value: anchorShort[anchor] ?? anchor.title)
        if anchor == current.logAnchor { return reply(.told, anchorLine(anchor), change: row) }
        _ = try? await store.update(TrackingUpdate(logAnchor: anchor))
        let undo = current.logAnchor.map { AssistUndo(tracking: TrackingUpdate(logAnchor: $0)) }
        return reply(.changed, anchorLine(anchor), change: row, undo: undo)
    }

    /// Line for line with assist/lines.py `anchor_line`, from the same slots the server sets.
    static func anchorLine(_ anchor: LogAnchor) -> String {
        let slots = CheckSlots.composed(for: anchor)
        if anchor == .own { return "Nothing moves. The check-ins stay at \(slots.lateMorning ?? "") and \(slots.evening)." }
        guard let late = slots.lateMorning else { return "One check-in at \(slots.evening) now, and nothing before the evening." }
        return "Your check-ins follow \(anchorPhrases[anchor] ?? "") now: \(late) and \(slots.evening)."
    }

    private static func setFriction(_ friction: Friction, remove: Bool, current: TrackingPreference, store: MockTrackingService) async -> AssistReply {
        var frictions = current.frictions.filter { !remove || $0 != friction }
        if !remove, !frictions.contains(friction) { frictions.append(friction) }
        let row = AssistChange(icon: "hand.raised", title: "What gets in the way", value: frictions.map(\.title).joined(separator: ", ").nilIfEmpty ?? "Nothing")
        let line = remove ? "Noted. \(friction.title) is off your list." : "Noted: \(friction.title). \(friction.support)"
        if frictions == current.frictions { return reply(.told, line, change: row) }
        _ = try? await store.update(TrackingUpdate(frictions: frictions))
        return reply(.changed, line, change: row, undo: AssistUndo(tracking: TrackingUpdate(frictions: current.frictions)))
    }

    private static func mute(_ subject: String, quiet: Bool) -> AssistReply {
        let word = subjectWords[subject] ?? subject
        let title = subjectTitles[subject] ?? subject
        let row = AssistChange(icon: "bell.slash", title: "Muted", value: quiet ? title : "\(title) back on")
        let line = quiet ? "The \(word) reminders stay quiet until you turn them back on." : "The \(word) reminders are back on."
        return reply(.changed, line, change: row)
    }

    private static func shown(metric: String, label: String, current: TrackingPreference) -> AssistReply {
        let day = MockTodayService.populated(date: .now, mode: current.mode, focus: current.focusMetrics)
        guard day.printsNumbers else { return reply(.told, noNumbers) }
        guard let panel = day.panels.first(where: { $0.metric == metric }) else {
            return reply(.told, "\(label) isn't on your Today. Say 'also show \(label.lowercased())' and it will be.")
        }
        return reply(.shown, "Your \(label.lowercased()) today.", panel: panel)
    }

    private static func pointed(_ surface: AssistPointer.Surface) -> AssistReply {
        reply(
            .pointed, pointerLines[surface] ?? other,
            pointer: AssistPointer(surface: surface.rawValue, title: pointerTitles[surface] ?? "Today")
        )
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
