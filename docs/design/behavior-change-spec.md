# Behavior change, end to end, designed under the Rams audit (REVIEW, then DIETERIFY)

Date: 2026-10-04. Mode: **REVIEW** of Lorenzo's ask the same evening ("apply the magic and
literature of behavioral science here, end to end, to really help make coaching and behavior
change superpowered"), then **DIETERIFY** applied to it. The protocol is Lorenzo's Rams brain
(`Agents/Dieter Rams Brain/AUDIT-PROTOCOL.md` in the MyLife vault, built 2026-09-23); the earlier
runs are `docs/restructure/06-rams-audit.md`, `docs/design/personalized-tracker-spec.md`,
`docs/design/onboarding-that-asks-spec.md` and `docs/design/nudges-that-reach-spec.md`. Quotation
marks plus a tag (W01, W02, T01, T02, I06) are Rams verbatim from the sources the protocol carries;
everything else is applied reading and is labelled inference. Two more sources are read as sources,
not as Rams: Lorenzo's own nudge philosophy (`Projects/Serein/Harness/rules/nudge-philosophy.md`
and `Nudges/Nudge-Policy.md`, tagged V) and his Journey nudge-writer skill (tagged J). The
literature is cited by author and year; the evidence grade after each is this review's reading of
it (strong: several randomized trials or a meta-analysis; moderate: field data or a few
experiments; weak: a lab finding or a popular book's claim), so that nobody builds a feature on a
grade it does not have.

The screen-by-screen review that accompanies this spec is a canvas, one artboard per screen with
the finding beside it: the Rams review on Lorenzo's claude.ai (the link is in the handoff and the
PR). This file is the written half: the gate, the findings, the mechanisms, the corrected design.

---

## 1. Intake

- **Purpose sentence (the builder's):** a person says what they ate and trusts the number that
  comes back; a person who chose their way sees only their way; a reminder reaches them only when
  it is theirs. The ask adds a fourth clause: the app helps them keep doing it, and get better at
  it, for years.
- **The person.** The concierge beta's few testers, Lorenzo and Francesco's clients; imagined more
  than met. Findings about need rank below findings about internal consistency.
- **The room.** A phone between meals; every other app's notifications already spent; a coach
  (Francesco) present for some people and absent for most; a kitchen, a restaurant, a desk. The
  behavior the app asks for takes ten seconds and happens three to five times a day.
- **The system.** The intake (mode, voice, frictions, basics, goal, real life, training, hunger,
  stress, meals), the reveal, Today composed per mode, the voice log and its result, the nudge
  engine with its reactions and its clock, the weekly check-in, the week budget, the monthly
  recalibration, the meal plan, Settings. Every one of these already exists; this review asks what
  the literature says each should do, and whether the words and the order say it.
- **The frame of the feasible.** Deterministic engine; copy final in the catalog (decision 67);
  additive wire; migrations through Deploy; no social, no gamification, no generated text per
  person; Health on the phone only. Build 31 must decode everything unchanged.
- **Artifacts seen.** Every Swift view and every API string, read in code; the mock day on paper
  (2,040 kcal plan, four meals); the canvas drawn from them. No device. A finding about a
  gesture under a thumb is marked as such.
- **Lifespan.** Years. Behavior change is measured in months; the design must still be right when
  the person has logged two thousand meals.
- **Provenance.** The structure was decided (decisions 56 to 67, the same day). The nudge copy
  was inherited from the legacy bank and ported (decision 63). Inherited words get a different
  recommendation from decided ones: rewrite, do not re-decide.

## 2. The necessity gate (the decisive questions for consumer software: 5, 7, 9, 12, 14; for AI
products: 7, 8, 9, 12)

**Q2, necessary?** "Is the product that we are designing really necessary? Are there not already
other, similar, tried and tested appliances that people have got used to and are good and
functional?" (I06). The incumbents for behavior change in food tracking are the streak
(MyFitnessPal, Duolingo's grammar), the badge, the coach-in-a-chat (Noom), and the notification
that fires at 7 pm for everyone. All four exist and all four are tried. What is not done: a
tracker whose coaching follows the person's stated way (how much to say, what gets in the way,
when they log), whose reminders answer back, and whose lapse handling is designed from the lapse
literature instead of from loss aversion. That is the only thing worth building here, and it is
mostly a matter of words and order on a structure that already exists.

**Q3, enrich or covet?** Streaks, badges and counts appeal to covetousness and to the fear of
loss; the literature on them is a literature of disengagement after the first break (the
"what-the-hell" effect, below). They stay out. What enriches: the person's own record, their own
words returned, a plan they can keep on a bad week.

**Q7, free or dependent?** "Does it help people or incapacitate them? Does it make them more free
or more dependent?" (I06). The test for every mechanism below: does the person end the month
better at eating without the app than they began it? Self-monitoring teaches portion sense and
pattern sense (the one skill the literature says transfers). A nudge that commands teaches
nothing; an invitation that names the fact leaves the judgment with the person.

**Q8, so perfect it humiliates?** An engine that knows the person skipped lunch, slept four hours
and trained at 16:40 could speak like it knows better. It must not. The engine computes; the
person decides; the words are inquiry (V, "the system never decides alone").

**Q12, convenience or passivity?** Voice logging removes the effort that killed food diaries
(Burke 2011 names burden as the first reason people stop). The effort that stays is the one that
changes behavior: saying it out loud, reading the number, the weekly look back. Nothing below
removes those.

**Q14, simpler on the whole?** One new question at intake (when you log) and one new question at
the check-in (what got in the way), each replacing a reminder that would otherwise fire at the
wrong hour or a lapse that would otherwise go unexamined. The whole path gets simpler: fewer wrong
nudges, one fewer silent failure.

**Q15, curiosity?** The reveal's whys and the week card already invite the person to understand
the engine. The mirror (their own words back) is the one addition that invites them to understand
themselves.

## 3. What holds (the behavioral structure is already right)

- **Self-monitoring is the intervention, and the app is built around making it cheap.** Burke,
  Wang and Sevick (2011), systematic review: consistent dietary self-monitoring is the strongest
  behavioral predictor of weight loss; Hollis et al. (2008): food records roughly doubled loss;
  Peterson et al. (2014): consistency of monitoring beats intensity (strong). Vo-Cal's purpose
  sentence is this finding. Every mechanism below serves the frequency and consistency of one
  ten-second act. "Good design makes a product useful" (W02).
- **Autonomy at every decision.** Deci and Ryan's self-determination theory; Williams et al.
  (1996): autonomy support predicts weight loss and its maintenance; Teixeira et al. (2012),
  review (strong). The person chooses the mode, how much the app says, what gets in the way; the
  ladder is an invitation with a permanent decline; the recalibration is applied by the person.
  No answer is named back as a kind of person (decision 66). "Their design should therefore be
  both neutral and restrained, to leave room for the user's self-expression." (I06)
- **Flexible, not rigid, restraint.** Westenhoefer, Stunkard and Pudel (1999): flexible control
  of eating predicts success; rigid control predicts disinhibition and weight gain (strong,
  observational and experimental). The treat with headroom, the plan as "a shape for the day, not
  a score", the habits mode with no numbers at all, the week budget that lets a Saturday be heavy:
  all flexible restraint by design. No streak exists to break (decision 48, no gamification).
- **No fear, no shame.** Witte's extended parallel process model (1992): a threat without
  efficacy produces defense, not action; Adams and Leary (2007): self-compassion after a lapse
  reduces subsequent overeating (moderate). "under-eating stalls progress too" carries its
  efficacy ("Anything you haven't logged yet?"); the recovery nudge says "Today is a fresh page";
  the plan's nudge says "A day that strays from it is still a day you logged". Nothing in the
  catalog threatens.
- **Prompts at the person's level, in their own slot, answering back.** Fogg's behavior model
  (B = MAP; a prompt lands only where motivation and ability cross): the nudge after a log, when
  ability is highest; the lock screen's "Log it" that removes the steps; the level the person
  chose (decision 66); three dismissals and the nudge retires (decision 67; V, "retire after
  three non-responses"). Brehm's reactance theory (1966): a command invites the opposite; the
  invitation form is the design's answer (V, "question not command").
- **The lapse is examined before the plan is cut.** Francesco's "diagnostics before a cut"
  (decision 64) is Marlatt and Gordon's relapse prevention (1985) in a nutritionist's words: look
  at what happened, then change the plan. "Before we change anything, let's look at what actually
  happened." holds as it stands.
- **The body is a clock, never a trigger.** Forman et al. (2017), ecological momentary
  assessment of dietary lapses: lapses cluster in the evening, with negative affect, tiredness,
  social eating and seeing food (moderate). The engine's evening fires (19:00 headroom, 20:00
  unlogged) sit where the lapses are; the body clock holds them before 21:00; nothing about a
  night or a workout leaves the phone.

## 4. Findings against the ask, structural first

### [B1] REVISE · structural · The plan is made once at intake and never revisited

**WHAT IT IS.** The intake asks what gets in the way (decision 66) and each answer moves one
thing. Nothing asks again. The weekly check-in asks weight, hunger, energy, a self-rated adherence
from 1 to 5 and a note; the answers feed the stress signal and the monthly titration. A person
whose trouble changes (they start eating out; the baby arrives) keeps the first week's moves for
a year.

**WHAT HE SAYS.** "I had in my mind always thinking not on one of blance alone always thinking
how can I add something and uh especially developing manager that people could change them they
could add something after using them" (T01).

**WHAT FOLLOWS (inference).** Schwarzer's health action process approach (HAPA, 1992; 2008)
separates action planning from coping planning and names recovery self-efficacy as the thing that
decides whether a lapse ends the attempt (strong on planning: Sniehotta et al. 2005 and 2006;
moderate on recovery). The intake's frictions are coping plans made once, in a cold state, before
the first week. The lapse literature (Marlatt) and HAPA both say the plan is remade after the
lapse, from what actually got in the way. The check-in is the moment, and it already exists; it
only lacks the question.

**THE MOVE.** The weekly check-in asks "What got in the way this week?" with the same four
answers as the intake (any or none) and writes them to the preference (`PUT /tracking`,
`frictions`), so the next week's moves follow the last week's trouble. One question, no new
vocabulary, the one-thing-each rule intact. The self-rated adherence row is reworded from a grade
to a description (6.8). What not to do: a free-text "why" (nothing to type at a check-in), a
score, a diagnosis.

### [B2] REVISE · structural · The consistency reminders fire at the maker's hour, not the person's

**WHAT IT IS.** "Nothing logged yet today" fires at 11:30 for everyone with nothing logged;
"Anything from today still unlogged?" at 20:00 for those who said they forget. A person who logs
their whole day before bed gets the 11:30 nudge every day, correct and wrong.

**WHAT HE SAYS.** "Indifference towards people and the reality in which they live is actually
the one and only cardinal sin in design." (I06)

**WHAT FOLLOWS (inference).** Gollwitzer (1999) and Gollwitzer and Sheeran (2006), meta-analysis
of 94 studies, d = 0.65: an "if [cue], then [action]" plan roughly doubles the chance the action
follows, because the cue does the remembering (strong); Adriaanse et al. (2011): the effect holds
for eating (strong). Fogg's anchor and Wood and Neal's context cues (Lally et al. 2010, median 66
days to automaticity; one missed day does not matter) say the cue must be one that already
happens. The app has the perfect cue in hand, the Action button, and no idea when the person
means to press it. The 11:30 nudge for the before-bed logger is the vault's Italy nudge
(technically correct, emotionally wrong; V); one of those and the person stops reading the rest.

**THE MOVE.** One more intake screen after the frictions: "When will you log?" with four answers,
each a moment that already happens: Right after I eat · When I sit back down · All at once,
before bed · I'll find my own moment. Stored as `log_anchor` on the preference. The engine moves
the consistency fires to the anchor: the before-bed logger never sees the late-morning nudge and
their evening check comes at 20:30, after dinner; the after-eating logger keeps 11:30. The
reminder's words name the person's own plan back ("You said right after you eat."), the mirror
pattern (J), deterministic: one catalog message per anchor, nothing generated. The Action button
setup card says the same sentence. What not to do: ask for a time of day (a clock is not a cue),
or let the anchor change the budgets.

### [B3] REVISE · material · The obstacle is asked before the outcome is imagined

**WHAT IT IS.** The intake's order: mode, how much to say, what gets in the way, the basics, the
desired weight, the goal, the realistic-pace screen, real life, training, momentum, hunger,
stress, meals, long-term results.

**WHAT HE SAYS.** "All objects that are to be used must be subject to a clear order." (W01)

**WHAT FOLLOWS (inference).** Oettingen's mental contrasting with implementation intentions
(MCII, or WOOP: wish, outcome, obstacle, plan): naming the obstacle after vividly imagining the
outcome produces the commitment; naming it before produces nothing (Oettingen 2012, review;
Stadler, Oettingen and Gollwitzer 2010: MCII doubled fruit and vegetable intake over two years;
strong). The intake is WOOP-shaped already (the goal is the wish, the realistic-pace screen with
the person's own numbers is the outcome, the frictions are the obstacle, the moves are the plan)
with the obstacle in the wrong place.

**THE MOVE.** Reorder: mode, the basics, the desired weight, the goal, the realistic pace (the
outcome, in their numbers), then what gets in the way, when you log, how much to say; then real
life, training, hunger, stress, meals. Habits mode, which has no goal screen: mode, basics, real
life, then the three. No screen is added or removed by this finding; the progress bar's total is
the same. What not to do: a "picture your success" screen (the outcome is their own numbers, not a
stock image).

### [B4] REVISE · material · The nudges' words are the legacy bank's, not the design's

**WHAT IT IS.** Fourteen catalog messages ported from the old bank (decision 63). "Welcome back!"
"Good news: you've got comfortable room left today." "Nicely played." "Feeling snacky? Boost your
fiber!" "Water check: you're under halfway". The pro tips are mostly good ("Keep a filled bottle
where you work. Proximity does the remembering for you.").

**WHAT HE SAYS.** "The majority of products that we encounter in our day-to-day lives scream for
attention or try to impress us" (W01). "Indifference towards people and the reality in which they
live is actually the one and only cardinal sin in design." (I06)

**WHAT FOLLOWS (inference).** The vault's anatomy of a nudge is recognition, invitation, agency
(V), and its two tests are "technically correct and emotionally right" and "would the person feel
seen, or managed?" An exclamation mark is the maker's enthusiasm in the person's slot (the
register test, 6.11). "Feeling snacky?" diagnoses a state the engine cannot know, the exact
failure the vault names ("never diagnose; surface"). "Boost your fiber!" is a command; Brehm says a
command invites its opposite. "Nicely played" grades the person. Ogilvy, from Lorenzo's own
library: "The consumer is not a moron. She is your wife. Don't insult her intelligence." The
content underneath is right almost everywhere (the fresh page, the honest log, the planned
treat); the voice is wrong.

**THE MOVE.** The copy pass, one rule per line: recognition (the fact the engine has), invitation
(the door), agency (the person's call), in that order; no exclamation marks; no feeling the
engine did not measure; no grade; "you" and the fact, never "we" except where the method speaks
(the recalibration keeps the coach's "we", a real coach exists). Every message rewritten in the
corrected design below; the ids, triggers, slots and budgets do not move. What not to do:
generate per person (decision 67 stands), or add a second sentence.

### [B5] REVISE · material · The person's own words go in and never come back

**WHAT IT IS.** The check-in stores a note (`notes`, up to 2,000 characters). It is written once,
stored, exported, and read by nobody, the person included.

**WHAT HE SAYS.** "Can the product be used in other, perhaps playful, ways?" (I06, question 11).

**WHAT FOLLOWS (inference).** The vault's strongest pattern: "the best nudge you will ever write
takes someone's own words, spoken in a moment of clarity, and returns them at the exact moment
that person is most likely to forget them" (J, the mirror). Bandura's mastery experience (1977)
and the self-prediction effect say one's own stated intention is the most credible evidence one
can be shown (moderate). The engine cannot write a sentence per person (decision 67) but it can
return one the person wrote, verbatim, marked as theirs (the register test's second fix: mark it
visibly as the maker's or, here, as the person's).

**THE MOVE.** The next check-in opens with last week's note, in quotation marks, under "You
wrote last week". Nothing is generated; nothing is interpreted; the person reads their own
sentence before answering again. The note's prompt becomes a question worth answering a week
later: "Anything you want next week's you to read?" What not to do: summarize it, score it,
show it on Today.

### [B6] HOLDS · The result screen is the celebration, and nothing follows it

**WHAT IT IS.** "Logged" with the server row, the system success tick, the number, and no
request after it.

**WHAT FOLLOWS (inference).** Kahneman's peak-end rule (Fredrickson and Kahneman 1993) and
Fogg's "celebration" (Tiny Habits, 2019): the feeling at the end of the behavior is what the
brain keeps (moderate). The design already ends on the one honest claim and a haptic. Protect it:
no "Great job!", no confetti, no "rate this", no "add a photo?" after the receipt. The
save-as-a-usual toggle is a setting the person chose (decision 66), not a request. The pro tip on
the card and the usual's one-tap re-log are the ability side of Fogg's model, exactly where they
belong.

### [B7] CUT · fine · Two of the three benefit interstitials (S6, decided 2026-10-04)

**WHAT IT IS.** Realistic pace (the person's own numbers on a curve), momentum, long-term
results.

**WHAT FOLLOWS (inference).** HAPA's motivation phase needs one outcome expectancy the person
believes; MCII needs that outcome to be theirs. Realistic pace is both. Momentum and long-term
results are the maker's claims about people in general, which the person cannot check (principle
six). Taken (Lorenzo, 2026-10-04): the first stays, without "It's not hard at all!" and carrying
Momentum's one true sentence as its support line (the first week is water, fat shows from the
second); the two go. The intake is thirteen screens.

### [B8] OPEN · fine · The hero number's framing early in the day

**WHAT IT IS.** Today's hero is calories left (to-go) all day.

**WHAT FOLLOWS (inference).** Koo and Fishbach (2012), the small-area hypothesis: before the
midpoint, to-date framing motivates more; after it, to-go (moderate). The card prints both numbers
already. Whether the hero should flip at noon is a decision only a model can make (6.9): draw it,
show it on a device, decide. Not built here.

## 5. Diagnosis

The structure already carries the strong evidence: self-monitoring made cheap, autonomy at every
decision, flexible restraint, prompts at the person's level, lapses examined before plans are cut.
What is missing is the volitional bridge the literature calls planning: the when (the anchor),
the coping plan remade weekly (the check-in's question), the obstacle asked after the outcome
(the order), and the person's own words returned (the mirror). And the voice: the engine's rules
are the design's, the words are still the old bank's. Eight findings, one shape: **the engine
knows the science; the words and the order do not say it yet.**

## 6. The design, corrected (DIETERIFY passes applied)

### 6.1 Restated purpose

A person says what they ate and trusts the number that comes back, in the way they chose, with
reminders that are theirs, and the app helps them keep doing it: it asks when they will log and
reminds them in their own plan's words; it asks each week what got in the way and changes one
thing; it returns their own words to them; and it speaks, when it speaks, as someone who sees
them, never as someone who manages them.

### 6.2 The end-to-end map (HAPA's phases, the app's screens)

| Phase | Screen | Mechanism | Evidence |
|---|---|---|---|
| Motivation | Welcome, the mode | Autonomy: the way is chosen, nothing preselected | SDT (strong) |
| Motivation | Goal, realistic pace | Outcome expectancy in the person's own numbers; mental contrasting begins | HAPA, MCII (strong) |
| Volition: coping plan | What gets in the way | Obstacle after outcome; each answer one coping move | MCII, HAPA (strong) |
| Volition: action plan | When will you log (new) | If-then plan on a cue that already happens; the reminders follow it | Gollwitzer, Fogg anchor, Wood (strong) |
| Volition: delivery | How much should Vo-Cal say | The prompt's intensity is the person's | Fogg B=MAP, reactance (strong) |
| Action | The reveal | Competence: the whys; one line binds the plan to the one habit | SDT competence, Burke (strong) |
| Action | The Action button, the bar | The cue and the ten-second act; the first log in the first session | Fogg tiny first step (moderate) |
| Action | The result | Peak-end: the honest claim, the tick, nothing after | Kahneman, Fogg (moderate) |
| Action | Today | Immediate, specific feedback; the person's meals loudest | Self-monitoring (strong) |
| Maintenance | The nudges | Recognition, invitation, agency; retire after three; the body clock | V, Brehm, Forman (strong/moderate) |
| Maintenance | The treat with headroom, the week budget, the plan | Flexible restraint; cold-state planning for hot-state moments | Westenhoefer, Loewenstein (strong/moderate) |
| Recovery | Gone quiet | A day is a day, never a verdict; fresh start named when it is one | AVE (Marlatt), Lally, Milkman (strong/moderate) |
| Recovery | The check-in | What got in the way, remade weekly; last week's words returned | HAPA coping planning, mirror (strong/moderate) |
| Outcome | Recalibration | Diagnostics before a cut; the person applies | Marlatt, SDT (strong) |

### 6.3 The anchor (B2): one screen, four answers, what each moves

Eyebrow "When you log" · title "When will you log?" · support "Pick a moment that already
happens. The reminders follow it."

| Answer | Stored | The consistency fires | The reminder's words | The button card |
|---|---|---|---|---|
| Right after I eat | `after_eating` | late morning 11:30, evening 20:00 (unchanged) | "You said right after you eat. Anything since breakfast?" | "Hold it when you put the fork down." |
| When I sit back down | `when_seated` | late morning 12:30, evening 20:00 | "You said when you sit back down. Anything from this morning?" | "Hold it when you're back at your desk." |
| All at once, before bed | `before_bed` | no late-morning fire; evening 20:30 | "Your day in one go, before bed. A sentence covers it." | "Hold it before you turn in. Say the whole day." |
| I'll find my own moment | `own` | unchanged (11:30, 20:00) | the current words | the current words |

The engine's `_SLOT_FIRST` gains the anchor's say; the budgets, quiet hours and cooldowns do not
move. `tracking_preferences.log_anchor` (nullable text; null is "never asked", every account
from before). `experience_for` says what the anchor changes (`reminder_slots`), so the phone
arranges and never decides.

### 6.4 The check-in (B1, B5), corrected

Order: "You wrote last week" (the previous note, verbatim, quoted; absent when none) · weight ·
hunger · energy · "How close did the week feel to the plan?" (the same 1 to 5, reworded from a
grade) · "What got in the way this week?" (the four frictions, any or none; writes the
preference) · "Anything you want next week's you to read?" (the note). The lapse question's
support line: "Pick what fits. One thing changes for next week." Nothing else is added.

### 6.5 The intake's order (B3)

Numeric modes: mode · basics · desired weight · goal · realistic pace · what gets in the way ·
when you log · how much to say · real life · training · hunger · stress · meals (thirteen).
Habits: mode · basics · real life · what gets in the way · when you log · how much to say ·
training · stress · meals (nine). Momentum and Long-term results are gone (B7).

### 6.6 The nudges' words (B4): every message, rewritten

One rule for all fourteen: recognition, invitation, agency. The fact first, then the door, then
nothing that takes the choice. No exclamation marks. No feeling the engine did not measure. No
grade. Pro tips keep their job (the how) and lose their cheer.

| id | Before | After |
|---|---|---|
| gone_quiet | Welcome back! No need to catch up on missed days. Today is a fresh page. One logged meal puts you right back in rhythm. | A few quiet days. Nothing to catch up on; today is its own page. One logged meal and you're back in it. |
| gone_quiet, on a Monday or the first of the month | (none) | New week, clean page. One logged meal and you're back in it. |
| stress_slipping | Stressful stretch, and it's early in the week. Keep it light: repeat a day you tracked well, or log one meal and call it a day. | A rough week by your own account, and it's early. Keep it light: repeat a day you tracked well, or log one meal and call it a day. |
| mid_week_slipping | The week is thin so far. Repeat a day you tracked well: the same meals, one log each. No thinking required, still tracking. | Two days logged so far this week. Repeat a day you tracked well: the same meals, one log each. |
| no_log_today | Nothing logged yet today. A ten-second voice note keeps the day honest. Just say what you had; we'll do the math. | Nothing logged yet today. Ten seconds covers it: say what you had, the math is done for you. |
| evening_unlogged | Anything from today still unlogged? A sentence now keeps the day whole. | Anything from today still unlogged? A sentence now keeps the day whole. (holds) |
| treat_headroom | Good news: you've got comfortable room left today. If you've been eyeing a treat, tonight fits your plan. Enjoy it, log it, no guilt. | Comfortable room left today. If a treat is on your mind, tonight fits the plan. Have it, log it. |
| protein_gap | You're a bit light on protein so far, and dinner is a great place to close the gap. Chicken, fish, Greek yogurt, or tofu all get you there fast. | Protein is light so far. Dinner can close most of the gap: chicken, fish, Greek yogurt or tofu. |
| hydration_low | Water check: you're under halfway to today's goal. A glass now and one with each meal quietly gets you the rest of the way. | Under halfway on water. A glass now and one with each meal gets you the rest of the way. |
| under_target | You're well under target so far today, and under-eating stalls progress too. Anything you haven't logged yet? | Well under target so far today. Anything you haven't logged yet? The plan assumes you eat it. |
| produce_behind | Light on fruit and veg so far. A serving with your next meal gets you most of the way there. | Light on fruit and veg so far. A serving with your next meal gets you most of the way there. (holds) |
| plan_slot_open | A meal on your plan is still open. Log it when you have it; the plan is there tomorrow too. | A meal on your plan is still open. Log it when you have it; the plan is there tomorrow too. (holds) |
| fiber_boost | Feeling snacky? Boost your fiber! Foods like oats, beans, or an apple can help curb cravings while keeping you full longer. | Fiber is behind for the day. Oats, beans or an apple with your next meal carry it, and keep you full longer. |
| evening_on_track | You're closing the day right around your target. Nicely played. A light evening keeps it landed. | Closing the day right around your target. A light evening keeps it there. |

Pro tips: "Momentum beats perfection." stays; "Think of fiber as your hunger helper" becomes
"Pre-portioned trail mix, or washed fruit in the fridge, for the busy days."; "A treat that's
planned is a win, not a slip." becomes "A treat you planned is part of the plan. Say it like any
other food."; the rest hold.

The invitation cards (decision 62) already follow the anatomy ("You've logged 14 of the last 21
days. Want to see your calories too?"); they hold.

### 6.7 The reveal's one line (the habit the plan rests on)

Under the hero, above the rows, one line in the secondary face: "Everything here follows from
one habit: say what you eat." In habits mode: "Three things, every day. Say what you eat and
they count themselves." The line names the behavior the literature says matters most, at the
moment of highest motivation, and asks for nothing.

### 6.8 The states, enumerated and decided

- Anchor never asked (every account from before): `log_anchor` null; the engine's slots are
  today's; the reminder's words are today's. Settings → How I track gains "When you log" with the
  four answers, so the person can say it later.
- Anchor `own`: identical to null in the engine; stored because it is an answer.
- A person who changes the anchor at 19:00: the next plan (after the next log or the morning
  re-plan) moves the fires; nothing already scheduled is pulled early.
- Check-in with no previous note: the "You wrote last week" row is absent; no empty quotation.
- Previous note longer than four lines: shown whole, scrolling inside its card; never truncated
  with an ellipsis (it is the person's sentence).
- Check-in's lapse answers: none ticked is an answer and writes an empty list (the frictions
  clear); the preference's version increments; `experience` recomputes.
- Fresh-start variant: fires only when gone_quiet would fire and today is Monday or the first;
  shares gone_quiet's id (one ledger entry, one cooldown), only the words differ, chosen by the
  catalog's `variant_for(day)`; a server before it sends the plain words.
- Reorder of the intake: the progress bar's total is unchanged; Back walks the new order; the
  self-test and the flow tests that count steps are updated with the order.
- The catalog's new words: the parser corpus does not read them; `test_nudges_api.py` pins the
  anatomy (no "!" in any message, no "we" outside the recalibration, every message under 140
  characters so the lock screen shows it whole).

### 6.9 The claim audit

- "The reminders follow it" (the anchor screen): true for the two consistency fires only; the
  support line says "the reminders", which the person will read as all of them. Reworded: "Your
  check-ins follow it."
- "One thing changes for next week" (the check-in's lapse question): true by construction
  (decision 66's one-thing rule).
- "You wrote last week": true only when the note is from the previous check-in; a note from three
  weeks ago reads "You wrote on September 14".
- "the math is done for you" (no_log_today): the parser and the deterministic ladder do it; true.

### 6.10 The restoration check

Did the passes remove anything warm? The exclamation marks carried enthusiasm; the enthusiasm was
the maker's, and what replaces it is attention (the fact the engine has, named first), which is
warmer. "Nicely played" carried approval; approval from a tool is a grade, and the person keeps
the approval of the number itself. The pro tips keep their ease. Nothing came out that did not
go back in another place, and two things came in: the person's own words, returned, and a
question that proves the app listened.

### 6.11 What is refused, and why, so nobody adds it back

- **Streaks and counts of consecutive days.** The abstinence violation effect (Marlatt and
  Gordon 1985; Polivy and Herman's "what-the-hell" effect, 1985): a broken streak predicts the
  binge and the quit; Lally et al. (2010): one missed day does not slow habit formation, so a
  streak punishes what the data says is harmless. Principle five and 6.7 (users, not consumers).
- **Badges, levels, points, leaderboards, confetti.** Variable rewards (Eyal) and Deterding's
  gamification are consumption mechanics; the Rams filter names them. "there is little that can be
  exploited as easily and as profitably as bad taste" (I06).
- **Loss framing and fear appeals.** Witte: without efficacy they produce defense. The one
  loss-shaped line in the catalog carries its efficacy and stays.
- **Social proof, sharing, friends.** Out of scope by decision (MUST NOT 4). The person's own
  record is the only proof shown.
- **Generated coaching text.** Decision 67: copy is final in the catalog. The mirror returns the
  person's words; it writes none.
- **A per-day score or a weekly grade.** The engine knows the days logged; a grade of them is a
  verdict (V, "never a verdict").
- **Diagnosing a state.** "Feeling snacky?", "You seem stressed": the engine measures intake and
  the check-in's answers; it says what it measured and nothing it inferred about the person
  (V, the Italy failure).

### 6.12 Apple Health, the Serein way (Lorenzo, 2026-10-04: "incorporate HealthKit the same way you executed with Serein")

Serein's pattern, from the vault (`Harness/rules/privacy-first.md`, `Harness/commands/health.md`,
`Nudges/Nudge-Policy.md` Part III): read only, never written to; processed on the device, never
sent; surfaced only where directly relevant, never casually; one consent per integration, revocable;
and the designer's protective defaults, the sacred silences (the first hour after waking is
silent) and the ceilings (after depletion, surface less). Vo-Cal already reads active energy
(Today's burned figure), workouts and sleep (the body clock, decision 67). Three more moves, all
on the phone, nothing sent (decision 52):

- **The first hour after waking is silent for every fire**, not only the ones the engine marks
  `after_wake`: `NudgeFireTiming` moves any fire inside the hour after last night's end to the
  end of that hour. The engine's marker stays as the additive hint it is.
- **A short night holds the coaching.** When last night's asleep total is under six hours, the
  phone schedules only the essential fires that day and holds the coaching ones (protein, water,
  fiber, produce, the treat, the plan slot). The engine's plan is unchanged; the phone applies the
  designer's ceiling. Nothing on Today says "short night": health is not surfaced casually.
- **The week's steps on the check-in form**, beside the movement question the recommendation
  asks ("How much did you actually move this week?"): one line, "About 6,200 steps a day this
  week, by your phone.", from HealthKit's step count on the device; absent when Health is not
  connected or has no steps. It is shown, not sent; the recalibration's `avg_steps` stays None.
  The usage string and the App Store wording name the fourth read.

What is not done, by the same pattern: heart rate or HRV as a stress signal (a diagnosis the
engine would be making about the person; the check-in's own answers are the stress signal), a
health score, a sleep nudge, a step goal.

### 6.13 Evidence

None yet of behavior; the mechanisms are pinned where they can be: the anchor's slot table and
the catalog's anatomy (tests), the check-in's write to the preference (test), the mirror's
absent-and-present states (render tests). The rest is months on phones, which `scripts/beta-metrics`
will read by answer: days logged per week by anchor, by level, by friction; the share of nudges
answered with a log within the hour (`acted`) by message; the share of check-ins with a lapse
answer; and whether the people who got the fresh-start words came back sooner than those who did
not (the one A/B the catalog's variant permits without a flag).

---

## 7. The ship gate, pre-filled for the builder

1. **Purpose.** The person keeps saying what they eat, in their way, and gets better at it.
   Serve it or do not ship.
2. **Honesty.** "Your check-ins follow it." Nothing promised the engine does not do.
3. **Butler.** No new fire; two fires move to the person's hour. The budgets stand.
4. **Order.** Strip the words from the anchor screen: four rows of moments still read as a
   choice of when.
5. **Register.** No "!", no diagnosis, no grade, no "we" outside the method's own voice.
6. **Detail.** The states of 6.8, each exercised on a device.
7. **Year five.** A new anchor is a new row in one table; a new friction is one row and one
   move; a new check-in question is one field. The mirror needs nothing new.
8. **Resources.** One screen and one question added; fourteen messages shortened.
9. **Subtraction.** What can still come out: the two benefit screens (S6); the hunger question in
   habits mode (already out); the pro tip, if nobody opens it.
10. **Restoration.** Section 6.10, re-read after the build, not before.

"Have I succeeded in improving things? Making them better than others did? Is my design good
design?" (I06, Boston, October 1984, archive 1.1.5.1)
