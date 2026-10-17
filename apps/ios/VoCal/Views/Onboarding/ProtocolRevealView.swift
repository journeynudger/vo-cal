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
    /// Back to the intake's last screen, with every answer kept, offered when the build failed
    /// (the 2026-10-16 audit, A12: one button that fails again is not a way back).
    var onBack: (() -> Void)?
    var service: any ProtocolService
    /// Spec R12's two variants of the habits reveal: (a) the water and produce counts shown,
    /// the app's default; (b) the three habits with no counts, first seen on Today. Both are
    /// drawn by the render loop so the decision is made from screens, not from the document.
    var habitCounts: Bool

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
        /// `offline` when the failure was the network's, so the screen can say so instead of
        /// blaming the build.
        case failed(offline: Bool)
    }

    init(
        intake: IntakeProfile,
        mode: TrackingMode = .method,
        onContinue: @escaping () -> Void,
        onBack: (() -> Void)? = nil,
        service: (any ProtocolService)? = nil,
        /// Renders and previews start from a phase; the app starts building.
        phase: Phase = .building,
        habitCounts: Bool = true
    ) {
        self.intake = intake
        self.mode = mode
        self.onContinue = onContinue
        self.onBack = onBack
        self.service = service ?? (RuntimeMode.usesMockServices ? MockProtocolService() : LiveProtocolService())
        self.habitCounts = habitCounts
        _phase = State(initialValue: phase)
    }

    var body: some View {
        ZStack {
            VoCalTheme.Colors.background.ignoresSafeArea()
            switch phase {
            case .building: building
            case let .ready(generated): reveal(generated)
            case let .failed(offline): failed(offline: offline)
            }
        }
        .task(id: attempt) {
            guard case .building = phase else { return }
            do {
                let generated = try await service.generate(from: intake, mode: mode)
                phase = .ready(generated)
            } catch {
                phase = .failed(offline: error is URLError)
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
        case .calories: calorieLine
        case .macros: "\(calorieLine) · splitting protein, carbs and fat"
        case .method, .mealPlan: "\(calorieLine) · scaling protein, fat, water and fiber"
        }
    }

    /// What the engine does with the calories for this goal (engine.py: a deficit for a cut,
    /// nothing for maintain, a small surplus for gain). "Placing your deficit" was false for
    /// two goals in three (the 2026-10-16 audit, A4).
    private var calorieLine: String {
        switch intake.goal {
        case "maintain": "Setting your maintenance calories"
        case "gain": "Placing your surplus"
        default: "Placing your deficit"
        }
    }

    private func reveal(_ generated: GeneratedProtocol) -> some View {
        let t = generated.targets
        // A server that predates `reveal` falls back by mode, never to a list with calories in
        // it for a person who chose none (the audit, A15).
        let keys = generated.reveal.isEmpty ? MockProtocolService.reveal(for: mode) : generated.reveal
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

                    // The one habit the plan rests on (decision 69, spec 6.7): said once, at the
                    // moment of highest motivation, asking nothing. Burke, Wang and Sevick 2011:
                    // self-monitoring is the behavior that predicts the outcome.
                    Text(mode == .habits
                         ? "Say what you eat and they count themselves."
                         : "Everything here follows from one habit: say what you eat.")
                        .font(VoCalTheme.Fonts.secondaryLabel)
                        .foregroundStyle(VoCalTheme.Colors.ink)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(A11y.Intake.revealHabitLine)

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

                    // The one canonical sentence (PROTOCOL_LOGIC §9), the same as the intake's first
                    // step: two texts for one meaning were two (the audit, A19).
                    Text("Vo-Cal provides general nutrition information and is not medical advice. Consult a physician before changing your diet, especially if you are pregnant, nursing, under 18, or have a medical condition or history of disordered eating.")
                        .font(VoCalTheme.Fonts.formLabel)
                        .foregroundStyle(VoCalTheme.Colors.muted)
                        .padding(VoCalTheme.Spacing.m)
                        .background(VoCalTheme.Colors.card, in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.chip, style: .continuous))
                        .padding(.top, VoCalTheme.Spacing.s)
                }
                .padding(.horizontal, VoCalTheme.Spacing.l)
                .padding(.bottom, VoCalTheme.Spacing.xl)
            }
            // In meal-plan mode the plan builder is the next step, so the pill says so instead
            // of promising logging the person is one screen away from (a claim above the state).
            // "Save" names the next screen's job (the account keeps it); "start logging" was two
            // screens away and "Saved" needs a receipt (A7).
            PillButton(title: continueTitle, action: onContinue)
                .padding(VoCalTheme.Spacing.l)
        }
    }

    private var continueTitle: String {
        switch mode {
        case .mealPlan: "Build my meal plan"
        case .habits: "Save my habits"
        default: "Save my protocol"
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
            targetRow("Water", value: habitValue("\(t.waterOz) oz"), color: VoCalTheme.Colors.muted, whyKey: key, whys: t.whys)
        case "fiber":
            targetRow("Fiber", value: "\(t.fiber) g", color: VoCalTheme.Colors.muted, whyKey: key, whys: t.whys)
        case "produce":
            targetRow("Produce", value: habitValue("\(t.produceServings) a day"), color: VoCalTheme.Colors.muted, whyKey: key, whys: t.whys)
        case "carbs":
            targetRow("Carbs", value: "\(t.carbs) g", color: VoCalTheme.Colors.carbs, whyKey: key, whys: t.whys)
        case "fat":
            targetRow("Fat", value: "\(t.fat) g", color: VoCalTheme.Colors.fats, whyKey: key, whys: t.whys)
        default:
            EmptyView()
        }
    }

    /// A habit's count, or nothing in variant b (R12): the row keeps its name and its why.
    private func habitValue(_ count: String) -> String {
        mode == .habits && !habitCounts ? "" : count
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
        // The answer in the person's words, never the enum's value ("Trains light"; A6).
        switch intake.train {
        case "light": out.append("Light training")
        case "moderate": out.append("Moderate training")
        case "heavy": out.append("Heavy training")
        default: break
        }
        // Habits never asked the goal, so it is not something the person told us.
        if mode != .habits, intake.goal == "cut" { out.append("Fat loss") }
        return out
    }

    private func failed(offline: Bool) -> some View {
        VStack(spacing: VoCalTheme.Spacing.l) {
            VStack(spacing: VoCalTheme.Spacing.s) {
                Text(mode == .habits ? "Couldn't set up your habits." : "Couldn't build your protocol.")
                    .font(VoCalTheme.Fonts.primaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.ink)
                // The honest reason where it is known; the answers are kept either way.
                Text(offline ? "You're offline. Your answers are kept." : "Your answers are kept.")
                    .font(VoCalTheme.Fonts.secondaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
            }
            .multilineTextAlignment(.center)
            PillButton(title: "Try again") {
                phase = .building
                attempt += 1
            }
            if let onBack {
                VoCalButton(title: "Back to my answers", kind: .tertiary, action: onBack)
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
