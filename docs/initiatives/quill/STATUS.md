# Quill — execution status

One row per PLAN task, in order. Updated in the same commit that completes a
task: the state becomes `done`. A commit cannot contain its own hash, so the
commit column of a task is filled in by the **next** task's commit (the last
one by a closing commit). States: `todo` · `in progress` · `done` · `blocked (OSn)` — waiting for
an owner session — · `blocked (reason)`.

Owner sessions (PLAN §2): OS1 2026-10-03 · OS2 — · OS3 2026-10-04 · OS4 — · OS5 — · OS6 — · OS7 —
(replace — with the date once held).

| Task | Title | State | Commit |
|---|---|---|---|
| P0-T1 | Quill's package, ModelKit moved, repository hygiene | done | ee2d20ee |
| P0-T2 | App skeleton, signing, debug hooks, verify script | done | 15e51215 |
| P0-T3 | SelectionKit foundations, logging, probe, picker harness | done | d6b92ec1 |
| P0-T4 | Spikes S1–S3: the app matrix | blocked (OS2) | — |
| P1-T0a | ModelKit contract amendments | done | 5f830603 |
| P1-T0b | Provider-specific amendments | done | 3b5840ef |
| P1-T1 | Profile model and built-in profiles | done | 8795fe19 |
| P1-T2 | PromptComposer | done | 24e69f54 |
| P1-T3 | Output guards G1–G13 | done | 8b6a830a |
| P1-T4 | GenerationEngine | done | da14d453 |
| P1-T5 | Evaluation and the case schema | done | c6ff4cf2 |
| P1-T6 | Case set, thresholds, judge rubric | done | 3cec867d |
| P1-T7a | `quill-bench` runs, budget and keys | done | 979f531f |
| P1-T7b | `quill-bench` gate, verdicts and readiness | done | 43edb606 |
| P1-T8 | On-device baseline and tuning | done | 087195e6 |
| P1-T9 | Hosted run | done | d214314f |
| P1-T10 | Checkpoint: provider defaults | done | — |
| P2-T1 | Fakes and pasteboard tests | done | e583c1e0 |
| P2-T2 | Capture sequence | done | 507b7e56 |
| P2-T3 | Replace sequence | done | bc4caf2a |
| P2-T4 | Selection bounds | done | 13066508 |
| P2-T5 | Live matrix regression | done | 0e2bb11a |
| P3-T1 | Stores | done | 6886e4ff |
| P3-T2 | Menu bar, hot key, permission state | done | 4f5fccfd |
| P3-T3 | RewriteSession view model | done | 39caea7e |
| P3-T4 | Picker panel | done | e4af26de |
| P3-T5 | Apply, copy, direct apply, toast | done | b70a940b |
| P3-T6 | Services entry (send-only) | blocked (OS6: replacing from the real contextual menu, QA Q-25) | 1560bd19 |
| P3-T7 | Presentation mapping | done | dc2333c6 |
| P3-T8 | End-to-end QA, first pass | blocked (OS7: owner-run rows; agent rows done in QA.md) | — |
| P4-T1 | Providers & models pane | done | baa96f14 |
| P4-T2 | Profiles pane | done | ce5199c2 |
| P4-T3 | Apps pane | done | c38516a9 |
| P4-T4 | "Correct…" (⌘E) | done | 3de28c21 |
| P4-T5 | General pane and About | done | 4de253eb |
| P4-T6 | End-to-end QA, second pass | blocked (OS7: hosted keys; keystroke rows as P3-T8) | — |
| P5-T1 | Onboarding | done | cbc83267 |
| P5-T2 | Localization | done | a93ad1b5 |
| P5-T3 | Accessibility of Quill's own UI | done | c5db1855 |
| P5-T4 | Performance pass | done | 274e9f44 |
| P5-T5 | Privacy pass | done | 55b9ff20 |
| P6-T1 | Verification gate | blocked (OS4: Q10, the Forgejo runner; verify.sh passes on a clean clone) | 10647f53 |
| P6-T2 | Final name, packaging and notarization | done | a9765a53 |
| P6-T3 | Release checklist and 1.0 | todo | — |
| P6-T4 | Distribution | in progress (published ahead of P6-T3 at the owner's request, 2026-10-05: public repository and GitHub release v1.0.0 with the DMG; quill.rrios.dev in rrios-dev/rrios.dev PR #15, awaiting merge) | — |
| P6-T5 | Merge and tag | todo | — |
