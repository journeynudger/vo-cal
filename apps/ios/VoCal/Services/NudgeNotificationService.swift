import Foundation
import UserNotifications

/// Local-notification delivery for nudges — Beacon's notification-service shape
/// (idempotent permission + a delegate for foreground banners/taps), minus APNs:
/// every nudge trigger derives from the user's OWN logging data, so the plan is
/// fetched from the server and delivered as LOCALLY scheduled notifications. No
/// push key, no device-token registry, no server sender.
///
/// Decision 67 gave each notification its words and its manners: the title is the subject in
/// the person's words (never the app's name), the level is `active` with the system sound only
/// for a nudge the catalog marks essential and `passive` without sound otherwise, never
/// time-sensitive; one thread; no badge, ever; two actions, "Log it" and "Not today"; and the
/// body's clock may move a fire later on the phone (`NudgeFireTiming`). Over the open app no
/// banner shows: the card on Today is the in-app surface.
///
/// Capture-path isolation: at launch only `attach()` runs, which creates the singleton (the
/// delegate and the category, two assignments, no fetch and no permission ask); every fetch,
/// ask and schedule starts from Today or the post-log refresh, never on the mic-hot path.
final class NudgeNotificationService: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NudgeNotificationService()

    /// Called (on the main actor) when the user taps a delivered nudge, with its id.
    /// NudgeCenter uses this to record the ledger entry.
    var onNudgeTapped: (@MainActor (String) -> Void)?
    /// Called (on the main actor) when the person answers from the lock screen: "Log it" is an
    /// act, "Not today" a dismissal. NudgeCenter records the reaction (decision 67).
    var onReaction: (@MainActor (String, NudgeReaction) -> Void)?

    private static let idPrefix = "nudge."
    static let categoryID = "nudge"
    static let logActionID = "nudge.log"
    static let notTodayActionID = "nudge.not-today"
    static let threadID = "nudges"

    private override init() {
        super.init()
        // We are the app's only notification producer; claiming the delegate here
        // (first use, never at launch) keeps foreground banners + taps working.
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([Self.category])
    }

    /// The one category: the two answers a reminder about food has. "Log it" brings the app
    /// forward and opens the voice log through the Action button's door; "Not today" needs no
    /// app at all. No destructive styling: a dismissal is not a deletion. Computed, not stored:
    /// UNNotificationCategory is not Sendable, so a stored static is shared mutable state to the
    /// Swift 6 checker (CI, 2026-10-04); it is built once, in `init`, and handed to the center.
    static var category: UNNotificationCategory {
        UNNotificationCategory(
            identifier: categoryID,
            actions: [
                UNNotificationAction(identifier: logActionID, title: "Log it", options: [.foreground]),
                UNNotificationAction(identifier: notTodayActionID, title: "Not today", options: []),
            ],
            intentIdentifiers: [],
            options: []
        )
    }

    /// Creates the singleton, and with it the delegate and the category, at launch: a response
    /// to a notification that cold-launches the app is delivered only to a delegate that already
    /// exists. Nothing else happens here.
    func attach() {}

    // MARK: - Permission (Beacon's idempotent request shape)

    func currentStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Ask only while undetermined; never re-prompts, safe to call repeatedly. Invoked from the
    /// person's own tap on the permission card (spec N8), never on its own. No badge is requested:
    /// a count is center-demanding and this app never counts (Serein's rule).
    @discardableResult
    func requestAuthorizationIfNeeded() async -> UNAuthorizationStatus {
        let status = await currentStatus()
        guard status == .notDetermined else { return status }
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
        return await currentStatus()
    }

    // MARK: - Content

    /// The notification as the person meets it, from the card alone: pure, so the render tests
    /// pin the words and the manners (spec 6.2).
    static func content(for card: NudgeCard) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = card.subject
        content.body = card.message
        content.sound = card.essential ? .default : nil
        content.interruptionLevel = card.essential ? .active : .passive
        content.relevanceScore = min(1, max(0, Double(card.priority) / 100))
        content.threadIdentifier = threadID
        content.categoryIdentifier = categoryID
        content.userInfo = ["nudge_id": card.id]
        return content
    }

    // MARK: - Scheduling

    /// Replace our pending local notifications with the fresh plan. Cancel-then-add
    /// keyed by the `nudge.` prefix, so a re-plan after every log/open converges the
    /// schedule (e.g. the 6 PM calorie check disappears once dinner is logged). ``clock`` is
    /// what the phone knows of the body today; a fire may move later for it (`NudgeFireTiming`:
    /// after training, out of the first hour after waking), a coaching fire is held after a
    /// short night, and a fire moved past quiet hours is dropped.
    func reschedule(_ scheduled: [ScheduledNudge], clock: NudgeFireTiming.BodyClock = .unknown, now: Date = Date()) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let ours = pending.map(\.identifier).filter { $0.hasPrefix(Self.idPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: ours)

        guard await currentStatus() == .authorized else { return }
        for entry in scheduled where entry.fireAt > now {
            // After a short night only the essentials speak (the behavior-change spec's 6.12).
            if NudgeFireTiming.holds(entry.card, clock: clock) {
                continue
            }
            guard let fireAt = NudgeFireTiming.shifted(fire: entry.fireAt, context: entry.context, clock: clock, now: now) else {
                continue
            }
            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: fireAt
            )
            let request = UNNotificationRequest(
                identifier: Self.idPrefix + entry.card.id,
                content: Self.content(for: entry.card),
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

    /// Over the open app, nothing: the card on Today is the in-app surface (spec 6.9), and a
    /// banner over a running capture would be the interruption Serein's rule forbids.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        []
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let id = response.notification.request.content.userInfo["nudge_id"] as? String else {
            return
        }
        switch response.actionIdentifier {
        case Self.logActionID:
            // The Action button's door (Intents/VoCalIntents.swift): a fresh ask the shell honors
            // once Today is on screen; the voice log's own door does the capture.
            await MainActor.run {
                PendingLaunchAction.shared.request(.startVoiceLog)
                onReaction?(id, .acted)
                onNudgeTapped?(id)
            }
        case Self.notTodayActionID:
            await MainActor.run {
                onReaction?(id, .dismissed)
                onNudgeTapped?(id)
            }
        default:
            await MainActor.run { onNudgeTapped?(id) }
        }
    }
}
