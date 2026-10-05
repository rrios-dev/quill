# Planning audit

The plan was audited before development, in rounds, by independent reviewers
with different lenses, until **two consecutive rounds found no blocker and no
major issue**. Each round used fresh reviewers who had not seen earlier rounds'
findings. Findings were fixed in the documents between rounds.

Severity: **blocker** — development would stop or build the wrong thing ·
**major** — a task would be redone, or a promise could not be kept ·
**minor** — clarity or polish.

| Round | Lenses | Blockers | Majors | Minors | Result |
|---|---|---|---|---|---|
| R1 | executability · macOS feasibility · product/privacy/bench | 1 | 33 | 28 | Fixed; documents largely rewritten |
| R2 | executability · macOS feasibility · product/privacy/bench | 0 | 29 | 28 | Fixed |
| R3 | executability · macOS feasibility · product/privacy/bench · cross-document consistency | 0 | 13 | 41 | Fixed |
| R4 | same four lenses | 0 | 8 | 47 | Fixed |
| R5 | same four lenses | 0 | 6 | 44 | Fixed — first round with no major from the macOS lens |
| R6 | same four lenses | 0 | 8 | 36 | Fixed — second consecutive round with no major from the macOS lens |
| R7 | same four lenses | 0 | 7 | 37 | Fixed — third consecutive round with no major from the macOS lens |
| R8 | same four lenses | 0 | 4 | 34 | Fixed — fourth consecutive round with no major from the macOS lens |
| R9 | same four lenses | 0 | 8 (≈6 distinct) | 34 | Fixed — several majors were side effects of round 8's fixes |
| R10 | same four lenses | 0 | 4 (3 distinct) | 35 | Fixed — sixth consecutive round with no major from the macOS lens |

## Round 1 — what changed

- **Blocker**: P1 could not exit without hosted spend. The hosted run became
  its own task (P1-T9), required only by the release gate (P6-T4).
- **Sequencing**: SelectionKit's foundations moved into P0-T3; stores moved
  into P3; U2 moved to P4's exit; owner actions batched into five sessions
  with defaults (PLAN §2); every task got Accept and Verify lines; the
  zero-warnings rule now forces a rebuild.
- **Repository hygiene**: all Quill paths under `native/quill/`; git-ignore
  for its build output; the export check runs after staging; Ámbar's CI
  excludes Quill's tree.
- **macOS correctness**: password fields detected by subrole; editability only
  when the selected text is settable, terminals read-only; secure input not a
  global refusal; ⌘C fallback only when accessibility is unavailable; Services
  send-only; exclusive hot-key registration; `changeCount`-guarded restore;
  macOS 27 pasteboard access policy; key-up wait before paste; element-level
  focus wait with a pid fallback; messaging timeout; coordinate conversion;
  snapshot caps; probe inside the signed app; Teams treated as MSWebView2.
- **Model layer**: finish reason and truncation state; prewarm; permissive
  guardrails for rewriting; framework context size; macOS 27 error types;
  temperature omitted when unset.
- **Product and quality**: built-in profiles specified field by field with
  es/en examples; picker states and keys tabulated; no silent model fallback;
  rich-formatting warning; guards G1, G3, G4, G5, G7 made safe against the
  false positives found; G9 for example echo; examples follow the memory-layer
  mould; ⌘C-fallback clipboard exposure disclosed.
- **Bench**: per-scope gate, critical cases must pass every repeat, holdout
  split, actual-cost metering, versioned judge rubric from a different vendor,
  case categories, baselines that refuse personal cases.


## Round 2 — what changed

- **Verification that could never pass**: the export check matched its own
  temporary directory; rewritten with `-mindepth 1` and anchored paths.
- **Hidden owner stops**: Keychain prompts on every bench rebuild (the bench is
  now signed by `Scripts/bench.sh` and has its own Keychain service); Teams/Slack
  rows after P0 (new session OS6); the onboarding walkthrough no longer resets
  the development grant (separate walkthrough bundle id); "n/a with reason"
  rows for apps not installed and macOS 27.
- **CI reality**: the origin is Forgejo, which never runs `.github/workflows/`;
  the gate became a local `verify.sh` (D-18), a Mac runner optional (Q10).
- **macOS corrections**: the pasteboard access policy exists since 15.4 and
  `.default` means "ask" — Quill now accepts one question asked in context
  (D-19) and degrades cleanly on deny; picker collection flags copied from
  Ámbar (`.canJoinAllApplications` was missing); permissive guardrails return
  refusals as text (new guard G10); on-device `maximumResponseTokens`
  truncates silently (not used); bold/italic detected through font names;
  total capture deadline and typical-vs-cap budgets; empty selections in lazy
  trees retried before refusing; secure-input holder not named (no public API);
  Services enabled with `NSRequiredContext`; correct `pbs` flag.
- **Model layer**: prices and vendor in `ModelDescriptor`; `estimateTokens`;
  `prewarm(promptPrefix:)` with a cached session; complete macOS 27 error list;
  OpenRouter `data_collection: deny`.
- **Product and safety**: full picker key × state table; separate keys for
  confirming flags and pasting anyway, never offered on terminals; direct apply
  only on the paste path (D-20); formatting loss is a flag (G11); Services
  checks the selection and never starts hosted rewrites unattended; "who does
  what to whom" is a base rule under every register, and the Formal examples
  were fixed to keep the actor; worked examples made to obey their own rules;
  G1 limited to a closed preamble list, G3 names via `NLTagger`, G9 redefined;
  Try it samples declared and screened; OpenRouter recipients worded honestly;
  examples evicted oldest first and marked.
- **Bench**: 96 cases with locked holdout files, every critical category in
  holdout, thresholds frozen before any run, judge required for rewrite
  profiles, judge calls metered, a price source, shipped examples disjoint from
  the cases, one profile per case, `tooLong` counted as a failure, a shipping
  rule for profiles that never become ready.

## Round 3 — what changed

- **Clipboard policy**: a first alert moves an app to *Ask*, which asks on
  every read — an alert mid-paste would steal ⌘V. Quill now reads the general
  pasteboard **only with Always Allow** (D-19 revised); onboarding guides the
  user to the setting; snapshots are taken off the critical path, during
  generation, with a deadline.
- **Prewarm**: a session keeps its transcript, so a cached session would leak
  the previous selection; prewarm now builds a single-use session from the
  request, after the profile is resolved, and its gain is not counted.
- **Gate integrity**: the locked gate file now holds thresholds, minimum
  repeats, allowed judges and the rubric hash; thresholds never change; tuning
  runs are development-only and holdout verdicts go through `gate` with a log;
  wrong holdout cases are retired and replaced, never edited; `mustKeep` holds
  meaning anchors; a critical case with a meaning score ≤ 2 fails; calls
  without usage are charged their upper bound.
- **Safety**: new guard G12 for added numbers, dates, links and addresses;
  consent state before anything reaches a new recipient; recipients in code
  name the routed party (OpenRouter, Vercel); guidance screened and its compact
  cut marked; xterm.js terminals read-only-only.
- **Executability**: owner sessions now cover the clipboard setting, the rows
  the agent cannot drive (browsers, IDEs, terminals), entering hosted keys in
  the app, the host-logging pass and a live smoke check; distribution moved
  after the release checklist; a *limitation* row state the gate accepts;
  `readiness.json` produced in P1-T8; the final name applied everywhere in
  P6-T2; `QuillSupport` as the logging target; verdict and judge logic tested
  before any spend.
- **Consistency**: built-in ids, readiness vocabulary mapping, prompt-hash
  inputs (temperature included), the full settings inventory, registry
  rebuilds, resolution order with the menu bar's choice, section references,
  case counts and capture/replace budgets that add up.

## Round 4 — what changed

- **Clipboard policy, grounded in a measurement**: on macOS 26.6.2 apps report
  `.alwaysAllow` (the policy is behind a developer-preview switch), and an app
  in `.default` is not listed in System Settings until it triggers an alert.
  Onboarding now skips the step where the policy is not enforced and, where it
  is, offers a deliberate check that gets Quill listed, a deep link to "Paste
  from Other Apps" and a restart; S2 tests Ask/Deny with the preview switch;
  the ⌘C-fallback limitation without Always Allow is stated in the product.
- **Gate governance simplified around the owner**: holdout and judge-list
  changes need owner approval recorded in the commit; sealed per-case
  failures let the owner judge a suspect case; "ready" needs two consecutive
  passing gate runs; gate runs per profile × model are capped; judges from at
  least two vendors on OpenRouter, and OS3 asks for an OpenRouter key; the
  judge is required only for rewrite profiles.
- **G12 dates defined** as absolute dates only (relative words like
  "tomorrow"/"tmrw" excluded), so expanding abbreviations is not flagged.
- **Release sequencing**: OS6 runs on the renamed build after P6-T2; Keychain
  service names are internal and survive the rename; the host-logging hook is
  created in P5-T5.
- **macOS details**: modifiers cleared before the ⌘C fallback; only complete
  snapshots restored; lazy trees polled to the phase deadline; Services
  returns before reading accessibility; emoji fonts and Chromium's HTML no
  longer trigger the formatting flag; Developer ID only for signing; debug
  builds named for every live step; exclusive hot-key status reported.
- **Smaller fixes**: Spanish fixtures in JSON (the language hook rejects them
  in Swift); bench data under `tools/QuillBench/data/`; ModelKit stays
  dependency-free; cost formula per split; `contentFilter` → refused; the
  Correcting state's edge cases; Friends example made to obey its rules;
  pinned on-device profiles never offered a hosted model on "too long".

## Round 5 — what changed

- **A crash that only users would have seen**: SwiftPM's `Bundle.module`
  calls `fatalError` when the build path is gone; every Quill module with
  resources now resolves its bundle like AppCore's `StringsBundle`, and
  `verify.sh` launches the release app with the build folder renamed.
- **Bench integrity model made explicit**: it guards against accidental
  overfitting, not deliberate circumvention — which ends the escalation of
  anti-gaming rules. Concretely: gate runs counted per prompt hash and not
  for infrastructure failures; confirmed verdicts reused at release when the
  prompt hash is unchanged, with two runs kept in reserve; `run` refuses
  holdout cases; sealed failures live outside the repository; approvals as
  commit trailers under Conventional Commits; versioned gate files and rubric
  bumps as an approvable change; one output cap for generation and judge;
  true per-call upper bounds.
- **Budgets that add up**: capture caps 200 ms (accessibility) and 800 ms
  (⌘C fallback, modifier wait included); replace cap 1.9 s with the snapshot
  re-take counted.
- **Readiness keyed by canonical model identity** (`vendor/model`, and the
  on-device model per macOS version), with "ready, unconfirmed" shown as
  "may need review".
- **Smaller fixes**: number parsing by the input's language and dates by
  components; G7 tolerant of typographic variants; every line break counted;
  correcting-field keys and the 500-character case; revoked Accessibility as
  a refusal reason; an onboarding exit with no provider; Reset deletes only
  the app's keys; the corrupt-file exception disclosed; `generate` as a
  protocol requirement; the rate-limit retry on a fresh session; a mock Chat
  Completions server to exercise the hosted path before keys exist; codesign
  checks without the `grep -q` false negative; `pbs -update`; a positive
  control for the logging canary; `--bundle-id` for walkthrough and renamed
  builds; a fresh Accessibility grant in OS6.

## Round 6 — what changed

- **The export rule itself would have named Quill** in Ámbar's public
  repository: the exclusion is now generic (a `.not-exported` marker), and the
  verification greps the export for the name.
- **Bench**: gate runs counted per profile × model across prompt hashes, and
  `gate` accepts a hash only after a ≥ 95 % development run — so the holdout
  cannot become a tuning signal; already-correct cases judged by similarity
  and meaning for rewrite profiles (exact "no changes" only for spelling-only);
  holdout edits through `holdout add|retire`; verdicts keyed by evaluation
  version; reasoning-only truncation treated as infrastructure; "not ready"
  shown as "not recommended".
- **Guards**: G1 compares the first line with the input after normalising, so
  corrected greetings are not flagged; G6 normalises chat abbreviations; edge
  whitespace trimmed and re-attached; only interior line breaks counted.
- **Execution**: a new owner session (OS7) after P4-T1 runs the browser,
  Teams and Slack rows on the finished flow and enters the app's keys early,
  leaving OS6 as a regression pass; the mock server runs on loopback with a
  debug hook (no Local Network prompt); the resource-bundle helper is built
  with the first resources and checked by a `--self-check` launch; matrix files
  checked by a script; ModelKit amendments and the bench CLI each split in
  two; recipients typed so the app can localize them; rubric v1 carries the
  judge's schema.
- **macOS details**: snapshot reads on a dedicated thread with no pasteboard
  writes racing them; the ⌘C snapshot runs alongside the modifier wait;
  refusing ⌘C when modifiers stay held; one cap for the focus wait with a pid
  fallback; a per-app editable signal for Chromium-based fields; non-zero
  `AXUnderline`; the host-side clipboard alert checked in OS2.

## Round 7 — what changed

- **Bench**: `run` takes an optional judge, so meaning failures surface on
  development cases; a model that never reaches the 95 % development bar gets a
  recorded "not ready (development NN %)", exported as "not recommended";
  gate-run counts reset when the evaluation version changes; judge calls
  retried once; already-correct inputs for rewrite profiles at least 20 words.
- **Product**: new guard G13 for closing commentary, and single-line
  "Texto corregido: …" answers unwrapped; direct apply requires ⌘Z undo
  verified per app (`undoVerified`); "Save as example" off by default and
  naming the recipient; corrections re-run the guards; "too long" with no
  fitting model defined; refusals narrowed to those aimed at the request.
- **Consistency**: recipients typed everywhere (`Recipient` enum, localized by
  the app); ARCHITECTURE §7 reduced to a pointer to PROVIDERS §8; one row-state
  vocabulary enforced by `check-matrix.sh`; readiness labels used verbatim in
  onboarding; the focus-timeout outcome named; bench output defined per command.
- **Execution**: SelectionKit implements its own waits behind its protocols
  (AppCore's helpers return nothing and use the real clock); the resource
  helper arrives with the first resources (P1-T1); OS7 covers every owner-run
  row of P3; OS3 also settles languages and shortcut; OS5 turns on the
  clipboard policy's preview switch; P1-T9's re-entry point and per-strategy
  prompt versions; the leak check in `verify.sh`; P6-T4 defined on the
  defaults; a placeholder file for `QuillSupport`.
- **macOS details**: restores always `.currentHostOnly`; a timed-out snapshot
  read leads to copy-only; rate limiting handled with backoff and measured by
  a 30-call burst; capture budgets include showing the picker; on-device
  readiness keyed by macOS major version.

## Round 8 — what changed

- **Rules defined once**: direct-apply conditions live only in PRODUCT F2, the
  consent trigger only in ARCHITECTURE §5.3 (user-authored examples or
  guidance; shipped examples do not count), the too-long suggestion only in
  ARCHITECTURE §4.4 (an on-device profile is never offered a hosted model);
  other documents reference them. Most consistency findings so far came from a
  rule updated in one document and not in another.
- **G9 redefined** so a correct spelling fix of a near-twin input is not taken
  for example echo; `exampleBait` cases carry their own injected example, which
  leaves the shipped examples free to tune; every reference must pass every
  guard (a test checks it); new categories `multiLine` and `noAddedFacts`.
- **The lock is created at the end of P1-T7b**, once the code that reads the
  gate file exists and before the first real run; 2 release-only gate runs.
- **Execution**: the similarity function and the judge client move to the
  tasks that first need them; probe options and a Debug "Test fields" window;
  debug and release builds in separate paths; the export leak check in
  `verify.sh`; on-device rate limiting measured from the CLI too; missing
  Accept criteria added (too-long suggestion, cancelling direct apply,
  prewarm, Try it consent, `Tradeoff`/`Recipient` copy).
- **macOS details**: SelectionKit's key-release wait and ⌘V behind
  `KeyEventPoster`; Copy and Return disabled while a timed-out clipboard read
  finishes; synthetic ⌘C/⌘V use the current layout's key codes; exclusive
  hot-key behaviour measured with a shared registration first, with a shared
  fallback; the replace cap raised to 2.2 s; outside network observation
  during OS6; prompt texts as JSON resources (they contain Spanish).

## Round 9 — what changed

- **Side effects of round 8, corrected**: G9's second branch (shared
  vocabulary) replaced by a run of at least 5 copied words; `exampleBait`
  measured against its own injected example; the reference-passes-guards rule
  checked at authoring and lock time, not in `verify.sh`, with cases parked
  for the owner after a guard change; `waitingForClipboard` modelled as a
  state that returns to Ready.
- **A real platform limit found by probe**: App Transport Security blocks
  plain http to remote hosts. Non-loopback custom servers must use https; LAN
  servers over http need `NSAllowsLocalNetworking`, a usage description and the
  user's permission, verified in QA.
- **Hot key, measured**: an exclusive registration takes over normal ones and
  fails only against an exclusive owner; a shared fallback would be dead, so
  there is none.
- **Synthetic keys**: SelectionKit posts its own layout-aware ⌘C/⌘V
  (`UCKeyTranslate` with the ⌘ state, ASCII-capable and ANSI fallbacks);
  Paster cannot, as it hard-codes `kVK_ANSI_V`.
- **Execution**: holdout written in a separate session, holdout changes
  owner-initiated; `CredentialStore.removeAll()` for reset; capped rate-limit
  retries with an app-side fallback; a `burst` subcommand; P1-T10 applies the
  shipping rule and recommended models; OS5 runs on the final DMG; a merge-and-tag
  task (P6-T5); Q5/Q6 by OS4, and "may need review" does not preselect.
- **Smaller fixes**: HTML inline styles and the Google Docs wrapper in the
  formatting check; G13 normalised like G6; the messaging timeout set once on
  the system-wide element; the replace cap at 2.3 s; debug items listed.

## Round 10 and closing verification

Round 10 found three distinct majors (G9 still sensitive to raw-text
differences, `spellingOnly` interactions undefined, a bench fallback promised
without a task). They were fixed: G9 now compares normalised text; inert and
constrained settings under `spellingOnly` are defined; the fallback was
dropped in favour of recording "not evaluated (CLI rate-limited)".

Two **targeted verification passes** followed instead of an eleventh full
round. The first found two contradictions introduced by those fixes (the
local-network server rule, the prompt-text version) and nine minors; all were
fixed. The second confirmed every fix and found **no major issue** anywhere in
the set; its six minors were fixed.

## Final status

- **Result**: the convergence criterion set at the start — two consecutive
  full rounds with no major — was **not** formally met. Majors per round:
  33 · 29 · 13 · 8 · 6 · 8 · 7 · 4 · 8 · 4, then 2 and 0 in the targeted
  verifications. The macOS-feasibility lens reported no major for the last six
  rounds; the remaining majors were increasingly fine-grained (often side
  effects of the previous round's fixes) in the bench's guard rules and in
  cross-document wording.
- **Why stopping here is sound**: the last full round found no blocker and
  three majors, all fixed and verified; the final pass found none. Further
  findings of the same kind are best caught by the plan's own executable
  checks — the guards' table tests (P1-T3), the case-set tests (P1-T6), the
  self-consistency test (P1-T2), the matrix checks (P0-T4) and `verify.sh`.
- **Where residual risk concentrates**, to watch during implementation:
  1. Guard false positives and negatives on real text (G1, G3, G9, G12, G13):
     the bench's development runs will expose them first.
  2. The bench's governance (counted runs, lock, parking) under real tuning:
     P1-T8 is its first real use.
  3. Platform behaviour only measurable live: Teams/Electron selection (S1),
     clipboard restore timing (S2), focus return (S3), on-device rate
     limiting from the CLI (P1-T7a), ATS on private-range IPs (P4-T1).
