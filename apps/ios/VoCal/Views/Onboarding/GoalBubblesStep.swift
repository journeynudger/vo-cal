import SwiftUI

// The bubbles (2026-11-06, Lorenzo: "the onboarding should have the bubbles"; the reference
// is the Areela keynote, where a client taps the areas that matter and each tap grows a
// bubble, the biggest being the priority). Here the bubbles decide three things the intake
// used to ask as lists: how the person wants to follow their nutrition (the mode, decision
// 57), the goal the engine prescribes against (cut, maintain, gain), and a metric to show
// beside the mode's own (the hormone bubble adds the fat tile; decision 30). Nothing is
// preselected; a person who grows nothing gets the five, maintaining, and may still change
// the mode on the next screen. The derivation is a pure function (`GoalPriorities.derived`)
// so a render test can pin it.

/// What matters to the person, in their own words. The order is the cloud's order.
enum GoalPriority: String, CaseIterable, Identifiable, Codable, Sendable {
    case loseFat = "lose_fat"
    case buildMuscle = "build_muscle"
    case moreEnergy = "more_energy"
    case sleepBetter = "sleep_better"
    case eatEnough = "eat_enough"
    case healthierHabits = "healthier_habits"
    case hormones
    case liveLonger = "live_longer"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .loseFat: "Lose fat"
        case .buildMuscle: "Build muscle"
        case .moreEnergy: "More energy"
        case .sleepBetter: "Sleep better"
        case .eatEnough: "Eat enough"
        case .healthierHabits: "Healthier habits"
        case .hormones: "Hormones"
        case .liveLonger: "Live longer"
        }
    }

    /// Where the bubble rests in the cloud before the sizes push it around, in unit
    /// coordinates of the cloud's frame. Spread so the eight read as a cloud, not a grid.
    var anchor: CGPoint {
        switch self {
        case .loseFat: CGPoint(x: 0.28, y: 0.22)
        case .buildMuscle: CGPoint(x: 0.72, y: 0.18)
        case .moreEnergy: CGPoint(x: 0.5, y: 0.42)
        case .sleepBetter: CGPoint(x: 0.2, y: 0.55)
        case .eatEnough: CGPoint(x: 0.8, y: 0.5)
        case .healthierHabits: CGPoint(x: 0.34, y: 0.82)
        case .hormones: CGPoint(x: 0.68, y: 0.8)
        case .liveLonger: CGPoint(x: 0.5, y: 0.9)
        }
    }
}

/// The sizes the person gave each bubble: 0 (not chosen) to 3 (the most). A tap grows one
/// by a step; a tap on the biggest lets it go.
struct GoalPriorities: Equatable, Sendable {
    static let maxWeight = 3

    var weights: [GoalPriority: Int] = [:]

    func weight(of goal: GoalPriority) -> Int { weights[goal] ?? 0 }

    mutating func tap(_ goal: GoalPriority) {
        let current = weight(of: goal)
        weights[goal] = current >= Self.maxWeight ? 0 : current + 1
    }

    var isEmpty: Bool { weights.values.allSatisfy { $0 == 0 } }

    /// The chosen bubbles, biggest first, ties in the cloud's order.
    var ranked: [GoalPriority] {
        GoalPriority.allCases
            .filter { weight(of: $0) > 0 }
            .sorted { a, b in
                let wa = weight(of: a), wb = weight(of: b)
                if wa != wb { return wa > wb }
                return GoalPriority.allCases.firstIndex(of: a)! < GoalPriority.allCases.firstIndex(of: b)!
            }
    }

    /// What the bubbles decide for the intake. The mode follows the biggest bubble; the goal
    /// follows which of fat loss and muscle is bigger; the focus adds the one tile a bubble
    /// asks for beyond the mode's own.
    struct Derived: Equatable, Sendable {
        var mode: TrackingMode
        var goal: String
        var focus: [FocusMetric]
    }

    var derived: Derived {
        let fat = weight(of: .loseFat)
        let muscle = weight(of: .buildMuscle)
        let goal: String = fat > muscle ? "cut" : (muscle > fat ? "gain" : "maintain")
        var focus: [FocusMetric] = []
        if weight(of: .hormones) > 0 { focus.append(.fat) }
        let mode: TrackingMode
        switch ranked.first {
        case .healthierHabits?: mode = .habits
        case .buildMuscle?: mode = .macros
        case .eatEnough?: mode = .calories
        case .hormones?: mode = .calories
        case .loseFat?, .moreEnergy?, .sleepBetter?, .liveLonger?, nil: mode = .five
        }
        // A focus the mode already prints is not an addition.
        let own = PanelComposer.offerableFocus(for: mode)
        return Derived(mode: mode, goal: goal, focus: focus.filter { own.contains($0) })
    }

    /// One sentence the next screen opens with, naming what was tapped (never a kind of
    /// person): "Fat loss first, then sleep."
    var sentence: String? {
        let top = ranked.prefix(2).map { $0.title.lowercased() }
        guard let first = top.first else { return nil }
        let lead = first.prefix(1).uppercased() + first.dropFirst()
        return top.count > 1 ? "\(lead) first, then \(top[1])." : "\(lead) first."
    }

    // MARK: Persistence (the phone's, for the home's one line)

    static let storageKey = "vocal.priorities"

    func save(to defaults: UserDefaults = .standard) {
        let raw = weights.filter { $0.value > 0 }.reduce(into: [String: Int]()) { $0[$1.key.rawValue] = $1.value }
        defaults.set(raw, forKey: Self.storageKey)
    }

    static func load(from defaults: UserDefaults = .standard) -> GoalPriorities {
        let raw = defaults.dictionary(forKey: storageKey) as? [String: Int] ?? [:]
        var out = GoalPriorities()
        for (key, value) in raw {
            if let goal = GoalPriority(rawValue: key) { out.weights[goal] = min(max(value, 0), maxWeight) }
        }
        return out
    }
}

// MARK: - The cloud's geometry

/// Where each bubble sits for a set of weights: the anchors, then a few rounds of pushing
/// overlapping bubbles apart, pulling each back toward its anchor and keeping all inside the
/// frame. Deterministic (the same weights give the same cloud) and cheap (eight bubbles),
/// so the view can animate between two clouds with one spring.
enum BubbleCloud {
    static let minDiameter: CGFloat = 74
    static let step: CGFloat = 24
    static let padding: CGFloat = 6

    static func diameter(weight: Int) -> CGFloat {
        minDiameter + CGFloat(weight) * step
    }

    struct Placement: Equatable {
        var center: CGPoint
        var diameter: CGFloat
    }

    static func layout(_ priorities: GoalPriorities, in size: CGSize) -> [GoalPriority: Placement] {
        let goals = GoalPriority.allCases
        var centers = goals.map { CGPoint(x: $0.anchor.x * size.width, y: $0.anchor.y * size.height) }
        let anchors = centers
        let radii = goals.map { diameter(weight: priorities.weight(of: $0)) / 2 + padding }
        for _ in 0..<60 {
            for i in goals.indices {
                for j in goals.indices where j > i {
                    let dx = centers[j].x - centers[i].x
                    let dy = centers[j].y - centers[i].y
                    let distance = max(sqrt(dx * dx + dy * dy), 0.001)
                    let overlap = radii[i] + radii[j] - distance
                    guard overlap > 0 else { continue }
                    let push = overlap / 2
                    let ux = dx / distance, uy = dy / distance
                    centers[i].x -= ux * push
                    centers[i].y -= uy * push
                    centers[j].x += ux * push
                    centers[j].y += uy * push
                }
            }
            for i in goals.indices {
                // A gentle pull home keeps the cloud's shape; the walls keep it on screen.
                centers[i].x += (anchors[i].x - centers[i].x) * 0.08
                centers[i].y += (anchors[i].y - centers[i].y) * 0.08
                let r = radii[i] - padding
                centers[i].x = min(max(centers[i].x, r), size.width - r)
                centers[i].y = min(max(centers[i].y, r), size.height - r)
            }
        }
        var out: [GoalPriority: Placement] = [:]
        for (index, goal) in goals.enumerated() {
            out[goal] = Placement(center: centers[index], diameter: diameter(weight: priorities.weight(of: goal)))
        }
        return out
    }
}

// MARK: - The step

/// "What matters to you?": the cloud of bubbles and the one line under it. The intake's first
/// screen after the welcome; `IntakeFlowView` reads `priorities.derived` for the mode, the
/// goal and the focus the screens after it rely on.
struct GoalBubblesStep: View {
    @Binding var priorities: GoalPriorities

    var body: some View {
        VStack(alignment: .leading, spacing: VoCalTheme.Spacing.s) {
            Text("What matters").sectionHeader()
            Text("What matters to you?")
                .font(.system(size: 27, weight: .semibold))
                .foregroundStyle(VoCalTheme.Colors.ink)
            Text("Tap to grow a bubble. The bigger, the more it matters.")
                .font(VoCalTheme.Fonts.secondaryLabel)
                .foregroundStyle(VoCalTheme.Colors.muted)
            GoalBubbleCloud(priorities: $priorities)
                .frame(height: 372)
                .padding(.top, VoCalTheme.Spacing.s)
                .accessibilityIdentifier(A11y.Intake.priorities)
            Text(priorities.sentence ?? "Nothing yet. Tap what fits, or go on.")
                .font(VoCalTheme.Fonts.secondaryLabel)
                .foregroundStyle(VoCalTheme.Colors.ink)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: priorities)
                .accessibilityIdentifier(A11y.Intake.prioritiesLine)
        }
    }
}

/// The cloud: a bubble per goal, sized by its weight, placed by `BubbleCloud.layout`. Every
/// change moves the whole cloud with one spring; a tap ticks (`select`).
struct GoalBubbleCloud: View {
    @Binding var priorities: GoalPriorities
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let placements = BubbleCloud.layout(priorities, in: geo.size)
            ZStack {
                ForEach(GoalPriority.allCases) { goal in
                    if let placement = placements[goal] {
                        bubble(goal, weight: priorities.weight(of: goal))
                            .frame(width: placement.diameter, height: placement.diameter)
                            .position(placement.center)
                    }
                }
            }
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.78), value: priorities)
        }
    }

    private func bubble(_ goal: GoalPriority, weight: Int) -> some View {
        let chosen = weight > 0
        return Button {
            VoCalHaptics.select()
            priorities.tap(goal)
        } label: {
            Text(goal.title)
                .font(.system(size: chosen ? 15 + CGFloat(weight) : 14, weight: chosen ? .semibold : .medium))
                .foregroundStyle(chosen ? VoCalTheme.Colors.onCta : VoCalTheme.Colors.ink)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .padding(VoCalTheme.Spacing.s)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    Circle().fill(chosen ? VoCalTheme.Colors.cta : VoCalTheme.Colors.card)
                }
                .overlay {
                    Circle().strokeBorder(chosen ? VoCalTheme.Colors.gold.opacity(0.35 + 0.2 * Double(weight)) : VoCalTheme.Colors.goldBorder, lineWidth: chosen ? 2 : 1.5)
                }
                .shadow(color: .black.opacity(chosen ? 0.14 : 0.04), radius: chosen ? 14 : 6, y: 6)
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(goal.title)
        .accessibilityValue(chosen ? "size \(weight) of \(GoalPriorities.maxWeight)" : "not chosen")
        .accessibilityHint("Tap to grow")
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .accessibilityIdentifier(A11y.Intake.priority(goal.rawValue))
    }
}

#Preview("Nothing yet") {
    @Previewable @State var priorities = GoalPriorities()
    ZStack {
        VoCalTheme.Colors.background.ignoresSafeArea()
        GoalBubblesStep(priorities: $priorities).padding()
    }
}

#Preview("Fat loss first") {
    @Previewable @State var priorities = GoalPriorities(weights: [.loseFat: 3, .sleepBetter: 2, .hormones: 1])
    ZStack {
        VoCalTheme.Colors.background.ignoresSafeArea()
        GoalBubblesStep(priorities: $priorities).padding()
    }
}
