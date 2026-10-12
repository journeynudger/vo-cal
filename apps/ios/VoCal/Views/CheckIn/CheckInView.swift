import SwiftUI
import VoCalCore

/// G1 — the weekly check-in. A short form (the system pre-fills what it knows; you answer what
/// it can't), then a rule-derived recommendation with its plain-English why and accept / keep.
/// Black/gold, VoCalTheme only. Accepting applies the new protocol version (mock today).
/// Decision 69 made it the place the plan is remade: it opens with the person's own words from
/// last week, asks what got in the way (the intake's four answers, writing the preference), and
/// closes with a sentence to next week's self. The adherence row describes rather than grades.
struct CheckInView: View {
    /// Called when the check-in finishes; `applied` is true if a new protocol was accepted, so
    /// the caller can refresh Today.
    var onComplete: (_ applied: Bool) -> Void

    @State private var model: CheckInViewModel
    @Environment(\.dismiss) private var dismiss

    init(onComplete: @escaping (_ applied: Bool) -> Void, model: CheckInViewModel? = nil) {
        self.onComplete = onComplete
        _model = State(initialValue: model ?? CheckInViewModel())
    }

    var body: some View {
        ZStack {
            VoCalTheme.Colors.background.ignoresSafeArea()
            switch model.phase {
            case .form: form
            case .submitting: busy("Thinking it through\u{2026}")
            case let .recommendation(rec): recommendation(rec)
            case .done: Color.clear
            }
        }
        .task { await model.load() }
        .onChange(of: model.phase) { _, new in
            if new == .done {
                // `applied` is the proof an adjustment actually landed server-side — only then
                // does Today refresh (a failed accept never reaches .done).
                onComplete(model.applied)
                dismiss()
            }
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    // MARK: - Form

    private var form: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: VoCalTheme.Spacing.l) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Weekly check-in").sectionHeader()
                        Text("How did the week go?")
                            .font(.system(size: 27, weight: .semibold))
                            .foregroundStyle(VoCalTheme.Colors.ink)
                    }
                    .padding(.top, VoCalTheme.Spacing.l)

                    // The mirror (decision 69): their own sentence, verbatim, before they answer
                    // again. Absent when there is none; never an empty quotation.
                    if let note = model.previousNote {
                        previousNoteCard(note)
                    }

                    // Only shown when the week-so-far summary is actually known (hidden on the
                    // live path until the server surfaces it — no fabricated "0 of 7 days").
                    if let computed = model.computed {
                        computedCard(computed)
                    }

                    // The week's movement from the phone alone (spec 6.12), beside the question
                    // the recommendation will ask; shown, never sent.
                    if let steps = model.stepsLine {
                        HStack(spacing: VoCalTheme.Spacing.s) {
                            Image(systemName: "figure.walk").foregroundStyle(VoCalTheme.Colors.gold)
                            Text(steps)
                                .font(VoCalTheme.Fonts.secondaryLabel)
                                .foregroundStyle(VoCalTheme.Colors.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityIdentifier(A11y.CheckIn.stepsLine)
                    }

                    field("Today's weight") {
                        HStack {
                            TextField("lb", text: $model.weightText)
                                .keyboardType(.decimalPad)
                                .font(VoCalTheme.Fonts.primaryLabel)
                            Text("lb").font(VoCalTheme.Fonts.secondaryLabel).foregroundStyle(VoCalTheme.Colors.muted)
                        }
                    }
                    scale("How's hunger been?", value: $model.hunger, low: "Ravenous", high: "Satisfied")
                    scale("Energy?", value: $model.energy, low: "Drained", high: "Great")
                    // A description, not a grade (Adams and Leary 2007: self-judgment after a
                    // lapse predicts the next one).
                    scale("How close did the week feel to the plan?", value: $model.adherence, low: "Far from it", high: "Right on it")

                    // The lapse question (decision 69, spec B1): the intake's four answers, any or
                    // none; the preference moves on submit, so one thing changes for next week.
                    VStack(alignment: .leading, spacing: VoCalTheme.Spacing.s) {
                        Text("What got in the way this week?")
                            .font(VoCalTheme.Fonts.formLabel)
                            .foregroundStyle(VoCalTheme.Colors.muted)
                        Text("Pick what fits. One thing changes for next week.")
                            .font(VoCalTheme.Fonts.formLabel)
                            .foregroundStyle(VoCalTheme.Colors.muted)
                        FrictionChooser(selection: $model.frictions)
                            .accessibilityIdentifier(A11y.CheckIn.lapseChooser)
                    }

                    field("Anything you want next week's you to read?") {
                        TextField("A sentence to yourself", text: $model.notes, axis: .vertical)
                            .font(VoCalTheme.Fonts.secondaryLabel)
                            .lineLimit(1...3)
                    }
                }
                .padding(.horizontal, VoCalTheme.Spacing.l)
                .padding(.bottom, VoCalTheme.Spacing.xl)
            }
            PillButton(title: "See my recommendation") { Task { await model.submit() } }
                .padding(VoCalTheme.Spacing.l)
        }
        .overlay(alignment: .topTrailing) { closeButton }
    }

    private func previousNoteCard(_ note: CheckinNote) -> some View {
        VStack(alignment: .leading, spacing: VoCalTheme.Spacing.xs) {
            Text(model.previousNoteLabel)
                .font(VoCalTheme.Fonts.formLabel)
                .foregroundStyle(VoCalTheme.Colors.muted)
            Text("\u{201C}\(note.text)\u{201D}")
                .font(VoCalTheme.Fonts.body.italic())
                .foregroundStyle(VoCalTheme.Colors.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(VoCalTheme.Spacing.l)
        .background(VoCalTheme.Colors.softFill, in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: VoCalTheme.Radius.card, style: .continuous)
                .stroke(VoCalTheme.Colors.goldBorder, lineWidth: 1.5)
        )
        .accessibilityIdentifier(A11y.CheckIn.previousNote)
    }

    private func computedCard(_ computed: CheckinComputed) -> some View {
        // Consistency AND capture quality (the certainty layer): effort + sharpness are the
        // two levers the user controls. Calm copy — a certainty % is transparency, not a grade.
        VStack(alignment: .leading, spacing: VoCalTheme.Spacing.s) {
            HStack(spacing: VoCalTheme.Spacing.s) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(VoCalTheme.Colors.gold)
                Text("You logged \(computed.loggedDays) of \(computed.weekDays) days"
                    + (computed.avgKcal > 0 ? " · avg \(computed.avgKcal.formatted()) kcal" : ""))
                    .font(VoCalTheme.Fonts.secondaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.ink)
            }
            if let certainty = computed.avgCertainty {
                HStack(spacing: VoCalTheme.Spacing.s) {
                    Image(systemName: "scope").foregroundStyle(VoCalTheme.Colors.gold)
                    Text("\(computed.mealsLogged) meals · \(certainty)% avg certainty")
                        .font(VoCalTheme.Fonts.secondaryLabel)
                        .foregroundStyle(VoCalTheme.Colors.ink)
                }
            }
            if let tip = computed.focusTip {
                Text(tip)
                    .font(VoCalTheme.Fonts.formLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(VoCalTheme.Spacing.m)
        .background(VoCalTheme.Colors.gold.opacity(0.12), in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.chip, style: .continuous))
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: VoCalTheme.Spacing.s) {
            Text(label).font(VoCalTheme.Fonts.formLabel).foregroundStyle(VoCalTheme.Colors.muted)
            content()
                .padding(VoCalTheme.Spacing.m)
                .background(VoCalTheme.Colors.card, in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.chip, style: .continuous))
        }
    }

    private func scale(_ label: String, value: Binding<Int?>, low: String, high: String) -> some View {
        VStack(alignment: .leading, spacing: VoCalTheme.Spacing.s) {
            Text(label).font(VoCalTheme.Fonts.formLabel).foregroundStyle(VoCalTheme.Colors.muted)
            HStack(spacing: VoCalTheme.Spacing.s) {
                ForEach(1...5, id: \.self) { n in
                    Button { value.wrappedValue = n } label: {
                        Text("\(n)")
                            .font(VoCalTheme.Fonts.primaryLabel)
                            .foregroundStyle(value.wrappedValue == n ? VoCalTheme.Colors.onCta : VoCalTheme.Colors.ink)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(
                                value.wrappedValue == n ? VoCalTheme.Colors.cta : VoCalTheme.Colors.card,
                                in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.chip, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Text(low); Spacer(); Text(high)
            }
            .font(VoCalTheme.Fonts.formLabel)
            .foregroundStyle(VoCalTheme.Colors.muted)
        }
    }

    // MARK: - Recommendation

    private func recommendation(_ rec: CheckinRecommendation) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: VoCalTheme.Spacing.l) {
                    Text("Your recommendation").sectionHeader()
                        .padding(.top, VoCalTheme.Spacing.xl)

                    GlassCard(accent: VoCalTheme.Colors.gold) {
                        VStack(alignment: .leading, spacing: VoCalTheme.Spacing.m) {
                            Text(rec.headline)
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(VoCalTheme.Colors.ink)
                            if let next = rec.newTargets {
                                HStack(spacing: VoCalTheme.Spacing.s) {
                                    Text("New daily calories")
                                        .font(VoCalTheme.Fonts.formLabel)
                                        .foregroundStyle(VoCalTheme.Colors.muted)
                                    Spacer()
                                    Text(next.kcal.formatted(.number.grouping(.automatic)))
                                        .font(VoCalTheme.Fonts.numeral(28))
                                        .monospacedDigit()
                                        .foregroundStyle(VoCalTheme.Colors.gold)
                                }
                                .padding(.top, VoCalTheme.Spacing.xs)
                            }
                            Text(rec.why)
                                .font(VoCalTheme.Fonts.secondaryLabel)
                                .foregroundStyle(VoCalTheme.Colors.ink)
                        }
                    }

                    Text("Not medical advice. Recommendations are rule-derived from your inputs and rail-bounded.")
                        .font(VoCalTheme.Fonts.formLabel)
                        .foregroundStyle(VoCalTheme.Colors.muted)
                }
                .padding(.horizontal, VoCalTheme.Spacing.l)
                .padding(.bottom, VoCalTheme.Spacing.xl)
            }
            VStack(spacing: VoCalTheme.Spacing.s) {
                if rec.newTargets != nil {
                    PillButton(title: "Update my plan") {
                        Task { await model.accept(rec) }
                    }
                    VoCalButton(title: "Keep my current plan", kind: .tertiary) { model.keep() }
                } else {
                    PillButton(title: "Done") { model.keep() }
                }
            }
            .padding(VoCalTheme.Spacing.l)
        }
    }

    // MARK: - Chrome

    private func busy(_ line: String) -> some View {
        VStack(spacing: VoCalTheme.Spacing.l) {
            VoCalLoader(size: 48)
            Text(line).font(VoCalTheme.Fonts.secondaryLabel).foregroundStyle(VoCalTheme.Colors.muted)
        }
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(VoCalTheme.Colors.ink)
                .frame(width: 34, height: 34)
                .glassEffect(.regular, in: Circle())
        }
        .padding(VoCalTheme.Spacing.l)
    }
}

#Preview {
    CheckInView(onComplete: { _ in })
}
