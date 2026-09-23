import Foundation

/// The one bar for "reads as confirmed": at or above it an item or a meal needs no attention,
/// below it the surface flags a quick edit. Two views spelled it separately (0.93 twice, 0.94
/// in the mock fixtures) and could drift apart; one address (restructure Phase 4, decision 1;
/// TIDY-ADDR-001 keeps the literal out of the app).
public enum ConfidenceBar {
    public static let confirmed = 0.93
}
