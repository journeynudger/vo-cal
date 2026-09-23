import Foundation

/// The refine amount answer grammar, "<amount> <unit>" (docs/PARSER_CONTRACT.md, "Refine
/// answers"): composed here, parsed by the server's `clarify._AMOUNT_ANSWER_RE`
/// (`^([\d.]+)\s*([a-z]*)$`). A cross-language decision with one address on each side; the
/// test mirrors the server's regex so the two cannot drift apart unnoticed (restructure
/// Phase 4, decision 3).
public enum RefineAmountAnswer {
    public static func text(amount: Double, unit: FoodUnit?) -> String {
        let number = amount == amount.rounded() && amount.magnitude < 1e9
            ? String(Int(amount))
            : String(amount)
        guard let unit else { return number }
        return "\(number) \(unit.rawValue)"
    }
}
