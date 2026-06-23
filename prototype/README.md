# Vo-Cal - interactive app prototype (`prototype/`)

A clickable, self-contained walkthrough of the Vo-Cal app for demos and design review.
Open `app-preview.html` in any browser - no build, no dependencies, **no JavaScript**.

## What it shows

A full tap-through of the core flow, in the frozen black/gold design system:

1. **Welcome** - "Photos guess. Voice knows."
2. **Intake (7 steps)** - basics → goal → *your real life* (occupation/obligations - activity is
   inferred, never asked) → training → hunger & history → the gray area (stress/meds) → food preferences.
3. **Protocol** - the personalized starting target (calories + protein/water/fiber/produce), each with an
   expandable "why", plus the "built from what you told us" chips and the *not medical advice* disclaimer.
4. **Sign in with Apple** - auth shown *after* the value, per the design.
5. **Today** - the split Calories-left / Protein dashboard + the produce/water/fiber micro row.
6. **Voice log** - meal-type picker → centered mic (listening) → the *enhancing* color-sweep →
   parsed items with confidence + per-ingredient checks (cheddar type, light vs regular mayo) → meal logged,
   dashboard updates.
7. **Progress** - weight trend, logging streak, daily-average calories, strength-based encouragement.

Tap **Restart** (top-right) to return to the start.

## Why pure CSS (no JS)

The navigation is a hidden-radio + `:checked` state machine; the protocol "why" rows are native
`<details>`; the voice "enhancing → results" reveal is a CSS animation. This is deliberate: the
preview must render inside sandboxed iframes (e.g. the Claude artifact viewer) that don't execute
inline `<script>`. Pure CSS means it works everywhere.

## Fidelity / honesty

- Palette and components match `../docs/DESIGN.md` (macro colors stay semantic; produce/water/fiber use a
  neutral metric tint). Intake steps follow `../.claude/plans/phase-f-intake-protocol.md` and the
  `../docs/PRODUCT_BRIEF.md` thesis.
- **All numbers are illustrative** for one persona (a night-shift nurse) - this is a design prototype, not
  live output from the protocol engine.

## Run it

```bash
open app-preview.html
```
