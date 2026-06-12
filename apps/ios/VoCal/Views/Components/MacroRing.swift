import SwiftUI

/// Circular progress ring (calories/macro remaining). 8pt stroke, semantic color.
struct MacroRing: View {
    /// 0...1 fraction of the target consumed.
    let progress: Double
    let color: Color
    var lineWidth: CGFloat = 8
    var size: CGFloat = 64
    var systemImage: String? = nil

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0, min(1, progress)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.spring(duration: 0.6), value: progress)
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.28, weight: .semibold))
                    .foregroundStyle(VoCalTheme.Colors.ink)
            }
        }
        .frame(width: size, height: size)
    }
}

#Preview {
    HStack(spacing: VoCalTheme.Spacing.xl) {
        MacroRing(progress: 0.35, color: VoCalTheme.Colors.protein, systemImage: "fork.knife")
        MacroRing(progress: 0.62, color: VoCalTheme.Colors.carbs)
        MacroRing(progress: 0.12, color: VoCalTheme.Colors.fats)
        MacroRing(progress: 0.8, color: VoCalTheme.Colors.ink, size: 88, systemImage: "flame.fill")
    }
    .padding(VoCalTheme.Spacing.xl)
    .background(VoCalTheme.Colors.background)
}
