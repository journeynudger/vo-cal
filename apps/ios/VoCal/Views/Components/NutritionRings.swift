import SwiftUI

// Saved for later (decision 2026-06): the "activity wheel". Built for the Today screen, then
// pulled back out so the dashboard could return to the green-card layout — but kept here as a
// standalone, reusable component for a planned Home-Screen WIDGET and/or a future "Activity"
// view. Theme-INDEPENDENT on purpose: every ring/label carries its own color, so it drops into
// a widget extension target (which won't have the app's VoCalTheme) with zero changes.
//
// App color mapping (for when you wire it up): Protein = gold, Water = blue, Fiber = green.

/// Concentric "activity rings" (Apple-style), tinted by the caller. Each ring fills 0→fraction
/// with a smooth, slightly-staggered animation on appear (outer first); overshoot stays a full
/// ring. `rings` is ordered outer→inner. Set `animated: false` for static contexts (widgets).
struct NutritionRings: View {
    struct Ring {
        let fraction: Double
        let color: Color

        init(fraction: Double, color: Color) {
            self.fraction = fraction
            self.color = color
        }
    }

    var rings: [Ring]               // outer → inner
    var lineWidth: CGFloat = 12
    var gap: CGFloat = 6
    var trackOpacity: Double = 0.18
    var animated: Bool = true

    @State private var appeared = false

    var body: some View {
        ZStack {
            ForEach(Array(rings.enumerated()), id: \.offset) { index, ring in
                // Inset each successive ring inward by one ring-width + gap; the base half-line
                // inset keeps the outermost stroke inside the frame.
                let inset = lineWidth / 2 + CGFloat(index) * (lineWidth + gap)
                let progress = min(1, max(0, ring.fraction))
                let shown = (animated ? appeared : true) ? progress : 0
                ZStack {
                    Circle()
                        .stroke(ring.color.opacity(trackOpacity), lineWidth: lineWidth)
                    Circle()
                        .trim(from: 0, to: shown)
                        .stroke(ring.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))   // start the fill at 12 o'clock
                        .animation(.smooth(duration: 0.85).delay(Double(index) * 0.06), value: shown)
                }
                .padding(inset)
            }
        }
        .onAppear { appeared = true }
    }
}

/// One labeled ring: name + value + color + fill fraction. The unit/value string is pre-formatted
/// by the caller so this stays presentation-only and portable.
struct NutritionRingSpec: Identifiable {
    let id: String
    let name: String
    let color: Color
    let fraction: Double
    let value: String

    init(id: String, name: String, color: Color, fraction: Double, value: String) {
        self.id = id
        self.name = name
        self.color = color
        self.fraction = fraction
        self.value = value
    }
}

/// Rings + labels — the "Today's Rings" summary layout. Reuse in a widget (pass `animated: false`,
/// pick a `valueColor` that suits the widget background) or a future Activity view.
struct NutritionRingsCard: View {
    var specs: [NutritionRingSpec]
    var ringSize: CGFloat = 116
    var animated: Bool = true
    var valueColor: Color = .primary

    var body: some View {
        HStack(spacing: 16) {
            NutritionRings(
                rings: specs.map { NutritionRings.Ring(fraction: $0.fraction, color: $0.color) },
                animated: animated
            )
            .frame(width: ringSize, height: ringSize)

            VStack(alignment: .leading, spacing: 12) {
                ForEach(specs) { spec in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(spec.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(spec.color)
                        Text(spec.value)
                            .font(.system(size: 17, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(valueColor)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

#Preview("Card") {
    NutritionRingsCard(specs: [
        .init(id: "protein", name: "Protein", color: VoCalTheme.Colors.gold, fraction: 1.0, value: "152 / 150 g"),
        .init(id: "water", name: "Water", color: VoCalTheme.Colors.water, fraction: 1.0, value: "96 / 96 oz"),
        .init(id: "fiber", name: "Fiber", color: VoCalTheme.Colors.optimal, fraction: 0.8, value: "24 / 30 g"),
    ])
    .padding()
    .background(VoCalTheme.Colors.card)
}

#Preview("Rings only") {
    NutritionRings(rings: [
        .init(fraction: 1.0, color: VoCalTheme.Colors.gold),
        .init(fraction: 1.0, color: VoCalTheme.Colors.water),
        .init(fraction: 0.8, color: VoCalTheme.Colors.optimal),
    ])
    .frame(width: 160, height: 160)
    .padding()
}
