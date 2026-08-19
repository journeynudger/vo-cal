import SwiftUI
import VoCalCore

/// One colour vocabulary for the week, used by the budget graph, Today's card
/// and the Progress page so a day means the same thing everywhere.
///
/// Status semantics (Lorenzo beta feedback, 2026-08-19, decision #45): gold
/// reads as "under / on the way" (today in progress draws full gold, a past
/// under-goal day sits at gold 55%), `optimal` green means the goal was met,
/// and `alert` red marks going over. Gold keeps its brand-accent role and
/// gains a second meaning, progress toward goal; the status green/red are
/// never used for macros.
extension WeekDayStatus {
    /// Fill for a bar in this state.
    var barFill: Color {
        switch self {
        case .under: return VoCalTheme.Colors.gold.opacity(0.55)
        case .onTarget: return VoCalTheme.Colors.optimal
        case .over: return VoCalTheme.Colors.alert
        case .inProgress: return VoCalTheme.Colors.gold
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
