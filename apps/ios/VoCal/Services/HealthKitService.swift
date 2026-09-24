import Foundation
import HealthKit

// Port provenance: Serein apps/ios/SereinApp/Sources/HealthDays.swift, reduced to one read.
// Serein reads ten types each morning and writes the day before into the journal; Vo-Cal reads
// today's active energy on demand and keeps nothing. Kept from Serein: the read-only request
// with nothing shared, the async statistics descriptor, and the rule that HealthKit never says
// whether reading was allowed. Not ported: the observer query, background delivery, the day
// summary and its offer schedule.

/// Apple Health, read only: today's active energy, for Today's burned figure next to what was
/// eaten (Phase U reverses decision 17 for this one number, on the phone only).
///
/// Never send these numbers anywhere: not to the API, not to telemetry, not to a log line
/// (AGENTS.md MUST-NOT 5, precise health values). The shell shows the number and forgets it.
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

    /// Shows the system's Health sheet for active energy, read only, nothing shared. Call it
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

    // The HealthKit calls run nonisolated: the descriptor and the type sets never leave the
    // function that made them, and only Sendable values (the store, dates, a Double) cross.

    nonisolated private static func requestReadAccess(store: HKHealthStore) async throws {
        try await store.requestAuthorization(toShare: [], read: [HKQuantityType(.activeEnergyBurned)])
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
