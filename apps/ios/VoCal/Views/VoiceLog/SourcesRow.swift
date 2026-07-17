import SwiftUI
import VoCalCore

/// Compact trust signal for search-grounded estimates: overlapping favicon circles and an
/// "N sources" label. Tapping slides up the full source list as clickable links, so the
/// row stays a glanceable badge — never an inline citation dump (DESIGN.md calm-copy rule).
struct SourcesRow: View {
    let sources: [FoodSource]

    @State private var showingList = false

    /// Deduped hosts (www. stripped) in first-seen order — one favicon circle per domain.
    private var domains: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for source in sources {
            guard let domain = Self.domain(of: source.url) else { continue }
            if seen.insert(domain).inserted { out.append(domain) }
        }
        return out
    }

    static func domain(of url: String) -> String? {
        guard let host = URL(string: url)?.host else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    var body: some View {
        if !sources.isEmpty {
            Button {
                showingList = true
            } label: {
                HStack(spacing: VoCalTheme.Spacing.s) {
                    overlappingFavicons
                    Text("\(sources.count) source\(sources.count == 1 ? "" : "s")")
                        .font(VoCalTheme.Fonts.chipLabel)
                        .foregroundStyle(VoCalTheme.Colors.muted)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(VoCalTheme.Colors.muted)
                }
                .padding(.horizontal, VoCalTheme.Spacing.m)
                .padding(.vertical, VoCalTheme.Spacing.s)
                .background(VoCalTheme.Colors.card, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(sources.count) sources. Tap to view the list.")
            .sheet(isPresented: $showingList) {
                SourceListSheet(sources: sources)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    /// Up to four favicon circles, overlapped left-to-right. Each wears a background-colored
    /// ring so the stack reads as separate coins against neighboring icons.
    private var overlappingFavicons: some View {
        HStack(spacing: -8) {
            ForEach(domains.prefix(4), id: \.self) { domain in
                FaviconCircle(domain: domain, size: 22)
                    .overlay(Circle().strokeBorder(VoCalTheme.Colors.background, lineWidth: 2))
            }
        }
    }
}

/// A single source favicon, fetched from Google's favicon service — the sources are
/// arbitrary web domains, so icons can't ship as bundled assets. Falls back to a
/// magnifying-glass coin while loading or when the icon can't load (offline, unknown
/// domain), so the row never shows an empty hole.
struct FaviconCircle: View {
    let domain: String
    var size: CGFloat = 22

    private var iconURL: URL? {
        URL(string: "https://www.google.com/s2/favicons?domain=\(domain)&sz=64")
    }

    var body: some View {
        AsyncImage(url: iconURL) { phase in
            if let image = phase.image {
                image
                    .resizable()
                    .scaledToFill()
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .background(VoCalTheme.Colors.card)
        .clipShape(Circle())
    }

    private var fallback: some View {
        Image(systemName: "magnifyingglass")
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(VoCalTheme.Colors.muted)
    }
}

/// Slide-up list of every source behind the estimate, each row a clickable link that
/// opens in the browser. Deduped by URL; rows whose URL doesn't parse are dropped
/// rather than rendered dead.
struct SourceListSheet: View {
    let sources: [FoodSource]

    @Environment(\.dismiss) private var dismiss

    private struct Entry: Identifiable {
        let id: String
        let url: URL
        let title: String
        let domain: String
    }

    private var entries: [Entry] {
        var seen = Set<String>()
        var out: [Entry] = []
        for source in sources {
            guard seen.insert(source.url).inserted,
                  let url = URL(string: source.url),
                  let domain = SourcesRow.domain(of: source.url)
            else { continue }
            out.append(Entry(id: source.url, url: url, title: source.title, domain: domain))
        }
        return out
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VoCalTheme.Spacing.s) {
                header
                ForEach(entries) { entry in
                    Link(destination: entry.url) {
                        row(entry)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(VoCalTheme.Spacing.l)
        }
        .background(VoCalTheme.Colors.background)
    }

    private var header: some View {
        HStack {
            Text("Sources")
                .font(VoCalTheme.Fonts.screenTitle)
                .foregroundStyle(VoCalTheme.Colors.ink)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(VoCalTheme.Colors.muted)
                    .frame(width: 30, height: 30)
                    .background(VoCalTheme.Colors.card, in: Circle())
            }
            .accessibilityLabel("Close")
        }
        .padding(.bottom, VoCalTheme.Spacing.s)
    }

    private func row(_ entry: Entry) -> some View {
        HStack(spacing: VoCalTheme.Spacing.m) {
            FaviconCircle(domain: entry.domain, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title.isEmpty ? entry.domain : entry.title)
                    .font(VoCalTheme.Fonts.secondaryLabel.weight(.medium))
                    .foregroundStyle(VoCalTheme.Colors.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(entry.domain)
                    .font(VoCalTheme.Fonts.formLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
            }
            Spacer()
            Image(systemName: "arrow.up.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(VoCalTheme.Colors.muted)
        }
        .padding(VoCalTheme.Spacing.m)
        .background(
            VoCalTheme.Colors.card,
            in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.chip, style: .continuous)
        )
    }
}
