import SwiftUI

/// The way to Settings: one 44 pt glass circle in the top trailing corner with the person
/// glyph (the reference icon Lorenzo picked, 2026-09-24), in place of the tab bar's small
/// muted glyph. 44 pt is the hit target the accessibility audit asks for and the size a
/// thumb finds without looking.
struct ProfileCircleButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "person.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(VoCalTheme.Colors.ink)
                .frame(width: 44, height: 44)
                // The droplets' bright face (CaptureBar.dropletFace): one face for every round
                // glass control on the page.
                .liquidGlass(in: Circle(), tint: CaptureBar.dropletFace, interactive: true)
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("Profile")
        .accessibilityIdentifier(A11y.Today.profileButton)
    }
}

#Preview {
    ProfileCircleButton {}
        .padding()
        .background(VoCalTheme.Colors.background)
}
