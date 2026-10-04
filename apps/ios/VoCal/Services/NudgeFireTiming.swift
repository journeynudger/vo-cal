import Foundation

/// The body as a clock for the reminders, on the phone (decision 67, the spec's 6.5). The
/// server marks which fires may move (`NudgeContext`); this moves them from what Apple Health
/// knows here and nowhere else: a fire for after training waits forty-five minutes past today's
/// last workout; a morning fire waits thirty minutes past the night's end. A fire is only ever
/// moved later, never earlier, and never into the night: pushed past quiet hours it is dropped,
/// not delayed. Pure, so the render tests pin it; the Health reads live in `HealthKitService`.
///
/// Never send these dates anywhere (decision 52; AGENTS.md MUST-NOT 5): they move a local
/// notification's time and are forgotten.
enum NudgeFireTiming {
    static let afterWorkout: TimeInterval = 45 * 60
    static let afterWake: TimeInterval = 30 * 60
    /// The engine's quiet hours end (nudges/engine.py QUIET_END_HOUR); a moved fire respects it too.
    static let quietEndHour = 21

    /// What the phone knows of the body today. Nil means unknown (no watch, no permission, no
    /// sample), and an unknown clock moves nothing.
    struct BodyClock: Sendable, Equatable {
        var lastWorkoutEnd: Date?
        var sleepEnd: Date?

        static let unknown = BodyClock()
    }

    /// The fire's time after the body's say, or nil when it should not fire today after all.
    static func shifted(
        fire: Date,
        context: NudgeContext,
        clock: BodyClock,
        now: Date,
        calendar: Calendar = .current
    ) -> Date? {
        var when = fire
        if context.afterWorkout, let end = clock.lastWorkoutEnd, calendar.isDate(end, inSameDayAs: fire) {
            when = max(when, end.addingTimeInterval(afterWorkout))
        }
        if context.afterWake, let sleepEnd = clock.sleepEnd, calendar.isDate(sleepEnd, inSameDayAs: fire) {
            when = max(when, sleepEnd.addingTimeInterval(afterWake))
        }
        guard when > now else { return nil }
        guard calendar.isDate(when, inSameDayAs: fire), calendar.component(.hour, from: when) < quietEndHour else {
            return nil
        }
        return when
    }
}
