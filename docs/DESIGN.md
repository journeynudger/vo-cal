# Design System

Authored fresh from frozen decision #6: Cal AI reference layout, black/gold palette. These tokens are **frozen** — changing any value requires a decisions.md amendment. Tokens live in code only in `apps/ios/VoCal/Theme/VoCalTheme.swift`; views never use inline hex.

## Color tokens

| Token | Hex | Role |
|---|---|---|
| `vcBackground` | `#FAF9F6` | App background (warm off-white) |
| `vcCard` | `#F4F2EE` | Card and chip fills |
| `vcInk` | `#1A1A1A` | Primary text |
| `vcMuted` | `#8A8A8E` | Secondary text, captions, inactive states |
| `vcGold` | `#C4A35A` | Brand accent: highlighted numerals, active states, confidence |
| `vcCTA` | `#111111` | Pill CTAs, the floating mic button |
| `vcWhite` | `#FFFFFF` | Text/icons on dark fills; elevated cards |
| `vcProtein` | `#DB4F40` | Protein — semantic red, frozen |
| `vcCarbs` | `#DE9C3B` | Carbs — semantic amber, frozen |
| `vcFats` | `#5B8DEF` | Fats — semantic blue, frozen |

Rules:

- **Gold is reserved** for brand accent: highlight numerals, active/selected states, and confidence. It is never a fill for large surfaces and never a macro color.
- **Macro chips keep their semantic colors** everywhere they appear (rings, chips, protocol cards). Macro colors are never used for non-macro meaning.
- **Light mode only in P0** (`UIUserInterfaceStyle = Light` locked in Info.plist). No dark-mode variants exist; do not add conditional colors.

## Radii

| Token | Value |
|---|---|
| Card | 24 pt |
| Chip | 16 pt |
| Pill | capsule (height/2) |

## Spacing scale

`4 / 8 / 12 / 16 / 24 / 32` pt. No other spacing constants; pick the nearest step.

## Type ramp (SF Pro)

| Role | Size / weight |
|---|---|
| Hero numerals (calories left, protocol kcal) | 40–64 pt semibold, monospaced digits |
| Screen title | 20–22 pt medium |
| Primary label (card titles, item names) | 16–17 pt medium |
| Secondary label (amounts, captions) | 14–15 pt regular |
| Form label / overline | 12–13 pt medium, tracking +0.5, often uppercase |

Numerals are the design's voice — large, confident, `vcInk` by default, `vcGold` when highlighted (today's headline number, an active selection).

## Component inventory

| Component | Spec (one line) |
|---|---|
| `PillButton` | Black (`vcCTA`) capsule, white 17 pt medium label, 52 pt height, full-width minus 16 pt gutters |
| `StatCard` | `vcCard` r24 card; form label on top, hero numeral below, optional trailing trend glyph |
| `MacroRing` | Circular progress ring, 8 pt stroke, semantic macro color on `vcCard` track, remaining-grams numeral centered |
| `ConfidenceBadge` | Gold-scale 0–100% chip: `vcGold` at full opacity ≥ high confidence, fading toward `vcMuted` as confidence drops; r16 |
| `MealItemCard` | `vcCard` r24 row: item name (primary), amount + unit (secondary), kcal (numeral, trailing), `ConfidenceBadge`, trash affordance |
| `WeekStrip` | Horizontal M T W T F S S selector; dot under each day, filled `vcInk` for selected, `vcMuted` for past, hollow for future |
| `OnboardingProgressBar` | Thin (4 pt) track in `vcCard`, fill in `vcInk`, step-fraction width, top of intake screens |

Floating mic button (app chrome, not a reusable component): 56 pt `vcCTA` circle, white mic glyph, bottom-right over Today, opens Voice log.

## Per-screen layout notes (the 6 screens)

### 1. Welcome
Full-bleed `vcBackground`. Wordmark top-third. Headline "Photos guess. Voice knows." in hero type (`vcInk`, "Voice knows." may carry `vcGold`). One `PillButton` "Build my protocol" pinned bottom with 32 pt bottom inset. Nothing else — no carousel, no login wall (auth comes after intake value is shown).

### 2. Intake
`OnboardingProgressBar` top (7 steps). One question per screen: form label overline, question as screen title, options as `vcCard` r16 chips (selected = `vcInk` border + check), `PillButton` "Continue" pinned bottom. Autosave-resume: re-entry lands on the first unanswered step. Disclaimer (see `docs/PROTOCOL_LOGIC.md` §9) shown in-flow.

### 3. Protocol
Scrolling. Hero: daily kcal target as 64 pt numeral with `vcGold` highlight, "why" one-liner under it in secondary type. Macro row: three `StatCard`s with semantic-colored grams and per-macro "why" disclosure. Meal-structure card (timeline of meals in the eating window). Behavioral rules as `vcCard` list rows with expandable "why". Lingo tutorial cards (the gold-standard utterances, e.g. "200g cooked jasmine rice"). Disclaimer footer, always visible at end of scroll. CTA "Start logging".

### 4. Today
Date + `WeekStrip` at top. Hero `StatCard`: calories left, 64 pt. Below: three `MacroRing`s (protein/carbs/fats) in a row. "Logged today" section: `MealItemCard` per meal with kcal and confidence; average `ConfidenceBadge` for the day in the section header. Floating mic button bottom-right. Empty state points at the mic button, never at a text field.

### 5. Voice log
Full-screen sheet from the mic button. Center: large mic button with recording state; status line beneath renders the claim ladder honestly per `docs/VOICE_CAPTURE.md` (calm acknowledgement → unmistakable escalation; "Saved" only on receipt). After capture: transcript in secondary type, then parsed `MealItemCard`s (editable amounts, deletable), per-item `ConfidenceBadge`s, at most one clarifying-question chip (`vcCard`, skippable, per `docs/PARSER_CONTRACT.md`). `PillButton` "Log meal" confirms.

### 6. Weekly check-in
Form screen: weight (numeral entry), adherence / hunger / energy as chip rows. Submit → recommendation card: proposed v(n+1) deltas as `StatCard`s with engine "why" text, accept (`PillButton`) or keep current protocol. Disclaimer present (protocol surface). Accepting shows the new protocol screen.

## Non-negotiables recap

- Tokens only in `VoCalTheme.swift`; **no inline hex in views**.
- Light mode only in P0.
- Gold = brand accent / highlight numerals / confidence, nothing else.
- Macro colors are semantic and frozen.
- Every numeral that represents live data uses monospaced digits (no layout shimmer while counting).

---

## 2026-06-18 — Dashboard final + UI reference (decisions #28, #30, #40)

**Home dashboard (locked):** a split top card — **Calories left** | **Protein** (shown with an optimal-range band) — over a row of three **micronutrient-minimum** cards: **Produce servings · Water · Fiber** (each "X / min" with a fill bar). Carbs & fat are NOT on the home dashboard (still on meal detail). This matches Francesco's coaching pillars exactly.

**Opt-in metrics edit screen (new, #30):** fats, carbs, sodium, sugar are off by default; a user adds any of them to their dashboard via an edit screen (diabetic → sugar, hypertensive → sodium). No unsolicited macro nagging anywhere.

**Per-ingredient checks (#29):** on the voice-log result, each ingredient whose unknown materially moves the meal (>75 cal / >10g) shows its own inline check with chips (beef fat ratio; cheddar whole/reduced/fat-free; mayo regular/light) — calories read "so far +" until resolved, with a "Log anyway (typical values)" escape.

**UI reference (#40) — green/cream nutrition app Lorenzo shared:** borrow the *patterns*, not the palette (palette stays black/gold):
- onboarding **food-preference chips** ("what do you like most" — multi-select food tiles) — fits the deep-intake "feel seen" goal;
- **water as a first-class dashboard card** (validates our micros row);
- **ingredient-detail with short descriptions** (a nice pattern for the parsed-item / meal-detail view).

Interactive prototype of the current direction: `scratchpad/vocal-preview.html` (hosted artifact).

---

## 2026-06-18 — Navigation / IA (decisions #41–43; Cal-AI-style)

**Tab bar: Home · [center Log] · Progress.** Home = overview/dashboard (calories left · protein · produce/water/fiber · meals logged); settings is a header icon, not a tab. The center **Log** button (black circle) is the primary action. **Progress** is the right tab. **No Groups tab** (social = out of scope).

**Log flow is meal-type-first:** tap Log → meal-type picker (Breakfast/Lunch/Dinner/Snack) → auto-advance into voice capture (centered mic → listening → transcribing → enhancing → parse → confirm); meal type pre-set, never re-asked.

**Progress screen:** weight + goal, logging streak, weight-trend chart (90D/6M/1Y/ALL), daily-average-calories trend, strength-based encouragement line, "Log Weight" action. Self-reported weight (no HealthKit, #17).

---

## 2026-06-19 — UI component framework (form-fit from Beacon, reference not copy)

Beacon (shipped) is the reference for *frontend conventions*, not visual style — we keep the
frozen black/gold palette, SF Pro, capsules, and light mode. Adopted, form-fit to Vo-Cal:

- **Role-based typography** (`VoCalTheme.Fonts` + `Tracking`): hierarchy from size · tracking ·
  casing · color, not heavy weights. Casing discipline (Beacon's rule): section/form labels are
  ALL CAPS + tracked; titles, buttons, names, and body stay sentence case; **never uppercase a
  button**. The one gold overline lives in `Text.sectionHeader(_:)` (was duplicated inline
  across Today / Protocol / Check-in / Intake).
- **Button system** (`VoCalButton` + `PressableButtonStyle`): three roles — `.primary` (black
  capsule), `.secondary` (outlined ink capsule), `.tertiary` (text link) — with uniform
  pressed / disabled / loading states. `PillButton` is the thin `.primary` alias. (Beacon's
  `BeaconButtonDesign`, our capsule/black-gold instead of its orange rounded-rect.)
- **`OnboardingStepScaffold`**: shared step chrome (back chevron + progress bar + scroll +
  pinned CTA), extending Beacon's `OnboardingStepContainer`; the intake flow uses it so steps
  only describe their question.
- **`VoCalLoader`**: branded gold waveform-bars loader (Beacon replaces the system spinner with
  a branded one; ours echoes the voice/mic identity).
- **`PreviewHelpers`** (DEBUG): centralized mock-backed view-model factories + `previewScreen()`.

We did **not** copy Beacon's Monument Grotesk, orange accent, gradient/glass backgrounds, or
custom font registration — those are Beacon's brand, not ours.
