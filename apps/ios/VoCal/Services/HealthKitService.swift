import Foundation
import HealthKit

// Port provenance: Serein apps/ios/SereinApp/Sources/HealthDays.swift, reduced to one read.
// Serein reads ten types each morning and writes the day before into the journal; Vo-Cal reads
// today's active energy on demand and keeps nothing. Kept from Serein: the read-only request
// with nothing shared, the async statistics descriptor, and the rule that HealthKit never says
// whether reading was allowed. Not ported: the observer query, background delivery, the day
// summary and its offer schedule.

/// Apple Health, read only: today's active energy, for Today's burned figure next to what was
/// eaten (Phase U reverses decision 17 for this one number, on the phone only); and, since
/// decision 67, the body as a clock for the reminders: today's last workout and last night's
/// end move a scheduled fire later on the phone (`NudgeFireTiming`). Never a trigger: no nudge
/// exists because of a workout or a night (the spec's N7).
///
/// Never send these numbers anywhere: not to the API, not to telemetry, not to a log line
/// (AGENTS.md MUST-NOT 5, precise health values). The shell shows the number and forgets it;
/// the clock moves a local notification's time and is forgotten.
///
/// Off the capture path: nothing here runs at launch. The store is created on the first use of
/// `shared`, which only the priming step, Today, the reminders' plan, the check-in and Settings →
/// Notifications reach, so capture works with this file deleted (AGENTS.md capture-path
/// isolation).
@MainActor
@Observable
final class HealthKitService {
    static let shared = HealthKitService()

    static let askedKey = "vocal.health.asked"

    /// Whether the Health sheet has a read left to ask: the one fact HealthKit gives about
    /// reading. It says whether each read was ever put to the person and never whether it was
    /// allowed, so the app can know there is something to ask and never what was answered.
    enum ReadAccess: Sendable, Equatable {
        /// A read was never put to the person, so the sheet would show: one an update added after
        /// they answered (builds 30 and 31 asked for active energy alone; steps, workouts and
        /// sleep came after), or all four after the onboarding step's Not now.
        case unasked
        /// Every read has been answered, allowed or not. The sheet would not show again.
        case answered
    }

    private let store = HKHealthStore()
    private let defaults: UserDefaults

    /// The priming step has been answered, Connect or Not now. The shell shows the step only
    /// while this is false.
    private(set) var hasAsked: Bool
    /// The workout observer and what it calls, kept so the sheet's answer can start it again.
    @ObservationIgnored private var workoutObserver: (query: HKObserverQuery, onChange: @Sendable () -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hasAsked = defaults.bool(forKey: Self.askedKey)
    }

    /// False where the device has no Health. The simulator has Health, with no samples.
    var isAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    func markAsked() {
        hasAsked = true
        defaults.set(true, forKey: Self.askedKey)
    }

    /// Shows the system's Health sheet for active energy, steps, workouts and sleep, read only,
    /// nothing shared. iOS shows it only while one of them was never answered, and lists only
    /// those: with active energy answered as build 31 left it, the sheet offered sleep, steps and
    /// workouts alone (pinned simulator, iOS 26.5, 2026-10-22). Call it only from the person's
    /// own tap: the onboarding step, or the door on Settings → Notifications. True
    /// when the request completed; HealthKit never says whether reading was allowed, so true is
    /// not a grant, and a refusal later reads as an empty day. False when Health is unavailable
    /// or the request failed (a missing entitlement lands here).
    func requestAuthorization() async -> Bool {
        markAsked()
        guard isAvailable else {
            return false
        }
        do {
            try await Self.requestReadAccess(store: store)
            restartWorkoutObserver()
            return true
        } catch {
            return false
        }
    }

    /// Whether the sheet has a read left to ask, for the door on Settings → Notifications. Nil
    /// when Health is unavailable or HealthKit cannot say: no door either way, rather than one
    /// that might open onto no sheet.
    func readAccess() async -> ReadAccess? {
        guard isAvailable else {
            return nil
        }
        return Self.readAccess(from: await Self.requestStatus(store: store))
    }

    /// HealthKit's request status classified at the boundary, pure so the render tests pin it.
    static func readAccess(from status: HKAuthorizationRequestStatus) -> ReadAccess? {
        switch status {
        case .shouldRequest: .unasked
        case .unnecessary: .answered
        case .unknown: nil
        @unknown default: nil
        }
    }

    /// Today's active energy in kcal, from local midnight. Nil when Health is unavailable, the
    /// person has not been asked, reading was not allowed, or there are no samples yet (the
    /// simulator): HealthKit answers a refused read as an empty one, so nil covers all four and
    /// the shell simply leaves the figure off.
    func activeEnergyToday(now: Date = .now) async -> Double? {
        guard isAvailable, hasAsked else {
            return nil
        }
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else {
            return nil
        }
        return await Self.activeEnergySum(store: store, from: start, to: end)
    }

    /// What the phone knows of the body today, for the reminders' clock (decision 67): the end
    /// of today's last workout and the end of last night's sleep. Unknown when Health is
    /// unavailable, never asked, refused or empty, and an unknown clock moves nothing.
    func bodyClock(now: Date = .now) async -> NudgeFireTiming.BodyClock {
        guard isAvailable, hasAsked else {
            return .unknown
        }
        let calendar = Calendar.autoupdatingCurrent
        let startOfDay = calendar.startOfDay(for: now)
        let workoutEnd = await Self.lastWorkoutEnd(store: store, from: startOfDay, to: now)
        let sleep = await Self.lastSleep(store: store, from: startOfDay.addingTimeInterval(-12 * 3600), to: now)
        return NudgeFireTiming.BodyClock(lastWorkoutEnd: workoutEnd, sleepEnd: sleep.end, sleepDuration: sleep.duration)
    }

    /// The week's steps a day, for the check-in's movement line (the behavior-change spec's
    /// 6.12): shown beside the question the recommendation asks, never sent. Nil when Health is
    /// unavailable, never asked, refused or empty (the simulator).
    func weeklyStepsPerDay(now: Date = .now) async -> Int? {
        guard isAvailable, hasAsked else {
            return nil
        }
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)) ?? now
        guard let total = await Self.stepSum(store: store, from: start, to: now), total > 0 else {
            return nil
        }
        return Int((total / 7).rounded())
    }

    /// A workout saved to Health wakes the app briefly (background delivery), so the fire that
    /// waits for training can move the same hour. Started once, after the first plan, only when
    /// the person has been asked; the observer calls `onChange` on an arbitrary queue.
    func startObservingWorkouts(onChange: @escaping @Sendable () -> Void) {
        guard isAvailable, hasAsked, workoutObserver == nil else {
            return
        }
        workoutObserver = (Self.observeWorkouts(store: store, onChange: onChange), onChange)
    }

    /// An observer on a read never asked ends at once (HealthKit error 5, authorization not
    /// determined; probed on the pinned simulator, iOS 26.5, 2026-10-16), and an updater's first
    /// plan on this build starts it before they reach the door. Starting it again on the sheet's
    /// answer lets a workout saved later that day move the fire, not only after the next launch.
    /// Background delivery needs nothing: enabling it succeeded before the ask.
    private func restartWorkoutObserver() {
        guard let observer = workoutObserver else {
            return
        }
        store.stop(observer.query)
        workoutObserver = (Self.observeWorkouts(store: store, onChange: observer.onChange), observer.onChange)
    }

    // The HealthKit calls run nonisolated: the descriptor and the type sets never leave the
    // function that made them, and only Sendable values (the store, dates, a Double, a status)
    // cross.

    /// The four reads, the ones the usage string names, made fresh wherever they are used.
    nonisolated private static func readTypes() -> Set<HKObjectType> {
        [
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.stepCount),
            HKObjectType.workoutType(),
            HKCategoryType(.sleepAnalysis),
        ]
    }

    nonisolated private static func requestReadAccess(store: HKHealthStore) async throws {
        try await store.requestAuthorization(toShare: [], read: readTypes())
    }

    /// `.unknown` when HealthKit cannot say, which offers nothing.
    nonisolated private static func requestStatus(store: HKHealthStore) async -> HKAuthorizationRequestStatus {
        (try? await store.statusForAuthorizationRequest(toShare: [], read: readTypes())) ?? .unknown
    }

    nonisolated private static func lastWorkoutEnd(store: HKHealthStore, from start: Date, to end: Date) async -> Date? {
        let window = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(window)],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
            limit: 1
        )
        guard let workouts = try? await descriptor.result(for: store) else {
            return nil
        }
        return workouts.first?.endDate
    }

    /// The end of the latest asleep stretch in the window (last night's end, for the first hour
    /// of silence) and how long the night was (the asleep samples' total, for the short-night
    /// ceiling). A sample still open (asleep now) is not an end. Both nil when nothing is known.
    nonisolated private static func lastSleep(
        store: HKHealthStore, from start: Date, to end: Date
    ) async -> (end: Date?, duration: TimeInterval?) {
        let window = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: window)],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
            limit: 64
        )
        guard let samples = try? await descriptor.result(for: store) else {
            return (nil, nil)
        }
        let asleep = samples.filter { sample in
            guard let value = HKCategoryValueSleepAnalysis(rawValue: sample.value) else { return false }
            return HKCategoryValueSleepAnalysis.allAsleepValues.contains(value)
        }
        guard !asleep.isEmpty else {
            return (nil, nil)
        }
        let duration = asleep.reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }
        return (asleep.map(\.endDate).filter { $0 <= end }.max(), duration)
    }

    nonisolated private static func stepSum(store: HKHealthStore, from start: Date, to end: Date) async -> Double? {
        let window = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let descriptor = HKStatisticsQueryDescriptor(
            predicate: .quantitySample(type: HKQuantityType(.stepCount), predicate: window),
            options: .cumulativeSum
        )
        guard let statistics = try? await descriptor.result(for: store) else {
            return nil
        }
        return statistics.sumQuantity()?.doubleValue(for: .count())
    }

    nonisolated private static func observeWorkouts(
        store: HKHealthStore, onChange: @escaping @Sendable () -> Void
    ) -> HKObserverQuery {
        let query = HKObserverQuery(sampleType: HKObjectType.workoutType(), predicate: nil) { _, completion, _ in
            onChange()
            completion()
        }
        store.execute(query)
        store.enableBackgroundDelivery(for: HKObjectType.workoutType(), frequency: .immediate) { _, _ in }
        return query
    }

    nonisolated private static func activeEnergySum(store: HKHealthStore, from start: Date, to end: Date) async -> Double? {
        let window = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let descriptor = HKStatisticsQueryDescriptor(
            predicate: .quantitySample(type: HKQuantityType(.activeEnergyBurned), predicate: window),
            options: .cumulativeSum
        )
        guard let statistics = try? await descriptor.result(for: store) else {
            return nil
        }
        return statistics.sumQuantity()?.doubleValue(for: .kilocalorie())
    }
}
