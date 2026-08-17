import Foundation
import Observation

/// Drives the weekly budget screen: loads the carry-adjusted week and hosts the
/// replan editor. The editor moves PLANNED kcal between today+future days while
/// keeping the weekly total constant — the same invariant the server enforces —
/// so a valid edit can never fail the sum check. All authoritative numbers
/// (carry, adjusted targets, clamps at the edges) come back from the engine on
/// save; the client-side redistribution below exists only to keep the editor's
/// bars conserving mass while you drag (AGENTS.md #6: the server calculates).
@MainActor
@Observable
final class WeekBudgetViewModel {
    enum ViewState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    private(set) var state: ViewState = .loading
    private(set) var budget: WeekBudget?

    /// Non-nil while editing: ISO date → planned whole kcal for ADJUSTABLE days only.
    private(set) var draft: [String: Int]?
    /// The draft as loaded — used to detect real changes and to discard.
    private var draftBaseline: [String: Int]?
    private(set) var saving = false
    var saveError: String?

    private let service: any WeekBudgetService

    init(service: (any WeekBudgetService)? = nil) {
        self.service = service
            ?? (RuntimeMode.usesMockServices ? MockWeekBudgetService() : LiveWeekBudgetService())
    }

    var isEditing: Bool { draft != nil }

    var isDirty: Bool {
        guard let draft, let draftBaseline else { return false }
        return draft != draftBaseline
    }

    /// Editable-day bounds, mirroring the server's plan validation exactly
    /// (weekbudget/router.py): [max(1200, 0.5·B), 2·B]. Mirroring, not inventing:
    /// the server remains the authority and re-validates on save.
    var planFloor: Int {
        Int(max(1200.0, 0.5 * (budget?.baselineDailyKcal ?? 2000)).rounded())
    }

    var planCeiling: Int {
        Int((2.0 * (budget?.baselineDailyKcal ?? 2000)).rounded())
    }

    func load(containing date: Date = .now) async {
        if budget == nil { state = .loading }
        do {
            budget = try await service.budget(containing: date)
            state = .loaded
        } catch {
            if error is CancellationError || Task.isCancelled { return }
            if budget == nil { state = .failed("Couldn't load your week.") }
        }
    }

    // MARK: - Editor lifecycle

    func beginEditing() {
        guard let budget else { return }
        var plan: [String: Int] = [:]
        for day in budget.days where day.isAdjustable {
            plan[day.date] = Int(day.plannedKcal.rounded())
        }
        draft = plan
        draftBaseline = plan
    }

    func discardEdits() {
        draft = nil
        draftBaseline = nil
    }

    /// The value the editor renders for a day: the draft while editing, else the plan.
    func editorValue(for day: WeekBudgetDay) -> Int {
        draft?[day.date] ?? Int(day.plannedKcal.rounded())
    }

    /// Move `date`'s planned kcal toward `proposed`, compensating across the OTHER
    /// adjustable days so the weekly total is conserved. The move is capped by how
    /// much the other days can absorb inside [floor, ceiling] — with one adjustable
    /// day there is nothing to trade with and the bar simply doesn't move.
    func setAllocation(_ date: String, proposing proposed: Int) {
        guard var plan = draft, let current = plan[date] else { return }
        let lo = planFloor
        let hi = planCeiling
        let others = plan.keys.filter { $0 != date }.sorted()
        guard !others.isEmpty else { return }

        var delta = min(max(proposed, lo), hi) - current
        guard delta != 0 else { return }

        // Others move by -delta in total. Their capacity bounds the primary move.
        let capacity = others.reduce(0) { total, key in
            let value = plan[key] ?? 0
            return total + (delta > 0 ? value - lo : hi - value)
        }
        if abs(delta) > capacity {
            delta = delta > 0 ? capacity : -capacity
        }
        guard delta != 0 else { return }
        plan[date] = current + delta

        // Equal-share waterfall (integer): each pass spreads the outstanding amount
        // over days that still have headroom; clamped days drop out. Terminates —
        // every pass either finishes the amount or removes a day (≤ 7 passes), and
        // the capacity pre-check guarantees full absorption.
        var outstanding = -delta
        var open = others
        while outstanding != 0, !open.isEmpty {
            let share = outstanding / open.count
            var remainder = outstanding % open.count
            var nextOpen: [String] = []
            outstanding = 0
            for key in open {
                var give = share
                if remainder != 0 {
                    give += remainder > 0 ? 1 : -1
                    remainder += remainder > 0 ? -1 : 1
                }
                let value = plan[key] ?? 0
                let moved = min(max(value + give, lo), hi)
                outstanding += (value + give) - moved
                plan[key] = moved
                if moved > lo && moved < hi { nextOpen.append(key) }
            }
            open = nextOpen
        }
        draft = plan
    }

    func savePlan() async {
        guard let budget, let draft, isDirty else {
            discardEdits()
            return
        }
        saving = true
        do {
            let updated = try await service.savePlan(
                weekStart: budget.weekStart, allocations: draft
            )
            self.budget = updated
            discardEdits()
        } catch {
            // Honest failure surface (waterFailureMessage pattern): a server
            // rejection names the server; only transport blames the network.
            if let apiError = error as? APIError, case let .status(code, body) = apiError {
                saveError = body.isEmpty
                    ? "The server couldn't save that plan (error \(code))."
                    : Self.detail(from: body, code: code)
            } else if let apiError = error as? APIError, case .transport = apiError {
                saveError = "That didn't reach the server. Check your connection and try again."
            } else {
                saveError = "That plan didn't save. Please try again in a moment."
            }
        }
        saving = false
    }

    /// Pull FastAPI's {"detail": "..."} message out so a validation rejection tells
    /// the user WHAT was wrong, not just that something was.
    private static func detail(from body: String, code: Int) -> String {
        struct ErrorBody: Decodable { let detail: String? }
        if let data = body.data(using: .utf8),
           let parsed = try? JSONDecoder().decode(ErrorBody.self, from: data),
           let detail = parsed.detail, !detail.isEmpty {
            return detail
        }
        return "The server couldn't save that plan (error \(code))."
    }
}
