import SwiftUI

// Port provenance: Serein apps/ios/SereinApp/Sources/HomeTourKit.swift, itself a copy of Beacon
// apps/ios/Beacon/Views/Components/HelpTour.swift. The mechanism is kept exactly: targets
// report global frames through onGeometryChange, a step whose target has no frame is skipped,
// the scrim punches its cutout with destinationOut inside a compositing group, the card sits
// on the half of the screen the target is not, tapping the scrim advances, one spring.
// Renamed HomeTour to HelpTour; restyled to Vo-Cal's card and black pill; Beacon's per-step
// inset and cutout shape restored (Serein had dropped them); the step change answers the
// finger with VoCalHaptics.select().

// MARK: - Harness launches

/// Launches driven by a harness must never be covered by a first-run surface (this tour, the
/// Action button card, What's New): the UI tests and the accessibility audit land on Today and
/// would audit a scrim instead of the screen, and the voice self-test and the DEBUG screenshot
/// hooks would capture it. Serein learned this with its inspection screenshots
/// (HomeTourKit.swift, `autoStartEnabled`). A `-Show...` argument turns its own surface back on,
/// and clears that surface's seen flag once per launch, for that surface's own tests.
enum FirstRunHarness {
    static let showTourArgument = "-ShowTour"
    static let showWhatsNewArgument = "-ShowWhatsNew"

    static var isHarnessLaunch: Bool {
        RuntimeMode.isUITestMode
            // The voice self-test's launch flag (VoiceSelfTestRuntime, bin/ios-sim-voice-test).
            || ProcessInfo.processInfo.arguments.contains("--self-test-run-id")
            || RuntimeMode.startsOnSettingsTab
            || RuntimeMode.debugSettingsDestination != nil
            || RuntimeMode.showsWeekBudgetOnLaunch
    }

    static func forces(_ argument: String) -> Bool {
        ProcessInfo.processInfo.arguments.contains(argument)
    }
}

// MARK: - First-run flag

enum HelpTourFlags {
    static let hasSeenHomeTourKey = "vocal.tour.home.seen"

    static func hasSeenHomeTour(userDefaults: UserDefaults = .standard) -> Bool {
        _ = resetIfForced
        return userDefaults.bool(forKey: hasSeenHomeTourKey)
    }

    static func markHomeTourSeen(userDefaults: UserDefaults = .standard) {
        userDefaults.set(true, forKey: hasSeenHomeTourKey)
    }

    /// Settings' replay row calls this; the next Today appearance starts the tour again.
    static func reset(userDefaults: UserDefaults = .standard) {
        userDefaults.removeObject(forKey: hasSeenHomeTourKey)
    }

    /// False under `-UITestMode` (and the other harness launches) unless `-ShowTour` is passed.
    static var autoStartEnabled: Bool {
        FirstRunHarness.forces(FirstRunHarness.showTourArgument) || !FirstRunHarness.isHarnessLaunch
    }

    /// The one question the shell asks on Today's first appearance.
    static var shouldAutoStart: Bool {
        autoStartEnabled && !hasSeenHomeTour()
    }

    /// `-ShowTour` clears the seen flag once per launch, so tour tests behave the same on a
    /// fresh install and on a reused simulator, and the tour still ends once it is seen.
    private static let resetIfForced: Void = {
        if FirstRunHarness.forces(FirstRunHarness.showTourArgument) {
            reset()
        }
    }()
}

// MARK: - Step

/// The hole cut in the scrim around a target.
enum HelpTourCutout: Equatable, Sendable {
    /// Half the height is the radius: pills, the text field, a row of chips.
    case capsule
    /// A true circle around the target's center: round buttons.
    case circle
    /// A card's own corner radius; the cutout's padding is added so the corners stay concentric.
    case roundedRect(cornerRadius: CGFloat)
}

/// One stop on the tour: which control to spotlight and what to say about it. A scrim darkens
/// the whole screen except that control, a card explains it in plain words, and Next walks to
/// the following control.
struct HelpTourStep: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let body: String
    /// Shrinks the reported frame before the cutout is drawn, for a target whose laid-out frame
    /// is larger than its visible face (Beacon's ignite orb carried a 60 pt glow halo).
    var inset: CGFloat = 0
    var shape: HelpTourCutout = .capsule
}

extension HelpTourStep {
    /// Today's tour. The shell tags each control with `.helpTourTarget(HelpTourStep.Home.mic,
    /// in: tour)`; a step whose control is not on screen is skipped, so a step can be declared
    /// before its control ships. Voice first, because it is the fastest way in; the other two
    /// ways next; then the plan, the day and the week. Short sentences, one detail each that
    /// the control does not show by itself.
    enum Home {
        static let mic = "home.mic"
        static let text = "home.text"
        static let photo = "home.photo"
        static let profile = "home.profile"
        static let calories = "home.calories"
        static let week = "home.week"

        static let steps: [HelpTourStep] = [
            HelpTourStep(
                id: mic,
                title: "Say what you ate",
                body: "Tap the mic and talk. Amounts help, like two eggs or a cup of rice.",
                shape: .circle
            ),
            HelpTourStep(
                id: text,
                title: "Or type it",
                body: "Somewhere you cannot talk? Type what you ate here and send it."
            ),
            HelpTourStep(
                id: photo,
                title: "Or snap it",
                body: "Take a photo of your plate. Vo-Cal asks about what a photo cannot show.",
                shape: .circle
            ),
            HelpTourStep(
                id: profile,
                title: "Your plan",
                body: "Your targets and settings live here.",
                shape: .circle
            ),
            HelpTourStep(
                id: calories,
                title: "Your day",
                body: "What you have left for today. With Apple Health connected, what you burned sits beside it.",
                shape: .roundedRect(cornerRadius: VoCalTheme.Radius.card)
            ),
            HelpTourStep(
                id: week,
                title: "Your week",
                body: "Tap a day to see what you logged. Pull the strip sideways for earlier weeks.",
                shape: .roundedRect(cornerRadius: VoCalTheme.Radius.chip)
            ),
        ]
    }
}

// MARK: - Model

/// Drives the tour: collects target frames (global coordinates) from tagged views and tracks
/// which step is showing. Steps whose target is not on screen right now are skipped, never
/// shown pointing at empty space. State only; the overlay renders it and plays the haptic.
@MainActor
@Observable
final class HelpTourModel {
    let steps: [HelpTourStep]
    /// Target frames in global coordinates, keyed by step id, written by `.helpTourTarget`.
    var frames: [String: CGRect] = [:]
    private(set) var activeStepID: String?

    init(steps: [HelpTourStep] = HelpTourStep.Home.steps) {
        self.steps = steps
    }

    var isActive: Bool {
        activeStepID != nil
    }

    /// The declared steps whose targets are laid out right now, in order.
    var visibleSteps: [HelpTourStep] {
        steps.filter { frames[$0.id] != nil }
    }

    var activeIndex: Int? {
        guard let activeStepID else {
            return nil
        }
        return visibleSteps.firstIndex { $0.id == activeStepID }
    }

    var activeStep: HelpTourStep? {
        guard let activeIndex else {
            return nil
        }
        return visibleSteps[activeIndex]
    }

    var isLastStep: Bool {
        guard let activeIndex else {
            return true
        }
        return activeIndex == visibleSteps.count - 1
    }

    func start() {
        activeStepID = visibleSteps.first?.id
    }

    /// Starts once every declared target has reported its frame, or after `timeout` with
    /// whatever is on screen. Serein's lesson (2026-09): straight out of onboarding the controls
    /// report their frames in no fixed order, and starting on the first report opened the tour
    /// on step two. A cancelled task (the screen went away) returns without starting.
    func startWhenReady(timeout: Duration = .seconds(2)) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while visibleSteps.count < steps.count, clock.now < deadline {
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
        }
        start()
    }

    func next() {
        guard let activeIndex else {
            finish()
            return
        }
        let following = activeIndex + 1
        if following < visibleSteps.count {
            activeStepID = visibleSteps[following].id
        } else {
            finish()
        }
    }

    func back() {
        guard let activeIndex, activeIndex > 0 else {
            return
        }
        activeStepID = visibleSteps[activeIndex - 1].id
    }

    func finish() {
        activeStepID = nil
    }
}

// MARK: - Target tagging

private struct HelpTourTarget: ViewModifier {
    let id: String
    let model: HelpTourModel
    /// `onGeometryChange` fires only when geometry changes, so a target that was covered (a
    /// sheet, a push) and revealed again gets no new callback; `onAppear` restores the last
    /// frame instead.
    @State private var lastFrame: CGRect?

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .global)
            } action: { frame in
                lastFrame = frame
                model.frames[id] = frame
            }
            .onAppear {
                if let lastFrame {
                    model.frames[id] = lastFrame
                }
            }
            // A vanished target must fall out of the tour (visibleSteps filters on frames),
            // not keep its old spot and spotlight empty space.
            .onDisappear {
                model.frames[id] = nil
            }
    }
}

extension View {
    /// Registers this view as the spotlight target for the tour step `id`.
    func helpTourTarget(_ id: String, in model: HelpTourModel) -> some View {
        modifier(HelpTourTarget(id: id, model: model))
    }

    /// The same, for a view that may live outside any tour (previews, render tests, the
    /// capture bar when no tour is running): no model, no registration.
    @ViewBuilder
    func helpTourTarget(_ id: String, in model: HelpTourModel?) -> some View {
        if let model {
            helpTourTarget(id, in: model)
        } else {
            self
        }
    }
}

// MARK: - Overlay

/// Full-screen scrim with the active step's control cut out, a gold ring around it, and a card
/// explaining it with Back and Next. Blocks every touch beneath it, the spotlit control
/// included, so nothing can be triggered mid tour; tapping the scrim advances, same as Next.
/// Renders nothing and takes no touches while the tour is not active, so the shell may keep
/// it mounted as an overlay.
struct HelpTourOverlay: View {
    let model: HelpTourModel

    /// Air between the control's edge and the cutout.
    private let cutoutPadding: CGFloat = 8
    /// Air between the cutout and the card.
    private let cardGap: CGFloat = 22
    private let stepAnimation = Animation.spring(response: 0.35, dampingFraction: 0.85)

    var body: some View {
        GeometryReader { geo in
            if let step = model.activeStep, let globalFrame = model.frames[step.id] {
                let origin = geo.frame(in: .global).origin
                let growth = cutoutPadding - step.inset
                let target = Self.cutoutRect(
                    for: step.shape,
                    around: globalFrame
                        .offsetBy(dx: -origin.x, dy: -origin.y)
                        .insetBy(dx: -growth, dy: -growth)
                )
                let radius = Self.cornerRadius(for: step.shape, cutout: target, growth: growth)

                ZStack {
                    scrim(cutout: target, cornerRadius: radius)

                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .stroke(VoCalTheme.Colors.gold, lineWidth: 1.5)
                        .shadow(color: VoCalTheme.Colors.gold.opacity(0.6), radius: 8)
                        .frame(width: target.width, height: target.height)
                        .position(x: target.midX, y: target.midY)
                        .allowsHitTesting(false)

                    card(for: step, target: target, container: geo.size)
                }
                .animation(stepAnimation, value: model.activeStepID)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(model.isActive)
        // Every step change answers the finger once, whether it came from Next, Back or the
        // scrim; played here so the model stays state only.
        .onChange(of: model.activeStepID, initial: true) { _, stepID in
            if stepID != nil {
                VoCalHaptics.select()
            }
        }
    }

    /// The dimming layer with the spotlight punched out via `.destinationOut`. The cutout is
    /// visual only: the whole layer stays hittable.
    private func scrim(cutout: CGRect, cornerRadius: CGFloat) -> some View {
        Color.black.opacity(0.72)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .frame(width: cutout.width, height: cutout.height)
                    .position(x: cutout.midX, y: cutout.midY)
                    .blendMode(.destinationOut)
            )
            .compositingGroup()
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(stepAnimation) {
                    model.next()
                }
            }
            .accessibilityHidden(true)
    }

    private func card(for step: HelpTourStep, target: CGRect, container: CGSize) -> some View {
        // The card goes on whichever half of the screen the control is not.
        let placeBelow = target.midY < container.height / 2

        return VStack(alignment: .leading, spacing: VoCalTheme.Spacing.s) {
            Text(step.title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(VoCalTheme.Colors.ink)
                .padding(.trailing, 36)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(A11y.HelpTour.title)

            Text(step.body)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(VoCalTheme.Colors.muted)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: VoCalTheme.Spacing.s) {
                backButton

                Spacer(minLength: 0)

                if let index = model.activeIndex {
                    Text("\(index + 1) of \(model.visibleSteps.count)")
                        .font(.system(size: 13, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(VoCalTheme.Colors.muted)
                        .accessibilityIdentifier(A11y.HelpTour.stepLabel)
                }

                Spacer(minLength: 0)

                nextButton
            }
            .padding(.top, VoCalTheme.Spacing.xs)
        }
        .padding(20)
        .frame(maxWidth: 360, alignment: .leading)
        .background(
            VoCalTheme.Colors.card,
            in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.card, style: .continuous)
        )
        .overlay(alignment: .topTrailing) {
            closeButton
                .padding(6)
        }
        .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier(A11y.HelpTour.card)
        .padding(.horizontal, VoCalTheme.Spacing.xl)
        .padding(.top, placeBelow ? target.maxY + cardGap : 0)
        .padding(.bottom, placeBelow ? 0 : container.height - target.minY + cardGap)
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: placeBelow ? .top : .bottom
        )
    }

    private var closeButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) {
                model.finish()
            }
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(VoCalTheme.Colors.muted)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("Close tour")
        .accessibilityIdentifier(A11y.HelpTour.closeButton)
    }

    private var backButton: some View {
        let isFirstStep = (model.activeIndex ?? 0) == 0
        return Button {
            withAnimation(stepAnimation) {
                model.back()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                Text("Back")
            }
            .font(VoCalTheme.Fonts.buttonLabel)
            .foregroundStyle(VoCalTheme.Colors.muted)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .opacity(isFirstStep ? 0 : 1)
        .disabled(isFirstStep)
        .accessibilityHidden(isFirstStep)
        .accessibilityIdentifier(A11y.HelpTour.backButton)
    }

    private var nextButton: some View {
        Button {
            withAnimation(stepAnimation) {
                model.next()
            }
        } label: {
            HStack(spacing: 4) {
                Text(model.isLastStep ? "Done" : "Next")
                if !model.isLastStep {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            .font(VoCalTheme.Fonts.buttonLabel)
            .foregroundStyle(VoCalTheme.Colors.onCta)
            .padding(.horizontal, 20)
            .frame(minHeight: 44)
            .background(VoCalTheme.Colors.cta, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityIdentifier(A11y.HelpTour.nextButton)
    }

    /// A circle cutout is a square around the target's center, so a round button is circled
    /// even when its laid-out frame is not square; every other shape keeps the padded frame.
    private static func cutoutRect(for shape: HelpTourCutout, around frame: CGRect) -> CGRect {
        guard shape == .circle else {
            return frame
        }
        let side = max(frame.width, frame.height)
        return CGRect(x: frame.midX - side / 2, y: frame.midY - side / 2, width: side, height: side)
    }

    private static func cornerRadius(for shape: HelpTourCutout, cutout: CGRect, growth: CGFloat) -> CGFloat {
        let limit = min(cutout.width, cutout.height) / 2
        switch shape {
        case .capsule, .circle:
            return limit
        case let .roundedRect(cornerRadius):
            return min(max(0, cornerRadius + growth), limit)
        }
    }
}

// MARK: - Accessibility identifiers

extension A11y {
    enum HelpTour {
        static let card = "helptour.card"
        static let title = "helptour.title"
        static let stepLabel = "helptour.step-label"
        static let backButton = "helptour.back-button"
        static let nextButton = "helptour.next-button"
        static let closeButton = "helptour.close-button"
    }
}

#Preview("Help tour") {
    @Previewable @State var tour = HelpTourModel()

    ZStack {
        VoCalTheme.Colors.background.ignoresSafeArea()

        VStack(spacing: VoCalTheme.Spacing.l) {
            HStack {
                Spacer()
                Circle()
                    .fill(VoCalTheme.Colors.card)
                    .frame(width: 44, height: 44)
                    .helpTourTarget(HelpTourStep.Home.profile, in: tour)
            }
            RoundedRectangle(cornerRadius: VoCalTheme.Radius.card, style: .continuous)
                .fill(VoCalTheme.Colors.card)
                .frame(height: 180)
                .helpTourTarget(HelpTourStep.Home.calories, in: tour)
            Spacer()
            HStack(spacing: VoCalTheme.Spacing.s) {
                Circle()
                    .fill(VoCalTheme.Colors.card)
                    .frame(width: 48, height: 48)
                    .helpTourTarget(HelpTourStep.Home.photo, in: tour)
                Capsule()
                    .fill(VoCalTheme.Colors.card)
                    .frame(height: 48)
                    .helpTourTarget(HelpTourStep.Home.text, in: tour)
                Circle()
                    .fill(VoCalTheme.Colors.cta)
                    .frame(width: 56, height: 56)
                    .helpTourTarget(HelpTourStep.Home.mic, in: tour)
            }
        }
        .padding(VoCalTheme.Spacing.l)

        HelpTourOverlay(model: tour)
    }
    .task {
        await tour.startWhenReady()
    }
}
