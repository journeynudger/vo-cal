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
                + "different result - a small cut gets things moving again without changing anything else.",
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
        let dto = try await api.recommendRecalibration()
        let kind = RecommendationKind(rawValue: dto.kind) ?? .hold

        // When an adjustment is proposed, build a complete preview: the recalibrated fields come
        // from the recommendation; carbs/fat/produce/meals carry from the active protocol (they
        // don't move on a recalibration). Engine numbers only — the client invents nothing.
        var newTargets: ProtocolTargets?
        if let t = dto.targets, let current = try? await api.activeProtocol() {
            let c = current.targets
            newTargets = ProtocolTargets(
                protocolId: current.protocolId,
                version: c.version + 1,
                kcal: t.targetKcal,
                protein: t.proteinG,
                // Carry the current band into the preview; the regenerated protocol recomputes it
                // server-side. (A check-in moves the protein target only slightly.)
                proteinMin: c.proteinMin ?? 0,
                proteinMax: c.proteinMax ?? 0,
                carbs: c.carbs,
                fat: c.fat,
                fiber: t.fiberG,
                produceServings: c.produceServings,
                waterOz: t.waterOz,
                mealsPerDay: c.mealsPerDay,
                whys: c.whys
            )
        }
        return CheckinRecommendation(
            kind: kind,
            headline: dto.headline,
            why: dto.rationale,
            newTargets: newTargets,
            protocolId: dto.protocolId
        )
    }

    func accept(_ recommendation: CheckinRecommendation) async throws {
        // Apply the recalibration server-side (it re-derives + supersedes; never trusts the
        // client's preview numbers). No protocol id ⇒ nothing to revise.
        guard let protocolID = recommendation.protocolId else { return }
        _ = try await api.reviseProtocol(protocolID: protocolID)
    }
}
