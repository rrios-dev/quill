# Quill — end-to-end QA

The matrix of PLAN P3-T4, P3-T8 and P4-T6: one row per use case × app, in the
row states `Scripts/check-matrix.sh` enforces (PLAN §1). Rows in Safari,
Chrome, Teams and Slack are run by the owner (OS7, then OS6 for what is still
pending); the agent runs the native apps. Screenshots live in [`qa/`](qa/).

## Picker panel (P3-T4)

Driven with `Scripts/spike-driver.swift prepare textedit` and `picker esc` —
the real global shortcut (posted as a keystroke) over a prepared
selection, the on-device model. Rows run before 2026-10-04 used the first
default, ⌃⌥⌘R; the default is ⌃⌥R since OS3 (README Q4), and the driver posts it.

| Row | App | Case | State | Result | Note |
|---|---|---|---|---|---|
| P-01 | TextEdit | Picker opens over the selection | pass | The panel is shown and key while TextEdit stays frontmost; the selection is kept (0+10 before, while open and after). Profile chips wrap to a second row rather than truncate; the hint row shows the Ready keys. [Screenshot](qa/picker-textedit.png). | — |
| P-02 | TextEdit | Esc returns focus to the host | pass | The panel closes (no Quill window on screen), TextEdit is frontmost with its selection, the text unchanged. | — |
| P-03 | TextEdit, full screen | Opens over another app's full-screen space | pass | With TextEdit in full screen: the panel shows and is key, TextEdit stays frontmost and its full-screen window stays on screen while the picker is open and after Esc — the user is not pulled out of the space. | Ámbar's four collection flags. |
| P-04 | Safari | Picker over Safari | pending | — | OS7. |

## Providers & models (P4-T1)

| Row | App | Case | State | Result | Note |
|---|---|---|---|---|---|
| PV-01 | Quill Settings | Pane renders with tradeoffs, readiness and the global model | pass | Opened at the pane through the debug hook: every provider with its advantages and drawbacks in Spanish, the on-device model listed with "No recomendado" and selected. [Screenshot](qa/settings-providers.png). | — |
| PV-02 | Quill Settings | Plain http to a private-range IP is still blocked by ATS | pending | — | OS6: needs a request from the app to a LAN address, which raises the Local Network permission prompt only the owner may answer. The form refuses such addresses before saving (unit-tested). |
| PV-03 | Quill Settings | A real LAN server by `.local` name works | pending | — | OS6 (PLAN §2), same reason. |

## Profiles (P4-T2)

| Row | App | Case | State | Result | Note |
|---|---|---|---|---|---|
| PF-01 | Quill Settings | Pane renders: list, editor, settings, readiness | pass | The four built-ins listed with their symbols; the editor shows name, symbol, readiness ("No recomendado" for Solo ortografía on the on-device model) and every setting in Spanish. [Screenshot](qa/settings-profiles.png). Editing, versions, Try it with consent, restore and export/import are covered by `ProfilesPaneTests`. | — |

## General and About (P4-T5)

| Row | App | Case | State | Result | Note |
|---|---|---|---|---|---|
| GN-01 | Quill Settings | General renders: shortcut, login, kill switches, Reset | pass | The recorder shows ⌃⌥⌘R with the takeover note; the three capture switches and "Restablecer Quill…" with what it deletes. [Screenshot](qa/settings-general.png). The system-shortcut warning, the kill switches and the reset are covered by `GeneralPaneTests`. | — |
| GN-02 | Quill Settings | About: version, privacy summary, licences | pass | 0.1.0 (1), four privacy lines and the licence note, in Spanish. | — |

## Onboarding walkthrough (P5-T1)

On a **walkthrough build** — `Scripts/make-app.sh debug --bundle-id
dev.rrios.quill.walkthrough`, copied out of `build/`, launched with
`open -n --env QUILL_DATA_DIR=<empty folder>` (through `open`, so macOS does
not attribute the terminal's Accessibility grant to it) — and stepped with
`QUILL_DATA_DIR=<folder> swift Scripts/spike-driver.swift onboarding next`.
Its Keychain service is `quill.providers.walkthrough`; the development
build's grant is untouched.

| Row | App | Case | State | Result | Note |
|---|---|---|---|---|---|
| OB-01 | Walkthrough build | First launch opens onboarding at Welcome | pass | Steps: welcome, relocate, accessibility, provider, shortcut, practice (the clipboard step is skipped: Always Allow on macOS 26). | — |
| OB-02 | Walkthrough build | Relocate offers the move, and Continue is not blocked by it | pass | Running from outside /Applications: "Mover a Aplicaciones" offered; not pressed (it would replace the development build). | — |
| OB-03 | Walkthrough build | Accessibility step without the grant, no dead end | pass | Not trusted: "Abrir Ajustes del Sistema" offered, Continue goes on. [Screenshot](qa/onboarding-accessibility.png). | The grant itself and the steps after it on a real first run: OS5. |
| OB-04 | Walkthrough build | Provider step follows readiness.json | pass | With the committed labels ("No recomendado" for every built-in on-device) a hosted model is recommended, Apple Intelligence still offered with its label. [Screenshot](qa/onboarding-provider.png). The default rule is unit-tested against fixtures (`OnboardingTests`). | — |
| OB-05 | Walkthrough build | Shortcut and practice steps | pass | The recorder with ⌃⌥⌘R and the takeover note; the practice field with the Spanish sample; Done on the last step. | A first real rewrite in the practice field needs keystrokes: OS5. |

## Performance (P5-T4)

Signposts `capture-to-picker`, `first-token` and `replace` (subsystem
`dev.rrios.quill`, category `performance`; Instruments' os_signpost track, or
`log show --signpost`). The export of the TextEdit runs is
[`qa/signposts-2026-10-04.txt`](qa/signposts-2026-10-04.txt). Debug build,
on-device model, Solo ortografía, 2026-10-04.

| Row | App | Case | State | Result | Note |
|---|---|---|---|---|---|
| PF-P1 | TextEdit | Hot key → picker visible, accessibility capture (budget ≤ 200 ms, cap 250) | pass | 74.5 ms (the first after launch), then 28.9 and 28.5 ms. | — |
| PF-P2 | Chrome or an Electron app | Same, first capture that needs `AXManualAccessibility` (≤ 250 ms) | pending | — | OS6: needs an owner-run app. |
| PF-P3 | Mail | Same, ⌘C fallback (≤ 450 ms, cap 850) | pass | 50.4 ms (on-device run) and 64.5 ms (hosted run). | — |
| PF-P4 | TextEdit | First streamed token, on-device, inside a rewrite (≤ 1.5 s) | pass | 952, 1215 and 1036 ms. | Within budget, and far above the bare model: the session also composes the prompt and runs the context pre-check, which ask the framework's `tokenCount` several times, and lists the on-device models for the too-long alternatives. Worth trimming in a later pass; not a miss. |
| PF-P5 | Quill (in-app probe) | Bare first token, cold vs prewarmed (measured separately, §11) | pass | Cold: median 182 ms (min 180, max 779 — the first, loading the model). Prewarmed: median 216 ms (min 209, max 225). | The prewarm buys no measurable gain on this Mac once the model is resident; it still removes the 779 ms first-load outlier. Kept, since it costs nothing. |
| PF-P6 | TextEdit | Return → replacement (≤ 400 ms, cap 2.3 s) | pass | 349, 339 and 332 ms. | The restore delay (300 ms, SPIKES.md) is most of it; the replacement itself is visible earlier. |

## Privacy (P5-T5)

| Row | App | Case | State | Result | Note |
|---|---|---|---|---|---|
| PR-01 | Quill binaries | The user-text log canary is in the debug binary and absent from the release binary | pass | `strings -a` finds `QUILL-USERTEXT` in the debug binary (the positive control) and not in the release one; `verify.sh` checks it on every run. | — |
| PR-02 | Quill data folder | Holds only what PRODUCT §7 lists | pass | `Scripts/check-data-folder.sh` on the development data folder (78 files: settings, profiles with versions and samples, the bench's folders, probe rows) and, in `verify.sh`, on the folder the accessibility walk writes (5 files). A stray file fails it (checked). | — |
| PR-03 | TextEdit, hosted (mock) | `QUILL_LOG_HOSTS` shows only the resolved provider's host | pass | One rewrite through the mock provider logged one host, `http://127.0.0.1:8767`; an on-device rewrite logs none. Scheme, host and port only — never the path, query or body (unit-tested). | The pass with real providers, watched from outside with `nettop -p <pid>`, is OS6. |

## Running these rows

Two traps the driver hit (P3-T5), both fixed in `spike-driver.swift`:

- Rewriting `quill-spike.txt` under the open document makes TextEdit raise
  "another application has modified the file" at the next autosave; the sheet
  then swallows keys and Apple Events. The fixture is written once; `arrange`
  resets the text through accessibility.
- A shortcut posted as one key event with modifier flags leaves the HID state
  showing the modifiers held, and the ⌘C path rightly refuses
  (`modifiersHeld`). The driver now posts the modifiers' release, as a hand
  does.

Keys posted from a **compiled** helper do not arrive (it has no
Accessibility grant); `swift <script>` runs under the grant that the driver
uses. With a keyboard-sharing tool (InputLeap) active, check that the system
has a focused application before trusting a keystroke row.

## Use cases (P3-T8, P4-T6)

| Row | Use case | App | Model | State | Result | Note |
|---|---|---|---|---|---|---|
| Q-01 | U1 | TextEdit | on-device | pass | The shortcut over a selection, Ready, Return: `replaced` (verified), the toast line, one ⌘Z restores the original (P3-T5, 2026-10-04). | — |
| Q-02 | U1 | Notes | on-device | pass | Replaced through the picker, one ⌘Z restores it; the temporary note was deleted (P3-T5). | — |
| Q-03 | U1 | Mail | on-device | pass | Re-run 2026-10-04 with the body focused (`spike-driver focus AXWebArea 0`; the first attempts had focus in a header field, so ⌘C had nothing to copy): captured by ⌘C in 50 ms, `pasted` (WebKit cannot be re-read), ⌘Z restored it, draft deleted. |
| Q-04 | U1 | Safari | on-device | pending | — | OS7. |
| Q-05 | U1 | Google Chrome | on-device | pending | — | OS7. |
| Q-06 | U1 | Microsoft Teams | on-device | pending | — | OS7. |
| Q-07 | U1 | Slack | on-device | pending | — | OS7. |
| Q-08 | U1 | TextEdit | hosted (mock) | pass | Isolated data folder, `QUILL_TREAT_LOOPBACK_AS_REMOTE`, `mock-chat-server.py`: Awaiting consent, Return sends (the first POST arrives only then), Ready, Return replaces; ⌘Z restores. | — |
| Q-09 | U1 | Notes | hosted (mock) | pass | Replaced through the mock provider, ⌘Z restores; temporary note deleted. | — |
| Q-10 | U1 | Mail | hosted (mock) | pass | ⌘C capture in 64.5 ms, replaced, ⌘Z restores, draft deleted. | — |
| Q-11 | U1 | TextEdit | hosted (real) | pending | — | After OS7 (keys) — P4-T6. |
| Q-12 | U1 | Notes | hosted (real) | pending | — | After OS7 (keys) — P4-T6. |
| Q-13 | U1 | Mail | hosted (real) | pending | — | After OS7 (keys) — P4-T6. |
| Q-14 | U1 | Safari | hosted (real) | pending | — | OS7. |
| Q-15 | U1 | Google Chrome | hosted (real) | pending | — | OS7. |
| Q-16 | U1 | Microsoft Teams | hosted (real) | pending | — | OS7. |
| Q-17 | U1 | Slack | hosted (real) | pending | — | OS7. |
| Q-18 | U1 | Microsoft Word | on-device | n/a | — | Not installed on the owner's Mac (SPIKES S1-09). |
| Q-19 | U3 | Safari (article) | on-device | pending | — | OS7. |
| Q-20 | U3 | Google Chrome (article) | on-device | pending | — | OS7. |
| Q-21 | U3 | Preview (PDF) | on-device | pass | A fixture PDF: captured, flagged G11 (formatting not checked); Return does nothing while flagged, ⌘Return accepts, Return copies — "Copiado — este texto no se puede editar aquí", the rewrite on the clipboard. | — |
| Q-22 | U4 | TextEdit | on-device | pass | Ready with Solo ortografía, 2 switches to Trabajo and regenerates (first token 451 ms), Return replaces; ⌘Z restores. | — |
| Q-23 | U4 | Safari | on-device | pending | — | OS7. |
| Q-24 | U4 | TextEdit | hosted (mock) | pass | 2 switches profile; one more POST; replaced, ⌘Z restores. | — |
| Q-25 | U5 | TextEdit | on-device | pending | Invoked from TextEdit's own Services menu (pressed through accessibility): the host returned at once and the picker opened with the 10 delivered characters, Ready after ⌘Return. The target read as uncertain — TextEdit's focused element answered "no value" right after the menu press — and ⌥Return (Paste anyway) ended in "Copiado — no se pudo volver a la app": the focus-return check reads the system-wide `AXFocusedApplication`, which answered `kAXErrorCannotComplete` on this Mac all night. Quill failed safe (nothing pasted blind, the result on the clipboard). | OS6: the real contextual menu (a right-click) with a working system-wide element. |
| Q-26 | U5 | Safari | on-device | pending | — | OS7. |
| Q-27 | U5 | Services, invoked with `NSPerformService` | hosted (mock) | pass | The service returned to the caller in 7–12 ms (the host is never blocked); the picker opened in Awaiting consent and the mock server received no request. A second invocation while that session was open started nothing (P3-T6, 2026-10-04, isolated `QUILL_DATA_DIR`, `QUILL_TREAT_LOOPBACK_AS_REMOTE`). | The menu path itself is Q-25. |
| Q-28 | U2 | TextEdit | on-device | pending | — | P4-T6. |
| Q-29 | U2 | Notes | on-device | pending | — | P4-T6. |
| Q-30 | U2 | Mail | on-device | pending | — | P4-T6. |
| Q-31 | U6 | Quill Settings | on-device | pending | — | P4-T6. |
| Q-32 | U7 | Quill Settings | on-device | pending | — | P4-T6. |
| Q-33 | U8 | Quill Settings | on-device | pending | — | P4-T6. |
| Q-34 | U8 | Quill Settings | hosted (real) | pending | — | After OS7 — P4-T6. |
