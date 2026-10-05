# Quill — architecture

How the product in [PRODUCT.md](PRODUCT.md) is built. Model providers have
their own document: [PROVIDERS.md](PROVIDERS.md). Measuring quality:
[BENCH.md](BENCH.md). Order of work: [PLAN.md](PLAN.md).

## 1. Package layout

Quill is its **own SwiftPM package** at `native/quill/`, not more targets in
`native/Package.swift`:

- `native/Scripts/export-public.sh` publishes every **tracked** file under
  `native/` except `argos/` and `public/` to Ámbar's public repository.
  Anything of Quill's elsewhere under `native/` would leak there. Everything
  lives under `native/quill/`, which the export skips through a generic rule
  — any top-level directory holding a `.not-exported` marker file — so the
  exported script itself never names Quill (PLAN P0-T1).
- Ámbar's shared libraries are reused as a **local package dependency**:
  `.package(name: "Ambar", path: "..")`, products `AppCore` and `GlassUI`.
  Verified on 2026-10-03, twice: a separate package depending on `native/`
  by path links both, and a copy of `native/` with exactly this nested
  `quill/Package.swift` builds with no warnings while the parent still builds.
  The dependency keeps the name `Ambar`, so AppCore's resource bundle keeps
  the name `Ambar_AppCore.bundle` that `StringsBundle.swift` hard-codes.
- `native/quill/.build/`, `native/quill/.swiftpm/` and `native/quill/build/`
  (app bundles, P0-T2) are git-ignored (P0-T1).

```
native/
├── Package.swift                     Ámbar
├── packages/{AppCore,GlassUI,…}      shared, reused by path
└── quill/                            ← Quill's package (not exported)
    ├── Package.swift
    ├── packages/
    │   ├── QuillSupport/             `QuillLog` and other leaf utilities every target may import
    │   ├── ModelKit/                 provider contract + adapters (moved here in P0-T1)
    │   ├── RewriteKit/               profiles, prompts, guards, generation engine, evaluation
    │   └── SelectionKit/             capture and replace text in other apps
    ├── apps/Quill/                   the app: wiring + UI; debug probe and hooks (§3.6)
    ├── tools/QuillBench/             `quill-bench` CLI; data/{cases,judge,baselines}/, data/gate-v<n>.json, data/{prices,readiness}.json
    ├── Tests/{ModelKit,RewriteKit,SelectionKit,Quill,QuillBench}Tests/
    ├── assets/brand/                 the brand: QuillBrand.swift (icon, .icns, DMG background, share images), generate.py (SVG), make-brand.sh
    └── Scripts/                      make-app, make-dmg, release, bench, verify, check-matrix, check-accessibility, mock-chat-server.py
```

Dependency graph (an arrow means "imports"; nothing points upward):

```
Quill (app) ──► RewriteKit ──► ModelKit
     │                            ▲
     ├──► ModelKit (registry, Keychain store)
     ├──► SelectionKit ──► AppCore    (reuses Paster's approach; posts its own events)
     └──► AppCore, GlassUI
QuillBench ──► RewriteKit, ModelKit
every Quill target except ModelKit ──► QuillSupport (leaf: depends on nothing)
```

`RewriteKit` knows nothing about AppKit, the Accessibility API or
SelectionKit; `SelectionKit` knows nothing about models or profiles. The app
is the only place where they meet. `ModelKit` stays dependency-free and logs
nothing; its callers log. `tools/QuillBench/data/` holds every non-Swift file
of the bench and is declared excluded, so SwiftPM raises no warning for it.

## 2. One rewrite, end to end

```
hot key down (Carbon) → wait for the hot key's release          Ámbar: a synthetic key sent
                                                                while the trigger is down beeps
resolve profile   §5.3 order (the frontmost app is known)
resolve model     profile's pinned model › global choice         never a silent fallback
ModelProvider.prewarm(for:)                                      on-device: a single-use session
SelectionKit.capture() → Capture | refusal                      §3.1, caps 200 ms (accessibility) / 800 ms (⌘C fallback)
RewriteKit.GenerationEngine.run(profile, input, provider)        §4.5
picker / direct apply                                            §5.2
SelectionKit.replace(result, on: capture) → outcome              §3.2
```

**State ownership.** `RewriteKit.GenerationEngine` owns the generation
states: `idle`, `generating(partial)`, `ready(result, flags)`, `noChanges`,
`truncated(partial)`, `refused`, `tooLong(suggestion)`,
`failed(ProviderError.Code, partial)`, `cancelled`. The app's
`RewriteSession` view model wraps them with the states RewriteKit cannot
know: `capturing`, `refusedCapture(reason)`, `awaitingConsent`,
`waitingToStart`, `correcting`, `waitingForClipboard`, `applying`,
`applied(outcome)` — where the
outcome is replaced, pasted, pasted with the clipboard left holding the
rewrite (no complete snapshot, §3.4), copied (target not confirmed editable),
pasted but not confirmed (verification found no change), copied because the
selection changed, or copied because focus did not return. Each layer is tested against the states it
owns; PRODUCT §4.1 is the user-facing table over both.

## 3. SelectionKit — reading and replacing text in other apps

### 3.1 Capture

Capture has two caps. The **accessibility phase** is capped at **200 ms**;
when it succeeds, that is the whole capture. When it yields nothing and the
⌘C fallback runs, the capture is capped at **800 ms**: the 200 ms
accessibility phase, the modifier wait (capped at 400 ms, below), and a
**200 ms ⌘C phase**. Accessibility calls run off
the main thread, raced against the phase deadline, under a short messaging
timeout (`AXUIElementSetMessagingTimeout`, 100 ms) set once on the system-wide
element — which makes it process-wide; set on any other element it would
apply to that object only — so a busy host cannot stall Quill for the system
default of several seconds; `kAXErrorCannotComplete` is
how a busy or timed-out host answers.
Accessibility constants that Swift 6 imports as global `var`s
(`kAXFontNameKey` and the other attributed-string keys) are used as string
literals, as `AppCore.Paster` already does, to stay concurrency-safe.

1. **Focused element.** System-wide element → `kAXFocusedUIElementAttribute`.
   When that fails or returns nothing, ask the frontmost application's element
   (`NSWorkspace.frontmostApplication`) for its focused element.
2. **Chromium, Electron and other lazy trees.** If there is no element, **or
   the element reports an empty selection in a process not yet switched**,
   set `AXManualAccessibility = true` on the application element (once per
   process, remembered for its lifetime) and poll at 4 ms until the
   accessibility phase's deadline: Chromium builds its tree asynchronously. A tree still being
   built may answer with an empty selection rather than an error, so an empty
   answer is only believed after this retry. Apps that do not know the
   attribute answer `kAXErrorAttributeUnsupported`, which is harmless.
   `AXEnhancedUserInterface` is off by default — it is VoiceOver's switch and
   breaks window-manager animations — and may be enabled only by a per-app
   strategy entry (§3.3) that spike S1 justifies. Microsoft Teams is **not**
   Electron: it embeds `MSWebView2`, and S1 tests it on its own. Settings has
   a kill switch for both attributes.
3. **Refusals.**
   - The focused element's **subrole** is `kAXSecureTextFieldSubrole` → refuse
     ("Quill never reads password fields"). A password field's role is a plain
     `AXTextField`; checking the role would never match.
   - A selection that is empty or only whitespace after step 2 → refuse
     ("Select some text first"), with **no** ⌘C fallback: VS Code, for one,
     copies the whole line when nothing is selected.
   - `IsSecureEventInputEnabled()` is system-wide — one app leaving it on
     would block Quill everywhere — so it is not a refusal by itself. When it
     is on and a synthetic key shows no effect — `changeCount` unmoved after
     ⌘C, or verification failing after ⌘V (`CGEventPost` reports nothing) —
     the message says that secure input may be on in another app (a password field, Terminal's Secure Keyboard
     Entry). There is no public API to name that app, so Quill does not try.
4. **Read.** `kAXSelectedTextAttribute`, `kAXSelectedTextRangeAttribute`.
5. **Editability.** Editable when `kAXSelectedTextAttribute` is settable, or
   when the app's strategy entry names another **editable signal** (§3.3) —
   nothing else. A text role alone is not enough: iTerm2's focused element is an
   `AXTextArea` whose value is settable, and pasting there runs text in a
   shell. Otherwise the target is *uncertain*, and the picker offers "Paste
   anyway". **Read-only-only apps** — the terminal denylist in the strategy
   table (Terminal, iTerm2, Warp, Ghostty, kitty, Alacritty) — never offer
   Paste anyway. VS Code's integrated terminal shares the editor's bundle id
   and its input is xterm.js's helper textarea, whose selection may report as
   settable; an element whose `AXDOMClassList` contains `xterm-helper-textarea`
   is therefore read-only-only too. S1 confirms both.
6. **Rich content.** The accessibility font dictionary carries only name,
   family and size, so bold and italic are visible only in the font name.
   The capture is marked `hasRichFormatting` when, over the selection's
   attributed string (`kAXAttributedStringForRangeParameterizedAttribute`),
   font names (ignoring emoji and system fallback fonts such as Apple Color
   Emoji) differ between runs or contain Bold/Italic/Oblique, or any run
   has a non-zero `AXUnderline` (it holds the underline style; 0 means none),
   an `AXLink` or an `AXListItemPrefix` — or, on the ⌘C fallback,
   the pasteboard's RTF has bold/italic/underline/strikethrough runs, links
   or list markers, or its HTML has `b`,
   `strong`, `i`, `em`, `u`, `a` or `li` elements or inline styles with a bold
   `font-weight`, an italic `font-style` or a `text-decoration` (Chromium's
   spans), ignoring Google Docs' `<b style="font-weight:normal"
   id="docs-internal-guid-…">` wrapper. Chromium puts HTML on the pasteboard
   even for plain text, so its mere presence proves nothing. The result has
   **three states** — rich, plain, **unknown** (the app does not answer the
   attributed-string query and no pasteboard data was read) — and unknown is
   a flag (G11), never treated as plain; S1 records which apps
   answer. RewriteKit turns it into a flag (G11).
7. **Bounds** for placing the picker: `kAXBoundsForRangeParameterizedAttribute`,
   converted from the accessibility API's top-left global coordinates to
   Cocoa's bottom-left screen coordinates; falls back to the mouse location;
   clamped to the screen that contains it.
8. **⌘C fallback** — only when the accessibility path is **unavailable** (no
   element after step 2, attribute unsupported, API error), never when it
   reported an empty selection; and only with `.alwaysAllow` (§3.4). Take a
   **complete** snapshot (§3.4) **in parallel with the modifier wait**, with its
   own 200 ms deadline — if it does not complete, refuse rather than risk the
   user's clipboard; **wait for modifiers to clear** — ⇧, ⌃ and ⌥ as the
   hardware reports them (`hidSystemState`: the combined session state also
   counts synthetic events, measured in S1-05), and not ⌘, which combines into
   exactly the ⌘C being posted, as in `Paster` — if the 400 ms cap expires
   with modifiers still held, refuse too (a ⌘C then would reach the host with
   them). SelectionKit implements this wait and the focus wait (§3.2) itself,
   behind `KeyEventPoster`, `AccessibilityClient` and `Clock`, returning
   whether the condition was met: AppCore's `Paster` helpers return nothing
   and run on the real clock, so fakes could not drive them. The modifier wait
   matters because with ⌃⌥R, ⌃⌥ are usually still down when R comes up, and
   a ⌘C posted then reaches the host as ⌃⌥⌘C. Then post ⌘C with exactly the
   command flag; poll at 4 ms within the phase until `changeCount` has moved
   **and** the string is there — a host may clear the pasteboard before it
   writes the text (Mail, SPIKES S1-05); restore. The phase's 200 ms starts after the
   modifiers clear; the modifier wait counts toward the 800 ms cap. Editability is then
   *uncertain*. The host app writes that copy without privacy markers; PRODUCT
   §7 discloses it and Settings can disable the fallback. Without
   `.alwaysAllow` the fallback cannot run, and capture refuses where
   accessibility is unavailable, with the reason "needs Always Allow
   clipboard access" (PRODUCT §4.1).

The sequence is `SelectionKit.SelectionCapturer` (P2-T2). Its waits run on
the injected `Clock`; the ⌘C path's snapshot deadline runs on real time,
because it bounds reads that block in real time.

Verified on 2026-10-03 in TextEdit: setting the range, reading
`kAXSelectedText` (settable), writing it and reading `kAXValue` back all
worked. On an Electron app (the Claude desktop app) the system-wide focus
queries returned `kAXErrorCannotComplete` — what steps 1–2 handle. iTerm2's
`AXTextArea` with a settable value is what step 5 handles.

### 3.2 Replace

**Paste is the primary path**, not writing `kAXSelectedText`:

- An accessibility write can report success without changing the field
  (documented by other projects for WhatsApp and Messages), and it bypasses
  the host's undo stack. A paste is one native undo step in nearly every app.
- An accessibility write remains a **per-app strategy** for apps where spike
  S2 shows paste failing; direct apply is disabled there (PRODUCT F2) and the
  toast never promises ⌘Z.

Sequence. Every wait polls at 4 ms with a cap; there are no fixed sleeps (Ámbar lesson).

1. **Wait for the Return key to come up** (SelectionKit's wait, behind
   `KeyEventPoster` and `Clock`, capped at 400 ms; the live implementation
   reads key state the way `Paster.waitForKeyRelease` does) —
   Ámbar 1.1.1: a paste posted while Return is down beeps in the host.
2. **Order the picker out** — not alpha-hide: a hidden panel keeps key status
   and swallows ⌘V (Ámbar lesson).
3. **Wait for focus to return** — one 600 ms cap for the whole step (typical:
   tens of milliseconds). Done when the focused element equals the captured
   element (`CFEqual`), or when the focused application's pid is the captured
   app's (what `Paster.waitForKeyboardFocus` checks today) — Chromium may
   recreate element objects, so a pid match with a different element proceeds
   to the selection check, which decides. Cap expired → copy instead and say
   so. Spike S3 measures both signals.
4. **Selection check.** Re-read the selected text and range whenever
   accessibility can (captures via accessibility, and Services deliveries,
   §5.1); if they no longer match, do not paste — put the result on the
   clipboard and say so.
5. **Snapshot** — already taken while the model was generating (§3.4); if
   `changeCount` moved since, it is taken again here.
6. **Write the result** with `NSPasteboard.prepareForNewContents(with: .currentHostOnly)`
   (no Universal Clipboard) plus the `org.nspasteboard.TransientType` and
   `org.nspasteboard.ConcealedType` markers (clipboard managers, Ámbar
   included, record neither). For a Paste anyway, trailing line breaks are
   removed first. Remember the resulting `changeCount`.
7. **Wait for modifiers to clear** (⇧⌃⌥ from the hardware state, as in §3.1
   step 8) and post ⌘V through `KeyEventPoster`.
   Its live implementation posts its **own** events, following
   `Paster.pasteToFrontmostApp`'s approach (the HID event tap,
   `.cghidEventTap`, with flags forced to exactly ⌘) — Paster itself hard-codes `kVK_ANSI_V` and has no ⌘C — and
   tests use the fake, so no test ever posts a real key. The key code is the
   one that produces "c"/"v" in the **current keyboard layout**, found with
   `UCKeyTranslate` **with the ⌘ modifier state** (on "Dvorak – QWERTY ⌘" the
   ⌘ layer differs from the plain one); when no key yields the letter
   (Cyrillic, Greek), the ASCII-capable layout
   (`TISCopyCurrentASCIICapableKeyboardLayoutInputSource`) and finally the
   ANSI code are used. TIS calls run on the main thread. Ámbar inherits the
   ANSI-only behaviour, noted for it separately.
8. **Verify** by re-reading when accessibility can: the value contains the
   result, or the selection collapsed after it. Unverifiable → the toast or
   picker says "Pasted", never "Replaced"; verified and **not** changed →
   outcome `pastedUnconfirmed` ("Pasted — couldn't confirm the change"), with
   the secure-input hint of §3.1 step 3 when it applies.
9. **Restore after the restore delay** (measured in S2; the host reads the
   pasteboard asynchronously, and restoring too early pastes the old content)
   — **only if a snapshot exists and `changeCount` still equals the value from
   step 6**. If the user copied something meanwhile, their copy wins. The
   restore write is itself marked transient and always `.currentHostOnly`: no
   API says whether the original was host-only (password managers write it
   that way), so a restore must never push it to Universal Clipboard.

The sequence is `SelectionKit.SelectionReplacer` (P2-T3). When a snapshot read
that timed out is still running after the extra 300 ms, it writes nothing and
returns `clipboardBusy`, which the session shows as `waitingForClipboard`
(§3.4). Key codes come from a `KeyboardLayoutSource` (the current layout's ⌘
layer, the ASCII-capable layout, then ANSI), injected so tests drive each case.

### 3.3 Strategy table

`AppStrategy` maps bundle identifiers to overrides: capture via ⌘C only,
replace via accessibility write, restore delay, read-only-only (the terminal
denylist), enhanced accessibility allowed, **`undoVerified`** (S2 confirmed
that ⌘Z undoes a paste there — direct apply requires it, PRODUCT F2), and an
**editable signal** for apps
whose fields do not report the selected text as settable (for example a
settable `AXValue` on a text role, or an `AXEditableAncestor`) — without it
Teams, Slack or Chrome would stay "uncertain", and direct apply would never
run there. The default strategy needs no
entry. The table is data (`SelectionKit/AppStrategy.swift`); each entry cites
the [SPIKES.md](SPIKES.md) row that justified it, and a test checks the rows
exist. Mail captures via ⌘C only until decision D-S1 (SPIKES.md, README Q12).

### 3.4 Pasteboard snapshot and the access policy

- **Access policy.** Since macOS 15.4, `NSPasteboard.accessBehavior` governs
  programmatic reads of the general pasteboard: `.default` ("ask upon
  programmatic access"), `.ask`, `.alwaysAllow`, `.alwaysDeny`. A first alert
  moves an app to `.ask`, which asks on **every** read — so an alert could
  appear mid-paste, take focus, and send ⌘V to the wrong place. An app in
  `.default` is not even listed in System Settings until it has triggered an
  alert. Measured on 2026-10-03 (macOS 26.6.2): an unsigned probe reports
  `.alwaysAllow`, and the system carries a developer-preview switch for the
  policy — so on macOS 26 the policy is very likely **not enforced by
  default**, and today Quill sees `.alwaysAllow`. Quill **reads the general
  pasteboard only when the behaviour is `.alwaysAllow`**:
  - `.alwaysAllow`: snapshot and restore as below; the ⌘C fallback is available.
  - `.default`, `.ask`, `.alwaysDeny`: no snapshot, no restore (restoring an
    empty snapshot would clear the clipboard); a paste leaves the rewrite on
    the clipboard and the picker says so; the ⌘C fallback is unavailable, and
    capture refuses where accessibility is unavailable.
  - Onboarding (PRODUCT F4 step 4) does nothing when the behaviour is already
    `.alwaysAllow`. Otherwise it offers **Check clipboard access**: one
    user-initiated read at a calm moment (no paste pending), which makes
    macOS show its alert and list Quill; then a link to System Settings →
    Privacy & Security → **Paste from Other Apps**
    (`x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard`)
    and "Restart Quill" — the pane itself warns that a change may only take
    effect after the app quits — before the behaviour is read again.
  - Spike S2 exercises Ask and Deny by enabling the policy's developer-preview
    switch for Quill (OS2).
- **Snapshot.** For a replace, taken off the critical path while the model
  generates; for the ⌘C fallback, in parallel with the modifier wait, with its
  own 200 ms deadline (§3.1 step 8).
  Types are listed first; file-promise types are not read (they make the
  snapshot incomplete); legacy aliases the system synthesizes from the modern
  types ("NeXT TIFF…", "Apple PICT…", `NSFilenamesPboardType`) are skipped
  without loss, since writing the modern types back regenerates them. The
  deadline is a race resolved once — never a task group, which would wait for
  a child blocked on the read (found by P2-T1's test). No API says which
  other types are generated lazily, and `data(forType:)` blocks and cannot be
  cancelled, so reads run on a dedicated thread: on timeout Quill marks the
  snapshot incomplete and never writes to the pasteboard while that read may
  still be running — Copy included: it waits up to 300 ms more for the read to
  end; if it still has not, the session enters `waitingForClipboard` (the
  result greyed, Copy and Return disabled). When the read ends, the session
  returns to the state it came from (`ready` or `flagged`, so a flag still
  needs ⌘Return) with the snapshot complete or incomplete; Esc leaves at any time. A
  snapshot is **complete** only if every type was read within the deadline
  (300 ms for a replace; for ⌘C, its own 200 ms running in parallel with the
  modifier wait) and the 10 MB total; a skipped type
  makes it incomplete. Only a complete snapshot is restored — restoring part
  of a clipboard would silently drop the rest. Incomplete → no restore, and
  Quill says "Your clipboard now holds the rewrite" (or, for ⌘C, refuses).
  Data compared byte for byte in tests.
- Ámbar is exposed to the same access policy; that is noted for Ámbar
  separately, not fixed here.

### 3.5 Permission

Accessibility is granted per code signature (TCC ties it to the designated
requirement: team + bundle id). Carried over from Ámbar:

- Development and bench builds are signed with the owner's **Developer ID**
  certificate (`make-app.sh` already prefers it; Apple Development has a
  different designated requirement, so switching between the two would drop
  the grant) from the first build (P0-T2): ad-hoc signatures change every build and silently
  revoke the grant, and a team-less self-signed identity makes the Keychain
  partition items by cdhash, so they would prompt again after every rebuild
  (§4.2). The self-signed "Ambar Local Signing" identity is a fallback that
  keeps the Accessibility grant but accepts those Keychain prompts.
- Debug builds are signed without a secure timestamp, so they build offline;
  release builds carry one, which notarization requires. The designated
  requirement — what the grant is tied to — is the same either way.
- The bundle id must be final before the first **distributed** build (README Q1).
- A grant given while the app runs makes `AXIsProcessTrusted()` true, but
  synthetic events may still fail until a restart; the app offers the restart.
- Onboarding offers moving the app to /Applications before the grant
  (`AppCore.AppRelocation`).

### 3.6 Probe, picker harness and debug hooks

Debug builds only (`Scripts/make-app.sh debug`; the default release build
compiles all of this out):

- **Debug → Probe frontmost app**: after a 3-second countdown, runs capture
  against the frontmost app and, optionally, a replace with a test string, and
  writes one JSON row (bundle id, focused role and subrole, which path worked,
  editability signals, rich-formatting signal, bounds, timings, verification,
  restore outcome) to `<data dir>/probe/`. It runs inside the signed app, so it
  uses the app's own Accessibility grant — a command-line probe would borrow
  the terminal's — and it exercises SelectionKit's real code.
- **Debug → Live provider test**: runs a burst of 30 on-device generations
  from inside the app, to measure the framework's rate limiting for an
  `LSUIElement` app that never activates (PROVIDERS §8).
- `QUILL_TREAT_LOOPBACK_AS_REMOTE` (debug only): treats a loopback custom
  server as a hosted provider, so the mock server (PLAN P3-T3) exercises the
  consent, waiting-to-start and cost paths.
- **Debug → Accessibility status**: shows `AXIsProcessTrusted()` (P0-T2).
- **Debug → Test fields**: a small window with a plain field, a rich-text
  field and a password field, for the probe's native rows (P0-T3).
- **Debug → Picker harness**: opens the picker over the frontmost app with a
  fixed text, for spike S3.
- **Menu dump** (`spike-driver.swift menu`, P3-T2): builds the status menu
  with the code that fills it on opening — provider line included, once its
  check answers — and writes the titles to `<data dir>/probe/menu.txt`, because
  a script cannot open a status-bar menu without taking the screen.
- **Debug hooks** (environment variables read only in debug builds, as Ámbar's
  `ReviewHooks`): `QUILL_DATA_DIR` (isolated data directory),
  `QUILL_SUPPRESS_PROMPTS` (no permission prompts), `QUILL_DUMP_A11Y` (opens
  every onboarding step, every Settings pane and the picker in six states, prints
  each window's real accessibility tree — names resolved as VoiceOver does, through
  the title element of a Form row — and quits; `Scripts/check-accessibility.sh`
  fails on an unnamed control or a button under 14 pt, exempting only the window's
  own buttons and scroll-bar parts, which the system names by subrole; P5-T3),
  `QUILL_LOG_HOSTS` (log every host the app connects to, for the privacy check, P5-T5:
  `HostLoggingTransport` wraps the providers' transport and logs `QUILL-HOST
  <scheme>://<host>[:port]`, nothing else; in release it reads unset and the plain
  transport is used).

### 3.7 Testability

Every system touch point is behind a protocol — `AccessibilityClient`,
`PasteboardClient`, `KeyEventPoster`, `Clock` — with live and fake
implementations. `Clock` is Swift's own protocol (`ContinuousClock` live, a
manual clock in tests), so no SelectionKit type shadows it. The raw operations
the probe and the sequences are built from live in `SelectionOperations`
(P0-T3); the capture and replace sequences compose them (P2-T2, P2-T3). Unit tests drive capture and replace against fakes and
assert the **order** of effects (release wait before ⌘C; snapshot before
write; ⌘V only after focus returned and modifiers cleared; restore only after
the delay, with a snapshot, and with an unchanged `changeCount`; abort on a
changed selection). Pasteboard tests use a private named pasteboard; no test
posts a real key or touches the general pasteboard (Ámbar learned that a
suite that pastes wipes the developer's clipboard).

## 4. RewriteKit — profiles, prompts, guards

### 4.1 Profile

```swift
struct Profile: Codable, Identifiable {
    var id: UUID
    var name: String                   // 1–40 characters
    var symbol: String                 // SF Symbol name
    var builtIn: BuiltInProfile?       // which shipped profile it started from
    var settings: ProfileSettings      // PRODUCT §5 fields
    var guidance: String               // free text, ≤ 600 characters
    var examples: [Example]            // ≤ 8, each side ≤ 500 characters (§4.3)
    var model: ModelSelection?         // pinned model; nil = global choice
    var temperature: Double?           // nil = omitted, the provider's default applies
    var version: Int
    var updatedAt: Date
}
```

(`ProfileSettings`, not `Settings`, to avoid colliding with SwiftUI's
`Settings` scene in the app.) Validation runs when decoding and saving; an
invalid profile is rejected with a typed error, never truncated silently.
Sample texts for Try it live beside the profile (§4.2), not inside it, so a
profile export can include or leave them out.

### 4.2 Storage

All under `~/Library/Application Support/<bundle id>/` — `dev.rrios.quill`
until README Q1 is answered — or `QUILL_DATA_DIR` in debug builds:

| Path | Content |
|---|---|
| `settings.json` | `schemaVersion`, global model, shortcut, app defaults (and which of them apply directly, PRODUCT F2), the menu bar's next-rewrite profile, last used profile, custom servers (id, name, base URL, key required), providers already notified, accepted recipients per profile, kill switches |
| `cache/models-<provider>.json` | Model lists with prices, refreshed on demand or after 24 h |
| `profiles/<uuid>/current.json` | The profile |
| `profiles/<uuid>/versions/<n>.json` | Previous versions for compare and revert; the last 20 are kept |
| `profiles/<uuid>/samples.json` | Try it samples: ≤ 10 texts of ≤ 1,000 characters, each with its results for the current and the previous version |
| `bench/cases/`, `bench/results/`, `bench/sealed/` | Personal bench cases, run results, sealed gate failures (BENCH.md) |
| `probe/` | Probe rows (development builds only) |

JSON, so profiles can be read, diffed, exported and imported (`.quillprofile`),
encoded by `RewriteKitCoding` — sorted keys, dates as ISO 8601 with whole
milliseconds, so a value read back equals the value written.
Writes are atomic (temporary file + rename). Every file carries
`schemaVersion`; loading runs forward migrations (the scaffold exists from
version 1, tested with a synthetic version-0 fixture); an unreadable file is
moved aside as `*.corrupt-<date>.json`, never overwritten, and deleted after
30 days or by "Reset Quill".

**Implementation** (`RewriteKit/Store`, PLAN P3-T1). `StoreFiles` does the
I/O for every file kind: the value's own keys plus `schemaVersion`; migrations
edit the decoded JSON object before any type sees it, and a migrated file is
rewritten at once; the quarantine name is `<name>.corrupt-<UTC stamp>.json`
(a counter is added rather than replacing an earlier one), swept by the date in
the name. A file from a **newer** schema is an error and stays in place — a
downgrade must not destroy it. `SettingsStore` holds `QuillSettings` (plain
values: the shortcut as key code and Carbon modifiers, so RewriteKit needs no
AppKit) and notifies observers after each written change. `ProfileStore`
archives the stored version on every edit that changes content (an identical
save creates none), reverts as a new version, purges a deleted example from
`current.json` and every `versions/<n>.json`, seeds the built-ins into an empty
store and restores deleted ones. An imported `.quillprofile` becomes a **new**
profile (new id, version 1), never a replacement. `QuillReset` empties the data
folder and calls `removeAll()` on the app's credential store.

**Custom servers and the registry.** `ProviderRegistry` is an immutable value
(PROVIDERS §2). The app builds a new registry from the shipped providers plus
`settings.json`'s custom servers at launch and whenever the custom-server list
changes, and swaps it in; a rewrite in flight keeps the registry it started with
(`ProviderRegistryHolder`, which follows the `SettingsStore`).

**Keys.** The app keeps API keys in the Keychain (`KeychainCredentialStore`,
service `quill.providers`; debug builds whose bundle id is overridden, such as
the walkthrough build, use `quill.providers.<suffix>` so they never touch —
or prompt for — another build's items). `quill-bench` uses its **own** service
(`quill.bench`). Both names are internal, fixed, and never renamed with the
product (P6-T2). The app never reads or deletes the bench's items — "Reset
Quill" deletes only `quill.providers`; the bench has `keys remove`. The
bench is signed by `Scripts/bench.sh` with the Developer ID certificate
(§3.5), so its items are partitioned by team id and rebuilds are not
re-prompted. With the self-signed fallback identity, expect one "Always
Allow" prompt per rebuild.

### 4.3 Examples are a memory layer

Examples are persisted user text that enters every prompt of their profile,
so they follow `.claude/rules/llm-memory-layers.md`:

| Rule of the mould | How Quill applies it |
|---|---|
| Caps in the schema | ≤ 8 examples, each side ≤ 500 characters, enforced by validation on decode and save. |
| `{id, text, at}` shape | `Example { id: UUID, input, output, addedAt }`. |
| Deterministic filter on write **and** read | A personal-identifier screen (e-mail addresses, phone numbers, IBANs, card numbers with a Luhn check, Spanish DNI/NIE) runs on save — the editor offers neutral stand-ins — and again when composing, where an example that fails is skipped and marked. The rule's health and legal topics filter does not apply: examples are pairs the user wrote and chose, not facts inferred about them; what must not travel unnoticed is identifiers. The same screen covers guidance and Try it samples. |
| Budget with eviction order | Guidance and examples share one budget: 600 tokens in the compact strategy, 1,500 in the full one, counted with the pre-check's estimator. Guidance is counted first (compact sends at most its first 60 words); a bench-pinned example (BENCH §2.1) comes next and is never evicted; examples fill the rest, and when over, the **oldest** are dropped first (the newest correction is the most relevant). The editor marks what is not being sent. |
| Written only by the user's action | An example exists only because the user saved one. Nothing is derived automatically. |
| Visible, deletable, exportable | Listed in the editor; deleting one also removes it from every stored version; exports warn; "Reset Quill" deletes all. |

### 4.4 Prompt composition

`PromptComposer` builds a `GenerationRequest` from a profile, the input and
the provider's descriptor.

| Strategy | Used when | Shape |
|---|---|---|
| `compact` | The model's context is below `ProviderTraits.smallContextThreshold` (the on-device model) | rules under 120 words; then the first 60 words of guidance (the editor marks the rest "not sent to small models"); then examples as real turns; guidance + examples within 600 tokens |
| `full` | Everything else | Full rule set; guidance; examples; guidance + examples within 1,500 tokens |

- Fields that are inert under `scope: spellingOnly` (PRODUCT §5) are left out
  of the prompt.
- **Base rules**, always present: rewrite only the text received; return only
  the rewritten text; **keep who does what to whom**; add no greetings,
  signatures or placeholders; keep names, numbers and links; if nothing needs
  changing, return the text unchanged.
- **Settings add to base rules and override only their own subject.** "Keep
  the language" is emitted only when `targetLanguage` is unset; "keep tú or
  usted as written" only when `register` is `keep`; "keep names, numbers and
  links" is emitted by `preserve`, for exactly the categories it lists; "if
  nothing needs changing, return it unchanged" only when the length is kept
  and there is no target language (a shorter or translated text is a change). A **self-consistency
  test** (conversational-agent contract §7) composes every valid combination of
  settings and fails if the output contains a rule together with its opposite.
- The input always travels as its own message, declared as text to rewrite
  and never as instructions (contract §3).
- Rule ids and the pairs that must never meet live with the texts in
  `RewriteKit/Resources/prompts.json`; golden files per built-in × strategy
  (`Tests/RewriteKitTests/Golden/`) catch any unintended change.
- Prompt texts are versioned JSON resources — they contain Spanish, which the
  language hook rejects in Swift source — changing one requires a bench run and
  a new baseline (BENCH.md). Each composed prompt has a **prompt hash**, used
  by the readiness labels (§5.1), over exactly: the strategy's prompt-text version (texts are versioned per strategy), strategy,
  `ProfileSettings`, guidance, examples (the profile's own; a bench-pinned
  example is excluded, BENCH §2.1), temperature. Name and symbol are not
  part of it.
- **Context pre-check** before sending: tokens of instructions + examples +
  input, estimated by the async `ModelProvider.estimateTokens` (the on-device
  provider uses the framework's `tokenCount` on macOS 26.4+, others characters ÷ 3.5),
  plus an **output reserve of 1.3 × the input**, must fit the model's context.
  If not: `tooLong`, naming a model that fits — the single definition of the
  suggestion: when the resolved model runs on-device, only on-device or local
  (loopback) models are suggested, so a rerun never sends the text to a
  hosted provider it was not going to; when nothing fits, none. Return reruns
  once with the suggestion (PRODUCT §4.1), through `awaitingConsent` if it is
  a new recipient.

### 4.5 Generation engine

`GenerationEngine.run` drives one generation. Leading and trailing
whitespace (a triple-click selection's final line break, for instance) is
trimmed before composing and re-attached to the result, so it neither
distorts the guards nor merges paragraphs on paste. Then: availability → pre-check →
compose → `ModelProvider.stream` → finish reason → post-process (G1) → guards
→ terminal state. A finish reason of `length` ends in `truncated`; G10, a
finish reason of `contentFilter` and `ProviderError.Code.refused` end in
`refused`; `.cancelled`
ends in `cancelled`; every other code ends in `failed(code)`. Partial text is
kept for display, never for copying or applying.

### 4.6 Output guards

Deterministic, run on every result.

| # | Guard | Kind | Rule |
|---|---|---|---|
| G1 | Preamble strip | transform / flag | Remove the first line only when it matches a **closed list** of es/en preamble patterns ("Aquí tienes el texto corregido:", "Texto reescrito:", "Here is the rewritten text:", …), ends in a colon followed by a line break, and does not occur in the input; a single-line answer of the form "Texto corregido: <text>" is reduced to `<text>`. A first line that looks like a preamble (ends in a colon and a line break), is not on the list, **shares no content word with the input**, and is not a greeting from G6's list replacing a greeting the input opened with, is **flagged**, never cut — so a corrected or re-registered greeting ("hola juan:" → "Hola, Juan:" or "Estimado Juan:") and a reworded lead-in ("Sobre el informe…:") are neither cut nor flagged, while "Aquí está la versión mejorada:" is. Wrapping quotes, backticks or a code fence are removed only when the input was not wrapped the same way. |
| G2 | Invented placeholder | flag | `[…]`, `{{…}}` or `<…>` in the output but not in the input. |
| G3 | Preserved categories | flag | For each category in the profile's `preserve`: links and @mentions must all appear; **numbers in digits compared by value**, parsed with the input's language for decimal and thousands separators (es "1.000" and "1,5"; en "1,000" and "1.5"), so "2,5 %" → "25 %" is caught; times compared as values ("3pm" = "15:00"); spelled-out numbers are not compared; **names** are the tokens `NLTagger` marks `.personalName`, `.placeName` or `.organizationName` in the input, and must appear in the output, compared case- and accent-insensitively ("ana" = "Ana", "Maria" = "María"), except tokens the profile removes as interjections ("Mira", "Oye", which the tagger may mistake for names); **line breaks**: the output has the same number of interior line breaks as the input (edge whitespace is handled before generation, §4.5). Emoji must all appear unless `emoji` is `remove`. |
| G4 | Language | flag | `NLLanguageRecognizer`, both texts ≥ 40 characters: without `targetLanguage`, flag when the output's dominant language is **not among the input's two most likely languages**; with it, flag when the output's dominant language is not the target. |
| G5 | Length band | flag | Output/input word ratio outside the profile's `lengthBand`, evaluated only when the input has at least 6 words. |
| G6 | Added greeting or sign-off | flag | A greeting at the start or a sign-off at the end where the input had **none** (a profile may change the register of an existing greeting: "hola juan" → "Estimado Juan" is not an addition) (es/en lists, extendable), comparing case-, accent- and punctuation-insensitively after expanding the input's chat abbreviations with the same table the profiles use — so "bss" → "besos", "thx" → "thanks" or "hola" → "¡Hola!" are not additions. |
| G7 | No changes | state | Output equals input after trimming leading/trailing whitespace, unifying line endings, and unifying typographic variants (curly and straight quotes and apostrophes, non-breaking and ordinary spaces, "..." and "…") — nothing else → `noChanges`. |
| G8 | Empty | error | Empty after G1 → `failed(malformedResponse)`. |
| G9 | Example echo | flag | Computed on **normalised** text (the shared abbreviation table applied whatever the profile's `abbreviations` setting, then case, accents and punctuation folded). For each example whose normalised input is not essentially the user's (similarity < 0.8): flag when the output's similarity to the example's output is ≥ 0.9 **and** at least 0.2 higher than its similarity to the user's normalised input. A correct rewrite stays close to its own input once both are normalised; an echo stays close to the example. |
| G10 | Refusal | state | The output matches a refusal **aimed at the request** (es/en: "No puedo ayudarte con esa solicitud", "No puedo reescribir este texto", "I can't help with that request", "As an AI…") and is not a plausible rewrite of the input (similarity to the input < 0.3) → `refused`. A rewritten apology ("Lo siento, no puedo ir") is not a refusal. The on-device provider's permissive guardrail mode returns refusals as text rather than throwing (PROVIDERS §8), which is why this guard exists. |
| G11 | Formatting loss | flag | The capture's formatting state (§3.1 step 6) is **rich** ("Formatting will be lost") or **unknown** ("Formatting couldn't be checked"). |
| G12 | Added facts | flag | Numbers in digits (by value, as G3), **absolute** dates and times, URLs, @mentions and e-mail addresses that appear in the output but not in the input. Absolute dates are `NSDataDetector` date matches whose text contains a digit or a month name ("15 de octubre", "15/10", "October 15", "3pm"), compared by their date components, so "15/10" → "15 de octubre" is the same date; relative words ("mañana", "tomorrow", "tmrw", "luego", weekdays) are not dates for G12, so expanding "tmrw" to "tomorrow" is not flagged, while "lo vemos luego" → "el 15 de octubre" is. |
| G13 | Trailing commentary | flag | A final paragraph matching a closed es/en list of model commentary ("Espero que te sirva", "Nota: he corregido…", "Let me know if…", "Note: I fixed…") that does not occur in the input, compared with G6's normalisation (chat abbreviations expanded, case, accents and punctuation ignored) — so "espero q te sirva" → "Espero que te sirva" and "lmk if…" → "Let me know if…" are not flagged. |

A flag never blocks showing the result; it blocks applying it without ⌘Return
(PRODUCT §4.1). The bench runs the same guards (BENCH §1).

Implementation notes (P1-T3; word lists in `RewriteKit/Resources/guards.json`,
cases in `Tests/RewriteKitTests/Fixtures/guard-cases.json`):
- Order: G1 transforms, then G8, G10 and G7 decide terminal states, then the
  flags.
- G3 names: a tagged word counts only if the tagger also classes it as a noun,
  so a sentence-initial "Te" or "I'm", capitalised by position, is not a name;
  the tagger tags no lowercase names ("ana"), which then are not checked.
- G3 and G12 read absolute dates and times with `NSDataDetector` and compare
  them by components (month, day; hour, minute); digits inside a date, time,
  link or @mention are not counted again as numbers.
- G6 and G13: a sign-off or closing note counts as added only if its phrase
  occurs nowhere in the input (normalised), so "gracias por…" moved to the end
  of a rewrite is not an addition.

### 4.7 Evaluation

`Evaluation` scores a result against a bench case: the guards, the finish
reason, `mustKeep`, `mustNotContain`, the change expectation, and reference
similarity (normalised word-level edit distance). Shared by `quill-bench` and
the app's Try it pane.

## 5. The app (`apps/Quill`)

Thin: wiring and UI. No logic a test cannot reach through a package or the
`RewriteSession` view model.

### 5.1 Components

| Component | Notes |
|---|---|
| Menu bar | `LSUIElement`. Menu: "Rewrite selection" (with the shortcut), quick profile list (sets the profile for the next rewrite), provider status (available / needs a key / Apple Intelligence off / needs a provider), Settings…, About, Quit; Debug submenu in development builds. Rebuilt on every opening, so the provider line asks the provider again (a removed key shows at once); a shortcut that could not be registered gets its own line; "Allow Accessibility…" while untrusted, and "Restart to finish enabling" when the grant arrives while running (`PermissionWatcher`, polled once a second). |
| Hot key | `AppCore.HotKeyCenter` (Carbon; needs no permission; hot-key events are delivered per process, so Ámbar's private signature is harmless inside Quill). Registered with **`kEventHotKeyExclusive`** through a backwards-compatible addition to `register` that takes options and reports the `OSStatus` (today it returns nil and drops it; Ámbar keeps the old call), so a combination another app holds **exclusively** (`eventHotKeyExistsErr`, −9878) is reported as "in use by another app" and Quill does **not** fall back to a shared registration — measured on 2026-10-03, a shared registration under an exclusive owner returns no error but never receives events. Against apps that registered the same keys normally, Quill's exclusive registration succeeds and takes the combination over (they stop receiving it) — and returns no error, so Quill cannot tell that this happened (measured); the shortcut recorder shows a general note that the combination is taken over from apps that registered it normally. Re-verified with Quill's own registration on 2026-10-04 (P3-T2) against a scratch process holding ⌃⌥⌘R: exclusive owner first → the menu shows "in use by another app" and the key still reaches the owner; shared owner first → Quill registers with no error and receives the key, the owner no longer does. Host menu shortcuts are not visible to Carbon and are overridden silently — onboarding says so. The recorder warning for system shortcuts lives in Quill's Settings view, beside `AppCore.ShortcutRecorder`: a built-in table of macOS's default system shortcuts plus the user's overrides from `com.apple.symbolichotkeys` (which stores only changed entries, with Cocoa modifier masks converted to Carbon's) — no AppCore change. |
| Picker | Borderless, **non-activating** `NSPanel` that can become key — the pattern Ámbar ships in `AmbarPanel` — so it takes the keyboard while the host stays active and keeps its selection. `collectionBehavior` = Ámbar's four flags: `.canJoinAllSpaces`, `.fullScreenAuxiliary`, `.transient`, `.canJoinAllApplications`; without the last, opening it over another app's full-screen space pulls the user out of it (`PanelController.swift` records that failure). Liquid Glass backdrop from `GlassUI`. Placed at the selection bounds (§3.1 step 7). States and keys: PRODUCT §4.1. Built in P3-T4: `PickerController` owns the panel, places it with `PickerPlacement`, routes keys through a local key-down monitor scoped to the panel (while correcting, only ⌘Return and Esc reach the session; the rest is typing), and re-measures the SwiftUI content on every state change keeping the top edge; `PickerView` renders the session — chips wrap to new rows (`ChipFlow`) rather than truncate a name, D shows a word-level diff (`WordDiff`). Verified in QA.md P-01…P-03. |
| Toast | Non-interactive panel for direct apply (PRODUCT F2). Anything that needs an action opens the picker instead. Built in P3-T5 (`ToastController`): borderless, ignores the mouse, never key — so ⌘Z goes to the host —, placed like the picker, announced to VoiceOver, gone after 2.2 s; it also carries the Applied line after a picker apply. |
| Services provider | **Send-only** `NSServices` entry "Rewrite with Quill" (`NSSendTypes` plain text, no return types; an empty `NSRequiredContext` so macOS enables it). A send-and-return service must hand back its result while the host waits blocked (up to `NSTimeout`), which an interactive picker cannot do. The provider copies the text and **returns at once** — the host's main thread is blocked until it does, so an accessibility query from inside the handler would time out — then, asynchronously, reads the focused element through accessibility as in §3.1 and compares its selection with the delivered text: equal → editable per the settable rule; different or unreadable → uncertain. Then the picker opens. A hosted model waits for Return (`waitingToStart`), so another process calling the service cannot spend the user's key unattended. Built in P3-T6 (`ServicesProvider`): the handler copies the text and returns on the next run-loop turn; the capture is built afterwards — a password field is refused, a selection that is not the delivered text is uncertain, terminals stay read-only-only. The title lives in `Contents/Resources/<lang>.lproj/ServicesMenu.strings` (copied by `make-app.sh` from `apps/Quill/BundleResources`) and names the product, so P6-T2's rename updates it with `Info.plist`. |
| Settings window | The macOS Settings layout: an `NSTabViewController` with a toolbar of panes (General · Providers & models · Profiles · Apps · About), each a SwiftUI view in its own hosting controller, sized to its content, titling the window. `SettingsWindowController` opens at a pane (an error's "open settings" lands on Providers); panes not built yet say so. Providers & models (P4-T1): `ProvidersPaneModel` — rows from the live registry with their tradeoffs (`Presentation`), availability ("needs a key" with its action), keys saved to and removed from the Keychain, model lists through `ModelListCache` (the on-device list loads by itself; a server's only on request; decoded lists are kept in memory keyed by the file's modification date, so a list of hundreds is decoded once and a file changed underneath is read again), readiness of the last used profile per model — computed in one batch when the lists change (`ReadinessIndex.labels`: the prompt hash and the edited check once per strategy, not once per model), never while drawing a row — the chosen global model at the top, each provider as one line that opens into its tradeoffs, key, connection and recommended models, and the full catalogue (hundreds on OpenRouter) in a searchable, lazy model browser shared with the profile editor; a saved key is tested at once, "Test connection" (a `-1022` reads as `insecureConnection`), the once-per-provider notice before a hosted global model, and custom servers under `ServerAddress` (PROVIDERS §4). Profiles (P4-T2): `ProfilesPaneModel` — the editor over a draft saved as a new version, versions with the fields that differ and revert, examples with the identifier screen, stand-ins and the composer's "not sent" marks (budget, personal data, guidance past the compact strategy's 60 words), deleting an example through the store (purged from every version), samples and Try it (the same consent as a rewrite, `ConsentRule`, before samples go to a hosted recipient; results kept beside the previous version's), the pinned model chosen in the model browser, the symbol from a grid, export with its warning, import as a new profile, restoring deleted built-ins, and the readiness label ("not evaluated (edited)" for an edited built-in). Apps (P4-T3): `AppsPaneModel` — per-app default profile and *apply directly* (`settings.json`'s `appDefaults` and `directApplyApps`), added from the running apps; deleting a profile removes its mappings. General (P4-T5): `GeneralPaneModel` — the recorder with the system-shortcut warning (`SystemShortcuts`: macOS's defaults by symbolic id, replaced or turned off by the user's `com.apple.symbolichotkeys` entries, Cocoa masks converted to Carbon's), the new shortcut re-registered exclusively with its problem shown, launch at login (`AppCore.LaunchAtLogin`), the three capture kill switches (the live selection is rebuilt when they change), and "Reset Quill" behind a confirmation, which restarts the app. About: version, the privacy summary and licences. |
| Edit menu | A main menu with Edit (Cut, Copy, Paste, Select All, Undo, Redo) installed at launch, as Ámbar's `EditMenu` (P4-T1; the picker's key monitor still sees its keys first): an `LSUIElement` has no menu bar, so without it ⌘C and ⌘V do nothing in Quill's own text fields (found in P2-T5). |
| Onboarding window | PRODUCT F4. Built in P5-T1: `OnboardingModel` owns the steps (relocation only when `AppRelocation` offers one, the clipboard step only when `accessBehavior` is not Always Allow), the Accessibility state (polled, "restart to finish enabling"), the clipboard re-read, and the provider default — the on-device model only when every built-in reads "works well" on it in `readiness.json` (README Q5), else a hosted model is recommended; it reuses `ProvidersPaneModel` for keys, models and the hosted notice, and `GeneralPaneModel` for the shortcut. Shown at launch until `settings.json`'s `onboardingCompleted`. A walkthrough build (QA.md) runs it with an isolated data folder and Keychain service. |
| Error presentation | One mapping from every `ProviderError.Code`, engine state, capture refusal and replace outcome to copy and an action. `Presentation` (P3-T7): exhaustive switches return a localization key, its arguments and the action (open provider, Apple Intelligence, Accessibility, Paste or capture settings; retry); the picker, the toast and the session's Return-in-Failed all read it. `PresentationTests` lists every case beside an exhaustive switch (a new case does not compile until listed) and fails on missing copy in either language, a wrong argument count, an untranslated line or a missing action. |
| Tradeoff copy | One mapping from every `Tradeoff` case to localized sentences — in `Presentation`, with the `Recipient` names (brands and hosts pass through untranslated). |
| Readiness labels | `readiness.json`, produced by `quill-bench export-readiness` from the committed baselines into `tools/QuillBench/data/readiness.json` and copied into the app bundle by `Scripts/make-app.sh`. Entries are keyed by **prompt hash** (§4.4) × **canonical model identity** — `vendor/model` (OpenRouter and Vercel ids already have that shape; OpenAI ids get `openai/`), and for the on-device model `apple/on-device@<macOS major>` — the model changes with major OS releases, and the bench re-measures it after each — mapping BENCH's verdicts: ready (confirmed) → "works well", ready (unconfirmed) → "may need review", any "not ready …" (including "not ready (development NN %)") → "not recommended", any "not evaluated …" (including "not evaluated (CLI rate-limited)") → "not evaluated". The key also carries RewriteKit's **evaluation version** (bumped whenever guards or evaluation change), so a verdict measured with older guards is not reused. A profile the user edited has a new hash and shows "not evaluated (edited)"; Try it signals are shown beside it, never turned into a label. |

### 5.2 Picker and direct apply

The `RewriteSession` view model owns PRODUCT §4.1 and is unit-tested for
every key in every state. It lives in `apps/Quill/Session/` and reaches the
outside only through three protocols — `SessionSelection` (capture, snapshot,
replace, copy, the clipboard wait; the live one wraps SelectionKit in P3-T5),
`ModelCatalog` (context sizes, prices, too-long alternatives) and
`ExampleSink` (Save as example; the live `StoreExampleSink` saves through the profile store, so a correction adds one example and one version, replaces the chosen one at 8, and its stand-ins pass the identifier screen — P4-T4) — so
`RewriteSessionTests` drives it with fakes, temporary stores and the real
engine; a table test walks every key of every row and a deliberate mutation
(Return applying a flagged result) fails it. `Scripts/mock-chat-server.py`
(127.0.0.1 only; `--seed <data dir>` adds it as a custom provider and the
global model) plus `QUILL_TREAT_LOOPBACK_AS_REMOTE` run the hosted path
end to end through the real Chat Completions adapter
(`QUILL_MOCK_CHAT_URL=… swift test --filter RewriteSessionMockServer`). Direct apply runs the same session without showing
the picker; it applies only under the conditions of **PRODUCT F2** (the single
definition) and opens the picker on anything else.

### 5.3 Resolution rules

- **Profile**: the picker's choice › the menu bar's next-rewrite choice (used
  once) › the app default › the last used.
- **Model**: the profile's pinned model › the global choice. If the pinned
  model's provider is unavailable (key removed, Apple Intelligence off, model
  gone), the session fails with "Choose a model for <profile>" — it never
  substitutes another provider.
- **Deleted profile still used as an app default**: the mapping is removed
  when the profile is deleted (the Apps pane shows it); a stale mapping met at
  runtime opens the picker with the last used profile and a note.
- **Large hosted rewrite**: over 1,500 words on a hosted model, the session
  waits for Return and shows an estimated cost when a price is known
  (`ModelDescriptor.pricing`, PROVIDERS §8).
- **User text to a new recipient** (the single definition of this trigger):
  when a profile with **user-authored** examples or guidance — shipped
  examples do not count — resolves to a **remote** provider (a recipient
  other than this Mac) it has not used before, a
  one-time notice says they will be sent there and the session waits in
  `awaitingConsent`; accepted recipients are remembered
  per profile in `settings.json`. The same state carries the one-time notice
  per hosted provider. Nothing is sent before acceptance.

## 6. Privacy and security

- **Logging**: a single `QuillLog` wrapper over `os_log`, created in P0-T3 so
  all code uses it from the start. User text goes only through
  `QuillLog.userText(…)`, which is a no-op unless the build flag
  `QUILL_LOG_USER_TEXT` is set (it is set only in debug); the format string
  for user text carries a canary (`QUILL-USERTEXT`) so a release build can be
  checked with `strings` (P5-T5).
- **Network**: only the endpoint of the provider the profile resolves to, only
  on a user-triggered rewrite, a model listing or a connection test. No update
  checks, no other traffic. Verified with the `QUILL_LOG_HOSTS` debug hook
  during a full QA pass.
- **Remote notices**: accepted before sending (`awaitingConsent`), once per
  hosted provider (recipients from `ProviderTraits.Execution.remote(recipients:)`,
  which names the routed party too — PROVIDERS §8 item 7), and once per
  profile under the trigger defined in §5.3.
- **Prompt injection**: the selected text is data. The worst a hostile text
  can do is produce a wrong rewrite: in the picker the user sees it before
  applying; direct apply applies only results with no flag, and ⌘Z undoes it
  (direct apply runs only on the paste path); Services never
  starts a hosted rewrite unattended.
- **Hardened Runtime, no sandbox, no entitlement exceptions** (no microphone,
  no JIT, no library-validation exception).

## 7. ModelKit amendments before RewriteKit depends on it

Found by the planning audit and implemented in PLAN P1-T0a (contract) and
P1-T0b (provider specifics) — except the app-side registry rebuild (item 9),
which is P3-T1. The list lives in **PROVIDERS §8** only, so there
is a single source to keep current.

## 8. Localization

Spanish (development language, as Ámbar) and English for the MVP (README
D-12). Same approach as Ámbar — `.strings` / `.stringsdict` per module
resolved through a module bundle, English keys, every `String(localized:)`
passes `bundle:` — so `native/Scripts/check-localization.sh` can be
parameterised to check Quill's resource directories too (P5-T2). Done:
the script reads `LOCALIZATION_*` variables whose defaults are Ámbar's own
paths (run bare, it checks exactly what it always did, and names no other
app); `native/quill/Scripts/check-localization.sh` points it at Quill — the
app's tables, `BundleResources/*/InfoPlist.strings`, AppCore's bundle (which
may carry more languages than Quill announces, never fewer), the
`PickerCopy.string` wrapper and interpolated keys resolved against the
catalog, and Quill's own reviewed cognate list. Counts use a
`.stringsdict`. `verify.sh` runs both checks.

**Resource bundles.** Older SwiftPM builds generated a `Bundle.module` that
looked only at the app's root and at the absolute build path, then called
`fatalError` — it worked on the developer's Mac and crashed on every user's
(Ámbar's `StringsBundle` exists because of it). Xcode 27's build system
looks in `Bundle.main.resourceURL` first, but the toolchain may change
again, so every Quill module with resources resolves its bundle through a
helper equivalent to `StringsBundle`, which lives in `QuillSupport` and is
built in P0-T2 with the app's first strings.
The check does not rely on launch-time loading — RewriteKit's word lists
load on the first rewrite — but on a `--self-check` launch argument, honoured
in release builds too, that loads every resource bundle and exits **before
touching the data folder, the Keychain or the hot key**; `verify.sh` runs it
against the release app with `native/quill/.build` renamed, plus a check that
every built `*.bundle` sits in `Contents/Resources`. Implemented in P3-T2
(`SelfCheck.swift`, run from `main.swift` before `NSApplication` exists): the
app's strings and RewriteKit's four JSON resources, loaded through the real
loaders, must resolve inside `Contents/Resources`, and every bundle there must
load. Removing `Quill_RewriteKit.bundle` from a copy of the app makes it exit
with SwiftPM's "unable to find bundle" fatal error (status 133) — checked.

## 9. Distribution

Developer ID, Hardened Runtime, notarized and stapled, shipped as a DMG and
downloaded from the owner's site, as Ámbar. No auto-updater in 1.0 (Ámbar has
none either; Sparkle stays a later item for both). Scripts are parameterised
copies of Ámbar's `make-app.sh`, `make-dmg.sh` and `release.sh`, which today
hard-code `Ambar.app`, `dev.rrios.ambar` and `AMBAR_*`.

## 10. Verification and CI

The repository's origin is Forgejo, which runs only `.forgejo/workflows/`
(the `.github/workflows/` files, Ámbar's `native-ci.yml` included, do not run
there), on a self-hosted runner that is not a Mac. So Quill's gate is a
**local verification script**, `native/quill/Scripts/verify.sh`, run at the
end of every phase and before every merge, and quoted in the PR description: release build; zero warnings
after a forced rebuild; `swift test` with live tests off; localization check;
accessibility check; the resource-bundle self-check (§8); the export leak
check (a fresh export into a temporary folder contains no "quill"); app bundle assembly with `codesign --verify --strict` and
the Hardened Runtime check; the release-binary log canary check. Registering
the owner's Mac as a Forgejo runner for these jobs is an option (README Q10),
not a dependency. P6-T1 (2026-10-04): on a fresh `git clone --branch` of the
working branch the script passes end to end — after the first such run found
every Quill script tracked as non-executable (this repository has
`core.fileMode false`, so a local `chmod` never reached the index). The
complete step list: forced rebuilds with zero warnings and tests in
`native/quill` and `native/`; both bundles assembled, signed, Hardened Runtime,
`readiness.json` inside; the log canary; the accessibility walk and the data
folder it leaves; the resource-bundle self-check with `.build` renamed; Quill's
and Ámbar's localization checks; the export leak check; the matrix files.

## 11. Performance budgets

Typical values are budgets; worst cases are caps that guarantee the flow
never hangs.

| Step | Typical (budget) | Worst case (cap) |
|---|---|---|
| Hot key release → picker visible, accessibility capture | ≤ 200 ms | 250 ms (200 capture + 50 to show the picker) |
| Same, first capture in a process that needed `AXManualAccessibility` | ≤ 250 ms | 250 ms |
| Same, ⌘C fallback | ≤ 450 ms | 850 ms (200 accessibility + 400 modifier wait + 200 ⌘C + 50 picker) |
| First streamed token, on-device | ≤ 1.5 s, without counting any prewarm gain (measured separately in P5-T4) | the generation timeout |
| Return → replacement visible | ≤ 400 ms | 2.3 s: key-up (400) + focus (600) + modifiers (400) + snapshot re-take when needed (300) + the extra wait for a timed-out read (300) + selection check and verify, raced against a 300 ms deadline |

Measured in P5-T4 with signposts (`QuillSignposts`; results and the export in
QA.md, "Performance"): every row measured so far is within budget — hot key →
picker 28–75 ms, first token in a rewrite 0.95–1.2 s (the bare model: 182 ms; the
rest is prompt composition and the pre-check's `tokenCount` calls), Return →
replacement 332–349 ms. The manual-accessibility and ⌘C-fallback rows wait for
owner-run apps (OS6) and for the keyboard (QA Q-03).
