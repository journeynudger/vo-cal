import Foundation
import VoCalCore

/// Finds a packaged food from the number on its box. The server owns the lookup (it prices
/// from its own foods first, then a public product database); the app sends the digits and
/// draws what comes back. A protocol so the scanner flow runs on the simulator with no
/// backend, which has no camera either.
protocol BarcodeService: Sendable {
    func lookup(code: String) async throws -> BarcodeFood
}

/// Why a lookup found nothing. Anything else (the network, a server error) is thrown as it
/// came, so the caller can tell "no such food" from "could not ask".
enum BarcodeLookupError: Error, Equatable {
    /// The server knows no food by this number (404).
    case notFound
    /// The number is not a barcode the server can look up (422, or not digits at all).
    case invalidCode
}

struct LiveBarcodeService: BarcodeService {
    let api: any APIClientProtocol

    func lookup(code: String) async throws -> BarcodeFood {
        // Digits only, checked before the code becomes part of a URL path.
        guard let code = BarcodeCode.normalized(code) else { throw BarcodeLookupError.invalidCode }
        do {
            return try await api.barcodeFood(code: code)
        } catch let error as APIError {
            if case let .status(status, _) = error {
                switch status {
                case 404: throw BarcodeLookupError.notFound
                case 422: throw BarcodeLookupError.invalidCode
                default: break
                }
            }
            throw error
        }
    }
}

/// No backend on the mock path: three canned products (a bar, a zero-calorie can, a
/// chocolate), so the scanner's type-a-number and sample-barcode doors reach the sheet on
/// the simulator. Any other number is "not found" after a short wait, the way the server
/// answers when its lookup comes up empty.
actor MockBarcodeService: BarcodeService {
    static let shared = MockBarcodeService()

    /// The oat bar's number: what the scanner's sample button sends.
    static let sampleCode = "5000000012345"

    static let oatBar = BarcodeFood(
        barcode: sampleCode,
        name: "Oat & Almond Bar",
        brand: "Bite Best",
        perServing: NutrientProfile(kcal: 210, protein: 10, carbs: 26, fat: 8, fiber: 5),
        servingGrams: 50,
        servingDescription: "1 bar",
        per100g: NutrientProfile(kcal: 420, protein: 20, carbs: 52, fat: 16, fiber: 10),
        source: "mock"
    )

    static let dietCola = BarcodeFood(
        barcode: "0049000028911",
        name: "Diet Cola",
        brand: "Classic",
        perServing: NutrientProfile(kcal: 0, protein: 0, carbs: 0, fat: 0, fiber: 0),
        servingGrams: nil,
        servingDescription: "1 can (355 ml)",
        per100g: nil,
        source: "mock"
    )

    static let darkChocolate = BarcodeFood(
        barcode: "7622300441937",
        name: "Dark Chocolate 85%",
        brand: "Lindt",
        perServing: NutrientProfile(kcal: 230, protein: 3, carbs: 15, fat: 19, fiber: 4),
        servingGrams: 40,
        servingDescription: "4 squares (40 g)",
        per100g: NutrientProfile(kcal: 575, protein: 7.5, carbs: 37.5, fat: 47.5, fiber: 10),
        source: "mock"
    )

    private static let foods: [String: BarcodeFood] = {
        let all = [oatBar, dietCola, darkChocolate]
        return Dictionary(uniqueKeysWithValues: all.map { ($0.barcode, $0) })
    }()

    func lookup(code: String) async throws -> BarcodeFood {
        guard let code = BarcodeCode.normalized(code) else { throw BarcodeLookupError.invalidCode }
        if let food = Self.foods[code] { return food }
        try await Task.sleep(for: .milliseconds(400))
        throw BarcodeLookupError.notFound
    }
}
