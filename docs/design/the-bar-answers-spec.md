# The bar answers: the one mouth handles requests (Phase T, decision 71)

> Mode: REVIEW of the ask, then DIETERIFY of the design. Protocol: the Rams audit
> (`Agents/Dieter Rams Brain/AUDIT-PROTOCOL.md` in Lorenzo's vault). Quotes carry their source
> tag (W01, W02, T01, T02, I06); everything else is inference and says so. Written 2026-10-04,
> the same night as `behavior-change-spec.md`; where this file and the code differ, this file wins
> until the code is corrected.

## 1. The ask

Lorenzo, in two messages:

> "muse does a really cool UX thing where if a user wants to change a setting it brings you back
> into this single chat that can handle your requests it trains the user to use the chat and
> needs to be personalized through natural language use a low cost claude model to execute this"

> "not saying we should build in a chat, but i am saying it should respond when someone has a
> response and in that they could chat with it if they choose to but it more importantly shows
> them what they need via that chat that uses ios 27 gestures and so on"

Read together: not a chat screen. The thing the person already speaks into should handle what
they say when it is not food, show them the thing they needed rather than tell them about it,
let them go on if they want to, and use the phone's gestures. A low-cost model understands the
sentence; the app does the rest.

## 2. What it is today

The capture bar's hint says "What did you eat?". A person types or says "stop the protein
reminders" or "how much protein do I have left". The sentence goes to the parser, which finds no
food and refuses (422). The sheet says: **"I couldn't make out any food in that. Try describing
the meal again."**

**WHAT HE SAYS.** "Good design is honest" (T01): the product presents itself as something that
listens, then answers a question about protein with a correction about meals. "Good design is
thorough down to the last detail" (T01): the failure path was written for a mumbled meal and
never for a sentence that was not one. Failure class A (dishonesty: the system's narrowness
presented as the person's error) and F (indifference: the person's words were read, classified
and discarded).

**The butler test.** A butler asked "how much protein have I had today" does not reply "I could
not make out any food in that". He says the number, or where it is written.

## 3. The chat screen: CUT

A second surface, a transcript, a personality: CUT, structural.

- **Accretion (D).** The bar already is the one mouth. A chat would be a second mouth that does a
  subset of what the first does, plus prose. "Weniger, aber besser" (W01): the bar exists; the
  answer is a state of the sheet the bar already opens.
- **Fashion (E).** The chat window is this year's shape. The person's need is older: say a thing,
  have it done, see that it was.
- **The habit.** Muse's lesson, read right, is the single mouth, not the transcript. Training the
  person to open a chat trains them away from the ten-second log. The bar stays the door to the
  one habit (spec `behavior-change-spec.md` 6.7: "Everything here follows from one habit: say what
  you eat."); a request through the same door strengthens the door.
- **Generated prose.** Decision 67 and the refused list of 6.11 stand: no generated coaching
  text. The model fills a form; a person never reads a sentence the model wrote. Every line the
  person reads is in a catalog, final, under the anatomy rule.

## 4. Necessity gate: what does the person need?

| They said | They need | Not |
|---|---|---|
| "switch to habits", "just calories", "I want to track macros" | the way changed, and to see it changed | a confirmation dialog |
| "also show fiber", "take sugar off" | the tile on or off Today | a settings tour |
| "stop reminding me", "only when I'm slipping", "coach me" | the level changed, said back in their own words | a toggle to find |
| "stop the protein reminders", "bring the water ones back" | that subject quiet, or back | thirteen switches |
| "I'll log before bed", "I forget" | the plan's cue or the obstacle recorded, and what it moves | a form |
| "how much protein do I have left", "how many calories so far" | the card Today draws, here | a paragraph of numbers |
| "show my week", "why is my protein 160" | the way to the surface that has it | a summary that drifts from the surface |
| "make me a sandwich", "what's the weather" | an honest no, with what the bar is for | an apology, a personality |
| "I had a big thing with stuff" | the old answer: it was a meal and nothing was heard; try again | a wrong reading as a request |

What they do not need: prose, memory of the conversation past this sheet, a second place to type,
a name for the assistant, a sparkle.

## 5. The design

### 5.1 One mouth

Food is the default and stays the parser's. A sentence typed or spoken into the bar goes to
`POST /parse` exactly as today. Only when the parse finds no food (the 422, or a result with no
items, no question and no recognized usual) does the same sentence go to `POST /assist`. The
sheet keeps its working surface ("Working out the numbers…") through both; the person sees one
wait, then one answer. Nothing on the capture path changes: the recording is committed before
any of this, and a request from a voice capture is a finished capture (Today never lists it as
unfinished), the same outcome as an empty transcript.

### 5.2 The answer is a thing, not a paragraph

The answer surface (`AssistReplyView`, a state of the voice-log sheet: `VoiceLogState.answered`)
has, top to bottom:

1. **"You asked"** and the sentence, quoted, as the failure surface echoes "You said".
2. **The line**: one sentence from the catalog (5.5), in the app's register.
3. **The thing**: exactly one of
   - a **change row**, drawn as Settings draws the same row (`SettingsRow`: icon tile, label,
     the new value trailing), so what the person sees here is what they will find there;
   - **the Today card** for a number (`PanelView`, the server-composed panel, the same component
     Today draws, framing included);
   - a **pointer row** with a chevron to the surface that has it (Settings, My protocol, the
     plan), opened by a tap;
   - nothing, when the answer is the line alone (the honest no, "already so").
4. **Undo**, only when a change landed, as a secondary button; after it, the line says "Undone."
   and the row goes.
5. **The field and the mic**: a capsule field ("Say more") and the mic droplet. Typing sends the
   next sentence through the same door with the thread; the mic starts the same recording the
   bar starts. This is the "if they choose to": the door stays open, nothing asks them through it.
6. **Close**, tertiary, and the floating X.

### 5.3 The extractor

- `claude-haiku-4-5` (`settings.assist_model`), the parser's own choice for extraction (p50 1.4 s,
  2026-09-25); `max_tokens` 300; the system prompt cached; the tool forced (`answer_request`), so
  the model's only output is the form. It mirrors `parser/llm.py`'s `AnthropicParserClient`.
- The form (`Intent`): `kind` in `set_mode`, `set_focus`, `set_level`, `set_anchor`,
  `set_frictions`, `mute`, `unmute`, `show`, `meal`, `other`; each kind's one or two fields from
  the app's own enums (modes, focus metrics, levels, anchors, frictions, nudge subjects,
  surfaces). The model never writes a sentence the person reads and never a number.
- The thread: up to six turns (the person's sentences, the app's catalog lines), held by the
  phone for the life of the sheet, sent with each request so "actually, coach me" resolves. The
  server stores none of it; what a request changed is on the record as a tracking version or a
  reaction row, the same records the Settings screen writes.
- `RulesAssistClient`: a deterministic keyword reading of the same form, used under `TEST_MODE`
  and when no key is configured. The suite is offline; a key-less dev server degrades to the rules,
  never to silence. A model error is an honest failure (502 to the phone, the usual failure
  surface with retry), never a guess that changes a setting.

### 5.4 The deterministic apply

| Intent | Effect (deterministic, the existing stores) | The thing shown | Undo |
|---|---|---|---|
| `set_mode` | `PUT /tracking` merge (`apply_update`), source `chosen` | change row "How I track" · mode | the previous mode |
| `set_focus` | the focus list, added or removed | change row "Also show" · the list | the previous list |
| `set_level` | `nudge_level` | change row "Reminders" · the level's sentence | the previous level, when one was ever chosen |
| `set_anchor` | `log_anchor` | change row "When you log" · the moment | the previous anchor, when one was ever chosen |
| `set_frictions` | the frictions list | change row "What gets in the way" · the list | the previous list |
| `mute` subject | `not_for_me` on every catalog nudge of that category | change row "Muted" · the subject | `unmute` the same ids |
| `unmute` subject | `unmute` on the same ids | change row "Muted" · "{subject} back on" | `not_for_me` the same ids |
| `show` metric | nothing; the day is composed as `GET /meals/today` composes it | the Today card for that metric | none |
| `show` surface | nothing | pointer row | none |
| `meal` | nothing | the old failure surface and copy, retry | none |
| `other` | nothing | the line alone | none |

"Stop all reminders" is `set_level off`, one version, never thirteen mutes. A number asked in a
mode that prints none (habits) is the line alone, naming the switch, never a number the person
chose not to see (decision 58). A metric not on the person's Today is the line alone, naming
"also show". "Already so" (the mode they are on) is the row without Undo.

### 5.5 The catalog of lines

Every sentence the person reads, final, under the anatomy rule (recognition, invitation, agency;
no exclamation mark; no diagnosed feeling; no grade; under 140 characters). `assist/lines.py`.

| When | Line |
|---|---|
| mode changed | "You're following {title} now." |
| mode already so | "You're already following {title}." |
| focus added | "{Metric} is on Today now." |
| focus removed | "{Metric} is off Today now." |
| level essential | "Vo-Cal will say something only when you're slipping." |
| level standard | "Vo-Cal will coach you along the way. Never more than two a day." |
| level off | "Vo-Cal will say nothing. Your weekly check-in still shows when it's due." |
| anchor after eating | "Your check-ins follow right after you eat now: 11:30 and 20:00." |
| anchor when seated | "Your check-ins follow when you sit back down now: 12:30 and 20:00." |
| anchor before bed | "One check-in at 20:30 now, and nothing before the evening." |
| anchor own | "Nothing moves. The check-ins stay at 11:30 and 20:00." |
| friction added | "Noted: {title}. {What it moves, the chooser's own line.}" |
| friction removed | "Noted. {Title} is off your list." |
| muted | "The {subject} reminders stay quiet until you turn them back on." |
| unmuted | "The {subject} reminders are back on." |
| number shown | "Your {metric} today." |
| number, habits | "Your way shows no numbers. Say 'watch my calories' and it will." |
| metric not on Today | "{Metric} isn't on your Today. Say 'also show {metric}' and it will be." |
| week | "Your week is on Today, under your meals." |
| protocol | "Your targets and their whys are in My protocol." |
| plan | "Your plan is in Settings, under Meal plan." |
| settings | "How you track lives in Settings." |
| notifications | "Reminders live in Settings, under Notifications." |
| meal | "I couldn't make out any food in that. Try describing the meal again." |
| other | "That's not something Vo-Cal does. Say what you ate, or ask about your day and how you track." |
| undone | "Undone." |

### 5.6 Gestures and touches

The phone's vocabulary (`docs/DESIGN.md`, Gestures and touches), nothing new invented:

| Gesture | On | Does |
|---|---|---|
| Swipe either way | the answer | closes the sheet; the one `select` tick (the nudge card's quiet dismiss) |
| Long-press (context menu) | the change row | Undo, the same as the button |
| Tap | the pointer row | opens the surface, the sheet closes |
| Tap | the mic droplet | the recording, with its swell, as from the bar |
| Type and send | the field | the next sentence through the same door |

Touches: `success` only when a change landed (the server's echo, or the undo's), the same tick
as "Logged"; nothing on a shown number, a pointer or a no.

### 5.7 Claims

"Changed" is said only from the server's echo (the appended version, the 204 on a reaction); the
mock path says it from its own store the same way. The thread claims no memory beyond the sheet:
closing it forgets. The old failure copy stays what it was for a meal nothing was heard in.

### 5.8 States

| State | Surface |
|---|---|
| asking | the enhancing surface, unchanged ("Working out the numbers…") |
| answered | 5.2 |
| undone | the line "Undone.", the row gone, the field and the mic remain |
| offline, server error | the failure surface, its copy, retry (the sentence echoed) |
| meal | the failure surface as today |

### 5.9 Refused, so nobody adds them back

A chat screen or tab. A transcript on any screen. Generated prose. A name, a face, a sparkle, an
"AI" badge. A proactive message from the assistant. Memory across sheets. A reply to a food
sentence (food is the parser's). A question back to the person beyond the catalog's lines.

### 5.10 Privacy

The sentence goes to the model as a meal transcript already does. The thread carries the person's
sentences and the catalog's lines, held on the phone, sent per request, stored nowhere. Logs carry
the intent kind and counts (MUST-NOT #5); never the sentence.

### 5.11 Evidence

- **Autonomy (SDT, Deci and Ryan; strong).** A setting changed by saying it is the person's
  choice made in their own words, with Undo as the visible exit.
- **Ability (Fogg B=MAP; moderate).** The shortest path from the wish to the change is the mouth
  already open; a request through the bar costs what a log costs.
- **The gulf of execution (Norman; strong in HCI).** The person's intention ("fewer reminders")
  meets the system's vocabulary (a level) in the model, not in a menu the person must learn.
- **One cue, one act (Wood and Neal; strong).** The bar stays the one door; every use of it,
  including a request, is a rehearsal of the habit's cue.

## 6. Ship gate

- A typed "switch to habits" lands a tracking version and the sheet shows the row Settings
  shows; Undo restores the previous way and the sheet says "Undone."
- "How much protein do I have left" shows the Today card for protein, framed as Today frames it;
  in habits mode it shows the line that names the switch and no number.
- "Stop the protein reminders" appends `not_for_me` for the protein nudges; Settings lists them
  under Muted; Undo appends `unmute`.
- A meal nothing was heard in shows the old failure copy, unchanged.
- No line in the catalog carries an exclamation mark, a diagnosed feeling or a grade; none is
  longer than 140 characters.
- The suite runs offline on the rules; a dev server without a key answers on the rules and says
  so in `/__dev/preflight`'s spirit (the log line names the client).
- `scripts/check-api` green; CI's iOS job green.
