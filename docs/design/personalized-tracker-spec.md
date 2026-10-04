# The personalized tracker, designed under the Rams audit (REVIEW, then DIETERIFY)

Date: 2026-10-04. Mode: **REVIEW** of the proposal in `.claude/plans/phase-p-personalized-tracker.md`,
then **DIETERIFY** applied to the proposal itself, in the protocol's order, one pass at a time. The
protocol is Lorenzo's "Dieter Rams" document (the operational half of the Rams brain, built
2026-09-23); the earlier run of it on the shipped app is `docs/restructure/06-rams-audit.md`.
Quotation marks plus a tag mean Rams verbatim (T = transcript, kept as captioned; W = Vitsoe's
published English; I06 = print, footnoted to the archive). Everything unmarked is applied
reading, and is inference. No em dashes.

Nothing here is built. Section 1 is what the builder must have before judging; Section 2 is the
necessity gate that runs first in REVIEW; Section 3 says what holds in the proposal; Section 4 is
the findings against it, structural first, with the move for each; Section 5 is the diagnosis;
Section 6 is the corrected design, screen by screen, with each element's job, its copy and its
states; Section 7 is the ship gate pre-filled for whoever builds it.

---

## 1. Intake

**1.1 The purpose sentence.** A person follows their nutrition the way they decided to, and the app
shows them only that, truthfully, from what they log.

(The plan's purpose line was "make how a person wants to follow their nutrition the first thing
the app learns". That is the maker's sentence. The one above is the person's. Every finding below
is judged against the person's.)

**1.2 The person.** Imagined more than met. Lorenzo's sales calls supply the sentences people
actually say ("I wanted a meal plan", "I just want to look at calories", "do I have to track? I
just want to build healthier habits") and his own week on MyFitnessPal supplies the behaviour
(after the first week of staples, logging is a tap on Recent). Francesco's clients are the warm
list. No one has used a mode. Per the protocol's fallback, findings about need rank below
findings about internal consistency, and the one thing REVIEW can insist on is the smallest real
version (6.9: "we need decision only only by models uh you can't get decision uh for to go
process only by discussions you need the models", T02).

**1.3 The room.** A phone in a hand between meals; every other app's notification budget already
spent; a kitchen, a desk, a restaurant table; sometimes a coach's text thread. The app is closed
by default, so the platform supplies the butler's corridor; the nudges are the one place the app
speaks first and they are the room test's whole subject.

**1.4 The system.** The capture ladder (`docs/VOICE_CAPTURE.md`, the one bar), the parse ladder
and its checks, named meals and recognition, usuals, personal foods, the week budget, the
protocol engine (the PRO IP v2.0, deterministic) and the nudge plan. The rail the new piece hangs
on is the person's own record: their logs, their names, their protocol. The new piece is a
preference and three projections of it.

**1.5 The frame of the feasible.** One developer; Swift 6 and FastAPI; shipped builds (31) that
decode today's wire shapes and must keep decoding them (the additive-field rule); the IP's
formulas are not ours to change; the capture core is not touched; migrations run only through
the deploy; no coach lane exists yet; Haiku prices the parse in about 1.4 s.

**1.6 The artifacts.** The plan (a document), the shipped app on the pinned simulator as of build
31 (Today, the intake, the reveal, Settings), the engine and the dashboard code, the nudge
catalogs. No mode has been drawn. Where a verdict below needs a drawn thing, it says OPEN and
names the model to build.

**1.7 The lifespan.** Years. A person's preference history is part of their record and must
outlive any one dashboard layout.

**1.8 Provenance.** The five-panel dashboard was decided (decision 28, Francesco's pillars). The
single intake shape was decided (decisions 35, 36). The absence of a preference was not decided;
it was never asked (findings ledger 56). Inherited failures get a different move from decided
ones: the pillars stay as a mode, the missing question is added.

---

## 2. The necessity gate (the fifteen questions, decisive ones for consumer software)

Run before anything in Section 4, because a thing that should not exist cannot be improved into
existing correctly.

**Q2.** "Is the product that we are designing really necessary? Are there not already other,
similar, tried and tested appliances that people have got used to and are good and functional?
Is innovation in this instance really necessary?" (I06, q2)

The incumbents, by name: MyFitnessPal, Lose It, Cal AI, Apple Health, a notebook, a coach's
text thread. Every one prescribes one dashboard and leaves the person to ignore the rest of it.
None asks how the person wants to follow their nutrition and then shows only that. The innovation
is not the voice, not the photo, not the parser; those exist elsewhere. It is the question and
the obedience to its answer. That is a real capability, not a surface: the server composes a
different Today from the same protocol. **Passes**, on that capability alone. If the question is
asked and the answer is not obeyed everywhere (the reveal, the rows, the result, the nudges), it
fails Q2 and principle six together.

**Q3.** Enrichment, covetousness, or something new. The pitch leans on enrichment: the person who
never wanted a calorie count gets a tracker without one. The risk sits in the ladder: named
levels, badges, "you've unlocked macros" would turn a step into status. **Passes if the ladder
has no names, no ranks and no celebration** (see finding R6).

**Q5.** "Can it be simply repaired or does it rely on an expensive customer service facility?"
(I06, q5). If the parse fails, the audio survives and the record is repaired later (the capture
ladder already guarantees this). If the composer fails, Today falls back to the seven fields a
build-31 client decodes. If the vendor fails, the person's record is on the vendor's rail: there
is no export. **OPEN**, named in R11; not a reason to stop, a reason to put export on the plan.

**Q7.** "Does it help people or incapacitate them? Does it make them more free or more dependent?"
(I06, q7). A habits mode that shows no number makes a person more free than a dashboard that
shows five. An invitation that fires on a fact the person can check ("you logged 14 of the last
21 days") does not make them dependent; an invitation that fires on the maker's wish does.
**Passes under R6's conditions.**

**Q9.** "Which previous human activity does it replace and can that really be called progress?"
(I06, q9). It replaces the notebook and the incumbents' fixed dashboard. What those did besides
their obvious job: MyFitnessPal's Recent taught people their own staples. Usuals, recognition and
search over the person's history already carry that function here, and the design below makes
them the first thing a person sees in every mode. **Passes.**

**Q12.** "Does the product really offer convenience or does it encourage passivity?" (I06, q12).
Hiding calories from a person who did not ask for them is not passivity; the effort of logging
is unchanged in every mode and is the point. Skipping the checks in habits mode (R3) removes
effort that served the maker's data, not the person. **Passes.**

**Q14.** "Does it make an action or activity on the whole more complicated or simpler, is it
easy to operate or do you have to learn how to use it?" (I06, q14). One question at the start
replaces a lifetime of "edit metrics" settings. On the whole, simpler. **Passes.**

**Q15.** "Does it arouse curiosity and the imagination? Does it encourage desire to use it,
understand it and even to change it?" (I06, q15). The invitation ("Want to see your calories?")
is the one place the design arouses curiosity on purpose, and it is the person's to accept. The
protocol one layer down (Settings → My protocol, always the whole thing) is where understanding
lives. **Passes.**

The gate passes. The thing should exist. Now the findings against how the plan proposed it.

---

## 3. What holds in the proposal

- **One engine, every mode.** The protocol is computed in full for everyone and the mode decides
  what is shown. One truth, one layer down. Principle six ("this design should not gives the
  people more as the product really can do then it is not honest", T02) and 6.6: hiding a number
  the person did not ask for is kindness, as long as the number is reachable.
- **The server composes Today.** The rail (the person's record and choice) and the brackets (the
  panels) are separate objects. A new mode is a new bracket. Principle seven, and 6.5: "die
  Systemmöbel sind ja meistens so dass sie auch von den Leuten selbst zusammengestellt werden
  können dass sie ihre eigenen Architekten werden" (T03). *Working translation: furniture systems
  are usually such that people can assemble them themselves, so that they become their own
  architects.*
- **Voice stays the one way in** (plan decision D4, option a). A second input surface for habits
  would be D1 in the failure taxonomy, a shared slot growing a second mode. Protect this from the
  first request for a "quick check-off".
- **The preference is history**, append-only, with its source. The graduation record is the
  person's and the beta's. Principle eight.
- **The choice is asked, never preselected** (plan decision D8). The sex-default bug of 2026-07
  is the evidence that a silent default is a wrong answer for half the people.
- **The deep intake stays** for the modes that prescribe a number. Its function is partly
  psychological (Francesco: the person feels seen) and the protocol forbids striking an element
  for that reason: "Human needs are more diverse than many designers are sometimes ready to admit
  or, perhaps, capable of knowing." (I06)

---

## 4. Findings against the proposal, structural first

### [R1] CUT · structural · Six modes are the coach's ladder, not the person's sentences

WHAT IT IS. The plan's mode set: habits, calories, calories + protein, the method, macros, meal
plan. "Calories + protein" is a step a coach would prescribe between two things a person said.

WHAT HE SAYS. "Indifference towards people and the reality in which they live is actually the one
and only cardinal sin in design." (I06, archive 1.1.3.1)

WHAT FOLLOWS (inference). The chooser is a slot the person owns (6.11): its options must be
sentences the person would say. Lorenzo's calls supply five: habits, calories, the method's five,
macros, a meal plan. Nobody on a call said "calories and protein". A sixth option that is the
maker's intermediate step makes the person read the maker's curriculum to find themselves in it,
and it is also the taxonomy's accretion (D1 in the failure family: a chip that is really a rung).

THE MOVE. Five modes. "Calories and protein" becomes the first invitation offered in calories
mode (R6), which is where a coach's step belongs: offered when the signal says the person is
ready, not listed as a choice on day one. Preserve: the step itself. It is Francesco's judgment
and it is right; it is just not a door.

### [R2] CUT · structural · "Why are you here?" is a twin of "Your goal"

WHAT IT IS. The plan adds a first question, "Why are you here?" (lose fat / build / maintain /
eat better / a coach sent me), before the existing "Your goal" (cut / maintain / gain).

WHAT HE SAYS. "what I'm fight always during my life is come back to the simple things yeah we
don't need all unnecessary things" (T02)

WHAT FOLLOWS. Two questions whose answers overlap three ways (D3, twins). "Eat better" is the
habits mode, which the mode question already captures; "a coach sent me" is a coach lane that
does not exist yet, so the option would be an orphan control (A4). The one new question the
design needs is the mode.

THE MOVE. Cut it. The intake gains exactly one question, first: how do you want to follow your
nutrition. "Your goal" stays where it is, for the modes that prescribe a number.

### [R3] REVISE · structural · In habits mode the checks serve the training data, not the person

WHAT IT IS. The plan leaves the parse ladder unchanged in every mode, so a person who chose "no
numbers" is still asked the fat ratio of their beef and the kind of mayo, because those checks
move a calorie count they will never see.

WHAT HE SAYS. "Does the product really offer convenience or does it encourage passivity?"
(I06, q12)

WHAT FOLLOWS. The check's job is to make a shown number right. With no number shown, the check's
only remaining job is the maker's corpus (D4, the stakeholder element, and here the stakeholder is
us). Effort by design is the thesis only where the effort buys the person something.

THE MOVE. In habits mode `clarify` is skipped and the parse prices with typical values, stored as
such (`is_estimate` already exists). When the person later moves to a numeric mode the reveal
says once, in one line, "Your past meals were estimated. From today each one is checked." Preserve
the capture, the transcript, the parse and the items: the record stays whole; only the questions
go.

### [R4] REVISE · material · "The world's first personalized food tracker" is a claim the person cannot check

WHAT IT IS. The plan's proposed headline for the welcome screen, the README and the landing page.

WHAT HE SAYS. "It does not make a product more innovative, powerful or valuable than it really
is. It does not attempt to manipulate the consumer with promises that cannot be kept." (I06,
archive text)

WHAT FOLLOWS. "Personalized" is true here and checkable: the person chose, and the screen obeys.
"World's first" is a superlative no person can verify from inside the app (principle six's last
failure signature). It belongs to a sales conversation, where it can be defended, not to a slot
the person reads alone. The protocol also names "personalised" over a lookup as the endemic
overpromise (A2); the defence is that the personalization here is a stored choice and a composed
screen, not an adjective. The copy must therefore say what happens, not what we are.

THE MOVE. The welcome states the capability in the person's register. Three candidates, in order
of preference; D1 picks the name, this picks the sentence:
1. "Follow your nutrition your way." / "Habits, calories, the method, or macros. You choose; the app shows only that."
2. "Track what matters to you. Nothing else."
3. "Your nutrition, followed the way you want."
Keep "world's first" for the pitch, the deck and the conference floor.

### [R5] REVISE · material · A mode named after the brand is a string that will be wrong next quarter

WHAT IT IS. The plan labels the pillars mode "the Vo-Cal method" (and the voice note calls it the
Frankie Pro method), while D1 has the name itself under decision.

WHAT HE SAYS. "It avoids being fashionable and therefore never appears antiquated." (I06,
archive text)

WHAT FOLLOWS. Principle seven's failure signature: a name that will be wrong next quarter. A
control's label should state its contents so it survives a rename, a rebrand and a coach lane
where the method has another coach's name.

THE MOVE. The option is labelled by what it tracks: "Calories, protein, produce, fiber, water",
with the support line "The five things the method tracks." The method's name, when D1 settles it,
appears once, in Settings → My protocol, where a name can be changed in one place.

### [R6] REVISE · material · The invitations must satisfy the three conditions for a proactive guest

WHAT IT IS. The plan's ladder: the engine offers "Want to see your calories?" after 14 of 21 days
logged, and the step down when logging thins, as nudge cards.

WHAT HE SAYS. "they have to stay in the background when we don't need it and have to be there
when we need it" (T02)

WHAT FOLLOWS. The protocol's rule for anything that speaks first (B2): it must be rare,
dismissible permanently, and correct. The plan had rare (a 14-day cooldown) and correct (a fact
the person can check), but "Not now" is a snooze, not a dismissal, and a snooze that returns is
the unclosable (B5). And an invitation shares a day's budget with the other nudges or it becomes
the second voice in the room.

THE MOVE. Each invitation carries three answers: "Yes", "Not now", "Don't offer this again". The
third is a durable write (a preference version with `source=declined`), never a timer. One
invitation per direction per 14 days; never on a day another nudge fired; never with a rank, a
level name or a celebration (Q3). The copy names the fact and the offer, nothing else: "You've
logged 14 of the last 21 days. Want to see your calories too?" Preserve: the step down. It is the
kinder of the two and the one the incumbents never make.

### [R7] REVISE · material · Macros as rings reintroduces a second progress language

WHAT IT IS. `docs/DESIGN.md` still lists `MacroRing` and the plan's macros mode proposes three
rings; Phase U set one progress style on Today (a bar under a header) and removed the badges.

WHAT HE SAYS. "The order of the elements – their arrangement, their shape, their size and their
colour – is based on a thoroughly-planned system." (W01)

WHAT FOLLOWS. Two progress languages on one screen is order encoded by only one channel, which
6.4 calls fragile. The semantic macro colours (protein red, carbs amber, fats blue) already carry
the difference; the shape need not.

THE MOVE. Macros mode shows protein, carbs and fat as the same tile the method mode uses for
produce, water and fiber, with the macro colour on the bar. `MacroRing` leaves the component
inventory. Preserve the colours; they are frozen and they are the meaning.

### [R8] REVISE · fine · Rows and the result must obey the mode too

WHAT IT IS. "Logged today" rows show calories at the trailing edge; the result screen shows
"Calories so far" and per-item macros. The plan changes the cards and leaves these.

WHAT HE SAYS. "Nothing must be arbitrary or left to chance." (I06, archive text)

WHAT FOLLOWS. The main-path bias (F4): right on the dashboard, wrong one step off it. A habits
person who sees no calories on Today and 547 on the result has been shown the number they
declined.

THE MOVE. The mode governs every surface that prints a number: rows (habits: name, slot and time,
no trailing number), the result (habits: the items and their amounts under "Here's what I heard",
no calories, no macros), usuals chips (habits: the name only), the week card (habits: hidden; the
week strip's dots are the habit's own record), the meal edit sheet (habits: amounts editable,
macros hidden behind one disclosure "Show the numbers"). Decide each; the table in 6.4 does.

### [R9] REVISE · fine · The habits mode needs its habits decided, not described

WHAT IT IS. The plan says "habit checklist (items derived from the logs)". Which items is left to
the implementer.

WHAT HE SAYS. "Care and accuracy in the design process show respect towards the consumer." (I06,
archive text)

THE MOVE. Three, decided here, all derivable from what the person already logs so no second input
surface exists: **Logged today** (a day with at least one log), **Water** (the protocol's ounces,
the one tile with a plus, as today), **Produce** (the protocol's servings). Fiber is a number
nobody feels and stays in the method mode. "Meals logged of planned" is the meal-plan mode's
job, not a habit.

### [R10] HOLDS · The composer and the additive wire

The seven fields stay for build 31; `panels` ride beside them; a client skips a kind it does not
know. Principle seven: the perishable (a layout) is separable from the durable (the record).
Protect it from the first request to "just add a field to DayTotals".

### [R11] OPEN · The person's record on the vendor's rail

Q5 and G2: there is no export. A person who leaves cannot take their meals, names and protocol.
This is not the plan's to solve, and it is the plan's to name: one task, "Export my record"
(JSON and CSV, from Settings), before the first paying user. What would resolve it: the task on
the plan with an owner.

### [R12] OPEN · The reveal in habits mode cannot be judged from the document

What a person who chose "no numbers" should be shown as their plan (three habits with two counts,
or three habits with none) is a decision only a drawn screen settles. The move, per 6.9: build the
habits reveal as a mock-backed render before deciding; the two variants cost an hour each.

---

## 5. Diagnosis

Every finding against the plan has one shape: **the maker's taxonomy in the person's slot.** Six
modes from a coach's ladder (R1), a duplicate question from a funnel's vocabulary (R2), checks
that serve the corpus (R3), a superlative the person cannot verify (R4), a brand where contents
belong (R5), a snooze dressed as a choice (R6), a second shape for the same meaning (R7), the
number declined on one screen printed on the next (R8). The move each time was the same: put the
person's sentence where the maker's category was, and let the one truth sit one layer down. The
plan's architecture was right (R10). Its surface had not yet been asked who it was for.

**The short list, in order.**
1. Five modes, labelled by what they track; the coach's step becomes the first invitation (R1, R5, R6).
2. One new question, first; nothing preselected; no "why are you here" (R2).
3. The mode governs every printed number: cards, rows, result, chips, week, edit sheet; and in habits mode the checks do not fire (R3, R8).
4. Build the habits reveal both ways before deciding it (R12); put export on the plan (R11).

---

## 6. The design, corrected (DIETERIFY passes applied to the proposal)

Each pass was run once, in the protocol's order; what each changed is noted where it changed
something. Tokens, radii, type and spacing are `docs/DESIGN.md`'s and are not restated.

### 6.1 Restated purpose

A person follows their nutrition the way they decided to, and the app shows them only that,
truthfully, from what they log.

### 6.2 The modes (the element inventory of the one new control)

Five options, one line of title and one of support each, words only (a glyph per option would be
C2, the undefined glyph), nothing preselected, in this order (the order is the ladder without
saying so: least to most asked of the person):

| Title (the person's sentence) | Support line | Job |
|---|---|---|
| Build better habits | Log each day, drink your water, eat your vegetables. No numbers. | The door for the person who asked "do I have to track?" |
| Watch my calories | One number a day, and what is left of it. | The door for "I just want to look at calories" |
| Calories, protein, produce, fiber, water | The five things the method tracks. | Today's dashboard, as a choice instead of a default |
| Track my macros | Calories, protein, carbs and fat. | The door for the person who already knows their numbers |
| Follow a meal plan | Meals you plan, checked off as you log them. | Offered since the builder shipped (2026-10-04, 6.12); before that it was absent, because an option that does nothing is A4 |

Removed by the strike list: the sixth mode (R1), the "why" question (R2), the brand in a label
(R5). Kept after the removal test: the support lines, because the titles alone do not tell a
stranger that "the method" has five parts or that "habits" has no numbers (the order pass found
the structure cannot carry that difference without the one line).

### 6.3 The intake, per mode

The question is asked first, after the welcome. What follows depends on the answer. The basics
(sex, age, height, weight) are asked in every mode because water scales with weight and the
engine needs them for the protocol that is computed regardless; the deep questions are asked
where they change a number the person will see or a nudge they will get.

| Step | Habits | Calories | The five | Macros | Meal plan |
|---|---|---|---|---|---|
| How do you want to follow your nutrition? | asked first | asked first | asked first | asked first | asked first |
| The basics | yes | yes | yes | yes | yes |
| Desired weight (ruler) | no | yes | yes | yes | yes |
| Your goal | no (nothing is prescribed) | yes | yes | yes | yes |
| Realistic pace (benefit) | no | yes | yes | yes | yes |
| Your real life (work, kids) | yes (nudges read it) | yes | yes | yes | yes |
| Training | yes | yes | yes | yes | yes |
| Momentum (benefit) | no | yes | yes | yes | yes |
| Hunger (medication) | no (only moves the deficit) | yes | yes | yes | yes |
| Life right now (stress) | yes (the gentler nudging) | yes | yes | yes | yes |
| Your day (meals) | yes | yes | yes | yes | yes, and it sizes the plan |
| Long-term results (benefit) | no | yes | yes | yes | yes |
| Build my protocol → the reveal | "Set up my habits" | yes | yes | yes | then the plan builder |

The disclaimer stays on the first step in every mode (App Review posture, unchanged).

### 6.4 Today, per mode (the panels the server composes)

One progress style (a `CardHeader` over a bar), one fill, completion as the green tick and
hairline, exactly as Phase U set it. The header, the week strip, the profile circle, usuals, the
logged rows, the unfinished rows and the capture bar are present in every mode; what changes is
the cards between the strip and the usuals, and which numbers are printed.

| Surface | Habits | Calories | The five | Macros |
|---|---|---|---|---|
| Hero card | none (the three tiles are the page) | Calories left (gold numeral, "of 1,805 today") | Calories left and Protein, twins | Calories left (full width) |
| Tiles | Logged today · Water (+) · Produce | none | Produce · Water (+) · Fiber | Protein · Carbs · Fat, macro colours on the bars |
| Week card | hidden; the strip's dots are the record | shown | shown | shown |
| Nudge card (only when nothing is logged) | shown | shown | shown | shown |
| Usual chips | name only | name · kcal | name · kcal | name · kcal |
| Logged rows, trailing | nothing (slot · time only) | kcal | kcal | kcal |
| Health "burned today" line | hidden | shown when connected | shown when connected | shown when connected |

Focus metrics (decision 30, realized): a person adds a tile from Settings → How I track; the list
offers only what the mode does not already show (fiber, water, produce, carbs, fat, and sugar and
sodium once the nutrient model carries them). A tile added is a tile in the same row style; the
row wraps to a second row at four or more. In habits mode a focus metric is allowed (a diabetic
who wants sugar and nothing else is exactly the person this mode is for) and it is the one number
the page then prints.

The joint pass: every mode's Settings → My protocol shows the whole protocol, mode items first,
the rest under one disclosure, "Everything else the engine computed". The number the person did
not ask for is one tap away and labelled as the engine's (the register pass: maker's output,
marked as the maker's, one layer down).

### 6.5 The result screen, per mode

| Element | Habits | Numeric modes |
|---|---|---|
| Header | the meal's name, the confidence badge | the meal's name, "N checks left", the badge |
| Recognized-usual card | as today | as today |
| Calories card | none | as today |
| Item cards | name, amount, state ("113 g · cooked"); no kcal, no macros | as today |
| Checks | do not fire (R3); typical values priced and stored as estimates | as today |
| Pinned bar | "Log it" | "Log meal" / "Log anyway (typical values)" |

The claim audit closed one gap here: the habits-mode header may not say "N checks left" when no
checks will be asked.

### 6.6 The reveal, per mode

Numeric modes: as today (the calorie hero, the mode's rows with their whys, the "built from what
you told us" chips, the disclaimer). Macros adds carbs and fat rows with the engine's existing
whys. Habits: OPEN (R12). Both variants to draw: (a) "Your three habits" with Water "96 oz" and
Produce "6 a day" as counts, Logged today with none; (b) the three habits with no counts and the
counts first seen on Today. The render loop decides, with a reader who did not build it.

### 6.7 The nudges, per mode

One engine (plan task P5). Each nudge names the modes it may fire in. The habit nudges fire
everywhere; a nudge may never name a number the person's mode does not print.

| Nudge | Habits | Calories | The five | Macros |
|---|---|---|---|---|
| Gone quiet, nothing logged today | yes | yes | yes | yes |
| Hydration, produce behind | yes | no | yes | yes |
| Mid-week slipping, stress slipping (ported from the legacy bank) | yes, in habit words | yes | yes | yes |
| Treat headroom, evening on track, under target | no | yes | yes | yes |
| Protein gap | no | no | yes | yes |
| Fiber | no | no | yes | no |
| Invitations (R6) | up: calories | up: protein as a focus; down: habits | down: calories | down: the five |

The room test, against the real room: the plan's budget stays (two a day, one at the essential
level, three a week), quiet hours stay, and an invitation counts against the budget like any
other card.

### 6.8 Settings → How I track

One page, reached from the Coaching card. The mode list is the same component as the intake's
chooser (not a twin; literally the same view), with the current mode ticked. Below it, "Also
show", the focus metrics the mode does not already print, as rows with a tick, and a one-line
footer: "Changing this changes what Today shows. Your record is unchanged." Changing the mode
appends a preference version (`source=chosen`) and reloads Today. Nothing else on the page.

### 6.9 The states, enumerated and decided

- **Empty day**: every mode shows the usual chips first and the tip card; habits shows the three
  tiles at zero with no red (a zero at breakfast is a day not yet lived).
- **First run**: the tour's six steps stay; the calories step is skipped in habits mode (there is
  no calories card to point at) and the week step points at the strip's dots instead of the
  budget card.
- **Error loading Today**: as today ("Couldn't load today." with a retry); the mode is not needed
  to show it.
- **Offline**: the capture bar works (capture-path isolation); Today shows the last loaded
  dashboard; a mode change made offline is queued like a rename, with the footer saying so.
- **No protocol yet** (stub): habits shows its tiles with the stub's water and produce counts and
  the starter banner; numeric modes show the starter banner as today; no nudge names a number
  (the fix of 2026-10-04 already guarantees this).
- **Longest string**: a usual named with 60 characters wraps to two lines in a chip in every
  mode; the mode titles are fixed and fit at the largest Dynamic Type the audit ratchets.
- **Mode changed mid-day**: the new panels compose from the same logs; nothing is re-priced;
  past days render in the mode they are viewed in, not the mode they were logged in (one rule,
  stated in Settings' footer).
- **An invitation declined forever**: never shown again for that direction; visible in Settings
  under "Also show" as a row the person can turn back on.
- **Meal plan mode before P8 shipped**: the option was absent, not disabled. Since 2026-10-04 it is offered; its own states are in 6.12.

### 6.10 The restoration check (written, as the protocol requires)

Did the passes remove any psychological, aesthetic or emotional function without replacing it?
The "why are you here" question carried a function the plan intended (the person feels asked);
the mode question carries it better, because it is the question the person came with. The checks
in habits mode carried the thesis's feeling of rigor; in that mode the rigor was ours, not
theirs, and the capture's completeness is preserved. The rings carried colour; the colour stays
on the bars. The superlative carried pride; it moves to the pitch, where it can be argued. Did
the design get quieter and better, or only quieter? Better: a person who asked for no numbers gets
none anywhere, and a person who asked for macros gets them in the one language the page speaks.
Nothing warm came out that did not go back in another place.

### 6.11 Evidence

None yet. Before and after, at real size, in the real room: the render loop's goldens per mode
(six Todays, five reveals, two results), the simulator at the pinned device, and one week of
Lorenzo's own logging in habits mode, which is the one mode he has not lived in. No claim of
improvement without them.

### 6.12 The meal plan (decision 65, built 2026-10-04)

The person writes the plan; the engine checks it; nobody generates a diet (D5 a). The builder
is one view in three places: the step after the reveal in meal-plan mode, Settings → My meal
plan (only in that mode), and a sheet from the plan card on Today.

**The builder.** One card of rows, one per slot, as many as the meals the person said they eat
(6.3: "Your day" sizes the plan). A filled row is the meal's name with the server's calories
trailing; an empty row says "Choose a meal"; "Add a meal" at the foot, to eight. A row opens the
picker: the usuals (name · kcal), or a meal typed the way the person would say it and parsed by
the server, the same parse a typed log takes; "Remove this meal" on a filled slot. Nothing is
preselected. Under the card: before a save, the planned calories (the server's totals added up,
never a food priced on the phone); after a save, the engine's one line as given. "Save plan" is
the one primary action; in onboarding it becomes "Continue" once saved, and "Not now" leaves the
plan unwritten (the card says "No plan yet"; never a default plan written for the person).

**The check's line** (`check_plan`, deterministic): "On your protocol: 1,790 of 1,805 calories,
protein covered." when the calories are within ten percent of the target and protein reaches
the band's floor; otherwise the facts, joined: "605 calories under your protocol; protein 31 g
under the band." It is set in the completion green when the plan lands and in ink otherwise,
never the alert red: a plan off the protocol is a fact about the plan, not a fault in the person.

**The card on Today** (`meal_plan_slots`, full width, first; the calories card beneath). One
row per planned meal with the server's tick and calories; the header's line "3 of 4 meals"; the
day's meals that filled no slot named under the rows as "Also today: Protein shake & a banana",
stated and not judged. A slot ticks by name, once, in the order the meals were logged: the
recognized usual, the re-logged chip and a typed meal all log under the name the slot carries,
because a typed slot is named by the server exactly as a typed log is. With no plan the card
says "No plan yet" and what the tap leads to; it never shows an empty list as a plan.

**The states.** No plan yet (the card says so; Settings' row and the step offer the builder). A
plan with every slot ticked (the header's tick and hairline, as every other completed card). A
day that strays (the open slot stays open, the extra is named, nothing turns red; the evening
nudge, `plan_slot_open`, says the plan is there tomorrow too, only in this mode and only on a
day with something logged). A usual deleted since the plan was saved (the save says which meal
to choose again, 404 as a sentence). No protocol to check against (the line is "Saved."; the
onboarding path always has one).

**The claim audit.** The tick is the server's match, never the client's guess; the calories on
the rows are the server's totals; the check line is the engine's sentence verbatim; the builder
shows the echo after a save, not the tap. "Planned" before a save is arithmetic on the server's
numbers and says so by its word.

**The restoration check.** The builder took nothing warm out: the "Also today" line keeps the
person's whole day visible under the plan, so a plan is a shape for the day and not a scorecard
of it (the nudge's words). What can still come out: the planned-calories line, if the rows'
numbers teach the sum on their own.

---

## 7. The ship gate, pre-filled for the builder

1. **Purpose.** A person follows their nutrition the way they decided to, and the app shows only that. Serve it or do not ship.
2. **Honesty.** Every printed number against every mode. The habits result may not say "checks left". The welcome may not say "first".
3. **Butler.** Invitations within the nudge budget, rare, dismissible for good, correct.
4. **Order.** Strip the support lines from the chooser: do the five titles alone teach the difference? (Expected no; the lines stay. Re-check after a week of real use.)
5. **Register.** No engine vocabulary in a slot the person owns: "estimated", not `is_estimate`; "the five things the method tracks", not a brand.
6. **Detail.** The states of 6.9, each drawn.
7. **Year five.** Export (R11). A coach-authored plan (`author` on the plan). A sixth mode without a client build (a new panel kind).
8. **Resources.** Nothing added that nobody needs: no icons on the chooser, no level names, no celebration.
9. **Subtraction.** What can still come out: the "Also show" footer if the behaviour proves obvious; the second line under each mode if the titles teach alone.
10. **Restoration.** Section 6.10, re-read after the build, not before.

"Have I succeeded in improving things? Making them better than others did? Is my design good
design?" (I06, Boston, October 1984, archive 1.1.5.1)
