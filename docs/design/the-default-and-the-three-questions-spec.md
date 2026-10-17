# The default and the three questions, designed under the Rams audit (REVIEW, then DIETERIFY)

Date: 2026-10-16. Mode: **REVIEW** of the owner's ask of the same day (Lorenzo: "make every path a
slightly different experience for each person ... mini food tracking quizzes that ask only 3
questions that are detailed ... a user might also not care and may want to skip all these steps
and go to the default and the default mind you needs to include fats, it doesn't ... every aspect
dieter rams needs to audit and approve"), then **DIETERIFY** applied to that ask, in the protocol's
order. The protocol is Lorenzo's "Dieter Rams" document; the earlier runs are
`docs/restructure/06-rams-audit.md` (the shipped app), `docs/design/personalized-tracker-spec.md`
(the modes), `docs/design/onboarding-that-asks-spec.md` (the questions about the app),
`docs/design/behavior-change-spec.md` (the order and the words) and
`docs/design/the-bar-answers-spec.md`. Quotation marks plus a tag mean Rams verbatim (T =
transcript, kept as captioned; W = Vitsoe's published English; I06 = print, footnoted to the
archive). Everything unmarked is applied reading, and is inference. No em dashes.

Section 1 is what the builder must have before judging; Section 2 is the necessity gate; Section 3
says what holds in the ask; Section 4 is the findings against it, structural first, with the move
for each; Section 5 is the diagnosis; Section 6 is the corrected design, screen by screen, with
each element's job, its copy and its states; Section 7 is the ship gate. Section 8 is the audit of
the rest of the app the owner asked for in the same breath, with what was fixed and what is his.

---

## 1. Intake

**1.1 The purpose sentence.** A person who wants the app to be theirs is asked three things and
it becomes theirs; a person who does not want to be asked is not, and the app still works,
truthfully, from the first thing they say.

(The ask's sentence was "make it more personalized". That is the maker's. The one above is two
people's, because the ask names two: the one who answers and the one who skips. Every finding is
judged against both.)

**1.2 The person.** Two now, and the second is new to the record. The first wants the app to fit
("I wanted a meal plan", "I just want to look at calories"; the sales calls). The second installed
it to log the lunch in front of them and will give the first screen one tap, not thirteen. Lorenzo
met the second in himself ("a user might also not care"). Francesco supplies the third voice, not
a person but a correction: a standard view that hides fat fails the woman repairing her hormones,
who needs "calories and overall fat intake ... more than anything" (2026-10-12, C-03), and "a low
fat intake dysregulates hormones" (the same conversation). No one has used a skip; findings about
need rank below findings about internal consistency, and the smallest real version is what REVIEW
can insist on.

**1.3 The room.** The first minute: a phone in one hand, lunch in the other, the install still
warm, the patience for forms already spent by every other app. Then the moment the skipper's
choice is tested: the first result screen, the first Today, the banner that says whose numbers
these are. The design is judged in the second room: a skip that lands on a page that lies, or on
a page with no door back to the questions, was not a skip but a trap.

**1.4 The system.** The welcome (`WelcomeView`), the intake and its per-mode steps
(`IntakeFlowView.steps(for:)`), the preference with its version 0 (`tracking_preferences`; no row
means never chosen, which renders the method's mode), the stub targets and the starter banner
(`meals/today.py STUB_TARGETS`, `TodayView.starterTargetsBanner`), the composer and the projection
(`meals/dashboard.py`, `tracking/projection.py`), the permission card after the first log
(`NotificationPermissionCard`, decision 67), the nudge plan's level (`nudges/router.py`: the
stored level wins, else the phone's cache), Settings → How I track and → Notifications.

**1.5 The frame of the feasible.** Additive wire shapes only: TestFlight build 32 decodes the mode
token `five` and must keep decoding it, so a mode may change its contents but not its wire name.
The engine already computes fat for everyone (27 percent of calories, `protocols/engine.py`), so
showing it costs nothing. No migration is needed (nothing new is stored). This environment has no
Swift toolchain; CI compiles the app. The capture core is not touched. The behavior-change order
(decision 69) is a decided thing: an obstacle is asked after the outcome, never before.

**1.6 The artifacts.** The intake as of `547d137` (build 32): thirteen screens for a numeric mode,
nine for habits, four of them about the person and the app (the mode, what gets in the way, when
you log, how much to say). The welcome with its one pill. The method's mode on Today: calories
beside protein, over produce, water and fiber; no fat. The permission card. Read in code, not run.

**1.7 The lifespan.** Years. A skip is not a record; a choice is. Both must still be true in year
five.

**1.8 Provenance.** The five pillars were decided (28, Francesco, June 2026: "carbs/fat off by
default") and are reopened here by both owners (Lorenzo's ask; Francesco's correction of
2026-10-12). The mode asked first with nothing preselected was decided (57) and stands. The voice
question's substance was decided (66) and stands; its place in the intake was the spec's layout,
and is moved. The order of the intake (69) stands. The permission card after the first log (67)
stands and is where the voice question now lands. Inherited things and decided things get
different moves below.

---

## 2. The necessity gate (the decisive questions for consumer software)

**Q2.** "Is the product that we are designing really necessary? Are there not already other,
similar, tried and tested appliances that people have got used to and are good and functional?
Is innovation in this instance really necessary?" (I06, q2)

Three things are asked for. *The skip.* No incumbent allows it: the quiz is their funnel, and the
person is its hostage until the paywall. A skip that lands on a real, usable, honest default is
the innovation, and it is cheap: the default already exists (version 0 renders the method's
mode). **Passes** on the obedience: the person who says "I don't care" is obeyed, and the app
still works. *The default with fat.* Francesco's clinical point and the owner's call; the engine
already knows the number. **Passes**: it is a hidden true thing shown. *Three questions.* The
intake asks four things about the person and the app; the ask is three. The question that leaves
must be the one whose answer changes nothing until later, or the cut is a loss. **Passes** under
D3's condition (the voice leaves the intake and is asked where it first acts, not dropped).

**Q3.** Enrichment, covetousness, or something new. The risk: a skip framed as the lesser door
("Skip for now, you'll miss out"), a personalization framed as the premium one. **Passes if the two
doors are stated as two doors, neither sold.**

**Q7.** "Does it help people or incapacitate them? Does it make them more free or more dependent?"
(I06, q7). A door out of the questions is the most free thing the welcome can offer. **Passes**, as
long as the way back in (the questions, later, from Settings) is as plain as the way out.

**Q12.** "Does the product really offer convenience or does it encourage passivity?" (I06, q12).
The skipper does the same work of logging as everyone; what they skip is the maker's curiosity,
not their own effort. **Passes.**

**Q14.** "Does it make an action or activity on the whole more complicated or simpler, is it easy
to operate or do you have to learn how to use it?" (I06, q14). One screen fewer for everyone who
answers; twelve fewer for the one who skips; one more line on the welcome. On the whole, simpler.
**Passes.**

**Q15.** "Does it arouse curiosity and the imagination? Does it encourage desire to use it,
understand it and even to change it?" (I06, q15). "Make it mine" is an offer, not a toll. The
skipper who later wonders what they skipped finds the same three questions in Settings, where
they can change the app at will. **Passes.**

The gate passes. The thing should exist. Now the findings against how it was asked.

---

## 3. What holds in the ask

- **Optional personalization.** "it's optional to get a personalized experience": the questions
  are an offer. "they have to stay in the background when we don't need it and have to be there
  when we need it" (T02).
- **The default must be true to the method as it is taught now.** Fat is in Francesco's method
  today (the plan generator already balances it, decision 73; the numbers-free guidance names it,
  decision 74); the standard view that hides it is the one surface still saying June.
- **Three, not more.** "what I'm fight always during my life is come back to the simple things
  yeah we don't need all unnecessary things" (T02).
- **Every path a different experience.** True since 2026-10-04, by behaviour: the mode decides
  the intake, the reveal, Today, the result, the rows, the chips, the week card and the nudges; a
  friction moves one thing each; the anchor moves two reminders; the level gates the voice. What
  does not fork, by decision 66 (S4), is the copy. 6.7 lays the forks out so nobody adds a fork
  of words to prove there are forks.
- **Rams audits every aspect.** Section 8.

---

## 4. Findings against the ask, structural first

### [D1] REVISE · structural · "A slightly different experience" must mean behaviour, not words

WHAT IT IS. The ask: "make every path a slightly different experience for each person."

WHAT HE SAYS. "this design should not gives the people more as the product really can do then it
is not honest" (T02)

WHAT FOLLOWS (inference). Read as words, the ask reopens S4 (decision 66): a welcome-back line per
answer, a result screen that "leads with" something different per segment, four voices for one
meaning. Read as behaviour, the ask is already the architecture: one typed preference drives
three projections, and every answer moves a thing the person can see that day. The difference a
person should feel is that the app shows, asks, reminds and offers differently; never that it
talks to them as a type.

THE MOVE. No copy forks by answer, as before. The forks that exist are written down in one table
(6.7) so the claim "every path is different" is checkable against the code, and so the next person
who wants a path to feel different adds a behaviour to the table, not a sentence to a screen.

### [D2] CUT · structural · "Mini quizzes" are one quiz; the recurring one already exists

WHAT IT IS. The ask's plural: "mini food tracking quizzes that ask only 3 questions."

WHAT HE SAYS. "Does the product really offer convenience or does it encourage passivity?" (I06,
q12)

WHAT FOLLOWS. A quiz is justified only where its answers act (the onboarding spec's rule: an answer
that changes nothing that day was a question that should not have been asked). There are two such
moments and both are built: the start (the three questions of D3) and the week (the check-in asks
"What got in the way this week?" and moves the preference, decision 69). A third quiz on day three
or day ten would ask things the app cannot act on, or ask again what it already knows.

THE MOVE. One quiz, at the start, optional; the weekly check-in stays the recurring one. No third.

### [D3] REVISE · structural · The fourth question leaves the intake and is asked where it first acts

WHAT IT IS. Four questions about the person and the app: how you want to follow your nutrition
(decision 57), what makes tracking hard (66), when you will log (69), how much Vo-Cal should say
(66). The ask is three.

WHAT HE SAYS. "Nothing must be arbitrary or left to chance." (I06)

WHAT FOLLOWS. The cut cannot be a loss: every one of the four moves something. Weigh them by when
the answer first acts. The mode acts on the next screen. What gets in the way acts on the first
parse (the amount checks), the first result (the usual toggle), the bar (the hint). When you log
acts on the first reminder's slot. How much the app says acts on nothing until the first log:
the nudge plan has nothing to say before a day exists, and the notification cannot reach the
person until the permission is asked, which decision 67 placed after the first log, in the
person's own sentence, on a card on Today. That card today says the person's chosen sentence back
to them ("You asked for a reminder only when a day goes quiet. Allow notifications to get it.")
and asks a second time, in effect, for what the intake already asked. Two beats for one meaning.

THE MOVE. "How much should Vo-Cal say?" leaves the intake and becomes the card after the first
log, for anyone never asked: the same three sentences (`VoiceChooser`, the one view, spec S3), the
same support lines (the engine's promises), nothing preselected. A tap writes the preference
(`PUT /tracking`, `nudge_level`), sets the phone's cache, and, unless the answer is "Nothing. I'll
check in myself.", shows the system permission sheet at once: the sentence is the ask. The card
is the only place the app speaks first about itself and it speaks once. A person who chose a
level before this build keeps the permission card as it was. Preserve: the three sentences, the
storage, Settings → Notifications as the editor. Amends decision 66's placement, not its
substance; realizes decision 67's "in the person's own sentence" with the person's own tap.

The intake's three questions about the person and the app are then: what you want to see (the
mode), what gets in the way, when you will log. The order of decision 69 is unchanged: the mode
first; the obstacle after the outcome; the plan's cue after the obstacle. In habits mode the
intake is eight screens; in a numeric mode twelve.

### [D4] REVISE · structural · The default is not a screen, not a partial intake, and not a write

WHAT IT IS. "skip all these steps and go to the default."

WHAT HE SAYS. "Indifference towards people and the reality in which they live is actually the one
and only cardinal sin in design." (I06, archive 1.1.3.1)

WHAT FOLLOWS. Three ways to build a skip, two of them wrong. A one-screen "here is the default"
before the account is a screen the person said they did not want. Asking "just the basics" on
the skip path is the intake wearing a shorter coat; the numbers would be theirs but the skip would
not. Writing a preference row for the skipper (a new source value, "skipped") records a choice
that was not made. The honest default already exists: version 0 of the preference, source
`default`, "never chosen", which renders the method's mode; and the honest numbers for a person
who gave none already exist too: the starter targets, flagged `targets_are_stub`, with the banner
on Today that says so and leads to the one place the basics live (Settings → My details, which
replays the intake and builds the protocol).

THE MOVE. The skip goes from the welcome to the account step to Today. Nothing is written for the
person; the record says never chosen, which is true. Today shows the method's six at the starter
targets with the banner; the bar works; the tour runs; the first log asks how much the app should
say (D3); the questions wait in Settings → How I track for the day the person wants them. The
banner's words are corrected to name the door (6.8). Preserve: the stub's flag and the banner; the
tour; the capture bar as the one way in.

### [D5] REVISE · material · Fat joins the method's mode; the label follows its contents

WHAT IT IS. The method's mode prints calories, protein, produce, fiber and water; its label is the
list of the five (R5: contents, not a brand). Decision 28 (June) set "carbs/fat off by default".
The owner: "the default mind you needs to include fats, it doesn't."

WHAT HE SAYS. "Human needs are more diverse than many designers are sometimes ready to admit or,
perhaps, capable of knowing." (I06)

WHAT FOLLOWS. The engine computes fat for everyone and the method now teaches it (decisions 73
and 74 both treat fat as a target to meet, with Francesco's reason). A standard view that hides it
is the last surface saying what the method said in June. Adding fat to the mode, rather than
making the skipper's default a special composition, keeps one mode for one meaning (D1 of the
failure family: a twin mode would be a shared slot growing a second mode) and reaches everyone who
chose or never chose the method, which is what "the default" means. The label must follow: a list
of five that prints six would be the first lie on the chooser.

THE MOVE. The method's mode prints calories, protein, fat, produce, water and fiber. The chooser's
title is "Calories, protein, fat, produce, fiber, water"; its support line "The six things the
method tracks."; Settings' short label "The method" (the method's name stays in one place, Settings
→ My protocol, as R5 set). The reveal gains the fat row with the engine's existing why. Today
places the fat tile first among the tiles, after the two heroes: the macros together, then the
habits (produce, water, fiber); four tiles wrap two and two as the layout already does. "Also
show" no longer offers fat in this mode (it is there). The assist reads "the six" and "six things"
as the mode and keeps reading "the five" (the words a tester learned). The wire token stays `five`
(build 32 decodes it); the identifier in code becomes `method`, with a comment saying why the two
differ, because a reader of `five` would count wrong. Amends decisions 28 and 58; realizes C-03
for everyone in the method's mode, not only through a focus tile.

### [D6] HOLDS · "Detailed" is the support line, not a longer list

WHAT IT IS. "3 questions that are detailed to understand more of what each person needs."

WHAT HE SAYS. "Care and accuracy in the design process show respect towards the consumer." (I06)

WHAT FOLLOWS. The three questions are specific already: each option is a sentence a person says,
and the support line names the one thing the tap buys. The candidates for a fifth and sixth
friction were weighed and refused: "I snack without noticing" would need a second essential
reminder a day (the budget is one); "weekends get away from me" would add a Friday nudge, a
voice, not a behaviour the person asked for; "I cook for others" would move the recipe door up
the result screen, a layout fork. None has an honest one-thing move. The depth is in the
obedience, not the count.

THE MOVE. None. The four frictions, the five modes and the four moments stay. A fifth friction is
a row and one more thing the projection does, when one is found that moves exactly one thing.

### [D7] REVISE · material · The welcome's two doors, stated as two doors

WHAT IT IS. The welcome: one pill, "Choose how I track", and the line "About 3 minutes · no
account needed yet".

WHAT HE SAYS. "It does not attempt to manipulate the consumer with promises that cannot be kept."
(I06)

WHAT FOLLOWS. Two doors are the minimum for an optional thing. The temptation is to sell one: a
count ("Three questions and it's yours") on the welcome would be a claim above the state, because
the engine's screens follow the three in every numeric mode; a "Skip for now" implies a later toll.
The time stays the honest measure. The second door's words must name what is skipped and nothing
about what is lost.

THE MOVE. The pill reads "Make it mine" (the offer, in the person's words); the caption under it
reads "A few minutes · no account needed yet" (the audit's A23 found "About 3 minutes" a duration
nobody measured); beneath, one text button, "Skip the questions",
with no line under it: what the skip leads to is taught by the thing itself (Today) and said once
in the banner there. Nothing else on the screen changes.

### [D8] REVISE · fine · The account gate's title is false on the skip path

WHAT IT IS. `AuthGateView`: "Save your protocol" and "One tap. We ask for nothing else - no email
lists, no password to forget."

WHAT HE SAYS. "this design should not gives the people more as the product really can do then it
is not honest" (T02)

WHAT FOLLOWS. The skipper built no protocol; the title names a thing that does not exist. The body
carries a hyphen standing in for a dash (the copy rule of spec 6.6). The error line is set in the
protein red, a macro colour carrying non-macro meaning (DESIGN.md: "Macro colors are never used
for non-macro meaning"; `vcAlert` is the one non-macro red).

THE MOVE. On the skip path the title is "Keep your log" and the line "One tap, and every meal you
say is yours to keep. No email lists, no password to forget." On the path through the questions
the title stays and the line loses its hyphen the same way. The error line takes the alert red.

### [D9] HOLDS · The claim audit of the skip

A skipper must never be told the starter numbers are theirs, never be nudged about a target that is
a stub (the engine already zeroes the targets for the plan when `is_stub`, so only the habit
nudges can speak), never see the system's notification prompt before the card asks them, and must
find the questions again in Settings without a tour. All four hold in the design below; the first
needed the banner's words (6.8).

---

## 5. Diagnosis

The earlier rounds added questions and made each one earn its place. This round asks whether a
person may refuse them, and the error to avoid is the funnel's reflex: making the refusal cost
something (a lesser default, a stub with no door, a nag to come back). The correction is the same
as every round before it, applied to the door instead of the question: the default must be a real
product (D4, D5), the skip must be stated as plainly as the offer (D7), and a question must sit
where its answer acts (D3), which is also how four became three without losing one.

**The short list, in order.**
1. Fat joins the method's mode; the label, the reveal, Today and the assist follow (D5).
2. The welcome has two doors; the skip lands on Today at the starter targets with the banner as
   the door to the basics; nothing is written for the skipper (D4, D7).
3. The voice question becomes the card after the first log, which is the permission ask; the
   intake asks three things about the person and the app (D3).
4. The gate's title and the banner's words tell the truth; the error red is the alert red (D8, 6.8).
5. The audit of the rest (Section 8).

---

## 6. The design, corrected (DIETERIFY passes applied to the ask)

Each pass was run once, in the protocol's order. Tokens, radii, type and spacing are
`docs/DESIGN.md`'s and are not restated.

### 6.1 Restated purpose

A person who wants the app to be theirs is asked three things and it becomes theirs; a person who
does not want to be asked is not, and the app still works, truthfully, from the first thing they
say.

### 6.2 The welcome (the element inventory)

| Element | Job | Copy | Notes |
|---|---|---|---|
| Wordmark | Says whose screen this is | "Vo-Cal" | unchanged |
| Headline | The capability in the person's register (decision 56) | "Follow your nutrition your way." | unchanged; gold on "your way." |
| Line | What the choice is and what the app does | "Habits, calories, the method, macros, or a meal plan. You choose; the app shows only that. Say what you ate and it logs." | unchanged |
| Pill | The offer | "Make it mine" | was "Choose how I track"; the new title names the whole of what the questions do, not the first of them |
| Caption | The honest cost of the offer | "A few minutes · no account needed yet" | the order of time, not a number: "About 3 minutes" was a duration nobody measured (Section 8, A23); a count of questions is refused (D7) |
| Text door | The way past the questions | "Skip the questions" | new; ink, 15 pt medium, centered under the caption; no line under it |

Removed by the strike list: a second caption under the skip ("you can always come back"), a glyph
on either door, a count of questions.

### 6.3 The three questions, and the intake per mode

**Habits** is mode · basics · real life · what gets in the way · when you log · training · stress
· meals (eight). **A numeric mode** (calories, the method, macros, the meal plan) is mode · basics
· desired weight · goal · the pace · what gets in the way · when you log · real life · training ·
hunger · stress · meals (twelve). The three questions about the person and the app are
the mode, what gets in the way and when you log; the rest set the number and the nudges, as before.
The order is decision 69's with the fourth question lifted out. The disclaimer stays on the first
step in every mode. The Continue gates stay: the mode (nothing preselected), sex, the anchor.

### 6.4 The default: what the skipper sees

| Surface | What it shows | Why it is honest |
|---|---|---|
| Account step | "Keep your log", one tap (Sign in with Apple; "Continue without an account" on live builds as today) | names the thing being kept |
| Apple Health step | as today, when the phone has it and it was never asked | unchanged |
| Today, the cards | the method's six at the starter targets: Calories left beside Protein, then Fat · Produce · Water · Fiber | the stub is flagged; the composer is the same one everyone gets |
| Today, the banner | "You're on starter targets" / "Add your height, weight and age and the numbers become yours." → Settings → My details | the one door to the basics, in the person's words |
| The bar, the tour, usuals, the week card | as for anyone in the method's mode | nothing forks by path |
| The first log's result | the method's result (calories and macros print) | the mode prints numbers |
| After the first log | the voice card (6.5) | asked where it acts |
| Nudges before the card is answered | the phone plans at its own default level (only when slipping) inside the three-day grace; no notification can land before the permission the card asks | nothing speaks first about the person's setup |
| Settings → How I track | the method's mode ticked; "Also show"; what gets in the way; when you log | the three questions, findable, changeable |

No preference row is written. The beta's "who asked for what" counts the skipper under never
chosen, which is what they did.

### 6.5 The card after the first log: "How much should Vo-Cal say?"

Shown on Today, above the day's meals, once the person has logged at least once and the preference
has no level (never asked). The same `GlassCard` with the gold hairline the nudge and permission
cards use; a title in the person's question, no support line of its own (each row carries the
engine's promise); the three rows of `VoiceChooser` (spec S3's one view). No close, no "Not now":
the question is answered or it waits, because every answer is a real setting and one of them is
"Nothing".

| Tap | The preference | The phone | The system |
|---|---|---|---|
| Only when I'm slipping | `nudge_level: essential` (a version appended) | `NudgeCenter.level = .essential`; the card goes | the permission sheet, at once |
| Coach me along the way | `standard` | `.standard`; the card goes | the permission sheet, at once |
| Nothing. I'll check in myself. | `off` | `.off`; the card goes; scheduled fires cancelled | nothing, ever (S7) |

The echo decides: the card leaves on the server's reply, not the tap; a write that did not land
leaves the row unticked with the one line Settings uses ("That didn't reach the server. Check your
connection and try again."). The permission sheet follows the echo too, so a denied write never
leaves a permission granted for a level the record does not hold. A person who chose a level at
onboarding before this build never sees this card; the permission card of decision 67 stays theirs.

### 6.6 The method's six

| Surface | Before | After |
|---|---|---|
| Chooser title | Calories, protein, produce, fiber, water | Calories, protein, fat, produce, fiber, water |
| Chooser support | The five things the method tracks. | The six things the method tracks. |
| Settings' short label | The five | The method |
| Reveal rows | protein, water, fiber, produce | protein, fat, water, fiber, produce (the fat row in the fats blue, its why the engine's) |
| Today | Calories left · Protein (twins); Produce · Water (+) · Fiber | Calories left · Protein (twins); Fat · Produce; Water (+) · Fiber (two and two) |
| Also show | fiber, water, produce, carbs, fat, sugar, sodium less the four shown | less the five shown: carbs, sugar, sodium |
| The assist | "the five", "five things" → the mode | and "the six", "six things"; the Settings row it draws says the new title |
| Meal plan mode's reveal | the five's keys | the six's keys (it checks the plan against the same protocol) |
| Wire | `five` | `five` (build 32 decodes it); identifier `method` in code |

The hero stays two twins: fat is a tile, not a third hero, because two heroes of one height is the
page's rhythm and a third would break it; among the tiles fat comes first so the macros read
together.

### 6.7 What each answer moves (the forks, in one table)

The evidence for "every path is different", so the next fork is added here as a behaviour.

| Answer | The intake | The reveal | Today | The result | Reminders and offers |
|---|---|---|---|---|---|
| Habits | 8 screens, no goal, no ruler, no medication | three habits, two counts | three tiles, no number anywhere, no week card, the guidance card | items without numbers, no checks, "Log it" | habit nudges in habit words; never an invitation up |
| Calories | 12 screens | the calorie hero alone | one card, the week card | as today | calorie nudges; invitation up: protein as a focus |
| The method | 12 | hero and five rows | twins and four tiles, the week card | as today | the full set less the macros' own |
| Macros | 12 | hero, protein, carbs, fat, fiber | hero and three macro tiles | as today | the method's set less fiber |
| Meal plan | 12, then the builder | the six's rows, then "Build my meal plan" | the plan card first, calories beneath | as today | the plan nudge, in the evening |
| Skip | 0 | none | the method's six at starter targets, the banner | as the method | the phone's default level until the card |
| I forget | | | | | the evening reminder at 20:00 (essential) |
| Portions and amounts | | | | the amount checks at the variant bar | |
| Eating out | | | the bar's photo hint; the tour leads with the photo | | |
| It takes too long | | | | "Save as a usual" on until three exist | |
| Right after I eat / When I sit back down / Before bed / My own moment | | | the Action button card's sentence | | the two consistency checks at 11:30 and 20:00 / 12:30 and 20:00 / none and 20:30 / unchanged; the late-morning check's words |
| Only when slipping / Coach me / Nothing | | | the card leaves | | one essential touch a day / the full catalog, two a day / nothing, and the system prompt never |
| A focus metric | | | one more tile | | |

Nothing in the table is a sentence that changes by who the person is.

### 6.8 The copy, every line that changes

| Where | Before | After |
|---|---|---|
| Welcome pill | Choose how I track | Make it mine |
| Welcome, new | | Skip the questions |
| Gate title, skip path | Save your protocol | Keep your log |
| Gate line, both paths | One tap. We ask for nothing else - no email lists, no password to forget. | questions: One tap. We ask for nothing else: no email lists, no password to forget. / skip: One tap, and every meal you say is yours to keep. No email lists, no password to forget. |
| Starter banner line | These numbers aren't yours yet. Build your protocol from your own stats. | Add your height, weight and age and the numbers become yours. |
| Voice card title, new | | How much should Vo-Cal say? |
| Chooser, the method | Calories, protein, produce, fiber, water / The five things the method tracks. | Calories, protein, fat, produce, fiber, water / The six things the method tracks. |
| Settings short label | The five | The method |
| Reveal, building, the method and the plan | Placing your deficit · scaling protein, water & fiber | Setting your calories · scaling protein, fat, water & fiber |
| Reveal, building | Placing your deficit (every goal) | Placing your deficit · Setting your maintenance calories · Placing your surplus, by the goal (Section 8, A1) |
| Goal screen, the card for a cut | A steady, livable pace. Fast enough to see it, slow enough to keep it. We won't crash your calories. | (cut: the pace screen says the one sentence, once; A5) |
| Stress screen, support | habits: Stressful weeks get gentler reminders. / numeric: A stressful week earns a lighter, more livable deficit. | cut: A stressful week earns a gentler deficit. / otherwise none (nothing true to say; A2) |
| The pace screen | Why Vo-Cal / Losing 17 lb is a realistic target. / Small daily deficits are the kind people keep. ... | Your pace / From 172 to 155 lb, at a steady pace. (the goal decides the verb) / Nothing here is extreme, so nothing has to be undone. (A3, A4, A5, A18) |
| The ruler's line | Losing 17 lb is a realistic target. You can absolutely do this. | 17 lb to lose: from 172 to 155 lb. (A4) |
| Reveal pill | Save & start logging | Save my protocol / Save my habits / Build my meal plan (A7) |
| Health step | Connect Apple Health (title and pill); ... Reminders fit around them. | Apple Health / Connect; the line ends at "never sent." (A17) |
| What's New | the release's rows | one row for the six, one for the door, one for the card |

### 6.9 The states, enumerated and decided

- **The welcome, both doors**: the pill and the text door are each one tap; Reduce Motion changes
  nothing (no animation on this screen); at the largest Dynamic Type the text door wraps to two
  lines under the caption and stays above the home indicator.
- **Skip, then the gate fails**: the honest message as today; the person is not returned to the
  welcome.
- **Skip on the sim**: the mock path lands on Today with the method's six and the canned day.
- **Skip, then "Make it mine" later**: Settings → How I track holds the three questions; Settings →
  My details holds the basics and builds the protocol; the banner leads there.
- **The card, nothing tapped**: it waits, above the meals, every day, until answered. It is the one
  surface allowed to wait, because every answer is a setting. It never fires a notification.
- **The card, a tap that did not land**: the row stays unticked, the one line says so, the system
  sheet is not shown.
- **The card and "Nothing"**: the card goes; no sheet; Settings → Notifications' Delivery row says
  "Not asked" (S7).
- **The card for a person who chose at onboarding before this build**: never shown; the permission
  card of decision 67 shows as before.
- **Two people on one phone**: the level is the account's (the preference), the card follows the
  account.
- **The method's six for a tester who chose the five on build 32**: the fat tile appears on the
  next load of Today; the chooser's row they ticked reads the new title; nothing else moves.
- **A server one deploy behind the phone**: the phone's composer twin draws the six; a server
  ahead of a build-32 phone sends six panels and the phone draws them (it draws any metric tile).
- **Fat on an empty day**: a tile at zero like the others, no red.
- **The longest string**: the chooser's title wraps to two lines at the default size, as the list
  of five did.

### 6.10 The claim audit

The welcome promises three minutes and no account, both true for the offer; the skip promises
nothing. "Keep your log" names what the account keeps. The banner names the three inputs that make
the numbers the person's and nothing else happens on that tap but the page where they are entered.
The card's three support lines are the engine's promises verbatim; "Nothing" never shows the
system sheet; the card leaves only on the echo. The chooser's list is the list of tiles. "The six
things the method tracks" is six tiles and six reveal rows. No surface says a skipper chose.

### 6.11 The restoration check

Did the passes remove any function without replacing it? The voice question left the intake and
carried the feeling of being asked how one wants to be spoken to; it returns at the first log, in
the same sentences, at the moment the answer means something, which is a better place for that
feeling, not a lesser one. The permission card's sentence ("You asked for ...") carried the warmth
of being remembered; for the people it still serves it stays, and for new people the card carries
the warmth of being asked. The welcome's pill named the first question ("Choose how I track") and
now names the whole offer; nothing is lost. The five's label was a list and stays a list. Did the
design get quieter and better, or only quieter? Better: a person who wants nothing asked gets
nothing asked and a working app; a person in the method's mode sees the number Francesco says
matters most for half his clients; and the app asks one question fewer before it has earned any.

### 6.12 Evidence

None yet. Before and after, at real size: the render loop's goldens for the welcome, the method's
Today (populated and empty), the method's reveal, the card after the first log, Settings → How I
track with the six; the first run on the pinned simulator through the skip and through each mode;
and the only evidence that counts, the beta's numbers by answer (`scripts/beta-metrics` already
counts never chosen). No claim of improvement without them.

---

## 7. The ship gate

1. **Purpose.** A person who wants it theirs gets three questions; a person who does not gets a
   working app. Serve both or do not ship.
2. **Honesty.** The method's label is its contents. The skipper is never told the starter numbers
   are theirs. "Nothing" never prompts. The card leaves only on the echo.
3. **Butler.** The card after the first log is the one surface that speaks first about the
   person's setup, once, inside the app they opened. Nothing else new speaks.
4. **Order.** Strip the text door's words: does the layout alone say there are two doors? (Expected
   no; the words stay.) Strip the fat tile's title: do the colour and the position say "fat"?
   (Expected yes among the macros; the title stays because the other tiles have one.)
5. **Register.** No engine word on a new line: no "level", no "stub", no "default" in a slot the
   person reads; "starter targets" is the person's phrase already on the page.
6. **Detail.** The states of 6.9, each drawn.
7. **Year five.** A seventh thing in the method's mode is one row in the projection's two tables,
   one tile, one reveal row, and the label's list; the wire token never moves. A skipper's record is
   indistinguishable from a never-asked record, which is the truth.
8. **Resources.** Nothing added that nobody needs: no screen for the skip, no row for it, no glyph
   on the doors, no count on the welcome.
9. **Subtraction.** What can still come out: the caption under the pill, if the two doors teach the
   cost alone; the card's title, if the three rows teach the question alone (expected no).
10. **Restoration.** Section 6.11, re-read after the build, not before.

"Have I succeeded in improving things? Making them better than others did? Is my design good
design?" (I06, Boston, October 1984, archive 1.1.5.1)

---

## 8. The audit of the rest of the app (the owner's "every aspect")

Run on the same day over every screen the person reads and every sentence the server writes, with
the same rules. What was fixed in this build is listed with its commit; what is a decided thing is
OPEN for the owner with the recommendation. See the section's table, filled in by the build.

Four audits, read in code the same day, over the screens and the server's sentences: the first
run (A), Today with Settings, the check-in, the week and the meal plan (B), every sentence the
server writes and mode obedience (C), the voice log, the result and the bar (D). Each row is one
finding with its class, its provenance (DECIDED is the owner's to reopen; INHERITED is a builder's
fix) and what became of it in this build. The owner's items are gathered in
`docs/restructure/05-questions.md`, 14 to 22, with the recommendation for each.

### 8.1 The first run

| | Finding | Class | Provenance | Outcome |
|---|---|---|---|---|
| A1 | "Placing your deficit" while building, for a person who maintains or gains | structural | inherited | FIXED: the line follows the goal |
| A2 | The stress line promised reminders that read the answer; false for maintain and gain | structural | decided (the onboarding spec 6.6) | FIXED the words (the line only for a cut); the habits screen is OPEN (ledger 16) |
| A3 | The ruler before the goal: "Losing 17 lb" over a maintenance protocol | structural | decided (69) | FIXED the pace screen (the goal decides the verb, the ruler's line states facts); the order is OPEN (ledger 17) |
| A4 | "a realistic target", "You can absolutely do this", "a great goal" | material | inherited | FIXED: the facts |
| A5 | One sentence on three screens; a gold-filled card forking by answer | material | inherited | FIXED: the goal screen's card cut; the pace line true for every goal |
| A6 | The reveal's chips printing the enum ("Trains light") | material | inherited | FIXED: "Light training" |
| A7 | "Save & start logging", two screens from logging | material | inherited | FIXED: "Save my protocol", "Save my habits" |
| A8 | The Action button card on every phone | material | inherited | FIXED: only on a phone with the button |
| A9 | "One press and it is listening." | material | inherited | FIXED: "One press opens the voice log." |
| A10 | The gate's hyphen and "nothing else" before the Health ask | material | inherited | FIXED |
| A11 | The sign-in error in the protein red | material | inherited | FIXED: the alert red |
| A12 | The reveal's failed state: one button that fails again | material | inherited | FIXED: "Back to my answers", "You're offline" |
| A13 | No selected trait on `ChoiceList`; the logo and the lock read aloud | material | inherited | FIXED (the ruler already carried a value and an adjustable action) |
| A14 | Six title sizes outside the theme; nothing scales | material | open (Q12) | OPEN (ledger 15) |
| A15 | The reveal's fallback keys with calories, whatever the mode | fine | inherited | FIXED: the fallback follows the mode |
| A16 | "Your check-ins follow it." (one word for two things); "Ten seconds" unmeasured | fine | inherited | FIXED |
| A17 | The Health step: one title twice, a 76 pt gold flame, a promise to the quiet | fine | inherited | FIXED |
| A18 | The eyebrow "Why Vo-Cal" | fine | inherited | FIXED: "Your pace" |
| A19 | Two disclaimers for one meaning | fine | inherited | FIXED: the canonical sentence |
| A20 | "Physical / manual work" | fine | inherited | FIXED |
| A21 | Off-scale spacing and radii in the ports | fine | inherited (ports) | OPEN (ledger 18) |
| A22 | The system progress bar's grey track; the tour's raw scrim | fine | inherited | FIXED the bar (`OnboardingProgressBar`); the scrim joins ledger 18 |
| A23 | "About 3 minutes", a duration nobody measured | fine | inherited | FIXED: "A few minutes" |
| A24 | The tour's "Your plan: your targets and settings" | fine | inherited | FIXED: "Settings" |
| A25 | "Your food log and voice stay private to your account." above proof | fine | inherited | FIXED: cut |

### 8.2 Today, Settings, the check-in, the week, the meal plan

| | Finding | Class | Provenance | Outcome |
|---|---|---|---|---|
| B1 | The meal editor opens a page of numbers in habits mode | structural | inherited | FIXED: never opens there; the flags say what is true |
| B2 | Five cards speak first on Today with no arbitration | structural | inherited | FIXED: one at a time, in a fixed order; the recalibration card's decline is OPEN (ledger 19) |
| B3 | Dynamic Type | structural | open (Q12) | OPEN (ledger 15) |
| B4 | Writes and loads blame the connection for a refusal | material | inherited | FIXED for every write (one rule); loads OPEN (ledger 22) |
| B5 | "rule-derived ... rail-bounded" | material | inherited | FIXED: the canonical sentence |
| B6 | The certainty statistic on the check-in and Progress; "avg", "kcal" | material | decided (DESIGN.md §6) | the words FIXED; the statistic OPEN (ledger 14) |
| B7 | "Go over or under ... Vo-Cal adjusts" against decision 54 | material | inherited | FIXED |
| B8 | Kilogram headlines after a pounds form | material | inherited | FIXED on the server (C4) |
| B9 | "Estimate. Tap to confirm" | material | inherited | FIXED: "Counted at a typical amount" |
| B10 | The Progress chip's gold for a drop, whatever the goal | material | inherited | FIXED: one fill |
| B11 | Rows and buttons without traits or labels; the 1 to 5 scale; the week's drag | material | inherited | FIXED the rows, the close buttons, the trash, the scale; the drag's adjustable action joins ledger 18 |
| B12 | The profile editor's options drifted from the intake | material | inherited | FIXED: one table (`IntakeOptions`) |
| B13 | The sparkle on "Build it for me" | material | inherited | FIXED |
| B14 | "Season's changed?", "today's you" | material | inherited | FIXED |
| B15 | Fiber in the completion green; water in a token outside the table | fine | decided (the 2026-06 mapping) | FIXED: muted, as the reveal draws them |
| B16 | Gold as a fill on five cards | fine | inherited | FIXED: the glass card or the card tone |
| B17 | "Nudges", "coaching" in the person's slot | fine | inherited | FIXED |
| B18 | "Thinking it through…" | fine | inherited | FIXED: "Working out your week…" |
| B19 | The week's labels: gold over a red bar | fine | inherited | FIXED the colour; the compact figure stays for the space under a bar |
| B20 | The delete footer restating the alert | fine | inherited | FIXED: cut |
| B21 | The week card blank when the week failed to load | fine | inherited | FIXED: one line and Try again |
| B22 | "Save plan" twice; "Profile" | fine | inherited | FIXED: "Save my week", "Settings" |
| B23 | Off-scale constants | fine | inherited | OPEN (ledger 18) |
| B24 | The generator's system tint and spinner | fine | inherited | FIXED |
| B25 | Glyphs beside the check-in's lines; a seal | fine | inherited | FIXED |

### 8.3 The server's words and mode obedience

| | Finding | Class | Provenance | Outcome |
|---|---|---|---|---|
| C1 | A habits person told "no numbers" about the water tile their page prints | structural | inherited | FIXED: water and produce answered; the line stops at the fact (72) |
| C2 | "We step the deficit down one notch" for a deeper cut; "you did the work" | material | decided branch (64), inherited words | FIXED the words |
| C3 | The diagnostics' verdict ("actually", "honest questions", "wasn't fully executed") | material | same | FIXED |
| C4 | Kilograms in the headlines | material | inherited | FIXED: the person's unit |
| C5 | "tighten consistency" | material | inherited | FIXED |
| C6 | An evening reminder named that does not exist for most people | material | inherited | FIXED: named only where it exists |
| C7 | Pointers to a week card or a plan row the mode lacks | material | inherited | FIXED |
| C8 | `/meals/summary` printing an average to a mode without numbers | material | inherited | FIXED |
| C9 | The whys' units and labels ("kcal", "Very High activity", "home dashboard", "We scaffold") | material | inherited | FIXED |
| C10 | "priced" in the result's assumptions | material | inherited | FIXED: "counted" |
| C11 | "Protein is the one number most people add first." | material | inherited | FIXED |
| C12 | "A rough week by your own account" | material | decided (69) words | FIXED the words |
| C13 | "you'll land right in your band" | material | inherited | FIXED |
| C14 | "held at maintenance for maintenance" | fine | inherited | FIXED |
| C15 | A number re-derived in the why layer | fine | inherited | FIXED: `protein_min_g` is a fact |
| C16 | "a flat month" asserted unmeasured | fine | inherited | FIXED |
| C17 | The server's one "I" | fine | inherited | FIXED |
| C18 | Menu titles as a sentence's object | fine | inherited | FIXED |
| C19 | The behavior-change spec's stale table cell | docs | decided | FIXED |

### 8.4 The voice log, the result, the bar

| | Finding | Class | Provenance | Outcome |
|---|---|---|---|---|
| D1 | "Resume" did nothing in the blocked state | structural | inherited | FIXED: Open Settings, or Try again |
| D2 | Try again dropped a typed or photographed log; "Your audio is safe" with no audio | structural | inherited | FIXED |
| D3 | "Log anyway (typical values)" never logged | structural | the labels decided (the tracker spec 6.5) | FIXED the label ("Use typical amounts"); one pill OPEN (ledger 20) |
| D4 | How sure, five times, two scales | structural | the badge decided | FIXED the card, the receipt and the sheet; the header badge OPEN (ledger 14) |
| D5 | Habits leaks: the working line, the checks' line, the coaching note | material | inherited | FIXED |
| D6 | One number, two precisions | material | inherited | FIXED on the pill and the receipt; the item cards keep the bare figure (joins ledger 14) |
| D7 | The confident zero | material | inherited | FIXED: "Not counted yet" |
| D8 | A usual saved unseen | material | inherited | FIXED |
| D9 | Two voices, five hyphens | material | inherited | FIXED |
| D10 | "we'll keep working" | material | inherited | FIXED: cut |
| D11 | The receipt vanishing in 1.4 s | material | inherited | FIXED: Done is the one control |
| D12 | "Saved - analyzing…"; the tag's gap | material | inherited | FIXED the line; the gap OPEN (ledger 21) |
| D13 | Three controls for one edit; a second Close | material | inherited | FIXED (the Edit button, the failure surface's Close); the answer's Close stays with decision 71 |
| D14 | A success haptic on a local swap | material | inherited | FIXED: the select tick |
| D15 | Variant keys raw on the card | fine | inherited | FIXED the card; the edit sheet's "Unspecified" chip joins ledger 18 |
| D16 | Glyphs and gold with no job | fine | inherited | FIXED: the seal, the crosshair, the instructions |
| D17 | "Enhancing your log" as the VoiceOver label; Reduce Motion | fine | inherited | FIXED the label; the motion OPEN (ledger 21) |
| D18 | Off-token literals in the bar and the sheets | fine | partly decided (the bar) | OPEN (ledger 18) |
| D19 | Fields and the mic without labels | fine | inherited | FIXED |
| D20 | Dynamic Type | fine | open | OPEN (ledger 15) |

### 8.5 What holds, across the four

The claim ladder's words from the one state that licenses them; the mode governing every printed
number (one surface slipped, B1, and is closed); one progress language on Today; no exclamation
mark, streak or grade anywhere; every empty state naming the gesture that fills it; the catalog's
messages under the anatomy rule; `meals/guidance.py` and the numbers-free check-in; the bar's one
spring and its labels. "Have I succeeded in improving things?" The question is the owner's to
answer on the pinned simulator (Section 6.12); the inventory above is what was changed so he can.
