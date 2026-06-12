import Foundation
import Testing
@testable import VoCalCore

@Suite("Parser contract Codable round-trips")
struct ParserContractTests {
    @Test func parsedMealRoundTrip() throws {
        let meal = ParsedMeal(
            mealType: .lunch,
            items: [
                ParsedItem(
                    name: "ground beef",
                    amount: 4,
                    unit: .oz,
                    state: .cooked,
                    fatRatio: "93/7",
                    brand: nil,
                    prepMethod: "pan-fried",
                    confidence: 0.96
                ),
                ParsedItem(name: "jasmine rice", amount: 200, unit: .g, state: .cooked, confidence: 0.98),
            ],
            missingDetails: []
        )
        let data = try VoCalJSON.encoder().encode(meal)
        let decoded = try VoCalJSON.decoder().decode(ParsedMeal.self, from: data)
        #expect(decoded == meal)
    }

    @Test func decodesCanonicalServerJSON() throws {
        // Snake_case payload exactly as docs/PARSER_CONTRACT.md specifies.
        let json = """
        {
          "meal_type": "dinner",
          "items": [
            {
              "name": "ground beef",
              "amount": 4,
              "unit": "oz",
              "state": "cooked",
              "fat_ratio": "93/7",
              "brand": null,
              "prep_method": null,
              "confidence": 0.95
            }
          ],
          "missing_details": [
            {
              "field": "items[0].fat_ratio",
              "importance": "high",
              "question": "What was the fat ratio of the beef?"
            }
          ]
        }
        """
        let meal = try VoCalJSON.decoder().decode(ParsedMeal.self, from: Data(json.utf8))
        #expect(meal.mealType == .dinner)
        #expect(meal.items.count == 1)
        #expect(meal.items[0].fatRatio == "93/7")
        #expect(meal.missingDetails[0].importance == .high)
    }

    @Test func toleratesUnknownFields() throws {
        // The server may add fields; shipped clients must not break.
        let json = """
        {
          "meal_type": "snack",
          "items": [],
          "missing_details": [],
          "added_in_v2": {"future": true}
        }
        """
        let meal = try VoCalJSON.decoder().decode(ParsedMeal.self, from: Data(json.utf8))
        #expect(meal.mealType == .snack)
    }

    @Test func nutrientProfileSums() {
        let a = NutrientProfile(kcal: 170, protein: 24, carbs: 0, fat: 8, fiber: 0)
        let b = NutrientProfile(kcal: 260, protein: 5, carbs: 56, fat: 1, fiber: 1.4)
        let total = a + b
        #expect(total.kcal == 430)
        #expect(total.protein == 29)
        #expect(total.fiber == 1.4)
    }

    @Test func parseResultWithQuestionRoundTrip() throws {
        let result = ParseResult(
            parseId: "parse_123",
            mealType: .dinner,
            items: [
                ResolvedItem(
                    item: ParsedItem(name: "burger patty", state: .cooked, confidence: 0.6),
                    macros: NutrientProfile(kcal: 230, protein: 19, carbs: 0, fat: 17, fiber: 0),
                    source: .dictionary,
                    grams: 113
                )
            ],
            totals: NutrientProfile(kcal: 230, protein: 19, carbs: 0, fat: 17, fiber: 0),
            mealConfidence: 0.6,
            question: MissingDetail(
                field: "items[0].fat_ratio",
                importance: .high,
                question: "What was the fat ratio of the beef?"
            )
        )
        let data = try VoCalJSON.encoder().encode(result)
        let decoded = try VoCalJSON.decoder().decode(ParseResult.self, from: data)
        #expect(decoded == result)
        #expect(decoded.question != nil)
    }

    @Test func protocolTargetsRoundTrip() throws {
        let targets = ProtocolTargets(
            protocolId: "proto_1",
            version: 1,
            kcal: 2400,
            protein: 180,
            carbs: 250,
            fat: 70,
            fiber: 34,
            mealsPerDay: 4,
            whys: ["protein": "You lift 4x/week, so protein sits at the high end."]
        )
        let data = try VoCalJSON.encoder().encode(targets)
        let decoded = try VoCalJSON.decoder().decode(ProtocolTargets.self, from: data)
        #expect(decoded == targets)
    }
}
