# Quill — rewrite selected text with profiles (macOS)

> **Product name** (Q1, 2026-10-05). Status: **in development**,
> following [PLAN.md](PLAN.md) task by task; progress in [STATUS.md](STATUS.md).
> Started 2026-10-03.

## Documents

| Document | Answers |
|---|---|
| [PRODUCT.md](PRODUCT.md) | What the app does, for whom, flows, built-in profiles, quality and privacy promises, non-goals. |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Packages, the rewrite pipeline, reading and replacing text in other apps, profiles, prompts, guards, storage, distribution, CI. |
| [PROVIDERS.md](PROVIDERS.md) | The model-provider contract and the catalogue of providers with their tradeoffs. |
| [BENCH.md](BENCH.md) | How rewrite quality is measured and gated. |
| [PLAN.md](PLAN.md) | Phases, tasks with acceptance criteria, owner touchpoints, risks. |
| [AUDIT.md](AUDIT.md) | The audit rounds this plan went through before development. |
| [SPIKES.md](SPIKES.md) | The app matrix: which capture and replace strategy works where. |
| [STATUS.md](STATUS.md) | Execution progress, one row per task. |
| [GOAL.md](GOAL.md) | The `/goal` prompt that runs the whole plan. |

## The problem

Writing in a hurry produces text with the wrong register, typos and clumsy
semantics, and the fix depends on who reads it: a colleague on Teams, a legal
counterpart, a friend. macOS Writing Tools rewrites, but has no user-defined
profiles and does not show up in apps such as Teams or Slack.

## Decisions

| # | Decision | Why |
|---|---|---|
| D-01 | **A new app**, not a feature of Ámbar. | Separate product, separate permissions story; Ámbar stays a clipboard manager. |
| D-02 | **Distributed outside the Mac App Store** (Developer ID, notarized, Hardened Runtime, no App Sandbox). | Rewriting in place in apps like Teams needs to read the selection and paste the result. App Sandbox forbids the Accessibility API, and App Review rejects synthetic ⌘C/⌘V under guideline 2.4.5 even where it is technically possible. |
| D-03 | **Provider-agnostic model layer** behind one contract. | Free/private vs. strong/paid is a real tradeoff and the user's choice. |
| D-04 | Providers: **Apple Intelligence on-device, OpenRouter, Vercel AI Gateway, OpenAI**, plus any OpenAI-compatible server (Ollama, LM Studio). | Free and private; one key for many models; one vendor with no intermediary. |
| D-05 | **No Private Cloud Compute.** | Apple grants the entitlement only to App Store apps. The unofficial `fm` CLI route is not adopted: any OS update can break it. |
| D-06 | Each provider's **advantages and drawbacks are shown**, derived from checkable facts. | The user chooses knowingly; the copy cannot contradict the facts. |
| D-07 | **Quill's own SwiftPM package** at `native/quill/`, excluded from Ámbar's public export, reusing `AppCore` and `GlassUI` by path. | Ámbar's export copies all of `native/`; a separate package keeps Quill out of it without rewriting the export. |
| D-08 | **Paste is the primary replacement path**; accessibility writes are a per-app fallback. | Accessibility writes can report success without changing the field and bypass the host's undo; a paste is one native undo step. |
| D-09 | **The model's output is untrusted**: deterministic guards run on every result, and a flagged result is never applied without explicit confirmation. | The small model invents, inverts and echoes (measured); hosted models are better but not infallible. |
| D-10 | **A bench gates profile quality** before the app is built on top of it. | "Refine a profile" needs a way to tell better from worse; the on-device model's fragility makes guessing expensive. |
| D-11 | **No telemetry, no history in the MVP**; text goes only to the chosen provider. | Privacy promise (PRODUCT §7); history is a later, opt-in feature. |
| D-12 | **macOS 26 minimum**, Spanish and English UI for the MVP. | Same floor as Ámbar and Foundation Models; the owner's language plus the widest second one. |
| D-13 | **Services entry is send-only.** | A send-and-return service blocks the host app until it returns; an interactive picker cannot answer in time. The service only delivers the text; replacement uses the normal path. |
| D-14 | **Editable means "the selected text is settable"** — or a per-app editable signal backed by a spike row — and terminals are read-only. | A text role alone would paste into iTerm2 and run text in a shell (found by the audit's probe). |
| D-15 | **Examples follow the memory-layer mould** (`llm-memory-layers.md`): caps, a personal-data screen on save and on use, a token budget, deletion purged from versions. | They are persisted user text that travels with every rewrite of their profile. |
| D-16 | **No silent model fallback.** A profile pinned to an unavailable model fails with "Choose a model". | A user who pins a profile to the on-device model does it for privacy; substituting a hosted model would break that. |
| D-17 | **The bench gates on locked holdout cases** with thresholds frozen before any run; critical cases must pass every repeat; rewrite profiles need a judge from another vendor; actual cost is metered against the budget. | Tuning and grading on the same cases overfits; an average hides a safety case that fails one run in three; meaning cannot be checked lexically. |
| D-18 | **A local verification script is the merge gate** (`native/quill/Scripts/verify.sh`), not a hosted CI workflow. | The repository's Forgejo runs only `.forgejo/workflows/` on a non-Mac runner; GitHub workflows never run. A Mac runner is optional (Q10). |
| D-19 | **Quill reads the general clipboard only when its access behaviour is Always Allow** — today's effective value on macOS 26, where the policy is not enforced by default. Where it is enforced, onboarding offers a deliberate check that gets Quill listed, then links to the setting; without Always Allow a paste leaves the rewrite on the clipboard and the ⌘C fallback is unavailable. | In Ask mode every read could raise an alert mid-paste and send ⌘V to the wrong place; an app is not listed in System Settings until it has triggered an alert. |
| D-20 | **Direct apply only on the paste path**, never on accessibility-write apps or with any flag. | Only a paste lands in the host's undo stack; an automatic action the user cannot undo breaks the conversational-agent contract (§4.4). |

## Open questions

Each has a default so that development does not stop; the deadline is the
task that cannot proceed without the answer.

| # | Question | Default until answered | Needed by |
|---|---|---|---|
| Q1 | Product name and bundle id. | Codename Quill, bundle id `dev.rrios.quill` for development builds only; onboarding uses a product-name constant. **Answered 2026-10-05: the product is Quill, bundle id `dev.rrios.quill`** — the codename stays, so no rename and no fresh Accessibility grant. | Owner session OS4, before P6. Hard stop at P6-T2: the bundle id cannot change after a distributed build without losing every user's Accessibility grant. |
| Q2 | License and price: free like Ámbar, paid, or freemium? Public source mirror? | Free, closed, no mirror. **Answered 2026-10-05: free and open source (MIT), public repository github.com/rrios-dev/quill — one snapshot per release, exported by `native/quill/Scripts/export-public.sh`.** | P6-T4 |
| Q3 | More UI languages than Spanish and English? | No (more can follow 1.0). **Confirmed at OS3 (2026-10-04): Spanish and English only.** | Confirmed at OS3, before P5-T2. |
| Q4 | Default global shortcut. | **⌃⌥R** (OS3, 2026-10-04: the owner wanted something simpler than the first default, ⌃⌥⌘R) — R for "rewrite", two modifiers, no macOS default shortcut; ⌥⌘R is Safari's "Reload Page From Origin" and ⇧⌘R is its Reader. A double tap of ⌥ was offered as the simplest option and left for later (it needs its own key monitor). The user can change it in onboarding and Settings. | Confirmed at OS3, before P3-T2. |
| Q5 | First-run provider when Apple Intelligence is available. | Preselect the on-device model only when the bench says "works well" (ready, confirmed) for the built-in profiles — "may need review" does not count; otherwise recommend a hosted model. **P1-T10, first pass:** `readiness.json` labels the on-device model "not recommended" for all four built-ins, so the default applies — onboarding recommends a hosted model. **Second pass, after P1-T9 (2026-10-04):** unchanged — the on-device model is "not recommended" for all four built-ins on macOS 26 and 27. | OS4 |
| Q6 | Recommended model ids per hosted provider. | The best-scoring models of the P1-T9 run (measured through OpenRouter), mapped to Vercel and OpenAI by canonical model identity; none where nothing maps. **P1-T10, second pass (after P1-T9, 2026-10-04):** OpenRouter and Vercel AI Gateway recommend `google/gemini-3.8-flash` (works well on all four built-ins) and `openai/gpt-6-luna` (Work and Formal); OpenAI recommends `gpt-6-luna`; Gemini has no OpenAI-direct equivalent. No built-in is removed: all four are ready on Gemini. The Vercel ids assume its catalogue names the models as OpenRouter does (not checked: no Vercel key); a recommended id the catalogue does not list is simply not marked. In `AppEnvironment.recommendedModels`; `RecommendedModelsTests` checks them against `readiness.json`. | OS4 |
| Q7 | Rewrite history (U10): ship at all, and when? | Not in 1.0. | After 1.0 |
| Q8 | Download page and domain. | None until Q1 and Q2. **Answered 2026-10-05: quill.rrios.dev, part of rrios.dev like Ámbar and Tessera; `quill.rrios.dev/download` redirects to the newest DMG, attached to its GitHub release.** | P6-T4 |
| Q9 | Bench budget for hosted models, and one API key. | **Approved at OS3 (2026-10-04): 15 USD in total, recorded in `tools/QuillBench/data/budget.json` with ≤ 5 USD per run; the OpenRouter key is in the bench's Keychain service.** Before: no hosted spend; P1-T9 waited. Proposed: ≤ 5 USD per run and ≤ 20 USD for all tuning. **Dry-run figures (P1-T8, prices of 2026-10-03, judge `anthropic/claude-sonnet-5.5` on the rewrite profiles)**, per model, for one development run of all four profiles (64 cases × 3 repeats + 96 judge calls): `google/gemini-3.8-flash` $0.54 (upper bound $7.95), `openai/gpt-6-luna` $0.39 ($6.16), `openai/gpt-5.4-mini` $0.56 ($8.31) — the same through OpenRouter, Vercel or OpenAI. Two confirming gate runs (32 holdout cases × 3 each) cost about one development run. Most of the cost is the judge. | Owner session OS3; required before P6-T3. |
| Q10 | Register the owner's Mac as a Forgejo runner so `verify.sh` also runs on PRs? | No; the local script is the gate (D-18). | OS4 |
| Q11 | Test on macOS 27 (a second Mac or a macOS 27 VM) before release? | No; macOS 27 rows are n/a and the risk (R14) is accepted explicitly at OS4. | OS4 |
| Q12 | Read WebKit selections (Mail's body) through text markers in the accessibility path, or keep the per-app ⌘C-only strategy? SPIKES.md D-S1. | ⌘C-only strategy for Mail (in place, works, S1-05); text markers recommended. | P2-T2 (capture sequence) |

## Measured on the bench (P1-T8, 2026-10-03)

The on-device model on the development cases, after three tuning rounds
(prompt texts v3: instructions in the input's language, same-language examples
last, explicit abbreviation and injection rules):

| Profile | Hard checks (development) | Verdict |
|---|---|---|
| Spelling only | 41 % | not ready (development 41 %) |
| Work | 74 % | not ready (development 74 %) |
| Formal / legal | 54 % | not ready (development 54 %) |
| Friends | 27 % | not ready (development 27 %) |

The gate refuses it (no development run reaches 95 %), so the on-device model
is labelled "not recommended" for every built-in in `readiness.json`. The CLI is
not rate-limited (30/30, PROVIDERS §8). The largest single fix was the
instruction language: with English instructions it answered Spanish text in
English (formal: 21 of 48 runs). Its remaining failures are genuine — missed
accents, expanded abbreviations the Friends profile keeps, an obeyed
injection, dropped emoji. Hosted models are measured in P1-T9 (after OS3).

## Measured on the bench (P1-T9, 2026-10-04)

Three hosted models through OpenRouter, judged by `anthropic/claude-sonnet-5.5`
(by `google/gemini-3.8-flash` for the OpenAI models on Work, see below), and
the on-device model again on macOS 27. Spent: **7.35 USD of the 15 approved**
(17 ledger entries). Verdicts on the holdout (`gate`), or on development cases
where the model never reached the 95 % the gate requires:

| Profile | `google/gemini-3.8-flash` | `openai/gpt-6-luna` | `openai/gpt-5.4-mini` | on-device (macOS 27) |
|---|---|---|---|---|
| Spelling only | **ready (confirmed)** | not ready (2nd gate run 91 %) | not ready (gate, a critical case) | not ready (development 43 %) |
| Friends | **ready (confirmed)** | not ready (development 87 %) | not ready (development 81 %) | not ready (development 16 %) |
| Work | **ready (confirmed)** | **ready (confirmed)** | not ready (gate 79 %) | not ready (development 54 %) |
| Formal / legal | **ready (confirmed)** | **ready (confirmed)** | not ready (development 81 %) | not ready (development 43 %) |

- **Every built-in ships** (BENCH §1.1: ready on at least one hosted model).
  Gemini is the only model ready on all four; judge means 4.7–4.9 of 5.
- **One tuning round**, on Work and Formal only: the first gate failed both
  on Gemini, and the development failures of the other two models pointed at
  the causes — tú and vosotros kept in Formal, colloquialisms (*ni de broma*)
  kept, paragraphs split into new line breaks, technical terms translated
  (*logs*), a proper name left without its accent. The profiles' guidance
  now says so (`builtins.json`); the strategy texts did not change, so the
  Spelling and Friends prompt hashes — and their confirmed verdicts — stayed.
  Luna went from 91 % to 100 % on both in development, and Gemini then passed
  both gates twice. `check-references`: every holdout reference passes.
- **Judge failure, voided and not counted**: on a Work holdout case Sonnet
  wrote notes over the rubric's 300 characters on both attempts (temperature
  0, so a retry repeats it), which voided Luna's and gpt-5.4-mini's Work gate
  runs. Those two were gated again with Gemini as judge, the other allowed
  judge from a different vendor.
- **The on-device model is worse on macOS 27** than on 26 on the prompts
  measured on both (Friends 27 % → 16 %; Spelling 41 % → 43 %). It stays
  "not recommended" everywhere; `readiness.json` keeps both majors, since
  the identity is per macOS major.
- gpt-5.4-mini obeyed an injected instruction on a Formal case (translated
  the text to French) — the guard caught it (G4, language changed).

## New built-ins (2026-10-04/05)

At the owner's request three built-ins were added — **Clean up dictation**,
**Concise** and **Synthesize** — and Formal / legal was renamed **Formal** (a
"legal" label invites contracts, where a changed nuance matters more than the
bench can show). Each got 16 development cases and 8 holdout cases written by a
separate agent (`Holdout-Change` in the commit), judged under rubric v2 /
gate v2 (rubric v1 plus the three definitions and a condensing note under
*meaning*; thresholds, repeats and judges unchanged). Spent: 4.68 USD, 12.03
of the 15 approved in total.

| Profile | `google/gemini-3.8-flash` | `openai/gpt-6-luna` | on-device (macOS 27) |
|---|---|---|---|
| Clean up dictation | **ready (confirmed)** | not ready (2nd gate run 91 %) | not ready (development 60 %) |
| Concise | **ready (confirmed)** | **ready (confirmed)** | not ready (development 50 %) |
| Synthesize | not ready (gate 87 %) | not ready (development 87 %) | not ready (development 29 %) |

- **Dictation and Concise ship** (picker numbers 5 and 6); **Synthesize does
  not** (BENCH §1.1): `BuiltInProfile.shipped` leaves it out of seeding,
  restoring and the menu, while the bench keeps measuring it.
- Development failures pointed at three guard behaviours that hurt condensing
  profiles and are worth fixing (each is a guard change, so an evaluation
  version bump and a re-gate of every profile, ≈ 3–5 USD — owner decision):
  a number or date the input repeats must appear as often in the output (a
  summary rightly says it once); a time range is parsed differently by wording
  ("desde aproximadamente la 1:40 hasta las 3:45" vs "de la 1:40 a las
  3:45"); a number written in words in the input and in digits in the output
  ("seis" → "6") reads as an added fact. Synthesize's guidance now asks for
  numbers as written and no generic heading ("Updates:" is taken for a
  preamble), which took Gemini from 83 % to 97 % in development; its holdout
  failures are sealed for the owner.

## Evidence that shaped the plan

Measured on the owner's Mac (M2 Max, macOS 26.6.2, Xcode 27 / SDK 27) on
2026-10-03:

- The on-device model is available, supports Spanish, and answers in 1–4 s.
- It is **fragile with prompts**. A plain prompt over-edited (invented greeting,
  signature and `[name]` placeholders) and once **reversed who asked for what**.
  With an example inlined in the instructions it **returned the example**.
  With strict "do not…" rules it **returned the input unchanged**.
- The M2 Max will not get the larger on-device model in macOS 27: AFM 3 Core
  Advanced requires an M3 or later with 12 GB.
- Reading the selection, replacing it and verifying the result through the
  Accessibility API works in TextEdit.
- A separate SwiftPM package can depend on Ámbar's package by path and link
  `AppCore` and `GlassUI`; the audit confirmed the exact nested layout
  (`native/quill` depending on `..`) builds with no warnings.
- On an Electron app the system-wide focus queries fail
  (`kAXErrorCannotComplete`); iTerm2's terminal is an `AXTextArea` with a
  settable value — both shaped the capture rules (ARCHITECTURE §3.1).
