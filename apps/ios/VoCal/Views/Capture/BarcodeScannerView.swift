import AVFoundation
import SwiftUI
import UIKit
import Vision
import VisionKit

enum ScannerA11y {
    static let screen = "scanner.screen"
    static let close = "scanner.close"
    static let manualField = "scanner.manual-field"
    static let manualSubmit = "scanner.manual-submit"
    static let sample = "scanner.sample"
    static let openSettings = "scanner.open-settings"
}

/// The dark room of the meal-photo camera (`CameraChrome` in CaptureCameraKit.swift, private
/// there), for the barcode page: the camera is the light, the chrome reads white over it.
/// Black and white are the system's own, never a hex.
private enum ScannerChrome {
    static let surface = Color.black
    static let ink = Color.white
    static let hint = Color.white.opacity(0.8)
    static let secondaryInk = Color.white.opacity(0.72)
    /// The manual-entry capsule: a faint lift off the black, with a hairline.
    static let fieldFill = Color.white.opacity(0.12)
    static let hairline = Color.white.opacity(0.35)
    /// Keeps white type legible when the plate under it is bright.
    static let legibility = Color.black.opacity(0.35)
}

/// Full-screen barcode scanner. Calls `onFound` with the number once, from the camera or from
/// the manual field, and leaves the page to the host: the host dismisses it (or presents the
/// found food over it). A scanned code arrives as the camera read it; the lookup service
/// decides whether it is a food barcode. The camera reports one code per presentation, so
/// present a fresh scanner to scan again.
///
/// Three doors, one page: the live camera (VisionKit) where the device has it and the person
/// allowed it, and, always, a field to type the number. The field is the whole page on the
/// simulator (VisionKit does not run there) and when the camera is off, so a person who
/// cannot or will not point a camera can still log what is on the box.
struct BarcodeScannerView: View {
    let onFound: (String) -> Void
    let onClose: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var phase: Phase
    @State private var manualCode = ""
    @FocusState private var fieldFocused: Bool

    private enum Phase: Equatable {
        /// Asking, or about to ask, for the camera.
        case checking
        case live
        /// The person said no, or the device is restricted.
        case denied
        /// No scanner on this device (the simulator), no purpose string, or the scanner failed
        /// to start. The manual field carries the page.
        case unavailable
    }

    init(onFound: @escaping (String) -> Void, onClose: @escaping () -> Void) {
        self.onFound = onFound
        self.onClose = onClose
        // Decided before the first frame where it can be: on the simulator the page opens on
        // its manual door instead of flashing a spinner first.
        _phase = State(initialValue: DataScannerViewController.isSupported ? .checking : .unavailable)
    }

    var body: some View {
        ZStack {
            ScannerChrome.surface.ignoresSafeArea()

            if phase == .live {
                CameraScanner(onCode: onFound, onFailure: { phase = .unavailable })
                    .ignoresSafeArea()
            }

            VStack(spacing: 0) {
                header
                viewport
                bottomBar
            }
        }
        // The page is a dark room: its own controls (the number pad, the field) take the dark
        // scheme through the environment, which stops at this view. `preferredColorScheme`
        // instead reaches the presenter, and the sheet presented right after the scanner
        // closed came up dark on a light-only app (2026-11-06, the scanned-food sheet with a
        // grey glass card). The status bar is hidden the way the Camera app hides it.
        .environment(\.colorScheme, .dark)
        .statusBarHidden(true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(ScannerA11y.screen)
        .task {
            guard phase == .checking else { return }
            await start()
        }
        // Back from Settings with the camera switched on: pick up where the person left off.
        .onChange(of: scenePhase) { _, new in
            guard new == .active, phase == .denied else { return }
            Task { await start() }
        }
        .onChange(of: manualCode) { _, new in
            let digits = Self.digitsOnly(new)
            if digits != new { manualCode = digits }
        }
    }

    // MARK: pieces

    private var header: some View {
        ZStack {
            Text("Scan a barcode")
                .font(VoCalTheme.Fonts.screenTitle)
                .foregroundStyle(ScannerChrome.ink)
                .shadow(color: ScannerChrome.legibility, radius: 3)
                .accessibilityAddTraits(.isHeader)
            HStack {
                closeButton
                Spacer()
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, VoCalTheme.Spacing.s)
    }

    /// 36 pt of glass inside a 44 pt target: glass contributes no hit region of its own, so
    /// the shape is named (LiquidGlass.swift, 2026-09-24).
    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(ScannerChrome.ink)
                .frame(width: 36, height: 36)
                .glassEffect(.regular, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("Close")
        .accessibilityIdentifier(ScannerA11y.close)
    }

    /// Everything between the title and the manual field: the viewfinder over the live camera,
    /// or the calm fallback that stands in for it.
    @ViewBuilder
    private var viewport: some View {
        Group {
            switch phase {
            case .checking:
                ProgressView()
                    .tint(ScannerChrome.ink)
            case .live:
                viewfinder
            case .denied:
                fallback(
                    symbol: "barcode.viewfinder",
                    title: "Camera access is off",
                    detail: "Turn it on in Settings to scan a barcode, or type the number below."
                ) {
                    linkButton("Open Settings", identifier: ScannerA11y.openSettings) {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
            case .unavailable:
                fallback(
                    symbol: "barcode.viewfinder",
                    title: "No camera here",
                    detail: "Type the number printed under the barcode below."
                ) {}
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var viewfinder: some View {
        VStack(spacing: VoCalTheme.Spacing.l) {
            ViewfinderBrackets()
                .stroke(ScannerChrome.ink, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                .frame(width: 220, height: 150)
                .shadow(color: ScannerChrome.legibility, radius: 3)
                .accessibilityHidden(true)
            Text("Line up the barcode. It reads on its own.")
                .font(VoCalTheme.Fonts.secondaryLabel)
                .foregroundStyle(ScannerChrome.hint)
                .shadow(color: ScannerChrome.legibility, radius: 3)
                .multilineTextAlignment(.center)
                .padding(.horizontal, VoCalTheme.Spacing.xl)
        }
    }

    private func fallback<Actions: View>(
        symbol: String,
        title: String,
        detail: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(spacing: 18) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(ScannerChrome.secondaryInk)
                .accessibilityHidden(true)
            Text(title)
                .font(VoCalTheme.Fonts.screenTitle)
                .foregroundStyle(ScannerChrome.ink)
            Text(detail)
                .font(VoCalTheme.Fonts.secondaryLabel)
                .foregroundStyle(ScannerChrome.secondaryInk)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            actions()
        }
    }

    // MARK: manual door

    private var bottomBar: some View {
        VStack(spacing: VoCalTheme.Spacing.s) {
            manualEntry
            #if DEBUG
            // Reachable only on the mock path: the simulator has no camera and no barcode to
            // hold up, and a render test needs a way into the found-food sheet.
            if RuntimeMode.usesMockServices {
                linkButton("Use a sample barcode", identifier: ScannerA11y.sample) {
                    onFound(MockBarcodeService.sampleCode)
                }
            }
            #endif
        }
        .padding(.horizontal, VoCalTheme.Spacing.l)
        .padding(.bottom, VoCalTheme.Spacing.l)
    }

    private var manualEntry: some View {
        HStack(spacing: VoCalTheme.Spacing.s) {
            TextField(
                "Barcode number",
                text: $manualCode,
                prompt: Text("Type the barcode number").foregroundStyle(ScannerChrome.secondaryInk)
            )
            .keyboardType(.numberPad)
            .textContentType(.none)
            .autocorrectionDisabled()
            .font(VoCalTheme.Fonts.body)
            .monospacedDigit()
            .foregroundStyle(ScannerChrome.ink)
            .tint(ScannerChrome.ink)
            .focused($fieldFocused)
            .submitLabel(.search)
            .onSubmit(submitManual)
            .accessibilityIdentifier(ScannerA11y.manualField)
            // A number pad has no return key: this is the way back to the camera.
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { fieldFocused = false }
                }
            }

            Button(action: submitManual) {
                Text("Find it")
                    .font(VoCalTheme.Fonts.buttonLabel)
                    .foregroundStyle(VoCalTheme.Colors.ink)
                    .padding(.horizontal, 18)
                    .frame(height: 44)
                    .background(Capsule().fill(ScannerChrome.ink))
                    .contentShape(Capsule())
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(manualDigits.isEmpty)
            .opacity(manualDigits.isEmpty ? 0.45 : 1)
            .accessibilityIdentifier(ScannerA11y.manualSubmit)
        }
        .padding(.leading, 20)
        .padding(.trailing, 6)
        .frame(height: 56)
        .background(Capsule().fill(ScannerChrome.fieldFill))
        .overlay(Capsule().strokeBorder(ScannerChrome.hairline, lineWidth: 1))
    }

    /// A text link in the dark room's ink, with a 44 pt target (`VoCalButton(kind: .tertiary)`
    /// is as tall as its words, and its muted gray is the light theme's).
    private func linkButton(_ title: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(VoCalTheme.Fonts.buttonLabel)
                .foregroundStyle(ScannerChrome.secondaryInk)
                .padding(.horizontal, VoCalTheme.Spacing.l)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityIdentifier(identifier)
    }

    // MARK: actions

    private var manualDigits: String { Self.digitsOnly(manualCode) }

    private static func digitsOnly(_ text: String) -> String {
        String(text.filter { $0.isASCII && $0.isNumber }.prefix(BarcodeCode.maxLength))
    }

    private func submitManual() {
        let digits = manualDigits
        guard !digits.isEmpty else { return }
        fieldFocused = false
        onFound(digits)
    }

    /// Asks before showing the scanner, and never for the microphone: the voice kernel owns
    /// that, and this page is video only. No purpose string is not a permission prompt, it
    /// is a process kill (TCC aborts an app that asks without one), so a build that lacks it
    /// gets the manual door instead of a crash (the same guard as CaptureCameraView).
    private func start() async {
        guard DataScannerViewController.isSupported,
              Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") != nil
        else {
            phase = .unavailable
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                phase = .denied
                return
            }
        case .denied, .restricted:
            phase = .denied
            return
        case .authorized:
            break
        @unknown default:
            break
        }
        phase = DataScannerViewController.isAvailable ? .live : .unavailable
    }
}

// MARK: - Camera

/// VisionKit's scanner, on its own: it starts when the page appears and stops when it goes,
/// and its delegate hands back the first barcode payload it reads.
///
/// THE AUDIO RULE (docs/INVARIANTS.md, and CaptureCameraSession's): a camera page must never
/// touch the audio session, because a voice recording may be live when it opens. VisionKit's
/// scanner is video only and never configures or activates the app's audio session, so
/// there is nothing to switch off here, and no AVAudio code belongs in this file.
private struct CameraScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onFailure: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode)
    }

    func makeUIViewController(context: Context) -> ScannerHost {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.ean13, .ean8, .upce, .code128, .qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            // The page says what to do in its own words, once.
            isGuidanceEnabled: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        let host = ScannerHost(scanner: scanner)
        host.onStartFailure = onFailure
        return host
    }

    func updateUIViewController(_ host: ScannerHost, context: Context) {
        context.coordinator.onCode = onCode
        host.onStartFailure = onFailure
    }

    static func dismantleUIViewController(_ host: ScannerHost, coordinator _: Coordinator) {
        host.stop()
    }

    /// Holds the scanner as a child so the page owns when it runs: `startScanning()` needs
    /// the view on screen, so it starts from `viewDidAppear` (not from `makeUIViewController`)
    /// and stops from `viewWillDisappear`. `DataScannerViewController` is not open, so it is
    /// contained, not subclassed. A failure to start (the camera is in use, say) is the
    /// page's cue to fall back to the manual door.
    final class ScannerHost: UIViewController {
        private let scanner: DataScannerViewController
        var onStartFailure: (() -> Void)?

        init(scanner: DataScannerViewController) {
            self.scanner = scanner
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("ScannerHost is built in code")
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            addChild(scanner)
            scanner.view.frame = view.bounds
            scanner.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(scanner.view)
            scanner.didMove(toParent: self)
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            do {
                try scanner.startScanning()
            } catch {
                onStartFailure?()
            }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            stop()
        }

        func stop() {
            scanner.stopScanning()
        }
    }

    /// Reports the first barcode with a readable payload, once. The scanner keeps firing as
    /// the same barcode is re-recognized, and the host must not be asked to look it up twice.
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onCode: (String) -> Void
        private var reported = false

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
        }

        func dataScanner(_: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems _: [RecognizedItem]) {
            report(addedItems)
        }

        /// A payload can arrive a frame after the item does.
        func dataScanner(_: DataScannerViewController, didUpdate updatedItems: [RecognizedItem], allItems _: [RecognizedItem]) {
            report(updatedItems)
        }

        func dataScanner(_: DataScannerViewController, didTapOn item: RecognizedItem) {
            report([item])
        }

        private func report(_ items: [RecognizedItem]) {
            guard !reported else { return }
            for item in items {
                guard case let .barcode(barcode) = item,
                      let payload = barcode.payloadStringValue, !payload.isEmpty
                else { continue }
                reported = true
                VoCalHaptics.success()
                onCode(payload)
                return
            }
        }
    }
}

// MARK: - Viewfinder

/// Four corner brackets of a rounded rectangle: an L at each corner, the sides left open.
private struct ViewfinderBrackets: Shape {
    var arm: CGFloat = 30
    var radius: CGFloat = 14

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = radius
        let a = arm

        path.move(to: CGPoint(x: rect.minX, y: rect.minY + a))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + a, y: rect.minY))

        path.move(to: CGPoint(x: rect.maxX - a, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + a))

        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - a))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - a, y: rect.maxY))

        path.move(to: CGPoint(x: rect.minX + a, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - a))

        return path
    }
}

#Preview("Scanner, no camera here") {
    BarcodeScannerView(onFound: { _ in }, onClose: {})
}
