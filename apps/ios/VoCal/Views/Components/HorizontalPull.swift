import SwiftUI
import UIKit

// Port provenance: Serein apps/ios/SereinApp/Sources/HorizontalPull.swift (2026-09-18),
// unchanged but for this note. Vo-Cal uses it to page the week strip on Today.

/// A pull along one horizontal direction that never fights the scroll it sits in.
///
/// A UIKit pan, not a SwiftUI DragGesture. A DragGesture on a row inside a ScrollView
/// swallowed every unhurried vertical drag: a flick scrolled, a slow finger moved nothing and
/// the row's tap fired on release (Serein, Lorenzo's phone and the simulator, 2026-09-18; the
/// same drag scrolled with the gestures removed). SwiftUI kept the drag for itself before the
/// scroll view could claim it. A pan recognizer is asked once, at the first movement, whether
/// it begins: a clearly horizontal pull in the wanted direction does, and anything else fails
/// on the spot, so the scroll view is never waiting on it. The distance is reported from the
/// touch's first point and only along the pull.
struct HorizontalPull: UIGestureRecognizerRepresentable {
    enum Direction {
        /// Toward the trailing edge (rightward in a left-to-right layout).
        case forward
        /// Toward the leading edge.
        case backward
    }

    enum Phase {
        case began
        case moved
        case ended
    }

    let direction: Direction
    var isEnabled = true
    let onChange: (Phase, CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(direction: direction)
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        // The controls under the pull keep their touch; a SwiftUI Button cancels itself once
        // the finger has moved, so a pull never ends in a stray tap.
        pan.cancelsTouchesInView = false
        pan.delegate = context.coordinator
        return pan
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.direction = direction
        recognizer.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let pulled = max(0, context.coordinator.along(recognizer.translation(in: recognizer.view)))
        switch recognizer.state {
        case .began:
            onChange(.began, pulled)
        case .changed:
            onChange(.moved, pulled)
        case .ended, .cancelled, .failed:
            onChange(.ended, pulled)
        case .possible:
            break
        @unknown default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var direction: Direction

        init(direction: Direction) {
            self.direction = direction
        }

        func along(_ translation: CGPoint) -> CGFloat {
            direction == .forward ? translation.x : -translation.x
        }

        /// Decided once, at the pan's first movement: a horizontal pull in the wanted
        /// direction begins; a vertical or opposite start fails until the finger lifts, and
        /// the scroll goes on undisturbed.
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else {
                return false
            }
            let translation = pan.translation(in: pan.view)
            return along(translation) > 0 && abs(translation.x) > abs(translation.y) * 1.5
        }

        func gestureRecognizer(
            _: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
