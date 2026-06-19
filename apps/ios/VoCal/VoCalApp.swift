import SwiftUI
import VoCalCore

@main
struct VoCalApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Lane bookkeeping only — must stay this thin. The voice coordinator bootstraps
        // lazily on scene-active/toggle so nothing (recovery scan, outbox open, telemetry)
        // sits in front of app launch or the mic-hot path (capture-path isolation,
        // Vo-Cal AGENTS.md; Serein paid three production incidents for eager launch work).
        AppRuntimeCoordinator.shared.observeLaunch()

        // C3 self-test entry (launch-argument form). startIfRequested self-gates on
        // `--self-test-run-id` — it is a no-op on every normal launch, so it stays off
        // the capture path entirely (Vo-Cal AGENTS.md capture-path isolation). The flag,
        // not a URL, is the primary mechanism so bin/ios-sim-voice-test needs no
        // CFBundleURLTypes round-trip through SpringBoard. (URL form below is parity with
        // Serein's serein://self-test for manual/interactive runs.)
        VoiceSelfTestRuntime.shared.startIfRequested()
    }

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .onOpenURL { url in
                    // vocal://self-test/voice?run_id=…&scenarios=… — manual self-test
                    // trigger. handleOpenURL ignores anything that is not the self-test
                    // host, so registering the scheme costs the capture path nothing.
                    VoiceSelfTestRuntime.shared.handleOpenURL(url)
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            AppRuntimeCoordinator.shared.publish(.scenePhaseChanged(AppScenePhaseValue(newPhase)))
            if AppRuntimeCoordinator.shared.shouldRunForegroundShellTasks() {
                // Scene-active drives the crash-recovery scan (Serein wiring preserved):
                // recovery runs on activation observations, never on the capture start path.
                Task {
                    await VoiceCaptureCoordinator.shared.handleScenePhaseChange(newPhase)
                }
            }
        }
    }
}

/// Tab shell + floating mic button (reference layout: Home / Settings tabs with
/// a black circular + action bottom-right). Placeholders are replaced by their
/// phases: Today (E1), Voice log (D0), Settings (I2).
struct AppRootView: View {
    @State private var showVoiceLog = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            TabView {
                Tab("Today", systemImage: "house") {
                    TodayPlaceholderView()
                        .accessibilityIdentifier(A11y.Root.todayTab)
                }
                Tab("Settings", systemImage: "gearshape") {
                    SettingsPlaceholderView()
                        .accessibilityIdentifier(A11y.Root.settingsTab)
                }
            }
            .tint(VoCalTheme.Colors.ink)

            Button {
                showVoiceLog = true
            } label: {
                Image(systemName: "mic.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(VoCalTheme.Colors.onCta)
                    .frame(width: 56, height: 56)
                    .background(VoCalTheme.Colors.cta, in: Circle())
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            }
            .accessibilityIdentifier(A11y.Root.micButton)
            .accessibilityLabel("Log a meal by voice")
            .padding(.trailing, VoCalTheme.Spacing.xl)
            .padding(.bottom, 64)
        }
        .fullScreenCover(isPresented: $showVoiceLog) {
            // Meal-type-first (DESIGN.md decisions #41–43): pick the meal, then auto-advance
            // into the voice capture with the meal type pre-set and never re-asked.
            MealLogFlowView()
        }
    }
}

/// Meal picker -> voice log. Tap Log -> choose Breakfast/Lunch/Dinner/Snack -> the chosen
/// type is passed straight into VoiceLogView (meal type pre-set, per the prototype flow).
struct MealLogFlowView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var pickedMealType: MealType?

    var body: some View {
        if let pickedMealType {
            VoiceLogView(mealType: pickedMealType, onLogged: nil)
        } else {
            MealTypePickerView(
                onPick: { pickedMealType = $0 },
                onCancel: { dismiss() }
            )
        }
    }
}

/// Breakfast/Lunch/Dinner/Snack tiles. The center Log action lands here first.
struct MealTypePickerView: View {
    var onPick: (MealType) -> Void
    var onCancel: () -> Void

    private let options: [(MealType, String, String)] = [
        (.breakfast, "Breakfast", "sun.horizon.fill"),
        (.lunch, "Lunch", "carrot.fill"),
        (.dinner, "Dinner", "fork.knife"),
        (.snack, "Snack", "applelogo"),
    ]

    var body: some View {
        ZStack(alignment: .topLeading) {
            VoCalTheme.Colors.background.ignoresSafeArea()
            VStack(alignment: .leading, spacing: VoCalTheme.Spacing.l) {
                Text("Log a meal")
                    .font(VoCalTheme.Fonts.screenTitle)
                    .foregroundStyle(VoCalTheme.Colors.ink)
                Text("Pick the meal \u{2014} then just talk.")
                    .font(VoCalTheme.Fonts.secondaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: VoCalTheme.Spacing.m) {
                    ForEach(options, id: \.0) { type, label, glyph in
                        Button {
                            onPick(type)
                        } label: {
                            VStack(spacing: VoCalTheme.Spacing.s) {
                                Image(systemName: glyph)
                                    .font(.system(size: 28, weight: .semibold))
                                    .foregroundStyle(VoCalTheme.Colors.ink)
                                Text(label)
                                    .font(VoCalTheme.Fonts.primaryLabel)
                                    .foregroundStyle(VoCalTheme.Colors.ink)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, VoCalTheme.Spacing.xl)
                            .background(
                                VoCalTheme.Colors.card,
                                in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.card, style: .continuous)
                            )
                        }
                        .accessibilityIdentifier("voicelog.meal-type.\(type.rawValue)")
                    }
                }
                Spacer()
            }
            .padding(VoCalTheme.Spacing.l)
            .padding(.top, 48)

            Button {
                onCancel()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(VoCalTheme.Colors.ink)
                    .frame(width: 36, height: 36)
                    .background(VoCalTheme.Colors.card, in: Circle())
            }
            .padding(VoCalTheme.Spacing.l)
            .accessibilityLabel("Close")
        }
    }
}

struct TodayPlaceholderView: View {
    var body: some View {
        ZStack {
            VoCalTheme.Colors.background.ignoresSafeArea()
            VStack(spacing: VoCalTheme.Spacing.l) {
                StatCard {
                    VStack(alignment: .leading, spacing: VoCalTheme.Spacing.s) {
                        Text("Calories left")
                            .font(VoCalTheme.Fonts.secondaryLabel)
                            .foregroundStyle(VoCalTheme.Colors.muted)
                        Text("—")
                            .font(VoCalTheme.Fonts.numeral())
                            .foregroundStyle(VoCalTheme.Colors.ink)
                            .accessibilityIdentifier(A11y.Today.caloriesLeft)
                    }
                }
                Text("Today dashboard lands in Phase E.")
                    .font(VoCalTheme.Fonts.secondaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
            }
            .padding(VoCalTheme.Spacing.l)
        }
    }
}

struct SettingsPlaceholderView: View {
    var body: some View {
        ZStack {
            VoCalTheme.Colors.background.ignoresSafeArea()
            Text("Settings lands in Phases F (sign out) and I (account deletion).")
                .font(VoCalTheme.Fonts.secondaryLabel)
                .foregroundStyle(VoCalTheme.Colors.muted)
                .padding(VoCalTheme.Spacing.xl)
        }
    }
}

#Preview {
    AppRootView()
}
