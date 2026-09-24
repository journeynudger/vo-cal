# Questions ledger (Phase 7.6)

Stop-and-ask items decided provisionally in the owner's absence, each with the options and
the recommendation. Provisional choices preserve current behavior where one existed.
Date: 2026-09-23.

| # | Question | Options | Provisional choice | Recommendation |
|---|---|---|---|---|
| 1 | Who runs the purge of tombstones past 30 days? | (a) operator calls `POST /admin/meals/purge-deleted` by hand; (b) a scheduled GitHub workflow with an admin token; (c) a Fly cron machine. | (a): the sweep exists, audited, dry-run first; nothing runs unattended. | (b) monthly, once an admin token has a home in the repository's secrets. |
| 2 | Should a learned name apply after one rename or two? | (a) at once (current); (b) after the same rename twice; (c) at once, but only when the rename kept the food's identity class. | (a): the teaching gesture works the first time and Forget is one tap. | Keep (a) through the beta; revisit if the findings ledger's item 6 shows up in feedback. |
| 3 | May the upload worker take a "network back" trigger through `NWPathMonitor`, which needs a `DispatchQueue` that TIDY-CONC-001 bans? | (a) no trigger (current: scene-active kick plus the planner's wake); (b) allow one named exception in the rule; (c) poll reachability on the wake schedule. | (a). | (b) with the exception path named in the rule's `expectedPaths`, if offline-to-online latency matters to the beta. |
| 4 | Enable GitHub branch protection on `main` requiring the API, Libraries and iOS app checks? | (a) enable now; (b) leave merges unguarded. | Not enabled: a repository setting is the owner's to change. The ship's CI run on `main` (4d4bcd1, run 35928561205) is green on all three jobs, so the payload is ready: `gh api -X PUT repos/journeynudger/vo-cal/branches/main/protection --input docs/restructure/branch-protection.json`. | (a), with that command; the owner can loosen it in the repository settings. |
| 5 | Should the iOS app post client metrics to `POST /metrics/client` so the beta-gate numbers exist? | (a) yes, durations and counts only; (b) drop the endpoint and the doc claim. | Neither: unchanged, recorded in the findings ledger (item 1). | (a), scoped to log duration and funnel step, reviewed against MUST NOT #5 before it ships. |
| 6 | Fly: delete the two empty Vocal organizations and review the Beacon organization's started machine on a suspended app? | (a) delete `vocal`, `vocal-262`; stop the machine; (b) leave. | Untouched (other organizations). | (a); the invoice is only visible in the dashboard, so confirm the plan tier there first. |
| 7 | A capture made while browsing a past day resumes to its recording day (findings 3): add a move-meal-day edit, or record the intended day at capture time? | (a) leave; (b) move-meal-day edit on the meal screen; (c) intent record in the ledger. | (a). | (b): it also fixes a wrongly dated meal made any other way. |
| 8 | Keep `web/` (the landing page) in this repository? | (a) keep as the only copy; (b) move it to its own repository or host and delete it here; (c) delete. | (a). | (b) if it is ever deployed; (c) if the native app's App Store page is the landing page now. |
| 9 | Keep the "avg N% sure" badge on Today's Logged section? (Rams audit F6) | (a) keep; (b) cut from Today, keep per-meal confidence on the meal screen. | (a), unchanged: the owner chose its dress in August. | (b). |
| 10 | Keep "reach 100%" as the certainty layer's wording? (Rams audit F7) | (a) keep; (b) "Add a detail and the estimate sharpens". | (a). | (b). |
| 11 | The nutritionist's photo as a side piece (Rams audit F8)? | (a) no photo, as decided; (b) a photo as an attachment the person can look at later, never priced by the parser; (c) photo pricing. | (a). | (a) through the beta; (b) if testers ask, never (c). |

## From the accessibility audit, 2026-09-24 (`bin/ios-ui-audit`; docs/UI_VERIFICATION.md)

12. **Should the theme fonts scale with Dynamic Type?** Every `VoCalTheme.Fonts` face is a fixed point size (`Font.system(size:)`), so Xcode's audit flags 74 labels on Today and the settings pages as "Dynamic Type font sizes are unsupported"; the render matrix at accessibility sizes therefore shows the same text as at the default size. Scaling them (`relativeTo:` text styles) changes how every screen lays out at large sizes and needs the goldens re-recorded on purpose. Until decided, the audit ratchets this category at its current count.

13. **Is the muted ink on cream (#8A8A8E on #FAF9F6, about 3.3:1) the palette or a defect?** The audit reports 54 contrast failures or near passes on the same screens, all secondary labels in the muted token. A darker muted token passes 4.5:1 and changes the look of every card. Until decided, the audit ratchets contrast at its current count.

