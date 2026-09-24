import SwiftUI
import UIKit

// Port provenance: Serein apps/ios/SereinApp/Sources/CaptureComposerModel.swift. Kept: the
// draft and the staged attachment held side by side, one send for both, and
// StagedAttachment's ImageIO thumbnail (480 px, never a full decode to draw a chip). Cut:
// the outbox commit, galleries of several photos, file staging and the error expiry. The
// Vo-Cal bar commits nothing itself: it hands one CaptureSubmission to the shell, which owns
// it from that moment.

/// What one send from the capture bar carries: the meal typed out, or one photo with the
/// words typed beside it as its note.
enum CaptureSubmission: Sendable, Equatable {
    case text(String)
    case photo(Data, note: String?)
}

/// The photo waiting in the composer. Nothing durable has happened yet: it lives in memory
/// until the person sends or discards it. The full bytes stay here and the upload copy is
/// made at send (`CapturePhotoEncoding`), so a discarded photo never costs an encode.
struct StagedPhoto: Identifiable, Sendable {
    let id = UUID()
    let data: Data
    /// A 480 px downsample for the chip; nil when the bytes do not decode as an image.
    let thumbnail: UIImage?

    init(data: Data) {
        self.data = data
        thumbnail = CapturePhotoEncoding.thumbnail(from: data)
    }

    /// The same, built off the main actor. A 48 MP library photo downsampled on the main
    /// thread drops frames in the very spring that brings its chip in.
    @concurrent
    static func prepare(_ data: Data) async -> StagedPhoto {
        StagedPhoto(data: data)
    }
}

/// The bar's state that outlives a keystroke: the words, the staged photo, and whether the
/// field holds the keyboard. The shell may read `isComposing` to give typing a calm page.
@MainActor
@Observable
final class CaptureComposerModel {
    /// The words in the field: the meal typed out, or the note riding a staged photo.
    var text: String
    var stagedPhoto: StagedPhoto?
    /// Mirrored from the bar's focus state; the bar is its only writer.
    var isFieldFocused = false

    init(text: String = "", stagedPhoto: StagedPhoto? = nil) {
        self.text = text
        self.stagedPhoto = stagedPhoto
    }

    var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Writing is a state of the whole bar: the keyboard is up, there are words, or a photo
    /// waits. While it holds, the trailing slot is the send logo instead of the mic.
    var isComposing: Bool {
        isFieldFocused || !trimmedText.isEmpty || stagedPhoto != nil
    }

    /// Words, a photo, or both.
    var canSend: Bool {
        stagedPhoto != nil || !trimmedText.isEmpty
    }

    func discardPhoto() {
        stagedPhoto = nil
    }

    func reset() {
        text = ""
        stagedPhoto = nil
    }

    /// Takes what the composer holds as one submission and clears the composer at once,
    /// before the photo's upload copy is encoded: a second tap on send during the encode
    /// finds nothing to send, and no keystroke lands in a draft that is already leaving.
    /// Nil when there is nothing to send.
    func takeSubmission() async -> CaptureSubmission? {
        let words = trimmedText
        guard let photo = stagedPhoto else {
            guard !words.isEmpty else { return nil }
            reset()
            return .text(words)
        }
        reset()
        let upload = await CapturePhotoEncoding.uploadJPEG(from: photo.data)
        return .photo(upload, note: words.isEmpty ? nil : words)
    }
}
