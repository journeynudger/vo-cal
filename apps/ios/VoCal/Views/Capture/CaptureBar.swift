import PhotosUI
import SwiftUI
import UIKit

// Port provenance: Serein apps/ios/SereinApp/Sources/CaptureBar.swift, with the glass circle
// from GlassChrome.swift. Kept: one bar whose trailing slot morphs (the shared glassEffectID
// "actionSlot"), a field that grows with the words and keeps Return as a newline (the
// hardware-keyboard catch included), the frosted attachment menu, the staged photo with its
// remove badge in the corner, and the one compose spring. Changed: Vo-Cal's palette and
// glass (`liquidGlass`), the mic opens the full-screen voice capture instead of recording
// in the bar, the send is the Vo-Cal mark, one photo instead of a gallery, and answers from
// the person's history rise above the bar while they type. Cut: the recording pill and stop
// square, the note typed during a take, the thread chip, the file importer, the error line
// and the saved flash; none of them is a Vo-Cal surface.

/// Accessibility identifiers for the capture surfaces (UI tests reference these, never
/// display strings). Here until the shell promotes them into `A11y`.
enum CaptureA11y {
    static let bar = "capture.bar"
    static let field = "capture.field"
    static let mic = "capture.mic"
    static let send = "capture.send"
    static let plus = "capture.plus"
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
/// the app's only bottom chrome. Three resting states, one row, one morphing trailing slot:
///   idle     [+] [What did you eat?            ] [mic]
///   typing   [+] [words, one to five lines     ] [mark]   answers rise above the row
///   staged   the photo above, [+] [Add a note (optional)] [mark]
/// The shell places it with `.safeAreaInset(edge: .bottom)`; the bar paints its own fade.
/// A send hands the shell one `CaptureSubmission` and clears the composer: the shell owns the
/// submission from then on (it can put the words back in `composer.text` if it must).
struct CaptureBar: View {
    @Bindable var composer: CaptureComposerModel
    let search: CaptureSearchModel
    let onVoice: () -> Void
    let onSend: (CaptureSubmission) -> Void
    let onPickHit: (CaptureSearchHit) -> Void
    /// The first-run tour registers the three ways in here (HelpTourStep.Home mic/text/photo).
    let tour: HelpTourModel?

    @FocusState private var fieldFocused: Bool
    @State private var menuOpen = false
    @State private var cameraPresented = false
    @State private var libraryPresented = false
    @State private var librarySelection: PhotosPickerItem?
    @State private var notice: String?
    @Namespace private var morph
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        composer: CaptureComposerModel,
        search: CaptureSearchModel,
        onVoice: @escaping () -> Void,
        onSend: @escaping (CaptureSubmission) -> Void,
        onPickHit: @escaping (CaptureSearchHit) -> Void,
        tour: HelpTourModel? = nil
    ) {
        _composer = Bindable(wrappedValue: composer)
        self.search = search
        self.onVoice = onVoice
        self.onSend = onSend
        self.onPickHit = onPickHit
        self.tour = tour
    }

    /// Opening and closing the composer is ONE motion, so it is one spring, for every part of
    /// the bar. Serein ran the bar at 0.38 while its page ran at 0.35: two curves over the same
    /// instant read as the parts arriving separately (Lorenzo: "it should not feel clunky",
    /// 2026-09-20).
    static let composeMotion = Animation.spring(response: 0.42, dampingFraction: 0.9)
    /// The resting line: the field's height and the trailing droplet's diameter.
    static let slot: CGFloat = 56
    static let plusSize: CGFloat = 44
    static let chipSize: CGFloat = 64
    static let logoSize: CGFloat = 52
    static let spacing: CGFloat = 10
    /// How far above the bar the page starts fading into the background.
    static let fadeRise: CGFloat = 28
    /// The frost of the surfaces that rise above the row (the photo menu, the answers):
    /// denser than the field's, so the page's own words behind them stop being readable while
    /// the surface keeps its translucency (Serein: frosted, not window glass).
    static let frost = VoCalTheme.Colors.white.opacity(0.55)

    var body: some View {
        // Container spacing below the row's gaps: glass surfaces bridge within the spacing
        // distance, and at 22 Serein's plus visibly melted into the field's edge.
        GlassEffectContainer(spacing: 8) {
            VStack(alignment: .leading, spacing: Self.spacing) {
                if let notice {
                    noticeLine(notice)
                }
                if showsResults {
                    CaptureSearchResults(model: search) { hit in
                        pick(hit)
                    }
                    .glassEffectID("results", in: morph)
                    .transition(.scale(scale: 0.96, anchor: .bottom).combined(with: .opacity))
                }
                if let photo = composer.stagedPhoto {
                    stagedChip(photo)
                }
                if menuOpen {
                    photoMenu
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
        .animation(motion, value: motionKey)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(CaptureA11y.bar)
        .onChange(of: fieldFocused) { _, focused in
            composer.isFieldFocused = focused
            if focused {
                menuOpen = false
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
        .onChange(of: librarySelection) { _, item in
            guard let item else { return }
            librarySelection = nil
            Task { await load(item) }
        }
        .onDisappear {
            composer.isFieldFocused = false
        }
        .photosPicker(isPresented: $libraryPresented, selection: $librarySelection, matching: .images)
        .fullScreenCover(isPresented: $cameraPresented) {
            CaptureCameraView { data in
                Task { await stagePhoto(data) }
            }
        }
        .task(id: notice) {
            guard notice != nil else { return }
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            notice = nil
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
            notice: notice
        )
    }

    // MARK: the row

    private var row: some View {
        HStack(alignment: .bottom, spacing: Self.spacing) {
            plusButton
            field
            if composer.isComposing {
                sendButton
            } else {
                micButton
            }
        }
    }

    private var plusButton: some View {
        Button {
            fieldFocused = false
            menuOpen.toggle()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(VoCalTheme.Colors.ink)
                .rotationEffect(.degrees(menuOpen ? 45 : 0))
                .frame(width: Self.plusSize, height: Self.plusSize)
                .liquidGlass(in: Circle(), interactive: true)
                .glassEffectID("plus", in: morph)
        }
        .buttonStyle(PressableButtonStyle())
        // Centered on the resting line; with a taller field it stays by the last line.
        .frame(height: Self.slot)
        .accessibilityLabel(menuOpen ? "Close photo options" : "Add a photo")
        .accessibilityIdentifier(CaptureA11y.plus)
        .helpTourTarget(HelpTourStep.Home.photo, in: tour)
    }

    /// One view in both shapes so focus survives the change: a capsule at rest, a card while
    /// writing, one RoundedRectangle so the glass morphs instead of swapping. One line at
    /// rest, up to five while writing, then it scrolls.
    private var field: some View {
        let shape = RoundedRectangle(
            cornerRadius: composer.isComposing ? VoCalTheme.Radius.card : Self.slot / 2,
            style: .continuous
        )
        return TextField(
            fieldPrompt,
            text: $composer.text,
            prompt: Text(fieldPrompt).foregroundStyle(VoCalTheme.Colors.muted),
            axis: .vertical
        )
        .textFieldStyle(.plain)
        .font(VoCalTheme.Fonts.body)
        .foregroundStyle(VoCalTheme.Colors.ink)
        .tint(VoCalTheme.Colors.gold)
        .lineLimit(1 ... 5)
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
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: Self.slot, alignment: .leading)
        .liquidGlass(in: shape)
        .glassEffectID("field", in: morph)
        // The whole surface is the field: a touch anywhere on it starts typing, no hunting
        // for the text line.
        .contentShape(shape)
        .onTapGesture {
            fieldFocused = true
        }
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

    /// The send, emerging from the mic's droplet (shared glass id, so the droplet stays and
    /// its glyph changes): the Vo-Cal mark in the mic's gold. Dim until there is something
    /// to send.
    private var sendButton: some View {
        Button(action: send) {
            VoCalTheme.Colors.gold
                .frame(width: Self.logoSize, height: Self.logoSize)
                .mask { logoMark }
                .opacity(composer.canSend ? 1 : 0.45)
                .frame(width: Self.slot, height: Self.slot)
                .actionSlotGlass()
                .glassEffectID("actionSlot", in: morph)
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(!composer.canSend)
        .accessibilityLabel("Send")
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

    // MARK: above the row

    /// Camera or library, nothing else, on frosted glass grown from the plus's droplet.
    private var photoMenu: some View {
        VStack(alignment: .leading, spacing: 2) {
            menuRow(symbol: "camera", title: "Take a photo", identifier: CaptureA11y.menuTake) {
                menuOpen = false
                cameraPresented = true
            }
            menuRow(symbol: "photo.on.rectangle", title: "Choose a photo", identifier: CaptureA11y.menuChoose) {
                menuOpen = false
                libraryPresented = true
            }
        }
        .padding(VoCalTheme.Spacing.s)
        .frame(width: 236, alignment: .leading)
        .liquidGlass(
            in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.card, style: .continuous),
            tint: Self.frost
        )
        .glassEffectID("menu", in: morph)
        .transition(.scale(scale: 0.3, anchor: .bottomLeading).combined(with: .opacity))
    }

    private func menuRow(
        symbol: String,
        title: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(VoCalTheme.Colors.ink)
                    .frame(width: 40, height: 40)
                    .background(VoCalTheme.Colors.card, in: Circle())
                Text(title)
                    .font(VoCalTheme.Fonts.primaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, VoCalTheme.Spacing.s)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityIdentifier(identifier)
    }

    /// The staged photo, above the field it belongs to, with the remove badge inside its own
    /// top-right corner the way Photos and Messages draw it. Serein's badge was a fixed mid
    /// gray because a translucent disc went faint on a bright photo; here it is the CTA ink.
    private func stagedChip(_ photo: StagedPhoto) -> some View {
        let shape = RoundedRectangle(cornerRadius: VoCalTheme.Radius.chip, style: .continuous)
        return ZStack(alignment: .topTrailing) {
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
            .frame(width: Self.chipSize, height: Self.chipSize)
            .clipShape(shape)
            .overlay(shape.strokeBorder(VoCalTheme.Glass.rim, lineWidth: 1.5))
            .shadow(color: VoCalTheme.Glass.lift, radius: 10, y: 4)
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
                    .padding(5)
                    // A 44 pt target on a 22 pt disc.
                    .frame(width: 44, height: 44, alignment: .topTrailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel("Remove photo")
            .accessibilityIdentifier(CaptureA11y.photoDiscard)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(CaptureA11y.photoChip)
        .padding(.leading, Self.plusSize + Self.spacing)
        .transition(.scale(scale: 0.9, anchor: .bottomLeading).combined(with: .opacity))
    }

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

    private func stagePhoto(_ data: Data) async {
        composer.stagedPhoto = await StagedPhoto.prepare(data)
    }

    private func load(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            notice = "That photo did not load. Try another one."
            return
        }
        await stagePhoto(data)
    }
}

private extension View {
    /// The trailing droplet (mic and send share it): a bright near-white face so the droplet
    /// separates from the field's frost (a gold wash blended into its own chrome, Lorenzo
    /// 2026-08-23), a gold rim, and the touch-down glass response.
    func actionSlotGlass() -> some View {
        liquidGlass(
            in: Circle(),
            tint: VoCalTheme.Colors.white.opacity(0.85),
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
            CaptureBar(composer: composer, search: search, onVoice: {}, onSend: { _ in }, onPickHit: { _ in })
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
