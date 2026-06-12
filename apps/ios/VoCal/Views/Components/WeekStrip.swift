import SwiftUI

/// Horizontal day selector from the reference layout: letter + day number,
/// dotted circle for selectable days, filled for the selected day.
struct WeekStrip: View {
    let days: [Date]
    @Binding var selected: Date
    var calendar: Calendar = .current

    private static let letterFormat: Date.FormatStyle = .dateTime.weekday(.narrow)

    var body: some View {
        HStack(spacing: 0) {
            ForEach(days, id: \.self) { day in
                let isSelected = calendar.isDate(day, inSameDayAs: selected)
                let isFuture = day > Date.now
                Button {
                    if !isFuture { selected = day }
                } label: {
                    VStack(spacing: VoCalTheme.Spacing.s) {
                        Text(day.formatted(Self.letterFormat))
                            .font(VoCalTheme.Fonts.formLabel)
                            .foregroundStyle(VoCalTheme.Colors.muted)
                        Text("\(calendar.component(.day, from: day))")
                            .font(VoCalTheme.Fonts.chipLabel)
                            .foregroundStyle(isSelected ? VoCalTheme.Colors.onCta : VoCalTheme.Colors.ink)
                            .frame(width: 34, height: 34)
                            .background {
                                if isSelected {
                                    Circle().fill(VoCalTheme.Colors.cta)
                                } else {
                                    Circle()
                                        .strokeBorder(
                                            VoCalTheme.Colors.muted.opacity(isFuture ? 0.25 : 0.5),
                                            style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                                        )
                                }
                            }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .disabled(isFuture)
            }
        }
    }
}

#Preview {
    struct Host: View {
        @State private var selected = Date.now
        var body: some View {
            let cal = Calendar.current
            let days = (-5...1).compactMap { cal.date(byAdding: .day, value: $0, to: .now) }
            WeekStrip(days: days, selected: $selected)
                .padding(VoCalTheme.Spacing.l)
                .background(VoCalTheme.Colors.background)
        }
    }
    return Host()
}
