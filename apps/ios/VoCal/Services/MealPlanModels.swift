import Foundation
import VoCalCore

// Swift mirror of the meal plan contract (services/api meals/plan.py, decision 65). Field names
// map to snake_case via VoCalJSON. Every server-added field decodes tolerantly (apps/ios/AGENTS.md
// decode rule): a plan from a later server never fails the load, and a slot this build cannot
// read is dropped, never the whole plan.

/// One planned meal as Today's plan card shows it (the `meal_plan_slots` panel): the slot, its
/// name and calories, and whether a logged meal ticked it. The tick is the server's, matched by
/// name on the one path every meal takes; the client only draws it.
struct PlanSlotStatus: Codable, Sendable, Equatable, Identifiable {
    var index: Int
    var name: String
    var kcal: Double
    var logged = false
    /// The logged meal that filled the slot, when one did.
    var mealId: String?

    var id: Int { index }
}

extension PlanSlotStatus {
    private enum CodingKeys: String, CodingKey {
        case index, name, kcal, logged, mealId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decode(Int.self, forKey: .index)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Meal"
        kcal = try container.decodeIfPresent(Double.self, forKey: .kcal) ?? 0
        logged = try container.decodeIfPresent(Bool.self, forKey: .logged) ?? false
        mealId = try container.decodeIfPresent(String.self, forKey: .mealId)
    }
}

/// The engine's one line about the plan against the protocol (AGENTS.md #6: deterministic code
/// computed it, and the client prints it as given). The numbers ride beside the line so a
/// screen may print them; the verdict is never re-derived here.
struct PlanCheck: Codable, Sendable, Equatable {
    var kcal: Double
    var protein: Double
    var targetKcal: Double
    var proteinFloor: Double
    var kcalWithin: Bool
    var proteinOk: Bool
    var line: String

    /// Both facts the engine checks hold: the plan lands on the protocol.
    var onProtocol: Bool { kcalWithin && proteinOk }
}

extension PlanCheck {
    private enum CodingKeys: String, CodingKey {
        case kcal, protein, targetKcal, proteinFloor, kcalWithin, proteinOk, line
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        line = try container.decode(String.self, forKey: .line)
        kcal = try container.decodeIfPresent(Double.self, forKey: .kcal) ?? 0
        protein = try container.decodeIfPresent(Double.self, forKey: .protein) ?? 0
        targetKcal = try container.decodeIfPresent(Double.self, forKey: .targetKcal) ?? 0
        proteinFloor = try container.decodeIfPresent(Double.self, forKey: .proteinFloor) ?? 0
        kcalWithin = try container.decodeIfPresent(Bool.self, forKey: .kcalWithin) ?? false
        proteinOk = try container.decodeIfPresent(Bool.self, forKey: .proteinOk) ?? false
    }
}

/// One slot of a saved plan: a usual by id, or the items of a typed meal, with the server's
/// totals (priced on the confirm path when the plan was saved; the client never sums a food).
struct PlanSlot: Codable, Sendable, Equatable, Identifiable {
    var index: Int
    var name: String
    var usualId: String?
    var items: [ConfirmedItem]
    var totals: NutrientProfile

    var id: Int { index }
}

extension PlanSlot {
    private enum CodingKeys: String, CodingKey {
        case index, name, usualId, items, totals
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decode(Int.self, forKey: .index)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Meal"
        usualId = try container.decodeIfPresent(String.self, forKey: .usualId)
        items = try container.decodeIfPresent([ConfirmedItem].self, forKey: .items) ?? []
        totals = try container.decodeIfPresent(NutrientProfile.self, forKey: .totals) ?? .zero
    }
}

/// `GET /meals/plan` and the `PUT /meals/plan` echo: the latest version of the plan, with the
/// engine's check when a protocol exists to check it against.
struct MealPlan: Codable, Sendable, Equatable {
    var version: Int
    /// Who wrote it: "person" today; "coach" is the lane decision 65 keeps open.
    var author: String
    var slots: [PlanSlot]
    var check: PlanCheck?

    /// The sum of the slots' server-priced calories, for the line the builder shows before a
    /// save: arranging the server's totals, never pricing a food (as PanelComposer does).
    var plannedKcal: Double { slots.reduce(0) { $0 + $1.totals.kcal } }
}

extension MealPlan {
    private enum CodingKeys: String, CodingKey {
        case version, author, slots, check
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 0
        author = try container.decodeIfPresent(String.self, forKey: .author) ?? "person"
        // A slot a later server shaped differently is dropped on its own, never the plan.
        slots = (try container.decodeIfPresent([FailableSlot].self, forKey: .slots) ?? []).compactMap(\.slot)
        check = try? container.decodeIfPresent(PlanCheck.self, forKey: .check)
    }

    private struct FailableSlot: Decodable {
        let slot: PlanSlot?
        init(from decoder: Decoder) throws {
            slot = try? PlanSlot(from: decoder)
        }
    }
}

/// One slot as `PUT /meals/plan` takes it: a usual by id (the server copies its items), or the
/// items of a typed meal's parse (the server re-prices them on the confirm path). A name is
/// optional: a fresh typed slot sends none, so the server names it from the items exactly as
/// it names a typed log, which is what lets a logged meal tick the slot by name.
struct PlanSlotInput: Encodable, Sendable, Equatable {
    var name: String? = nil
    var usualId: String? = nil
    var items: [ConfirmedItem]? = nil
}

/// `PUT /meals/plan`: the whole plan, in order. Appends a version server-side.
struct MealPlanUpdate: Encodable, Sendable, Equatable {
    var slots: [PlanSlotInput]
    var author: String = "person"
}

/// `POST /meals/plan/generate` (decision 73): Francesco's three steps. The shape of the day,
/// the foods to include, and whether the plan may add foods the person did not name.
struct GeneratePlanRequest: Encodable, Sendable, Equatable {
    var meals: Int
    var snacks: Int
    var dessert: Bool
    var foods: [String]
    var mayAdd: Bool
}

/// A drafted slot: a plan slot (priced on the confirm path) and the part of the day it is.
struct GeneratedSlot: Decodable, Sendable, Equatable, Identifiable {
    var slot: PlanSlot
    /// "Breakfast", "Snack", "Dinner": the builder may print it; the plan stores only the slot.
    var label: String

    var id: Int { slot.index }

    private enum CodingKeys: String, CodingKey { case label }

    init(slot: PlanSlot, label: String) {
        self.slot = slot
        self.label = label
    }

    init(from decoder: Decoder) throws {
        slot = try PlanSlot(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? slot.name
    }
}

/// The draft: never stored. It opens in the builder, where the person edits and saves it like
/// any plan. `added` are foods the plan added (only when allowed), `unused` foods the day had
/// no place for, `unpriced` names nothing could price.
struct GeneratedPlan: Decodable, Sendable, Equatable {
    var slots: [GeneratedSlot]
    var check: PlanCheck?
    var added: [String] = []
    var unused: [String] = []
    var unpriced: [String] = []
    var notes: [String] = []

    private enum CodingKeys: String, CodingKey {
        case slots, check, added, unused, unpriced, notes
    }

    init(slots: [GeneratedSlot], check: PlanCheck?, added: [String] = [], unused: [String] = [], unpriced: [String] = [], notes: [String] = []) {
        self.slots = slots
        self.check = check
        self.added = added
        self.unused = unused
        self.unpriced = unpriced
        self.notes = notes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        slots = try container.decodeIfPresent([GeneratedSlot].self, forKey: .slots) ?? []
        check = try? container.decodeIfPresent(PlanCheck.self, forKey: .check)
        added = try container.decodeIfPresent([String].self, forKey: .added) ?? []
        unused = try container.decodeIfPresent([String].self, forKey: .unused) ?? []
        unpriced = try container.decodeIfPresent([String].self, forKey: .unpriced) ?? []
        notes = try container.decodeIfPresent([String].self, forKey: .notes) ?? []
    }
}

/// `POST /meals/plan/receipt`: the foods a grocery receipt lists, as names (decision 73).
struct ReceiptFoods: Decodable, Sendable, Equatable {
    var foods: [String]
}
