import Foundation
import VoCalCapture
import Observation

/// Drives the Today dashboard. Loads the day's dashboard through `TodayService` (mock on the
/// sim path, live REST otherwise) and projects it into a small view state. Keeps the last
/// loaded dashboard visible across a refresh so the screen never flashes empty (the reward
/// beat after a log just updates the numbers in place).
@MainActor
@Observable
final class TodayViewModel {
    enum ViewState: Equatable {
        case loading
        case loaded(TodayDashboard)
        case failed(String)
    }

    private(set) var state: ViewState = .loading
    /// True when a weekly check-in is due (drives the Today banner, G1).
    private(set) var checkinDue = false
    var selectedDate: Date

    /// Committed recordings on the selected day that never reached "logged" (R8): the outbox
    /// is the truth for "recorded", the outcome ledger for "finished or discarded".
    private(set) var unfinished: [UnfinishedCapture] = []

    private let service: any TodayService
    private let checkin: any CheckinService
    private let outcomes: any UnfinishedCaptureReading & CaptureOutcomeRecording

    init(
        service: (any TodayService)? = nil,
        checkin: (any CheckinService)? = nil,
        outcomes: (any UnfinishedCaptureReading & CaptureOutcomeRecording)? = nil,
        date: Date = .now
    ) {
        self.selectedDate = date
        let mock = RuntimeMode.usesMockServices
        self.service = service ?? (mock ? MockTodayService() : LiveTodayService())
        self.checkin = checkin ?? (mock ? MockCheckinService() : LiveCheckinService())
        self.outcomes = outcomes ?? (mock ? MockCaptureOutcomes.shared : CaptureOutcomeStore.shared)
    }

    /// The dashboard currently on screen, if any (kept visible during a refresh).
    var dashboard: TodayDashboard? {
        if case let .loaded(dashboard) = state { return dashboard }
        return nil
    }

    /// Monotonic ticket for in-flight loads: a completion only writes state if it is still
    /// the NEWEST request. Without it, switching days fast lets a slow older response land
    /// after a newer one and show the wrong day's numbers.
    private var loadGeneration = 0

    func load() async {
        // Usuals ride ALONGSIDE the day, never in front of it: their own task, their own
        // failure. A shortcut row that can't load must cost the day's numbers nothing —
        // delete the whole usuals feature and this load is unchanged (capture/critical-path
        // isolation, AGENTS.md). Unstructured on purpose: it only ever assigns a list, so a
        // late arrival can't corrupt the day the way a stale dashboard could.
        Task { await self.loadUsuals() }
        // Unfinished recordings ride alongside the day the same way: local reads only, their
        // own task, and a failure leaves the list as it was.
        Task { await self.loadUnfinished() }
        // Don't blank an already-loaded screen on refresh — only show the spinner cold.
        if dashboard == nil { state = .loading }
        loadGeneration += 1
        let ticket = loadGeneration
        do {
            let dashboard = try await service.dashboard(date: selectedDate)
            guard ticket == loadGeneration else { return }
            state = .loaded(dashboard)
        } catch {
            // A cancelled task (view disappeared, refreshToken bumped) is not a failure —
            // writing .failed here flashed "Couldn't load today." during normal navigation.
            if error is CancellationError || Task.isCancelled { return }
            guard ticket == loadGeneration else { return }
            if dashboard == nil {
                state = .failed("Couldn't load today.")
            }
            // If we already have a dashboard, keep showing it; a transient refresh failure
            // shouldn't wipe the day.
        }
        // Only the current day surfaces the check-in banner; a snooze mutes it, and
        // the post-onboarding grace window keeps it away from fresh accounts.
        checkinDue =
            Calendar.current.isDateInToday(selectedDate)
            && !Self.checkinSnoozed
            && !OnboardingGrace.isActive
            ? await checkin.isDue() : false
    }

    /// Refresh the Unfinished list for the selected day (after a voice sheet closes, after a
    /// discard). A day switched mid-read keeps the newer day's list.
    func loadUnfinished() async {
        let day = selectedDate
        let listed = (try? await outcomes.unfinishedCaptures(on: day)) ?? []
        guard day == selectedDate else { return }
        unfinished = listed
    }

    /// Discard an unfinished recording: a ledger mark, never a deletion. The audio stays in
    /// the outbox and on the server; only Today stops listing it.
    func discardUnfinished(_ captureID: String) async {
        await outcomes.record(CaptureOutcome(captureID: captureID, kind: .dismissed, at: Date(), reason: "user"))
        await loadUnfinished()
    }

    /// Hide the banner for the rest of the week once the user has handled the check-in.
    func dismissCheckin() {
        // A completed check-in supersedes any pending snooze (the server's 7-day
        // cadence owns the next appearance from here).
        UserDefaults.standard.removeObject(forKey: Self.checkinSnoozeKey)
        checkinDue = false
    }

    /// "Later" on the banner: mute it for a couple of days without doing the check-in.
    /// The check-in stays reachable (it re-surfaces after the snooze); this only quiets
    /// the banner — being due is server truth and untouched.
    func snoozeCheckin(days: Int = 2) {
        let until = Calendar.current.date(byAdding: .day, value: days, to: .now) ?? .now
        UserDefaults.standard.set(
            until.timeIntervalSince1970, forKey: Self.checkinSnoozeKey
        )
        checkinDue = false
    }

    private static let checkinSnoozeKey = "vocal.checkin.snoozedUntil"

    private static var checkinSnoozed: Bool {
        UserDefaults.standard.double(forKey: checkinSnoozeKey) > Date.now.timeIntervalSince1970
    }

    func select(_ date: Date) async {
        guard !Calendar.current.isDate(date, inSameDayAs: selectedDate) else { return }
        selectedDate = date
        state = .loading
        await load()
    }

    // MARK: - Edit / delete a logged meal

    /// Fetch a logged meal's full items for the edit screen.
    func loadMeal(_ id: String) async throws -> LoggedMeal {
        try await service.meal(id: id)
    }

    /// Persist edits, then refresh the day so totals reflect the change.
    func saveMeal(_ id: String, name: String?, items: [ConfirmedItem]) async throws {
        _ = try await service.updateMeal(id: id, UpdateMealRequest(name: name, mealType: nil, items: items))
        await load()
    }

    /// Delete a logged meal, then refresh the day's totals. Throws on failure — the edit
    /// sheet keeps itself open and says so; dismissing on a swallowed error read as success
    /// while the meal was still there (a false claim, MUST-NOT #6).
    func deleteMeal(_ id: String) async throws {
        try await service.deleteMeal(id: id)
        await load()
    }

    // MARK: - Usuals (one-tap re-log)

    /// Saved meal templates for the Today chips row. Empty = no row at all (an empty header
    /// is clutter on a home screen whose job is to stay calm, decision #28).
    private(set) var usuals: [SavedMeal] = []
    /// The usual currently being re-logged, so its chip can show the in-flight state. One at a
    /// time: a chip tap is a deliberate single action, not a queue.
    private(set) var loggingUsualID: String?

    /// Refresh the usuals row. A failure keeps the LAST known list rather than blanking the
    /// row: usuals are a shortcut, so a transient fetch failure must not look like the user
    /// lost their saved meals. Nothing downstream reads a truth claim off this list — the row
    /// only ever offers to log, and the logging itself is proved by the server's row.
    func loadUsuals() async {
        guard let loaded = try? await service.usuals() else { return }
        usuals = loaded
    }

    /// Re-log a usual onto the SELECTED day. No optimistic UI: the meal joins the list only
    /// after the server's row comes back (the "Logged" rung needs that row, MUST-NOT #6).
    /// Returns nil on success, or an honest failure message.
    func logUsual(_ usual: SavedMeal) async -> String? {
        loggingUsualID = usual.id
        defer { loggingUsualID = nil }
        let request = LogMealRequest(
            parseID: nil,  // a re-log has no capture of its own; corrections need one, so none are minted
            name: usual.name,
            // The template doesn't carry a meal type (saved_meals has no such column), and
            // guessing one from the clock would be inventing data — Today numbers meals by
            // order logged, not by type.
            mealType: .unspecified,
            items: usual.items,
            // Backdating uses the SAME instant math as the voice confirm — one helper, so a
            // usual logged onto a past day lands exactly where a spoken one would.
            loggedAt: VoiceLogViewModel.loggedAt(on: selectedDate)
        )
        do {
            _ = try await service.logUsual(request)
        } catch {
            return Self.logFailureMessage(for: error, subject: "meal")
        }
        await load()
        return nil
    }

    /// Forget a saved template. On success the chip goes away locally — the server already
    /// confirmed the row is gone, so removing it here is reloaded truth, not optimism. Throws
    /// so the view can say the remove didn't land (a silent no-op reads as a broken button).
    func deleteUsual(_ id: String) async throws {
        try await service.deleteUsual(id: id)
        usuals.removeAll { $0.id == id }
    }

    // MARK: - Water quick-add

    /// Log a manual water amount (Today's water tile → add-water sheet), then refresh so the
    /// water card reflects the new server total. Returns nil on success, or an HONEST failure
    /// message on failure — the tile shows it (the sheet dismisses optimistically). Swallowing
    /// the failure entirely was a field bug (2026-07: "water logging isn't working" — adds
    /// failed with zero feedback); blaming the network for a SERVER rejection was the next one
    /// (2026-07: prod 500'd on every water write from a deploy/migration gap, but the alert
    /// said "check your connection", sending users to chase a network problem that wasn't
    /// there). Mirror AuthGateView.message: only a real transport error blames the network.
    func addWater(oz: Double) async -> String? {
        guard oz > 0 else { return "Enter an amount greater than zero." }
        // ONE request per user intent, retried with the SAME clientWaterID: a fresh
        // UUID per attempt defeats the idempotency key it exists for (RT-13) — a
        // timeout after the server committed, then a retry under a new key, double
        // counts. Under a stable key the retry dedupes server-side (201, deduped).
        let request = WaterLogRequest(amountOz: oz)
        var lastError: Error?
        for attempt in 0..<2 {
            do {
                _ = try await service.logWater(request)
                await load()
                return nil
            } catch {
                lastError = error
                if attempt == 0 { continue }
            }
        }
        // The tile only ever shows reloaded server truth, so no false "added" claim — but the
        // caller must still TELL the user the add didn't land, and tell them the TRUTH about why.
        return Self.waterFailureMessage(for: lastError)
    }

    /// Honest failure copy: a genuine transport error (offline, timeout) is the only case that
    /// blames the connection; a server rejection (4xx/5xx) says the server refused it, so the
    /// user doesn't waste time on a network that's fine. The real error is logged for triage.
    static func waterFailureMessage(for error: Error?) -> String {
        logFailureMessage(for: error, subject: "water")
    }

    /// The honest-failure rule itself, shared by every Today write (water, re-logged usuals):
    /// `subject` is the thing that didn't log. One implementation so a new write surface can't
    /// quietly reintroduce the "check your connection" lie for a server-side rejection.
    static func logFailureMessage(for error: Error?, subject: String) -> String {
        let connection = "That didn't reach the server. Check your connection and try again."
        let generic = "That \(subject) didn't log. Please try again in a moment."
        if let apiError = error as? APIError {
            switch apiError {
            case .transport:
                return connection
            case let .status(code, _):
                return "The server couldn't log that \(subject) (error \(code)). Please try again in a moment."
            case .badURL, .decoding:
                return generic
            }
        }
        if error is URLError { return connection }
        return generic
    }
}
