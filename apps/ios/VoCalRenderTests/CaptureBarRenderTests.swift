import SwiftUI
import UIKit
import XCTest
@testable import VoCal

/// The capture bar's three resting states, drawn through the fast UI loop into /tmp/ui
/// (capture-bar-idle, capture-bar-typing, capture-bar-staged) for reading. No golden is
/// asserted yet: the goldens are recorded once, on purpose, when the bar is wired into the
/// shell (docs/UI_VERIFICATION.md). The scene is the one the previews draw, the bar under a
/// scrolling stand-in for Today, as the shell places it.
@MainActor
final class CaptureBarRenderTests: XCTestCase {
    private static let height: CGFloat = 560

    func testIdle() throws {
        let composer = CaptureComposerModel()
        let search = CaptureSearchModel(provider: MockCaptureSearchProvider())
        XCTAssertFalse(composer.isComposing)
        _ = try RenderHarness.render(
            CaptureBarPreviewScene(composer: composer, search: search),
            name: "capture-bar-idle",
            height: Self.height
        )
    }

    func testTypingWithSearchHits() async throws {
        let composer = CaptureComposerModel(text: "chi")
        let search = CaptureSearchModel(provider: MockCaptureSearchProvider())
        search.query = composer.text
        await search.settle()
        XCTAssertEqual(search.hits.map(\.name), ["Chicken, rice & broccoli", "My chili recipe"])
        XCTAssertTrue(composer.isComposing)
        _ = try RenderHarness.render(
            CaptureBarPreviewScene(composer: composer, search: search),
            name: "capture-bar-typing",
            height: Self.height
        )
    }

    func testStagedPhoto() throws {
        let photo = StagedPhoto(data: CapturePreviewFixtures.mealPhotoJPEG())
        XCTAssertNotNil(photo.thumbnail)
        let composer = CaptureComposerModel(stagedPhoto: photo)
        let search = CaptureSearchModel(provider: MockCaptureSearchProvider())
        XCTAssertTrue(composer.canSend)
        _ = try RenderHarness.render(
            CaptureBarPreviewScene(composer: composer, search: search),
            name: "capture-bar-staged",
            height: Self.height
        )
    }

    /// Not a render: what one send hands the shell. Words go trimmed and clear the field; a
    /// photo goes as its upload copy, bounded on the long edge, with no note when none was typed.
    func testSubmissions() async throws {
        let typed = CaptureComposerModel(text: "  two eggs and toast \n")
        let words = await typed.takeSubmission()
        XCTAssertEqual(words, .text("two eggs and toast"))
        XCTAssertEqual(typed.text, "")
        let again = await typed.takeSubmission()
        XCTAssertNil(again)

        let large = CapturePreviewFixtures.mealPhotoJPEG(pixels: CGSize(width: 4000, height: 3000))
        let staged = CaptureComposerModel(stagedPhoto: StagedPhoto(data: large))
        let sent = await staged.takeSubmission()
        guard case let .photo(upload, note)? = sent else {
            return XCTFail("a staged photo sends as a photo, got \(String(describing: sent))")
        }
        XCTAssertNil(note)
        XCTAssertNil(staged.stagedPhoto)
        let decoded = try XCTUnwrap(UIImage(data: upload))
        let longEdge = max(decoded.size.width, decoded.size.height) * decoded.scale
        XCTAssertLessThanOrEqual(longEdge, CapturePhotoEncoding.uploadMaxDimension)
        XCTAssertLessThan(upload.count, large.count)
    }
}
