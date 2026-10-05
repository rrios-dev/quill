# Quill — product definition

What the app does, for whom, and what it deliberately does not do. The how is
in [ARCHITECTURE.md](ARCHITECTURE.md); the order of work in [PLAN.md](PLAN.md).

## 1. The user and the job

A person who writes all day in other people's apps — Teams, Slack, Mail, a
browser form, a document — and loses time fixing register, typos and clumsy
phrasing before pressing Send. The fix depends on the reader: a colleague, a
lawyer, a friend. They want it fixed **where they are typing**, in a second,
in the voice that reader expects.

The job: *select, press a key, get the right version in place.*

## 2. Core concepts

| Concept | Meaning |
|---|---|
| **Profile** | A named way of rewriting: "Spelling only", "Work", "Formal", "Friends", "Clean up dictation", "Concise", "Synthesize". Structured settings (§5), free guidance, worked examples, saved sample texts for trying it, and an optional pinned model. The user creates, edits and refines profiles. |
| **App default** | "In Teams, use Work." A mapping from an app to a profile, optionally with *apply directly*. |
| **Provider / model** | Who runs the rewrite: Apple Intelligence on this Mac, or a hosted model through OpenRouter, Vercel AI Gateway, OpenAI or a custom OpenAI-compatible server. Chosen once globally; a profile may pin its own. |
| **Rewrite** | One run: captured text + profile + model → result, checked by the output guards (§6) before it can be applied. |

## 3. Use cases

| # | Use case | MVP |
|---|---|---|
| U1 | Select text in an editable field (Teams compose box, Mail, TextEdit), press the shortcut, see the rewrite, press Return: the selection is replaced. | ✅ |
| U2 | Same, in an app whose default profile has *apply directly*: no picker; a toast confirms. | ✅ |
| U3 | Select text on a static page (a web article, a PDF). The result appears in the picker with Copy. | ✅ |
| U4 | Change profile on the fly in the picker and see the new result. | ✅ |
| U5 | Start from the contextual menu: Services → "Rewrite with Quill" opens the same picker. | ✅ |
| U6 | Create a profile, tune it, try it on saved sample texts, see its signals, compare and revert versions. | ✅ |
| U7 | Correct a bad result and keep the correction as an example for that profile. | ✅ |
| U8 | Pick provider and model, seeing the advantages and drawbacks of each; enter an API key once; add a custom OpenAI-compatible server. | ✅ |
| U9 | Rewrite a whole document or a text longer than the model's context (chunking). | ⏳ later |
| U10 | Searchable history of past rewrites. | ⏳ later (opt-in when it ships) |
| U11 | Preserve rich formatting (bold, lists, links) through a rewrite. | ⏳ later — 1.0 is plain text and flags the loss (§6) |
| U12 | iOS / iPadOS. | ❌ out of scope |

## 4. Flows

### F1 — Rewrite with the picker (U1, U3, U4)

1. The user selects text and presses the global shortcut (default ⌃⌥R,
   configurable; README Q4).
2. Quill captures the selection and notes the frontmost app (ARCHITECTURE §3.1).
3. The **picker** appears near the selection. Top to bottom: an **instruction
   field** that has the keyboard ("Describe the change you want…"), the
   profiles as buttons numbered 1–9 with the one resolved by ARCHITECTURE §5.3
   selected, a card with the result and what made it, and the actions as
   buttons that show their keys — the primary one is what Return does. The
   rewrite starts at once — except when it must wait for Return: a pending
   privacy notice (`Awaiting consent`), a hosted rewrite over the large-text
   threshold, and any hosted rewrite started from Services.
4. Everything works with the pointer as well as the keyboard: a click on a
   profile is its number, a click on an action is its key.
5. **Instruction.** Typing in the field and pressing Return rewrites the
   selection with what was typed, on the global model, instead of a profile —
   the system Writing Tools' "Describe your change", kept fast. It runs through
   the same consent, guards, keys and toast as a profile. The instruction
   replaces the profile rules it would contradict (tone, length, register,
   language) and keeps the ones it cannot override: the text is data, who does
   what, nothing invented, names, numbers and links kept. It is not remembered
   as the last used profile, and choosing a profile drops it. Its results carry
   no readiness label: the bench cannot measure what it has not seen.
6. Keys and states: §4.1.

### F2 — Direct apply (U2)

Same trigger, in an app whose default has *apply directly* on. Direct apply
happens **only** when all of these hold: the result is `Ready` with no flag
(formatting that will be lost, or could not be checked, is a flag), the target is editable, and the app's strategy
replaces by **paste** with ⌘Z undo verified for that app in the spike matrix
(`undoVerified`) — the only path the host can undo. Then the
selection is replaced and a toast shows "Rewritten with Work · ⌘Z to undo".

Anything else opens the picker instead, with the reason visible. While a
direct apply is generating, the shortcut cancels it.

### F3 — Refine a profile (U6, U7)

1. Settings → Profiles → a profile: structured settings, guidance, examples,
   sample texts, pinned model.
2. **Try it** runs the profile on its saved sample texts with its model and
   shows each result with its signals (the guards, "no changes", length),
   side by side with the result the previous version produced (saved with the
   sample).
3. From the picker, ⌘E ("Correct…") opens the result for editing; saving adds
   the original → corrected pair as an example (subject to §7).
4. Every saved edit creates a **version**; the user compares and reverts.
5. Profiles can be exported and imported as files; exporting warns that the
   file contains the profile's examples and samples, which are user text.
6. "Restore built-in profiles" brings back any built-in profile the user
   deleted, without touching the rest.

### F4 — First run (U8)

1. Welcome: what Quill does, in one screen.
2. Move to /Applications if launched elsewhere (before the permission: the
   grant is tied to the installed app).
3. Accessibility permission: why, a button to the right System Settings pane,
   live detection, and "Restart Quill" when the grant arrives while running.
4. Clipboard access: Quill keeps your clipboard intact around a paste by
   saving and restoring it, which needs permission to read the clipboard.
   On macOS versions that enforce clipboard privacy per app (Ask, Always
   Allow, Always Deny), the step offers **Check clipboard access**, which
   makes macOS ask once and list Quill, then opens System Settings → Paste
   from Other Apps and offers to restart Quill (ARCHITECTURE §3.4). Where the
   policy is not enforced — macOS 26 by default — the step is skipped. Without
   Always Allow: a paste leaves the rewrite on the clipboard, and in apps that
   do not expose text to accessibility (where Quill would fall back to ⌘C)
   capture is unavailable; the picker explains both when they happen.
5. Provider: Apple Intelligence preselected when available and when the bench
   says it is ready for the built-in profiles (README Q5); otherwise the user
   is offered a hosted provider — and can still choose Apple Intelligence,
   shown with its readiness label ("may need review", "not recommended" or
   "not evaluated"), if they have no key. If Apple Intelligence is
   off, downloading or unsupported and there is no key, the step offers "Turn
   on Apple Intelligence" (opens System Settings) and "Set up later", which
   finishes onboarding; the menu bar then shows "Needs a provider". Each option shows its
   advantages and drawbacks. A hosted provider shows, once, who receives the text.
6. Shortcut: the default, a recorder to change it, a warning when the
   combination is already a system shortcut, and a note that a host app's
   own menu shortcut with the same keys stops working while Quill runs.
7. Practice field: a first rewrite with real text.

### 4.1 Picker: states × keys

| State | Shows | Return | ⌘Return | ⌥Return | ⌘C | 1–9 / Tab | ⌘E | ⌘D | ⌘R | Esc / shortcut |
|---|---|---|---|---|---|---|---|---|---|---|
| **Awaiting consent** (first text to a hosted provider, or a profile's user-authored examples or guidance to a new recipient — trigger defined in ARCHITECTURE §5.3) | Who will receive the text (and the examples), plus the word count and estimated cost when the text is over the large-text threshold | accept and start (consent and the large-text confirmation are one step) | — | — | — | change profile | — | — | — | cancel; nothing is sent |
| **Waiting to start** (hosted large text, or hosted via Services) | Word count; estimated cost when the price is published | start | — | — | — | change profile | — | — | — | close |
| **Generating** | Streaming text | — | — | — | — | cancel and restart with that profile (a new request; the previous one is not billed beyond what it already used) | — | — | — | cancel, close |
| **Ready** | Result; changes marked (on by default for spelling-only profiles; ⌘D toggles) | replace (editable) · copy (uncertain, read-only-only) | — | paste anyway (uncertain targets only) | copy | rerun with that profile | correct | diff | rerun | close |
| **Correcting** (⌘E) | The result in a multi-line editable field (Return inserts a line break) and an unchecked "Save as example (sent with this profile's rewrites to <provider>)" — disabled, with the reason, when either text exceeds the 500-character example cap | inserts a line break | commits: the corrected text becomes the result, and the guards run again on it (a formatting-loss flag stays); if "Save as example" is checked it is also saved — when the profile already has 8 examples Quill asks which to replace, and when the text contains personal identifiers it offers neutral stand-ins or saving without the example | — | — | — | — | — | — | discard the edit, back to the previous state |
| **Flagged** | Result + each flag's reason | — | confirm the flags → becomes Ready | — | copy | rerun | correct | diff | rerun | close |
| **No changes suggested** | The original | close | — | — | copy | rerun | correct | — | rerun | close |
| **Truncated** | Partial text, greyed; "The answer was cut off" | — | — | — | — | rerun | — | — | rerun | close |
| **Refused by the model** | "The model declined this text" | — | — | — | — | rerun | — | — | rerun | close |
| **Failed** | The error and its action (add a key, open settings); partial text greyed | the action | — | — | — | rerun | — | — | retry | close |
| **Too long** | "Too long for <model>" + the suggestion defined in ARCHITECTURE §4.4 (on-device or local models only when the resolved model is on-device); if none fits, "Shorten the selection" and no suggestion | rerun once with the suggested model (subject to Awaiting consent); nothing when there is none | — | — | — | change profile | — | — | — | close |
| **Refused capture** | Why (no selection; password field; Accessibility permission missing or revoked, with a button to System Settings; the app exposes no text and the ⌘C fallback needs Always Allow clipboard access, is turned off, could not save the clipboard in time, or found modifier keys still held) | close | — | — | — | — | — | — | — | close |
| **Applied** | Toast or picker line: "Replaced" (verified), "Pasted" (not verifiable), "Pasted — couldn't confirm the change" (verification found no change), "Pasted — your clipboard now holds the rewrite" (no complete snapshot to restore), "Copied — the selection changed", "Copied — couldn't return to the app" (aborted, result on the clipboard), or "Copied — this text can't be edited here" (target not confirmed editable) | — | — | — | — | — | — | — | — | — (the picker has closed) |
| **Waiting for the clipboard** | The result, greyed, while a clipboard read that timed out finishes (ARCHITECTURE §3.4); then back to the previous state (Ready or Flagged) | — | — | — | — | — | — | — | — | close |

- Partial text (Truncated, Failed) is never copied or applied.
- Targets are **editable** (the selected text is settable), **uncertain**
  (could not be confirmed) or **read-only-only** (terminals; ARCHITECTURE §3.1
  step 5). "Paste anyway" exists only for uncertain targets, and trailing line
  breaks are removed before such a paste.
- Confirming flags (⌘Return) and pasting anyway (⌥Return) are different keys
  on purpose: a flagged result on an uncertain target needs both decisions.
- Read-only Ready says "Copied — this text can't be edited here" after Return.
- The instruction field has the keyboard, so the picker's letter keys carry ⌘
  (⌘D, ⌘R). Digits 1–9 choose a profile while the field is empty and are
  typing once it is not. With a draft the current result was not made with,
  Return sends the draft (the primary button says so) instead of the state's
  Return; Esc always closes. ⌘C copies the result unless the field has a
  selection of its own.
- Changes are shown the way the system's proofreading shows them: the new text,
  with what changed underlined and tinted; what was removed is not painted.

## 5. Built-in profiles

Shipped as editable starting points. Each row is precise enough to write its
prompt and its bench cases. Each built-in ships with **two examples** of its
own, kept disjoint from the bench cases (BENCH §2), and a short **guidance**
(under 60 words, so small models receive it whole) carrying the behaviour the
settings cannot express — Friends' opening ¿ ¡, Formal's "vague stays vague".

### Profile settings (the fields every profile has)

| Field | Values |
|---|---|
| `scope` | `spellingOnly` (fix errors, keep wording) · `rewrite` (rephrase) |
| `register` | `keep` · `informal` (es: tú) · `formal` (es: usted; en: formal, no contractions) |
| `tone` | `keep` · `neutral` · `cordial` · `warm` · `direct` |
| `length` | `keep` · `shorter` · `longer` |
| `abbreviations` | `expand` (q → que, u → you) · `keep` |
| `interjections` | `keep` · `remove` (oye, tío, hey, lol) |
| `emoji` | `keep` · `remove` |
| `preserve` | any of: `names`, `numbers`, `links`, `lineBreaks` |
| `targetLanguage` | none (keep the input's) or a language code |
| `lengthBand` | output/input word ratio accepted without a flag |

Under `scope: spellingOnly`, `tone`, `length` and `interjections` are inert
(left out of the prompt, greyed out in the editor); `register` must be `keep`
and `targetLanguage` none — validation rejects anything else, so the
self-consistency test only meets valid combinations. `abbreviations`, `emoji`
and `preserve` stay active.

Under **every** setting, a rewrite keeps **who does what to whom**: the
person who acts, receives or is obliged stays the same, whatever the register.

### The built-in profiles

In the picker's order (1–7). The first four shipped first; the last three were
added at the owner's request on 2026-10-04 (dictation is how the owner writes
most text; concise and synthesis cover the "shorter" and "make sense of this"
jobs the system Writing Tools are used for).

| | Spelling only | Work | Formal | Friends |
|---|---|---|---|---|
| scope | spellingOnly | rewrite | rewrite | spellingOnly |
| register | keep | keep | formal | keep |
| tone | keep | cordial | neutral | keep |
| length | keep | keep | keep | keep |
| abbreviations | expand | expand | expand | **keep** |
| interjections | keep | remove | remove | keep |
| emoji | keep | keep | remove | keep |
| preserve | names, numbers, links, lineBreaks | names, numbers, links | names, numbers, links, lineBreaks | names, numbers, links, lineBreaks |
| targetLanguage | none | none | none | none |
| lengthBand | 0.8–1.8 | 0.6–1.6 | 0.7–1.8 | 0.8–1.4 |
| id (`BuiltInProfile`) | `spelling` | `work` | `formal` | `friends` |

| | Clean up dictation | Concise | Synthesize |
|---|---|---|---|
| scope | spellingOnly | rewrite | rewrite |
| register | keep | keep | keep |
| tone | keep | keep | direct |
| length | keep | shorter | shorter |
| abbreviations | expand | expand | expand |
| interjections | remove (inert in the prompt, where the guidance names the fillers; it lets the guards accept their removal) | remove | remove |
| emoji | keep | keep | remove |
| preserve | names, numbers, links, lineBreaks | names, numbers, links | names, numbers, links |
| targetLanguage | none | none | none |
| lengthBand | 0.5–1.1 | 0.3–1.05 | 0.1–1.05 |
| id (`BuiltInProfile`) | `dictation` | `concise` | `synthesis` |

**Spelling only** — fixes spelling, accents, missing *h*, capitalisation,
punctuation (including opening ¿ ¡), agreement, and expands chat
abbreviations (they are non-standard spelling; laughter and interjections such
as "lol" or "jaja" are not abbreviations). Keeps word choice, word order,
tone, interjections and emoji.
- es: "q tal estas? ya e llegado a casa" → "¿Qué tal estás? Ya he llegado a casa."
- en: "im running late, cu at 5" → "I'm running late, see you at 5."

**Work** — everything Spelling only does, plus: rephrases for clarity, splits
run-on sentences, removes filler interjections and vulgarities, prefers
professional vocabulary ("mil cosas" → "mucho trabajo"). Never adds greetings,
sign-offs, apologies, promises or facts.
- es: "oye mira lo del informe q me pediste ayer no lo e podido acabar xq e tenido mil cosas, te lo paso mañana sin falta vale? perdona"
  → "Sobre el informe que me pediste ayer: no he podido terminarlo porque he tenido mucho trabajo. Te lo envío mañana sin falta. Disculpa."
- en: "hey so the report u asked for yesterday isnt done, been swamped, ill send it tmrw sorry"
  → "The report you asked for yesterday isn't done; I've been swamped. I'll send it tomorrow. Sorry."

**Formal** — formal register (usted; no contractions in English),
complete sentences, precise and consistent vocabulary, no colloquialisms or
emoji. **Vague stays vague**: a vague source ("luego", "pronto") becomes a
formal vague expression ("más adelante", "próximamente"), never a guessed
date. Keeps who holds each action or obligation — no passive voice that hides
the actor. Never adds facts, dates, amounts, obligations, legal formulas,
greetings or signatures.
- es: "te devuelvo el contrato firmado, lo de la clausula 3 lo vemos luego"
  → "Le devuelvo el contrato firmado. La cláusula 3 la revisaremos más adelante."
- en: "sending back the signed contract, we'll sort clause 3 later"
  → "I am returning the signed contract. We will address clause 3 at a later date."

**Friends** — fixes real spelling errors and accents, adds opening ¿ ¡ to
match the closing marks, capitalises sentence starts except a leading chat
abbreviation or laughter. **Keeps** chat abbreviations (q, xq, tb, u, lol),
slang, laughter, interjections, expressive punctuation (!!, …) and emoji.
Does not restructure.
- es: "jajaja q fuerte!! mañana te cuento, e quedado con la ana aver si vamos al cine 🎬"
  → "¡¡jajaja q fuerte!! Mañana te cuento, he quedado con la Ana a ver si vamos al cine 🎬"
- en: "lol omg thats crazy, ill tell u tmrw 🎬" → "lol omg that's crazy, I'll tell u tmrw 🎬"

**Clean up dictation** — for text spoken into the Mac. Removes filler sounds and
words ("eh", "em", "este", "o sea", a leading "bueno"), repeated words and false
starts, keeping the last version of each sentence; adds punctuation and
capitals. Keeps the words, their order and the tone: it tidies what was said,
it does not rephrase or summarise. A spelling-only profile, so it is measured
by the hard checks and the reference similarity, without a judge.
- es: "eh bueno lo que te decía que el informe el informe lo tengo casi pero me falta eh la parte de costes"
  → "Lo que te decía: el informe lo tengo casi, pero me falta la parte de costes."
- en: "so um the thing is the the deploy failed again and uh nobody knows why"
  → "The thing is, the deploy failed again and nobody knows why."

**Concise** — the same text with fewer words: removes repetition, roundabout
phrasing, filler and padding, and keeps every fact, request and nuance, and the
text's structure. Already short text comes back unchanged. Never adds anything.
- es: "quería comentarte que, tal y como hablamos el otro día, finalmente he podido revisar el documento que me pasaste y está todo bien"
  → "He revisado el documento que me pasaste y está todo bien."
- en: "I wanted to follow up to let you know that I have now had the chance to go through the slides and they look good to me"
  → "I've gone through the slides and they look good."

**Synthesize** — *defined and measured, not shipped in 1.0 yet: it has not
passed its gate (README, "New built-ins").* Turns a long, dense or badly structured text into a short,
practical one: the gist first, then decisions, requests (who does what), dates
and open questions, in short sentences or a list. Keeps every name, number,
date and link; drops repetition, detours and digressions. It does not
interpret, judge or add anything — dropping a digression is not a lost detail,
losing a decision, a request or a date is.
- es: "a ver, resumo lo de la llamada con Marta porque se alargó mucho, ella dice que el diseño le gusta pero quiere cambiar los colores, que lo tengamos para el lunes 6 si puede ser y que la factura se la mandemos a su socio"
  → "Llamada con Marta: le gusta el diseño, pero quiere otros colores. Lo quiere para el lunes 6 si es posible. La factura, a su socio."
- en: "long story short after the whole discussion we agreed Tom owns the migration, it ships on the 14th, and we still have to decide who tells the client"
  → "Tom owns the migration; it ships on the 14th. Still open: who tells the client."

## 6. Quality promises

Each is enforced by a deterministic guard after the model answers
(ARCHITECTURE §4.6). The model's output is untrusted text.

1. **Nothing invented**: no placeholders (`[name]`), greetings, sign-offs,
   numbers, dates, links, @mentions or e-mail addresses that were not in the input; the names, numbers (by value) and links the
   profile preserves survive; emoji survive unless the profile removes them.
2. **Same language** as the input — or the profile's target language when it sets one.
3. **No commentary**: a known preamble the model added ("Here is the text:")
   is removed; an uncertain one, or a closing note ("Espero que te sirva"),
   is flagged, never silently cut.
4. **Plausible length** for the profile; a cut-off answer is never applied.
5. **"No changes suggested"** when the model returns the input untouched —
   stated as what happened, not as a verdict that the text is correct.
6. **No example echo**: a result that copies one of the profile's examples
   instead of rewriting the input is flagged.
7. **No refusal passed off as a rewrite**: a model's "I can't help with that"
   is shown as a refusal, never offered for applying.
8. **Formatting**: 1.0 replaces with plain text. When the selection carries
   rich formatting, the result is flagged "Formatting will be lost"; when the
   app does not let Quill check, "Formatting couldn't be checked".

A flagged result is never applied without the user's explicit confirmation.

## 7. Privacy promises

- **Who receives the text**: only the provider the profile resolves to, only
  when the user triggers a rewrite. A profile pinned to a model that becomes
  unavailable fails with "Choose a model" — it never falls back silently. A
  notice, accepted **before anything is sent** (`Awaiting consent`), names the
  recipients once per hosted provider: OpenAI; Vercel **and the provider
  serving the model**; OpenRouter **and the inference provider it routes to**
  (Quill asks OpenRouter to use only providers that do not collect data); or a
  custom server's host. When a profile's user-authored examples or guidance
  are about to go to a remote provider that has not received them before, Quill asks
  once, the same way (ARCHITECTURE §5.3).
- **What Quill keeps**, all local, in Quill's Application Support folder:
  profiles with their examples, sample texts and the samples' results for the
  current and previous version, the last 20 versions of each profile,
  settings, cached model lists with prices, unreadable files set aside for 30 days, and — only if the user
  runs the bench — its personal cases, every run's results and the sealed gate
  failures (personal cases are sent to the judge's vendor too when a judge is used). Development builds also keep
  probe rows. No rewritten text is kept otherwise. "Reset Quill" deletes all
  of it, including the cached model lists and the app's API keys (the bench,
  a developer tool, removes its own keys with `keys remove`).
- **Try it** sends samples only after the same consent as a rewrite.
- **Examples, guidance and samples are user text**: examples and guidance
  travel with every rewrite of their profile to its provider; samples travel
  only when Try it runs. All are capped and screened for personal identifiers (e-mail addresses,
  phone numbers, IBANs, card numbers, Spanish DNI/NIE) when saved and before
  each use. Deleting an example removes it from every stored version too —
  except from an unreadable file set aside as corrupt, which Quill cannot
  parse; such files are deleted after 30 days or by "Reset Quill".
- **The clipboard**: Quill's own temporary clipboard writes are marked so
  clipboard managers ignore them and kept off Universal Clipboard. Keeping the
  user's clipboard intact needs the Always Allow clipboard setting (F4 step 4);
  without it, a paste leaves the rewrite on the clipboard. When Quill must fall back to ⌘C to read a selection, the
  **host app** writes the copy, and clipboard managers or Universal Clipboard
  may record it — Settings explains this and can disable the fallback.
- No analytics, no telemetry, no crash reporter that uploads anything; release
  builds log no user text (development builds log it to the system log only
  as private data). Password fields are never read.

## 8. Non-goals

- Not a chat assistant, not a writing generator from scratch.
- No App Store version (README D-02).
- No account, no server of our own: providers are reached directly with the
  user's key.
- No automatic rewriting while typing.
