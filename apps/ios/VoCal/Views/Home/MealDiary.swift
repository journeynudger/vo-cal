import Foundation
import VoCalCore

// The diary (2026-11-06, Lorenzo: "instead of saying meal, which makes it hard to see what
// meal you're referring to, show the history of meals logged like MyFitnessPal; there's a
// method to their madness"). The method: a day is read as breakfast, lunch, dinner and
// snacks, each with what went in it and its own total, each with its own way to add. A
// pure grouping of the server's rows; nothing here prices or sums a food, it adds up the
// calories the server already put on each row for the section's line.

/// The four sections of a day, in the order a day is read.
enum DiarySlot: String, CaseIterable, Identifiable, Sendable {
    case breakfast, lunch, dinner, snack

    var id: String { rawValue }

    var title: String {
        switch self {
        case .breakfast: "Breakfast"
        case .lunch: "Lunch"
        case .dinner: "Dinner"
        case .snack: "Snacks"
        }
    }

    /// The meal type a log from this section carries.
    var mealType: MealType {
        switch self {
        case .breakfast: .breakfast
        case .lunch: .lunch
        case .dinner: .dinner
        case .snack: .snack
        }
    }

    /// The section a meal falls in when it was logged without a slot: by the hour it was
    /// eaten. The boundaries are where most days break (before half past ten is breakfast,
    /// before half past two lunch, before five a snack, the rest dinner). A slot the person
    /// named wins over the clock.
    static func slot(for meal: TodayMealRow, calendar: Calendar = .current) -> DiarySlot {
        switch meal.mealType {
        case "breakfast": return .breakfast
        case "lunch": return .lunch
        case "dinner": return .dinner
        case "snack": return .snack
        default: break
        }
        let components = calendar.dateComponents([.hour, .minute], from: meal.loggedAt)
        let minutes = (components.hour ?? 12) * 60 + (components.minute ?? 0)
        switch minutes {
        case ..<(10 * 60 + 30): return .breakfast
        case ..<(14 * 60 + 30): return .lunch
        case ..<(17 * 60): return .snack
        default: return .dinner
        }
    }

    /// The section the clock suggests for a new log right now, the log sheet's default.
    static func suggested(at date: Date = .now, calendar: Calendar = .current) -> DiarySlot {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let minutes = (components.hour ?? 12) * 60 + (components.minute ?? 0)
        switch minutes {
        case ..<(10 * 60 + 30): return .breakfast
        case ..<(14 * 60 + 30): return .lunch
        case ..<(17 * 60): return .snack
        default: return .dinner
        }
    }
}

/// One section of the diary: its meals in the order they were eaten and the calories the
/// server put on them, added up for the section's line.
struct DiarySection: Identifiable, Equatable, Sendable {
    let slot: DiarySlot
    var meals: [TodayMealRow]

    var id: String { slot.id }
    var kcal: Double { meals.reduce(0) { $0 + $1.kcal } }
}

enum MealDiary {
    /// Every section, every day, in the day's order, empty ones included: an empty section is
    /// where the person adds the meal, which is the method.
    static func sections(_ meals: [TodayMealRow], calendar: Calendar = .current) -> [DiarySection] {
        var grouped: [DiarySlot: [TodayMealRow]] = [:]
        for meal in meals {
            grouped[DiarySlot.slot(for: meal, calendar: calendar), default: []].append(meal)
        }
        return DiarySlot.allCases.map { slot in
            DiarySection(slot: slot, meals: (grouped[slot] ?? []).sorted { $0.loggedAt < $1.loggedAt })
        }
    }
}
