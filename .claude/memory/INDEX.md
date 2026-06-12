# Memory Index

Shared session memory for Vo-Cal. Read once at session start, refer back as needed. Keep concise — every line gets paid for at every session boot.

| File | Read when |
|------|-----------|
| `architecture.md` | Touching the codebase. Stack, repo layout, data model, verification tiers, project-wide rules. |
| `product.md` | Discussing scope or roadmap. Thesis, P0 scope, phase status, beta gate, open threads. |
| `decisions.md` | Before proposing an approach. Frozen decisions with rationale — don't re-litigate, amend. |
| `patterns-that-worked.md` | Choosing an approach. Validated techniques inherited from Beacon/Serein/doccure + earned here. |
| `patterns-that-failed.md` | Choosing an approach. Failures already paid for (mostly Serein production incidents). Don't pay twice. |
| `glossary.md` | A term is unfamiliar. Claim ladder, FDC, CAF, corrections, usuals, etc. |
| `people.md` | A name comes up. Solo project; beta roster lands during Phase I. |

When a fact changes, edit the file in place. Do not append revision history. Decisions move only via an amendment in `decisions.md` + the master plan's Amendments log.

Status note: created at planning time, before any code exists. `architecture.md` describes the *planned* system — phases A–I make it real; update as they land.
