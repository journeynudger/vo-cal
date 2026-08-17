import Foundation
import Testing
@testable import VoCalCore

/// The week graph, Today's card and the Progress page all colour and word a day
/// from this one classifier, so these tests pin the product's promises:
/// missing data is never a deficit, a day in progress is never scolded, and the
/// on-target band matches the app's existing "landed day" definition (90–105%).
struct WeekDayStatusTests {
    private func classify(
        _ consumed: Double,
        goal: Double = 2000,
        isPast: Bool = true,
        isToday: Bool = false,
        logged: Bool = true
    ) -> WeekDayStatus {
        WeekDayStatus.classify(
            consumed: consumed, goal: goal, isPast: isPast, isToday: isToday, logged: logged
        )
    }

    @Test("A finished day well below goal reads under")
    func underDay() {
        #expect(classify(1500) == .under)
        #expect(classify(1799) == .under) // just below the 90% edge
    }

    @Test("The on-target band is 90 to 105 percent of the day's goal")
    func onTargetBand() {
        #expect(classify(1800) == .onTarget) // exactly 90%
        #expect(classify(2000) == .onTarget)
        #expect(classify(2100) == .onTarget) // exactly 105%
        #expect(classify(2101) == .over)
    }

    @Test("Going past the band reads over")
    func overDay() {
        #expect(classify(2400) == .over)
    }

    @Test("An unlogged past day is notLogged, never under")
    func unloggedIsNotADeficit() {
        // Zero consumed with no logs is missing data, not a fasting day: painting
        // it as a deficit would invent a surplus the user never earned.
        #expect(classify(0, logged: false) == .notLogged)
    }

    @Test("A logged day that genuinely came in at zero is still scored")
    func loggedZeroIsScored() {
        #expect(classify(0, logged: true) == .under)
    }

    @Test("Today is never under, only in progress until it goes over")
    func todayIsNeverScolded() {
        #expect(classify(200, isPast: false, isToday: true) == .inProgress)
        #expect(classify(1990, isPast: false, isToday: true) == .inProgress)
        // Already past the band is a fact, not a prediction, so it does show.
        #expect(classify(2400, isPast: false, isToday: true) == .over)
    }

    @Test("Future days are upcoming regardless of the numbers")
    func futureDays() {
        #expect(classify(0, isPast: false, isToday: false) == .upcoming)
        #expect(classify(5000, isPast: false, isToday: false) == .upcoming)
    }

    @Test("A zero goal is never scored as over or under")
    func zeroGoalIsUnscored() {
        #expect(classify(1800, goal: 0) == .onTarget)
        #expect(classify(0, goal: 0, logged: false) == .notLogged)
        #expect(classify(1800, goal: 0, isPast: false, isToday: true) == .inProgress)
    }

    @Test("Only finished, scored days carry a delta figure")
    func scoredStatuses() {
        #expect(WeekDayStatus.under.isScored)
        #expect(WeekDayStatus.onTarget.isScored)
        #expect(WeekDayStatus.over.isScored)
        #expect(!WeekDayStatus.inProgress.isScored)
        #expect(!WeekDayStatus.notLogged.isScored)
        #expect(!WeekDayStatus.upcoming.isScored)
    }
}

/// The week's running total is stated in the product's plain language: no
/// "banked", no "absorbed" (user feedback 2026-08 — "just say X over or X
/// under, keeping it super simple").
struct WeekStandingTests {
    @Test("Positive carry reads under, negative reads over")
    func direction() {
        #expect(WeekStanding(carryKcal: 220).shortLabel == "220 under")
        #expect(WeekStanding(carryKcal: -480).shortLabel == "480 over")
    }

    @Test("Rounding noise reads as on plan, not a result")
    func tolerance() {
        #expect(WeekStanding(carryKcal: 0).isOnPlan)
        #expect(WeekStanding(carryKcal: 24).shortLabel == "on plan")
        #expect(WeekStanding(carryKcal: -24).shortLabel == "on plan")
        #expect(WeekStanding(carryKcal: 25).isUnder)
        #expect(WeekStanding(carryKcal: -25).isOver)
    }

    @Test("The sentence form never uses jargon")
    func sentenceCopy() {
        #expect(WeekStanding(carryKcal: -480).sentence == "480 calories over so far this week")
        #expect(WeekStanding(carryKcal: 300).sentence == "300 calories under so far this week")
        #expect(WeekStanding(carryKcal: 5).sentence == "On plan so far this week")
        for carry in [-900.0, -30, 0, 30, 900] {
            let sentence = WeekStanding(carryKcal: carry).sentence
            #expect(!sentence.contains("absorb"))
            #expect(!sentence.contains("bank"))
        }
    }
}
