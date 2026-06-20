import SwiftUI
import VoCalCore

/// F5 — the protocol reveal. Generates targets from the intake (mock on the sim path) behind a
/// brief "building…" beat, then shows the daily-calorie hero, the four home pillars
/// (protein/water/fiber/produce) each with a tap-to-expand "why", the "built from what you told
/// us" chips, and the not-medical-advice disclaimer. Black/gold, VoCalTheme only.
struct ProtocolRevealView: View {
    let intake: IntakeProfile
    var onContinue: () -> Void
    var service: any ProtocolService = RuntimeMode.usesMockServices
        ? MockProtocolService() : LiveProtocolService()

    @State private var phase: Phase = .building
    @State private var expanded: Set<String> = []

    enum Phase: Equatable {
        case building
        case ready(ProtocolTargets)
        case failed
    }

    var body: some View {
        ZStack {
            VoCalTheme.Colors.background.ignoresSafeArea()
            switch phase {
            case .building: building
            case let .ready(targets): reveal(targets)
            case .failed: failed
            }
        }
        .task {
            guard case .building = phase else { return }
            do {
                let targets = try await service.generate(from: intake)
                phase = .ready(targets)
            } catch {
                phase = .failed
            }
        }
    }

    private var building: some View {
        VStack(spacing: VoCalTheme.Spacing.l) {
            VoCalLoader(size: 48)
            Text("Building your protocol\u{2026}")
                .font(VoCalTheme.Fonts.primaryLabel)
                .foregroundStyle(VoCalTheme.Colors.ink)
            Text("Placing your deficit · scaling protein, water & fiber")
                .font(VoCalTheme.Fonts.formLabel)
                .foregroundStyle(VoCalTheme.Colors.muted)
        }
        .padding(VoCalTheme.Spacing.xl)
    }

    private func reveal(_ t: ProtocolTargets) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: VoCalTheme.Spacing.l) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your protocol").sectionHeader()
                        Text("Here's your starting point.")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(VoCalTheme.Colors.ink)
                    }
                    .padding(.top, VoCalTheme.Spacing.xl)

                    // Calorie hero
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

                    // Pillars with expandable why
                    VStack(spacing: 0) {
                        targetRow("Protein", value: "\(t.protein) g", color: VoCalTheme.Colors.protein, whyKey: "protein", whys: t.whys)
                        divider
                        targetRow("Water", value: "\(t.waterOz) oz", color: VoCalTheme.Colors.muted, whyKey: "water", whys: t.whys)
                        divider
                        targetRow("Fiber", value: "\(t.fiber) g", color: VoCalTheme.Colors.muted, whyKey: "fiber", whys: t.whys)
                        divider
                        targetRow("Produce", value: "\(t.produceServings) / day", color: VoCalTheme.Colors.muted, whyKey: "produce", whys: t.whys)
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
        if intake.goal == "cut" { out.append("Fat loss") }
        return out
    }

    private var failed: some View {
        VStack(spacing: VoCalTheme.Spacing.l) {
            Text("Couldn't build your protocol.")
                .font(VoCalTheme.Fonts.primaryLabel)
                .foregroundStyle(VoCalTheme.Colors.ink)
            PillButton(title: "Try again") { phase = .building }
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
                    .background(VoCalTheme.Colors.card, in: Capsule())
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

#Preview {
    ProtocolRevealView(intake: IntakeDraft().profile, onContinue: {}, service: MockProtocolService(latency: .milliseconds(100)))
}
