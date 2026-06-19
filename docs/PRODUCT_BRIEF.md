# Vo-Cal — Product Brief

> **Source:** Cofounder conversation, Lorenzo × Francesco Provinzano, 2026-06-18 (raw transcript held by Lorenzo; processed prompt is the basis for this file).
> **Status:** Canonical product spec. When this conflicts with an older plan, this wins — but `docs/INVARIANTS.md` (safety/trust) still wins over everything.
> Francesco is the nutrition cofounder; his coaching method is the protocol IP (arriving via Notion, likely under NDA).

## What we're building

A **voice-first nutrition tracker** built on Serein's voice engine. The user *speaks* what they ate ("4 oz chicken thighs, a cup of cooked white rice, a cup of broccoli with a tablespoon of olive oil"); the app parses it, maps each item to a public food library (USDA FDC + internal dictionary — the MyFitnessPal-style pre-logged item carrying calories/macros), logs it, and shows a dead-simple dashboard of what's left to eat. One-line: **"ChatGPT meets MyFitnessPal" — but the entire point is removing friction, not adding features.**

## The core thesis (do not lose this)

The hard part of food tracking is **not** the perfect nutritional layout — it's **doing it at all.** Francesco's whole coaching career rests on this: clients who log get results; the layout is almost irrelevant. So Vo-Cal's job is singular — **collapse the friction of logging to near zero** — and voice is how. Saying a PB&J is one breath; typing bread + 2 tbsp peanut butter + 2 tbsp jelly is friction.

**The inverse principle is equally load-bearing: what the app does NOT do is more interesting than what it does.** MyFitnessPal "went off the deep end trying to do everything" — that's why people hate it. Vo-Cal is MyFitnessPal with ~10% of the surface area: the essential 10%. *"If we could have the version of MyFitnessPal I started with, you would not hate food tracking."*

## The three pillars (this is the whole product — "it doesn't need to be any more")

1. **Voice-first logging.** Speak food → AI parses → maps to library items with calories/macros. Radically less friction than typing. (Text search is the fallback, not the star.)
2. **A genuinely personalized protocol** from a deeper, more human intake than any other app — not just height/weight/age/activity, but occupation, daily routine, obligations (kids, commute, "tennis on Sundays"), medications affecting hunger/metabolism, and life stress. Makes the user **feel seen** ("what other app asks who I truly am?") *and* produces a starting calorie/protein/water/fiber target that's actually right.
3. **Mid-week, situational nudging** — proactive check-ins that arrive *during* the week, not an end-of-week report, adapting to context ("haven't logged today — rough day?"). Francesco rates this **highest**: *"That's the game changer, not the voice first."*

## Dashboard — what matters, nothing else

Default view shows only the pillars Francesco coaches to: **calories left · protein · fruits/vegetables · fiber · water.** Nothing else by default. (This is exactly the v2 dashboard redesign — validated by the source.)

**Anti-features (as load-bearing as the features):**
- **No unsolicited nutritional nagging.** No "high in saturated fat / too much sodium" pop-ups. The default dashboard is **silent on fats, carbs, sodium, sugar.**
- **Micro-tracking is opt-in.** A diabetic can add sugar, a hypertensive can add sodium — via an **edit screen** — but they're **off by default.**
- **No overwhelming surface.** No planning tabs, progress mazes, or a generic ChatGPT-with-emojis "coach" tab (MyFitnessPal's bloat is the failure mode to avoid).
- **MVP voice does not talk back.** The user is stating exactly what they ate, so logging settles on their end without the app speaking. (Voice replies are a later, opt-in layer.)
- **No generic AI slop.** When the AI does talk (later), it sounds like Serein / like Francesco — a guide, not a cheerleader.

## MVP scope (build this first)

- Voice-first logging (speak → transcript → parse → map → log, with a confirm/edit step).
- **Text logging fallback** (search a food library and pick — the MyFitnessPal way). Voice primary, text the safety net.
- Dead-simple dashboard (calories left + protein + produce/fiber/water).
- Onboarding that computes a real starting protocol so the dashboard is personalized from the first log.

**Deliberately NOT in MVP (later):** photo logging (Cal-AI-style with an AI confirm step), QR/barcode scanning, the conversational AI "guide," Carbon-style weekly check-in forms.

## Onboarding & the protocol engine

Francesco's coaching is **formulaic, not judgment-based** — *"I don't change calories based on what I feel. It's all calculated."* That's why it can be encoded. Real formulas arrive from his Notion (under NDA); the engine must be **formula-pluggable** so they drop in.

**Order:** (1) stats — height/weight/age/gender (sets the range); (2) goal — in practice almost always fat loss; (3) the deeper human intake (the differentiator) — occupation, routine, obligations, steps, medical history, hunger/metabolism meds, stress. **Infer activity level; never ask it** (everyone over-rates themselves — "I lift 3×/week" while sitting at a desk otherwise). Suss activity from occupation + routine.

**The calculation (mechanics Francesco gave; real tree pending):**
- Ideal body weight from gender/height/weight (rough; body composition refines).
- Fat loss target: **~24–29 calories per kg of ideal body weight.** Where in that band is **not** the user's choice — set by understanding the person (stress, training load, age, menopausal status, meds). High-stress single parent → lighter deficit; low appetite → more aggressive.
- Protein scales with body weight. Water ≈ half body weight in ounces. Fiber proportional to calorie intake. Produce = servings/day target.

**Monthly recalibration (later, design for it):** every month at minimum *pitch* an adjustment. Lost weight → recalibrate to adjusted ideal body weight (shifts calories/protein/water/fiber), often framed optional. No loss + claims did everything right → knock the cal/kg allocation down one point ("same thing, different result = insanity"). When a user asks "why haven't I lost weight?", surface honest diagnostics (how much did you actually move? how accurate was logging?) — the guiding-toward-truth interaction is candidate secret sauce.

## The AI "guide" (later)

Conversational AI — ChatGPT prompted to behave like Serein / like Francesco. It does **not** tell people what they want to hear; it **guides.** *"It's more of a guide than a coach."* (Methodology: the `guide` + `serein-voice` skills — propose don't impose, mirror, help the person see.) Encode Francesco's actual moves as a **bank of situational advice** (e.g. "can't track this week? repeat a day you tracked perfectly — zero friction, still tracking").

## Nudging (the highest-rated pillar)

Mid-week and situational, not end-of-week. Triggers: no log today → "rough day?" with a branch. Detect a stressful stretch *before* the week's midpoint so it doesn't run off the rails. Back nudges with the situational-advice bank. This productizes what Francesco already does manually with Claude (auto-generated personalized mid-week check-in texts off reflection forms). (Craft: the `nudge` skill.)

## Validation, metrics, GTM

- **Prove the concept before building everything.** Success metrics up front: are people logging **faster**? Are people who normally **wouldn't** log actually logging? Willingness to **pay** (cool-from-non-payers means nothing).
- **Shipping path is open:** TestFlight (App-Store-bound, more setup) **vs a web app** (vocal.com, sign in via browser) as the fast workaround to prove the concept. The call leaned web app. **(See OPEN DECISION below — this is the one big fork.)**
- **User research: ask about the past, never the hypothetical.** Not "would voice help?" but "on a week tracking was hard, what did you actually do?" Especially: interview disciplined people who do everything right *except* log.
- **GTM wedge = coaches.** Francesco's ~6 years of clients (warm email list, many already volunteered to beta) + a referral mechanic (free 3 months for referring 2 friends). If Vo-Cal is the best AI-leveraged nutrition app, coaches send clients to it instead of MyFitnessPal. Francesco sells in person at nutrition conferences. *"The quality and intention behind the work is the product."*

## Reference points
- **Serein** — the voice engine Vo-Cal is built on (the hard voice part is done).
- **MyFitnessPal** — the incumbent to beat by *subtraction* (expensive, paywalled barcode, bloated, generic "coach" tab).
- **Cal AI** — admired for simplicity; photo + AI confirm; **no voice** (the open lane). Photo fails on stir-fries/sandwiches/wraps where ingredients hide — another argument for voice.
- **Carbon** — reference for the (later) weekly check-in form.
- **Delphi** — clones a coach's voice/knowledge base; adjacent inspiration + a data-ownership caution.

## Open decisions still owed
1. **Platform: web-app MVP vs native iOS / TestFlight.** The single biggest fork — see the master plan amendment + `decisions.md`.
2. **Name: "Vocal" vs "Vo-Cal"** (the call says "Vocal").
3. Monetization model + price point; willingness-to-pay validation.
4. How much monthly-recalibration logic ships in MVP vs later.
5. Where the conversational "guide" sits relative to nudging on the roadmap.
