import Foundation

/// The body as a clock for the reminders, on the phone (decision 67, the spec's 6.5; decision 69,
/// the behavior-change spec's 6.12, Serein's pattern). The server marks which fires may move for
/// training (`NudgeContext`); this moves them from what Apple Health knows here and nowhere else:
/// a fire for after training waits forty-five minutes past today's last workout; every fire
/// waits out the first hour after the night's end (Serein's sacred silence: the morning belongs
/// to the person before the system); after a short night only the essential fires speak (the
/// designer's protective ceiling). A fire is only ever moved later, never earlier, and never into
/// the night: pushed past quiet hours it is dropped, not delayed. Pure, so the render tests pin
/// it; the Health reads live in `HealthKitService`.
///
/// Never send these dates anywhere (decision 52; AGENTS.md MUST-NOT 5): they move a local
/// notification's time and are forgotten.
enum NudgeFireTiming {
    static let afterWorkout: TimeInterval = 45 * 60
    /// The first hour after waking is silent for every fire; the engine's `after_wake` marker
    /// (a thirty-minute wait on morning fires) sits inside it and stays as the additive hint.
    static let afterWake: TimeInterval = 60 * 60
    /// The engine's quiet hours end (nudges/engine.py QUIET_END_HOUR); a moved fire respects it too.
    static let quietEndHour = 21
    /// Under this much sleep last night, the coaching fires are held and the essentials kept.
    static let shortNight: TimeInterval = 6 * 3600

    /// What the phone knows of the body today. Nil means unknown (no watch, no permission, no
    /// sample), and an unknown clock moves nothing and holds nothing.
    struct BodyClock: Sendable, Equatable {
        var lastWorkoutEnd: Date?
        var sleepEnd: Date?
        var sleepDuration: TimeInterval?

        static let unknown = BodyClock()

        /// A night under six hours, by Health's asleep samples. Unknown is not short.
        var isShortNight: Bool {
            guard let sleepDuration else { return false }
            return sleepDuration < NudgeFireTiming.shortNight
        }
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
        if let sleepEnd = clock.sleepEnd, calendar.isDate(sleepEnd, inSameDayAs: fire) {
            when = max(when, sleepEnd.addingTimeInterval(afterWake))
        }
        guard when > now else { return nil }
        guard calendar.isDate(when, inSameDayAs: fire), calendar.component(.hour, from: when) < quietEndHour else {
            return nil
        }
        return when
    }

    /// Serein's protective ceiling (the behavior-change spec's 6.12): after a short night the
    /// coaching waits and the essentials (a day gone quiet, the evening's unlogged meal) keep
    /// their place. The engine's plan is unchanged; the phone applies the designer's ceiling.
    static func holds(_ card: NudgeCard, clock: BodyClock) -> Bool {
        !card.essential && clock.isShortNight
    }
}
