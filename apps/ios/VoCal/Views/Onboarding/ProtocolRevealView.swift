import SwiftUI
import VoCalCore

/// F5 — the reveal. Generates the protocol from the intake (mock on the sim path) behind a
/// brief "building…" beat, then shows what the person's mode reveals of it (decision 59): the
/// calorie hero and the mode's rows with their tap-to-expand "why", the "built from what you
/// told us" chips, and the not-medical-advice disclaimer. The engine computed every target
/// for every mode; this screen shows the subset the server names in `reveal`. Habits shows its
/// two counts and its one habit with none (spec R12, variant a: the reveal may not contradict
/// the Today it leads to, whose tiles show the same counts). Black/gold, VoCalTheme only.
struct ProtocolRevealView: View {
    let intake: IntakeProfile
    /// The way the person chose on the first step; it decides the copy here and travels with
    /// the generate call so the server's `reveal` matches before the preference write lands.
    var mode: TrackingMode
    var onContinue: () -> Void
    var service: any ProtocolService

    @State private var phase: Phase
    @State private var expanded: Set<String> = []
    /// Bumped by "Try again". `.task(id:)` restarts only when its id changes, so a retry that
    /// merely set `phase = .building` never re-ran the generate call and spun forever
    /// (found 2026-10-04 in the onboarding sweep; the first run is the one place a hang costs
    /// an activation).
    @State private var attempt = 0

    enum Phase: Equatable {
        case building
        case ready(GeneratedProtocol)
        case failed
    }

    init(
        intake: IntakeProfile,
        mode: TrackingMode = .five,
        onContinue: @escaping () -> Void,
        service: (any ProtocolService)? = nil,
        /// Renders and previews start from a phase; the app starts building.
        phase: Phase = .building
    ) {
        self.intake = intake
        self.mode = mode
        self.onContinue = onContinue
        self.service = service ?? (RuntimeMode.usesMockServices ? MockProtocolService() : LiveProtocolService())
        _phase = State(initialValue: phase)
    }

    var body: some View {
        ZStack {
            VoCalTheme.Colors.background.ignoresSafeArea()
            switch phase {
            case .building: building
            case let .ready(generated): reveal(generated)
            case .failed: failed
            }
        }
        .task(id: attempt) {
            guard case .building = phase else { return }
            do {
                let generated = try await service.generate(from: intake, mode: mode)
                phase = .ready(generated)
            } catch {
                phase = .failed
            }
        }
    }

    private var building: some View {
        VStack(spacing: VoCalTheme.Spacing.l) {
            VoCalLoader(size: 48)
            Text(mode == .habits ? "Setting up your habits\u{2026}" : "Building your protocol\u{2026}")
                .font(VoCalTheme.Fonts.primaryLabel)
                .foregroundStyle(VoCalTheme.Colors.ink)
            Text(buildingDetail)
                .font(VoCalTheme.Fonts.formLabel)
                .foregroundStyle(VoCalTheme.Colors.muted)
        }
        .padding(VoCalTheme.Spacing.xl)
    }

    private var buildingDetail: String {
        switch mode {
        case .habits: "Your water and your produce, from your weight"
        case .calories: "Placing your deficit"
        case .macros: "Placing your deficit · splitting protein, carbs & fat"
        case .five, .mealPlan: "Placing your deficit · scaling protein, water & fiber"
        }
    }

    /// The five's keys, for a server that predates `reveal`.
    private static let fiveKeys = ["kcal", "protein", "water", "fiber", "produce"]

    private func reveal(_ generated: GeneratedProtocol) -> some View {
        let t = generated.targets
        let keys = generated.reveal.isEmpty ? Self.fiveKeys : generated.reveal
        let rowKeys = keys.filter { $0 != "kcal" && Self.rowKeys.contains($0) }
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: VoCalTheme.Spacing.l) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mode == .habits ? "Your habits" : "Your protocol").sectionHeader()
                        Text(mode == .habits ? "Three things, every day." : "Here's your starting point.")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(VoCalTheme.Colors.ink)
                    }
                    .padding(.top, VoCalTheme.Spacing.xl)

                    if keys.contains("kcal") {
                        calorieHero(t)
                    }

                    // The mode's rows, with expandable whys. Habits leads with the one habit
                    // that has no nutrient behind it.
                    VStack(spacing: 0) {
                        if mode == .habits {
                            targetRow("Logged today", value: "Every day", color: VoCalTheme.Colors.gold, whyKey: "logged", whys: [:])
                            if !rowKeys.isEmpty { divider }
                        }
                        ForEach(Array(rowKeys.enumerated()), id: \.element) { index, key in
                            if index > 0 { divider }
                            row(key, t)
                        }
                    }
                    .padding(.horizontal, VoCalTheme.Spacing.l)
                    .background(VoCalTheme.Colors.card, in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.card, style: .continuous))

                    Text("Built from what you told us").sectionHeader(VoCalTheme.Colors.muted)
                        .padding(.top, VoCalTheme.Spacing.s)
                    seenChips

                    Text("Not medical advice. These targets are a starting point from your inputs, not a clinical recommendation. Check with a professional for medical concerns.")
                        .font(VoCalTheme.Fonts.formLabel)
                        .foregroundStyle(VoCalTheme.Colors.muted)
                        .padding(VoCalTheme.Spacing.m)
                        .background(VoCalTheme.Colors.card, in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.chip, style: .continuous))
                        .padding(.top, VoCalTheme.Spacing.s)
                }
                .padding(.horizontal, VoCalTheme.Spacing.l)
                .padding(.bottom, VoCalTheme.Spacing.xl)
            }
            PillButton(title: "Save & start logging", action: onContinue)
                .padding(VoCalTheme.Spacing.l)
        }
    }

    private func calorieHero(_ t: ProtocolTargets) -> some View {
        VStack(spacing: VoCalTheme.Spacing.xs) {
            Text("Daily calories")
                .font(VoCalTheme.Fonts.formLabel)
                .foregroundStyle(VoCalTheme.Colors.muted)
            Text(t.kcal.formatted(.number.grouping(.automatic)))
                .font(VoCalTheme.Fonts.numeral(60))
                .monospacedDigit()
                .foregroundStyle(VoCalTheme.Colors.gold)
            if let why = t.whys["kcal"] {
                Text(why)
                    .font(VoCalTheme.Fonts.formLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, VoCalTheme.Spacing.s)
    }

    /// The keys this screen can draw as a row, so a key from a later server is skipped, never
    /// a blank row.
    private static let rowKeys: Set<String> = ["protein", "water", "fiber", "produce", "carbs", "fat"]

    @ViewBuilder
    private func row(_ key: String, _ t: ProtocolTargets) -> some View {
        switch key {
        case "protein":
            targetRow("Protein", value: proteinValue(t), color: VoCalTheme.Colors.protein, whyKey: key, whys: t.whys)
        case "water":
            targetRow("Water", value: "\(t.waterOz) oz", color: VoCalTheme.Colors.muted, whyKey: key, whys: t.whys)
        case "fiber":
            targetRow("Fiber", value: "\(t.fiber) g", color: VoCalTheme.Colors.muted, whyKey: key, whys: t.whys)
        case "produce":
            targetRow("Produce", value: "\(t.produceServings) a day", color: VoCalTheme.Colors.muted, whyKey: key, whys: t.whys)
        case "carbs":
            targetRow("Carbs", value: "\(t.carbs) g", color: VoCalTheme.Colors.carbs, whyKey: key, whys: t.whys)
        case "fat":
            targetRow("Fat", value: "\(t.fat) g", color: VoCalTheme.Colors.fats, whyKey: key, whys: t.whys)
        default:
            EmptyView()
        }
    }

    /// Protein as its optimal band when the protocol carries one; the bare target otherwise
    /// (older protocols), never a fabricated 0 to 0 range.
    private func proteinValue(_ t: ProtocolTargets) -> String {
        if t.proteinMax > t.proteinMin, t.proteinMin > 0 {
            return "\(t.proteinMin) to \(t.proteinMax) g"
        }
        return "\(t.protein) g"
    }

    private var divider: some View {
        Rectangle().fill(VoCalTheme.Colors.ink.opacity(0.07)).frame(height: 1)
    }

    private func targetRow(_ label: String, value: String, color: Color, whyKey: String, whys: [String: String]) -> some View {
        let isOpen = expanded.contains(whyKey)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                if isOpen { expanded.remove(whyKey) } else { expanded.insert(whyKey) }
            } label: {
                HStack(spacing: VoCalTheme.Spacing.m) {
                    Circle().fill(color).frame(width: 9, height: 9)
                    Text(label)
                        .font(VoCalTheme.Fonts.primaryLabel)
                        .foregroundStyle(VoCalTheme.Colors.ink)
                    Spacer()
                    Text(value)
                        .font(.system(size: 15, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(VoCalTheme.Colors.ink)
                    if whys[whyKey] != nil {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(VoCalTheme.Colors.muted)
                            .rotationEffect(.degrees(isOpen ? 180 : 0))
                    }
                }
                .padding(.vertical, VoCalTheme.Spacing.m)
            }
            .buttonStyle(.plain)
            .disabled(whys[whyKey] == nil)
            if isOpen, let why = whys[whyKey] {
                Text(why)
                    .font(VoCalTheme.Fonts.secondaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
                    .padding(.bottom, VoCalTheme.Spacing.m)
            }
        }
    }

    private var seenChips: some View {
        let chips = intakeChips
        return SeenChipsRow(items: chips)
    }

    private var intakeChips: [String] {
        var out: [String] = []
        out.append(intake.work == "on_feet" ? "On my feet all day" : (intake.work == "manual" ? "Physical work" : "Desk job"))
        if intake.kids { out.append("Young kids") }
        switch intake.stress {
        case "high": out.append("High stress")
        case "low": out.append("Low stress")
        default: break
        }
        if intake.train != "none" { out.append("Trains \(intake.train)") }
        // Habits never asked the goal, so it is not something the person told us.
        if mode != .habits, intake.goal == "cut" { out.append("Fat loss") }
        return out
    }

    private var failed: some View {
        VStack(spacing: VoCalTheme.Spacing.l) {
            Text(mode == .habits ? "Couldn't set up your habits." : "Couldn't build your protocol.")
                .font(VoCalTheme.Fonts.primaryLabel)
                .foregroundStyle(VoCalTheme.Colors.ink)
            PillButton(title: "Try again") {
                phase = .building
                attempt += 1
            }
        }
        .padding(VoCalTheme.Spacing.xl)
    }
}

/// Wrapping chip row for the "built from what you told us" tags.
private struct SeenChipsRow: View {
    let items: [String]

    var body: some View {
        FlowLayout(spacing: VoCalTheme.Spacing.s) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(VoCalTheme.Fonts.formLabel.weight(.semibold))
                    .foregroundStyle(VoCalTheme.Colors.ink)
                    .padding(.horizontal, VoCalTheme.Spacing.m)
                    .padding(.vertical, VoCalTheme.Spacing.s)
                    .background(VoCalTheme.Colors.softFill, in: Capsule())
                    .overlay(Capsule().strokeBorder(VoCalTheme.Colors.goldBorder, lineWidth: 1.5))
            }
        }
    }
}

/// Minimal left-to-right wrapping layout (chips flow onto new rows as width runs out).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

#Preview("The five") {
    ProtocolRevealView(intake: IntakeDraft().profile, onContinue: {}, service: MockProtocolService(latency: .milliseconds(100)))
}

#Preview("Habits") {
    ProtocolRevealView(intake: IntakeDraft().profile, mode: .habits, onContinue: {}, service: MockProtocolService(latency: .milliseconds(100)))
}
