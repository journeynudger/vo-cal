import SwiftUI

/// Single source of design tokens. Views read from here only — no inline hex
/// anywhere else (docs/DESIGN.md). Black/gold system on the Cal AI reference layout.
enum VoCalTheme {
    // MARK: - Colors

    enum Colors {
        /// Warm off-white screen background.
        static let background = Color(hex: 0xFAF9F6)
        /// Card surface.
        static let card = Color(hex: 0xF4F2EE)
        /// Primary text.
        static let ink = Color(hex: 0x1A1A1A)
        /// Secondary text.
        static let muted = Color(hex: 0x8A8A8E)
        /// Brand accent: highlighted numerals, active states, confidence.
        static let gold = Color(hex: 0xC4A35A)
        /// Primary CTA fill (black pill).
        static let cta = Color(hex: 0x111111)
        /// Text/icon on CTA fills.
        static let onCta = Color.white

        // Semantic macro colors (kept for glanceability; gold stays brand-only).
        static let protein = Color(hex: 0xDB4F40)
        static let carbs = Color(hex: 0xDE9C3B)
        static let fats = Color(hex: 0x5B8DEF)
    }

    // MARK: - Radii

    enum Radius {
        static let card: CGFloat = 24
        static let chip: CGFloat = 16
    }

    // MARK: - Spacing

    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // MARK: - Typography

    enum Fonts {
        /// Large stat numerals (calories left, meal kcal). 40–64pt semibold.
        static func numeral(_ size: CGFloat = 56) -> Font {
            .system(size: size, weight: .semibold, design: .default)
        }

        static let screenTitle = Font.system(size: 21, weight: .medium)
        static let primaryLabel = Font.system(size: 17, weight: .medium)
        static let body = Font.system(size: 16, weight: .regular)
        static let secondaryLabel = Font.system(size: 14, weight: .regular)
        static let formLabel = Font.system(size: 13, weight: .regular)
        static let chipLabel = Font.system(size: 14, weight: .medium)
    }
}

extension Color {
    /// Token-table hex initializer. Used by VoCalTheme only.
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }
}
