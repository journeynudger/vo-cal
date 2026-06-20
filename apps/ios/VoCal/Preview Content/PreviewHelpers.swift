#if DEBUG
import SwiftUI

/// Centralized factories for SwiftUI previews (Beacon's `PreviewHelpers` pattern): each screen
/// gets a ready-made, mock-backed view model so previews are one-liners and stay in sync as the
/// VMs evolve. DEBUG-only — never compiled into a shipping build.
@MainActor
enum PreviewHelpers {
    // Today
    static var todayPopulated: TodayViewModel {
        TodayViewModel(service: MockTodayService(scenario: .populated), checkin: MockCheckinService(due: false))
    }
    static var todayEmpty: TodayViewModel {
        TodayViewModel(service: MockTodayService(scenario: .empty), checkin: MockCheckinService(due: false))
    }
    static var todayCheckinDue: TodayViewModel {
        TodayViewModel(service: MockTodayService(scenario: .populated), checkin: MockCheckinService(due: true))
    }

    // Voice log
    static func voiceLog(_ scenario: MockCaptureScenario = .beefAndRice) -> VoiceLogViewModel {
        VoiceLogViewModel(mealType: .lunch, useMock: true, mockScenario: scenario)
    }

    // Check-in
    static var checkin: CheckInViewModel {
        CheckInViewModel(service: MockCheckinService())
    }
}

extension View {
    /// Frame a preview in the app background, so previews read true to the running app.
    func previewScreen() -> some View {
        ZStack {
            VoCalTheme.Colors.background.ignoresSafeArea()
            self
        }
    }
}
#endif
