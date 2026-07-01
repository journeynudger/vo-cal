import Foundation
import Observation

/// Drives the weekly check-in: collect self-report → submit → recommendation → accept/keep.
/// Numbers the system already knows are loaded read-only; the form only asks what it can't
/// compute. Accepting an adjustment applies the new protocol version (mock today).
@MainActor
@Observable
final class CheckInViewModel {
    enum Phase: Equatable {
        case form
        case submitting
        case recommendation(CheckinRecommendation)
        case done
    }

    private(set) var phase: Phase = .form
    /// Week-so-far summary; nil when the service can't compute it (live path today) → card hidden.
    private(set) var computed: CheckinComputed?
    /// True only once an adjustment has been applied server-side — the proof the caller uses to
    /// decide whether to refresh Today. Never set on a failed accept (facts-first, AGENTS.md #4).
    private(set) var applied = false
    /// Surfaced to the user when submit/accept fails, instead of silently swallowing the error.
    var errorMessage: String?

    // Form fields.
    var weightText = ""
    var hunger: Int?
    var energy: Int?
    var adherence: Int?
    var notes = ""

    private let service: any CheckinService

    init(service: (any CheckinService)? = nil) {
        if let service {
            self.service = service
        } else if RuntimeMode.usesMockServices {
            self.service = MockCheckinService()
        } else {
            self.service = LiveCheckinService()
        }
    }

    func load() async {
        computed = await service.computed()
    }

    func submit() async {
        let inputs = CheckinInputs(
            weightKg: Double(weightText.trimmingCharacters(in: .whitespaces)),
            hunger: hunger,
            energy: energy,
            adherenceSelf: adherence,
            notes: notes.isEmpty ? nil : notes
        )
        phase = .submitting
        do {
            phase = .recommendation(try await service.submit(inputs))
        } catch {
            errorMessage = "Couldn't get your recommendation. Check your connection and try again."
            phase = .form
        }
    }

    func accept(_ recommendation: CheckinRecommendation) async {
        do {
            try await service.accept(recommendation)
            applied = true
            phase = .done
        } catch {
            // Don't claim the plan changed when the revise call failed — stay on the
            // recommendation so the user can retry or keep their current plan.
            errorMessage = "Couldn't update your plan. Please try again."
        }
    }

    func keep() {
        // Explicitly not applied — Today shouldn't refresh for "keep current plan".
        applied = false
        phase = .done
    }
}
