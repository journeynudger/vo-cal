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

    private let api: (any APIClientProtocol)?
    private let defaults = UserDefaults.standard
    private var refreshTask: Task<Void, Never>?

    private static let ledgerKey = "vocal.nudges.shown"
    private static let enabledKey = "vocal.nudges.enabled"
    private static let levelKey = "vocal.nudges.level"
    private static let ledgerCap = 48  // ids worth remembering; oldest pruned

    private init() {
        // Mock/sim path serves a canned card with no network (UI reachable in tests).
        self.api = RuntimeMode.usesMockServices ? nil : APIClient()
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
        guard isEnabled else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.performRefresh()
        }
    }

    /// A meal or water entry just committed: the moment we've delivered value —
    /// ask for notification permission (once), then re-plan on the fresh context.
    func logCompleted() {
        guard isEnabled else { return }
        Task { [weak self] in
            NudgeNotificationService.shared.onNudgeTapped = { [weak self] id in
                self?.markShown(id)
            }
            await NudgeNotificationService.shared.requestAuthorizationIfNeeded()
            self?.refresh()
        }
    }

    /// User dismissed (or acted on) the in-app card: record it so the server's
    /// cooldown suppresses a repeat, then drop it.
    func dismissCurrent() {
        guard let card = currentCard else { return }
        markShown(card.id)
        currentCard = nil
    }

    // MARK: - Internals

    private func performRefresh() async {
        guard let api else {
            // Mock path: a representative card so sim/UITest reaches the UI. An
            // ESSENTIAL-level card, since that's the default the live path plans for.
            currentCard = NudgeCard(
                id: "no_log_today",
                category: "consistency",
                message: "Nothing logged yet today — a ten-second voice note keeps your streak honest. Just say what you had; we'll do the math.",
                proTip: "Right after a meal is the easiest moment: phone up, one sentence, done.",
                priority: 70,
                cooldownDays: 1
            )
            return
        }
        do {
            let plan = try await api.nudgePlan(recentlyShown: ledger(), level: level)
            if Task.isCancelled { return }
            if let card = plan.immediate.first {
                currentCard = card
                markShown(card.id)  // surfaced on Today = shown
            } else {
                currentCard = nil
            }
            // Same-day fires are recorded at schedule time: if it's set to fire today,
            // it counts against today's budget whether or not the user taps it.
            for entry in plan.scheduled
            where Calendar.current.isDateInToday(entry.fireAt) {
                markShown(entry.card.id, on: entry.fireAt)
            }
            await NudgeNotificationService.shared.reschedule(plan.scheduled)
        } catch {
            // A failed plan fetch is silent — nudges are a delight layer, never an error.
            if !Task.isCancelled { currentCard = nil }
        }
    }

    private func ledger() -> [String: String] {
        defaults.dictionary(forKey: Self.ledgerKey) as? [String: String] ?? [:]
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
