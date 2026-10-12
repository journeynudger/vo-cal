import SwiftUI

/// The bar's answer (decision 71, spec 5.2): what the person asked, quoted; the one line; the
/// one thing (the changed row as Settings draws it, the Today card as Today draws it, the
/// pointer row); Undo when a change landed; the field and the mic so the person may go on,
/// nothing asking them to. A state of the voice-log sheet, never a screen of its own.
///
/// Gestures are the phone's (spec 5.6): a swipe either way closes with the one `select` tick
/// (the nudge card's quiet dismiss); a long-press on the row offers Undo, the same as the
/// button; the mic is the recording's own door. Touches: `success` only when a change landed,
/// fired by the view model from the server's echo, never here.
struct AssistReplyView: View {
    let context: AnswerContext
    var onUndo: () -> Void
    var onSayMore: (String) -> Void
    var onSpeak: () -> Void
    var onOpen: (AssistPointer.Surface) -> Void
    var onClose: () -> Void

    @State private var more = ""
    @State private var dragX: CGFloat = 0
    @FocusState private var fieldFocused: Bool

    /// A swipe this far, either way, closes; shorter snaps back (the nudge card's distance).
    static let closeDistance: CGFloat = 80
    /// Line for line with assist/lines.py UNDONE.
    static let undoneLine = "Undone."

    var body: some View {
        VStack(alignment: .leading, spacing: VoCalTheme.Spacing.l) {
            asked
            Text(context.undone ? Self.undoneLine : context.reply.line)
                .font(VoCalTheme.Fonts.primaryLabel)
                .foregroundStyle(VoCalTheme.Colors.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(A11y.VoiceLog.answerLine)
            thing
            Spacer(minLength: 0)
            if context.canUndo {
                VoCalButton(title: "Undo", kind: .secondary, isLoading: context.isUndoing, action: onUndo)
                    .accessibilityIdentifier(A11y.VoiceLog.answerUndo)
            }
            door
            VoCalButton(title: "Close", kind: .tertiary, action: onClose)
                .frame(maxWidth: .infinity)
        }
        .padding(VoCalTheme.Spacing.xl)
        // Under the floating X, which the sheet draws for every surface but the result.
        .padding(.top, VoCalTheme.Spacing.xxl)
        .offset(x: dragX)
        .gesture(swipe)
    }

    /// "You asked" and the sentence, as the failure surface echoes "You said".
    private var asked: some View {
        VStack(alignment: .leading, spacing: VoCalTheme.Spacing.xs) {
            Text("You asked")
                .font(VoCalTheme.Fonts.formLabel)
                .foregroundStyle(VoCalTheme.Colors.muted)
            Text("\u{201C}\(context.asked)\u{201D}")
                .font(VoCalTheme.Fonts.secondaryLabel)
                .foregroundStyle(VoCalTheme.Colors.ink)
                .lineLimit(3)
        }
    }

    /// Exactly one of the row, the card, the pointer; nothing when the line is the answer or
    /// Undo has run.
    @ViewBuilder
    private var thing: some View {
        if context.undone {
            EmptyView()
        } else if let change = context.reply.change {
            SettingsCard {
                SettingsRow(
                    icon: change.icon, label: change.title, value: change.value,
                    showsChevron: false, accessibilityID: A11y.VoiceLog.answerChange
                )
            }
            .contextMenu {
                if context.canUndo {
                    Button(action: onUndo) {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                    }
                }
            }
        } else if let panel = context.reply.panel {
            PanelView(panel: panel, size: .hero)
                .accessibilityIdentifier(A11y.VoiceLog.answerPanel)
        } else if let pointer = context.reply.pointer {
            SettingsCard {
                SettingsRow(
                    icon: "arrow.up.right", label: pointer.title, showsChevron: true,
                    accessibilityID: A11y.VoiceLog.answerPointer
                ) {
                    if let surface = pointer.knownSurface { onOpen(surface) }
                }
            }
        }
    }

    /// The field and the mic: the same door the bar is, kept open. Typing sends the next
    /// sentence through the parse-first path with the thread; the mic starts the recording.
    private var door: some View {
        HStack(spacing: VoCalTheme.Spacing.m) {
            HStack(spacing: VoCalTheme.Spacing.s) {
                TextField("Say more", text: $more)
                    .textFieldStyle(.plain)
                    .font(VoCalTheme.Fonts.body)
                    .foregroundStyle(VoCalTheme.Colors.ink)
                    .submitLabel(.send)
                    .focused($fieldFocused)
                    .onSubmit(send)
                    .accessibilityIdentifier(A11y.VoiceLog.answerField)
                if !more.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(VoCalTheme.Colors.ink)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Send")
                }
            }
            .padding(.horizontal, VoCalTheme.Spacing.l)
            .frame(height: 52)
            .background(VoCalTheme.Colors.card, in: Capsule())
            Button(action: onSpeak) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(VoCalTheme.Colors.ink)
                    .frame(width: 52, height: 52)
                    .background(VoCalTheme.Colors.card, in: Circle())
                    .overlay(Circle().strokeBorder(VoCalTheme.Colors.goldBorderStrong, lineWidth: 1.5))
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel("Say more by voice")
            .accessibilityIdentifier(A11y.VoiceLog.answerMic)
        }
    }

    private func send() {
        let text = more.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        more = ""
        fieldFocused = false
        onSayMore(text)
    }

    /// The quiet close: the answer follows the finger sideways and leaves past the distance,
    /// with the one `select` tick. A mostly vertical drag is not ours.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                dragX = value.translation.width
            }
            .onEnded { value in
                let close = abs(value.translation.width) > Self.closeDistance
                    && abs(value.translation.width) > abs(value.translation.height)
                withAnimation(.snappy(duration: 0.25)) { dragX = 0 }
                if close {
                    VoCalHaptics.select()
                    onClose()
                }
            }
    }
}
