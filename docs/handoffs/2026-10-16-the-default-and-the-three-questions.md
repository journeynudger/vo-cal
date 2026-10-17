# Handoff, 2026-10-16: the default and the three questions, built on `claude/nice-mayer-yysfuq`

What this session built, what it proved, and what it could not prove from a Linux box with no
Swift toolchain. Read with `.claude/plans/phase-w-the-default-and-the-three-questions.md` (the
plan, ticked) and `docs/design/the-default-and-the-three-questions-spec.md` (the Rams REVIEW of
the ask, the corrected design, and in Section 8 the audit of every aspect with what was fixed and
what is the owner's).

## What landed

| Task | What it is |
|---|---|
| W0 | The spec; decisions 75 to 77; the plan; the master plan's row and amendment; memory. |
| W1 | API: the method's six (fat after protein on Today, in the reveal, in the label and the assist); meal plan mode owns no tile so "Also show" offers them; `METHOD = "five"` with the reason. The audit's server fixes: the recommendation headlines in the person's unit and without a verdict (the "down one notch" that was up), the habits person answered about water and produce and never pointed at a surface their way lacks, the evening reminder named only where it exists, no first person, no average calories to a mode without numbers, the whys in the person's words with no re-derived number, "counted" not "priced", no inferred account or promised outcome or statistic of other people in a nudge. |
| W2 | iOS: the welcome's two doors; the skip path (nothing written); the intake's three questions; `VoiceAskCard` after the first log with `NudgeCenter.voiceAskPending`, `evaluateVoiceAsk`, `chooseLevel`; the gate's purpose; the six on the phone (`TrackingMode.method`, the composer, the reveal, the twins, the assist); Settings → Notifications says when the tick is the default's; What's New for this release; the render tests. |
| W3 | The audit's fixes on the first run, Today, Settings, the check-in, the week, the voice log and the result (the spec's Section 8, every row marked FIXED). |
| W4 | The docs: DESIGN, UI_VERIFICATION, the review notes, DATABASE, the brief, the agents notes, the questions ledger (14 to 22), memory, this handoff. |

## What was proved

`scripts/check-api`: ruff clean, the suite green with the new tests (the six's order, a fat focus
not doubled, meal plan owning no tile, the default reveal, the habits summary without an average,
the habits person answered about water, the pointers). The Swift was read for balance and for
every call site of every changed signature; CI's iOS job is the compile proof.

## What to verify on the Mac, in order

1. `bin/ios-app-build` at zero warnings (the CI job runs it on the push).
2. `bin/ios-render-tests`: read the PNGs in `/tmp/ui`, then record the goldens on the pinned
   runtime, saying why (`RECORD_SNAPSHOTS=1`): new are `welcome` (two doors), `voice-ask-card`,
   `notification-settings-default`; changed are the method's Today (`today-populated`, the focus
   wrap), the method's and the plan's reveal (the fat row), How I track (fat gone from "Also
   show"), the result with checks ("Use typical amounts", the certainty card without its
   percentage), the item card matrix (no Edit button, "Not counted yet"), the check-in form (no
   glyphs, the card tone), the Health step, the progress bar on every intake screen. The runtime
   the goldens were recorded on is gone from the build Mac (phase V's note), so this is the pass
   that re-pins and re-records everything at once.
3. The first run, on the pinned simulator: "Skip the questions" lands on Today with the method's
   six at starter targets and the banner; "Make it mine" asks the mode, then the engine's screens
   with what gets in the way and when you log among them, and never how much the app says; the
   first log shows the card; "Only when I'm slipping" writes the level and shows the system sheet;
   "Nothing" writes the level and shows no sheet; Settings → Notifications ticks the choice.
4. On a phone without the Action button (an iPhone 15 or earlier), the card after the tour does
   not appear; on a 15 Pro or later, it does.
5. `bin/ios-flow-tests` and `bin/ios-sim-voice-test` unchanged (the bar and the capture core
   did not move).

## Open, in the owner's order

The questions ledger's 14 to 22 (the certainty statistic, Dynamic Type, the stress question in
habits, the ruler before the goal, the ports' literals, the recalibration card's decline, one pill
for typical amounts, Reduce Motion on the reveal, the failed-load lines). Then the goldens above.

## Restore

`git checkout 547d137` restores the tree to before this pass (main at build 32). Nothing was
deployed and no migration exists for this phase.
