import Foundation
import UserNotifications

/// Local-notification delivery for nudges — Beacon's notification-service shape
/// (idempotent permission + a delegate for foreground banners/taps), minus APNs:
/// every nudge trigger derives from the user's OWN logging data, so the plan is
/// fetched from the server and delivered as LOCALLY scheduled notifications. No
/// push key, no device-token registry, no server sender.
///
/// Capture-path isolation: nothing here runs at app launch or on the mic-hot path.
/// The singleton is first touched from the Today surface / post-log refresh.
final class NudgeNotificationService: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NudgeNotificationService()

    /// Called (on the main actor) when the user taps a delivered nudge, with its id.
    /// NudgeCenter uses this to record the ledger entry.
    var onNudgeTapped: (@MainActor (String) -> Void)?

    private static let idPrefix = "nudge."

    private override init() {
        super.init()
        // We are the app's only notification producer; claiming the delegate here
        // (first use, never at launch) keeps foreground banners + taps working.
        UNUserNotificationCenter.current().delegate = self
    }

    // MARK: - Permission (Beacon's idempotent request shape)

    func currentStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Ask only while undetermined — never re-prompts, safe to call repeatedly.
    /// Deliberately invoked AFTER the first successful meal log (value before ask).
    @discardableResult
    func requestAuthorizationIfNeeded() async -> UNAuthorizationStatus {
        let status = await currentStatus()
        guard status == .notDetermined else { return status }
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])
        return await currentStatus()
    }

    // MARK: - Scheduling

    /// Replace our pending local notifications with the fresh plan. Cancel-then-add
    /// keyed by the `nudge.` prefix, so a re-plan after every log/open converges the
    /// schedule (e.g. the 6 PM calorie check disappears once dinner is logged).
    func reschedule(_ scheduled: [ScheduledNudge]) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let ours = pending.map(\.identifier).filter { $0.hasPrefix(Self.idPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: ours)

        guard await currentStatus() == .authorized else { return }
        for entry in scheduled where entry.fireAt > Date() {
            let content = UNMutableNotificationContent()
            content.title = "Vo-Cal"
            content.body = entry.card.message
            content.sound = .default
            content.userInfo = ["nudge_id": entry.card.id]
            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: entry.fireAt
            )
            let request = UNNotificationRequest(
                identifier: Self.idPrefix + entry.card.id,
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            )
            try? await center.add(request)
        }
    }

    func cancelAll() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let ours = pending.map(\.identifier).filter { $0.hasPrefix(Self.idPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: ours)
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let id = response.notification.request.content.userInfo["nudge_id"] as? String else {
            return
        }
        await MainActor.run { onNudgeTapped?(id) }
    }
}
