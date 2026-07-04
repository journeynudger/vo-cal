import Foundation
import VoCalCore

/// The weekly check-in: due-state, submit-and-recommend, accept-a-revision. Mock on the sim
/// path drives the whole flow with zero network; the live path covers what the backend exposes
/// today (`GET /checkins/due`, `POST /checkins`). The recommendation + protocol-revise endpoints
/// are a pending backend addition (recommend.py exists but isn't wired to a route yet), so the
/// live recommendation is a neutral HOLD until then — flagged, not faked as an adjustment.
protocol CheckinService: Sendable {
    func isDue() async -> Bool
    /// The week-so-far summary card, or nil when it isn't known — the live path returns nil
    /// until the server surfaces computed adherence, so the UI hides the card rather than
    /// showing a fabricated "0 of 7 days".
    func computed() async -> CheckinComputed?
    func submit(_ inputs: CheckinInputs) async throws -> CheckinRecommendation
    /// Accept an adjustment → new active protocol version. Live: pending the revise endpoint.
    func accept(_ recommendation: CheckinRecommendation) async throws
}

struct MockCheckinService: CheckinService {
    var due = true

    func isDue() async -> Bool { due }

    func computed() async -> CheckinComputed? {
        CheckinComputed(
            loggedDays: 6, weekDays: 7, avgKcal: 2140,
            mealsLogged: 18, avgCertainty: 74,
            focusTip: "Next week, try adding a portion — \"a medium bowl,\" \"about two cups,\" \"one plate.\""
        )
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

    func computed() async -> CheckinComputed? {
        // GET /meals/summary re-scores the week's stored meals deterministically. Any failure
        // (or an empty week) → nil so the form hides the card entirely: never state a summary
        // we can't compute (facts-first, AGENTS.md #4).
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        guard let summary = try? await api.weeklySummary(date: formatter.string(from: Date())),
              summary.mealsLogged > 0
        else { return nil }
        return CheckinComputed(
            loggedDays: summary.daysLogged,
            weekDays: 7,
            avgKcal: summary.avgKcal ?? 0,
            mealsLogged: summary.mealsLogged,
            avgCertainty: summary.avgCertainty,
            // A focus tip only when the server judged the week sufficient — thin weeks show
            // the honest count line alone, never fabricated trends.
            focusTip: summary.sufficientData ? summary.focusTip : nil
        )
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
