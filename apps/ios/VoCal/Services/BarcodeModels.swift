import Foundation
import VoCalCore

// Swift mirror of `GET /foods/barcode/{code}`: a packaged food found by the number on its
// box. Decoded through VoCalJSON (convertFromSnakeCase), so the Swift names are camelCase.
// Decode rule (AGENTS.md): only what the sheet cannot draw without is required (barcode,
// name, per_serving); everything else defaults, so a server that omits a field never turns
// a found food into a failed lookup.

/// A packaged food the server resolved from a barcode. Numbers are the server's, per
/// serving; the phone never sums or converts them (the sheet multiplies for display only).
struct BarcodeFood: Decodable, Sendable, Equatable {
    let barcode: String
    let name: String
    let brand: String?
    let perServing: NutrientProfile
    let servingGrams: Double?
    let servingDescription: String
    let per100g: NutrientProfile?
    let source: String

    init(
        barcode: String,
        name: String,
        brand: String? = nil,
        perServing: NutrientProfile,
        servingGrams: Double? = nil,
        servingDescription: String = BarcodeFood.defaultServingDescription,
        per100g: NutrientProfile? = nil,
        source: String = BarcodeFood.defaultSource
    ) {
        self.barcode = barcode
        self.name = name
        self.brand = brand
        self.perServing = perServing
        self.servingGrams = servingGrams
        self.servingDescription = servingDescription
        self.per100g = per100g
        self.source = source
    }

    static let defaultServingDescription = "1 serving"
    static let defaultSource = "unknown"

    /// "Bite Best Oat & Almond Bar": the brand in front of the name, unless the name already
    /// begins with it ("Lindt Excellence" from brand "Lindt" stays as it is).
    var displayName: String {
        let name = self.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let brand = brand?.trimmingCharacters(in: .whitespacesAndNewlines), !brand.isEmpty else {
            return name
        }
        if let lead = name.range(of: brand, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) {
            // "Lindt Excellence" already leads with "Lindt"; "Lindtner Bar" does not.
            let continuesWord = name[lead.upperBound...].first.map { $0.isLetter || $0.isNumber } ?? false
            if !continuesWord { return name }
        }
        return name.isEmpty ? brand : "\(brand) \(name)"
    }

    /// "1 bar (50 g)": the serving as the label words it, plus the grams when the server knows
    /// them and the label did not already say them. No calories: the sheet draws those
    /// itself, and only when the person's mode prints numbers.
    var servingText: String {
        var serving = servingDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if serving.isEmpty { serving = Self.defaultServingDescription }
        if let grams = servingGrams, grams > 0 {
            let printed = Self.gramsText(grams)
            let alreadySaid = serving.range(of: "\(printed) g", options: .caseInsensitive) != nil
                || serving.range(of: "\(printed)g", options: .caseInsensitive) != nil
            if !alreadySaid { serving += " (\(printed) g)" }
        }
        return serving
    }

    /// "1 bar (50 g) · 210 cal": the serving, then the server's calories rounded to a whole
    /// number.
    var servingLine: String {
        "\(servingText) · \(Self.wholeNumber(perServing.kcal)) cal"
    }

    /// A rounded whole number that cannot trap: a non-finite or absurd value from a bad
    /// payload prints as a clamped number rather than crashing `Int(_:)`.
    static func wholeNumber(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return Int(min(max(value, -1_000_000), 1_000_000).rounded())
    }

    private static func gramsText(_ grams: Double) -> String {
        grams.rounded() == grams ? String(Int(grams)) : String(format: "%.1f", grams)
    }
}

// MARK: - Tolerant decode

extension BarcodeFood {
    /// `per_100g` is the one key convertFromSnakeCase does not turn into `per100g`: it
    /// capitalizes the segment after the underscore, so the wire key arrives as `per100G`
    /// (checked against the Foundation decoder, 2026-11-06). The explicit raw value says so
    /// where the next reader will look; renaming the case to match the property would
    /// silently decode every food without its per-100 g profile.
    private enum CodingKeys: String, CodingKey {
        case barcode
        case name
        case brand
        case perServing
        case servingGrams
        case servingDescription
        case per100g = "per100G"
        case source
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            barcode: try container.decode(String.self, forKey: .barcode),
            name: try container.decode(String.self, forKey: .name),
            brand: container.lenient(String.self, forKey: .brand),
            perServing: try container.decode(TolerantNutrients.self, forKey: .perServing).profile,
            servingGrams: container.lenient(Double.self, forKey: .servingGrams),
            servingDescription: container.lenient(String.self, forKey: .servingDescription)
                ?? Self.defaultServingDescription,
            per100g: container.lenient(TolerantNutrients.self, forKey: .per100g)?.profile,
            source: container.lenient(String.self, forKey: .source) ?? Self.defaultSource
        )
    }
}

private extension KeyedDecodingContainer {
    /// A value that is absent, null or the wrong type reads as nil: these fields decorate a
    /// found food, and none of them is worth failing the lookup over.
    func lenient<Value: Decodable>(_ type: Value.Type, forKey key: Key) -> Value? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}

/// A nutrient block whose keys may each be missing (fiber is the usual one): a missing
/// macro reads as zero instead of failing the whole food. The block itself must be an object.
private struct TolerantNutrients: Decodable {
    let profile: NutrientProfile

    private enum CodingKeys: String, CodingKey {
        case kcal, protein, carbs, fat, fiber
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profile = NutrientProfile(
            kcal: try container.decodeIfPresent(Double.self, forKey: .kcal) ?? 0,
            protein: try container.decodeIfPresent(Double.self, forKey: .protein) ?? 0,
            carbs: try container.decodeIfPresent(Double.self, forKey: .carbs) ?? 0,
            fat: try container.decodeIfPresent(Double.self, forKey: .fat) ?? 0,
            fiber: try container.decodeIfPresent(Double.self, forKey: .fiber) ?? 0
        )
    }
}

// MARK: - The number on the box

/// A scanned or typed barcode, checked once at the edge so no service ever builds a URL from
/// free text (`/foods/barcode/../meals` is a different route). Digits only: the symbologies
/// the scanner reads for food (EAN-13, EAN-8, UPC-E) are all digits, and a QR code or a
/// Code 128 with letters in it is not a food barcode the server could look up.
enum BarcodeCode {
    static let maxLength = 32

    /// The code trimmed of whitespace, or nil when it is empty, too long or not all ASCII
    /// digits.
    static func normalized(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxLength,
              trimmed.allSatisfy({ $0.isASCII && $0.isNumber })
        else { return nil }
        return trimmed
    }
}


extension BarcodeFood: Identifiable {
    /// The code is the identity: one sheet per scan.
    var id: String { barcode }
}
