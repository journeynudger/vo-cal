# Vo-Cal - Marketing landing page (`web/`)

A single-file, self-contained marketing landing page for Vo-Cal. No build step, no
dependencies, no external assets - open `index.html` in any browser or drop it on any
static host (Vercel, Netlify, Cloudflare Pages, GitHub Pages, S3).

## What it is

- **`index.html`** - the whole site. Inline CSS + a small vanilla-JS block (nav shadow,
  mobile menu, scroll-reveal, footer year). The favicon and all phone mockups are inline
  SVG/CSS - nothing is fetched at runtime.

## Design

- Uses the **frozen app palette** from `../docs/DESIGN.md` (black/gold on warm off-white:
  `--bg #FAF9F6`, `--ink #1A1A1A`, `--gold #C4A35A`, `--cta #111111`) and the semantic
  macro colors (protein/carbs/fats). The marketing voice adds an editorial serif for
  display headlines (system `New York`/Georgia stack); body + UI type is the app's SF Pro
  system stack.
- The device mockups render the **actual product screens** (Today dashboard, voice-log
  with per-ingredient checks, mid-week nudge, personalized protocol) in pure CSS so the
  page stays self-contained and on-brand - swap them for real app screenshots once the
  iOS UI phases (E/D/F/G) are screenshot-ready.
- Section rhythm references a best-in-class fitness landing page (`future.co`); **all copy
  and assets are original to Vo-Cal**. Messaging is drawn from `../docs/PRODUCT_BRIEF.md`.

## Honesty

No fabricated metrics or App Store ratings (Vo-Cal is pre-launch). Social proof is the
cofounder's real coaching thesis; a visible note says real beta results will be published
when they exist. Keep it that way - see the project's MUST-NOT rules in `../AGENTS.md`.

## Run it

```bash
# simplest
open index.html

# or serve locally
python3 -m http.server 4321 --directory .   # then http://localhost:4321
```

## Edit

It's one file. Tokens are CSS custom properties at the top of the `<style>` block; keep
them in sync with `../docs/DESIGN.md` if the palette ever changes (it's frozen - a change
requires a `decisions.md` amendment). Copy lives inline in semantic sections
(`<!-- Hero -->`, `<!-- Four pillars -->`, etc.).
