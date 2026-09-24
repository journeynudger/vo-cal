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
| `vcOptimal` | `#4F9D69` | The one positive green: in-range bands, completion, goal met — never a macro color |
| `vcAlert` | `#B5443A` | The one non-macro red: over goal, capture escalation, destructive — distinct from protein red |

Rules:

- **Gold is reserved** for brand accent: highlight numerals, active/selected states, and confidence. It is never a fill for large surfaces and never a macro color.
- **Macro chips keep their semantic colors** everywhere they appear (rings, chips, protocol cards). Macro colors are never used for non-macro meaning.
- **Light mode only in P0** (`UIUserInterfaceStyle = Light` locked in Info.plist). No dark-mode variants exist; do not add conditional colors.

## Radii

| Token | Value |
|---|---|
| Card | 24 pt |
| Row (a logged meal, a micro tile) | 20 pt |
| Chip | 16 pt |
| Pill | capsule (height/2) |

Three radii and no more (Rams pass, 2026-09-25): a 68 pt row at 24 reads as a pill, at 16
as a chip.

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
| `StatCard` | `vcCard` r24 card (r20 for tiles), one fill always; completion is a green hairline plus the tick in its header, never a tinted fill or a corner badge |
| `CardHeader` | The header every card starts with: 13 pt muted title, optional completion tick, the value 8 pt below, one 13 pt support line 4 pt under it. Fixed spacings so every card sits on one rhythm |
| `CaptureBar` | The app's only bottom chrome: `[+] [What did you eat?] [mic]`. The mic (56 pt gold-on-light glass circle) is the primary control; typing morphs the slot into the Vo-Cal mark and raises answers from the person's history; `+` opens Take a photo / Choose a photo; a staged photo sits above the row with a note field. One spring for every motion (response 0.42, damping 0.9); frosted, never opaque; ported from Serein |
| `ProfileCircleButton` | 44 pt glass circle with `person.fill`, top trailing on Today: the way to Settings (the tab bar is gone) |
| `StatusBarFrost` | A material strip under the status bar on every scrolling root, so content passes beneath the time and battery instead of colliding with them |
| `SwipeableRow` | A row in a ScrollView that swipes right to edit and left to delete (`HorizontalPull`), a glyph rising behind it, a tick when it arms |
| `RecognizedMealCard` | "Is this your metal detox smoothie?" above the result: Yes logs the usual's items under its name, No dismisses; a one-line hint the first time |
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
`OnboardingProgressBar` top (10 steps: 7 questions + 3 animated benefit interstitials — realistic pace after the goal question, momentum after training, long-term results before the protocol build; `BenefitInterstitials.swift`). One question per screen: form label overline, question as screen title, options as `vcCard` r16 chips (selected = `vcInk` border + check), `PillButton` "Continue" pinned bottom. Autosave-resume: re-entry lands on the first unanswered step. Disclaimer (see `docs/PROTOCOL_LOGIC.md` §9) shown in-flow.

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
- **`GlassCard`**: elevated *frosted* card (material fill + soft shadow + hairline, optional
  accent border) — form-fit of Beacon's `GlassCard` to light mode. Used for surfaces that should
  read as results floating above the page: the voice-log calories card, per-ingredient checks
  (gold accent), and the check-in recommendation. Flat `StatCard` (cream) stays for list rows.
- **Spinner → `VoCalLoader`**: the system `ProgressView` is replaced app-wide (voice processing,
  Today/Protocol/Check-in loading, in-card "updating…").

---

## 2026-08-19 — Status colors for weekly progress (Lorenzo beta feedback)

Weekly bars now read as status, not just intensity (`apps/ios/VoCal/Views/Week/WeekStatusStyle.swift`):
gold = under / on the way (today in progress draws full gold, a past under-goal day sits at gold
55%), green (`vcOptimal`) = goal met (the existing 90–105% on-target band), red (`vcAlert`) = over.
The change consolidated the palette rather than growing it: the previously undocumented `optimal`
green (protein band, completion states) is now the one positive green and covers "goal met"; a new
`vcAlert` `#B5443A` is the one non-macro red (weekly overage, mid-capture escalation, destructive
rows) and absorbed the near-duplicate `danger` token. Gold's reserved role (brand accent:
highlighted numerals, active states, confidence) gains one more meaning, progress toward goal.
Macro colors remain semantic-only and are never repurposed for status, in either direction.

---

## 2026-08-20 — Layering rule: floating chrome never occludes resting controls

Field report (Lorenzo, build-25 rc): the item-detail sheet opened at `.medium` with its
pinned glass footer floating over the fat-ratio field — an interactive control RESTING
half-hidden behind translucent chrome reads as broken, even though it could scroll clear.

The rule, for every surface with floating/pinned chrome (glass footers, the tab bar, pinned
CTAs) and for every sheet detent:

1. **At the surface's presented size, every interactive control must clear the chrome at
   rest.** Content scrolling *under* glass is for overflow the user creates by scrolling —
   never the initial layout. If the content doesn't fit above the chrome at `.medium`,
   the sheet presents at `.large` (or a fitting fraction); don't ship the occlusion.
2. **Secondary actions center under their pill** (`.frame(maxWidth: .infinity)` inside
   leading-aligned stacks — a left-hugging Cancel under a full-width Done is a bug).
3. **Verification is visual:** any change to a sheet, footer, or floating bar gets a
   simulator screenshot AT THE PRESENTED DETENT, reviewed specifically for occlusion and
   alignment before it ships. A screenshot that shows a control cut off behind chrome is a
   red build regardless of what compiles.

## Gestures and touches

One vocabulary, the phone's own, applied where a gesture is the natural verb (restructure R12,
ported from Serein where the pattern was dogfood-hardened):

| Gesture | Where | What it does |
|---|---|---|
| Tap | mic, rows, cards | The primary action (record, open, edit). |
| Long-press (context menu) | Today meal rows, unfinished recordings, usuals, result item cards | Edit, Name this meal or Delete; Finish or Discard; Forget. |
| Swipe right / left | Today meal rows | Edit / Delete (`SwipeableRow`); the row follows the finger, a tick marks the point of no return, delete plays the warning. |
| Type / photograph | the capture bar | A typed log is a transcript with no audio; a photo is a capture (docs/CAPTURE_LIFECYCLE.md §9). Voice stays the emphasized way in. |
| Pull down to refresh | Today | Reloads the day and the unfinished list. |
| Horizontal pull | the week strip | Pages a week back (rightward) or forward (leftward, while there is one); the strip follows the finger with damping and a light tick marks the point of no return. `HorizontalPull` is a UIKit pan that decides at the first movement, so the page's scroll never waits on it. |
| Drag | week budget bars | Sets a day's allocation in steps. |

Touches (`VoCalHaptics`) are texture, never a claim: a swell when a capture starts or stops,
a settled double-thump only on the commit receipt (never on a deferred commit), the system's
success tick only when the server row lands ("Logged"), a light tick when a pull arms.

Every action answers the finger (2026-09-25): every button clicks on touch-down
(`PressableButtonStyle` calls `VoCalHaptics.tap`), a chip or a day cell ticks (`select`), a
rename or a staged photo confirms (`success`), a delete warns (`warning`), a swipe arms
(`armed`). The two swells stay reserved for the recording, so the deep touch keeps meaning
"the capture".

## The top and the bottom of every root (2026-09-25)

The tab bar is gone. Today is the only root; Settings opens from the profile circle as a
cover with its own close; the capture bar is the whole bottom chrome and the frosted strip
is the whole top chrome. Content scrolls under both. Nothing else floats.

## The bar, to the letter (2026-09-24 evening)

Build 30 on the phone showed where the port of Serein's bar had thinned it (Lorenzo: the plus
opened the week, the keyboard had no way out, the mic jumped). The bar is now Serein's to the
point, in Vo-Cal's palette:

- **Three states of one row.** Resting: the plus and the mic as twin 56 pt droplets around
  the capsule. Menu: Camera and Photos on frosted glass grown from the plus's droplet, owning
  the row. Composing: one card takes the row, the staged photo 120 pt inside its top-left
  corner, the words beneath, the plus and the Vo-Cal mark in its bottom corners. One spring
  moves all of it.
- **Every way out.** A tap anywhere on the page closes the menu or puts the keyboard away
  (Serein's catchers, laid under the bar by the shell). The mark with nothing to send is
  "Done" and puts the keyboard away too. A 36 pt dead zone above the row swallows a near
  miss, so a finger landing high never opens the card behind the bar.
- **A glass surface is solid to the finger.** Glass contributes no hit region of its own on
  iOS 26.5, so `liquidGlass` makes its shape the hit region; a glyph on glass with a hairline
  rim took no touch for a build, and the touch landed on the page beneath (`LiquidGlass.swift`
  carries the finding). Round glass controls share the droplets' bright face.
- **The camera and the library are presented by the shell**, never from inside the safe-area
  inset; what comes back is staged in the composer, and words typed beside it are the note the
  photo parse reads.
- **The Action button card** sits on the page above the bar, on its own frost, with Open
  Settings and Later; never a card inside a sheet.
- **Calories and protein are twins:** title, a 40 pt numeral, a bar, one line, one height.
  The calories bar is consumed of the target in gold, alert red past it.
- **The capture's first seconds** draw through one view: the ring draws in as the mic arms
  and settles when listening is confirmed; nothing changes the mic's frame. The arming pulse
  is gone (a repeat-forever scale had no clean stop and the mic snapped back on "Listening").
- **Usuals are named the way meals are:** press and hold a chip, Rename, the same alert.
