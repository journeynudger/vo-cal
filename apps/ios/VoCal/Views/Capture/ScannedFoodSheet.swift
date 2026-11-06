import SwiftUI

enum ScannedFoodA11y {
    static let sheet = "scanned-food.sheet"
    static let minus = "scanned-food.minus"
    static let plus = "scanned-food.plus"
    static let servings = "scanned-food.servings"
    static let log = "scanned-food.log"
    static let close = "scanned-food.close"
}

/// A packaged food found by its barcode, before it is logged: what it is, what one serving
/// holds, and how many servings the person had. The numbers are the server's, per serving;
/// the sheet multiplies them for the line under the stepper and does no other math (the
/// server prices what is logged, AGENTS.md #6). When the person's mode does not print
/// numbers (`printsNumbers` false) no calorie appears anywhere on it: the name, the serving
/// and the amount are the whole sheet.
struct ScannedFoodSheet: View {
    let food: BarcodeFood
    var printsNumbers: Bool = true
    let onLog: (_ servings: Double) -> Void
    let onClose: () -> Void
    var isLogging: Bool = false

    @State private var servings = ScannedFoodSheet.defaultServings

    static let defaultServings = 1.0
    static let step = 0.5
    static let minimumServings = 0.5
    static let maximumServings = 20.0

    var body: some View {
        ZStack {
            VoCalTheme.Colors.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: VoCalTheme.Spacing.l) {
                    titleBlock
                    servingCard
                    stepperRow
                    if printsNumbers {
                        Text(totalLine)
                            .font(VoCalTheme.Fonts.secondaryLabel)
                            .foregroundStyle(VoCalTheme.Colors.muted)
                            .contentTransition(.numericText())
                            .animation(.snappy, value: servings)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .padding(.horizontal, VoCalTheme.Spacing.l)
                .padding(.top, VoCalTheme.Spacing.xl)
                .padding(.bottom, VoCalTheme.Spacing.xxl)
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: VoCalTheme.Spacing.s) {
                PillButton(title: "Log it", isLoading: isLogging) {
                    onLog(servings)
                }
                .accessibilityIdentifier(ScannedFoodA11y.log)
                VoCalButton(title: "Close", kind: .tertiary, action: onClose)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier(ScannedFoodA11y.close)
            }
            .padding(VoCalTheme.Spacing.l)
            .glassEffect(.regular, in: Rectangle())
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(ScannedFoodA11y.sheet)
    }

    // MARK: pieces

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Found").sectionHeader()
            Text(food.displayName)
                .font(VoCalTheme.Fonts.screenTitle)
                .foregroundStyle(VoCalTheme.Colors.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let brand = food.brand?.trimmingCharacters(in: .whitespacesAndNewlines), !brand.isEmpty {
                Text(brand)
                    .font(VoCalTheme.Fonts.secondaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
            }
        }
    }

    private var servingCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: VoCalTheme.Spacing.xs) {
                if printsNumbers {
                    HStack(alignment: .firstTextBaseline, spacing: VoCalTheme.Spacing.xs) {
                        Text("\(BarcodeFood.wholeNumber(food.perServing.kcal))")
                            .font(VoCalTheme.Fonts.numeral(48))
                            .monospacedDigit()
                            .foregroundStyle(VoCalTheme.Colors.ink)
                        Text("cal")
                            .font(VoCalTheme.Fonts.secondaryLabel)
                            .foregroundStyle(VoCalTheme.Colors.muted)
                    }
                    .accessibilityElement(children: .combine)
                }
                Text(food.servingText)
                    .font(VoCalTheme.Fonts.body)
                    .foregroundStyle(printsNumbers ? VoCalTheme.Colors.muted : VoCalTheme.Colors.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var stepperRow: some View {
        HStack(spacing: VoCalTheme.Spacing.s) {
            Text("Servings")
                .font(VoCalTheme.Fonts.primaryLabel)
                .foregroundStyle(VoCalTheme.Colors.ink)
            Spacer(minLength: VoCalTheme.Spacing.s)
            stepButton(
                "minus", label: "Fewer servings", identifier: ScannedFoodA11y.minus,
                enabled: servings > Self.minimumServings
            ) { change(by: -Self.step) }
            Text(Self.servingsText(servings))
                .font(.system(size: 22, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(VoCalTheme.Colors.ink)
                .contentTransition(.numericText())
                .animation(.snappy, value: servings)
                .frame(minWidth: 56)
                .accessibilityLabel("\(Self.servingsText(servings)) \(servings == 1 ? "serving" : "servings")")
                .accessibilityIdentifier(ScannedFoodA11y.servings)
            stepButton(
                "plus", label: "More servings", identifier: ScannedFoodA11y.plus,
                enabled: servings < Self.maximumServings
            ) { change(by: Self.step) }
        }
        .padding(.horizontal, VoCalTheme.Spacing.l)
        .padding(.vertical, VoCalTheme.Spacing.m)
        .background(
            VoCalTheme.Colors.softFill,
            in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.row, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: VoCalTheme.Radius.row, style: .continuous)
                .strokeBorder(VoCalTheme.Colors.goldBorder, lineWidth: 1)
        )
    }

    private func stepButton(
        _ symbol: String,
        label: String,
        identifier: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(VoCalTheme.Colors.ink)
                .frame(width: 44, height: 44)
                .background(Circle().fill(VoCalTheme.Colors.white))
                .overlay(Circle().strokeBorder(VoCalTheme.Colors.goldBorder, lineWidth: 1.5))
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(!enabled || isLogging)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    // MARK: arithmetic (display only)

    private func change(by delta: Double) {
        servings = min(max(servings + delta, Self.minimumServings), Self.maximumServings)
    }

    /// "420 cal for 2 servings": the server's per-serving calories times the amount, for the
    /// eye only. What is logged is priced by the server from the food, never from this.
    private var totalLine: String {
        let total = BarcodeFood.wholeNumber(food.perServing.kcal * servings)
        return "\(total) cal for \(Self.servingsText(servings)) \(servings == 1 ? "serving" : "servings")"
    }

    /// "1", "1.5", "20": whole numbers bare, halves with the half.
    private static func servingsText(_ servings: Double) -> String {
        servings.rounded() == servings ? String(Int(servings)) : String(format: "%.1f", servings)
    }
}

#Preview("Oat bar") {
    ScannedFoodSheet(food: MockBarcodeService.oatBar, onLog: { _ in }, onClose: {})
}

#Preview("Numbers off") {
    ScannedFoodSheet(food: MockBarcodeService.oatBar, printsNumbers: false, onLog: { _ in }, onClose: {})
}

#Preview("Logging") {
    ScannedFoodSheet(food: MockBarcodeService.darkChocolate, onLog: { _ in }, onClose: {}, isLogging: true)
}
