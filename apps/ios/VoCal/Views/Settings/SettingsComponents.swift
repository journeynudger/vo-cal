import SwiftUI

/// Shared building blocks for the Settings surface: grouped cards of rows in the
/// black/gold system. The shape follows the grouped-inset pattern of a professional
/// settings screen — icon tile · label · optional value · chevron — rendered with
/// VoCalTheme tokens only (no system List, so the cream background and r24 cards
/// match the rest of the app instead of UIKit's grouped grays). Every line follows the
/// person's text size (`scaledFont`) and every secondary line is `secondaryInk`: the
/// nightly audit of 2026-10-12 failed these pages on the muted token and fixed sizes.

/// Section label above a card: the app's one overline treatment, in the secondary ink
/// (gold stays reserved for accents; a wall of gold headers reads loud, not premium).
struct SettingsSectionLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .scaledSectionHeader(VoCalTheme.Colors.secondaryInk)
            .padding(.horizontal, VoCalTheme.Spacing.s)
    }
}

/// A grouped card: stack rows with `SettingsDivider()` between them.
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .background(
            VoCalTheme.Colors.card,
            in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.card, style: .continuous)
        )
    }
}

/// Hairline separator between rows, inset to the text edge (past the icon tile)
/// so the rows read as one aligned column.
struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(VoCalTheme.Colors.ink.opacity(0.06))
            .frame(height: 1)
            .padding(.leading, 62)
    }
}

/// One settings row. `value` renders trailing in the secondary ink (e.g. "On", "Due"). `tint`
/// colors the label + icon — pass `VoCalTheme.Colors.alert` for destructive rows.
/// With an `action` it renders as a button; without one it is static content
/// (wrap it in a `NavigationLink` for push rows — the chevron is controlled by
/// `showsChevron` alone, so link rows keep theirs).
struct SettingsRow: View {
    let icon: String
    let label: String
    var value: String?
    var tint: Color = VoCalTheme.Colors.ink
    var showsChevron = true
    var accessibilityID: String?
    var action: (() -> Void)?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if let action {
            Button(action: action) { rowContent }
                .buttonStyle(SettingsRowButtonStyle())
                .modifier(OptionalA11yID(id: accessibilityID))
        } else {
            rowContent
                .modifier(OptionalA11yID(id: accessibilityID))
        }
    }

    private var rowContent: some View {
        HStack(spacing: VoCalTheme.Spacing.m) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(
                    VoCalTheme.Colors.background,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
            // Side by side the label and the value split each other's words at large sizes
            // ("Notificatio/ns" at xxxLarge, renders of 2026-10-14): the label takes its width
            // first, and at the accessibility sizes the value moves under it, the way the
            // phone's own Settings lays a row out.
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) {
                    labelText
                    if let value { valueText(value) }
                }
                Spacer(minLength: VoCalTheme.Spacing.s)
            } else {
                labelText
                    .layoutPriority(1)
                Spacer(minLength: VoCalTheme.Spacing.s)
                if let value { valueText(value) }
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(VoCalTheme.Colors.muted)
            }
        }
        .padding(.horizontal, VoCalTheme.Spacing.l)
        .padding(.vertical, VoCalTheme.Spacing.m)
        .contentShape(Rectangle())
    }

    private var labelText: some View {
        Text(label)
            .scaledFont(.primaryLabel)
            .foregroundStyle(tint)
    }

    private func valueText(_ value: String) -> some View {
        Text(value)
            .scaledFont(.secondaryLabel)
            .foregroundStyle(VoCalTheme.Colors.secondaryInk)
    }
}

/// Press feedback for a card row: a subtle ink wash, not opacity (opacity on a
/// row inside a card flashes the divider hairlines too).
private struct SettingsRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                VoCalTheme.Colors.ink.opacity(configuration.isPressed ? 0.05 : 0)
            )
    }
}

/// Applies an accessibility identifier only when one is provided (keeps callsites
/// terse without minting empty identifiers).
private struct OptionalA11yID: ViewModifier {
    let id: String?

    func body(content: Content) -> some View {
        if let id {
            content.accessibilityIdentifier(id)
        } else {
            content
        }
    }
}

/// A labeled value pair for read-only detail pages (Profile). Same geometry as
/// `SettingsRow` minus the icon tile — detail pages are data, not navigation.
struct SettingsDetailRow: View {
    let label: String
    let value: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // Stacked at the accessibility sizes, as `SettingsRow` is.
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) {
                    labelText
                    valueText
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack {
                    labelText
                        .layoutPriority(1)
                    Spacer()
                    valueText
                }
            }
        }
        .padding(.horizontal, VoCalTheme.Spacing.l)
        .padding(.vertical, VoCalTheme.Spacing.m)
    }

    private var labelText: some View {
        Text(label)
            .scaledFont(.secondaryLabel)
            .foregroundStyle(VoCalTheme.Colors.secondaryInk)
    }

    private var valueText: some View {
        Text(value)
            .monospacedDigit()
            .scaledFont(.primaryLabel)
            .foregroundStyle(VoCalTheme.Colors.ink)
    }
}

/// Detail-page divider (no icon inset).
struct SettingsDetailDivider: View {
    var body: some View {
        Rectangle()
            .fill(VoCalTheme.Colors.ink.opacity(0.06))
            .frame(height: 1)
            .padding(.leading, VoCalTheme.Spacing.l)
    }
}

/// A row of a list the person keeps (My foods, Learned names, Recently deleted): the item's
/// name, its lines in the secondary ink, and the one thing to do with it, trailing. The
/// action is ink, not gold (gold text on the card reads 2.2:1), and its target is 44 pt
/// square at least (finding 29, docs/restructure/04-findings.md).
struct SettingsItemRow: View {
    let title: String
    let lines: [String]
    let actionTitle: String
    let actionID: String
    var actionDisabled = false
    let action: () -> Void

    var body: some View {
        HStack(spacing: VoCalTheme.Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .scaledFont(.primaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.ink)
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .scaledFont(.formLabel)
                        .foregroundStyle(VoCalTheme.Colors.secondaryInk)
                }
            }
            Spacer(minLength: VoCalTheme.Spacing.s)
            Button(action: action) {
                Text(actionTitle)
                    .scaledFont(.formLabel.weight(.semibold))
                    .foregroundStyle(VoCalTheme.Colors.ink)
                    .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .disabled(actionDisabled)
            .accessibilityIdentifier(actionID)
        }
        .padding(.horizontal, VoCalTheme.Spacing.l)
        .padding(.vertical, VoCalTheme.Spacing.m)
    }
}

/// Shared scaffold for a pushed settings page: cream background, back-friendly
/// inline title, consistent insets.
struct SettingsPageScaffold<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            VoCalTheme.Colors.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: VoCalTheme.Spacing.l) {
                    content()
                }
                .padding(.horizontal, VoCalTheme.Spacing.l)
                .padding(.top, VoCalTheme.Spacing.s)
                .padding(.bottom, 120) // clear the floating bottom bar
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(VoCalTheme.Colors.background, for: .navigationBar)
    }
}

#Preview {
    ZStack {
        VoCalTheme.Colors.background.ignoresSafeArea()
        VStack(alignment: .leading, spacing: VoCalTheme.Spacing.s) {
            SettingsSectionLabel(title: "Account")
            SettingsCard {
                SettingsRow(icon: "person.crop.circle", label: "My details", action: {})
                SettingsDivider()
                SettingsRow(icon: "target", label: "My protocol", value: "v3", action: {})
                SettingsDivider()
                SettingsRow(icon: "calendar.badge.checkmark", label: "Weekly check-in", value: "Due", action: {})
            }
            SettingsSectionLabel(title: "Info")
                .padding(.top, VoCalTheme.Spacing.l)
            SettingsCard {
                SettingsRow(icon: "info.circle", label: "Version", value: "0.1.0 (22)")
            }
        }
        .padding()
    }
}
