import SwiftUI

// Port provenance: Serein apps/ios/SereinApp/Sources/CaptureSearchKit.swift. Kept: the
// model's 60 ms breath after a keystroke, the generation count that drops a stale answer,
// the cancellable pending task, and SearchHitRow's matched words in full weight. Changed: a
// provider answers (earlier meals, usuals, the person's own foods) instead of the outbox's
// FTS index, the match is found in the name instead of marked in a snippet, and the answers
// rise above the capture bar instead of filling a search screen. Cut: the full-screen
// CaptureSearchScreen and the top-hits split.

/// One thing the person has eaten or declared before, offered while they type.
struct CaptureSearchHit: Identifiable, Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        /// A meal logged earlier.
        case meal
        /// A saved meal template (Today's usuals).
        case usual
        /// A food the person declared: a label they typed, a batch they cooked.
        case personalFood
    }

    let id: String
    let kind: Kind
    let name: String
    let kcal: Double?
    let subtitle: String?
}

/// Answers a typed query with the person's own history. A protocol so the bar runs on the
/// simulator with no backend; the live answer is the shell's to wire.
protocol CaptureSearchProvider: Sendable {
    func search(_ query: String) async throws -> [CaptureSearchHit]
}

/// Six believable answers, matched word by word against the name (case and accents aside),
/// so every state of the results surface is reachable with no network.
struct MockCaptureSearchProvider: CaptureSearchProvider {
    var hits: [CaptureSearchHit] = MockCaptureSearchProvider.seeded

    func search(_ query: String) async throws -> [CaptureSearchHit] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        return hits.filter { hit in
            words.allSatisfy { hit.name.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    static let seeded: [CaptureSearchHit] = [
        CaptureSearchHit(id: "mock-usual-smoothie", kind: .usual, name: "Metal detox smoothie", kcal: 310, subtitle: "Usual · most mornings"),
        CaptureSearchHit(id: "mock-meal-yogurt", kind: .meal, name: "Greek yogurt, berries & granola", kcal: 386, subtitle: "Yesterday · breakfast"),
        CaptureSearchHit(id: "mock-meal-chicken", kind: .meal, name: "Chicken, rice & broccoli", kcal: 541, subtitle: "Monday · dinner"),
        CaptureSearchHit(id: "mock-usual-shake", kind: .usual, name: "Protein shake", kcal: 162, subtitle: "Usual · after training"),
        CaptureSearchHit(id: "mock-food-chili", kind: .personalFood, name: "My chili recipe", kcal: 410, subtitle: "Your recipe · 1 serving"),
        CaptureSearchHit(id: "mock-meal-oats", kind: .meal, name: "Overnight oats", kcal: 348, subtitle: "Last week · breakfast"),
    ]
}

/// The answers to what is being typed. The bar writes `query` as the words change; a burst of
/// keystrokes runs one lookup per pause, and an answer that arrives after a newer question
/// is dropped.
@MainActor
@Observable
final class CaptureSearchModel {
    var query = "" {
        didSet {
            if query != oldValue {
                schedule()
            }
        }
    }

    private(set) var hits: [CaptureSearchHit] = []
    /// The query the current hits answer; the rows bold its words.
    private(set) var answeredQuery = ""
    /// True between a keystroke and its answer.
    private(set) var searching = false

    private let provider: any CaptureSearchProvider
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    /// A breath after the keystroke, so a fast typist runs one query per pause, not one per
    /// letter (Serein's number).
    static let debounce: Duration = .milliseconds(60)

    init(provider: any CaptureSearchProvider) {
        self.provider = provider
    }

    var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Something is being asked.
    var isActive: Bool {
        !trimmedQuery.isEmpty
    }

    /// A settled question with no answer: the surface's one quiet line.
    var foundNothing: Bool {
        isActive && !searching && hits.isEmpty
    }

    /// Waits for the pending answer: previews and render tests draw a settled list.
    func settle() async {
        await pending?.value
    }

    private func schedule() {
        pending?.cancel()
        generation += 1
        let generation = generation
        let asked = trimmedQuery
        guard !asked.isEmpty else {
            pending = nil
            hits = []
            answeredQuery = ""
            searching = false
            return
        }
        searching = true
        pending = Task { [weak self] in
            try? await Task.sleep(for: CaptureSearchModel.debounce)
            guard !Task.isCancelled else { return }
            await self?.run(asked, generation: generation)
        }
    }

    private func run(_ asked: String, generation: Int) async {
        // Search is a convenience beside the send path, never on it: a failed lookup reads as
        // nothing found, and sending the words still works.
        let found = (try? await provider.search(asked)) ?? []
        guard generation == self.generation else { return }
        hits = found
        answeredQuery = asked
        searching = false
    }
}

/// The answers, on frosted glass above the bar: a row per hit (name with the typed words in
/// full weight, where it comes from, its calories), or one quiet line when nothing matches.
/// Up to four rows show at once; more scroll, the fifth peeking to say so.
struct CaptureSearchResults: View {
    let model: CaptureSearchModel
    let onPick: (CaptureSearchHit) -> Void

    static let rowHeight: CGFloat = 56
    static let visibleRows: CGFloat = 4.5

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .liquidGlass(
                in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.card, style: .continuous),
                tint: CaptureBar.frost
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(CaptureA11y.searchResults)
    }

    @ViewBuilder
    private var content: some View {
        if model.hits.isEmpty {
            Text("Nothing like that yet. Send it and Vo-Cal will work it out.")
                .font(VoCalTheme.Fonts.secondaryLabel)
                .foregroundStyle(VoCalTheme.Colors.muted)
                .padding(.horizontal, VoCalTheme.Spacing.l)
                .padding(.vertical, 14)
                .accessibilityIdentifier(CaptureA11y.searchEmpty)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.hits) { hit in
                        Button {
                            onPick(hit)
                        } label: {
                            CaptureSearchHitRow(hit: hit, query: model.answeredQuery)
                                .overlay(alignment: .bottom) {
                                    if hit.id != model.hits.last?.id {
                                        Rectangle()
                                            .fill(VoCalTheme.Colors.ink.opacity(0.08))
                                            .frame(height: 0.5)
                                            .padding(.leading, VoCalTheme.Spacing.l)
                                    }
                                }
                        }
                        .buttonStyle(PressableButtonStyle())
                        .accessibilityIdentifier(CaptureA11y.searchHit)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(CGFloat(model.hits.count), Self.visibleRows) * Self.rowHeight)
        }
    }
}

/// One answer: the name with the typed words in full weight, where it comes from, and its
/// calories as the server priced them.
private struct CaptureSearchHitRow: View {
    let hit: CaptureSearchHit
    let query: String

    var body: some View {
        HStack(spacing: VoCalTheme.Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.highlighted(hit.name, matching: query))
                    .font(VoCalTheme.Fonts.body)
                    .foregroundStyle(VoCalTheme.Colors.ink)
                    .lineLimit(1)
                Text(detail)
                    .font(VoCalTheme.Fonts.formLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: VoCalTheme.Spacing.s)
            if let calories {
                // Muted: the name is what the person is looking for; the calories confirm it.
                Text("\(calories) cal")
                    .font(VoCalTheme.Fonts.chipLabel.monospacedDigit())
                    .foregroundStyle(VoCalTheme.Colors.muted)
            }
        }
        .padding(.horizontal, VoCalTheme.Spacing.l)
        .frame(height: CaptureSearchResults.rowHeight)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var calories: Int? {
        guard let kcal = hit.kcal, kcal.isFinite else { return nil }
        return Int(kcal.rounded())
    }

    private var detail: String {
        if let subtitle = hit.subtitle, !subtitle.isEmpty {
            return subtitle
        }
        switch hit.kind {
        case .meal: return "Earlier meal"
        case .usual: return "Usual"
        case .personalFood: return "Your food"
        }
    }

    private var accessibilityText: String {
        var parts = [hit.name]
        if let calories {
            parts.append("\(calories) calories")
        }
        parts.append(detail)
        return parts.joined(separator: ", ")
    }

    /// Every typed word found in the name, in full weight and ink: Serein's marked snippet,
    /// with the match found here (case and accents aside) instead of marked by an index.
    static func highlighted(_ name: String, matching query: String) -> AttributedString {
        var matches: [Range<String.Index>] = []
        for word in query.split(whereSeparator: \.isWhitespace) {
            var searchStart = name.startIndex
            while searchStart < name.endIndex,
                  let found = name.range(
                      of: word,
                      options: [.caseInsensitive, .diacriticInsensitive],
                      range: searchStart ..< name.endIndex
                  ),
                  !found.isEmpty {
                matches.append(found)
                searchStart = found.upperBound
            }
        }
        matches.sort { $0.lowerBound < $1.lowerBound }

        var result = AttributedString()
        var cursor = name.startIndex
        for match in matches where match.upperBound > cursor {
            let start = max(match.lowerBound, cursor)
            if cursor < start {
                result.append(AttributedString(String(name[cursor ..< start])))
            }
            var piece = AttributedString(String(name[start ..< match.upperBound]))
            piece.font = VoCalTheme.Fonts.body.weight(.bold)
            result.append(piece)
            cursor = match.upperBound
        }
        if cursor < name.endIndex {
            result.append(AttributedString(String(name[cursor...])))
        }
        return result
    }
}

#Preview("Answers") {
    @Previewable @State var model = CaptureSearchModel(provider: MockCaptureSearchProvider())
    CaptureSearchResults(model: model) { _ in }
        .padding(VoCalTheme.Spacing.l)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .background(VoCalTheme.Colors.background)
        .task {
            model.query = "o"
            await model.settle()
        }
}

#Preview("Nothing found") {
    @Previewable @State var model = CaptureSearchModel(provider: MockCaptureSearchProvider())
    CaptureSearchResults(model: model) { _ in }
        .padding(VoCalTheme.Spacing.l)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .background(VoCalTheme.Colors.background)
        .task {
            model.query = "zucchini fritters"
            await model.settle()
        }
}
