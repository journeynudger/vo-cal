import SwiftUI
import VoCalCore

/// "Log a meal" (2026-11-06): the sheet under the home's one pill. The meal it lands in, the
/// four ways in (speak first and largest; type, a photo, a barcode beside it), the usuals as
/// one tap, and water. Nothing is logged from here: each way hands the shell a slot and the
/// shell opens the capture, the chat, the camera or the scanner. A usual is the one exception,
/// logged through the model the way Today's chips did, with its chip busy until the row lands.
struct LogSheet: View {
    @State var slot: DiarySlot
    var usuals: [SavedMeal] = []
    var loggingUsualID: String? = nil
    var printsNumbers = true
    var onSpeak: (DiarySlot) -> Void = { _ in }
    var onType: (DiarySlot) -> Void = { _ in }
    var onPhoto: (DiarySlot) -> Void = { _ in }
    var onScan: (DiarySlot) -> Void = { _ in }
    var onUsual: (SavedMeal, DiarySlot) -> Void = { _, _ in }
    var onWater: () -> Void = {}

    var body: some View {
        ZStack {
            VoCalTheme.Colors.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: VoCalTheme.Spacing.l) {
                    HStack {
                        Text("Log a meal")
                            .font(VoCalTheme.Fonts.screenTitle)
                            .foregroundStyle(VoCalTheme.Colors.ink)
                        Spacer()
                    }
                    .padding(.top, VoCalTheme.Spacing.xl)
                    slotChips
                    speakCard
                    waysRow
                    if !usuals.isEmpty { usualsRow }
                    waterRow
                }
                .padding(.horizontal, VoCalTheme.Spacing.l)
                .padding(.bottom, VoCalTheme.Spacing.xl)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(A11y.Log.sheet)
    }

    /// Which meal this goes in: the clock's suggestion, or the section whose Add was tapped.
    private var slotChips: some View {
        HStack(spacing: VoCalTheme.Spacing.s) {
            ForEach(DiarySlot.allCases) { candidate in
                let on = candidate == slot
                Button {
                    VoCalHaptics.select()
                    withAnimation(.snappy(duration: 0.2)) { slot = candidate }
                } label: {
                    Text(candidate.title)
                        .font(VoCalTheme.Fonts.chipLabel)
                        .foregroundStyle(on ? VoCalTheme.Colors.onCta : VoCalTheme.Colors.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.horizontal, VoCalTheme.Spacing.s)
                        .frame(height: 36)
                        .frame(maxWidth: .infinity)
                        .background(on ? VoCalTheme.Colors.cta : VoCalTheme.Colors.card, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityIdentifier(A11y.Log.slot(candidate.rawValue))
            }
        }
    }

    /// Voice is the way in (decision 5, relaxed never reversed): the largest control on the
    /// sheet, the mic on the gold glass face the bar's droplet wears.
    private var speakCard: some View {
        Button { onSpeak(slot) } label: {
            HStack(spacing: VoCalTheme.Spacing.l) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(VoCalTheme.Colors.gold)
                    .frame(width: 64, height: 64)
                    .liquidGlass(in: Circle(), tint: CaptureBar.dropletFace, interactive: true, rim: VoCalTheme.Colors.goldBorderStrong, rimWidth: 1.5)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Say what you ate")
                        .font(VoCalTheme.Fonts.primaryLabel)
                        .foregroundStyle(VoCalTheme.Colors.ink)
                    Text("Tap and talk. Amounts help, like two eggs or a cup of rice.")
                        .font(VoCalTheme.Fonts.formLabel)
                        .foregroundStyle(VoCalTheme.Colors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(VoCalTheme.Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(VoCalTheme.Colors.card, in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.card, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: VoCalTheme.Radius.card, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("Log a meal by voice")
        .accessibilityIdentifier(A11y.Log.speak)
    }

    private var waysRow: some View {
        HStack(spacing: VoCalTheme.Spacing.s) {
            way("keyboard", "Type", id: A11y.Log.type) { onType(slot) }
            way("camera", "Photo", id: A11y.Log.photo) { onPhoto(slot) }
            way("barcode.viewfinder", "Scan", id: A11y.Log.scan) { onScan(slot) }
        }
    }

    private func way(_ symbol: String, _ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: VoCalTheme.Spacing.s) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(VoCalTheme.Colors.ink)
                Text(title)
                    .font(VoCalTheme.Fonts.chipLabel)
                    .foregroundStyle(VoCalTheme.Colors.ink)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 84)
            .background(VoCalTheme.Colors.card, in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.row, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: VoCalTheme.Radius.row, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("\(title) a meal")
        .accessibilityIdentifier(id)
    }

    private var usualsRow: some View {
        VStack(alignment: .leading, spacing: VoCalTheme.Spacing.s) {
            Text("Usuals")
                .font(VoCalTheme.Fonts.formLabel.weight(.semibold))
                .foregroundStyle(VoCalTheme.Colors.muted)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: VoCalTheme.Spacing.s) {
                    ForEach(usuals) { usual in
                        usualChip(usual)
                    }
                }
                .padding(.vertical, 2)
                .padding(.horizontal, VoCalTheme.Spacing.l)
            }
            .padding(.horizontal, -VoCalTheme.Spacing.l)
        }
    }

    private func usualChip(_ usual: SavedMeal) -> some View {
        let isLogging = loggingUsualID == usual.id
        let blocked = loggingUsualID != nil && !isLogging
        return Button {
            onUsual(usual, slot)
        } label: {
            ZStack {
                HStack(spacing: VoCalTheme.Spacing.xs) {
                    Text(usual.name)
                        .font(VoCalTheme.Fonts.chipLabel)
                        .foregroundStyle(VoCalTheme.Colors.ink)
                        .lineLimit(1)
                    if printsNumbers {
                        Text("· \(DashboardNumber.whole(usual.kcal)) cal")
                            .font(VoCalTheme.Fonts.chipLabel)
                            .monospacedDigit()
                            .foregroundStyle(VoCalTheme.Colors.muted)
                            .lineLimit(1)
                    }
                }
                .opacity(isLogging ? 0 : 1)
                if isLogging { VoCalLoader(size: 18) }
            }
            .padding(.horizontal, VoCalTheme.Spacing.l)
            .frame(height: 44)
            .background(VoCalTheme.Colors.card, in: Capsule())
            .overlay(Capsule().strokeBorder(VoCalTheme.Colors.goldBorder, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(loggingUsualID != nil)
        .opacity(blocked ? 0.45 : 1)
        .accessibilityLabel(printsNumbers ? "Log \(usual.name), \(DashboardNumber.whole(usual.kcal)) calories" : "Log \(usual.name)")
        .accessibilityIdentifier(A11y.Log.usualChip)
    }

    private var waterRow: some View {
        Button(action: onWater) {
            HStack(spacing: VoCalTheme.Spacing.m) {
                Image(systemName: "drop.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(VoCalTheme.Colors.water)
                Text("Add water")
                    .font(VoCalTheme.Fonts.body)
                    .foregroundStyle(VoCalTheme.Colors.ink)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(VoCalTheme.Colors.muted)
            }
            .padding(.horizontal, VoCalTheme.Spacing.l)
            .frame(height: 52)
            .background(VoCalTheme.Colors.card, in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.chip, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityIdentifier(A11y.Log.water)
    }
}

#Preview {
    LogSheet(
        slot: .lunch,
        usuals: [
            SavedMeal(id: "1", name: "Chicken & rice", items: [], totals: NutrientProfile(kcal: 540, protein: 57, carbs: 56, fat: 7, fiber: 1)),
            SavedMeal(id: "2", name: "Protein shake", items: [], totals: NutrientProfile(kcal: 120, protein: 25, carbs: 3, fat: 1, fiber: 0)),
        ]
    )
}
