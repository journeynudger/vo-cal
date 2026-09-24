import AVFoundation
import ImageIO
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// Port provenance: Serein apps/ios/SereinApp/Sources/CaptureCameraKit.swift. Kept: the
// photo-only session actor that never touches audio, the delegate that keeps itself alive
// until AVFoundation is done with it, the preview layer, and the full-screen camera with its
// denied and no-camera fallbacks. Changed: the preview source is Sendable with the one
// unchecked field marked nonisolated(unsafe), instead of an @unchecked Sendable type
// (TIDY-CONC-003 holds that shape to its two named bridges); the camera's colors are the
// dark-room pair in CameraChrome; the fallbacks offer the photo library in both cases.
// Added: CapturePhotoEncoding, the upload copy of a photo. Cut: CameraRollSaver (Vo-Cal
// keeps no copy of a meal photo in the person's library).

// MARK: - Upload encoding

/// The upload copy of a meal photo: an ImageIO downsample to 1600 px on the long edge, JPEG
/// at 0.8, about 300 KB from a 12 MP frame. The parser reads a plate, not pores, and a phone's
/// uplink in a restaurant is the constraint. The re-encode also drops EXIF, location
/// included: the server needs the pixels, not where the person ate.
enum CapturePhotoEncoding {
    static let uploadMaxDimension: CGFloat = 1600
    static let uploadQuality: CGFloat = 0.8
    static let thumbnailMaxDimension: CGFloat = 480

    /// Bytes that do not decode or encode as an image come back unchanged: a photo is never
    /// dropped for being unusual, it only travels larger.
    static func jpeg(
        from data: Data,
        maxDimension: CGFloat = CapturePhotoEncoding.uploadMaxDimension,
        quality: CGFloat = CapturePhotoEncoding.uploadQuality
    ) -> Data {
        guard let image = downsample(data, maxDimension: maxDimension) else { return data }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return data }
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return data }
        return output as Data
    }

    /// The chip's thumbnail: never decode a 48 MP photo just to draw 76 points of it.
    static func thumbnail(
        from data: Data,
        maxDimension: CGFloat = CapturePhotoEncoding.thumbnailMaxDimension
    ) -> UIImage? {
        downsample(data, maxDimension: maxDimension).map { UIImage(cgImage: $0) }
    }

    /// `jpeg(from:)` off the main actor, where the send button's Task would otherwise
    /// decode and compress a full photo between two frames.
    @concurrent
    static func uploadJPEG(from data: Data) async -> Data {
        jpeg(from: data)
    }

    /// Always from the full image (an embedded EXIF thumbnail is 160 px), with the EXIF
    /// orientation applied so a portrait photo does not arrive on its side.
    private static func downsample(_ data: Data, maxDimension: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

// MARK: - Session

enum CaptureCameraError: LocalizedError {
    case cameraUnavailable
    case captureFailed

    var errorDescription: String? {
        switch self {
        case .cameraUnavailable: "The camera is not available on this device."
        case .captureFailed: "That photo did not come through. Try again."
        }
    }
}

/// Hands the capture session to the main-actor preview layer.
///
/// `AVCaptureSession` is not Sendable (iOS 26.5 SDK), but this one handoff is safe: the
/// owning actor only touches configuration and lifecycle (serialized by the actor), while the
/// main-actor preview layer only attaches to the session and renders its frames, the split
/// Apple's AVCam sample uses under strict concurrency (carried from Beacon's
/// StoryCameraSession through Serein). The unchecked claim sits on the one field that makes
/// it, not on the type. Reading an actor's own `nonisolated(unsafe)` property from the main
/// actor instead stops the Swift 6.3 region checker ("pattern that the region-based
/// isolation checker does not understand", 2026-09-24).
struct CaptureCameraPreviewSource: Sendable {
    nonisolated(unsafe) let session: AVCaptureSession
}

/// Photo-only capture for a meal photo.
///
/// The one non-negotiable: THIS SESSION MUST NEVER TOUCH AUDIO. A voice recording may be live
/// when the camera opens, and capture is sacred (docs/INVARIANTS.md), so there is no audio
/// input, no movie output, and `automaticallyConfiguresApplicationAudioSession` is false so
/// AVFoundation does not reconfigure the recorder's audio session behind its back. Serein
/// verified this by design, not yet on a device (the simulator has no camera); the voice
/// kernel's own liveness checks are the backstop either way.
actor CaptureCameraSession {
    let preview = CaptureCameraPreviewSource(session: AVCaptureSession())

    private var session: AVCaptureSession { preview.session }
    private let photoOutput = AVCapturePhotoOutput()
    private var currentInput: AVCaptureDeviceInput?
    private var position: AVCaptureDevice.Position = .back
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    /// Keeps capture delegates alive until AVFoundation finishes with them.
    private var activeDelegates: [Int64: PhotoCaptureDelegate] = [:]

    static var hasCamera: Bool {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil
            || AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) != nil
    }

    func configureAndStart() throws {
        if session.inputs.isEmpty {
            session.beginConfiguration()
            // The voice kernel owns the app's audio session. Without this flag, adding inputs
            // or starting the session can silently reroute or deactivate it mid-recording.
            session.automaticallyConfiguresApplicationAudioSession = false
            session.sessionPreset = .photo
            do {
                try attachInput(position: .back)
            } catch {
                session.commitConfiguration()
                throw error
            }
            guard session.canAddOutput(photoOutput) else {
                session.commitConfiguration()
                throw CaptureCameraError.cameraUnavailable
            }
            session.addOutput(photoOutput)
            // Set on the OUTPUT at configuration time, before any per-shot
            // photoQualityPrioritization = .quality: raising one capture above the output's
            // ceiling throws NSInvalidArgumentException (learned in Beacon, kept in Serein).
            photoOutput.maxPhotoQualityPrioritization = .quality
            session.commitConfiguration()

            // Deliberately a second configuration block: the preset and input settle the
            // device's activeFormat, and the dimension pick below reads that format. Asking
            // before the first block commits can report the outgoing format's capabilities.
            session.beginConfiguration()
            applyPhotoDimensions()
            session.commitConfiguration()
        }
        if !session.isRunning {
            session.startRunning()
        }
    }

    func stop() {
        if session.isRunning {
            session.stopRunning()
        }
    }

    func flipCamera() {
        let next: AVCaptureDevice.Position = position == .back ? .front : .back
        session.beginConfiguration()
        if let currentInput {
            session.removeInput(currentInput)
        }
        do {
            try attachInput(position: next)
        } catch {
            // Put the old input back rather than leave a black preview.
            if let currentInput, session.canAddInput(currentInput) {
                session.addInput(currentInput)
            }
        }
        applyPhotoDimensions()
        session.commitConfiguration()
    }

    func capturePhoto() async throws -> Data {
        let settings: AVCapturePhotoSettings
        if photoOutput.availablePhotoCodecTypes.contains(.jpeg) {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        } else {
            settings = AVCapturePhotoSettings()
        }
        // Without these the still inherits the preset's dimensions and .balanced processing:
        // a 2 MP frame with no photo fusion on a sensor capable of far more.
        settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        settings.photoQualityPrioritization = .quality
        if let connection = photoOutput.connection(with: .video) {
            if let rotationCoordinator {
                connection.videoRotationAngle = rotationCoordinator.videoRotationAngleForHorizonLevelCapture
            }
            if position == .front, connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
            }
        }

        let settingsID = settings.uniqueID
        return try await withCheckedThrowingContinuation { continuation in
            let delegate = PhotoCaptureDelegate(continuation: continuation) { [weak self] in
                Task { await self?.finishCapture(settingsID: settingsID) }
            }
            activeDelegates[settingsID] = delegate
            photoOutput.capturePhoto(with: settings, delegate: delegate)
        }
    }

    private func finishCapture(settingsID: Int64) {
        activeDelegates.removeValue(forKey: settingsID)
    }

    private func attachInput(position: AVCaptureDevice.Position) throws {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
            throw CaptureCameraError.cameraUnavailable
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw CaptureCameraError.cameraUnavailable
        }
        session.addInput(input)
        currentInput = input
        self.position = position
        rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
    }

    /// Pins maxPhotoDimensions to the largest still matching the preview's own aspect (1%
    /// tolerance), falling back to the exact stream size: Beacon's supersampling-friendly pick.
    private func applyPhotoDimensions() {
        guard let format = currentInput?.device.activeFormat else { return }
        let video = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        guard video.width > 0, video.height > 0 else { return }
        let previewAspect = Double(video.width) / Double(video.height)

        let sameAspect = format.supportedMaxPhotoDimensions.filter { candidate in
            guard candidate.height > 0 else { return false }
            let aspect = Double(candidate.width) / Double(candidate.height)
            return abs(aspect - previewAspect) / previewAspect < 0.01
        }
        let exact = sameAspect.first { $0.width == video.width && $0.height == video.height }
        let largest = sameAspect.max { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }
        if let chosen = largest ?? exact {
            photoOutput.maxPhotoDimensions = chosen
        }
    }
}

private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let continuation: CheckedContinuation<Data, any Error>
    private let onFinish: @Sendable () -> Void
    private var resumed = false

    init(continuation: CheckedContinuation<Data, any Error>, onFinish: @escaping @Sendable () -> Void) {
        self.continuation = continuation
        self.onFinish = onFinish
    }

    func photoOutput(_: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: (any Error)?) {
        defer { onFinish() }
        guard !resumed else { return }
        resumed = true
        if let error {
            continuation.resume(throwing: error)
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            continuation.resume(throwing: CaptureCameraError.captureFailed)
            return
        }
        continuation.resume(returning: data)
    }
}

// MARK: - Preview layer

private struct CameraPreview: UIViewRepresentable {
    let source: CaptureCameraPreviewSource

    final class PreviewView: UIView {
        override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var previewLayer: AVCaptureVideoPreviewLayer? { layer as? AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context _: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer?.session = source.session
        view.previewLayer?.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_: PreviewView, context _: Context) {}
}

// MARK: - Camera page

/// The camera is a dark room whatever the app's theme: the preview is the light, and the
/// chrome over it reads white on shadowed glass. Private tokens until the theme has a camera
/// section (VoCalTheme is light-only).
private enum CameraChrome {
    static let surface = Color.black
    static let ink = Color.white
    static let secondaryInk = Color.white.opacity(0.72)
    /// A shadow in the glass so a white glyph holds over a bright plate.
    static let glassTint = Color.black.opacity(0.18)
    /// Reduce Transparency: a flat smoke disc instead of glass (the app's cream fallback
    /// would put a white glyph on cream).
    static let reducedFill = Color.white.opacity(0.18)
    static let hairline = Color.white.opacity(0.35)
}

/// Full-screen photo capture that never touches the audio session. Where there is no camera
/// (the simulator), no permission, or no camera purpose string, it becomes a door to the
/// photo library, so the attach-a-photo flow is walkable everywhere.
struct CaptureCameraView: View {
    /// Called with the captured or picked photo's bytes, just before the page dismisses.
    let onPhoto: (Data) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var camera = CaptureCameraSession()
    @State private var phase: Phase = .starting
    @State private var capturing = false
    @State private var librarySelection: PhotosPickerItem?
    @State private var notice: String?

    private enum Phase: Equatable {
        case starting
        case live
        case denied
        case unavailable
    }

    var body: some View {
        ZStack {
            CameraChrome.surface.ignoresSafeArea()

            switch phase {
            case .starting:
                ProgressView()
                    .tint(CameraChrome.ink)
            case .live:
                CameraPreview(source: camera.preview)
                    .ignoresSafeArea()
            case .denied:
                deniedFallback
            case .unavailable:
                unavailableFallback
            }

            VStack(spacing: VoCalTheme.Spacing.l) {
                HStack {
                    chromeButton("xmark", label: "Close camera", identifier: CaptureA11y.cameraClose) {
                        dismiss()
                    }
                    Spacer()
                    if phase == .live {
                        chromeButton("arrow.triangle.2.circlepath", label: "Flip camera", identifier: CaptureA11y.cameraFlip) {
                            let camera = camera
                            Task { await camera.flipCamera() }
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, VoCalTheme.Spacing.s)

                Spacer()

                if let notice {
                    Text(notice)
                        .font(VoCalTheme.Fonts.secondaryLabel)
                        .foregroundStyle(CameraChrome.ink)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, VoCalTheme.Spacing.xl)
                        .transition(.opacity)
                }

                if phase == .live {
                    shutter
                        .padding(.bottom, 28)
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: notice)
        .task {
            await start()
        }
        .onDisappear {
            let camera = camera
            Task { await camera.stop() }
        }
        .onChange(of: librarySelection) { _, item in
            guard let item else { return }
            librarySelection = nil
            Task { await deliver(item) }
        }
        .task(id: notice) {
            guard notice != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            notice = nil
        }
    }

    // MARK: pieces

    private var shutter: some View {
        Button(action: shoot) {
            ZStack {
                Circle()
                    .strokeBorder(CameraChrome.ink, lineWidth: 4)
                    .frame(width: 76, height: 76)
                Circle()
                    .fill(CameraChrome.ink)
                    .frame(width: 62, height: 62)
                    .scaleEffect(capturing ? 0.82 : 1)
            }
            .contentShape(Circle())
        }
        .buttonStyle(ShutterButtonStyle())
        .disabled(capturing)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: capturing)
        .accessibilityLabel("Take photo")
        .accessibilityIdentifier(CaptureA11y.cameraShutter)
    }

    private func chromeButton(
        _ systemName: String,
        label: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(CameraChrome.ink)
                .frame(width: 44, height: 44)
                .modifier(CameraGlass())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    private var deniedFallback: some View {
        fallback(
            symbol: "camera.badge.ellipsis",
            title: "Camera access is off",
            detail: "Turn it on in Settings to photograph a meal, or choose a photo you already took."
        ) {
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Self.pillLabel("Open Settings", filled: true)
            }
            .buttonStyle(PressableButtonStyle())
            libraryPicker(filled: false)
        }
    }

    private var unavailableFallback: some View {
        fallback(
            symbol: "camera.on.rectangle",
            title: "No camera here",
            detail: "Choose a photo of the meal from your library."
        ) {
            libraryPicker(filled: true)
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
                .foregroundStyle(CameraChrome.secondaryInk)
            Text(title)
                .font(VoCalTheme.Fonts.screenTitle)
                .foregroundStyle(CameraChrome.ink)
            Text(detail)
                .font(VoCalTheme.Fonts.secondaryLabel)
                .foregroundStyle(CameraChrome.secondaryInk)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            VStack(spacing: VoCalTheme.Spacing.m) {
                actions()
            }
            .padding(.top, VoCalTheme.Spacing.s)
        }
    }

    private func libraryPicker(filled: Bool) -> some View {
        PhotosPicker(selection: $librarySelection, matching: .images) {
            Self.pillLabel("Choose a photo", filled: filled)
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityIdentifier(CaptureA11y.cameraLibrary)
    }

    /// The camera's pills invert the app's: on the dark room the primary is a white pill with
    /// ink, the secondary a white hairline. Nonisolated because PhotosPicker builds its label
    /// in a @Sendable closure (iOS 26.5 SDK).
    private nonisolated static func pillLabel(_ title: String, filled: Bool) -> some View {
        Text(title)
            .font(VoCalTheme.Fonts.buttonLabel)
            .foregroundStyle(filled ? VoCalTheme.Colors.ink : CameraChrome.ink)
            .padding(.horizontal, 22)
            .frame(height: 48)
            .background {
                if filled {
                    Capsule().fill(CameraChrome.ink)
                } else {
                    Capsule().strokeBorder(CameraChrome.hairline, lineWidth: 1)
                }
            }
            .contentShape(Capsule())
    }

    // MARK: actions

    /// Checks before asking, then asks before configuring (Beacon's StoryCameraView order).
    /// Video permission only: this page must never request the microphone, which the voice
    /// kernel owns.
    private func start() async {
        // No purpose string is not a permission prompt, it is a process kill: TCC aborts an
        // app that asks for the camera without NSCameraUsageDescription. Until Info.plist
        // carries it, the page is the library door instead of a crash.
        guard Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") != nil,
              CaptureCameraSession.hasCamera
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
        do {
            try await camera.configureAndStart()
            phase = .live
        } catch {
            phase = .unavailable
        }
    }

    private func shoot() {
        capturing = true
        let camera = camera
        Task {
            defer { capturing = false }
            do {
                let data = try await camera.capturePhoto()
                onPhoto(data)
                dismiss()
            } catch {
                notice = CaptureCameraError.captureFailed.errorDescription
            }
        }
    }

    private func deliver(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            notice = "That photo did not load. Try another one."
            return
        }
        onPhoto(data)
        dismiss()
    }
}

/// Clear glass shadowed for the dark room, interactive, with a flat fallback under Reduce
/// Transparency. Not `liquidGlass`: its cream fallback would hide a white glyph.
private struct CameraGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(Circle().fill(CameraChrome.reducedFill))
        } else {
            content
                .glassEffect(.clear.tint(CameraChrome.glassTint).interactive(), in: Circle())
        }
    }
}

/// The shutter answers the finger twice: a light click on touch-down (the same click as
/// every Vo-Cal button) and the inner disc giving under the press.
private struct ShutterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { VoCalHaptics.tap() }
            }
    }
}

#Preview("Camera, no camera here") {
    CaptureCameraView { _ in }
}
