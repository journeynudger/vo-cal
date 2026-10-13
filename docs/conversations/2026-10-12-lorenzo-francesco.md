# Lorenzo and Francesco, on the drive (transcript received 2026-10-12)

> **What this is.** A cleaned voice transcript Lorenzo pasted on 2026-10-12 with the note "this is
> kinda what we are looking to achieve". The conversation's own date isn't in the source.
> **Speakers** are attributed from what each one says: Francesco is the coach with the clients and
> the check-in agent; Lorenzo built Vo-Cal and its food database. The source had no labels, so a few
> attributions are a best reading; those are marked *(attribution uncertain)*.
> **Cleaning.** Filler, false starts and repeats are cut. Profanity is softened. Cut passages are
> marked [...]: the driving asides (directions, Siri, a speed camera) and a side conversation about
> clothes. Mis-transcriptions are fixed: "vocal" is Vo-Cal, "my fitness pal/bell" is MyFitnessPal,
> "JGD" is ChatGPT, "clock code" is Claude Code, "non-skill victory" is non-scale victory,
> "console calls" are consult calls, "roofed" is removed, "wings" are wins. Nothing is added.

---

## 1. What we're looking to achieve

**A food tracker that turns into what each person needs.** The person says what they want to
see, and the app shows that and nothing else:

- calories only, for the person who just wants to know they're eating enough;
- calories and fat, for a woman repairing her hormones after an aggressive diet;
- the method's five (calories, a protein range, fiber, fruit and vegetables, water) for the
  90 percent;
- sugar or carbs when a health condition calls for them;
- and no numbers at all for the person who must not see them (an eating-disorder history),
  **only when that person chooses it** (Lorenzo, 2026-10-12: "numbers blind only for those that
  select that's what they don't want to see"). The app still logs everything for them and does
  the work in the background.

Logging stays one tap of the mic, a whole day at once if that's how the person logs. The numbers
are accurate because label data comes first and a model checks it. Nothing nags: no unsolicited
macro critique, and no "you're way over on carbs" on a day the calories landed.

The principles under it:

1. **Show only what the person chose.** Anything else is off their screen, not collapsed into a
   tab they get bombarded by (MyFitnessPal's nutrition tab is the anti-pattern: open it to see
   fiber and you get fats, carbs, saturated fat and cholesterol too).
2. **Numbers-blind is a choice, never a default.** Nothing is preselected (decision 57).
3. **The default is the method's five.** It's what 90 percent of people should focus on, and the
   only thing Francesco's clients focus on.
4. **Different people need a different focus**: hormones (fat), diabetes (sugar, carbs), eating
   disorder history (no numbers), "make sure I eat enough" (calories).
5. **Accuracy comes from the label.** Label data first, the model as a cross-check, USDA last.
6. **Health before a cut.** A woman with no period and bad bloodwork needs a phase before fat
   loss, not a 500-calorie diet.
7. **The coach's voice, at scale.** Check-ins that read like Francesco wrote them: a varied
   structure, no advice he already gave last week, specificity scaled to how long the client has
   been with him, and no AI phrases. The goal is to draft and send without editing.

## 2. Change list against build 32

Each request in the conversation, where it lives, and whether build 32 carries it. Lorenzo held
build 32 until C-07, C-09 and C-12 were in; decisions 72 to 74 were taken and built on
`release/build-32` the same day.

| # | Request (their words) | Where it lives | Build 32 |
|---|---|---|---|
| C-01 | Show people "only the things that they're wanting to track" | Phase P: five modes, chosen first, nothing preselected (decisions 56 to 61, `docs/design/personalized-tracker-spec.md`) | **In.** First TestFlight build with Phase P (PR #26; build 31 predates it) |
| C-02 | "I don't care about protein, I want to know how many calories I'm eating" | Mode *Watch my calories* | **In** |
| C-03 | Hormones: "calories and overall fat intake" | *Watch my calories* plus the Fat tile (Settings → How I track → Also show). The engine sets fat at 27 percent of calories and trims protein, never fat, when calories are tight (`protocols/engine.py`) | **In** |
| C-04 | The five are "what 90 percent of people should focus on" | Mode *Calories, protein, produce, fiber, water*, the default | **In** |
| C-05 | Sugar or carbs for an underlying condition (diabetes) | Sugar tile (a ceiling, a tenth of calories), Carbs tile | **In** |
| C-06 | No "you're way over on carbs" when the calories landed | Decision 28: no unsolicited macro nagging | **In** (since June) |
| C-07 | A preset that keeps people "blind to the numbers" | Mode *Build better habits* ("No numbers"). Six screens still leaked numbers, closed by decision 72: the weekly check-in (asked for weight, could offer "New daily calories" because the habits intake never asks a goal and the profile defaults to fat loss), typed-log search hits, Settings → My foods, Recently deleted, Progress, and Profile's post-save line | **In** (decision 72) |
| C-08 | Numbers-blind only for those who choose it | Nothing is preselected; habits is one of five equal choices; every other mode prints its numbers. The ladder no longer invites a person without numbers to see calories (Lorenzo, 2026-10-12) | **In** (decision 72) |
| C-09 | "Recommendations based off what you're eating ... let us do the work for you" | *Something to add*: from the last seven days against the protocol, the first thing short (protein, produce, fat, fiber) in one sentence with no number, naming the person's own foods; on Today under the tiles and as the weekly check-in's answer (`meals/guidance.py`) | **In** (decision 74) |
| C-10 | Label data as "the ultimate source of truth", AI as the cross-check | Resolver ladder (2026-09-24): FatSecret label rows before the curated head and the estimator; branded rows banded against the curated head; USDA last, behind the Atwater plausibility gate. Brand-less label rows are guarded by name relevance, not by a model | **In** |
| C-11 | "One button" to track "an entire day's worth of food" | Voice capture; the *All at once, before bed* log anchor (decision 69) | **In** |
| C-12 | Meal plan generator: shape of the day → foods to include (a grocery receipt upload) → may it add foods? → the plan | *Build it for me* in My meal plan: Francesco's three steps, the person's most-logged foods as chips, a receipt from the camera or the library; deterministic code drafts the day against the protocol (`meals/generator.py`), the draft opens in the builder and saves like any plan | **In** (decision 73, amends 65) |
| C-13 | A health phase before fat loss (no period, bloodwork) | The check-in's compliance gate ("diagnostics before a cut") exists; a hormone-repair phase does not | **Needs Francesco's rules** (AGENTS.md #6: the engine never invents math) |
| C-14 | Check-ins that vary, don't repeat advice, scale to tenure, avoid AI phrases | Francesco's own drafting agent, outside Vo-Cal. Vo-Cal's weekly check-in is deterministic and refuses generated coaching text (decision 69) | **Context** |
| C-15 | "Should we change the name?" | Decision 68: Vo-Cal for now, reopen only with a name that passes the three tests | **Open** |
| C-16 | The coach reads "the food log in an overall sense": averages, consistency | No coach view yet; the coach lane is kept open (`tracking_preferences.source = coach`, meal plan `author`) | **Context** |

## 3. The conversation

**Francesco:** [...] the wins. For a check-in I look at the food log in an overall sense: the
average intake of calories, protein, whatever. I don't go into the individual days. I look at how
consistently they tried, the whole check-in. The check-in agent has a workflow: first it looks at
the responses, then it cross-references them against everything else and tries to connect the
dots, and then it writes the check-in.

What went wrong is that I made the instructions so rigid that every check-in sounded the same. It
opened by congratulating them on their non-scale victory every single time, then went right into
the wins. The voice was correct, how I would speak. The ethics, the principles, all of that was
correct. But it was such a concrete, computerized message. It did everything right; it just
sounded too generic. The same order every time, and someone's going to catch on. Somebody tells me
their clothes are fitting differently, and it opens with "The fact that your clothes are fitting
differently is awesome." You know what I'm saying?

**Lorenzo:** So when you say voice, you don't literally mean voice?

**Francesco:** I mean tone. Writing voice, not literally voice.

**Francesco:** So I gave it a much simpler set of instructions: 5,000 characters instead of
100,000. I removed all the fluff. The two versions are very close, but one is still a little too
rigid. It gives redundant advice. For example, every time somebody has an event coming up, it says
to try to save 100 to 150 calories, every single time, even if I told them that last week. So I
have to go in, delete it and reword it myself. I want to get to the point where I can just draft
it and send it, and not check it over.

The way I've been doing it: the check-ins are pending in the app. Instead of my current agent, I
made a V2, which goes from Opus 4.8 to Opus 5.5 and cross-tracks the last five emails that went
out. And the new one is Opus 5.5, very similar in structure, except it also has a guardrail for AI
phrases.

**Lorenzo:** Oh, nice.

**Francesco:** They both print out and they're super similar, within about 80 percent, except one
might dive much more into specifics. For example, a new rule we just put in: a client who's more
tenured doesn't need as much specificity in a game plan. Somebody in their fourth week who has
something going on for the first time while we're working together needs a step-by-step
explanation. With somebody who's done it before, you can generalize.

**Lorenzo:** Sure.

**Francesco:** Once I have the two, I put the first one into ChatGPT and she reads it to me. Then
the second one, she reads it to me, and I ask her which one she thinks is better. Then I decide;
usually I already think one is better. If it gels, we work on that one and I start rephrasing
things. Once I finalize the draft, I tell ChatGPT to write a very detailed bullet-pointed list,
with the explanation, of why I made every adjustment I made. Then I put all of that back into
Claude.

I was doing that on the drive here, and once I finalized the check-in, which was beautiful, it
showed the icon of the monitor with a slash through it, only on that one. Every other one was
open. You know, on the Remote Control?

**Lorenzo:** Oh, yeah. [...] Claude Code. [...]

**Lorenzo:** So this is for drafting emails?

**Francesco:** No, drafting my check-ins in the app.

**Lorenzo:** Oh, I see.

**Francesco:** And honestly, it was decent, because the main check-in only goes out to them once a
week, with everything they had going on that week, from one check-in to the next. They're not
looking at their last check-in. So it passes, but I want it to be amazing. I pay for the pro plans
on ChatGPT and Claude, so I might as well go all in.

**Lorenzo:** I've got the same. Claude. I worked on some of the changes you mentioned for [...]

**Francesco:** Should we change the name? We had a great one, with the emblem too.

**Lorenzo:** Yeah, we can. *(attribution uncertain)*

**Francesco:** Because I know how people are, and I know the friction I get on my consult calls
when I bring up food tracking. People say: okay, fine, I'll do it, but is there any way I don't
see how many calories I'm eating? With me, no. But if you need an app that does that, I can make
one. And it's like that with so many different things.

I'm working on a meal plan generator, so people can make a meal plan that includes the foods they
like. It's step by step. First and foremost: how do you want your day to look? How many meals?
Snacks between meals? A dessert after dinner? Step two: what foods do you want it to include?
They could even upload their grocery receipt.

**Lorenzo:** Oh, nice.

**Francesco:** And the final step: is it okay for the generator to add foods you didn't mention,
or should it only use the foods you mentioned? Then it puts out a meal plan. Because again, there
are so many different ways people handle their nutrition. An app that abides by all of them is a
real *my* fitness pal. An app that only does it one way isn't your fitness pal, it's your fitness
dictator: you do it this way or you can't do it.

Everyone hates MyFitnessPal. I haven't met one person I work with who says they actually like it.
It's overwhelming. If you want to see how much fiber you ate for the day, you have to go into the
nutrition tab, the more analytical one, and you're bombarded with fats, carbs, saturated fat,
cholesterol. You see all these things you didn't hit, or did hit, or had too much of. So just
because they wanted to see fiber, they get bombarded, and they don't even look at their fiber
because they end up looking at everything else.

On top of that, they hit their calories for the day, but because it wants them to track their
macros perfectly, it's: well, I'm way over on my carbs, even though I nailed my calories. What do I
look at? It causes way more anxiousness around it, because they're not sure they're doing it
right. And I hate telling people to just ignore what MyFitnessPal says, because you can't ignore
it. It makes a point of shoving the information in your face.

Those things could be toggled off. Some people say: I don't care about protein, I want to know how
many calories I'm eating. Cool. Even if it's not the most optimal, that's what will keep you using
the app. Some people would be better off losing some muscle and bone if they're losing fat too.
Some people just need to lose weight. [...]

**Lorenzo:** I have a pretty thorough update I could send you, basically a handoff of all the
changes I made. It's still the core of Vo-Cal, but a much more personalized experience, showing
people only the things they want to track. I took what you said, plus edits I was getting from
other people testing it.

The biggest reason we had low accuracy was the USDA database. Based on my research it was pretty
decent, and it was supplemented by AI, but if it found something in USDA it used that, because that
was the rule: it saw USDA as the source of truth. And USDA itself didn't have accurate information.
I reverse-engineered all the errors that were happening. I'd tell it the same thing, "this is the
wrong thing, figure it out", and it would use AI to figure it out, but the next time it would still
see "USDA says it's this many calories, so this is what it is". Only if a food wasn't in USDA would
it use AI, and AI was way more accurate. If I had to guess, MyFitnessPal is fully using AI.

**Francesco:** You think? They also have a huge database.

**Lorenzo:** True, but that's a problem: the users add the entries. They can add anything.

**Francesco:** I thought you were saying they have so much data on accurate food tracking; their
whole app is history. A lot of people put in junk, but for the most part people scan a food item,
it pops up, and now it's saved. So any time someone says Chobani, it knows exactly how many
calories from a scan of the product, which is the ultimate source of truth, right? The actual
nutrition label.

**Lorenzo:** Right. So I found that out, and now we're using that other database. But it isn't the
single source of truth: it still references AI to cross-check that it's accurate. It's a little
more expensive to run, but I think it'll make sense in the future, at least for now.

I really like it. I've been using it, and it was really accurate for me with this eating pattern
I've been working with lately. Not really a diet: foods that come from the ground, nothing
processed, no gluten. I was worried I wasn't going to get enough calories, because I cut out eggs
and a lot of things that were a big source of protein. And tracking it was so easy. I literally
click one button and sometimes track an entire day's worth of food, because I remember it, and
then I'd see I still had 300 calories left and eat something. So it's especially good for a person
who doesn't need perfect macros or perfect calories, someone like me who wants to make sure they're
eating enough, or wants a rough estimate.

**Francesco:** But a lot of the people who download it want results. They're going to be driven by
calories.

**Lorenzo:** Totally. But there's going to be a small subset of people who say: I don't even care
about seeing my calories. If they can toggle it off, they're going to say: this is exactly what I
need.

**Francesco:** Then what are they tracking for, if not to see their calories? It's like me asking
you why you're tracking, if you don't care that much about the calories and it's more about the
principles of the eating pattern.

**Lorenzo:** No, I do care about the calories. That's the only thing I care about: making sure I'm
having enough calories in a day. I don't care about the rest.

**Francesco:** So vice versa: you'd turn everything off besides calories, because all the extra
information is noise to you.

**Lorenzo:** That's true.

**Francesco:** Though some would argue that even with just calories, you should pay attention to
fiber, and to getting enough fat, especially women. A smaller woman whose calorie target is 1,300
just because she's small tends to keep her fat low, because that's the only way she can eat a
high-volume diet: fat is more calorie-dense. The bad part is that a low fat intake dysregulates
your hormones, especially in women. They lose their period, they're super irritable, they lose
fertility. I have clients who come to me after dieting aggressively: they lost weight, but they
also lost hair, had super low energy, felt like wind-up dolls, lost their period.

So nutrition can be a totally different focus from one person to the next. If an app only delivers
your targets one way... For example, Vo-Cal as standard doesn't show fat. For somebody trying to
regulate their hormones, seeing calories and overall fat intake is probably more important than
anything, because they can confirm they're getting enough fat without exceeding their calories and
gaining fat.

**Lorenzo:** Right now it shows protein and fat?

**Francesco:** No. Right now it shows overall calories, a protein intake range, and the daily
minimum targets of fiber, fruit and vegetables, and water. That's what 90 percent of people should
focus on. It's the only thing my clients focus on. If they ever need to look at something else,
like sugar or carbs, it's because they came to me with an underlying health issue as well, like
diabetes. Or they came to me without a period. Women come to me who don't have their period; they
upload their bloodwork, and that's why they went looking for a nutritionist. And I have to tell
them: I know your goal is fat loss, but there's no way you're going to get sustainable fat loss or
optimal health if we don't take care of this first. You're not going to optimize your hormones by
trying to lose more fat with jumbled-up hormones. You'll put yourself in a calorie deficit and get
no results from it. So I help them understand there's a whole phase that needs to come before
fat loss if it's going to be sustainable. Otherwise you're stuck on a 500-calorie diet, worsening
your health just to lose more fat.

So MyFitnessPal is good in that you can open the nutrition tab and look for what you're
prioritizing for your specific issue or goal. But it also serves you every other variable and you
have to skip over it, and a lot of people can't, because a lot of people naturally want to be
perfect at everything. Removing the rest from view is the easiest way to stay focused on what
matters. And that's everything: you have to remove the fluff to find the optimal path.

**Lorenzo:** There's no app out there like that. One that shape-shifts into what you need.
*(attribution uncertain)*

**Francesco:** It's crazy. Think about people with eating disorders. They rule out food logging
completely because it's so overwhelming. This could be an answer for them. The only kind of food
tracking those people may ever do again is keeping a journal: they write down the foods, but they
don't see the fat, the protein or the calories. Then they go to a dietitian, who breaks it all down
without telling them, and gives them general guidance on what more they can include, leaving the
numbers out. That could be a preset: recommendations based on what you're eating, with you blind
to the numbers. Let us do the work for you. *(attribution uncertain)*
