# The onboarding that asks, designed under the Rams audit (REVIEW, then DIETERIFY)

Date: 2026-10-04. Mode: **REVIEW** of the proposal made in conversation the same day (Lorenzo:
"a personalized onboarding that's written really well, that helps us filter what they get out of
the app and personalize how they experience the app as a whole based on their selection and
priorities"; the builder's answer: two questions at most, each changing something the person sees
that day, and a copy pass), then **DIETERIFY** applied to that proposal, in the protocol's order.
The protocol is Lorenzo's "Dieter Rams" document; the earlier runs are
`docs/restructure/06-rams-audit.md` (the shipped app) and `docs/design/personalized-tracker-spec.md`
(the tracker, built as plan P). Quotation marks plus a tag mean Rams verbatim (T = transcript, kept
as captioned; W = Vitsoe's published English; I06 = print, footnoted to the archive). Everything
unmarked is applied reading, and is inference. No em dashes.

Nothing here is built when it is written. Section 1 is what the builder must have before judging;
Section 2 is the necessity gate; Section 3 says what holds in the proposal; Section 4 is the
findings against it, structural first, with the move for each; Section 5 is the diagnosis;
Section 6 is the corrected design, screen by screen, with each element's job, its copy and its
states; Section 7 is the ship gate pre-filled for whoever builds it.

---

## 1. Intake

**1.1 The purpose sentence.** A person tells the app once how it should behave toward them, and
it does, from the first day, in their own words.

(The conversation's sentence was "helps us filter what they get out of the app". That is the
maker's sentence: a funnel's. The one above is the person's. Every finding below is judged
against the person's.)

**1.2 The person.** Still imagined more than met. What is known: the sentences from Lorenzo's
calls that became the modes; the behaviour of everyone who has used a tracker (the first week's
diligence, then Recent); the four things people say when asked why they stopped: I forgot, I
never knew the amounts, I eat out, it took too long. And the one thing every app has already
spent on their behalf: their patience for being talked to. No one has answered these questions
yet, so findings about need rank below findings about internal consistency, and the smallest
real version is what REVIEW can insist on.

**1.3 The room.** Two rooms. The first three minutes with the app, one hand, a form already half
expected; then, later, the moments the answers act: eight in the evening with nothing logged, a
restaurant table, the result screen after a vague "some rice". The design is judged in the second
room. An answer that changes nothing there was a question that should not have been asked.

**1.4 The system.** The tracking preference (versioned, append-only, the person's record of every
move), `tracking/projection.py` (the one place that says what a choice changes), the nudge engine
with its three delivery levels and their promises, the invitations, the clarify engine with its
one threshold, the capture bar and its hint, the result screen and its "Save as a usual", the
first-run tour, the Action button card, Settings → Notifications and Settings → How I track.

**1.5 The frame of the feasible.** Additive wire shapes only (build 31 keeps decoding). Migrations
run only through the deploy. The nudge level lives on the phone today (UserDefaults) and rides on
every plan request; the server enforces whatever level it is sent. The parser's thresholds are
deterministic parameters already (`clarify.py`: 75 kcal or 10 g, 40 and 4 for a variant). The
build environment has no Swift toolchain; CI compiles. The capture core is not touched.

**1.6 The artifacts.** The intake as of `8170c88`: twelve screens for a numeric mode (the mode,
the basics, the ruler, the goal, three benefit interstitials, real life, training, hunger,
stress, meals), six for habits. Settings → Notifications with "Essential / All coaching / Off".
The nudge catalog. The welcome. Read in code, not run: this environment cannot run the app.

**1.7 The lifespan.** Years. The answers join the preference history and outlive any one screen.

**1.8 Provenance.** The mode question was decided (57) and is not reopened. The nudge level's home
on the phone was a convenience of 2026-08, never a decision. The three interstitials are inherited
from Beacon and were kept on purpose in the tracker spec (§3: the deep intake's function is partly
psychological). Inherited things and decided things get different moves below.

---

## 2. The necessity gate (the decisive questions for consumer software)

**Q2.** "Is the product that we are designing really necessary? Are there not already other,
similar, tried and tested appliances that people have got used to and are good and functional?
Is innovation in this instance really necessary?" (I06, q2)

Every incumbent's onboarding asks the goal, the weight, the activity: the engine's inputs. None
asks how the app should talk to you, and none asks what gets in your way, and so none can obey
either. The innovation is not another question; it is the obedience. A person who asked for quiet
is never sent a tip. A person who said they forget gets one reminder in the evening, and nobody
else does. A person who eats out sees the photo path on the bar. **Passes on the obedience
alone.** A question whose answer changes nothing the person can see fails Q2 on its own.

**Q3.** Enrichment, covetousness, or something new. The risk here is the segment: "you are a
Forgetter", a profile type, a badge for the diligent. **Passes if no answer is ever named back to
the person as a kind of person.** The app changes its behaviour and says nothing about it.

**Q7.** "Does it help people or incapacitate them? Does it make them more free or more dependent?"
(I06, q7). Choosing how much the app says is more freedom than a default chosen for them. A
reminder the person asked for is theirs; a reminder the maker wished on them is not. **Passes.**

**Q12.** "Does the product really offer convenience or does it encourage passivity?" (I06, q12).
The questions change nothing about the work of logging. **Passes.**

**Q14.** "Does it make an action or activity on the whole more complicated or simpler, is it easy
to operate or do you have to learn how to use it?" (I06, q14). Two screens longer at the start.
In exchange: a setting nobody finds (the coaching level) is asked once in plain words; a person
who wants nothing never sees the system's notification prompt; the evening reminder, the bar's
hint and the usual toggle arrive set. **Passes, and the two screens are written down as the
price** (S6 names what could pay for them).

**Q15.** "Does it arouse curiosity and the imagination? Does it encourage desire to use it,
understand it and even to change it?" (I06, q15). "What makes tracking hard for you?" is the one
place the app admits that tracking is hard. That admission is worth more than any promise.
**Passes.**

The gate passes. The thing should exist. Now the findings against how it was proposed.

---

## 3. What holds in the proposal

- **Two questions at most**, and a question must change something the person sees that day.
  "what I'm fight always during my life is come back to the simple things yeah we don't need
  all unnecessary things" (T02).
- **Orthogonal to the mode and to the goal.** The tracker spec cut "Why are you here?" as a twin
  (R2); the same test applies to anything added here.
- **The copy pass over the whole intake**, not only the new screens. One voice.
- **The answers as the beta's segmentation**: who logs and trusts, by what they asked for.
- **The preference is the home.** The answers join `tracking_preferences`, versioned, exported,
  deleted with the account, like the mode.

---

## 4. Findings against the proposal, structural first

### [S1] CUT · structural · "What would make this worth it to you?" is a twin of the mode

WHAT IT IS. The proposed first question, with four answers: know what I eat without the work,
hit my numbers, build the habit, follow my coach's plan.

WHAT HE SAYS. "Indifference towards people and the reality in which they live is actually the one
and only cardinal sin in design." (I06, archive 1.1.3.1)

WHAT FOLLOWS (inference). "Build the habit" is habits mode. "Hit my numbers" is macros or the
five. "Follow my coach's plan" is meal-plan mode. The person who just answered the mode question
would be asked it again in a funnel's words and would read the maker's segmentation to find
themselves in it. Three of the four answers are the taxonomy's twins (D3); the fourth, "without
the work", is a wish every person has and no answer can grant.

THE MOVE. Cut it. The axis the mode does not cover is how much the app should say. That is a
behaviour the app performs, not a kind of person, and the engine already enforces exactly three
settings of it. The first new question asks that, in three sentences (6.2).

### [S2] REVISE · structural · The nudge level has two owners

WHAT IT IS. The coaching level lives in UserDefaults on the phone and rides on every plan request;
the server enforces what it is sent and stores nothing. Asking it in onboarding and leaving it
there would make the onboarding's answer a local setting the record never sees, lost on a new
phone, absent from the export, invisible to the invitations.

WHAT HE SAYS. "Nothing must be arbitrary or left to chance." (I06)

WHAT FOLLOWS. Same storage is fine; same authority is not (AGENTS.md). One durable truth for how
much the app says, in the preference beside the mode; the phone keeps a cache for the moment
before the first read. The server's engine reads the stored level and the request's level only
for a client that has none. Settings → Notifications edits the preference, not a local flag.

THE MOVE. `tracking_preferences` gains `nudge_level`. The plan endpoint prefers it. The phone
adopts it on every read and writes it on every change.

### [S3] REVISE · material · "Essential", "All coaching", "Off" are the maker's words

WHAT IT IS. The three level labels in Settings → Notifications, with the delivery promise under
them in a second line.

WHAT HE SAYS. "We make the effort to produce products like this for the intelligent and
responsible users – not consumers" (W01)

WHAT FOLLOWS. "Essential" is the engine's category. The person's sentence is "only when I'm
slipping". Once the onboarding asks in the person's words, Settings must answer in the same
words or the person meets two vocabularies for one thing (D1, two names for one meaning).

THE MOVE. The three sentences of the onboarding answer are the three labels everywhere; the
delivery promise stays as the support line, which is the one place the engine's promise is
owed in full.

### [S4] CUT · material · Copy that multiplies by segment

WHAT IT IS. The proposal mentioned a welcome-back line per answer and a result screen that "leads
with" different things per answer.

WHAT HE SAYS. "this design should not gives the people more as the product really can do then it
is not honest" (T02)

WHAT FOLLOWS. Copy that forks by segment is the taxonomy speaking in four voices; the nudge copy
is final in the catalog and the client never rewrites it (decision 63). A result screen with a
different order per person is a second layout for the same meaning (D2).

THE MOVE. No per-answer copy anywhere. An answer may add one nudge (the evening reminder) with
one copy, set one default (the usual toggle), change one hint (the bar's) and move one threshold
(the amount checks). Nothing is reworded for anyone.

### [S5] REVISE · material · "Written really well" read as more words

WHAT IT IS. The intake's copy today: functional, in several registers ("We infer how active you
are from this - so you never rate yourself", "Yes - it curbs my appetite", a hyphen standing in
for a dash twice).

WHAT HE SAYS. "what I'm fight always during my life is come back to the simple things" (T02)

WHAT FOLLOWS. Well written means one sentence per title, one line per support, in the person's
register, each line saying what the tap does; and fewer words than today, not more.

THE MOVE. The copy of every intake screen is written in 6.6 and the build applies it as given.

### [S6] OPEN · fine · The two screens' price

WHAT IT IS. The intake grows by two screens in every mode. The numeric intake carries three
benefit interstitials; two of them ("momentum", "long-term results") teach nothing from the
person's own numbers (the realistic-pace one does: it draws their curve).

WHAT HE SAYS. "Human needs are more diverse than many designers are sometimes ready to admit or,
perhaps, capable of knowing." (I06)

WHAT FOLLOWS. The tracker spec kept the deep intake on purpose, for a function that is partly
felt. The protocol forbids striking a kept element for the builder's taste. The owner decides.

RECOMMENDATION. Cut "momentum" and "long-term results"; keep "realistic pace". The numeric intake
then stays at twelve screens with the two questions in. Not built here: OPEN for Lorenzo.

### [S7] HOLDS · The claim audit of "Nothing"

A person who answers "Nothing. I'll check in myself." must never see the system's notification
prompt, never a card, never a scheduled fire. The weekly check-in banner on Today appears when
the check-in is due, inside the app the person opened; it is a fact about the week, not the app
speaking first, and it stays. The support line says so, so the claim is checked before the tap.

---

## 5. Diagnosis

The proposal's error was the plan's before it: **a segment in the person's slot** (S1, S4). The
correction is the same as last time, one layer down: ask about behaviour the app will perform
(how much it says, what it should help with), never about who the person is; put the answer in
the one durable place (S2) and say it back in the person's words (S3). Fewer words, not more (S5).

**The short list, in order.**
1. Two questions after the mode: how much the app says (three sentences, the three levels) and what makes tracking hard (four, any or none).
2. The level joins the preference; the server reads it; Settings edits it in the same sentences.
3. Each friction moves exactly one thing: a reminder, a threshold, a hint, a default. No copy forks.
4. The copy pass over every intake screen, as written in 6.6.

---

## 6. The design, corrected (DIETERIFY passes applied to the proposal)

Each pass was run once, in the protocol's order. Tokens, radii, type and spacing are
`docs/DESIGN.md`'s and are not restated; the two new screens use the intake's one layout
(eyebrow, title, support, a `ChoiceList`, the pinned pill).

### 6.1 Restated purpose

A person tells the app once how it should behave toward them, and it does, from the first day, in
their own words.

### 6.2 The two questions (the element inventory)

**How much should Vo-Cal say?** One answer, nothing preselected. The three answers are the three
delivery levels the engine already enforces (`nudges/engine.py`); the support line is that level's
promise, which is the one place the engine's words are owed.

| Title (the person's sentence) | Support line (the promise) | Stored as |
|---|---|---|
| Only when I'm slipping | A reminder when a day goes quiet. Nothing else. | `essential` |
| Coach me along the way | Tips on protein, water, treats and the week. Never more than two a day. | `standard` |
| Nothing. I'll check in myself. | No reminders, no tips. Your weekly check-in still shows when it is due. | `off` |

**What makes tracking hard for you?** Any number of answers, or none. Each names one thing the
app will do about it; the support line is that thing, so the person knows what the tap buys.

| Title | Support line (what the app does) | Stored as |
|---|---|---|
| I forget | A reminder in the evening when a meal is still unlogged. | `forgetting` |
| Portions and amounts | A question about an amount you left vague, more often. | `portions` |
| Eating out | The photo path, right on the bar. | `eating_out` |
| It takes too long | Each meal offered as a usual, until you have a few. | `time` |

Removed by the strike list: the "worth it" question (S1), per-answer copy (S4), glyphs on the
options (the undefined glyph, C2), a "none of these" row (continuing with nothing ticked is the
answer; a row for it would be a control that does what the pill already does, A4).

### 6.3 The intake, per mode

The two questions follow the mode and precede the engine's questions, because they are about the
person and the app, and the engine's questions are about the number. Every mode asks both.

| Step | Habits | Numeric modes | Meal plan |
|---|---|---|---|
| How do you want to follow your nutrition? | 1 | 1 | 1 |
| How much should Vo-Cal say? | 2 | 2 | 2 |
| What makes tracking hard for you? | 3 | 3 | 3 |
| The basics | 4 | 4 | 4 |
| The ruler, the goal, the interstitials, hunger | no | yes | yes |
| Real life, training, stress, meals | yes | yes | yes, and meals sizes the plan |
| The reveal | "Set up my habits" | "Build my protocol" | then the plan builder |

The disclaimer stays on the first step in every mode.

### 6.4 What each answer moves

`tracking/projection.py` is the one place that says it (decision 59), as `experience_for(level,
frictions)`; the preference response carries the result so the phone arranges and never decides.

| Answer | The server | The phone, the same day |
|---|---|---|
| Only when I'm slipping | plans at `essential`; no invitations | the habit-protecting nudges only, at most one a day; the system's notification prompt after the first log, as today; the ladder stays reachable in Settings → How I track |
| Coach me along the way | plans at `standard`; invitations on quiet days | the full catalog, never more than two a day |
| Nothing. I'll check in myself. | plans nothing; no invitations | no plan requested, no card, no scheduled fire, and the system's notification prompt is never shown; the weekly check-in banner stays (S7) |
| I forget | the evening reminder joins the catalog for this person: at 20:00 local, on a day with fewer meals logged than the person said they eat, essential (so it fires for "slipping" too, never for "Nothing"), one copy: "Anything from today still unlogged? A sentence now keeps the day whole." | one local notification in the evening, inside the level's budget |
| Portions and amounts | the amount checks fire at the variant bar (40 kcal or 4 g) instead of the standard bar (75 or 10); still at most four checks; never in habits mode, where checks are off (tracker spec R3) | one more question on the result screen when an amount was vague |
| Eating out | `bar_hint: photo` | the bar reads "Say it, type it, or snap your plate." and the tour shows the photo step before the typing step |
| It takes too long | `seed_usuals: true` | "Save as a usual" is on by default on the result screen until three usuals exist; the toggle stays visible and a tap turns it off for that meal |

An invitation is the maker speaking first about the person's setup; "Only when I'm slipping"
declines that voice, so invitations wait for "Coach me along the way". The ladder is not lost: the
rows in Settings → How I track move the mode and the focus metrics by hand, as before.

### 6.5 Settings

**Notifications** becomes the voice's editor in the voice's words: the section is "How much
Vo-Cal says", the three rows are the three sentences of 6.2 with the promise under the chosen one,
and a tap appends a preference version (`PUT /tracking`, `nudge_level`). The iOS permission row
stays as it is: what the phone allows is a separate fact and is shown as one.

**How I track** gains "What gets in the way" under "Also show": the four rows of 6.2 as ticks, each
appending a version. Changing one changes the one thing it names, the same day.

### 6.6 The copy, every screen of the intake

One eyebrow (the section), one title (the question, in the person's words), one support line (what
the answer does), options with one line each. No hyphen stands in for a dash. The engine's
questions keep their answers; their lines are tightened to say what the answer changes.

| Screen | Eyebrow | Title | Support | Options |
|---|---|---|---|---|
| Mode | How you track | How do you want to follow your nutrition? | You can change this any time. | the five, with their lines (tracker spec 6.2) |
| Voice | How we talk | How much should Vo-Cal say? | Change it any time in Settings. | the three of 6.2 |
| Friction | What gets in the way | What makes tracking hard for you? | Pick what fits. Or nothing. | the four of 6.2 |
| Basics | The basics | Let's start with you. | Height, weight and age set the range. The rest makes it yours. | Female · Male; the three wheels |
| Goal | Your goal | What are we working toward? | (none) | Lose fat, keep muscle · Maintain where I am · Build muscle |
| Real life | Your real life | What does a normal week look like? | Your activity comes from this. You never have to rate yourself. | Mostly at a desk · On my feet all day · Physical work; Young kids at home? No · Yes |
| Training | Training | How much do you train? | With your work, this is how we read your real activity. | Not much yet · Light (1 to 2 days a week) · Moderate (3 to 4) · Heavy (5 or more) |
| Hunger | Hunger | On any medication that affects appetite? | It changes the math more than you would think. | No · Yes, it curbs my appetite · Yes, it increases my appetite |
| Stress | Life right now | How are your stress and sleep? | habits: Stressful weeks get gentler reminders. / numeric: A stressful week earns a lighter, more livable deficit. | Pretty steady · Normal ups and downs · Stressed, sleep is rough |
| Meals | Your day | How many meals do you prefer? | habits: So a day with every meal logged reads as one. / meal plan: Your plan starts with this many meals. / numeric: Your targets are shaped around it. | 2 · 3 · 4 · 5 |

The welcome's line gains the fifth way, now that it ships: "Habits, calories, the method, macros,
or a meal plan. You choose; the app shows only that. Say what you ate and it logs."

### 6.7 The states, enumerated and decided

- **Nothing chosen on the voice screen**: the pill waits (nothing is preselected; a silent default
  here is a prompt or a silence the person did not choose).
- **Nothing ticked on the friction screen**: the pill continues; the preference stores an empty
  list; nothing changes anywhere, and nothing says so.
- **"Nothing" and the first log**: no permission prompt. Settings → Notifications shows "Delivery"
  as "Not asked" rather than "Asked after your first log".
- **A level changed in Settings**: the preference appends a version; the phone's cache follows the
  echo, never the tap; a change that did not land says so and leaves the old row ticked.
- **A friction changed in Settings**: the same, and the one thing it names changes from the next
  parse, the next evening, the next result.
- **The evening reminder on a day with every meal logged**: silent. On a day with nothing logged
  and a late-morning reminder already shown: silent (one essential touch a day).
- **"It takes too long" once three usuals exist**: the toggle returns to off by default; the three
  chips are the reason.
- **A server that predates the fields**: the phone sees no `nudge_level` and keeps its cache; no
  frictions and changes nothing. A client that predates them sends neither and the server's
  defaults are today's behaviour.
- **Before the migration is applied**: `PUT /tracking` fails as it does for the mode; the intake's
  writes are fire-and-forget and retried after sign-in, so onboarding completes.

### 6.8 The claim audit

The voice's support lines are the engine's promises verbatim, so the sentence the person reads is
the rule the server enforces. The friction lines name one thing each and the build does exactly
that thing. "Nothing" means the system prompt never appears. "Until you have a few" is three, and
the toggle is visible every time. The bar's hint names three ways in and all three exist. Nothing
on these screens promises an outcome.

### 6.9 The restoration check

Did the passes remove any function without replacing it? The cut "worth it" question carried the
feeling of being asked what one wants; the voice question carries it better, because its answer
is kept. The cut per-answer copy carried warmth; the warmth stays in the one admission ("What
makes tracking hard for you?") and in the four support lines, which are promises kept rather than
tone. "Essential" and "All coaching" carried precision for the maker; the promise line keeps it.
Nothing warm came out that did not go back in another place.

### 6.10 Evidence

None yet. Before and after, at real size: the render loop's goldens for the two new screens and
the Notifications page; the first run on the pinned simulator through all three modes; and, the
only evidence that counts, the beta's numbers by answer (`scripts/beta-metrics` gains who asked
for what). No claim of improvement without them.

---

## 7. The ship gate, pre-filled for the builder

1. **Purpose.** A person tells the app once how it should behave, and it does. Serve it or do not ship.
2. **Honesty.** Each support line is the thing the build does. "Nothing" never prompts. "Until you have a few" is three.
3. **Butler.** Invitations only for "Coach me along the way". The evening reminder only for those who asked, inside the budget.
4. **Order.** Strip the support lines from the two new screens: do the titles alone say what the tap does? (Expected no for the frictions; yes for the voice. Re-check after a week of real use.)
5. **Register.** No engine word in a slot the person owns: no "essential", no "standard", no "level" on a screen.
6. **Detail.** The states of 6.7, each drawn.
7. **Year five.** A fifth friction is a row and one more thing the projection does; a fourth level is not allowed (three promises are enough to keep).
8. **Resources.** Nothing added that nobody needs: no glyphs, no "none of these", no profile type.
9. **Subtraction.** What can still come out: two of the three interstitials (S6); the friction screen's support lines if the titles teach alone.
10. **Restoration.** Section 6.9, re-read after the build, not before.

"Have I succeeded in improving things? Making them better than others did? Is my design good
design?" (I06, Boston, October 1984, archive 1.1.5.1)
