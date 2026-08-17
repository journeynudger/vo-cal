import SwiftUI
import VoCalCore

/// One colour vocabulary for the week, used by the budget graph, Today's card
/// and the Progress page so a day means the same thing everywhere.
///
/// Borrowed structure from the reference (a light tone for short of the line,
/// the base tone for landing on it, a distinct tone for going past it), mapped
/// onto Vo-Cal's black/gold palette instead of its navy/purple: ink is the
/// confident "you landed it" tone, faded ink is the short-of-goal tone, and
/// gold — the brand's attention colour, never a shaming red — marks an overage.
extension WeekDayStatus {
    /// Fill for a bar in this state.
    var barFill: Color {
        switch self {
        case .under: return VoCalTheme.Colors.ink.opacity(0.28)
        case .onTarget: return VoCalTheme.Colors.ink
        case .over: return VoCalTheme.Colors.gold
        case .inProgress: return VoCalTheme.Colors.ink.opacity(0.55)
        case .notLogged: return .clear
        case .upcoming: return VoCalTheme.Colors.ink.opacity(0.07)
        }
    }

    /// Outline for states that read as an empty frame rather than a filled bar.
    var barStroke: Color {
        switch self {
        case .notLogged: return VoCalTheme.Colors.muted.opacity(0.45)
        case .upcoming: return VoCalTheme.Colors.ink.opacity(0.12)
        default: return .clear
        }
    }

    /// A day with no bar of its own draws its goal as an empty frame instead.
    var drawsGoalFrame: Bool {
        self == .notLogged || self == .upcoming
    }

    /// Plain-language label for legends and accessibility.
    var label: String {
        switch self {
        case .under: return "Under"
        case .onTarget: return "On target"
        case .over: return "Over"
        case .inProgress: return "Today"
        case .notLogged: return "Not logged"
        case .upcoming: return "Planned"
        }
    }
}

/// The three-swatch legend under the week graph: what the colours mean, stated
/// once instead of left to be inferred.
struct WeekStatusLegend: View {
    var body: some View {
        HStack(spacing: VoCalTheme.Spacing.l) {
            ForEach([WeekDayStatus.under, .onTarget, .over], id: \.self) { status in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(status.barFill)
                        .frame(width: 10, height: 10)
                    Text(status.label)
                        .font(VoCalTheme.Fonts.formLabel)
                        .foregroundStyle(VoCalTheme.Colors.muted)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Bar colours: under, on target, over")
    }
}

/// The dashed reference line drawn across the whole graph at the daily goal —
/// the number the protocol set, so the cusp you are aiming at is always visible
/// even when a day's own target has been rebalanced away from it.
struct GoalReferenceLine: Shape {
    /// 0 (top) … 1 (bottom) position within the plot.
    var fraction: CGFloat

    nonisolated func path(in rect: CGRect) -> Path {
        var path = Path()
        let y = rect.minY + rect.height * min(max(fraction, 0), 1)
        path.move(to: CGPoint(x: rect.minX, y: y))
        path.addLine(to: CGPoint(x: rect.maxX, y: y))
        return path
    }
}

/// Dash pattern shared by the goal line and the per-day goal ticks.
let goalLineStroke = StrokeStyle(lineWidth: 1.5, dash: [5, 4])
