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
        /// Secondary text that passes WCAG AA (4.5:1): the ink at 65 percent reads 5.1:1 or
        /// better on the background, the card and the gold tint, where `muted` reads 3.1 to
        /// 3.3:1 and Xcode's audit fails it (item 13, docs/restructure/05-questions.md).
        /// Derived like `goldBorder`, so no frozen value moves. A line a person reads takes
        /// this one; `muted` stays for icons, chevrons and inactive states.
        static let secondaryInk = ink.opacity(0.65)
        /// Brand accent: highlighted numerals, active states, confidence.
        static let gold = Color(hex: 0xC4A35A)
        /// Primary CTA fill (black pill).
        static let cta = Color(hex: 0x111111)
        /// Text/icon on CTA fills.
        static let onCta = Color.white
        /// Elevated white card surface (`vcWhite` in docs/DESIGN.md) — same literal value as
        /// `onCta`, named separately because its role here is a card fill, not CTA foreground.
        static let white = Color.white

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

        // "Optimal" green — the ONE positive-status green: bounded-goal ranges (protein
        // band), completion states (stat cards), and weekly-bar "goal met" (decision #45).
        // Protein is NOT more-is-merrier — too little and too much are both suboptimal —
        // so the in-range zone reads as a calm green, distinct from the protein-red macro.
        static let optimal = Color(hex: 0x4F9D69)

        // Nutrition-ring palette (user mapping 2026-06): protein = gold (brand), water = blue,
        // fiber = green (= optimal). A clean azure that reads as "water" on the light dashboard.
        static let water = Color(hex: 0x4A90D9)

        // The ONE non-macro red: weekly-bar overage (decision #45), mid-capture escalation,
        // and destructive actions (delete account). Deliberately NOT the protein red — macro
        // colors are semantic and frozen (DESIGN.md). Consolidated 2026-08-19: absorbed the
        // near-duplicate `danger` (#B03A2E) so status and destructive share one red.
        static let alert = Color(hex: 0xB5443A)
    }

    // MARK: - Liquid Glass (iOS 26 chrome)

    /// Tokens for the floating Liquid-Glass chrome (bottom menu, action buttons). The rim is the
    /// load-bearing token: `.glassEffect(.regular)` alone on the near-white background (#FAF9F6)
    /// reads as a flat bar — the bright hairline rim + soft lift are what make a surface read as
    /// glass on a light theme (user report 2026-07: "it doesn't look like a real liquid-glass
    /// menu"). Mirrors Serein's shipped bottom-bar recipe, form-fit to the light/gold palette.
    enum Glass {
        /// Frosted brightening tint so `.regular` glass separates from the cream background.
        static let barTint = Color.white.opacity(0.30)
        /// Bright hairline rim — the glass edge highlight that reads as "glass".
        static let rim = Color.white.opacity(0.6)
        /// Soft drop shadow lifting glass chrome off the scrolling content.
        static let lift = Color.black.opacity(0.12)
        /// Solid capsule fill when Reduce Transparency is on (no glass); on-brand card tone.
        static let reduceTransparencyFill = Color(hex: 0xF1EEE7)
    }

    // MARK: - Radii

    enum Radius {
        static let card: CGFloat = 24
        /// Rows and small tiles (a logged meal, a micro tile): 24 reads as a pill on a 68 pt
        /// row, 16 reads as a chip; 20 is the row (Rams pass, 2026-09-25).
        static let row: CGFloat = 20
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

        /// A role of the ramp that follows Dynamic Type, set with `View.scaledFont(_:)`. At the
        /// default text size it is its fixed token above exactly (same size and weight, so a
        /// render at the default size does not move); at every other size it scales along its
        /// text style's curve. The fixed tokens stay fixed until item 12 in
        /// docs/restructure/05-questions.md is decided; a view that adopts a role scales now.
        struct Scaled {
            let size: CGFloat
            let weight: Font.Weight
            let textStyle: Font.TextStyle

            static let primaryLabel = Scaled(size: 17, weight: .medium, textStyle: .body)
            static let secondaryLabel = Scaled(size: 14, weight: .regular, textStyle: .subheadline)
            static let formLabel = Scaled(size: 13, weight: .regular, textStyle: .footnote)
            static let sectionHeader = Scaled(size: 13, weight: .semibold, textStyle: .footnote)

            /// The role in another weight, the way `Font.weight(_:)` reads on a fixed token.
            func weight(_ weight: Font.Weight) -> Scaled {
                Scaled(size: size, weight: weight, textStyle: textStyle)
            }
        }
    }

    /// Letter-spacing constants for the ALL-CAPS roles (tracking does the work, not weight).
    enum Tracking {
        static let wide: CGFloat = 1.2
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

    /// The same overline at the person's text size (`Fonts.Scaled.sectionHeader`). Main actor,
    /// like `scaledFont`: a `View` extension's methods carry the protocol's isolation.
    @MainActor
    func scaledSectionHeader(_ color: Color = VoCalTheme.Colors.gold) -> some View {
        self.tracking(VoCalTheme.Tracking.wide)
            .textCase(.uppercase)
            .scaledFont(.sectionHeader)
            .foregroundStyle(color)
    }
}

extension View {
    /// Sets a Dynamic Type role (`VoCalTheme.Fonts.Scaled`) as the font of this view's text:
    /// the fixed token's face at the default text size, the person's size everywhere else.
    func scaledFont(_ role: VoCalTheme.Fonts.Scaled) -> some View {
        modifier(ScaledFontModifier(role: role))
    }
}

/// `@ScaledMetric` reads the environment's Dynamic Type size, so the role's size resolves in a
/// view. Xcode's audit counts a label as supporting Dynamic Type once its size moves with the
/// setting; a fixed `Font.system(size:)` never does (checked with `bin/ios-ui-audit`, 2026-10-13).
private struct ScaledFontModifier: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight

    init(role: VoCalTheme.Fonts.Scaled) {
        _size = ScaledMetric(wrappedValue: role.size, relativeTo: role.textStyle)
        weight = role.weight
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight))
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
