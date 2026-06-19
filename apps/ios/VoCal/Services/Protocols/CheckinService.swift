import Foundation
import VoCalCore

/// The weekly check-in: due-state, submit-and-recommend, accept-a-revision. Mock on the sim
/// path drives the whole flow with zero network; the live path covers what the backend exposes
/// today (`GET /checkins/due`, `POST /checkins`). The recommendation + protocol-revise endpoints
/// are a pending backend addition (recommend.py exists but isn't wired to a route yet), so the
/// live recommendation is a neutral HOLD until then — flagged, not faked as an adjustment.
protocol CheckinService: Sendable {
    func isDue() async -> Bool
    func computed() async -> CheckinComputed
    func submit(_ inputs: CheckinInputs) async throws -> CheckinRecommendation
    /// Accept an adjustment → new active protocol version. Live: pending the revise endpoint.
    func accept(_ recommendation: CheckinRecommendation) async throws
}

struct MockCheckinService: CheckinService {
    var due = true

    func isDue() async -> Bool { due }

    func computed() async -> CheckinComputed {
        CheckinComputed(loggedDays: 6, weekDays: 7, avgKcal: 2140)
    }

    func submit(_ inputs: CheckinInputs) async throws -> CheckinRecommendation {
        try? await Task.sleep(for: .milliseconds(700))
        // Representative case: a high-adherence stall → trim 150 kcal (rail-bounded), with the
        // new targets carried so Accept can flip Today to v2.
        var next = ProtocolTargets.personaFixture
        next.version = 2
        next.kcal -= 150
        next.protocolId = "mock-protocol-v2"
        return CheckinRecommendation(
            kind: .reduceAllocation,
            headline: "Trim 150 calories",
            why: "You logged 6 of 7 days and stayed on target, but the scale held. Same effort, "
                + "different result — a small cut gets things moving again without changing anything else.",
            newTargets: next
        )
    }

    func accept(_ recommendation: CheckinRecommendation) async throws {
        try? await Task.sleep(for: .milliseconds(300))
    }
}

struct LiveCheckinService: CheckinService {
    let api: APIClient
    init(api: APIClient = APIClient()) { self.api = api }

    func isDue() async -> Bool {
        (try? await api.checkinDue().due) ?? false
    }

    func computed() async -> CheckinComputed {
        // Server attaches computed adherence to the check-in; until that field is surfaced,
        // show a neutral placeholder rather than guess.
        CheckinComputed(loggedDays: 0, weekDays: 7, avgKcal: 0)
    }

    func submit(_ inputs: CheckinInputs) async throws -> CheckinRecommendation {
        _ = try await api.submitCheckin(inputs)
        // The recommendation route isn't wired server-side yet (recommend.py pending a router);
        // return a neutral HOLD so the UI never invents an adjustment the engine didn't make.
        return CheckinRecommendation(
            kind: .hold,
            headline: "Logged — keep going",
            why: "Your check-in is saved. We'll surface a recommendation here once the engine "
                + "endpoint is live.",
            newTargets: nil
        )
    }

    func accept(_ recommendation: CheckinRecommendation) async throws {
        // Protocol-revise endpoint pending (G1 step 2). No-op until then.
    }
}
