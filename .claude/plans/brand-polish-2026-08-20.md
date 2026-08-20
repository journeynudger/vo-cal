# Brand polish — every screen wears the black/gold (2026-08-20)

> Source: Lorenzo, 2026-08-20 — "every screen that looks like edit meal … needs to look more
> professional and on brand, like the new settings — which should actually say Profile now,
> with a profile icon." One feature branch per screen; delegated to lighter models per screen.
>
> Next: merge the three branches, sim sweep every secondary screen, fix stragglers.

## Audit method

Two greps over `apps/ios/VoCal/Views`: (1) files never referencing `VoCalTheme`, (2) system-
styling markers (`Form`/`List`/system semantic colors/system backgrounds). False positives
ruled out by reading (ChoiceList matched `List(`, a `// MARK: - Form` comment matched `Form`).
IntakeFlowView, CheckInView, OnboardingFlowView (pure coordinator) are already on-brand.

Confirmed offenders: **LoggedMealEditView** (system List + toolbar + ProgressView +
ContentUnavailableView + system-red destructive row + `protein` token misused for a status
flag) and its **ItemMacroEditor** (system Form); **MealItemEditSheet** (system Form, zero
theme usage). Plus the rename: tab + screen say "Settings" with a gear glyph.

## Tasks

### P1. `feature/polish-meal-edit` — LoggedMealEditView + ItemMacroEditor reskin *(sonnet, worktree)*

- [x] Custom header (X circle · "Edit meal" · gold Save), card-based item rows, gold
      attention flag (protein-token misuse fixed), branded add-by-voice + delete rows,
      VoCalLoader, themed failure stack; ItemMacroEditor → card fields + PillButton
- [x] Behavior/state/network byte-identical; `ios-app-build` green
- [x] **Commit:** `feat(ios): edit-meal sheet wears the brand`

### P2. `feature/polish-item-edit-sheet` — MealItemEditSheet reskin *(sonnet, worktree)*

- [x] Form → branded sheet: card fields, unit/state chips (ChoiceList pattern), pinned
      PillButton Save; RefineAnswer logic byte-identical; a11y ids kept
- [x] `ios-app-build` green
- [x] **Commit:** `feat(ios): item detail sheet wears the brand`

### P3. `feature/profile-tab` — Settings presents as Profile *(sonnet, worktree)*

- [x] Tab: gearshape.fill/"Settings" → person.crop.circle.fill/"Profile"; screen title →
      "Profile"; inner "Profile" row de-collided (→ "My details"); a11y ids/type names unchanged
- [x] `ios-app-build` green
- [x] **Commit:** `feat(ios): settings presents as Profile`

### P4. Merge + sweep

- [x] Merge P1–P3 to main (no push)
- [x] Sim visual sweep of secondary screens (Profile sub-screens, check-in, water/detail
      sheets) — anything still rough gets its own branch
- [x] Battery: `scripts/check` + `bin/ios-app-build` (voice test not required — no
      capture-path files touched; MealItemEditSheet is result-surface UI only)
- [x] Screenshots to Lorenzo

## Amendments

### 2026-08-20 — P1 finished by the main session, not the delegate

The P1 agent lost ~50 min to machine-sleep stalls and a stale worktree base and produced no
edits; it was stopped and the reskin implemented directly (same spec). P2/P3 delegates
delivered. Sonnet delegation worked where runs were short; long runs on this machine keep
getting killed by sleep — prefer shorter agent tasks while that's true.

## Progress log

| Task | Status | SHA |
|---|---|---|
| P1 meal edit reskin | ✅ sim-verified (done in-session) | cff328f |
| P2 item sheet reskin | ✅ sim-verified | 29d9b15 |
| P3 profile rename | ✅ sim-verified | 6a86157 |
| P4 merge + battery + sweep | ✅ 659 API / SPM / zero-warn / 9-9 voice | (wrap) |
