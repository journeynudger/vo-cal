import SwiftUI

/// Swipe a row right to edit it, left to delete it (Lorenzo, 2026-09-24), on rows that live
/// in a ScrollView, where `swipeActions` does not exist. Built on `HorizontalPull` (Serein's
/// UIKit pan, which never steals the page's vertical scroll) rather than a DragGesture.
///
/// The row follows the finger with tanh damping up to a rail; a glyph rises behind it as the
/// pull grows; crossing the threshold ticks once (`VoCalHaptics.armed`) and a release past it
/// fires the action. A release short of it snaps back. Delete plays the system warning.
struct SwipeableRow: ViewModifier {
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var offset: CGFloat = 0
    @State private var armed = false

    static let threshold: CGFloat = 72
    static let rail: CGFloat = 96

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .background { reveal }
            .gesture(HorizontalPull(direction: .forward) { phase, pulled in
                handle(phase, pulled, sign: 1)
            })
            .gesture(HorizontalPull(direction: .backward) { phase, pulled in
                handle(phase, pulled, sign: -1)
            })
            .accessibilityAction(named: "Edit", onEdit)
            .accessibilityAction(named: "Delete", onDelete)
    }

    /// What the swipe uncovers: the pencil on the leading side for a rightward pull, the
    /// trash on the trailing side for a leftward one, each fading in with the pull.
    private var reveal: some View {
        HStack {
            glyph("pencil", color: VoCalTheme.Colors.ink, visible: offset > 0)
            Spacer()
            glyph("trash", color: VoCalTheme.Colors.alert, visible: offset < 0)
        }
        .padding(.horizontal, VoCalTheme.Spacing.l)
    }

    private func glyph(_ name: String, color: Color, visible: Bool) -> some View {
        Image(systemName: name)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(color)
            .opacity(visible ? min(1, abs(offset) / Self.threshold) : 0)
            .scaleEffect(armed && visible ? 1.1 : 1)
            .animation(.snappy(duration: 0.2), value: armed)
    }

    private func handle(_ phase: HorizontalPull.Phase, _ pulled: CGFloat, sign: CGFloat) {
        switch phase {
        case .began, .moved:
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                offset = sign * Self.rail * tanh(pulled / Self.rail)
            }
            let nowArmed = pulled >= Self.threshold
            if nowArmed != armed {
                armed = nowArmed
                if nowArmed { VoCalHaptics.armed() }
            }
        case .ended:
            let fires = pulled >= Self.threshold
            withAnimation(.snappy(duration: 0.25)) { offset = 0 }
            armed = false
            guard fires else { return }
            if sign > 0 {
                onEdit()
            } else {
                VoCalHaptics.warning()
                onDelete()
            }
        }
    }
}

extension View {
    /// Swipe right to edit, left to delete; press and hold stays the row's context menu.
    func swipeable(onEdit: @escaping () -> Void, onDelete: @escaping () -> Void) -> some View {
        modifier(SwipeableRow(onEdit: onEdit, onDelete: onDelete))
    }
}
