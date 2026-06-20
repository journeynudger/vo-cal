import SwiftUI

/// Branded loading animation — gold waveform bars that bounce, echoing the app's voice/mic
/// identity (Beacon replaces the system ProgressView with a branded loader; this is Vo-Cal's
/// equivalent, form-fit to the black/gold palette). Drop-in where a spinner would go.
struct VoCalLoader: View {
    var size: CGFloat = 44
    var color: Color = VoCalTheme.Colors.gold

    private let bars = 4

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: size * 0.11) {
                ForEach(0..<bars, id: \.self) { i in
                    let phase = t * 3.0 + Double(i) * 0.55
                    let h = (sin(phase) + 1) / 2 // 0…1
                    Capsule()
                        .fill(color)
                        .frame(width: size * 0.13, height: size * (0.32 + 0.68 * h))
                }
            }
            .frame(width: size, height: size)
        }
        .accessibilityLabel("Loading")
    }
}

#Preview {
    ZStack {
        VoCalTheme.Colors.background.ignoresSafeArea()
        VStack(spacing: 40) {
            VoCalLoader()
            VoCalLoader(size: 22, color: VoCalTheme.Colors.onCta)
                .padding()
                .background(VoCalTheme.Colors.cta, in: Capsule())
        }
    }
}
