import SwiftUI

/// "What makes tracking hard for you?" (decision 66): four answers, any or none, each naming
/// the one thing the app will do about it. The intake's step after the outcome, and Settings →
/// How I track, render this same view so the two never drift (spec S3). "How much should
/// Vo-Cal say?" left the intake on 2026-10-16 (decision 77): it changes nothing until the first
/// log, so Today asks it then (`VoiceAskCard`), and Settings → Notifications edits it.
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

/// "When will you log?" (decision 69): four moments that already happen, nothing preselected.
/// The intake's step after the frictions and Settings → How I track render this same view. The
/// consistency check-ins follow the answer server-side; the words of the late-morning one and
/// the Action button card follow it on the phone.
struct AnchorChooser: View {
    @Binding var selection: LogAnchor?

    var body: some View {
        ChoiceList(options: Self.options, selection: rawSelection)
    }

    private static let options: [(value: String, label: String, sub: String?)] = LogAnchor.allCases.map {
        (value: $0.rawValue, label: $0.title, sub: $0.support as String?)
    }

    private var rawSelection: Binding<String> {
        Binding(
            get: { selection?.rawValue ?? "" },
            set: { selection = LogAnchor(rawValue: $0) }
        )
    }
}

#Preview {
    @Previewable @State var frictions: [Friction] = [.forgetting]
    @Previewable @State var anchor: LogAnchor? = .afterEating
    ScrollView {
        VStack(spacing: 32) {
            FrictionChooser(selection: $frictions)
            AnchorChooser(selection: $anchor)
        }
        .padding()
    }
    .background(VoCalTheme.Colors.background)
}
