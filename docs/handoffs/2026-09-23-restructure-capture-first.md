# Handoff: restructure/capture-first, 2026-09-23

Written for a session with no other context. Read the permanent documents first: `AGENTS.md`,
`docs/VOICE_CAPTURE.md`, `docs/INVARIANTS.md`, `docs/CAPTURE_LIFECYCLE.md`, then
`.claude/plans/_completed/restructure-capture-first-2026-09-23.md` (done and next markers), then
`git log restructure-start..HEAD`, then run the full ladder before touching anything.

## Where the tree is

- Branch `restructure/capture-first`, tag `restructure-start` = `00e34d1` (main at the start).
- Last commit at the time of writing: the R14 documentation commit (see `git log -1`). The
  tree is clean after it.
- Shipped: merged to `main` as `a15e439` (no fast-forward), pushed; Deploy run 35928298696
  succeeded (the production API answers 200 on /health); TestFlight build 27 uploaded through
  the publish lane, its bump commit `4d4bcd1` on `main`; CI run 35928561205 on that head is
  green on API, Libraries and iOS app. Branch protection is not enabled (questions ledger 4:
  the owner's setting; the payload and command are in the ledger).

## What shipped on the branch, in order

R0 ground truth (`cfa63bc`, `d734683`), R1 ratchet tables (`d356080`), R2 map and Home glyph
(`3bdf526`, `1f49b08`, `98a02e5`), R3+R4 repair fuse and blob cap (`4748d03`), R5 CI ladder and
push hook (`3dcc987`), R6 crash evidence (`d3f7c5a`, `c70be60`), R7 upload worker (`7af4ac6`),
R8 unfinished recordings (`a29ae9f`), R9 learned names and the root-of-chain diff (`520df05`),
R10 recently deleted with Restore (`e3dba26`), R11 one address per decision (`993f2fa`), R12
gestures and touches (`a660a7b`, corrected by `64ec1d0`), R13 census delete (`df54948`), R14
this documentation. `docs/restructure/` holds the ground truth (00), the complaints with their
closing commits (01), the ratchets (01), the map (02), the ladder (03), the findings (04) and
the questions (05).

## Tools and paths the next machine needs

- macOS with Xcode 26.2 and the pinned simulator (AGENTS.md, Identifiers); `xcodegen`;
  `uv`; `gh` authenticated; `git config core.hooksPath .githooks` (installed by `make setup`).
- The ladder: `scripts/check` (SPM tests + API), `bin/ios-app-build` (zero warnings),
  `bin/ios-sim-voice-test` (12 scenarios, prints `PASSED_OF_EXPECTED`), `scripts/parser-eval`
  (ratchet against the committed SCORES.md). All four are what CI runs.
- Ship lane: `.claude/skills/publish` (bump, archive, upload with the API key); the Deploy
  workflow on `main` deploys the API to Fly.

## Remaining work, in order, with the verification owed

1. Branch protection on `main` (questions ledger 4): one command, the owner's word first.
2. Prove findings 4 on the deployed API: rename an item, log it, `GET /meals/learned-names`
   returns it (the PostgREST embed is only fake-tested offline).
3. Then the questions ledger, in the owner's order.

## Standing rules

One concern per commit with a `Verified:` block; never weaken a test or raise a ceiling;
the stop-and-ask list in the protocol; no em dashes in copy a person reads; never run a
migration or a database reset; never push without the owner's word (given for this pass);
never log phone numbers or precise health values; the capture path reaches nothing that
serves another concern.

## Restore

`git checkout restructure-start` restores the tree to the start of the pass. It does not
restore: the Fly release or the TestFlight build once shipped, GitHub branch protection once
enabled, and any server rows written by the new endpoints (learned-name and forget rows are
plain corrections rows; a restored meal is an ordinary live row).
