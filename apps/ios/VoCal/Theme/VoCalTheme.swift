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

        // Soft-selection treatment (mirrors the web design system's chip / secondary-button
        // styling, user request 2026-06: "white pill, tiny gold inner shadow, unselected ones
        // get a gold border... it's softer"). Near-white fill + gold hairline; selected inputs
        // get a stronger gold border and a faint inner gold glow.
        /// Near-white fill for soft (secondary/selectable) surfaces.
        static let softFill = Color(hex: 0xFCFBF8)
        /// Resting gold hairline border for selectable/secondary surfaces.
        static let goldBorder = gold.opacity(0.5)
        /// Gold border for the selected/active state.
        static let goldBorderStrong = gold.opacity(0.9)
        /// Inner-glow tint painted into a selected surface's fill.
        static let goldInner = gold.opacity(0.30)

        // Semantic macro colors (kept for glanceability; gold stays brand-only).
        static let protein = Color(hex: 0xDB4F40)
        static let carbs = Color(hex: 0xDE9C3B)
        static let fats = Color(hex: 0x5B8DEF)

        // "Optimal" green for bounded-goal ranges (protein band): protein is NOT
        // more-is-merrier — too little and too much are both suboptimal — so the in-range
        // zone reads as a calm green, distinct from the protein-red macro accent.
        static let optimal = Color(hex: 0x4F9D69)

        // Nutrition-ring palette (user mapping 2026-06): protein = gold (brand), water = blue,
        // fiber = green (= optimal). A clean azure that reads as "water" on the light dashboard.
        static let water = Color(hex: 0x4A90D9)
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

    /// Role-based type scale (form-fitted from Beacon's typography toolkit): hierarchy comes
    /// from size · tracking · casing · color, not heavy weights or decorative fonts. SF Pro
    /// throughout (light mode, black/gold). Casing discipline: section/form labels are
    /// ALL CAPS + tracked (`Text.sectionHeader()` / `Fonts.formLabel`); titles, buttons, names,
    /// and body stay sentence case; the wordmark is its own role. Never uppercase a button.
    enum Fonts {
        /// Large stat numerals (calories left, meal kcal). 40–64pt semibold.
        static func numeral(_ size: CGFloat = 56) -> Font {
            .system(size: size, weight: .semibold, design: .default)
        }

        static let wordmark = Font.system(size: 20, weight: .semibold)
        static let screenTitle = Font.system(size: 21, weight: .medium)
        static let primaryLabel = Font.system(size: 17, weight: .medium)
        static let body = Font.system(size: 16, weight: .regular)
        static let secondaryLabel = Font.system(size: 14, weight: .regular)
        /// Interactive label — Medium weight, sentence case (Beacon button rule). 15–16pt.
        static let buttonLabel = Font.system(size: 16, weight: .medium)
        /// Overline / section header — pair with ALL CAPS + tracking via `Text.sectionHeader()`.
        static let sectionHeader = Font.system(size: 13, weight: .semibold)
        static let formLabel = Font.system(size: 13, weight: .regular)
        static let chipLabel = Font.system(size: 14, weight: .medium)
    }

    /// Letter-spacing constants for the ALL-CAPS roles (tracking does the work, not weight).
    enum Tracking {
        static let wide: CGFloat = 1.2
        static let wordmark: CGFloat = 1.6
    }
}

extension Text {
    /// ALL-CAPS, tracked, gold overline — the one section-header / eyebrow treatment, so the
    /// pattern that was repeated inline across Today / Protocol / Check-in / Intake lives in
    /// one place (Beacon SectionHeaderCaps, form-fit to our gold accent).
    func sectionHeader(_ color: Color = VoCalTheme.Colors.gold) -> some View {
        self.font(VoCalTheme.Fonts.sectionHeader)
            .textCase(.uppercase)
            .tracking(VoCalTheme.Tracking.wide)
            .foregroundStyle(color)
    }
}

extension View {
    /// Soft-selectable surface treatment, form-fit from the web design system's chip /
    /// secondary-button styling (user request 2026-06: softer inputs — gold hairline when
    /// resting, near-white fill + stronger gold border + faint inner gold glow when selected).
    /// Used by the onboarding choice rows, the yes/no toggle, and seen-chips so selection feel
    /// is uniform. The inner glow uses iOS 16+ `ShapeStyle.shadow(.inner:)` on the fill.
    func softSelectableCard(isSelected: Bool, radius: CGFloat = VoCalTheme.Radius.card) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return self
            .background(
                Group {
                    if isSelected {
                        shape.fill(
                            VoCalTheme.Colors.softFill.shadow(
                                .inner(color: VoCalTheme.Colors.goldInner, radius: 3, x: 0, y: 1)
                            )
                        )
                    } else {
                        shape.fill(VoCalTheme.Colors.card)
                    }
                }
            )
            .overlay(
                shape.strokeBorder(
                    isSelected ? VoCalTheme.Colors.goldBorderStrong : VoCalTheme.Colors.goldBorder,
                    lineWidth: 1.5
                )
            )
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
