import SwiftUI
import UIKit
import XCTest
@testable import VoCal

/// The fast UI loop (docs/UI_VERIFICATION.md): a SwiftUI view rendered to a PNG in a unit
/// test, no simulator navigation, no app launch. Deterministic by construction: a fixed
/// 393 pt width at 3x, a solid background behind any material (Liquid Glass blurs whatever
/// sits behind it, so an unstable background is diff noise), animations disabled, light
/// appearance (Vo-Cal ships light only), and an injected Dynamic Type size.
///
/// Hosted in a real window and drawn with drawHierarchy, NOT ImageRenderer. Found on the
/// first recording (2026-09-24): ImageRenderer draws nothing inside a ScrollView, so every
/// scrolling screen (Today, the result, the sheets) recorded as a blank page and the tests
/// passed against blank goldens. A loop that cannot see the content is worse than none.
@MainActor
enum RenderHarness {
    static let width: CGFloat = 393
    /// 3x, the pinned simulator's own scale. A 2x context was tried to shrink the goldens
    /// and did the opposite (7.6 MB against 6.4 MB): `drawHierarchy` resamples the 3x window
    /// into it, every pixel becomes unique, and the result confirmed view stopped matching
    /// its own golden between two runs (2026-09-24). At 3x the blit is 1:1 and stable.
    nonisolated static let scale: CGFloat = 3
    static let outputDirectory = URL(fileURLWithPath: "/tmp/ui", isDirectory: true)

    static func render<V: View>(
        _ view: V,
        name: String,
        height: CGFloat = 900,
        dynamicType: DynamicTypeSize = .large
    ) throws -> UIImage {
        UIView.setAnimationsEnabled(false)
        let content = view
            .environment(\.colorScheme, .light)
            .environment(\.dynamicTypeSize, dynamicType)
            .transaction { $0.disablesAnimations = true }
            .frame(width: width, height: height)
            .background(VoCalTheme.Colors.background)
        let host = UIHostingController(rootView: content)
        host.view.backgroundColor = UIColor(VoCalTheme.Colors.background)
        // A window with no scene draws nothing through drawHierarchy on iOS 26 (the second
        // blank recording, 2026-09-24); the test host app's scene is the one to attach to.
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: .zero)
        }
        window.frame = CGRect(x: 0, y: 0, width: width, height: height)
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        // Turns of the run loop so SwiftUI commits its first layout and any @State set
        // during appearance (the result screen's sheet bindings, Today's sections).
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        // Standard-range sRGB, 8 bits: the golden is a PNG decoded back to sRGB, and the
        // library's perceptual compare runs with colour management off. With the renderer's
        // default (extended range on a wide-colour simulator) an identical render still
        // showed 0.22 percent of its pixels beyond the colour threshold whenever the byte
        // compare did not short-circuit (2026-09-24), which made every golden with a glass
        // control flaky. Same space on both sides, the baseline is zero.
        format.preferredRange = .standard
        format.opaque = true
        var image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        if isBlank(image) {
            // drawHierarchy needs the compositor; the layer tree does not. Same pixels for
            // SwiftUI content, minus UIKit-only effects (which these screens do not use).
            image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { context in
                window.layer.render(in: context.cgContext)
            }
        }
        window.isHidden = true
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try image.pngData()?.write(to: outputDirectory.appendingPathComponent("\(name).png"))
        guard !isBlank(image) else { throw RenderError.blank(name) }
        return image
    }

    /// A rendered page that is one flat colour is the harness failing, never a golden.
    static func isBlank(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage else { return true }
        let width = cg.width, height = cg.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return true }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        let first = (data[0], data[1], data[2])
        var samples = 0
        var differing = 0
        var offset = 0
        let stride = max(4, (width * height * 4) / 20_000 / 4 * 4)
        while offset + 2 < data.count {
            samples += 1
            if abs(Int(data[offset]) - Int(first.0)) + abs(Int(data[offset + 1]) - Int(first.1)) + abs(Int(data[offset + 2]) - Int(first.2)) > 24 {
                differing += 1
            }
            offset += stride
        }
        return samples == 0 || Double(differing) / Double(samples) < 0.005
    }

    enum RenderError: Error {
        case blank(String)
    }
}
