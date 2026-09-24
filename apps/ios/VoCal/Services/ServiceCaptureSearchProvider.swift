import Foundation

/// The capture bar's search, backed by the meal capture service (GET /meals/search live,
/// canned hits on the sim). One provider for both modes so the bar never knows which.
struct ServiceCaptureSearchProvider: CaptureSearchProvider {
    let service: any MealCaptureService

    init(service: (any MealCaptureService)? = nil) {
        if let service {
            self.service = service
        } else if RuntimeMode.usesMockServices {
            self.service = MockMealCaptureService()
        } else {
            self.service = LiveMealCaptureService(
                api: APIClient(),
                audioReader: VoiceCaptureCoordinator.shared,
                uploader: CaptureUploadWorker.shared,
                deviceName: nil
            )
        }
    }

    func search(_ query: String) async throws -> [CaptureSearchHit] {
        try await service.searchLogged(query: query).map { hit in
            CaptureSearchHit(
                id: hit.id,
                kind: Self.kind(hit.kind),
                name: hit.name,
                kcal: hit.kcal,
                subtitle: Self.subtitle(hit)
            )
        }
    }

    private static func kind(_ raw: String) -> CaptureSearchHit.Kind {
        switch raw {
        case "usual": .usual
        case "personal_food": .personalFood
        default: .meal
        }
    }

    /// "Logged 6 times" or "One of your foods": what the hit is, in a few words.
    private static func subtitle(_ hit: SearchHit) -> String? {
        switch hit.kind {
        case "personal_food": return "One of your foods"
        case "usual": return "A usual"
        default: return hit.times > 1 ? "Logged \(hit.times) times" : nil
        }
    }
}
