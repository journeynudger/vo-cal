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
/// `shared`, which only the priming step and Today's calories card reach, so capture works with
/// this file deleted (AGENTS.md capture-path isolation).
@MainActor
@Observable
final class HealthKitService {
    static let shared = HealthKitService()

    static let askedKey = "vocal.health.asked"

    private let store = HKHealthStore()
    private let defaults: UserDefaults

    /// The priming step has been answered, Connect or Not now. The shell shows the step only
    /// while this is false.
    private(set) var hasAsked: Bool
    @ObservationIgnored private var observingWorkouts = false

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

    /// Shows the system's Health sheet for active energy, workouts and sleep, read only, nothing
    /// shared. Call it
    /// only from the person's own tap. True when the request completed; HealthKit never says
    /// whether reading was allowed, so true is not a grant, and a refusal later reads as an
    /// empty day. False when Health is unavailable or the request failed (a missing
    /// entitlement lands here).
    func requestAuthorization() async -> Bool {
        markAsked()
        guard isAvailable else {
            return false
        }
        do {
            try await Self.requestReadAccess(store: store)
            return true
        } catch {
            return false
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
        let sleepEnd = await Self.lastSleepEnd(store: store, from: startOfDay.addingTimeInterval(-12 * 3600), to: now)
        return NudgeFireTiming.BodyClock(lastWorkoutEnd: workoutEnd, sleepEnd: sleepEnd)
    }

    /// A workout saved to Health wakes the app briefly (background delivery), so the fire that
    /// waits for training can move the same hour. Started once, after the first plan, only when
    /// the person has been asked; the observer calls `onChange` on an arbitrary queue.
    func startObservingWorkouts(onChange: @escaping @Sendable () -> Void) {
        guard isAvailable, hasAsked, !observingWorkouts else {
            return
        }
        observingWorkouts = true
        Self.observeWorkouts(store: store, onChange: onChange)
    }

    // The HealthKit calls run nonisolated: the descriptor and the type sets never leave the
    // function that made them, and only Sendable values (the store, dates, a Double) cross.

    nonisolated private static func requestReadAccess(store: HKHealthStore) async throws {
        try await store.requestAuthorization(
            toShare: [],
            read: [HKQuantityType(.activeEnergyBurned), HKObjectType.workoutType(), HKCategoryType(.sleepAnalysis)]
        )
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

    /// The end of the latest asleep stretch in the window: last night's end, for a morning
    /// fire. A sample still open (asleep now) is not an end.
    nonisolated private static func lastSleepEnd(store: HKHealthStore, from start: Date, to end: Date) async -> Date? {
        let window = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: window)],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
            limit: 64
        )
        guard let samples = try? await descriptor.result(for: store) else {
            return nil
        }
        let asleep = samples.filter { sample in
            guard let value = HKCategoryValueSleepAnalysis(rawValue: sample.value) else { return false }
            return HKCategoryValueSleepAnalysis.allAsleepValues.contains(value)
        }
        return asleep.map(\.endDate).filter { $0 <= end }.max()
    }

    nonisolated private static func observeWorkouts(store: HKHealthStore, onChange: @escaping @Sendable () -> Void) {
        let query = HKObserverQuery(sampleType: HKObjectType.workoutType(), predicate: nil) { _, completion, _ in
            onChange()
            completion()
        }
        store.execute(query)
        store.enableBackgroundDelivery(for: HKObjectType.workoutType(), frequency: .immediate) { _, _ in }
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
