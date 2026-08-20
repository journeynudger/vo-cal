import SwiftUI

/// Shared building blocks for the Settings surface: grouped cards of rows in the
/// black/gold system. The shape follows the grouped-inset pattern of a professional
/// settings screen — icon tile · label · optional value · chevron — rendered with
/// VoCalTheme tokens only (no system List, so the cream background and r24 cards
/// match the rest of the app instead of UIKit's grouped grays).

/// Section label above a card: the app's one overline treatment, in muted (gold
/// stays reserved for accents; a wall of gold headers reads loud, not premium).
struct SettingsSectionLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .sectionHeader(VoCalTheme.Colors.muted)
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

/// One settings row. `value` renders trailing-muted (e.g. "On", "Due"). `tint`
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
            Text(label)
                .font(VoCalTheme.Fonts.primaryLabel)
                .foregroundStyle(tint)
            Spacer(minLength: VoCalTheme.Spacing.s)
            if let value {
                Text(value)
                    .font(VoCalTheme.Fonts.secondaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
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

    var body: some View {
        HStack {
            Text(label)
                .font(VoCalTheme.Fonts.secondaryLabel)
                .foregroundStyle(VoCalTheme.Colors.muted)
            Spacer()
            Text(value)
                .font(VoCalTheme.Fonts.primaryLabel)
                .monospacedDigit()
                .foregroundStyle(VoCalTheme.Colors.ink)
        }
        .padding(.horizontal, VoCalTheme.Spacing.l)
        .padding(.vertical, VoCalTheme.Spacing.m)
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
