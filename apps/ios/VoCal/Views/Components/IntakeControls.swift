import SwiftUI

// Intake input controls, lifted out of IntakeFlowView (2026-08) so the editable
// Settings Profile page reuses the EXACT controls onboarding used — same wheels,
// same selection feel — instead of a second, drifting implementation.

/// Single-select list of big tappable option rows (selected = ink border + check).
struct ChoiceList: View {
    let options: [(value: String, label: String, sub: String?)]
    @Binding var selection: String

    var body: some View {
        VStack(spacing: VoCalTheme.Spacing.m) {
            ForEach(options, id: \.value) { opt in
                Button {
                    selection = opt.value
                } label: {
                    HStack(spacing: VoCalTheme.Spacing.m) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(opt.label)
                                .font(VoCalTheme.Fonts.primaryLabel)
                                .foregroundStyle(VoCalTheme.Colors.ink)
                            if let sub = opt.sub {
                                Text(sub)
                                    .font(VoCalTheme.Fonts.formLabel)
                                    .foregroundStyle(VoCalTheme.Colors.muted)
                            }
                        }
                        Spacer()
                        if selection == opt.value {
                            Image(systemName: "checkmark")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(VoCalTheme.Colors.gold)
                        }
                    }
                    .padding(VoCalTheme.Spacing.l)
                    .softSelectableCard(isSelected: selection == opt.value)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Age / Height / Weight editor for the first intake step. Tap a row to expand a native wheel
/// picker beneath it (one open at a time). Wheels are used deliberately: they make an invalid
/// value impossible and feel native, and the row stays compact when collapsed. Imperial units —
/// the intake model and engine are lb/inches (`IntakeProfile.heightIn`/`weightLb`).
struct BasicsEditor: View {
    @Binding var age: Int
    @Binding var heightIn: Double
    @Binding var weightLb: Double

    @State private var expanded: Field?

    private enum Field { case age, height, weight }

    var body: some View {
        VStack(spacing: VoCalTheme.Spacing.s) {
            row(.age, label: "Age", value: "\(age)", id: A11y.Intake.age)
            row(.height, label: "Height", value: heightLabel, id: A11y.Intake.height)
            row(.weight, label: "Weight", value: "\(Int(weightLb.rounded())) lb", id: A11y.Intake.weight)
        }
    }

    private var heightLabel: String {
        let inches = Int(heightIn.rounded())
        return "\(inches / 12)′ \(inches % 12)″"
    }

    private func row(_ field: Field, label: String, value: String, id: String) -> some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    expanded = (expanded == field) ? nil : field
                }
            } label: {
                HStack {
                    Text(label)
                        .font(VoCalTheme.Fonts.secondaryLabel)
                        .foregroundStyle(VoCalTheme.Colors.muted)
                    Spacer()
                    Text(value)
                        .font(VoCalTheme.Fonts.primaryLabel)
                        .foregroundStyle(expanded == field ? VoCalTheme.Colors.gold : VoCalTheme.Colors.ink)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(VoCalTheme.Colors.muted)
                        .rotationEffect(.degrees(expanded == field ? 180 : 0))
                }
                .padding(VoCalTheme.Spacing.m)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded == field {
                picker(for: field)
                    .frame(height: 150)
                    .clipped()
                    .padding(.bottom, VoCalTheme.Spacing.s)
            }
        }
        .background(VoCalTheme.Colors.card, in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.chip, style: .continuous))
        .accessibilityIdentifier(id)
    }

    @ViewBuilder
    private func picker(for field: Field) -> some View {
        switch field {
        case .age:
            Picker("Age", selection: $age) {
                ForEach(14...90, id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.wheel)
            .labelsHidden()
        case .weight:
            Picker("Weight", selection: weightInt) {
                ForEach(70...500, id: \.self) { Text("\($0) lb").tag($0) }
            }
            .pickerStyle(.wheel)
            .labelsHidden()
        case .height:
            HStack(spacing: 0) {
                Picker("Feet", selection: feet) {
                    ForEach(3...7, id: \.self) { Text("\($0) ft").tag($0) }
                }
                .pickerStyle(.wheel)
                .labelsHidden()
                Picker("Inches", selection: inches) {
                    ForEach(0...11, id: \.self) { Text("\($0) in").tag($0) }
                }
                .pickerStyle(.wheel)
                .labelsHidden()
            }
        }
    }

    // Proxies: the draft stores weight as Double lb and height as Double inches; the wheels
    // pick whole numbers (feet/inches/lb), composed back into those fields.
    private var weightInt: Binding<Int> {
        Binding(get: { Int(weightLb.rounded()) }, set: { weightLb = Double($0) })
    }
    private var feet: Binding<Int> {
        Binding(
            get: { Int(heightIn.rounded()) / 12 },
            set: { heightIn = Double($0 * 12 + Int(heightIn.rounded()) % 12) }
        )
    }
    private var inches: Binding<Int> {
        Binding(
            get: { Int(heightIn.rounded()) % 12 },
            set: { heightIn = Double((Int(heightIn.rounded()) / 12) * 12 + $0) }
        )
    }
}
