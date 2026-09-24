import SwiftUI

/// Horizontal day selector from the reference layout: letter + day number,
/// dotted circle for selectable days, filled for the selected day.
struct WeekStrip: View {
    let days: [Date]
    @Binding var selected: Date
    var calendar: Calendar = .current

    /// Three letters, not one: "F S S M T W T" made two days ambiguous (critic, 2026-09-24).
    private static let dayFormat: Date.FormatStyle = .dateTime.weekday(.abbreviated)

    var body: some View {
        HStack(spacing: 0) {
            ForEach(days, id: \.self) { day in
                let isSelected = calendar.isDate(day, inSameDayAs: selected)
                let isFuture = day > Date.now
                Button {
                    guard !isFuture, !isSelected else { return }
                    VoCalHaptics.select()
                    selected = day
                } label: {
                    VStack(spacing: VoCalTheme.Spacing.s) {
                        Text(day.formatted(Self.dayFormat))
                            .font(VoCalTheme.Fonts.formLabel)
                            .foregroundStyle(VoCalTheme.Colors.muted.opacity(isFuture ? 0.5 : 1))
                        Text("\(calendar.component(.day, from: day))")
                            .font(VoCalTheme.Fonts.chipLabel)
                            .monospacedDigit()
                            .foregroundStyle(
                                isSelected ? VoCalTheme.Colors.onCta
                                    : VoCalTheme.Colors.ink.opacity(isFuture ? 0.35 : 1)
                            )
                            // The selected day is the one filled circle on the strip; the
                            // others are plain numbers (the dashed rings were noise).
                            .frame(width: 36, height: 36)
                            .background {
                                if isSelected {
                                    Circle().fill(VoCalTheme.Colors.cta)
                                }
                            }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isFuture)
                .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).month().day()))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
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
