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

## Agent workflow (observed in real Serein/Codex sessions — pure waste)

- **Fixing compile errors one at a time** → 3–5 sequential 30–90s builds for one logical fix.
- **Running the sim self-test to check compilation** → paying for simulator boot + 9 scenarios to learn what `ios-app-build` says in seconds.
- **Guessing file paths** (`AppDelegate.swift` that doesn't exist) instead of searching first.
- **Trusting Apple docs for safety-critical behavior** without device verification (liveUpdates cadence, `stationary` reliability, ActivityKit background requests — all differed from docs).
- **Re-reading the same large file repeatedly across turns** instead of extracting the needed sections to `.tmp/`.

## Product discipline (pre-registered for Vo-Cal — the predictable temptations)

- **"While we're here" scope creep into the out-of-scope list.** Photo logging, text-search food entry, restaurant DBs, and gamification are explicitly out; any task that seems to need one stops and asks.
- **Optimistic UI on trust surfaces.** A premature "Logged"/"Listening" that turns out false costs more trust than slower honest states — the single most trust-eroding failure is acknowledged-start-while-silently-not-listening (Serein doctrine).
- **Letting the LLM near arithmetic.** Macro totals, conversions, thresholds, protocol targets: deterministic code only. A parse that "looks right" with invented numbers poisons the trust loop invisibly.
