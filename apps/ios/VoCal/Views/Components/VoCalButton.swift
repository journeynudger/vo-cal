import SwiftUI

/// The button system, form-fitted from Beacon's BeaconButtonDesign toolkit: shape + color +
/// weight create hierarchy, labels are **never uppercase** (sentence case, Medium weight),
/// and every button shares one set of states (pressed / disabled / loading). Vo-Cal's design
/// keeps the capsule + black-gold palette rather than Beacon's orange rounded-rect.
///
/// Three roles (Beacon: primary / secondary / tertiary):
/// - `.primary`   — black `vcCTA` capsule, white label. The one main action per screen.
/// - `.secondary` — outlined `vcInk` capsule, ink label. Alternative / "keep current".
/// - `.tertiary`  — text link, muted label. Low-priority (skip, cancel, learn more).
enum VoCalButtonKind {
    case primary
    case secondary
    case tertiary
}

struct VoCalButton: View {
    let title: String
    var kind: VoCalButtonKind = .primary
    var isEnabled: Bool = true
    var isLoading: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                // Keep the label in the layout while loading so the button doesn't resize.
                label.opacity(isLoading ? 0 : 1)
                if isLoading {
                    VoCalLoader(size: 22, color: loaderColor)
                }
            }
            .frame(maxWidth: kind == .tertiary ? nil : .infinity)
            .frame(height: kind == .tertiary ? nil : 52)
            .background(background)
            .overlay(border)
            .contentShape(kind == .tertiary ? AnyShape(Rectangle()) : AnyShape(Capsule()))
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(!isEnabled || isLoading)
        .opacity(isEnabled ? 1 : 0.45)
    }

    private var label: some View {
        Text(title)
            .font(VoCalTheme.Fonts.buttonLabel)
            .foregroundStyle(foreground)
    }

    private var foreground: Color {
        switch kind {
        case .primary: return VoCalTheme.Colors.onCta
        case .secondary: return VoCalTheme.Colors.ink
        case .tertiary: return VoCalTheme.Colors.muted
        }
    }

    private var loaderColor: Color {
        kind == .primary ? VoCalTheme.Colors.onCta : VoCalTheme.Colors.gold
    }

    @ViewBuilder
    private var background: some View {
        switch kind {
        case .primary: Capsule().fill(VoCalTheme.Colors.cta)
        case .secondary: Capsule().fill(.clear)
        case .tertiary: Color.clear
        }
    }

    @ViewBuilder
    private var border: some View {
        if kind == .secondary {
            Capsule().strokeBorder(VoCalTheme.Colors.ink.opacity(0.25), lineWidth: 1.5)
        }
    }
}

/// Shared press feedback: a calm scale + opacity dip (Beacon: subtle, no color change). Used by
/// every Vo-Cal button so press feel is uniform.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

#Preview {
    VStack(spacing: VoCalTheme.Spacing.l) {
        VoCalButton(title: "Log meal") {}
        VoCalButton(title: "Keep current plan", kind: .secondary) {}
        VoCalButton(title: "Skip", kind: .tertiary) {}
        VoCalButton(title: "Saving…", isLoading: true) {}
        VoCalButton(title: "Disabled", isEnabled: false) {}
    }
    .padding(VoCalTheme.Spacing.xl)
    .background(VoCalTheme.Colors.background)
}
