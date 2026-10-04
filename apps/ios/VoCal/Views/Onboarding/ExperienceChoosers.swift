import SwiftUI

/// "How much should Vo-Cal say?" (decision 66): the three delivery levels in the person's own
/// sentences, the engine's promise under each, nothing preselected. The intake's second step
/// and Settings → Notifications render this same view, so the two never drift (spec S3).
struct VoiceChooser: View {
    @Binding var selection: NudgeLevel?

    var body: some View {
        ChoiceList(options: Self.options, selection: rawSelection)
    }

    private static let options: [(value: String, label: String, sub: String?)] = NudgeLevel.allCases.map {
        (value: $0.rawValue, label: $0.label, sub: $0.detail as String?)
    }

    private var rawSelection: Binding<String> {
        Binding(
            get: { selection?.rawValue ?? "" },
            set: { selection = NudgeLevel(rawValue: $0) }
        )
    }
}

/// "What makes tracking hard for you?" (decision 66): four answers, any or none, each naming
/// the one thing the app will do about it. The intake's third step and Settings → How I track.
struct FrictionChooser: View {
    @Binding var selection: [Friction]

    var body: some View {
        MultiChoiceList(options: Self.options, selection: rawSelection)
    }

    private static let options: [(value: String, label: String, sub: String?)] = Friction.allCases.map {
        (value: $0.rawValue, label: $0.title, sub: $0.support as String?)
    }

    /// Kept in the enum's order whatever order the person ticked them in.
    private var rawSelection: Binding<Set<String>> {
        Binding(
            get: { Set(selection.map(\.rawValue)) },
            set: { chosen in selection = Friction.allCases.filter { chosen.contains($0.rawValue) } }
        )
    }
}

#Preview {
    @Previewable @State var level: NudgeLevel? = nil
    @Previewable @State var frictions: [Friction] = [.forgetting]
    ScrollView {
        VStack(spacing: 32) {
            VoiceChooser(selection: $level)
            FrictionChooser(selection: $frictions)
        }
        .padding()
    }
    .background(VoCalTheme.Colors.background)
}
