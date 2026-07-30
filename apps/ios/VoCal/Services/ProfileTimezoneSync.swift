import Foundation

/// Fire-and-forget sync of the device's IANA timezone to `profiles.tz`.
///
/// Until this existed nothing ever wrote the profile tz, so the nudge planner (which has
/// no request to read a `tz` param from) computed every quiet-hours window in UTC, and any
/// read that omitted the param bucketed days by UTC (deferred item from #18). Runs from a
/// view `.task` after auth is ready — never on the capture path, never blocking a screen.
///
/// Re-sends only when the current tz differs from the last server-acknowledged one, so the
/// steady-state launch cost is a UserDefaults read. Failure is swallowed on purpose: the
/// read endpoints still receive the device tz per-request, and the next launch retries.
enum ProfileTimezoneSync {
    private static let syncedTZKey = "vocal.profile.tz.synced"

    static func syncIfNeeded(api: APIClient = APIClient()) async {
        let tz = TimeZone.current.identifier
        guard UserDefaults.standard.string(forKey: syncedTZKey) != tz else { return }
        do {
            try await api.updateProfile(tz: tz)
            UserDefaults.standard.set(tz, forKey: syncedTZKey)
        } catch {
            // Best-effort by design — see the type comment.
        }
    }
}
