# Quill — implementation plan

Sequential plan from the current state to a released 1.0. Each task is small
enough for one or two working sessions, names what it produces, how it is
accepted and how it is verified. Tasks run in order. The things only the
owner can do are batched into seven short sessions (§2), each with a default
that lets work continue.

**Starting state (2026-10-03)**: `ModelKit` existed (provider contract, Apple
on-device and Chat Completions adapters, 31 tests: 29 run by default and green,
2 live tests passing with `MODELKIT_LIVE_APPLE=1`), committed in `b95a5ddf`
under `native/packages/ModelKit`. Progress from there is tracked in
[STATUS.md](STATUS.md).

## 1. Rules for every task

A task is done when:

1. Its **Accept** criteria hold, checked by its **Verify** steps.
2. The build has **zero warnings** after a forced rebuild, and tests are green:
   ```bash
   cd native/quill && find . -name '*.swift' -not -path './.build/*' -exec touch {} + \
     && test "$(swift build --build-tests 2>&1 | grep -c 'warning:')" = 0 && swift test
   ```
   The same in `native/` when a task touches Ámbar's package or shared code.
   From P0-T2 on, `Scripts/verify.sh` wraps these and the later checks
   (ARCHITECTURE §10) and is run at the end of every phase.
3. New code and docs are in English (`.claude/rules/language-policy.md`); UI
   copy has `es` and `en` entries. Spanish test fixtures and pattern lists
   (guard word lists, sample texts) live in JSON resources, not in `.swift`
   files — the repository's `lint-language` hook rejects Spanish in Swift
   source. Files exported to Ámbar's public repository — everything tracked under
   `native/` except `argos/`, `public/` and `quill/` — never name Quill.
4. Affected documents are updated in the same change, including the task's
   row in [STATUS.md](STATUS.md) (state `done` and the commit's short hash).
5. It is committed on its own (Conventional Commits, scope `quill`). Nothing
   is pushed without the owner's explicit go-ahead (repository policy).

Row states in SPIKES.md and QA.md — exactly these words, which
`Scripts/check-matrix.sh` enforces: **pass**; **limitation** (works as a
documented limitation in PRODUCT, e.g. Teams on the ⌘C fallback); **fail**
(the row's note gives the fix or the decision; a phase cannot exit with a
fail that has no fix in that phase); **pending** (waiting for an owner session); **n/a**
(with a reason: app not installed, needs macOS 27 — README Q11). The release
gate accepts pass, limitation and n/a.

**Who runs a row.** The agent drives native apps fully (TextEdit, Notes,
Mail, Word) but, in this environment, browsers are read-only and terminals
and IDEs click-only for it: no typing, no key presses. Rows in Safari,
Chrome, VS Code, Terminal and iTerm2, and every Teams/Slack row, are run in
owner sessions OS2, OS7 and OS6 from a checklist the agent prepares; the
agent records the results. A leak check (`! grep -rqi quill` on a fresh
export) is part of `verify.sh`, since later tasks edit exported files.

Sizes: **S** ≈ under half a session · **M** ≈ one session · **L** ≈ two sessions.

## 2. Owner sessions

| Session | When | What only the owner can do | Default meanwhile |
|---|---|---|---|
| OS1 · 5 min | During P0-T2 | Grant Accessibility to the debug build of Quill. | P0-T3's code is written and unit-tested; its live acceptance and P0-T4 wait. If OS1 is still missing after P0-T3's code, jump to P1 and return. |
| OS2 · 60 min | P0-T4 | Run the matrix rows the agent cannot drive (Safari, Chrome, VS Code, Terminal, iTerm2, Teams, Slack — draft messages, never sent); enable the clipboard policy's developer-preview switch for Quill, run S2 under Ask and Deny; enable the switch for TextEdit too and check whether Quill's synthetic ⌘V raises an alert there; switch everything off again. | The agent's native-app rows run; the others *pending*. |
| OS3 · 15 min | Any time from P1-T7a | Approve the bench budget (README Q9) and enter an **OpenRouter** API key with `Scripts/bench.sh keys set openrouter` — one key that reaches candidates and judges from several vendors. Review the sealed bench failures if any, and request holdout changes (BENCH §2.3). Confirm or change the UI languages and the default shortcut (Q3, Q4), so P3 and P5 do not need reopening. | P1-T9 waits; rewrite profiles stay "not evaluated"; hosted QA rows *pending*. |
| OS4 · 30 min | Before P6 | Product name and bundle id (Q1); icon direction; license and price (Q2); download page (Q8); provider defaults (Q5, Q6); review sealed bench failures if a built-in is blocked (BENCH §2.3); approval to push and open PRs; Forgejo macOS runner yes/no (Q10) and, if yes, its registration token; macOS 27 testing (Q11); more bench budget if P1-T9 ran out. | Development continues under the codename; P6 waits. |
| OS5 · 30 min | P6-T3, on the final DMG | In a clean macOS user account the owner creates: turn on the clipboard policy's developer-preview switch (so onboarding's clipboard step appears on macOS 26), install the release DMG, go through onboarding including the Accessibility grant and the clipboard step; then give (or withhold) the go-ahead to publish (P6-T4). | Release waits. |
| OS7 · 60 min | After P4-T1 | Enter API keys for OpenRouter, Vercel AI Gateway and OpenAI in Quill's Providers & models pane (so the agent can run hosted rows in native apps itself; a provider without an account is marked n/a and OS4 decides whether its preset ships); run every owner-run row of P3 on the finished flow — U1, U3, U4, U5 in Safari, Chrome, Teams and Slack, the picker over Safari, Services from Safari — so failures surface while there is time to fix them. | Those rows stay *pending* for OS6. |
| OS6 · 45 min | After P6-T2 (on a **debug** build with the final bundle id), before P6-T3 | **Regression pass**: grant Accessibility to that build (the new bundle id needs a fresh grant); allow Keychain access or re-enter keys if macOS asks after the rename; re-run every row still *pending* plus one pass per owner-run app (Safari, Chrome, VS Code, terminals, Teams, Slack), a real LAN custom server by `.local` name, and — if OS2 slipped — the clipboard Ask/Deny rows with the preview switch; run the P5-T5 host-logging pass — with `nettop -p <pid>` (preferred; `lsof -a -i -p <pid>` is a snapshot) watching Quill from outside, since the hook sees only Quill's own transport — and the live smoke check (one rewrite per configured provider). | Release waits. |

## 3. Phases

| Phase | Goal | Exit criterion |
|---|---|---|
| P0 | Foundations and spikes | Quill's package builds, is git-ignored correctly and excluded from Ámbar's export; `verify.sh` exists; SPIKES.md says which strategy works where. |
| P1 | ModelKit amendments, RewriteKit, the bench | On-device baseline committed (or the on-device model recorded as "not evaluated (CLI rate-limited)"); spelling-only built-ins measured; hosted dry-run estimates ready; hosted run done if OS3 happened. |
| P2 | SelectionKit | Capture and replace pass their unit tests and the live matrix regression. |
| P3 | Stores and the rewrite flow | U1, U3, U4, U5 work end to end on the matrix apps (QA.md). |
| P4 | Settings | U2, U6, U7, U8 work end to end (QA.md). |
| P5 | Onboarding, localization, accessibility, performance, privacy | Onboarding walkthrough passes; checks green; budgets met or explained; privacy checks pass (the host-logging part *pending* → OS6). |
| P6 | Release | A notarized DMG passes the release checklist. |

## 4. Tasks

### P0 — Foundations and spikes

**P0-T1 · Quill's package, ModelKit moved, repository hygiene** · M
- Create `native/quill/Package.swift` (tools 6.2, macOS 26, Swift 6 mode)
  with `.package(name: "Ambar", path: "..")`, and the leaf target
  `QuillSupport` (one placeholder source file, so SwiftPM does not warn;
  `QuillLog` arrives in P0-T3).
- Move `native/packages/ModelKit` → `native/quill/packages/ModelKit` and
  `native/Tests/ModelKitTests` → `native/quill/Tests/ModelKitTests`; remove the
  ModelKit product, target and test target from `native/Package.swift`.
- Add `native/quill/.build/`, `native/quill/.swiftpm/` and `native/quill/build/`
  to `.gitignore`;
  make `native/Scripts/export-public.sh` skip any top-level directory that
  holds a `.not-exported` marker file (a generic rule — the exported script
  must not name Quill), and add that marker to `native/quill/`. Remove the
  ModelKit comment in `native/Package.swift`.
- Update PROVIDERS §7's commands to `cd native/quill`, and
  `docs/architecture/native-platform.md` (a second Swift package under
  `native/`). `native/README.md` is exported publicly, so it is not changed
  and never names Quill.
- Accept: both packages build with zero warnings and pass `swift test` (31
  ModelKit tests now in Quill's package); nothing of Quill's is exported;
  build output is ignored.
- Verify:
  ```bash
  git add native/quill native/Package.swift native/Scripts/export-public.sh .gitignore
  D="$TMPDIR/ambar-export-check"; rm -rf "$D"; native/Scripts/export-public.sh "$D"
  test -z "$(find "$D" -mindepth 1 \( -path "$D/quill" -o -path "$D/quill/*" -o -name 'ModelKit*' \))"
  ! grep -rqi quill "$D"
  git check-ignore -q native/quill/.build/x && git check-ignore -q native/quill/.swiftpm/x \
    && git check-ignore -q native/quill/build/x
  ```
- If SwiftPM rejected the nested path dependency (the audit's probe showed it
  does not): move `AppCore` and `GlassUI` into a `native/shared/` package both
  depend on, and record it in ARCHITECTURE §1.

**P0-T2 · App skeleton, signing, debug hooks, verify script** · M · OS1
- `apps/Quill`: `LSUIElement` app with menu bar icon, Quit, and a Debug
  submenu (development builds) showing `AXIsProcessTrusted()`; `Info.plist`
  with bundle id `dev.rrios.quill` (until Q1); entitlements file with no keys
  (Hardened Runtime only); a placeholder icon (an SF Symbol rendered by the
  build; the final icon comes with the name in P6-T2); debug hooks
  `QUILL_DATA_DIR`, `QUILL_SUPPRESS_PROMPTS` (ARCHITECTURE §3.6; the others
  arrive with their tasks); the resource-bundle helper in `QuillSupport`
  (ARCHITECTURE §8), used by the app's first strings.
- `Scripts/make-app.sh` parameterised from Ámbar's (`debug` and `release`
  modes, each building to its own output path — `native/quill/build/debug/`
  and `native/quill/build/release/`, git-ignored and outside `.build`, which
  the self-check renames — so `verify.sh` can hold both;
  a `--bundle-id` override for the walkthrough and renamed builds;
  prints the path of the bundle it builds), signing with the Developer
  ID certificate (ARCHITECTURE §3.5), never ad hoc. Every live step before P6
  uses the debug build.
- `Scripts/verify.sh`: rule 2's commands plus app assembly, the codesign
  checks and the export leak check (fresh export, no "quill"); later tasks
  append their checks.
- Accept: the app launches from /Applications with its icon; codesign checks
  pass; after OS1, a rebuild + reinstall keeps the grant.
- Verify: `Scripts/verify.sh`; with `APP` the path `make-app.sh` printed:
  `codesign --verify --strict --verbose=2 "$APP"`; the Hardened Runtime
  check done the way Ámbar's `make-app.sh` does it — output captured in a
  variable and retried, because piping `codesign -d` into `grep -q` gives
  false negatives; the Debug item reads "trusted" after a rebuild.

**P0-T3 · SelectionKit foundations, logging, probe, picker harness** · L
- `SelectionKit` target (depends on `AppCore`) with the protocols
  `AccessibilityClient`, `PasteboardClient`, `KeyEventPoster`, `Clock` and their
  live implementations, plus the raw operations the spikes need (ARCHITECTURE
  §3.1–3.4): focused element with the fallback, messaging timeout, manual
  accessibility retry, subrole and settable checks, attributed-string check,
  bounds, ⌘C read, paste write with markers and `.currentHostOnly`,
  `accessBehavior` read, snapshot/restore with the `changeCount` guard,
  accessibility write.
- `QuillLog` in `QuillSupport` (ARCHITECTURE §6), used by all code from here on.
- Debug → **Probe frontmost app** (options: with or without enhanced
  accessibility; replace via paste or accessibility write; restore delay 150 /
  300 / 600 / 1000 ms), **Picker harness** and **Test fields** (a small window
  with a plain field, a rich-text field and a password field) (ARCHITECTURE §3.6);
  the harness shows a stand-in panel built with the picker's exact `NSPanel`
  configuration (Ámbar's flags, non-activating, key-capable), which P3-T4 reuses.
- Accept: unit tests cover the pure helpers (coordinate conversion, marker
  writing on a named pasteboard, rich-format detection on fixture attribute
  runs). After OS1: in TextEdit with a temporary document, the probe
  reproduces the 2026-10-03 manual result and a probe replace restores the
  clipboard; the picker harness opens over TextEdit without stealing its selection.
- Verify: `swift test --filter SelectionKitTests`; the Debug items over
  TextEdit; the probe row in `<data dir>/probe/`.

**P0-T4 · Spikes S1–S3: the app matrix** · L · OS2
- Apps: TextEdit, Notes, Mail (compose), Safari (textarea + static page),
  Chrome (textarea + static page), Microsoft Teams (compose box), Slack
  (compose box), Visual Studio Code (editor + integrated terminal), Terminal,
  iTerm2, Microsoft Word, a password field — Debug → Test fields (agent) and a
  Safari sign-in form (OS2) — which must be refused. Apps not installed are n/a.
- S1 capture: which path yields the selection; whether manual accessibility
  was needed; whether a lazy tree first answered with an empty selection;
  Teams with and without enhanced accessibility; side effects in the
  following minute.
- S2 replace: paste vs accessibility write; verification; ⌘Z undo; restore
  delay that works (150 / 300 / 600 / 1000 ms); rich text kept or lost; the
  clipboard question's behaviour (`accessBehavior` before and after answering).
- S3 picker focus: element-level focus return vs the pid fallback; selection
  kept while the picker is key; full-screen spaces of another app.
- `Scripts/check-matrix.sh <file>` asserts every row of a matrix file has a
  valid state (pass, limitation, fail, pending, n/a; a fail needs a note); every
  later "reviewed" Verify uses it.
- Output: `docs/initiatives/quill/SPIKES.md` — the matrix, the default restore
  delay, and the initial `AppStrategy` entries, each citing its row (the
  terminal denylist is a category rule: Terminal and iTerm2 are its tested
  representatives, and the other terminals cite them).
- Accept: every row has a state; the default strategy passes in TextEdit,
  Notes and Mail (agent) and in Safari and Chrome (OS2 — *pending* until then);
  the Test fields password field is refused (agent); terminals, VS Code's
  terminal and Safari's password field are refused or read-only-only (OS2 —
  *pending* until then).
- If Teams exposes no selection by any path: U1 in Teams runs on the ⌘C
  fallback with Paste anyway — which needs Always Allow clipboard access
  wherever the policy is enforced — recorded in PRODUCT as a known limitation
  and the rows marked *limitation*.
- Verify: `Scripts/check-matrix.sh docs/initiatives/quill/SPIKES.md`; every
  `AppStrategy` entry cites a row (grep).

### P1 — ModelKit amendments, RewriteKit, the bench

**P1-T0a · ModelKit contract amendments** · M
- PROVIDERS §8 items 1–3 and 7–8, plus item 4's protocol change: `finishReason`; `generate` as a protocol
  requirement (stream-based default kept); `prewarm(for:)` and async
  `estimateTokens(_:)` with defaults; `ModelDescriptor.pricing` and `vendor`;
  recipients that name the routed party, expressed as **typed recipients**
  (`.named("OpenRouter")`, `.routedInferenceProvider`, `.modelServingProvider`,
  `.host(String)`) that the app localizes — not English strings in data;
  `singleVendorCatalog`; `KeychainCredentialStore`'s doc comment.
- Accept: contract tests cover `finishReason` (`length` from a
  `finish_reason: "length"` chunk), pricing and vendor parsed from an
  OpenRouter model-list fixture, the defaults of `prewarm`, `estimateTokens`
  and `generate`; `ProviderDescriptorTests` asserts OpenRouter's and Vercel's
  recipients include the routed party and OpenAI's preset carries
  `singleVendorCatalog`.
- Verify: `swift test --filter ModelKitTests`.

**P1-T0b · Provider-specific amendments** · M
- PROVIDERS §8 items 4–6: on-device permissive guardrails, single-use
  prewarmed session, no `maximumResponseTokens`, framework `contextSize`,
  macOS 27 error types, `generate` via `respond`, the rate-limit retry on a
  fresh session; OpenRouter `data_collection: deny`; loopback note. A Debug →
  **Live provider test** item runs a 30-call on-device burst from inside the
  app; its result (rate-limited or not, after how many calls) is recorded in
  PROVIDERS §8.
- Accept: the `data_collection` field is in every OpenRouter request body;
  the macOS 27 mappings compile behind `#available`; the live on-device tests
  pass both under `swift test` and from the Debug item.
- Verify: `swift test --filter ModelKitTests`; `MODELKIT_LIVE_APPLE=1 swift
  test --filter AppleOnDeviceProviderTests`.

**P1-T1 · Profile model and built-in profiles** · M
- `RewriteKit` target; `Profile`, `ProfileSettings`, `Example`, `Sample`,
  validation (ARCHITECTURE §4.1, §4.3 caps, and the `spellingOnly` rules of
  PRODUCT §5); RewriteKit's first JSON resources (the built-ins' examples, the
  shared abbreviation table) loaded through the `QuillSupport` helper; the four built-ins exactly as the
  PRODUCT §5 table (ids `spelling`, `work`, `formal`, `friends`), each with
  two shipped examples written here.
- Accept: lossless round trip; typed errors for every cap; a test asserts
  each built-in's settings equal the PRODUCT §5 table.
- Verify: `swift test --filter ProfileTests`.

**P1-T2 · PromptComposer** · M
- Strategies, base rules (who does what always present), the
  override-own-subject rule, examples budget with oldest-first eviction,
  personal-identifier screen on read (examples and guidance), the bench's
  pinned example (added first, never evicted, excluded from the hash — BENCH
  §2.1 `exampleBait`), inert `spellingOnly` fields omitted, compact
  strategy's 60-word guidance cut, input as its own message, prompt hash over
  exactly the fields of ARCHITECTURE §4.4.
- Accept: golden files per built-in × strategy; compact under 120 words; the
  self-consistency test over every **valid** settings combination finds no rule with its
  opposite; an example containing an e-mail address is skipped and reported;
  the prompt hash changes with each of its inputs (temperature included) and
  not with name or symbol; compact sends at most 60 words of guidance.
- Verify: `swift test --filter PromptComposerTests` (goldens in
  `Tests/RewriteKitTests/Golden/`).

**P1-T3 · Output guards G1–G13** · M
- The guards' word lists are JSON resources, loaded through the helper built
  in P0-T2. The similarity function (normalised word-level edit distance)
  lives here, since G9 and G10 use it; P1-T5 reuses it.
- Accept: a table test per guard with positive and negative cases, including
  the measured failures — invented `[nombre]` (G2), invented greeting and
  signature (G6), an example returned instead of the input (G9) — and the
  false-positive traps: a multi-line rewrite whose first line changed and
  "Hola, Juan:" (G1 must not strip either); sentence-initial "Oye", "Te
  devuelvo", "I'm" (G3 must not flag); "1000" → "1.000", "3pm" → "15:00",
  "mil cosas" → "mucho trabajo" (G3); chat shorthand (G4); "ok" → "De acuerdo"
  under 6 words (G5); a refusal in Spanish and in English, and a rewrite that
  merely contains "lo siento" (G10); "ana" → "Ana" and "Maria" → "María"
  (G3 must not flag); a lost paragraph break (G3); "lo vemos luego" → "el 15
  de octubre" and an added link (G12 must flag); "Espero que te sirva" closing
  a rewrite (G13 must flag); a correct spelling fix of an input that is a near
  twin of an example's input (G9 must not flag) and a copied example output
  (G9 must flag); "Estimado Juan:" for "hola juan:" (G1 and G6 must not flag)
  and "Aquí está la versión mejorada:" (G1 must flag).
- Verify: `swift test --filter OutputGuardsTests`.

**P1-T4 · GenerationEngine** · M
- ARCHITECTURE §4.5 with the pre-check's output reserve.
- Accept: with a scripted provider, every transition is tested: `length` →
  `truncated`; G10 and `ProviderError.refused` → `refused`; each other code →
  `failed(code)`; `cancelled` → `cancelled`; a `contentFilter` finish →
  `refused`; G7 → `noChanges`; G8 → `failed(malformedResponse)`; a too-long
  input → `tooLong` without reaching the provider.
- Verify: `swift test --filter GenerationEngineTests`.

**P1-T5 · Evaluation and the case schema** · S
- The bench case type (BENCH §2's fields) is defined here, as Evaluation's
  input; P1-T6 fills it.
- Accept: hand-computed similarity values (the P1-T3 function); each hard check reported separately.
- Verify: `swift test --filter EvaluationTests`.

**P1-T6 · Case set, thresholds, judge rubric** · L
- `QuillBench` executable target skeleton (usage text only) with its data
  folders declared as excluded resources, and the `QuillBenchTests` target.
- 96 synthetic cases (BENCH §2.1, every category incl. `multiLine` and
  `noAddedFacts`; `exampleBait` cases with their own `injectExample`, in the
  [0.5, 0.8) band on normalised text) — the
  holdout written in a separate session or subagent from P1-T8's tuning — in
  `cases/dev/` and `cases/holdout/`; judge rubric v1 (with the judge's JSON
  schema); `gate-v1.json` (thresholds, minimum repeats, allowed judges from
  two vendors, rubric hash, maximum runs, release runs). The lock is created
  at the end of P1-T7b.
- Accept: `CaseSetTests` validates the schema and asserts per profile: every
  category ≥ 2 cases, 8 holdout cases covering every critical category plus
  `exampleBait` and `refusalBait`, every reference satisfying its case's
  `mustKeep`/`mustNotContain`, disjointness from shipped examples and PRODUCT
  §5 examples, every `exampleBait` input in [0.5, 0.8) similarity (normalised)
  to its own `injectExample` input and every injected example clear (< 0.8) of shipped
  and PRODUCT §5 examples, `critical` true exactly when a case has a
  critical category, and identical thresholds and minimum repeats across gate files. Case texts are
  JSON, so the language hook does not apply; every reference passes every
  guard with no flag and meets its change expectation (a one-off check in this
  task and at lock creation, not part of `verify.sh` — BENCH §2).
- Verify: `swift test --filter CaseSetTests`. The owner may review 10 random
  cases at any time; corrections land as a follow-up (adding or retiring
  holdout cases per BENCH §2.3).

**P1-T7a · `quill-bench` runs, budget and keys** · L
- `burst --model <id> --calls 30` (rate-limit measurement), `run` (development cases only; `--profiles`, `--models`, `--repeat`, `--judge`,
  `--dry-run`, `--budget`, `--allow-unpriced`, `--max-requests`, `--label`,
  `--cases`, `--total-budget`), `compare`, `keys set|remove`; `prices.json`; the
  spend ledger; `Scripts/bench.sh`
  builds and signs with the Developer ID certificate.
- The judge client (call, schema validation, one retry) is built here, so
  `run --judge` and judge-inclusive estimates work from this task on.
- Accept, with a scripted transport: no budget on a hosted model → stops
  before any request; estimate (judge included) over budget → stops; actual
  cost crossing the budget mid-run → aborts; a response without usage is
  charged its upper bound (input at one token per character); output caps of
  max(1,024, 4 × input); a `length` finish with no visible output is retried
  once with double the cap as an infrastructure failure; on-device calls use
  `generate` (non-streaming) and `rateLimited` is retried as an infrastructure
  failure, at most 5 times with backoff; dry runs without keys use `prices.json` and the canonical
  identity; `run` refuses holdout cases even through `--cases`; a run whose
  upper bound would take the ledger past `--total-budget` is refused; a development
  run below 95 % records "not ready (development NN %)".
- Verify: `swift test --filter QuillBenchTests`; one real on-device run of the
  spelling profile through `Scripts/bench.sh`, preceded by a 30-call on-device
  burst from the CLI whose result is recorded in PROVIDERS §8 next to the app's.

**P1-T7b · `quill-bench` gate, verdicts and readiness** · L
- `gate` (holdout; judge required for rewrite profiles; gate log; sealed
  failures; confirmation; counted runs), `holdout add|retire`,
  `check-references`, `baseline`,
  `export-readiness`.
- Accept, with a scripted transport and fixture results: `gate` refuses fewer
  than the minimum repeats, a judge not in the gate file, a changed rubric, a
  same-vendor judge, and a prompt hash without a ≥ 95 % development run; it
  appends to the gate log and writes sealed failures outside the repository;
  the ninth counted run for a profile × model is refused, infrastructure
  failures do not count, the count resets on an owner-approved lock change
  and when the evaluation version changes, and the 2 release runs are usable
  only with `--release`; an evaluation-version change re-checks references
  and parks failing cases for the owner; "ready" needs two consecutive passing runs on one
  prompt hash; the **verdict logic** (95 %, critical every repeat, 0.85, judge
  4.0/3.5 and the critical meaning ≤ 2 rule, the rewrite-profile rule for
  already-correct cases, "not evaluated") is tested; the **judge call** is
  tested, including rejecting JSON that fails the rubric's schema; `holdout
  add|retire` update the lock without printing holdout contents; `baseline`
  refuses a run with a personal case; `check-references` re-checks holdout
  references against the shipped plus injected examples and parks failing
  ones (ids only); `export-readiness` keys entries by
  canonical model identity and evaluation version. At the end of this task,
  create `cases/holdout.lock` (holdout files and `gate-v1.json`) and commit it
  on its own: the first lock commit.
- Verify: `swift test --filter QuillBenchTests` and `--filter CaseSetTests`
  (now including the lock).

**P1-T8 · On-device baseline and tuning** · L
- Run all four profiles on the on-device model; tune prompts on development
  cases only (after any shipped-example edit, run `check-references`); commit the on-device baseline; produce hosted dry-run estimates
  for two candidate models per provider, judge included; run `gate` for the
  on-device model on the spelling-only profiles (no judge needed);
  `export-readiness` to `tools/QuillBench/data/readiness.json`.
- Accept: baseline JSON in `tools/QuillBench/data/baselines/`; spelling-only
  profiles have a gate verdict, a recorded "not ready (development NN %)", or
  — if P1-T7a's burst showed the CLI throttled — "not evaluated (CLI
  rate-limited)" recorded in README;
  rewrite profiles show "not evaluated" (no judge yet) or "not ready
  (development NN %)"; `readiness.json` exists; estimates added to README Q9;
  `holdout.lock` changed only by owner-approved commits since its first
  commit (P1-T7b).
- Verify: `Scripts/bench.sh compare` between the first and final tuning runs;
  `swift test --filter CaseSetTests`; every commit touching the lock except
  the first carries a `Holdout-Change:` trailer:
  ```bash
  L=native/quill/tools/QuillBench/data/cases/holdout.lock
  test "$(git log --format=%H -- $L | wc -l)" -eq "$(( $(git log --grep='^Holdout-Change:' --format=%H -- $L | wc -l) + 1 ))"
  ```

**P1-T9 · Hosted run** · M · OS3
- Within the approved budget: all four profiles on two hosted models, and the
  on-device model again; tune on development cases; `gate` with an allowed
  judge until each built-in is confirmed ready on ≥ 1 hosted model, the
  counted gate runs are used, or the budget ends (BENCH §1.1 shipping rule);
  commit the baseline; `export-readiness`.
- Accept: every built-in × model has a gate verdict or a recorded development
  "not ready"; profiles that cannot be made ready recorded in README;
  `readiness.json` regenerated.
- Verify: `Scripts/bench.sh compare`; `readiness.json` diff reviewed.
- If OS3 has not happened: skip, and run this task (then P1-T10) at the first
  task boundary after OS3; P6-T3 requires it done. Prompt texts are versioned
  per strategy, and hosted tuning edits only the full strategy's prompt
  texts, so the on-device (compact) prompt hashes and goldens stay put;
  tuning shared inputs (shipped examples, guidance) requires re-gating the
  on-device verdicts and running `check-references`.

**P1-T10 · Checkpoint: provider defaults** · S
- Present the results; the owner answers Q5 and Q6 in OS4 at the latest;
  README defaults apply until then. Apply the outcome: built-ins left out by
  BENCH's shipping rule are removed from the shipped set (code, tests,
  PRODUCT §5, QA rows), and the recommended model ids are passed to the
  presets' `recommended:` — Vercel's and OpenAI's by canonical model identity
  (the same model measured through OpenRouter), none where no measured model
  maps. The first pass (before P1-T9) removes nothing; removals apply only
  after P1-T9. Re-run this task after P1-T9.
- Accept: README Q5/Q6 and `readiness.json` agree.
- Verify: read both side by side (P5-T1's Accept later checks that onboarding
  reads `readiness.json`).

### P2 — SelectionKit

**P2-T1 · Fakes and pasteboard tests** · M
- Fakes for the four protocols. On a private named pasteboard: lossless
  restore for text, RTF, images and file URLs (byte comparison); promise and
  heavy types skipped from the type list; 10 MB cap abandons the snapshot;
  restore skipped when `changeCount` moved or no snapshot exists;
  `.alwaysDeny`, `.ask` and `.default` → no read at all, no restore, ⌘C
  fallback refused (the `PasteboardClient` fake injects the behaviour: only
  the general pasteboard can be Ask or Deny, so a named pasteboard cannot
  produce them); an incomplete snapshot (a skipped or timed-out type) is
  never restored.
- Verify: `swift test --filter PasteboardTests`.

**P2-T2 · Capture sequence** · M
- ARCHITECTURE §3.1 with the strategy table from SPIKES.md.
- Accept, on fakes: subrole refusal; an empty selection in a process not yet
  switched triggers manual accessibility and polling to the phase deadline,
  then a refusal without ⌘C; editable only when settable or by the app's
  editable signal; terminal denylist read-only-only; manual accessibility set once
  per process; ⌘C only when accessibility is unavailable and only after the
  hot key's release and the modifier wait; the 200 ms and 800 ms caps
  honoured; rich formatting detected.
- Verify: `swift test --filter CaptureTests`.

**P2-T3 · Replace sequence** · M
- ARCHITECTURE §3.2.
- Accept, on fakes, asserting the order: Return key-up → order out → focus
  wait (element, then pid fallback) → selection check → snapshot → write with
  markers and `.currentHostOnly` (trailing line breaks removed for Paste
  anyway) → modifiers clear → ⌘V → verify → restore after the delay only with
  a snapshot and an unchanged `changeCount`; the abort path when the selection
  changed; the accessibility-write strategy; the ⌘C/⌘V key code taken from the
  current layout with the ⌘ state, with the ASCII-capable and ANSI fallbacks
  (a fake layout source drives each case).
- Verify: `swift test --filter ReplaceTests`.

**P2-T4 · Selection bounds** · S
- Accept: tests with fixed screen geometries, including a secondary display
  above and to the left of the main one.
- Verify: `swift test --filter BoundsTests`.

**P2-T5 · Live matrix regression** · S
- Re-run the probe on the matrix with the final sequences; update SPIKES.md.
- Accept: no row regressed from P0-T4; the owner-run rows (Safari, Chrome,
  VS Code, Terminal, iTerm2, Teams, Slack) *pending* until OS6.
- Verify: SPIKES.md diff reviewed against P0-T4's rows.

### P3 — Stores and the rewrite flow

**P3-T1 · Stores** · M
- `SettingsStore` and `ProfileStore` (ARCHITECTURE §4.2–4.3): atomic writes,
  versions (keep 20), example deletion purged from versions, samples,
  custom servers in `settings.json` with the registry rebuilt when they change
  (PROVIDERS §8 item 9), migration scaffold, corrupt-file quarantine with 30-day deletion,
  export/import, "Reset Quill" (files and the app's `quill.providers` Keychain service).
- Accept: tests for migration of a synthetic version-0 fixture, quarantine of
  a corrupt file, pruning to 20, purge of a deleted example from all versions,
  import of an exported profile under a new id, reset leaving no files and no
  `quill.providers` items (against an `InMemoryCredentialStore`).
- Verify: `swift test --filter StoreTests` (temporary directories only).

**P3-T2 · Menu bar, hot key, permission state** · M
- Menu per ARCHITECTURE §5.1. A backwards-compatible addition to
  `AppCore.HotKeyCenter` that registers with options and reports the
  `OSStatus` (no Quill naming in AppCore); Quill registers exclusively.
- A `--self-check` launch argument (ARCHITECTURE §8) and its `verify.sh`
  step: release app, `.build` renamed, every resource bundle loaded before
  any data, Keychain or hot-key access, every built `*.bundle` in
  `Contents/Resources`. Permission
  watcher and "restart to finish enabling".
- Accept: Ámbar's tests stay green; an exclusive registration failure is
  reported in the menu; provider status reflects a removed key on the next
  menu opening.
- Verify: `swift test` in `native/` and `native/quill/`; manual: register the
  same combination exclusively from a scratch process **first**, then launch
  Quill and observe the report; repeat with a **shared** registration first,
  confirm Quill's exclusive registration succeeds and takes the combination
  over; with an exclusive owner first, confirm the conflict is reported and
  no shared fallback is registered.

**P3-T3 · RewriteSession view model** · L
- App-level states (ARCHITECTURE §2: capturing, refused capture, awaiting
  consent, waiting to start, correcting, applying, applied outcomes), PRODUCT
  §4.1 table, resolution rules (ARCHITECTURE §5.3), direct apply exactly as
  PRODUCT F2 defines it, the too-long suggestion of ARCHITECTURE §4.4, prewarm
  at hot-key time; the Correcting
  state's cap and identifier paths against a fake store (P4-T4 builds the
  real store side); the `waitingForClipboard` state (ARCHITECTURE §3.4).
- `Scripts/mock-chat-server.py`: a minimal Chat Completions server on
  127.0.0.1, seeded as a custom provider through `settings.json` under
  `QUILL_DATA_DIR`, plus a debug hook `QUILL_TREAT_LOOPBACK_AS_REMOTE` so it
  exercises the hosted path (consent, waiting to start, cost estimate) without
  keys and without the Local Network prompt a LAN address would raise.
- Accept: a test for every key in every state of PRODUCT §4.1; a flagged
  result is never applied without ⌘Return; Paste anyway never offered on
  read-only-only apps; direct apply only on a clean result, editable target and
  paste strategy with `undoVerified`; the shortcut cancels a direct apply that
  is generating; a too-long text on an on-device profile is never offered a
  hosted model; prewarm is requested when the hot key fires; a pinned
  unavailable model yields "Choose a model"; nothing
  is sent while awaiting consent, and Esc there sends nothing.
- Verify: `swift test --filter RewriteSessionTests`.

**P3-T4 · Picker panel** · M
- Non-activating key panel over `RewriteSession` (showing the presentation
  mapping's provisional copy until P3-T7 completes it) with Ámbar's four collection
  flags, Liquid Glass, chips, streaming, diff, flags, key hints.
- Accept: opens over another app's full-screen space without leaving it; the
  host keeps its selection (S3); Esc returns focus to the host.
- Verify: manual over TextEdit and a full-screen app (agent); over Safari in
  OS7; screenshots in `docs/initiatives/quill/QA.md`, created here from a
  template with one row per use case × app.

**P3-T5 · Apply, copy, direct apply, toast** · M
- Wire `SelectionKit.replace`; read-only → copy; toast per PRODUCT F2.
- Accept: replacement in TextEdit, Notes and Mail (agent) and in Safari and
  Chrome (*pending* → OS7); direct apply refused on accessibility-write apps
  and on apps without `undoVerified`.
- Verify: manual on those apps; outcomes in QA.md.

**P3-T6 · Services entry (send-only)** · S
- `NSServices` with an empty `NSRequiredContext`; selection comparison;
  hosted models wait for Return.
- Accept: available from TextEdit's contextual menu (agent) and Safari's
  (*pending* → OS7); replacing works from TextEdit; the host is never blocked;
  invoking the service with the mock hosted provider sends nothing before Return.
- Verify: `/System/Library/CoreServices/pbs -update`, then
  `/System/Library/CoreServices/pbs -dump | grep -i quill`, after install;
  manual from both apps.

**P3-T7 · Presentation mapping** · S
- Accept: a test enumerates every `ProviderError.Code`, engine state, capture
  refusal, replace outcome, `Tradeoff` case and `Recipient` case and fails if
  one lacks copy (and, where applicable, an action) in both languages.
- Verify: `swift test --filter PresentationTests`.

**P3-T8 · End-to-end QA, first pass** · M
- U1, U3, U4, U5 on the matrix apps with the on-device model; the hosted path exercised against the mock server (P3-T3); real hosted rows
  *pending* → after OS7 (keys entered there); owner-run rows *pending* → OS7.
- Verify: `Scripts/check-matrix.sh docs/initiatives/quill/QA.md` (QA.md uses the
  script's row format: one row per use case × app).
- Accept: every cell has a state; no fail without a fix before P4.

### P4 — Settings

**P4-T1 · Providers & models pane** · M
- Providers with advantages/drawbacks and readiness labels; key entry and
  removal; custom OpenAI-compatible server under PROVIDERS §4's rule (https,
  or plain http only to a `.local` name; plain http to an IP address rejected
  with an explanation; `NSAllowsLocalNetworking` and
  `NSLocalNetworkUsageDescription`; any `-1022` mapped to copy suggesting a
  `.local` name or https; confirm on a private-range IP that ATS still blocks
  it, and a real LAN server by `.local` name works); model list with cache and prices;
  "Test connection"; remote notices. `make-app.sh` copies
  `tools/QuillBench/data/readiness.json` into the bundle.
- Accept: a missing key shows "needs a key" with an action; removing a key
  deletes the Keychain item; a loopback server shows its note; the remote
  notice appears once per provider; the bundle contains `readiness.json`.
- Verify: `swift test --filter ProvidersPaneTests`; with `APP` the path
  `make-app.sh` printed, `test -f "$APP/Contents/Resources/readiness.json"`.

**P4-T2 · Profiles pane** · L
- Editor (settings, guidance with its "not sent to small models" mark,
  examples with the identifier screen and the "not sent" marks, samples,
  pinned model), versions compare and revert, Try
  it, export/import with the warning, "Restore built-in profiles", the
  user-text-to-new-recipient notice (trigger: ARCHITECTURE §5.3), the "not
  evaluated (edited)" readiness label.
- Accept: an edit creates a version; revert restores it; Try it shows G6 on a
  sample that triggers it and goes through consent before sending samples to
  a new hosted recipient; restoring brings back only deleted built-ins.
- Verify: `swift test --filter ProfilesPaneTests`; manual pass.

**P4-T3 · Apps pane** · S
- Per-app default and *apply directly*; add from running apps; deleting a
  profile removes its mappings.
- Accept and verify: `swift test --filter AppsPaneTests`.

**P4-T4 · "Correct…" (⌘E)** · M
- The Correcting UI: editable field, "Save as example" with its recipient,
  the replace-which-example chooser at 8 examples, the stand-ins offer.
- Accept: saving a correction adds one example and one version; the
  identifier screen applies; the chooser and the stand-ins work.
- Verify: `swift test --filter RewriteSessionTests`.

**P4-T5 · General pane and About** · S
- Recorder with the system-shortcut warning (Quill-side view), launch at
  login, kill switches (enhanced/manual accessibility, ⌘C fallback), "Reset
  Quill" with a confirmation, About (version, licences, privacy summary).
- Accept: a system-shortcut combination shows the warning; with the ⌘C
  fallback off, capture refuses where accessibility is unavailable.
- Verify: `swift test --filter GeneralPaneTests`; manual.

**P4-T6 · End-to-end QA, second pass** · M
- U2, U6, U7, U8 on the matrix apps, plus the hosted rows of U1, U3, U4, U5
  in native apps left *pending* in P3-T8, now that OS7 entered keys; QA.md updated.
- Accept: every cell has a state; no fail without a fix before P5.
- Verify: `Scripts/check-matrix.sh docs/initiatives/quill/QA.md`.

### P5 — Onboarding, localization, accessibility, performance, privacy

**P5-T1 · Onboarding** · M
- PRODUCT F4 with the product-name constant (codename until Q1), the
  clipboard-access step (opens the System Settings pane, re-reads
  `accessBehavior`) and the `readiness.json`-driven provider default.
- Accept: the agent's walkthrough on a **walkthrough build** (bundle id
  `dev.rrios.quill.walkthrough`, isolated data dir, its own Keychain service
  suffix) goes from first launch to
  the Accessibility step with no dead end, without touching the development
  build's grant; the steps after the grant are covered by OS5. The provider
  step's default is checked by an onboarding view-model test against a
  fixture `readiness.json`.
- Verify: the walkthrough checklist in QA.md.

**P5-T2 · Localization** · M
- Every UI string in `es` and `en`; parameterise
  `native/Scripts/check-localization.sh` for Quill's resource directories;
  `InfoPlist.strings`; Quill declares `es` and `en` and the check accepts
  AppCore's extra languages in its own bundle; add the check to `verify.sh`.
  The parameterised script stays generic (no Quill naming: it is exported).
- Accept and verify: the check passes for Quill and still for Ámbar.

**P5-T3 · Accessibility of Quill's own UI** · M
- VoiceOver labels for picker, toast, settings, onboarding; the
  `QUILL_DUMP_A11Y` hook; a Quill variant of `check-accessibility.sh` in
  `verify.sh`.
- Accept and verify: the check reports no unlabeled control.

**P5-T4 · Performance pass** · S
- Signposts for ARCHITECTURE §11; measure on the matrix.
- Accept: typical budgets met, caps never exceeded, or the miss recorded with its cause.
- Verify: Instruments signpost export attached to QA.md.

**P5-T5 · Privacy pass** · S
- Create the `QUILL_LOG_HOSTS` debug hook (ARCHITECTURE §3.6).
- Accept: `strings -a` finds `QUILL-USERTEXT` in the debug binary (positive
  control) and not in the release binary; the data folder holds only PRODUCT §7's items; the
  `QUILL_LOG_HOSTS` pass during OS6 shows only the selected providers' hosts.
- Verify: the three checks, added to `verify.sh` where automatable.

### P6 — Release

**P6-T1 · Verification gate** · S · OS4
- `verify.sh` complete (ARCHITECTURE §10); if Q10 is yes, a
  `.forgejo/workflows/quill.yml` running it on the owner's Mac runner.
- Accept: `verify.sh` passes on a clean clone (`git clone --branch <the
  working branch>` into a temporary directory, then run it).
- Verify: the clean-clone run.

**P6-T2 · Final name, packaging and notarization** · M · OS4
- Apply the final name (Q1) everywhere: bundle id, app name, menu and
  Services item titles, UI strings, `InfoPlist.strings`, data folder, DMG
  name; the final icon. The Keychain service names (`quill.providers`,
  `quill.bench`) are internal and stay as they are.
- Parameterised `make-dmg.sh` and `release.sh` (preflight, notarize with the
  existing notary keychain profile passed as `NOTARY_PROFILE`, staple, `spctl`).
- Verify: `release.sh preflight`; `spctl --assess --type execute` on the app;
  `xcrun stapler validate` on the DMG.
- Accept: `release.sh preflight` passes; `spctl --assess --type execute`
  accepts the app; `xcrun stapler validate` passes on the DMG.

**P6-T3 · Release checklist and 1.0** · M · OS5, OS6
- Gates, all required: SPIKES.md and QA.md rows all pass, limitation or n/a
  (OS6 done, live smoke check included); P1-T9 done and the built-ins shipping
  per BENCH's rule — confirmed verdicts are reused when the release build's
  prompt hashes and evaluation version equal those in `readiness.json`;
  otherwise re-gate with the 2 release runs (`gate --release`; spend under Q9), re-export `readiness.json`, and repeat P6-T2 so the DMG carries it; OS5 done; P5-T5 re-run; `verify.sh` green.
- Order: OS6 → fixes → re-gate and DMG rebuild if needed → OS5 on that final
  DMG; any later rebuild voids OS5. Then an agent pass over the native-app
  rows on the **release** build (TextEdit, Notes, Mail), since every earlier
  live step used debug builds. The 1.0 tag is created only in P6-T5.

**P6-T4 · Distribution** · S · OS4, OS5
- Only after P6-T3 and the owner's go-ahead. With Q2 and Q8 at their defaults
  (closed, no page), the deliverable is the notarized DMG and its checksum
  handed to the owner; hosting and a download page become their own task
  once Q8 is answered.
- Accept and verify: the DMG's checksum is recorded; when a download URL
  exists, it serves that DMG (`curl -sI` 200, checksum matches).

**P6-T5 · Merge and tag** · S · OS4 approval
- After the go-ahead: push the branch, open a PR whose description quotes the
  final `verify.sh` output, merge to `main`, tag 1.0 on `main`.
- Accept and verify: the tag points at `main`; `git log origin/main` contains it.

## 5. Risks

| # | Risk | Mitigation | Where |
|---|---|---|---|
| R1 | Teams (MSWebView2) or an Electron app exposes no selection. | Lazy-tree retry; per-app enhanced accessibility if justified; ⌘C fallback with Paste anyway; documented limitation. | P0-T4, P2-T2 |
| R2 | Restoring the pasteboard pastes stale content, overwrites a newer copy, or clears it. | Measured delay; `changeCount` guard; no restore without a snapshot; transient markers. | P0-T4, P2-T3 |
| R3 | The on-device model is not good enough for some profiles. | Bench decides; readiness labels; hosted models recommended. | P1-T8, P1-T9 |
| R4 | Manual or enhanced accessibility causes side effects. | Lazy, per process; measured; kill switches. | P0-T4, P4-T5 |
| R5 | The default shortcut clashes. | Exclusive registration; system-shortcut warning; recorder in onboarding. | P3-T2, P5-T1 |
| R6 | A signature or bundle id change drops the grant. | Stable signing from P0-T2; bundle id fixed at P6-T2 before any distributed build. | P0-T2, P6-T2 |
| R7 | A provider changes its API. | Contract suite; live smoke check in OS6 before release. | OS6, P6-T3 |
| R8 | A selected text tries to instruct the model. | Text-as-data; critical injection cases in holdout; guards; user confirms; Services never starts hosted rewrites unattended. | P1-T2, P1-T6, P3-T6 |
| R9 | Clipboard access is not Always Allow. | No general-pasteboard read at all; paste leaves the rewrite on the clipboard and says so; ⌘C fallback off; onboarding guides to Always Allow. | P2-T1, P5-T1 |
| R10 | Quill code leaks into Ámbar's public repository. | Everything under `native/quill/`; export exclusion and its check. | P0-T1 |
| R11 | AppCore changes break Ámbar. | Backwards-compatible parameters only; Ámbar's suite on every AppCore change. | P3-T2 |
| R12 | Paste into a terminal runs text. | Editable only when settable; read-only-only denylist; no Paste anyway there. | P2-T2, P3-T3 |
| R13 | Owner sessions slip. | Short, batched, with defaults; only the release waits. | §2 |
| R14 | Untested on macOS 27 (pasteboard policy, new error types). | Code paths behind `#available`; README Q11 decides whether a macOS 27 machine or VM is used before release. | P1-T0b, P6-T3 |
| R15 | The gate is bent to fit results. | Locked gate file (thresholds, repeats, judges, rubric); locked holdout with retire-and-replace only; tuning on development cases; gate log. | P1-T6, P1-T7b |
| R16 | The agent cannot drive browsers, IDEs and terminals in this environment. | Those rows run in OS2, OS7 and OS6 from agent-prepared checklists. | P0-T4, OS7, OS6 |
