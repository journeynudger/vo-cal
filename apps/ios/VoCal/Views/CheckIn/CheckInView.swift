import SwiftUI
import VoCalCore

/// G1 — the weekly check-in. A short form (the system pre-fills what it knows; you answer what
/// it can't), then a rule-derived recommendation with its plain-English why and accept / keep.
/// Black/gold, VoCalTheme only. Accepting applies the new protocol version (mock today).
struct CheckInView: View {
    /// Called when the check-in finishes; `applied` is true if a new protocol was accepted, so
    /// the caller can refresh Today.
    var onComplete: (_ applied: Bool) -> Void

    @State private var model = CheckInViewModel()
    @Environment(\.dismiss) private var dismiss
    @State private var acceptedAdjustment = false

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
                onComplete(acceptedAdjustment)
                dismiss()
            }
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

                    computedCard

                    field("Today's weight") {
                        HStack {
                            TextField("kg", text: $model.weightText)
                                .keyboardType(.decimalPad)
                                .font(VoCalTheme.Fonts.primaryLabel)
                            Text("kg").font(VoCalTheme.Fonts.secondaryLabel).foregroundStyle(VoCalTheme.Colors.muted)
                        }
                    }
                    scale("How's hunger been?", value: $model.hunger, low: "Ravenous", high: "Satisfied")
                    scale("Energy?", value: $model.energy, low: "Drained", high: "Great")
                    scale("How'd you stick to the plan?", value: $model.adherence, low: "Off it", high: "Nailed it")
                    field("Anything else? (optional)") {
                        TextField("e.g. travelled Tuesday, slept badly", text: $model.notes, axis: .vertical)
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

    private var computedCard: some View {
        HStack(spacing: VoCalTheme.Spacing.s) {
            Image(systemName: "checkmark.seal.fill").foregroundStyle(VoCalTheme.Colors.gold)
            Text("You logged \(model.computed.loggedDays) of \(model.computed.weekDays) days"
                + (model.computed.avgKcal > 0 ? " · avg \(model.computed.avgKcal.formatted()) kcal" : ""))
                .font(VoCalTheme.Fonts.secondaryLabel)
                .foregroundStyle(VoCalTheme.Colors.ink)
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
                    .padding(VoCalTheme.Spacing.l)
                    .background(VoCalTheme.Colors.card, in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.card, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: VoCalTheme.Radius.card, style: .continuous)
                            .strokeBorder(VoCalTheme.Colors.gold.opacity(0.5), lineWidth: 1)
                    )

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
                        acceptedAdjustment = true
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
            ProgressView().controlSize(.large).tint(VoCalTheme.Colors.gold)
            Text(line).font(VoCalTheme.Fonts.secondaryLabel).foregroundStyle(VoCalTheme.Colors.muted)
        }
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(VoCalTheme.Colors.ink)
                .frame(width: 34, height: 34)
                .background(VoCalTheme.Colors.card, in: Circle())
        }
        .padding(VoCalTheme.Spacing.l)
    }
}

#Preview {
    CheckInView(onComplete: { _ in })
}
