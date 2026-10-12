import SwiftUI

/// The one chooser for how the person follows their nutrition: the intake's first step and
/// Settings → How I track render this same view (spec 6.8), so the two can never drift. Five
/// sentences with one line each, words only, nothing preselected; the order is the ladder
/// without saying so, least to most asked of the person (spec 6.2).
struct TrackingModeChooser: View {
    @Binding var selection: TrackingMode?

    var body: some View {
        ChoiceList(options: Self.options, selection: rawSelection)
    }

    private static let options: [(value: String, label: String, sub: String?)] = TrackingMode.offered.map {
        (value: $0.rawValue, label: $0.title, sub: $0.support as String?)
    }

    private var rawSelection: Binding<String> {
        Binding(
            get: { selection?.rawValue ?? "" },
            set: { selection = TrackingMode(rawValue: $0) }
        )
    }
}

#Preview {
    @Previewable @State var mode: TrackingMode? = nil
    ScrollView {
        TrackingModeChooser(selection: $mode)
            .padding()
    }
    .background(VoCalTheme.Colors.background)
}
