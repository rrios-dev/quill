# Quill — spikes S1–S3: the app matrix

Which capture and replace strategy works in which app, measured with the debug
build's probe and picker harness (PLAN P0-T4, ARCHITECTURE §3). `AppStrategy`
entries (`native/quill/packages/SelectionKit/AppStrategy.swift`) cite the rows
below; a test checks every cited row exists.

Row states — exactly these words, enforced by `native/quill/Scripts/check-matrix.sh`:
**pass**; **limitation** (works as a documented limitation in PRODUCT);
**fail** (the note gives the fix or the decision); **pending** (waiting for an
owner session); **n/a** (with a reason).

## Method

- **Where**: the owner's Mac (M2 Max, macOS 26.6.2), debug build of Quill signed
  with the Developer ID certificate and granted Accessibility (OS1, 2026-10-03).
- **How**: `native/quill/Scripts/spike-driver.swift` arranges each scene — a known
  fixture text in a known field, part of it selected — and asks Quill, through
  distributed notifications its Debug menu listens to (debug builds only), to run
  the probe or open the harness. Quill measures with its own grant and writes one
  JSON row per run to `<data dir>/probe/`. Rows record lengths and booleans, never
  the text.
- **Lesson from the first attempt**: opening Quill's status-bar menu from a script
  hands activation to another app when the menu closes, so a menu-driven probe can
  measure the wrong app. The notifications avoid the menu, and the driver refuses
  to continue when the target is not frontmost.
- **Who**: the agent drives native apps fully. Browsers, VS Code, terminals, Teams
  and Slack are run by the owner in OS2 from the checklist at the end (PLAN §1,
  R16); their rows are *pending* until then.
- Fixture text: "hello john, I will send you the report tomorrow"; the selection
  is "hello john" unless the row says otherwise.

## S1 — capture

| Row | App | Case | State | Result | Note |
|---|---|---|---|---|---|
| S1-01 | TextEdit | Plain document | pass | Accessibility path (system-wide focus), `AXTextArea`, 10/10 characters; selected text and value settable; formatting plain; bounds from accessibility. Focus 13–16 ms, read ≈ 1 ms. | — |
| S1-02 | TextEdit | Rich document ("hello john" in bold) | pass | Accessibility path; formatting **rich** (`Helvetica-Bold` run). | — |
| S1-03 | Notes | Note body | pass | Accessibility path, `AXTextArea`, 10/10 characters, settable; formatting plain. | The body includes the note's title line; the selection was set past it. |
| S1-04 | Mail | Compose body, default capture | fail | The body is an `AXWebArea`: `kAXSelectedText` answers *no value* and there is no `AXSelectedTextRange`, so default capture reads an empty selection and refuses ("Select some text first"). The selection **is** exposed through WebKit text markers: `AXSelectedTextMarkerRange` → `AXStringForTextMarkerRange` returned all 48 selected characters. | Fixed in this phase by the Mail strategy entry (S1-05). A better fix — reading text markers in the accessibility path — needs a plan change: decision D-S1 below. |
| S1-05 | Mail | Compose body, ⌘C-only capture | pass | 5/5 captures of 48 characters, clipboard restored each time, after a fix: the first runs read nothing in 1 of 3, because Mail moves the change count (clearing the pasteboard) before writing the text. ⌘C now polls until the string is there, within the same 200 ms phase (unit-tested). | Needs Always Allow clipboard access wherever the policy is enforced (ARCHITECTURE §3.4). |
| S1-06 | Quill Test fields | Plain field | pass | Accessibility path, `AXTextField`, 10/10 characters; plain. | — |
| S1-07 | Quill Test fields | Rich field | pass | Formatting **rich** over the bold words and over the link; plain over plain words. | — |
| S1-08 | Quill Test fields | Password field | pass | Refused: subrole `AXSecureTextField` (role `AXTextField`); the text is never read. | — |
| S1-09 | Microsoft Word | Document | n/a | — | Not installed on the owner's Mac. |
| S1-10 | Safari | Textarea | pending | — | OS2. |
| S1-11 | Safari | Static page text | pending | — | OS2. Expected: captured, target uncertain or read-only; result offered for Copy. |
| S1-12 | Safari | Sign-in form password field | pending | — | OS2. Must be refused. |
| S1-13 | Google Chrome | Textarea | pending | — | OS2. Record whether manual accessibility was needed and whether the first answer was an empty selection. |
| S1-14 | Google Chrome | Static page text | pending | — | OS2. |
| S1-15 | Microsoft Teams | Compose box, default | pass | Owner-run, 2026-10-05, Quill 1.0.2, InputLeap running: captured through the ⌘C fallback. Teams exposes no accessibility focus at all — `AXFocusedUIElement` and `AXFocusedWindow` of the app answer `kAXErrorNoValue`, `AXManualAccessibility` is unsupported. | Teams embeds `MSWebView2`, not Electron. A draft only; never sent. |
| S1-16 | Microsoft Teams | Compose box, enhanced accessibility | pending | — | OS2. Only if S1-15 finds no selection. |
| S1-17 | Slack | Compose box | pending | — | OS2. A draft only; never sent. |
| S1-18 | Visual Studio Code | Editor | pending | — | OS2. |
| S1-19 | Visual Studio Code | Integrated terminal | pending | — | OS2. Must be read-only-only (`xterm-helper-textarea`). |
| S1-20 | Terminal | Shell window | pending | — | OS2. Must be read-only-only (denylist). |
| S1-21 | iTerm2 | Shell window | pending | — | OS2. Must be read-only-only (denylist). |
| S1-22 | Chrome, Slack, Teams | Side effects of manual accessibility in the following minute | pending | — | OS2: scrolling, typing and window animations still normal. |

## S2 — replace

| Row | App | Case | State | Result | Note |
|---|---|---|---|---|---|
| S2-01 | TextEdit | Paste, verify, restore at 150 / 300 / 600 / 1000 ms | pass | Pasted and verified (value contains the result) at every delay; clipboard restored each time. | — |
| S2-02 | TextEdit | ⌘Z after a paste | pass | One ⌘Z restores the original text, at every delay. | — |
| S2-03 | TextEdit | Accessibility write, verify | pass | Write reported ok; value re-read contains the result — the 2026-10-03 manual result, reproduced. | — |
| S2-04 | TextEdit | ⌘Z after an accessibility write | pass | TextEdit registers the write with its undo manager: one ⌘Z restores the text. | Not true of every app (README D-08); direct apply still requires the paste path. |
| S2-05 | TextEdit | Paste into a rich document | limitation | Pasted and verified, but the plain result takes the style of the selection's start (the bold of "hello john" covered all of it): mixed formatting is not kept. ⌘Z restores it — one ⌘Z was missed on the first try and not reproduced in 2 repeats. | PRODUCT §6.8: the capture is flagged "Formatting will be lost" (G11). |
| S2-06 | Notes | Paste, verify, restore at 150 / 300 ms | pass | Pasted and verified at both delays; clipboard restored. | — |
| S2-07 | Notes | ⌘Z after a paste | pass | One ⌘Z restores the text. | — |
| S2-08 | Notes | Accessibility write, verify, ⌘Z | pass | Write ok, verified; one ⌘Z restores the text. | — |
| S2-09 | Mail | Paste after a ⌘C capture | pass | Pasted; clipboard restored after both the ⌘C and the paste. `AXValue` of the web area is always empty, so verification by value reports "unchanged"; read through text markers, the body held the result. | Replace in Mail reports "Pasted", never "Replaced", until verification reads text markers (P2-T3). |
| S2-10 | Mail | ⌘Z after a paste | pass | One ⌘Z restores the body. | — |
| S2-11 | TextEdit, Notes, Mail | Clipboard fidelity after a restore | pass | The restored clipboard equals the original byte for byte, type by type, plus the transient marker the restore adds by design (ARCHITECTURE §3.2 step 9). | — |
| S2-12 | — | `accessBehavior` on macOS 26.6.2 | pass | `.alwaysAllow` in every run, with no alert: the policy is not enforced by default. | — |
| S2-13 | Quill | Clipboard policy **Ask** (developer-preview switch on) | pending | — | OS2: `accessBehavior` before and after answering the alert. |
| S2-14 | Quill | Clipboard policy **Deny** (switch on) | pending | — | OS2: no snapshot, no restore, ⌘C fallback unavailable. |
| S2-15 | TextEdit | Alert on Quill's synthetic ⌘V with the switch on for TextEdit | pending | — | OS2. |
| S2-16 | Safari, Chrome | Paste, verify, restore delay | pending | — | OS2. |
| S2-17 | Teams, Slack | Paste, verify, restore delay, ⌘Z | partial | Teams, owner-run, 2026-10-05, Quill 1.0.2: the paste replaces the selection (outcome `pasted`: the field cannot be re-read to verify). Before 1.0.2 every replace ended `copiedFocusNotReturned` — with InputLeap running every system-wide accessibility query fails, and nothing in Teams could confirm focus. Restore delay and ⌘Z not measured; Slack pending. | OS2. Drafts only; never sent. |
| S2-18 | Visual Studio Code | Editor: paste, ⌘Z | pending | — | OS2. |

## S3 — picker focus

| Row | App | Case | State | Result | Note |
|---|---|---|---|---|---|
| S3-01 | TextEdit | Selection and activation while the picker is key | pass | The panel is key; TextEdit stays the active app; the selection is unchanged while it is open and after it closes; the panel opens 6 pt below the selection. | — |
| S3-02 | TextEdit | Focus return: element vs pid | pass | Both signals hold on the first poll (< 0.02 ms): the non-activating panel never takes focus from the host element, so the element-level check passes at once. | The pid fallback is not needed here; S3 in Chromium apps (pending) decides whether it is needed anywhere. |
| S3-03 | TextEdit, full screen | Picker over another app's full-screen space | pass | The panel is on screen in TextEdit's full-screen space; TextEdit stays frontmost and full screen; selection kept. | Ámbar's four collection flags. |
| S3-04 | Notes | Selection, activation, focus return | pass | As S3-01 and S3-02. | — |
| S3-05 | Mail | Selection, activation, focus return | pass | Panel key, Mail active, focus back on the first poll; the body's selection (read through text markers) kept. | Placed at the mouse: the web area reports no range bounds. |
| S3-06 | Safari | Selection, activation, focus return | pending | — | OS2. |
| S3-07 | Google Chrome | Selection, activation, focus return | pending | — | OS2. |
| S3-08 | Microsoft Teams | Selection, activation, focus return | pending | — | OS2. |
| S3-09 | Slack | Selection, activation, focus return | pending | — | OS2. |

## Regression with the final sequences (P2-T5, 2026-10-03)

The native rows re-run through `SelectionCapturer` and `SelectionReplacer` (the
probe's `sequences` mode) instead of the raw operations. No row regressed:

| Rows | Result with the sequences |
|---|---|
| S1-01, S2-01, S2-02 (TextEdit) | Captured through accessibility, editable, plain; `replaced` 3 of 3, one ⌘Z restores each. |
| S1-02 (TextEdit, rich) | Captured, formatting `rich`. |
| S1-03, S2-06, S2-07 (Notes) | Captured, editable; `replaced` 2 of 2, ⌘Z restores. |
| S1-05, S2-09, S2-10 (Mail) | ⌘C-only strategy: captured 48 characters by copy, editable by its signal; `pasted` 2 of 2 (the body cannot be re-read through `AXValue`), body replaced, ⌘Z restores. |
| S1-06, S1-08 (Test fields) | Plain field captured; password field refused (`passwordField`). |

Found and fixed on the way: the first run reported `pastedUnconfirmed` in
TextEdit although the paste had landed. The sequence verified right after ⌘V,
before the host processed it; verification is now polled through the restore
delay (a unit test with a host that pastes 50 ms late fails on the old code).

Not a row: pasting into Quill's own test field does nothing — Quill, an
`LSUIElement`, has no Edit menu for ⌘V to reach. Its own text fields (Settings,
P4) need a hidden Edit menu, as Ámbar's `EditMenu` provides; recorded in
ARCHITECTURE §5.1.

## Default restore delay

**300 ms**, provisional. Every native app measured worked at 150 ms; 300 keeps a
margin for hosts that read the pasteboard asynchronously (Chromium, Electron),
which S2-16 and S2-17 measure in OS2. `AppStrategy.defaultRestoreDelay` holds it.

## Initial `AppStrategy` entries

| Bundle id | Overrides | Rows |
|---|---|---|
| `com.apple.TextEdit` | `undoVerified` | S2-01, S2-02 |
| `com.apple.Notes` | `undoVerified` | S2-07, S2-08 |
| `com.apple.mail` | `captureViaCopyOnly`, `editableSignal: settableValue`, `undoVerified` | S1-04, S1-05, S2-10 |
| `com.apple.Terminal`, `com.googlecode.iterm2` | `readOnlyOnly` (terminal denylist) | S1-20, S1-21 |
| Warp, Ghostty, kitty, Alacritty | `readOnlyOnly`, by the category rule | S1-20, S1-21 |

## Decision D-S1 — reading WebKit selections through text markers

Mail's compose body answers the selection only through WebKit text markers
(S1-04). Two ways to capture there:

| Option | Consequence |
|---|---|
| **A. Strategy entry, ⌘C only** (in place now, no plan change) | Works (S1-05). Uses the clipboard: needs Always Allow wherever the policy is enforced, the host writes an unmarked copy that clipboard managers may record (PRODUCT §7), and capture takes up to 800 ms instead of ≈ 20 ms. Each WebKit editor found later needs its own entry. |
| **B. Text markers in the accessibility path** (recommended) | ARCHITECTURE §3.1 gains a step: when `kAXSelectedText` has no value and the element exposes `AXSelectedTextMarkerRange`, read the selection through it. No clipboard, no Always Allow, accessibility speed, and it covers any WebKit editor (Mail, and likely editors in Safari pages, which S1-10 will show). Verification reads text markers too (S2-09), so Mail could say "Replaced". Costs one more raw operation, already written for the probe, plus its tests. |

Until decided, A stays in the table.

## OS2 checklist (owner, ~60 min)

Prepared by the agent. The debug build of Quill must be running. For every app
below, put the fixture text in the field, select "hello john", then run the
probe from Quill's menu (**Depuración → Sondear la app de delante (en 3 s)**),
clicking back into the field during the countdown. Messages are **drafts only —
never sent**.

1. **Safari**: a textarea (S1-10), a static page paragraph (S1-11), a sign-in
   form's password field (S1-12, must be refused); with **Opciones de la sonda →
   Sustituir pegando** in the textarea (S2-16); the **Arnés del selector** over the
   textarea (S3-06).
2. **Chrome**: the same textarea and page (S1-13, S1-14, S2-16, S3-07).
3. **Teams**: a compose box (S1-15; S1-16 with **Accesibilidad mejorada** if the
   first finds nothing), paste and ⌘Z (S2-17), the harness (S3-08).
4. **Slack**: a compose box (S1-17, S2-17, S3-09).
5. **VS Code**: an editor tab (S1-18, S2-18) and the integrated terminal (S1-19,
   capture only).
6. **Terminal** and **iTerm2**: capture only (S1-20, S1-21) — never paste.
7. For a minute after the Chrome, Slack and Teams runs: scroll and type normally
   and note anything odd (S1-22).
8. **Clipboard policy**: turn on the developer-preview switch for Quill, run the
   probe with paste under **Ask** and under **Deny** (S2-13, S2-14); turn it on for
   TextEdit and check whether Quill's ⌘V raises an alert (S2-15); then switch
   everything off again.

Quill writes each row to `~/Library/Application Support/dev.rrios.quill/probe/`;
the agent reads them afterwards and fills in the rows.
