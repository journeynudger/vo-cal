import SwiftUI

/// The floating menu's Home glyph: a rounded house with an arched doorway, drawn as
/// a Path so it stays crisp at any size (the reference the user supplied was a small
/// raster; this is its vector form-fit, user ask 2026-08-23). Inherits the current
/// foreground style, so the tab button's gold/muted selection colors it like any
/// SF Symbol.
struct HomeGlyphIcon: View {
    var body: some View {
        GeometryReader { geo in
            // Corner rounding: re-stroke the filled silhouette with a round-join
            // stroke of the same color — the standard trick for rounding a filled
            // polygon without hand-computing every corner arc. The stroke fattens
            // the shape by half its width all around (the door notch in
            // HomeGlyphShape is drawn wide to compensate).
            let stroke = min(geo.size.width, geo.size.height) * 0.14
            ZStack {
                HomeGlyphShape().fill(.foreground)
                HomeGlyphShape().stroke(
                    .foreground,
                    style: StrokeStyle(lineWidth: stroke, lineCap: .round, lineJoin: .round)
                )
            }
        }
    }
}

/// House silhouette with the arched-door notch cut through the bottom edge, in a
/// normalized 100x100 design space.
struct HomeGlyphShape: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(
                x: rect.minX + x / 100 * rect.width,
                y: rect.minY + y / 100 * rect.height
            )
        }

        var path = Path()
        path.move(to: point(50, 8))        // apex
        path.addLine(to: point(91, 44))    // right eave
        path.addLine(to: point(91, 90))    // bottom right
        path.addLine(to: point(70, 90))    // door, right foot
        path.addLine(to: point(70, 72))    // door, right jamb
        // Arch over the doorway, right jamb to left jamb through the top.
        path.addArc(
            center: point(50, 72),
            radius: 20 / 100 * rect.width,
            startAngle: .degrees(0),
            endAngle: .degrees(180),
            clockwise: true
        )
        path.addLine(to: point(30, 90))    // door, left foot
        path.addLine(to: point(9, 90))     // bottom left
        path.addLine(to: point(9, 44))     // left eave
        path.closeSubpath()
        return path
    }
}

#Preview {
    HStack(spacing: 24) {
        HomeGlyphIcon()
            .frame(width: 26, height: 26)
            .foregroundStyle(VoCalTheme.Colors.gold)
        HomeGlyphIcon()
            .frame(width: 26, height: 26)
            .foregroundStyle(VoCalTheme.Colors.muted)
        HomeGlyphIcon()
            .frame(width: 64, height: 64)
            .foregroundStyle(VoCalTheme.Colors.ink)
    }
    .padding()
    .background(VoCalTheme.Colors.background)
}
