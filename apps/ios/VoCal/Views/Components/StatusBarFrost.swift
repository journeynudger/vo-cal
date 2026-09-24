import SwiftUI

/// A frosted strip under the status bar so scrolling content passes beneath the time and
/// battery instead of colliding with them (Lorenzo, 2026-09-24: "the top tool bar should be
/// blurred, the elements of the app are superimposed by the time and battery"). Today,
/// Settings and the result have no navigation bar to blur, so this is their bar: a
/// zero-height view pinned to the top whose material background extends into the safe area.
/// Never hit-testable; the content underneath keeps every gesture.
struct StatusBarFrost: View {
    var body: some View {
        Color.clear
            .frame(height: 0)
            .background(.ultraThinMaterial, ignoresSafeAreaEdges: .top)
            .allowsHitTesting(false)
    }
}

extension View {
    /// Pin a frosted strip under the status bar. Apply to the scrolling surface itself.
    func frostedStatusBar() -> some View {
        overlay(alignment: .top) { StatusBarFrost() }
    }
}
