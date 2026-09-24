import PhotosUI
import SwiftUI
import UIKit

// Port provenance: Serein apps/ios/SereinApp/Sources/CaptureBar.swift, with the glass circle
// from GlassChrome.swift. Kept to the letter this time (Lorenzo, 2026-09-24: "exactly like
// Serein"): the plus and the mic as twin droplets, the attachment menu growing out of the
// plus's droplet and owning the row while it is open, the composing card that takes the whole
// row with the staged photo inside its top corner and the plus and the send in its bottom
// corners, the field that grows with the words and keeps Return as a newline, the dead zone
// above the row, and the one compose spring. Changed: Vo-Cal's palette and glass
// (`liquidGlass`), the mic opens the full-screen voice capture instead of recording in the
// bar, the send is the Vo-Cal mark, one photo instead of a gallery, answers from the person's
// history rise above the bar while they type, and the shell presents the camera and the
// library (Serein's home presents the camera too; a cover raised from inside a safe-area
// inset is one more thing that can quietly not happen). Cut: the recording pill and stop
// square, the note typed during a take, the thread chip, the file importer and the saved
// flash; none of them is a Vo-Cal surface.

/// Accessibility identifiers for the capture surfaces (UI tests reference these, never
/// display strings). Here until the shell promotes them into `A11y`.
enum CaptureA11y {
    static let bar = "capture.bar"
    static let field = "capture.field"
    static let mic = "capture.mic"
    static let send = "capture.send"
    static let plus = "capture.plus"
    static let menu = "capture.menu"
    static let photoChip = "capture.photo.chip"
    static let photoDiscard = "capture.photo.discard"
    static let menuTake = "capture.menu.take"
    static let menuChoose = "capture.menu.choose"
    static let searchResults = "capture.search.results"
    static let searchHit = "capture.search.hit"
    static let searchEmpty = "capture.search.empty"
    static let cameraShutter = "capture.camera.shutter"
    static let cameraClose = "capture.camera.close"
    static let cameraFlip = "capture.camera.flip"
    static let cameraLibrary = "capture.camera.library"
}

/// Everything typed or photographed enters Vo-Cal here, and the voice capture opens from it:
/// the app's only bottom chrome. Three states of one row:
///   resting    [+] [What did you eat?              ] [mic]
///   menu       [ Camera / Photos, grown from the plus ]
///   composing  [ photo · words, one to eight lines · (+) … (mark) ]   answers rise above
/// The shell places it with `.safeAreaInset(edge: .bottom)` and lays Serein's catchers under
/// it: a tap anywhere else closes the menu or puts the keyboard away. The bar paints its own
/// fade and its own dead zone. A send hands the shell one `CaptureSubmission` and clears the
/// composer: the shell owns the submission from then on.
struct CaptureBar: View {
    @Bindable var composer: CaptureComposerModel
    let search: CaptureSearchModel
    /// Owned by the shell (Serein's home owns `attachmentMenuOpen`) so the catcher it lays
    /// under the bar can close the menu on a tap anywhere else.
    @Binding var menuOpen: Bool
    let onVoice: () -> Void
    let onSend: (CaptureSubmission) -> Void
    let onPickHit: (CaptureSearchHit) -> Void
    /// The shell presents the camera and the library and stages what comes back.
    let onCamera: () -> Void
    let onLibrary: () -> Void
    /// The first-run tour registers the three ways in here (HelpTourStep.Home mic/text/photo).
    let tour: HelpTourModel?

    @FocusState private var fieldFocused: Bool
    @Namespace private var morph
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        composer: CaptureComposerModel,
        search: CaptureSearchModel,
        menuOpen: Binding<Bool>,
        onVoice: @escaping () -> Void,
        onSend: @escaping (CaptureSubmission) -> Void,
        onPickHit: @escaping (CaptureSearchHit) -> Void,
        onCamera: @escaping () -> Void = {},
        onLibrary: @escaping () -> Void = {},
        tour: HelpTourModel? = nil
    ) {
        _composer = Bindable(wrappedValue: composer)
        self.search = search
        _menuOpen = menuOpen
        self.onVoice = onVoice
        self.onSend = onSend
        self.onPickHit = onPickHit
        self.onCamera = onCamera
        self.onLibrary = onLibrary
        self.tour = tour
    }

    /// Opening and closing the composer is ONE motion, so it is one spring, for every part of
    /// the bar. Serein ran the bar at 0.38 while its page ran at 0.35: two curves over the same
    /// instant read as the parts arriving separately (Lorenzo: "it should not feel clunky",
    /// 2026-09-20).
    static let composeMotion = Animation.spring(response: 0.42, dampingFraction: 0.9)
    /// The resting line: the field's height and both droplets' diameter. The plus is the mic's
    /// twin, as in Serein; at 44 it was the smallest target on the page and the one people
    /// missed (Lorenzo, 2026-09-24).
    static let slot: CGFloat = 56
    /// The plus and the send inside the composing card: 44 pt targets on smaller marks.
    static let controlSize: CGFloat = 44
    /// The staged photo inside the card's top corner (Serein's reference composer).
    static let previewSize: CGFloat = 120
    static let menuWidth: CGFloat = 252
    static let spacing: CGFloat = 10
    /// How far above the bar the page starts fading into the background.
    static let fadeRise: CGFloat = 28
    /// The strip above the row that swallows a near miss (Serein's dead zone, 2026-09-21: a
    /// finger aiming at the field that landed a few points high opened the card behind it).
    /// Here a tap meant for the plus opened the week's budget and the unfinished recording
    /// that sit right above the bar (Lorenzo, 2026-09-24). Never part of the bar's height.
    static let deadZone: CGFloat = 36
    /// The frost of the surfaces that rise above the row (the menu, the answers): denser than
    /// the field's, so the page's own words behind them stop being readable while the surface
    /// keeps its translucency (Serein: frosted, not window glass).
    static let frost = VoCalTheme.Colors.white.opacity(0.55)
    /// The droplets' bright near-white face (the plus and the mic), separating them from the
    /// field's frost (a gold wash blended into its own chrome, Lorenzo 2026-08-23).
    static let dropletFace = VoCalTheme.Colors.white.opacity(0.85)

    var body: some View {
        // Container spacing below the row's gaps: glass surfaces bridge within the spacing
        // distance, and at 22 Serein's plus visibly melted into the field's edge.
        GlassEffectContainer(spacing: 8) {
            VStack(alignment: .leading, spacing: Self.spacing) {
                if let notice = composer.notice {
                    noticeLine(notice)
                }
                if showsResults {
                    CaptureSearchResults(model: search) { hit in
                        pick(hit)
                    }
                    .glassEffectID("results", in: morph)
                    .transition(.scale(scale: 0.96, anchor: .bottom).combined(with: .opacity))
                }
                row
            }
        }
        .padding(.horizontal, VoCalTheme.Spacing.l)
        .padding(.vertical, VoCalTheme.Spacing.s)
        .frame(maxWidth: .infinity)
        .background(alignment: .bottom) {
            fade
        }
        .overlay(alignment: .top) {
            deadZoneStrip
        }
        .animation(motion, value: motionKey)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(CaptureA11y.bar)
        .onChange(of: fieldFocused) { _, focused in
            composer.isFieldFocused = focused
            if focused {
                menuOpen = false
            }
        }
        // The shell's catcher puts the keyboard away through the model (Serein resigned the
        // first responder from its home; here the model keeps the bar the one owner of focus).
        .onChange(of: composer.isFieldFocused) { _, focused in
            if !focused, fieldFocused {
                fieldFocused = false
            }
        }
        .onChange(of: searchQuery, initial: true) { _, query in
            search.query = query
        }
        .onChange(of: composer.stagedPhoto?.id) { _, staged in
            if staged != nil {
                VoCalHaptics.success()
            }
        }
        .onDisappear {
            composer.isFieldFocused = false
        }
        .task(id: composer.notice) {
            guard composer.notice != nil else { return }
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            composer.notice = nil
        }
    }

    // MARK: state

    private var fieldPrompt: String {
        composer.stagedPhoto == nil ? "What did you eat?" : "Add a note (optional)"
    }

    /// With a photo staged the words are its note, not a question for the history.
    private var searchQuery: String {
        composer.stagedPhoto == nil ? composer.text : ""
    }

    /// Answers show while there are words and an answer to show: hits, or the quiet line once
    /// a lookup has settled on nothing (never a flash of it while the first lookup runs).
    private var showsResults: Bool {
        !menuOpen && composer.stagedPhoto == nil && search.isActive
            && (!search.hits.isEmpty || search.foundNothing)
    }

    private var motion: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : Self.composeMotion
    }

    /// Everything that changes the bar's shape, animated by the one spring.
    private struct MotionKey: Equatable {
        let composing: Bool
        let photo: UUID?
        let results: [String]?
        let menuOpen: Bool
        let notice: String?
    }

    private var motionKey: MotionKey {
        MotionKey(
            composing: composer.isComposing,
            photo: composer.stagedPhoto?.id,
            results: showsResults ? search.hits.map(\.id) : nil,
            menuOpen: menuOpen,
            notice: composer.notice
        )
    }

    // MARK: the row

    /// Writing takes the whole row: the plus and the mic leave their droplets and the plus
    /// reappears inside the card's bottom corner beside the send, so the words get the full
    /// width and the keyboard's company. While the menu is open it owns the row: squeezing
    /// the field beside it truncated the field into a broken stub (Serein).
    private var row: some View {
        HStack(alignment: .bottom, spacing: Self.spacing) {
            if menuOpen {
                attachmentMenu
                Spacer(minLength: 0)
            } else {
                if !composer.isComposing {
                    plusButton
                        // It shrinks into the card's bottom-left corner, where it comes back.
                        // Fading in place left a plus sitting on top of the field that had
                        // just taken its width (Serein, Lorenzo's screenshot 2026-09-20).
                        .transition(.scale(scale: 0.4, anchor: .bottomLeading).combined(with: .opacity))
                }
                surface
                if !composer.isComposing {
                    micButton
                        .transition(.scale(scale: 0.4, anchor: .bottomTrailing).combined(with: .opacity))
                }
            }
        }
    }

    private var plusButton: some View {
        Button {
            fieldFocused = false
            menuOpen = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(VoCalTheme.Colors.ink)
                .frame(width: Self.slot, height: Self.slot)
                // The bright face, like the mic's: twin droplets. (The touch itself is the
                // glass modifier's contentShape; a glyph on glass with a hairline rim took no
                // touch for a build, LiquidGlass.swift, 2026-09-24.)
                .liquidGlass(in: Circle(), tint: Self.dropletFace, interactive: true)
                .glassEffectID("plus", in: morph)
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("Add a photo")
        .accessibilityIdentifier(CaptureA11y.plus)
        .helpTourTarget(HelpTourStep.Home.photo, in: tour)
    }

    /// Capsule at rest, a softer card while writing; one shape type so the glass morphs
    /// instead of swapping.
    private var surfaceShape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: composer.isComposing ? VoCalTheme.Radius.card : Self.slot / 2,
            style: .continuous
        )
    }

    /// The field, one view in two shapes so focus survives the change: the resting capsule,
    /// and while writing a card whose geometry is Serein's reference composer in points: the
    /// text line 17 pt below the top edge and 16 pt in from the left; a staged photo a 120 pt
    /// square 8 pt inside the top-left corner with the words beneath it; the controls row
    /// (plus at left, the mark at right) 44 pt tall under the last line. One line at rest,
    /// up to eight while writing, then it scrolls; the controls never move with the text.
    private var surface: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let photo = composer.stagedPhoto {
                stagedPreview(photo)
                    .padding(.top, 8)
                    .padding(.leading, 8)
                    .padding(.bottom, 8)
            }
            TextField(
                fieldPrompt,
                text: $composer.text,
                prompt: Text(fieldPrompt).foregroundStyle(VoCalTheme.Colors.muted),
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(VoCalTheme.Fonts.body)
            .foregroundStyle(VoCalTheme.Colors.ink)
            .tint(VoCalTheme.Colors.gold)
            .lineLimit(composer.isComposing ? 1 ... 8 : 1 ... 1)
            .focused($fieldFocused)
            // Return adds a line; only the mark sends. With `.submitLabel(.send)` plus
            // `.onSubmit`, a vertical TextField turns Return into submit and a typed meal could
            // never get a second line (Serein, September 2026).
            .submitLabel(.return)
            // A hardware keyboard sends Return as a key press, which a vertical TextField treats
            // as submit: the field resigned focus and every keystroke after it was lost (Serein,
            // simulator, 2026-09-13). Handled here as the newline the key means; the on-screen
            // keyboard never takes this path.
            .onKeyPress(.return) {
                composer.text.append("\n")
                return .handled
            }
            .accessibilityIdentifier(CaptureA11y.field)
            .helpTourTarget(HelpTourStep.Home.text, in: tour)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, 16)
            .padding(.top, composer.isComposing ? 17 : 0)

            if composer.isComposing {
                HStack(alignment: .center, spacing: 0) {
                    composerPlusButton
                    Spacer(minLength: 0)
                    sendButton
                }
                .padding(.top, 7)
                .padding(.leading, 1)
                .padding(.trailing, 2)
                .transition(.scale(scale: 0.86, anchor: .bottomLeading).combined(with: .opacity))
            }
        }
        .frame(minHeight: Self.slot)
        .frame(maxWidth: .infinity)
        .liquidGlass(in: surfaceShape)
        .glassEffectID("field", in: morph)
        // The whole surface is the field: any touch on or around it starts typing, no hunting
        // for the text line. The buttons inside still win their own taps.
        .contentShape(surfaceShape)
        .onTapGesture {
            fieldFocused = true
        }
    }

    /// The plus in its composing place, inside the card's bottom-left corner.
    private var composerPlusButton: some View {
        Button {
            fieldFocused = false
            menuOpen = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(VoCalTheme.Colors.ink)
                .frame(width: Self.controlSize, height: Self.controlSize)
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("Add a photo")
        .accessibilityIdentifier(CaptureA11y.plus)
    }

    /// The focal action: the retired tab bar's mic, look unchanged (gold glyph on a bright
    /// glass face with a gold rim). It opens the full-screen voice capture; nothing records
    /// in the bar.
    private var micButton: some View {
        Button {
            fieldFocused = false
            menuOpen = false
            onVoice()
        } label: {
            Image(systemName: "mic.fill")
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(VoCalTheme.Colors.gold)
                .frame(width: Self.slot, height: Self.slot)
                .actionSlotGlass()
                .glassEffectID("actionSlot", in: morph)
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("Log a meal by voice")
        .accessibilityIdentifier(CaptureA11y.mic)
        .helpTourTarget(HelpTourStep.Home.mic, in: tour)
    }

    /// The send, in the card's bottom-right corner: the Vo-Cal mark in the mic's gold on a
    /// bright disc with the gold rim. No glass carrier inside the glass card (a carrier there
    /// rendered as a halo ring in Serein). Dim until there is something to send, and with
    /// nothing to send a tap on it puts the composer away: the bar must never hold the
    /// keyboard with no way out (Lorenzo, 2026-09-24).
    private var sendButton: some View {
        Button {
            if composer.canSend {
                send()
            } else {
                fieldFocused = false
            }
        } label: {
            ZStack {
                Circle().fill(VoCalTheme.Colors.white.opacity(0.85))
                Circle().strokeBorder(VoCalTheme.Colors.goldBorderStrong, lineWidth: 1.5)
                VoCalTheme.Colors.gold
                    .frame(width: 30, height: 30)
                    .mask { logoMark }
            }
            .frame(width: 36, height: 36)
            .opacity(composer.canSend ? 1 : 0.45)
            .frame(width: Self.controlSize, height: Self.controlSize)
            .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(composer.canSend ? "Send" : "Done")
        .accessibilityIdentifier(CaptureA11y.send)
    }

    /// The mark alone, as a mask. The AppLogo asset is a black mark on an OPAQUE near-white
    /// squircle (alpha 255 across the squircle, measured 2026-09-24), so
    /// `.renderingMode(.template)` paints a solid gold squircle and the mark disappears.
    /// Flattened onto white, inverted and pushed apart, its luminance becomes the mask's
    /// alpha: the mark opaque, the squircle and the corners clear. A glyph-only template
    /// asset would retire this.
    private var logoMark: some View {
        ZStack {
            VoCalTheme.Colors.white
            Image(.appLogo)
                .resizable()
                .scaledToFit()
        }
        .compositingGroup()
        .colorInvert()
        .contrast(1.5)
        .luminanceToAlpha()
    }

    // MARK: the menu

    /// Camera and Photos, nothing else: large icons beside large labels, Apple's attachment
    /// menu proportions, on frosted glass grown from the plus's droplet (the shared glass id).
    private var attachmentMenu: some View {
        VStack(alignment: .leading, spacing: 4) {
            attachmentRow(symbol: "camera", title: "Camera", identifier: CaptureA11y.menuTake) {
                closeMenu()
                onCamera()
            }
            attachmentRow(symbol: "photo.on.rectangle", title: "Photos", identifier: CaptureA11y.menuChoose) {
                closeMenu()
                onLibrary()
            }
        }
        .padding(14)
        .frame(width: Self.menuWidth, alignment: .leading)
        .liquidGlass(
            in: RoundedRectangle(cornerRadius: 32, style: .continuous),
            tint: Self.frost
        )
        .glassEffectID("plus", in: morph)
        .transition(.scale(scale: 0.2, anchor: .bottomLeading).combined(with: .opacity))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(CaptureA11y.menu)
    }

    private func attachmentRow(
        symbol: String,
        title: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(VoCalTheme.Colors.ink)
                    .frame(width: 54, height: 54)
                    .background(VoCalTheme.Colors.card, in: Circle())
                Text(title)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(VoCalTheme.Colors.ink)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }

    private func closeMenu() {
        menuOpen = false
    }

    // MARK: inside the card

    /// The staged photo inside the card, flush in its top-left corner with the words beneath
    /// it: one container holds photo, text and controls, so the card's height is the sum of
    /// what is in it. A chip on its own glass above the bar read as a second object floating
    /// over the field (Serein's testers, 2026-09-02). The remove badge sits inside the photo's
    /// own top-right corner, the way Photos and Messages draw it, in the CTA ink because a
    /// translucent disc went faint on a bright photo.
    private func stagedPreview(_ photo: StagedPhoto) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return HStack(alignment: .top, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let thumbnail = photo.thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                    } else {
                        VoCalTheme.Colors.card
                            .overlay {
                                Image(systemName: "photo")
                                    .font(.system(size: 22, weight: .medium))
                                    .foregroundStyle(VoCalTheme.Colors.muted)
                            }
                    }
                }
                .frame(width: Self.previewSize, height: Self.previewSize)
                .clipShape(shape)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Photo to send")
                .accessibilityAddTraits(.isImage)

                Button {
                    composer.discardPhoto()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(VoCalTheme.Colors.onCta)
                        .frame(width: 22, height: 22)
                        .background(VoCalTheme.Colors.cta.opacity(0.78), in: Circle())
                        .padding(8)
                        .contentShape(Circle())
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel("Remove photo")
                .accessibilityIdentifier(CaptureA11y.photoDiscard)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(CaptureA11y.photoChip)
            Spacer(minLength: 0)
        }
        .transition(.scale(scale: 0.9, anchor: .topLeading).combined(with: .opacity))
    }

    // MARK: around the row

    /// A notice says its piece and leaves (six seconds); nothing it refers to is lost.
    private func noticeLine(_ message: String) -> some View {
        Text(message)
            .font(VoCalTheme.Fonts.secondaryLabel)
            .foregroundStyle(VoCalTheme.Colors.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .liquidGlass(in: Capsule())
            .glassEffectID("notice", in: morph)
            .frame(maxWidth: .infinity)
            .transition(.opacity)
    }

    /// The near-miss catcher above the row (Serein's dead zone): a tap here goes nowhere, and
    /// while the composer or the menu is open it puts them away, as the shell's catcher does.
    /// Invisible, and never part of the bar's height.
    private var deadZoneStrip: some View {
        Color.clear
            .frame(height: Self.deadZone)
            .contentShape(Rectangle())
            .onTapGesture {
                collapse()
            }
            // Its bottom on the bar's top: laid out above the bar, never transformed there.
            .alignmentGuide(.top) { dimensions in dimensions[.bottom] }
            .accessibilityHidden(true)
    }

    /// The page recedes into the background under the bar (Serein's journal fade, painted
    /// by the bar because the bar cannot mask the shell's page): clear above the bar, never
    /// fully opaque at the bottom, so what scrolls under stays faintly there.
    private var fade: some View {
        LinearGradient(
            stops: [
                .init(color: VoCalTheme.Colors.background.opacity(0), location: 0),
                .init(color: VoCalTheme.Colors.background.opacity(0.7), location: 0.45),
                .init(color: VoCalTheme.Colors.background.opacity(0.88), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .padding(.top, -Self.fadeRise)
        .ignoresSafeArea(.container, edges: .bottom)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: actions

    private func collapse() {
        fieldFocused = false
        menuOpen = false
    }

    private func send() {
        guard composer.canSend else { return }
        fieldFocused = false
        menuOpen = false
        Task {
            guard let submission = await composer.takeSubmission() else { return }
            onSend(submission)
        }
    }

    /// A picked answer ends the question: the words were the search, the hit is the meal.
    private func pick(_ hit: CaptureSearchHit) {
        fieldFocused = false
        composer.reset()
        onPickHit(hit)
    }
}

private extension View {
    /// The trailing droplet: a bright near-white face so the droplet separates from the
    /// field's frost (a gold wash blended into its own chrome, Lorenzo 2026-08-23), a gold
    /// rim, and the touch-down glass response.
    func actionSlotGlass() -> some View {
        liquidGlass(
            in: Circle(),
            tint: CaptureBar.dropletFace,
            interactive: true,
            rim: VoCalTheme.Colors.goldBorderStrong,
            rimWidth: 1.5
        )
    }
}

// MARK: - Previews and render fixtures

/// A drawn stand-in for a meal photo (a plate on a warm table): the chip and the upload
/// encoder need real image bytes, and a bundled JPEG would ship in the app.
@MainActor
enum CapturePreviewFixtures {
    static func mealPhotoJPEG(pixels: CGSize = CGSize(width: 1200, height: 900)) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: pixels, format: format).image { context in
            let canvas = context.cgContext
            let bounds = CGRect(origin: .zero, size: pixels)
            UIColor(VoCalTheme.Colors.carbs).setFill()
            canvas.fill(bounds)
            let plate = bounds.insetBy(dx: pixels.width * 0.2, dy: pixels.height * 0.1)
            UIColor(VoCalTheme.Colors.card).setFill()
            canvas.fillEllipse(in: plate)
            UIColor(VoCalTheme.Colors.optimal).setFill()
            canvas.fillEllipse(in: CGRect(
                x: plate.minX + plate.width * 0.18, y: plate.minY + plate.height * 0.25,
                width: plate.width * 0.36, height: plate.height * 0.4
            ))
            UIColor(VoCalTheme.Colors.protein).setFill()
            canvas.fillEllipse(in: CGRect(
                x: plate.minX + plate.width * 0.5, y: plate.minY + plate.height * 0.35,
                width: plate.width * 0.3, height: plate.height * 0.34
            ))
        }
        return image.jpegData(compressionQuality: 0.9) ?? Data()
    }
}

/// The bar placed the way the shell places it (`.safeAreaInset(edge: .bottom)` under a
/// scrolling page) over a static stand-in for Today, so the glass has something to frost and
/// the fade something to fade. The previews and the render tests draw this same scene.
struct CaptureBarPreviewScene: View {
    let composer: CaptureComposerModel
    let search: CaptureSearchModel
    @State private var menuOpen: Bool

    init(composer: CaptureComposerModel, search: CaptureSearchModel, menuOpen: Bool = false) {
        self.composer = composer
        self.search = search
        _menuOpen = State(initialValue: menuOpen)
    }

    private struct Meal {
        let slot: String
        let name: String
        let kcal: Int
    }

    private static let meals = [
        Meal(slot: "Breakfast", name: "Overnight oats", kcal: 348),
        Meal(slot: "Snack", name: "Greek yogurt, berries & granola", kcal: 386),
        Meal(slot: "Lunch", name: "Chicken, rice & broccoli", kcal: 541),
        Meal(slot: "Snack", name: "Protein shake", kcal: 162),
        Meal(slot: "Dinner", name: "My chili recipe", kcal: 410),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VoCalTheme.Spacing.m) {
                Text("Today")
                    .font(VoCalTheme.Fonts.screenTitle)
                    .foregroundStyle(VoCalTheme.Colors.ink)
                ForEach(Self.meals, id: \.name) { meal in
                    mealCard(meal)
                }
            }
            .padding(VoCalTheme.Spacing.l)
        }
        .scrollIndicators(.hidden)
        .background(VoCalTheme.Colors.background)
        // An overlay, not a safe-area inset, in the preview scene: inside the render
        // harness's fixed frame an inset bar landed half below the canvas (2026-09-25); the
        // shell itself insets the bar, and the bar's own fade covers the overlap here.
        .overlay(alignment: .bottom) {
            CaptureBar(
                composer: composer, search: search, menuOpen: $menuOpen,
                onVoice: {}, onSend: { _ in }, onPickHit: { _ in }
            )
        }
    }

    private func mealCard(_ meal: Meal) -> some View {
        VStack(alignment: .leading, spacing: VoCalTheme.Spacing.s) {
            Text(meal.slot)
                .sectionHeader()
            HStack(alignment: .firstTextBaseline, spacing: VoCalTheme.Spacing.xs) {
                Text(meal.name)
                    .font(VoCalTheme.Fonts.primaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.ink)
                    .lineLimit(1)
                Spacer(minLength: VoCalTheme.Spacing.s)
                Text("\(meal.kcal)")
                    .font(VoCalTheme.Fonts.numeral(28))
                    .foregroundStyle(VoCalTheme.Colors.ink)
                Text("cal")
                    .font(VoCalTheme.Fonts.secondaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
            }
        }
        .padding(VoCalTheme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            VoCalTheme.Colors.card,
            in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.card, style: .continuous)
        )
    }
}

#Preview("Idle") {
    CaptureBarPreviewScene(
        composer: CaptureComposerModel(),
        search: CaptureSearchModel(provider: MockCaptureSearchProvider())
    )
}

#Preview("Menu") {
    CaptureBarPreviewScene(
        composer: CaptureComposerModel(),
        search: CaptureSearchModel(provider: MockCaptureSearchProvider()),
        menuOpen: true
    )
}

#Preview("Typing, with answers") {
    CaptureBarPreviewScene(
        composer: CaptureComposerModel(text: "chi"),
        search: CaptureSearchModel(provider: MockCaptureSearchProvider())
    )
}

#Preview("Typing, nothing found") {
    CaptureBarPreviewScene(
        composer: CaptureComposerModel(text: "zucchini fritters"),
        search: CaptureSearchModel(provider: MockCaptureSearchProvider())
    )
}

#Preview("Staged photo") {
    CaptureBarPreviewScene(
        composer: CaptureComposerModel(stagedPhoto: StagedPhoto(data: CapturePreviewFixtures.mealPhotoJPEG())),
        search: CaptureSearchModel(provider: MockCaptureSearchProvider())
    )
}

