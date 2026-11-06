import Foundation
import Observation
import VoCalCore

// The one chat (2026-11-06, Lorenzo: "in just a single chat they should be able to see what
// they need"). Decision 71 put the answer inside the capture sheet and refused a chat screen;
// this amends it (decision 75): the thread is a screen, kept for the app's session and stored
// nowhere, and every turn is still one of the things the sheet already drew. The engine of
// each turn is the voice-log view model, unchanged: it owns the capture rungs, the parse, the
// answer and the confirm, and its state licenses every claim. This model only holds the turns
// that are over and the model of the turn under way.

/// A turn the thread keeps once it is over: the person's words, a receipt, an answer, or an
/// honest failure. The turn under way is `ChatThreadModel.current`, drawn live from its state.
struct ChatTurn: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// What the person sent: typed, spoken (the transcript), or "Your photo".
        case person(String)
        /// A server row landed (the only proof of the word): the meal's name and calories, and
        /// water when any was in it.
        case receipt(name: String, kcal: Double, printsNumbers: Bool, waterOz: Double, waterOnly: Bool)
        /// The bar's answer (decision 71), folded once the next turn starts: the line and the
        /// thing, Undo gone with the model that could run it.
        case answer(asked: String, reply: AssistReply, undone: Bool)
        /// A derived step that did not finish; the transcript stays so the person can rephrase.
        case failure(message: String, transcript: String?)
    }

    let id: String
    let kind: Kind
    let at: Date

    init(_ kind: Kind, at: Date = .now) {
        id = UUID().uuidString
        self.kind = kind
        self.at = at
    }
}

@MainActor
@Observable
final class ChatThreadModel {
    private(set) var turns: [ChatTurn] = []
    /// The turn under way (a parse running, a result waiting to be logged, an answer with its
    /// Undo), drawn live. Nil between turns.
    private(set) var current: VoiceLogViewModel?
    /// The voice capture presented over the chat for the turn under way; the sheet reads the
    /// same model, so the capture rungs draw exactly as they always have.
    var presentsVoice = false
    /// A spoken turn has no words until the transcript arrives: the person's bubble is written
    /// from the first outcome state (the result, the answer, the failure), once.
    private var awaitingSpokenWords = false
    /// The assist thread carried between turns, so a follow-up resolves ("make it protein"
    /// after "show my calories"), six turns at most, as the sheet kept it.
    private var assistThread: [AssistTurn] = []
    /// The day the chat's logs land on and the slot they take: the home's selected day and
    /// whatever the clock suggests, or the section the person tapped Add in.
    var targetDate: Date = .now
    var mealType: MealType = .unspecified

    /// The shell's post-log beat, so the home's diary reloads.
    var onLogged: (() -> Void)?

    /// Starting a new turn ends the last: an answer still showing Undo folds into the thread
    /// as it stands (undone or not), a result not logged is dropped (the person moved on), and
    /// a failure is kept as a turn.
    private func foldCurrent() {
        guard let current else { return }
        switch current.state {
        case let .answered(context):
            turns.append(ChatTurn(.answer(asked: context.asked, reply: context.reply, undone: context.undone)))
            assistThread = current.currentThread
        case let .failed(message, _, _, transcript):
            turns.append(ChatTurn(.failure(message: message, transcript: transcript)))
        default:
            break
        }
        current.cancel()
        self.current = nil
    }

    private func makeModel() -> VoiceLogViewModel {
        VoiceLogViewModel(mealType: mealType, targetDate: targetDate, thread: assistThread)
    }

    /// A typed turn: the words are the transcript, the parse is the same parse (CAPTURE_LIFECYCLE
    /// §9), and a sentence with no food in it is answered.
    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        foldCurrent()
        turns.append(ChatTurn(.person(trimmed)))
        let model = makeModel()
        current = model
        model.startTyped(trimmed)
    }

    /// A photographed turn: the note, when typed, is the person's words; without one the turn
    /// says it was a photo.
    func sendPhoto(_ data: Data, note: String?) {
        foldCurrent()
        let shown = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        turns.append(ChatTurn(.person((shown?.isEmpty == false) ? shown! : "Your photo")))
        let model = makeModel()
        current = model
        model.startPhoto(data, note: shown)
    }

    /// A spoken turn: the capture sheet opens over the chat on a fresh model; `absorbVoice`
    /// reads where it got to once the sheet closes.
    func speak() {
        foldCurrent()
        let model = makeModel()
        current = model
        awaitingSpokenWords = true
        presentsVoice = true
    }

    /// Every change of the live model's state, from the view: a spoken turn's words are
    /// written on the first outcome (the transcript the result or the failure carries, the
    /// sentence the answer quotes), and a landed row folds into a receipt. The view calls
    /// this whether the voice sheet is up or not, so a meal logged from the sheet is a receipt
    /// by the time the sheet is gone.
    func observe(_ state: VoiceLogState?) {
        guard let state else { return }
        if awaitingSpokenWords {
            switch state {
            case let .result(context):
                turns.append(ChatTurn(.person(context.transcript)))
                awaitingSpokenWords = false
            case let .answered(context):
                turns.append(ChatTurn(.person(context.asked)))
                awaitingSpokenWords = false
            case let .failed(_, _, _, transcript):
                if let transcript, !transcript.isEmpty { turns.append(ChatTurn(.person(transcript))) }
                awaitingSpokenWords = false
            default:
                break
            }
        }
        if case .logged = state { noteLogged() }
    }

    /// The capture sheet closed: a result stays as the live turn (the person logs it here), an
    /// answer and a failure stay live too (Undo, Try again), and a capture closed before
    /// anything derived leaves no turn (the saved recording is on the home's Unfinished list,
    /// as before).
    func absorbVoice() {
        awaitingSpokenWords = false
        guard let current else { return }
        switch current.state {
        case .result, .answered, .failed, .logged:
            break
        default:
            current.cancel()
            self.current = nil
        }
    }

    /// Log the result on screen; the receipt lands when the server's row does.
    func log(saveAsUsual: Bool) {
        current?.confirm(saveAsUsual: saveAsUsual) { [weak self] in
            self?.noteLogged()
        }
    }

    /// The model reached "logged" (observed by the view): fold the receipt and clear the turn.
    func noteLogged() {
        guard let current, case let .logged(confirmation) = current.state else { return }
        turns.append(ChatTurn(.receipt(
            name: confirmation.name ?? "Meal",
            kcal: confirmation.totals.kcal,
            printsNumbers: current.lastLogPrintsNumbers,
            waterOz: current.lastLoggedWaterOz,
            waterOnly: current.lastLogWasWaterOnly
        )))
        self.current = nil
        onLogged?()
    }

    /// The answer's Undo, through the model that landed the change.
    func undo() {
        current?.undoAnswer()
    }

    /// A failed derived step, tried again from the saved audio (a spoken turn) or re-sent (a
    /// typed one).
    func retry() {
        guard let current, case let .failed(_, retryable, _, transcript) = current.state else { return }
        if current.hasCapture {
            if retryable { current.retry() }
        } else if let transcript {
            current.cancel()
            self.current = nil
            send(transcript)
        }
    }

    /// A scanned food, logged as a serving of one of the person's foods: the label is saved
    /// first (the server prices it by name from then on), then one confirm carrying the
    /// serving, the same path a usual takes. The turn reads as the scan.
    func logScanned(_ food: BarcodeFood, servings: Double, personalFoods: any PersonalFoodsService) async {
        foldCurrent()
        turns.append(ChatTurn(.person("Scanned \(food.displayName)")))
        let model = makeModel()
        current = model
        do {
            let saved = try await personalFoods.saveLabel(SaveLabelFoodRequest.from(food))
            model.logServing(of: saved, servings: servings) { [weak self] in
                self?.noteLogged()
            }
        } catch {
            turns.append(ChatTurn(.failure(message: "Couldn't save that food. Check your connection and try again.", transcript: nil)))
            current = nil
        }
    }

    /// Renders and previews: a thread as it would stand, turns already over.
    func seed(_ turns: [ChatTurn]) {
        self.turns = turns
    }

    /// Forget everything: the chat is for the session, never longer (decision 71's rule on
    /// memory stands across launches).
    func clear() {
        foldCurrent()
        turns = []
        assistThread = []
    }
}
