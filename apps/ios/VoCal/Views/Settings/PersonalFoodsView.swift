import SwiftUI
import VoCalCore

/// Settings > My foods: what the person has declared themselves, a label typed once or a batch
/// saved as a recipe, each priced by name from then on. Forget retires one: a mark on the
/// server, and every meal already logged with it keeps its numbers.
struct PersonalFoodsView: View {
    var api: APIClient = APIClient()

    private enum ViewState: Equatable {
        case loading
        case loaded
        case failed
    }

    @State private var state: ViewState = .loading
    @State private var foods: [PersonalFood] = []
    @State private var forgetting: String?
    @State private var forgetFailed = false
    private let service: any PersonalFoodsService
    /// False when the person chose to follow their nutrition without numbers (decision 72):
    /// each food keeps its name and where it came from, never its calories or macros.
    private let printsNumbers: Bool

    /// `preloaded` starts the page in its loaded state with these foods: previews and the
    /// render loop, which cannot run `.task`, show the list rather than the spinner.
    init(api: APIClient = APIClient(), preloaded: [PersonalFood]? = nil, printsNumbers: Bool = true) {
        self.api = api
        self.printsNumbers = printsNumbers
        service = RuntimeMode.usesMockServices ? MockPersonalFoodsService.shared : LivePersonalFoodsService(api: api)
        if let preloaded {
            _foods = State(initialValue: preloaded)
            _state = State(initialValue: .loaded)
        }
    }

    var body: some View {
        SettingsPageScaffold(title: "My foods") {
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
        .alert("Not forgotten", isPresented: $forgetFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("That didn't reach the server. Check your connection and try again.")
        }
    }

    @ViewBuilder
    private var loaded: some View {
        if foods.isEmpty {
            VStack(spacing: VoCalTheme.Spacing.s) {
                Image(systemName: "fork.knife.circle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(VoCalTheme.Colors.gold)
                Text("Nothing saved yet")
                    .scaledFont(.primaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.ink)
                Text("When a food isn't in our lists, enter its label from an item's edit sheet. A batch you cooked can be saved as a recipe from the result.")
                    .scaledFont(.secondaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.secondaryInk)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, VoCalTheme.Spacing.xxl)
        } else {
            Text(printsNumbers ? "Say a name and it logs with these numbers." : "Say a name and it logs the way you saved it.")
                .scaledFont(.secondaryLabel)
                .foregroundStyle(VoCalTheme.Colors.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, VoCalTheme.Spacing.s)
            SettingsCard {
                ForEach(Array(foods.enumerated()), id: \.element.id) { index, food in
                    row(food)
                    if index < foods.count - 1 { SettingsDivider() }
                }
            }
        }
    }

    private func row(_ food: PersonalFood) -> some View {
        let numbers = "\(Int(food.perServing.kcal.rounded())) cal a serving · \(macros(food.perServing))"
        return SettingsItemRow(
            title: food.name,
            lines: printsNumbers ? [numbers, origin(food)] : [origin(food)],
            actionTitle: "Forget",
            actionID: "settings.my-foods.forget",
            actionDisabled: forgetting != nil
        ) {
            Task { await forget(food) }
        }
    }

    private func macros(_ p: NutrientProfile) -> String {
        "\(Int(p.protein.rounded()))P \(Int(p.carbs.rounded()))C \(Int(p.fat.rounded()))F"
    }

    private func origin(_ food: PersonalFood) -> String {
        if food.isBatch {
            if let n = food.servingsPerPackage { return "A recipe, makes \(Int(n.rounded())) servings" }
            return "A recipe"
        }
        if let grams = food.servingGrams { return "From its label, \(Int(grams.rounded())) g a serving" }
        return "From its label"
    }

    private var failure: some View {
        VStack(spacing: VoCalTheme.Spacing.l) {
            VStack(spacing: VoCalTheme.Spacing.s) {
                Text("Couldn't load your foods")
                    .scaledFont(.primaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.ink)
                Text("Check your connection and try again.")
                    .scaledFont(.secondaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.secondaryInk)
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
        if state == .loaded, !foods.isEmpty { return }
        do {
            foods = try await service.list()
            state = .loaded
        } catch {
            state = foods.isEmpty ? .failed : .loaded
        }
    }

    private func forget(_ food: PersonalFood) async {
        forgetting = food.id
        defer { forgetting = nil }
        do {
            try await service.retire(id: food.id)
            foods = try await service.list()
        } catch {
            forgetFailed = true
        }
    }
}
