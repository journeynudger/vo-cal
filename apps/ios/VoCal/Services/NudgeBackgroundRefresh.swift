import BackgroundTasks
import Foundation

/// The daily re-plan for the person who stopped opening the app (decision 67, spec N10): the
/// plan is otherwise fetched only on Today-open and after a log, so the one who went quiet, the
/// person gone_quiet exists for, would keep only the fires scheduled on their last visit. iOS
/// grants the refresh when it sees fit (usually around the asked hour); the task fetches a plan
/// and reschedules, nothing else. Off the capture lane by construction: it runs NudgeCenter and
/// never touches the mic, the outbox or the upload worker.
enum NudgeBackgroundRefresh {
    static let taskID = "com.vo-cal.app.replan"
    /// The hour the next re-plan is asked for: inside the engine's quiet hours, after the night.
    static let morningHour = 8
    static let morningMinute = 30

    /// Registration must happen before the app finishes launching (BackgroundTasks' rule), so
    /// `VoCalApp.init` calls this: a closure stored, no work done.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            // BGTask is not Sendable; it is thread-safe and completed exactly once below.
            nonisolated(unsafe) let task = task
            let work = Task { @MainActor in
                await NudgeCenter.shared.refreshNow()
                scheduleNextMorning()
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = {
                work.cancel()
                task.setTaskCompleted(success: false)
            }
        }
    }

    /// Ask for the next morning's re-plan. Called after every plan; a submit that fails (the
    /// simulator, a denied background mode) is silent: the next open plans as before.
    static func scheduleNextMorning(now: Date = .now, calendar: Calendar = .current) {
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        request.earliestBeginDate = nextMorning(after: now, calendar: calendar)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Tomorrow at 08:30 local. Pure, so the render tests pin it.
    static func nextMorning(after now: Date, calendar: Calendar = .current) -> Date {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        return calendar.date(bySettingHour: morningHour, minute: morningMinute, second: 0, of: tomorrow) ?? tomorrow
    }
}
