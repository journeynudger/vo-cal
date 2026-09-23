import Foundation
import Testing
@testable import VoCalCore

@Suite("RefineAmountAnswer")
struct RefineAmountAnswerTests {
    /// The server's clarify._AMOUNT_ANSWER_RE, verbatim. A function, not a stored global:
    /// Regex is not Sendable and Swift 6 refuses a shared mutable global of it.
    private static func serverGrammar() -> Regex<(Substring, Substring, Substring)> {
        /^([\d.]+)\s*([a-z]*)$/
    }

    // BOUNDARY: the grammar is spelled once per side; this is the Swift side's proof that
    // what it composes is what the server parses (docs/PARSER_CONTRACT.md, Refine answers).
    @Test("Every composed answer matches the server's amount grammar")
    func matchesServerGrammar() throws {
        let cases: [(Double, FoodUnit?, String)] = [
            (4, .oz, "4 oz"),
            (1.5, .cup, "1.5 cup"),
            (200, .g, "200 g"),
            (2, nil, "2"),
            (0.25, .tsp, "0.25 tsp"),
        ]
        for (amount, unit, expected) in cases {
            let text = RefineAmountAnswer.text(amount: amount, unit: unit)
            #expect(text == expected)
            #expect(text.wholeMatch(of: Self.serverGrammar()) != nil)
        }
    }

    @Test("Every contract unit fits the grammar's unit token")
    func unitsFitTheGrammar() throws {
        for unit in FoodUnit.allCases {
            let text = RefineAmountAnswer.text(amount: 1, unit: unit)
            let match = try #require(text.wholeMatch(of: Self.serverGrammar()))
            #expect(String(match.2) == unit.rawValue)
        }
    }
}
