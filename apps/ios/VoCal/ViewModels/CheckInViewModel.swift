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
    private(set) var computed = CheckinComputed(loggedDays: 0, weekDays: 7, avgKcal: 0)

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
            phase = .form
        }
    }

    func accept(_ recommendation: CheckinRecommendation) async {
        try? await service.accept(recommendation)
        phase = .done
    }

    func keep() {
        phase = .done
    }
}
