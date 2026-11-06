# The calm home, the bubbles and the one chat (decision 75)

Date: 2026-11-06. Lorenzo's ask, in his words: the app "barely works, looks like shit, can't
scan QRs"; "reinvent the entire app"; "users only see what they need"; "the onboarding should
have the bubbles"; "the home should say log meal or something, click that and then it shows they
can take a picture or can voice like it does now"; "in just a single chat they should be able to
see what they need"; "instead of saying meal, which makes it hard to see what meal you're
referring to, show the history of meals logged like MyFitnessPal, there's a method to their
madness"; "make it calm and really clean"; "needs to start referencing the new logging db". The
references: the Areela keynote (the bubbles that grow, the one input, the orb's calm), Gleb
Kuznetsov's generative-OS boards (a wash of colour, one greeting, a few cards), MyFitnessPal's
diary (breakfast, lunch, dinner, snacks, each with its own Add), and MyFitnessPal's own voice
complaint ("chocolate cake high whey protein powder" logged as "chocolate cake one slice": a
transcript must be honoured, never predicted into a generic food). Lorenzo kept the palette:
"I like our designs better." No em dashes.

What stands from the personalized tracker (decisions 56 to 74): the mode governs every printed
number; the server composes the cards; the capture path is sacred; the claim ladder licenses
every word; the LLM extracts and deterministic code prices. What this amends: decision 71's
"no chat screen" (the chat is now the one surface for anything said to the app) and decision
57's "nothing preselected" for the mode (the bubbles offer it; the person confirms or changes
it on its own screen).

## 1. The purpose sentence

A person says what matters to them once, then logs a meal with one tap and a sentence, and
sees their day as the day reads: what they ate, meal by meal, and what is left.

## 2. The screens

### 2.1 Welcome, on the wash

`WelcomeView`: the wordmark, "Follow your nutrition your way." with the gold on the person's
part, one line ("Tell it what matters to you. It shows only that. Say what you ate, snap it,
scan it or type it, and it logs."), "Let's begin". The wash (`WashBackground`, `VoCalTheme.Wash`)
is two blurred discs of the brand gold and the carbs amber at low opacity, fading down the
page; it is built from tokens already in the table, so the palette gains no colour.

### 2.2 The bubbles

`GoalBubblesStep`, the intake's first screen. Eight bubbles: Lose fat · Build muscle · More
energy · Sleep better · Eat enough · Healthier habits · Hormones · Live longer. A tap grows one
by a step (three steps), a tap on the biggest lets it go; the cloud rearranges with one spring
(`BubbleCloud.layout`, deterministic). Under the cloud, one sentence: "Lose fat first, then
sleep better." The bubbles decide, as a pure function (`GoalPriorities.derived`):

| The biggest bubble | The mode offered |
|---|---|
| Healthier habits | Build better habits |
| Build muscle | Track my macros |
| Eat enough, Hormones | Watch my calories |
| Lose fat, More energy, Sleep better, Live longer, none | The five |

The goal: fat loss bigger than muscle is a cut, muscle bigger is a gain, otherwise maintain.
The focus: Hormones adds the fat tile (decision 30). The next screen, "What you'll see",
shows the chooser with the offered mode ticked and the sentence above it ("Picked from your
bubbles. Change it any time."): the person keeps or changes it, so the choice stays theirs
(decision 57's reason, a default the person never saw, does not apply to a tick they are
looking at). The goal question is gone from the intake; the ruler and the realistic-pace
screen show only when a number is prescribed (cut or gain). The bubbles stay on the phone
(`vocal.priorities`); what they decided travels as the preference's own fields. The home's
greeting names them back.

### 2.3 The home

`HomeView`, the root. On the wash: the greeting by the clock ("Good morning"), the bubbles'
sentence under it, the day with a step either way. Then:

- **The one line** (`HomeView.focusSentence`): the day in a sentence from the server's
  calories card and its framing (decision 70): "420 so far. 1,620 left of 2,040 today.",
  "60 left of 2,040 today.", "240 over your 2,040 today.", "2,040 for today. Nothing logged
  yet."; in meal-plan mode the plan's line; without numbers, "Say what you eat and it counts
  itself." or "3 meals logged. The day is on the page." Never a number the mode hides.
- The check-in banner when due, the permission card once, the nudge card on an empty day.
- **Today, the summary card** (`TodaySummaryCard`): each of the mode's panels as one row (the
  title, the value, a thin bar in the panel's own colour), the plan's or the habit's line where
  the mode has one. It is the door to Progress.
- The guidance card without numbers (decision 74), the unfinished recordings.
- **The diary** (`MealDiary`, `DiarySection`): Breakfast · Lunch · Dinner · Snacks, every
  section every day, each with its meals (name, time, calories where the mode prints them),
  its total, and its own Add. A meal logged without a slot falls in by the hour it was eaten
  (before 10:30 breakfast, before 14:30 lunch, before 17:00 a snack, then dinner); a named
  slot wins. Tap to edit, swipe right to edit and left to delete, press and hold for the menu,
  as the rows always had.
- "Ask Vo-Cal anything", the way into the chat.
- **The one pill**, "Log a meal", on the bar's own fade at the foot (`HomeBar`).

### 2.4 Log a meal

`LogSheet`, under the pill or under a section's Add: the slot chips (the clock's suggestion
or the section tapped), **Speak** largest and first (the gold mic on the bar's glass face),
then Type · Photo · Scan beside each other, the usuals as chips (one tap logs into the chosen
slot), and water. Speak opens the voice capture with the slot; Type opens the chat with the
slot; Photo opens the camera and the result; Scan opens the scanner. The sheet logs nothing
itself but a usual.

### 2.5 The one chat

`ChatView` over `ChatThreadModel`: the thread of turns, the capture bar as its mouth
(`CaptureBar`, unchanged in its three states, with "Scan a barcode" joining Camera and Photos in
its menu), the voice capture over it when the mic is tapped. The engine of every turn is
`VoiceLogViewModel`, untouched: it owns the capture rungs, the parse, the answer and the
confirm, and its state licenses every word. The turns:

- the person's words (typed, the transcript of a spoken turn, "Your photo", "Scanned ...");
- the working line while the parse runs;
- **the meal card** (`MealResultCard`): the name the server will give it, the calories and
  macros (where the mode prints them), the items, the checks left (a tap opens the full result
  sheet on the same model), Save as a usual, Edit and Log;
- **the receipt** (`ReceiptCard`) once the server's row landed: `ClaimCopy.logged`, the name,
  the calories, the water that went to the tally;
- **the answer** (`ChatAnswerCard`, decision 71's anatomy): the catalog's line, then one of the
  changed row as Settings draws it, the Today card as Today draws it, or the pointer row; Undo
  while the change can be put back; folded without Undo once the next turn starts;
- the honest failure with the words echoed and Try again.

The first screen is "What did you eat?" on the wash with four sentences the thread already
understands. The thread lives for the app's session and is stored nowhere; the assist thread
(six turns) is carried between turns so a follow-up resolves. Closing the voice sheet over the
chat keeps a result, an answer or a failure as the live turn (`keepsOutcomeOnClose`); the
shell's own voice sheet forgets, as before.

### 2.6 Progress

`TodayView`, retitled, behind the summary card: the week strip, the mode's full cards, the
guidance, the week's budget. The day's meals are the home's diary now.

### 2.7 The scanner

`BarcodeScannerView` (VisionKit's `DataScannerViewController`, EAN-13, EAN-8, UPC-E, Code 128
and QR; the manual field under the viewfinder; the simulator and a denied camera open on the
manual door) and `ScannedFoodSheet` (the food found, its serving and calories, a servings
stepper, Log it). The server reads the code (`GET /foods/barcode/{code}`): FatSecret's
`food.find_id_for_barcode` when configured (the database Lorenzo called "the new logging db";
its credentials are live on Fly), Open Food Facts otherwise, cached in `usda_cache` under
`bc:<gtin13>`. Logging a scanned food saves it as one of the person's foods (the label, read by
the camera instead of typed; `SaveLabelFoodRequest` carries `barcode` and `brand` as
provenance) and logs a serving through the one confirm path a usual takes.

## 3. What is refused, still

A sparkle, an "AI" badge, a name for the chat, generated prose, a proactive message, memory
across launches, streaks, badges, points, confetti, a grade, a diagnosed feeling, a number the
mode hides, a claim above the state's proof.

## 4. The ship gate

- `bin/ios-app-build` zero warnings; `scripts/check` green; `scripts/check-api` green with the
  barcode tests.
- `bin/ios-render-tests`: the welcome, the bubbles (empty and grown), the home (populated,
  empty, habits), the log sheet, the chat (empty, a thread, the meal card with and without
  checks), the scanned food, Progress per mode; the pure checks on the bubbles' derivation and
  cloud, the diary's grouping, the one line.
- `bin/ios-flow-tests` on the chat (`-StartOnChat`); `bin/ios-ui-audit` on the home, Progress,
  the chat and Settings; `bin/ios-motion` on the home.
- On a device: a spoken meal from the chat, a scanned package, a photo from the log sheet.
