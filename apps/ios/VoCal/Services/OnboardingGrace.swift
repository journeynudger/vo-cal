import Foundation

/// Quiet period after a fresh onboarding: no check-in banner, no nudges. A brand
/// new user has nothing to review and no habit to protect yet, so coaching
/// surfaces on day one read as noise, not care (user ask 2026-08). The stamp is
/// written when onboarding completes; devices onboarded before this build have
/// no stamp and get no retroactive grace (their habit already exists).
enum OnboardingGrace {
    static let key = "vocal.onboardedAt"
    /// Long enough for a few days of logging to accumulate, short enough that
    /// the first weekly check-in still lands inside week one.
    static let graceDays = 3

    /// Stamp the completion moment (called once from the onboarding gate).
    static func markOnboarded(now: Date = .now) {
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: key)
    }

    /// True while coaching surfaces should stay quiet.
    static var isActive: Bool {
        let stamp = UserDefaults.standard.double(forKey: key)
        guard stamp > 0 else { return false }
        let onboardedAt = Date(timeIntervalSince1970: stamp)
        guard let end = Calendar.current.date(byAdding: .day, value: graceDays, to: onboardedAt)
        else { return false }
        return Date.now < end
    }
}
