# `/goal` prompt — Quill 1.0

Two messages, because `/goal` accepts at most 4,000 characters:

1. **Kickoff** (§1) — sent first, as a normal message. It loads the context,
   the rules and the procedure, and asks Claude not to start yet.
2. **Goal** (§2) — sent second, after `/goal `. Only the end-state condition,
   short and checkable.

Both point at §3, the binding rules. The plan is [PLAN.md](PLAN.md); progress
lives in [STATUS.md](STATUS.md).

---

## 1. Kickoff message (send first, as a normal message)

--- BEGIN KICKOFF ---

You are going to build Quill 1.0 by executing docs/initiatives/quill/PLAN.md task by task, in order, from the first task in docs/initiatives/quill/STATUS.md that is not `done`, up to P6-T5.

Before anything else, read in full: docs/initiatives/quill/README.md, PRODUCT.md, ARCHITECTURE.md, PROVIDERS.md, BENCH.md, PLAN.md, STATUS.md and GOAL.md, and the rules in .claude/rules/ (language-policy, repo-conventions, testing-conventions, conversational-agent-contract, llm-memory-layers).

The documents are the specification. Where they define a rule in one place — direct apply in PRODUCT F2, consent in ARCHITECTURE §5.3, the too-long suggestion in ARCHITECTURE §4.4, ModelKit amendments in PROVIDERS §8 — implement exactly that. If two documents disagree, stop and ask; do not pick one silently.

The rules in GOAL.md §3 are binding for the whole run. Breaking any of them means the goal is not met, whatever else is true.

Procedure for every task:
1. Mark it `in progress` in STATUS.md.
2. Implement it; meet its Accept criteria; actually run its Verify steps and PLAN §1's checks (forced rebuild with zero warnings, tests green, `verify.sh` from P0-T2 on).
3. Update the affected documents, set the task to `done` with its commit's short hash in STATUS.md, and commit the task on its own (Conventional Commits, scope `quill`, English).
4. Move to the next task.

At an owner session (OS1–OS7, PLAN §2), or when a README open question blocks the next task: mark the task `blocked (OSn)`, commit, and end the turn with a short checklist for me — what to do, where, how long, and what you will verify afterwards. Continue with tasks that do not depend on it, as that session's default allows; otherwise wait for me.

Reply now with: the first three tasks you will do, the first owner session you expect to reach and when, and any contradiction you found while reading. Then wait for my `/goal` message before writing code.

--- END KICKOFF ---

## 2. Goal message (send second, after `/goal `)

--- BEGIN GOAL ---

Quill 1.0 is built per docs/initiatives/quill/PLAN.md, following the kickoff procedure and the binding rules in docs/initiatives/quill/GOAL.md §3. The goal is met only when ALL of these are true at once, each checked by running it, not inferred:

1. STATUS.md shows every task P0-T1…P6-T5 as `done` with its commit's short hash, and OS1–OS7 each with the date held. Every task was committed on its own and left the build green.
2. `native/quill/Scripts/verify.sh` exits 0 on the working branch and on a clean clone (`git clone --branch <branch>` into a temporary directory).
3. A forced rebuild (`touch` every .swift, then `swift build --build-tests`) prints zero warnings, and `swift test` passes, in both `native/quill` and `native`.
4. A fresh `native/Scripts/export-public.sh` export contains nothing matching "quill" (`grep -rqi` finds nothing).
5. `native/quill/Scripts/check-matrix.sh` passes on docs/initiatives/quill/SPIKES.md and QA.md, and neither has a row in `pending` or `fail`.
6. Every built-in profile that ships has a `ready (confirmed)` gate verdict on at least one hosted model, on the release build's prompt hashes; any that could not reach it is removed from the shipped set and recorded in README.md. `tools/QuillBench/data/readiness.json` was regenerated from the committed baselines and is the copy inside the release app.
7. `tools/QuillBench/data/cases/holdout.lock` changed after its first commit only in commits carrying an owner-approved `Holdout-Change:` trailer, and `gate-v1.json` thresholds and repeats are unchanged since that commit.
8. The release DMG is notarized and stapled (`xcrun stapler validate` passes, `spctl --assess --type execute` accepts the app), uses the final bundle id from OS4, and OS5 was held on that exact DMG.
9. With my go-ahead, the work is merged to `main` through a PR quoting the final `verify.sh` output, and the tag `1.0` exists on `main`.
10. No rule in GOAL.md §3 was broken during the run: nothing weakened to pass, no push before OS4 approval, no key typed or security setting changed by Claude, no hosted spend beyond the OS3 budget, no secrets or personal texts committed.

At owner sessions and blockers, stop cleanly as the kickoff says; do not loop.

--- END GOAL ---

---

## 3. Binding rules

**Quality and integrity**
- PLAN §1 applies to every task: Accept criteria met and Verify steps
  actually run; zero warnings; tests green; English code and docs; Spanish
  fixtures, word lists and prompt texts in JSON resources; affected docs and
  STATUS.md updated in the same commit.
- If a check fails, fix the cause. Never weaken, skip or delete a test, a
  guard, a gate threshold, a hook, the export exclusion or a Verify step to
  make something pass. Never edit `gate-v1.json` thresholds or repeats; never
  edit or delete holdout cases outside BENCH §2.3.
- A Verify step that proves impossible as written may be changed only if the
  new one is at least as strict; say so in the commit message.
- Keep the holdout out of the tuning context: write it in a separate session
  or subagent (P1-T6), and never open holdout files or sealed failures while
  tuning.

**What only the owner does**
- Never push, open a PR or merge before the owner's approval at OS4; never
  force-push; never push to `main` directly.
- Never type a real API key, password or token; never change system or
  security settings (Accessibility grants, clipboard privacy, Keychain
  prompts, user accounts); never send a message from a real account.
- Hosted-model spend only within the budget approved at OS3 (README Q9),
  enforced with `--budget` and `--total-budget`; never run a hosted bench
  without them.

**Boundaries**
- Do not modify AGENTS.md, `.opencode/`, `templates/`, or Ámbar's behaviour.
  AppCore changes are backwards-compatible additions only, and exported files
  under `native/` never name Quill.
- Never put secrets, keys, personal texts or personal bench cases in the
  repository.

**Escalation**
- Owner sessions and blocking open questions: as in the kickoff — mark
  `blocked (OSn)`, commit, give the owner a checklist, continue only with
  independent tasks.
- Any other blocker outside reach (missing tool, platform behaviour that
  contradicts the plan, a measured fact that invalidates a decision): stop,
  record it in STATUS.md with the evidence, propose the smallest change to the
  plan, and wait for the owner's decision. Never redesign silently.

## 4. How to run it

1. Open a Claude Code session on the branch that holds this plan.
2. Send §1 as a normal message and read the reply: it should name P0-T1,
   P0-T2, P0-T3 and expect OS1 during P0-T2.
3. Send `/goal ` followed by §2.
4. At each stop, do the checklist and reply "done" (or answer the question).

`/goal` with no arguments shows progress; `/goal clear` cancels. A new session
resumes from STATUS.md: send §1 again, then §2.

| Phase | Owner sessions it reaches |
|---|---|
| P0 | OS1, OS2 |
| P1 | OS3 (any time from P1-T7a) |
| P2–P3 | — |
| P4 | OS7 (after P4-T1) |
| P5 | — |
| P6 | OS4, OS6, OS5 |
