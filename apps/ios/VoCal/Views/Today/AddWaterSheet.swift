import SwiftUI
import VoCalCore

/// Manual water quick-add, opened from the Today water tile. This is the counterpart to saying
/// "16 oz of water" by voice — it closes the gap where water had a displayed target but no way
/// to fill it from the dashboard. Preset chips cover the common glass/bottle sizes; the custom
/// field takes any oz. The caller performs the async log + refresh (`TodayViewModel.addWater`);
/// this view only collects the amount. Black/gold, VoCalTheme tokens only.
struct AddWaterSheet: View {
    /// Called with the oz to log; the sheet dismisses immediately after.
    var onAdd: (Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var customText = ""

    private let presets: [Double] = [8, 12, 16, 20]

    var body: some View {
        ZStack(alignment: .top) {
            VoCalTheme.Colors.background.ignoresSafeArea()
            VStack(alignment: .leading, spacing: VoCalTheme.Spacing.l) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add water").sectionHeader()
                    Text("How much?")
                        .font(.system(size: 27, weight: .semibold))
                        .foregroundStyle(VoCalTheme.Colors.ink)
                }
                .padding(.top, VoCalTheme.Spacing.xl)

                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    spacing: VoCalTheme.Spacing.s
                ) {
                    ForEach(presets, id: \.self) { oz in
                        Button { add(oz) } label: {
                            Text("+\(Int(oz)) oz")
                                .font(VoCalTheme.Fonts.primaryLabel)
                                .foregroundStyle(VoCalTheme.Colors.ink)
                                .frame(maxWidth: .infinity, minHeight: 54)
                                .background(
                                    VoCalTheme.Colors.card,
                                    in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.chip, style: .continuous)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }

                VStack(alignment: .leading, spacing: VoCalTheme.Spacing.s) {
                    Text("Custom amount")
                        .font(VoCalTheme.Fonts.formLabel)
                        .foregroundStyle(VoCalTheme.Colors.muted)
                    HStack {
                        TextField("oz", text: $customText)
                            .keyboardType(.decimalPad)
                            .font(VoCalTheme.Fonts.primaryLabel)
                            .accessibilityIdentifier(A11y.Today.addWaterField)
                        Text("oz")
                            .font(VoCalTheme.Fonts.secondaryLabel)
                            .foregroundStyle(VoCalTheme.Colors.muted)
                    }
                    .padding(VoCalTheme.Spacing.m)
                    .background(
                        VoCalTheme.Colors.card,
                        in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.chip, style: .continuous)
                    )
                }

                Spacer()

                PillButton(title: "Add water") { addCustom() }
                    .opacity(customOz == nil ? 0.5 : 1)
                    .disabled(customOz == nil)
                    .accessibilityIdentifier(A11y.Today.addWaterConfirm)
            }
            .padding(.horizontal, VoCalTheme.Spacing.l)
            .padding(.bottom, VoCalTheme.Spacing.l)
        }
        .overlay(alignment: .topTrailing) { closeButton }
    }

    /// The parsed custom oz, or nil when the field is empty/invalid (gates the Add button).
    private var customOz: Double? {
        guard let value = Double(customText.trimmingCharacters(in: .whitespaces)), value > 0 else { return nil }
        return value
    }

    private func add(_ oz: Double) {
        onAdd(oz)
        dismiss()
    }

    private func addCustom() {
        guard let oz = customOz else { return }
        add(oz)
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(VoCalTheme.Colors.ink)
                .frame(width: 34, height: 34)
                .glassEffect(.regular, in: Circle())
        }
        .padding(VoCalTheme.Spacing.l)
    }
}

#Preview {
    AddWaterSheet { _ in }
}
