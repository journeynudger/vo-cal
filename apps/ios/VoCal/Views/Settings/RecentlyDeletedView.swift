import SwiftUI
import VoCalCore

/// Settings > Recently deleted: meals deleted in the last 30 days, each with Restore (R10).
/// A delete is a tombstone on the server, so Restore puts the meal back on its day exactly
/// as it was; past the window the server hides it and the operator's purge removes it.
/// The list says when each window closes, never a vague "soon".
struct RecentlyDeletedView: View {
    var api: APIClient = APIClient()

    private enum ViewState {
        case loading
        case loaded
        case failed
    }

    @State private var state: ViewState = .loading
    @State private var meals: [DeletedMeal] = []
    @State private var restoring: String?
    @State private var restoreError: String?
    private let mock = RuntimeMode.usesMockServices

    var body: some View {
        SettingsPageScaffold(title: "Recently deleted") {
            switch state {
            case .loading:
                VoCalLoader(size: 40)
                    .frame(maxWidth: .infinity)
                    .padding(.top, VoCalTheme.Spacing.xxl)
            case .failed:
                failure
            case .loaded:
                loaded
            }
        }
        .task { await load() }
        .alert(
            "Not restored",
            isPresented: Binding(get: { restoreError != nil }, set: { if !$0 { restoreError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(restoreError ?? "")
        }
    }

    @ViewBuilder
    private var loaded: some View {
        if meals.isEmpty {
            VStack(spacing: VoCalTheme.Spacing.s) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(VoCalTheme.Colors.gold)
                Text("Nothing deleted recently")
                    .font(VoCalTheme.Fonts.primaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.ink)
                Text("A deleted meal stays here for 30 days, ready to restore.")
                    .font(VoCalTheme.Fonts.secondaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, VoCalTheme.Spacing.xxl)
        } else {
            Text("Restore puts a meal back on its day exactly as it was.")
                .font(VoCalTheme.Fonts.secondaryLabel)
                .foregroundStyle(VoCalTheme.Colors.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, VoCalTheme.Spacing.s)
            SettingsCard {
                ForEach(Array(meals.enumerated()), id: \.element.id) { index, meal in
                    row(meal)
                    if index < meals.count - 1 { SettingsDivider() }
                }
            }
        }
    }

    private func row(_ meal: DeletedMeal) -> some View {
        HStack(spacing: VoCalTheme.Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(meal.name ?? "Meal")
                    .font(VoCalTheme.Fonts.primaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.ink)
                Text("\(Int(meal.totals.kcal.rounded())) cal · logged \(meal.loggedAt.formatted(.dateTime.month(.abbreviated).day()))")
                    .font(VoCalTheme.Fonts.formLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
                Text("Restore by \(meal.restoreUntil.formatted(.dateTime.month(.abbreviated).day()))")
                    .font(VoCalTheme.Fonts.formLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
            }
            Spacer(minLength: VoCalTheme.Spacing.s)
            Button {
                Task { await restore(meal) }
            } label: {
                Text(restoring == meal.id ? "Restoring" : "Restore")
                    .font(VoCalTheme.Fonts.formLabel.weight(.semibold))
                    .foregroundStyle(VoCalTheme.Colors.gold)
            }
            .disabled(restoring != nil)
            .accessibilityIdentifier("settings.recently-deleted.restore")
        }
        .padding(.horizontal, VoCalTheme.Spacing.l)
        .padding(.vertical, VoCalTheme.Spacing.m)
    }

    private var failure: some View {
        VStack(spacing: VoCalTheme.Spacing.l) {
            VStack(spacing: VoCalTheme.Spacing.s) {
                Text("Couldn't load deleted meals")
                    .font(VoCalTheme.Fonts.primaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.ink)
                Text("Check your connection and try again.")
                    .font(VoCalTheme.Fonts.secondaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, VoCalTheme.Spacing.xxl)
            PillButton(title: "Try again") {
                state = .loading
                Task { await load() }
            }
            .padding(.horizontal, VoCalTheme.Spacing.xxl)
        }
    }

    private func load() async {
        if mock {
            meals = Self.seeded
            state = .loaded
            return
        }
        do {
            meals = try await api.deletedMeals()
            state = .loaded
        } catch {
            state = meals.isEmpty ? .failed : .loaded
        }
    }

    private func restore(_ meal: DeletedMeal) async {
        restoring = meal.id
        defer { restoring = nil }
        if mock {
            meals.removeAll { $0.id == meal.id }
            return
        }
        do {
            _ = try await api.restoreMeal(id: meal.id)
            meals = try await api.deletedMeals()
        } catch {
            restoreError = Self.restoreFailureCopy(error)
        }
    }

    /// Calm, specific copy per failure class: the two server refusals name what to do; a
    /// transport failure says to try again. Never a raw code on the surface.
    static func restoreFailureCopy(_ error: any Error) -> String {
        if let api = error as? APIError, case let .status(code, _) = api {
            if code == 409 {
                return "That meal was logged again after it was deleted. Delete the newer copy first, then restore."
            }
            if code == 410 {
                return "That meal's 30 days are up, so it can't be restored."
            }
        }
        return "That didn't reach the server. Check your connection and try again."
    }

    /// The mock path has no server: one deleted meal so the page is exercisable on the sim.
    private static let seeded = [
        DeletedMeal(
            id: "mock-deleted-1", name: "Lunch", mealType: .lunch,
            totals: NutrientProfile(kcal: 612, protein: 41, carbs: 58, fat: 22, fiber: 6),
            loggedAt: Date().addingTimeInterval(-86_400 * 2),
            deletedAt: Date().addingTimeInterval(-3_600),
            restoreUntil: Date().addingTimeInterval(86_400 * 30 - 3_600)
        ),
    ]
}
