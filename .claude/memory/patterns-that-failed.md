# Patterns That Failed

Failures already paid for — mostly Serein production incidents. Vo-Cal inherits the evidence so it never pays twice. Add Vo-Cal-specific failures as they're earned (they will be).

## Capture path (Serein production incidents — the expensive ones)

- **Putting any non-audio subsystem on the capture path.** Recovery-scanner lifecycle notifications killed live recordings (March 2026). Eager relay-worker startup consumed the voice intent's authorization window (April 2026). A single wedged upload blocked all subsequent captures for hours. Same root cause every time: something that had no business on the capture path was on it. The mechanical test: delete the subsystem — if capture still works, it must not gate capture.
- **Treating iOS notifications as commands.** Route-change handlers treated informational events (`.categoryChange`) as hardware failure and tore down healthy sessions — five distinct bugs. Default response to a notification is non-destructive; destruction requires evidence (byte-flow loss, hardware change, timeout).
- **Propagating an asymmetry instead of questioning it.** Voice finalization deferred commit until unlock because of a wrong file-protection assumption one agent made; subsequent agents added guards "for consistency." Real fix was `.completeUntilFirstUserAuthentication` on the file — the deferred path shouldn't have existed.
- **Auto-resuming after audio interruption.** Pause + seal + explicit user resume (5-min auto-finalize) is the contract; auto-resume recorded dead air or fought the OS.

## Architecture

- **Same storage becomes same authority.** The outbox had the DB handle, so retry/lease/polling logic accreted onto it — capture durability coupled to transport policy. Stores record facts; planners decide; workers execute. Guards bolted onto wrong ownership are evidence of the wrong boundary, not safety.
- **Narrow-patching a failure-class bug.** If the architecture permits the *class*, the instance fix is new debt. Name the class before writing the fix.
- **Deriving truth from mutable flags** (`if phase == .committed { showSaved = true }`). Re-derived truth drifts; require the receipt/proof type.
- **Silent early returns on the durability path.** `guard ... else { return }` hides invariant drift exactly where it matters most.

## Earned here (the 2026-10-22 endpoint audit, on a real local stack)

- **Reading a person's whole table and taking the max in Python.** PostgREST answers at most 1000 rows in no promised order: past the thousandth version the newest fell out, the "latest" was old, and every append collided for good. Ask the database for the newest row (`order_by="version", descending=True, limit=1`); page anything that must be whole (`db.every_row`). `FakeDatabase(max_rows=...)` answers as PostgREST does, so a test can prove it.
- **A version read-modify-write outside the store.** Twelve of twelve concurrent toggles lost a change and bursts answered 500. The store owns the version and the conflict; the caller passes its merge, which reruns on the version it lands after (`TrackingStore.append`, `MealPlanStore.append`); a burst it cannot carry is a 409.
- **A grammar run across an input it was not written for.** The composed-meal reader (one spoken meal: a dish and its contents) run over a drafted day zeroed a burrito bowl beside chicken. A plan's items are not one sentence; each grammar names the input it reads.
- **A line counted from exact values beside a number the phone draws whole.** Python rounds a half to even, Swift away from zero: "1,620 left" sat under a numeral of 1,621, and a gap under half a gram printed "0 g to optimal". Count every printed figure from the wholes the phone draws.
- **A fake that answers any input, served where real records live.** The photo and receipt fixtures answer every image; a hosted deployment missing its key would have handed every person the fixture's foods as if read. Recorded answers only in the suite or against a local database (`recorded_answers_allowed`).

## Agent workflow (observed in real Serein/Codex sessions — pure waste)

- **Fixing compile errors one at a time** → 3–5 sequential 30–90s builds for one logical fix.
- **Running the sim self-test to check compilation** → paying for simulator boot + 12 scenarios to learn what `ios-app-build` says in seconds.
- **Guessing file paths** (`AppDelegate.swift` that doesn't exist) instead of searching first.
- **Trusting Apple docs for safety-critical behavior** without device verification (liveUpdates cadence, `stationary` reliability, ActivityKit background requests — all differed from docs).
- **Re-reading the same large file repeatedly across turns** instead of extracting the needed sections to `.tmp/`.

## Product discipline (pre-registered for Vo-Cal — the predictable temptations)

- **"While we're here" scope creep into the out-of-scope list.** Social, payments, restaurant DBs and gamification are explicitly out; any task that seems to need one stops and asks. (Photo and typed logging left this list on 2026-09-24 by Lorenzo's instruction, decision 52, with voice kept as the emphasized way in.)
- **Optimistic UI on trust surfaces.** A premature "Logged"/"Listening" that turns out false costs more trust than slower honest states — the single most trust-eroding failure is acknowledged-start-while-silently-not-listening (Serein doctrine).
- **Letting the LLM near arithmetic.** Macro totals, conversions, thresholds, protocol targets: deterministic code only. A parse that "looks right" with invented numbers poisons the trust loop invisibly.
