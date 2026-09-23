import SwiftUI
import VoCalCore

/// Settings > Learned names: what the parser remembers from renames on the result sheet
/// (R9). Each row is a name the transcriber heard and the name it now logs as, applied
/// deterministically on every later parse. Forget appends a server-side record so the
/// rename stops; nothing is deleted, the audit trail keeps what taught it. The empty state
/// names the gesture that teaches instead of a blank list.
struct LearnedNamesView: View {
    var api: APIClient = APIClient()

    private enum ViewState {
        case loading
        case loaded
        case failed
    }

    @State private var state: ViewState = .loading
    @State private var names: [LearnedName] = []
    @State private var forgetting: String?
    @State private var forgetFailed = false
    private let mock = RuntimeMode.usesMockServices

    var body: some View {
        SettingsPageScaffold(title: "Learned names") {
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
        if names.isEmpty {
            VStack(spacing: VoCalTheme.Spacing.s) {
                Image(systemName: "text.badge.checkmark")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(VoCalTheme.Colors.gold)
                Text("Nothing learned yet")
                    .font(VoCalTheme.Fonts.primaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.ink)
                Text("Rename an item on a result and Vo-Cal remembers it next time.")
                    .font(VoCalTheme.Fonts.secondaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, VoCalTheme.Spacing.xxl)
        } else {
            Text("A rename on a result teaches Vo-Cal. These names now log as corrected.")
                .font(VoCalTheme.Fonts.secondaryLabel)
                .foregroundStyle(VoCalTheme.Colors.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, VoCalTheme.Spacing.s)
            SettingsCard {
                ForEach(Array(names.enumerated()), id: \.element.id) { index, name in
                    row(name)
                    if index < names.count - 1 { SettingsDivider() }
                }
            }
        }
    }

    private func row(_ name: LearnedName) -> some View {
        HStack(spacing: VoCalTheme.Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name.corrected)
                    .font(VoCalTheme.Fonts.primaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.ink)
                Text(name.count > 1 ? "Heard as \"\(name.heard)\" · \(name.count) times" : "Heard as \"\(name.heard)\"")
                    .font(VoCalTheme.Fonts.formLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
            }
            Spacer(minLength: VoCalTheme.Spacing.s)
            Button {
                Task { await forget(name) }
            } label: {
                Text("Forget")
                    .font(VoCalTheme.Fonts.formLabel.weight(.semibold))
                    .foregroundStyle(VoCalTheme.Colors.gold)
            }
            .disabled(forgetting != nil)
            .accessibilityIdentifier("settings.learned-names.forget")
        }
        .padding(.horizontal, VoCalTheme.Spacing.l)
        .padding(.vertical, VoCalTheme.Spacing.m)
    }

    private var failure: some View {
        VStack(spacing: VoCalTheme.Spacing.l) {
            VStack(spacing: VoCalTheme.Spacing.s) {
                Text("Couldn't load learned names")
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
            names = Self.seeded
            state = .loaded
            return
        }
        do {
            names = try await api.learnedNames()
            state = .loaded
        } catch {
            state = names.isEmpty ? .failed : .loaded
        }
    }

    private func forget(_ name: LearnedName) async {
        forgetting = name.id
        defer { forgetting = nil }
        if mock {
            names.removeAll { $0.id == name.id }
            return
        }
        do {
            try await api.forgetLearnedName(heard: name.heard)
            names = try await api.learnedNames()
        } catch {
            forgetFailed = true
        }
    }

    /// The mock path has no server: two learned names so the page is exercisable on the sim.
    private static let seeded = [
        LearnedName(heard: "oil coast", corrected: "Oikos", count: 3, learnedAt: nil),
        LearnedName(heard: "cosmic chris apple", corrected: "Cosmic Crisp apple", count: 1, learnedAt: nil),
    ]
}
