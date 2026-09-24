# The Rams audit of Vo-Cal, 2026-09-24

Mode: AUDIT, then DIETERIFY on the findings the owner's earlier decisions allow. Quotations
marked (W01), (W02), (T01), (T02) or (I06) are Dieter Rams verbatim from the sources the
protocol carries; everything else is applied reading. No em dashes.

## Intake

- Purpose sentence: a person says what they ate and trusts the number that comes back.
- The person: the concierge beta's few testers and the owner; imagined more than met, so
  findings about need rank below findings about internal consistency.
- The room: a phone in a hand between meals, with every other app's notifications already
  spent; the mic is the only thing Vo-Cal asks the person to reach for.
- The system: the capture ladder (docs/VOICE_CAPTURE.md), the parser contract, the Today
  surface, Settings; the API and its database behind them.
- The frame of the feasible: the shipped app decodes the contract as of build 27 (additive
  fields only); migrations run only through the deploy; no photo, no gamification, no
  text-search logging by decision (MASTER-PLAN).
- Artifacts seen: the mock-backed app on the pinned simulator, 2026-09-23 and 24: Today
  (top and scrolled), the voice sheet's result, an item's edit sheet, Settings; then the
  same after the changes, with the recipe sheet and the label door. The onboarding
  interstitials were read in code, not run.
- Lifespan: years; the durable layer is the capture and the person's own records.

## What holds

- The claim ladder's words read from the one state that licenses them, and a rule keeps
  them out of every other file (TIDY-CLAIM-001). "this design should not gives the people
  more as the product really can do then it is not honest" (T02).
- The calorie card says "~480" for a rough estimate and "430+" while a check is open:
  precision the data supports, never more.
- The bottom bar is a butler: one mic, two quiet tabs, nothing badged, nothing counting.
  "they have to stay in the background when we don't need it and have to be there when we
  need it" (T02).
- The empty and edge states are decided: no meals yet, nothing deleted, nothing learned,
  an unfinished recording, a failed load with a way back. "Nothing must be arbitrary or
  left to chance." (I06)
- The person's own material is the loudest thing on Today: the day's numbers and their
  meals; the brand mark is a word in a tab.

## Findings, structural first

[F1] CUT, structural, fixed in 7097af1. Two onboarding lines cited a survey that does not
exist ("86% of users say the change is obvious", a counted-up "86% of Vo-Cal users
maintain their weight loss even 6 months later"). "It does not attempt to manipulate the
consumer with promises that cannot be kept." (I06) Fabricated authority is the one failure
the protocol calls non-negotiable. The lines now say what the method is; the curves stay.

[F2] REVISE, structural, fixed in f62ba45 and a144b74. A food no database has (a meal-prep
container, a batch of chili) had no honest door: the estimator guessed and the guess sat in
the meal as an item; the only manual path came after logging. Now the person states the
truth once, from the label or as a recipe, and the product uses their numbers by name from
then on, before every database. "Human needs are more diverse than many designers are
sometimes ready to admit" (I06); the function that was missing was the person's own
authority over their own food.

[F3] REVISE, material, fixed in 29d26db. "keeps your streak honest" and "Streaks survive on
easy days" put a consumption mechanic in the person's slot, against the no-gamification
decision. "We make the effort to produce products like this for the intelligent and
responsible users – not consumers" (W01).

[F4] REVISE, material, fixed in a144b74. "Priced as apple" is the engine's register in the
person's slot (the cardinal sin passage, I06). It reads "Counted as apple"; a personal
food reads "One of your foods".

[F5] REVISE, material, fixed in a144b74. "Enhancing log" named an animation, not the work.
It reads "Working out the numbers", which is what happens.

[F6] OPEN, material. Today's "avg 95% sure" badge is a statistic of the system's own
confidence in the person's day, in an abbreviation. The owner chose its dress in August;
the choice to keep it is the owner's. Recommendation: cut it from Today and leave the
per-meal confidence on the meal screen, where a person acts on it.

[F7] OPEN, fine. "Tap a flagged item to add a detail and reach 100%" frames certainty as a
score to chase. It is the certainty layer's design. Recommendation: "Add a detail and the
estimate sharpens", which names the outcome rather than the score.

[F8] OPEN, structural, not built. The nutritionist's photo as a side piece. The decision
that photos do not price a meal stands ("Photos guess. Voice knows."). If a photo ever
enters, the only honest form is an attachment the person can look at later and the parser
never reads; anything else reintroduces guessing under a voice-first claim.

## Diagnosis

Every failure has one shape: the product saying more than it knew (a survey it never ran, an
"enhancing" it was not doing, a guessed food presented as the person's item) or speaking in
its own register (priced, avg, streak). The move was the same each time: say what is true in
the person's words, and give the person the door to state the truth themselves (the label,
the recipe, the rename). That door is the whole of the new feature.

## The short list

1. Decide F6 (the Today badge).
2. Decide F7 (the "100%" wording).
3. Decide F8 (photo as an attachment, or not at all).
4. The Fly organizations (questions ledger 6) are still open.

## The DIETERIFY passes run

Purpose restated (above). Element inventory over the strings a person reads (185 literals,
each with a job). Strike list: the two statistics, the count-up view, three consumption
words, two register words. Register pass: F3, F4, F5. Claim audit: F1, F5. Order pass: the
new sheets teach by arrangement (name, then numbers, then the emphasized "Servings I had");
copy carries nothing the fields do not. Room test: the recipe door is a tertiary line under
the items, the label door lives inside the edit sheet; neither speaks first. State
enumeration for the new surfaces: empty My foods, a failed load, a failed save, a name
already saved (the server versions it), a batch that prices to zero (refused), the longest
name (wraps), reduced motion (no count-up remains). Joint pass: the number of servings and
the serving weight are visible in My foods; the arithmetic is named in the sheet. Year five:
foods are versioned and retirable; the identity a meal was priced with survives the food's
retirement. Restoration check: the count-up was a flourish on an invented number, not
warmth; the curves that carried the feeling stay. The changes made the product quieter and
truer, not only quieter.

Evidence: the mock-backed app on the pinned simulator before and after, 2026-09-23 and 24;
the twelve voice scenarios and the ladder on the branch head.

## The ship gate

Purpose served. Honesty: no known gap after F1 to F5. Butler: waits. Order: the structure
teaches on Today, the result and both new sheets. Register: F6 open, the rest clean.
Detail: decided. Year five: yes. Resources: nothing added that nobody needs. Subtraction:
F6 and F7 are what could still come out, and they are the owner's. Restoration: nothing
warm was removed.

"Have I succeeded in improving things? Making them better than others did? Is my design
good design?" (I06)
