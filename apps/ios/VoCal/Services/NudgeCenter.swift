import Foundation
import Observation

/// Owns the nudge loop client-side: fetch the deterministic plan, apply the local
/// shown-ledger, surface at most one in-app card, and (re)schedule the local
/// notifications. The SERVER decides what could help (tested engine); this type
/// only decides delivery bookkeeping — what was already shown, when.
///
/// Refresh triggers: Today appearing and a meal/water log completing. Never the
/// capture path — delete this type and voice logging still works (AGENTS.md
/// capture-path isolation).
@MainActor
@Observable
final class NudgeCenter {
    static let shared = NudgeCenter()

    /// The one in-app nudge card Today shows (nil = no card, or nudges disabled).
    private(set) var currentCard: NudgeCard?
    /// The nudges the person said were not for them (decision 67), from the last plan.
    private(set) var muted: [MutedNudge] = []
    /// The permission card is due (spec N8): a log happened, the level is not off, iOS has not
    /// been asked, and the person has not said Not now before.
    private(set) var permissionAskPending = false
    /// The card or fire last surfaced, so a log within the hour counts as acting on it.
    @ObservationIgnored private var lastSurfaced: (id: String, at: Date)?

    private let api: (any APIClientProtocol)?
    /// Where an invitation's answer goes (decision 62): the preference moves, or the offer is
    /// declined for good. Mock on the sim path, like the plan itself.
    private let tracking: any TrackingService
    private let defaults = UserDefaults.standard
    private var refreshTask: Task<Void, Never>?

    private static let ledgerKey = "vocal.nudges.shown"
    private static let enabledKey = "vocal.nudges.enabled"
    private static let levelKey = "vocal.nudges.level"
    private static let ledgerCap = 48  // ids worth remembering; oldest pruned
    private static let permissionDeclinedKey = "vocal.nudges.permission.declined"
    /// Answers not yet on the server (offline, or given from the lock screen with the app
    /// closed), as [{"id", "kind", "day"}]: idempotent by the three, flushed on the next plan.
    private static let reactionQueueKey = "vocal.nudges.reactions.pending"
    /// A log this soon after a card or a fire counts as acting on it.
    private static let actedWithin: TimeInterval = 3600

    private init() {
        // Mock/sim path serves a canned card with no network (UI reachable in tests).
        self.api = RuntimeMode.usesMockServices ? nil : APIClient()
        self.tracking = RuntimeMode.usesMockServices ? MockTrackingService() : LiveTrackingService()
    }

    /// The user's coaching level. Defaults to `.essential` — the calm default (the
    /// louder "standard" catalog is opt-in). Migrates the legacy on/off toggle once:
    /// an explicit old "off" stays off; anything else takes the new default.
    var level: NudgeLevel {
        get {
            if let raw = defaults.string(forKey: Self.levelKey),
               let stored = NudgeLevel(rawValue: raw) {
                return stored
            }
            if defaults.object(forKey: Self.enabledKey) as? Bool == false { return .off }
            return .essential
        }
        set {
            defaults.set(newValue.rawValue, forKey: Self.levelKey)
            if newValue == .off {
                currentCard = nil
                Task { await NudgeNotificationService.shared.cancelAll() }
            } else {
                refresh()
            }
        }
    }

    /// Convenience the guards below read: any level that delivers something.
    var isEnabled: Bool { level != .off }

    /// Re-plan: fetch, filter, surface, reschedule. Coalesces concurrent calls.
    func refresh() {
        wireNotificationCallbacks()
        guard isEnabled else { return }
        // Post-onboarding grace: a brand-new user gets a few quiet days before any
        // coaching fires. Also drops anything already scheduled, so a plan fetched
        // in the same session onboarding completed can't fire mid-grace.
        guard !OnboardingGrace.isActive else {
            currentCard = nil
            Task { await NudgeNotificationService.shared.cancelAll() }
            return
        }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.performRefresh()
        }
    }

    /// A meal or water entry just committed: the moment we've delivered value. A log soon after
    /// a card or a fire is the answer to it (decision 67); the permission is asked by the card
    /// on Today in the person's own sentence (spec N8), never by the system sheet on its own;
    /// then re-plan on the fresh context.
    func logCompleted() {
        wireNotificationCallbacks()
        guard isEnabled else { return }
        if let last = lastSurfaced, Date().timeIntervalSince(last.at) < Self.actedWithin {
            react(last.id, .acted)
            lastSurfaced = nil
        }
        Task { [weak self] in
            guard let self else { return }
            if await NudgeNotificationService.shared.currentStatus() == .notDetermined,
               !defaults.bool(forKey: Self.permissionDeclinedKey) {
                permissionAskPending = true
            }
            refresh()
        }
    }

    /// The person's tap on the permission card, or on Settings' Delivery row: the system sheet
    /// comes from this and nothing else.
    func allowNotifications() async {
        permissionAskPending = false
        defaults.removeObject(forKey: Self.permissionDeclinedKey)
        await NudgeNotificationService.shared.requestAuthorizationIfNeeded()
        refresh()
    }

    /// "Not now" on the permission card: remembered, so the card never comes back on its own.
    /// Settings → Notifications keeps the door (Delivery, "Not asked yet").
    func declineNotificationAsk() {
        permissionAskPending = false
        defaults.set(true, forKey: Self.permissionDeclinedKey)
    }

    /// One answer to one nudge (decision 67): queued locally, idempotent by nudge, kind and day,
    /// sent on the next plan or now. The engine remembers; the phone forgets once it is sent.
    func react(_ id: String, _ kind: NudgeReaction) {
        var queue = NudgeReactionQueue(reactionQueue())
        if queue.add(id: id, kind: kind, day: Self.dayFormatter.string(from: Date())) {
            defaults.set(queue.entries, forKey: Self.reactionQueueKey)
        }
        Task { [weak self] in await self?.flushReactions() }
    }

    /// The long-press's answer (spec N6): the card goes, the reason is the dismissal.
    func report(_ card: NudgeCard, _ kind: NudgeReaction) {
        markShown(card.id)
        if currentCard?.id == card.id { currentCard = nil }
        react(card.id, kind)
    }

    /// "Turn back on" in Settings: the nudge leaves the muted list on the next plan.
    func unmute(_ id: String) {
        react(id, .unmute)
        muted.removeAll { $0.id == id }
        refresh()
    }

    /// The background refresh's entry: one plan, awaited, no coalescing.
    func refreshNow() async {
        wireNotificationCallbacks()
        guard isEnabled, !OnboardingGrace.isActive else { return }
        await performRefresh()
    }

    private func wireNotificationCallbacks() {
        NudgeNotificationService.shared.onNudgeTapped = { [weak self] id in
            self?.markShown(id)
        }
        NudgeNotificationService.shared.onReaction = { [weak self] id, kind in
            self?.react(id, kind)
        }
    }

    /// User dismissed (or acted on) the in-app card: record it so the server's
    /// cooldown suppresses a repeat, then drop it.
    func dismissCurrent() {
        guard let card = currentCard else { return }
        markShown(card.id)
        currentCard = nil
        // The quiet dismiss is an answer too (decision 67): three in a row and the engine
        // goes quiet on that nudge for a month. An invitation's Not now is not a dismissal of a
        // nudge; its fortnight is the engine's already.
        if !card.isInvitation {
            react(card.id, .dismissed)
        }
    }

    /// Yes to an invitation: the preference moves to what it offered (a mode, or a focus
    /// metric added to the current ones), source "invited". The card goes only once the
    /// server's echo is back; false means the write did not land and the card stays, so the
    /// view can say so (a vanished card would claim a change that never happened).
    func acceptInvitation(_ card: NudgeCard) async -> Bool {
        var update = TrackingUpdate(source: .invited)
        if let mode = card.offerMode.flatMap(TrackingMode.init(rawValue:)) {
            update.mode = mode
        } else if let focus = card.offerFocus.flatMap(FocusMetric.init(rawValue:)) {
            // The list is replaced whole server-side, so the current focus metrics come first.
            guard let current = try? await tracking.preference() else { return false }
            update.focusMetrics = current.focusMetrics.contains(focus) ? current.focusMetrics : current.focusMetrics + [focus]
        } else {
            // An offer this build cannot act on: say so rather than pretend.
            return false
        }
        guard (try? await tracking.update(update)) != nil else { return false }
        dismissCurrent()
        return true
    }

    /// "Don't offer this again": a durable decline of the offer key (never a timer), reversible
    /// from Settings → How I track. Same contract as `acceptInvitation` for the return value.
    func declineInvitation(_ card: NudgeCard) async -> Bool {
        guard let key = card.declineKey else {
            dismissCurrent()
            return true
        }
        guard (try? await tracking.update(TrackingUpdate(declineOffer: key, source: .declined))) != nil else {
            return false
        }
        dismissCurrent()
        return true
    }

    // MARK: - Internals

    private func performRefresh() async {
        guard let api else {
            // Mock path: a representative card so sim/UITest reaches the UI. An
            // ESSENTIAL-level card, since that's the default the live path plans for.
            currentCard = NudgeCard(
                id: "no_log_today",
                category: "consistency",
                message: "Nothing logged yet today. A ten-second voice note keeps the day honest. Just say what you had; we'll do the math.",
                proTip: "Right after a meal is the easiest moment: phone up, one sentence, done.",
                priority: 70,
                cooldownDays: 1
            )
            return
        }
        // The preference owns how much the app says (decision 66); the phone's level is a
        // cache of it. Adopt the stored level before planning so a new phone, or a change made
        // on another, speaks at the level the person chose. Written to the cache directly: the
        // setter's refresh would re-enter this very refresh.
        if let stored = (try? await tracking.preference())?.nudgeLevel, stored != level {
            defaults.set(stored.rawValue, forKey: Self.levelKey)
            if stored == .off {
                currentCard = nil
                await NudgeNotificationService.shared.cancelAll()
                return
            }
        }
        await flushReactions()
        do {
            let plan = try await api.nudgePlan(recentlyShown: ledger(), level: level)
            if Task.isCancelled { return }
            muted = plan.muted
            if let card = plan.immediate.first {
                currentCard = card
                markShown(card.id)  // surfaced on Today = shown
                if !card.isInvitation { lastSurfaced = (card.id, Date()) }
            } else {
                currentCard = nil
            }
            // Same-day fires are recorded at schedule time: if it's set to fire today,
            // it counts against today's budget whether or not the user taps it.
            for entry in plan.scheduled
            where Calendar.current.isDateInToday(entry.fireAt) {
                markShown(entry.card.id, on: entry.fireAt)
            }
            // The body's clock, from the phone alone (decision 52): a fire the server marked
            // may move later for today's workout or the night's end; nothing is sent back.
            let clock = await HealthKitService.shared.bodyClock()
            await NudgeNotificationService.shared.reschedule(plan.scheduled, clock: clock)
            HealthKitService.shared.startObservingWorkouts { [weak self] in
                Task { @MainActor in self?.refresh() }
            }
            NudgeBackgroundRefresh.scheduleNextMorning()
        } catch {
            // A failed plan fetch is silent — nudges are a delight layer, never an error.
            if !Task.isCancelled { currentCard = nil }
        }
    }

    private func ledger() -> [String: String] {
        defaults.dictionary(forKey: Self.ledgerKey) as? [String: String] ?? [:]
    }

    private func reactionQueue() -> [[String: String]] {
        defaults.array(forKey: Self.reactionQueueKey) as? [[String: String]] ?? []
    }

    /// Send what the person answered. A transport failure keeps the answer for the next plan; a
    /// server that refuses it (a build before the endpoint, an unknown kind) drops it, since
    /// retrying would never land. The mock path has no server and forgets at once.
    private func flushReactions() async {
        let queue = reactionQueue()
        guard !queue.isEmpty else { return }
        guard let api else {
            defaults.removeObject(forKey: Self.reactionQueueKey)
            return
        }
        var remaining: [[String: String]] = []
        for entry in queue {
            guard let id = entry["id"], let raw = entry["kind"], let kind = NudgeReaction(rawValue: raw) else { continue }
            do {
                try await api.reactToNudge(NudgeReactionRequest(nudgeId: id, kind: kind))
            } catch let error as APIError {
                if case .transport = error { remaining.append(entry) }
            } catch {
                remaining.append(entry)
            }
        }
        defaults.set(remaining, forKey: Self.reactionQueueKey)
    }

    private func markShown(_ id: String, on date: Date = Date()) {
        var entries = ledger()
        entries[id] = Self.dayFormatter.string(from: date)
        if entries.count > Self.ledgerCap {
            // Prune oldest entries; the ledger is advisory delivery state, not truth.
            let sorted = entries.sorted { $0.value < $1.value }
            for (key, _) in sorted.prefix(entries.count - Self.ledgerCap) {
                entries.removeValue(forKey: key)
            }
        }
        defaults.set(entries, forKey: Self.ledgerKey)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
