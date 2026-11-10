# Quill — efficiency, live text, dictionary and identity

The owner's request (2026-11-10): transcription as fast as it can be, a light app,
per-person dictionaries that can be created and that identify people correctly, a
finish that reads as a professional product. Decision J-15 (JOURNAL.md): build all of
it, new functions included.

## In short

Quill is light at rest and heavy in a long meeting. The transcriber itself is not the
bottleneck: what costs is separating voices again and again over everything heard, and
what feels slow is that the live text waits for finished sentences. The per-person
dictionary works but has never been used on the owner's Mac, cannot be written by hand
and rewrites text blindly. People are still linked by name when a name is typed.

## Measured (2026-11-10, release build, this Mac)

| What | Result | How |
|---|---|---|
| Installed 1.4.1 at rest | 33 MB resident, 0 % CPU, 36 MB on disk | `ps`, `du` |
| Transcription + separation of a 10 min case | 11 s (c2-es) | `meeting-bench run` |
| Separating one hour of audio, one pass | 19 s | `meeting-bench incremental` on a 60 min case (c3-ami looped) |
| All 30 live passes of that hour | 322 s wall, 295 s CPU | same run |
| Peak memory of that run | 1.27 GB | `/usr/bin/time -l`; the audio is 230 MB, a pass copies it, the pipeline holds the rest |
| Measuring one sentence's voiceprint | ~60 ms (2.1 s for 36) | VOICES.md S1 |
| Sentences the separation leaves whole | 30 of 89 (c2-es), 18 of 36 (c4-similar) | `meeting-bench run`, the new note |
| The owner's history | 11 meetings, 5 MB, largest 1.3 MB | file sizes only |
| The owner's dictionary | no entry: `vocabulary.json` does not exist | file listing |

Not measured: the delay of the live text, and the app's own memory and CPU during a
real call (the bench runs no transcriber next to the passes). The hour is synthetic.

## Findings

1. **Live text waits for the end of each sentence.** `ChannelTranscriber` asks for
   final results only (`reportingOptions: []`). The macOS 26 SDK offers
   `.volatileResults` and `.fastResults`; neither is used.
2. **The end of a meeting measured every sentence one by one, on the main thread**,
   after loading models the live passes had already loaded. Fixed in E1.
3. **Every live pass separates the whole meeting again** and copies its audio: the
   cost grows with the square of the length, and the pipeline's memory with the length.
4. **The history decodes every meeting** to list, search or learn voices at launch.
5. **People are linked by name** when a name is typed (`MeetingStore.remember(name:)`):
   two people with one name become one person, against J-02.
6. **The dictionary rewrites text and keeps no original.** Forgetting an entry undoes
   nothing; a correction on an unnamed voice becomes global for good; nothing guards a
   common word; the live panel does not apply it; entries cannot be written or edited
   by hand, only forgotten. The S4 tie-breaker (vocabulary in recognition) was not built.
7. **Recognition thresholds rest on three meetings and eleven voices**; the live panel
   still names a voice by its mean print.

## Slices

| Slice | Builds | Done when (machine-checked) | Stop |
|---|---|---|---|
| E1 | End of meeting: reuse the loaded models, measure sentences while they are heard (`SentencePrints`), measure the rest off the main thread, log both times | Tests; bench gate green; the log line reports seconds and reuse | — |
| E2 | Live passes that do not redo everything: longer intervals as the meeting grows or a window with the labeler's evidence; audio kept as 16-bit | 60 min case: CPU of the passes and peak memory, before and after; naming accuracy of `incremental` not worse | — |
| E3 | History index: summaries and search text beside the meetings, rebuilt when missing | Store tests; listing 200 synthetic meetings timed before and after | — |
| E4 | Identity by id when a name collides (pick or create); dictionary that keeps the original text, holds an unnamed voice's corrections until it has a person, and asks before a common word | Migration and store tests; a forgotten entry restores the text | ✋ owner tries a real meeting |
| E5 | Live text while people speak (`.volatileResults`, `.fastResults` measured against final-only on WER), dictionary applied in the live panel | Bench: WER not worse than today's gate; latency to first text measured | ✋ owner tries a real meeting |
| E6 | Dictionary by person in Settings: grouped by owner, add and edit by hand | Store tests; screenshots of the section (built directly: the owner asked for every slice in one run) | ✋ owner judges the screenshots |
| E8 | Dictate and rewrite (J-17): a second shortcut, Ámbar's engine (VoiceKit) in Quill, Ámbar's dictation dictionary when installed, the picker on what was said, the result where the cursor is | VoiceKit tests for the moved dictionary and corrector (Ámbar's suites green); Quill's dictation on real Spanish audio from a file; the whole path in the debug app with a screenshot | ✋ owner dictates for real |
| E7 | Meetings driven from an agent (J-16): list the apps in a call, start, follow, stop or wait for the end, then transcript and synthesis | Tool tests; an end-to-end run through `quill-mcp` against the debug app with a bench meeting, scored like T3 | ✋ owner tries it from Claude in a real call |

## Results

### E1 — the end of a meeting (2026-11-10)

- The final pass and the sentence measuring reuse the separator and embedder the live
  passes loaded; a meeting stopped before they loaded loads them as before.
- Each of the others' sentences is measured when it is heard, one at a time, at
  utility priority, on its own stretch of audio (`AudioAccumulator.copy(from:to:)`).
  At the end, a sentence the separation left whole keeps that print; the rest are
  measured then, off the main thread (it ran on it before, with the window frozen).
- On the bench 34 % (c2-es) and 50 % (c4-similar) of the measurable sentences are
  left whole. Both cases change speaker every few seconds; a real meeting's share is
  read from the log: `separation: … voiceprints: …, N of M measured during the meeting`.
- `meeting-bench run --gate` green on c2-es, c3-ami and c4-similar; `swift test` green.
- Not verified: a real meeting on the installed app (nothing was installed).

### E2 — long meetings (2026-11-10)

- Live passes wait 15 times what the last one took (`LivePassSchedule`): two minutes
  while a pass is cheap, ten at most. The others' audio is kept as 16-bit samples.
- `meeting-bench live c3-ami --minutes 60` (the case looped to an hour, fed block by
  block into the app's accumulator, a pass when the schedule says):

  | Rhythm | Live passes | CPU of the passes | Share of the hour | Final pass | Right at the end | Peak memory |
  |---|---|---|---|---|---|---|
  | Every 2 min (1.4.1) | 30 | 329 s | 9.1 % | 18.6 s | 83.2 % | 1.47 GB |
  | Adaptive | 24 | 231 s | 6.4 % | 19.4 s | 83.2 % | 1.48 GB |

- 30 % less CPU, the same naming accuracy pass by pass; the first 30 minutes are
  unchanged (a pass costs under 8 s there). The schedule starts spacing at minute 28.
- Peak memory did not move: it is the diarizer's own working set on an hour of audio,
  not the kept samples (230 → 115 MB, under the noise). Lowering it means separating a
  window instead of the whole meeting, which changes naming; left for a measured slice.
- The bench found its own bug on the way: summing tenths of a second never reached the
  end of the hour and the last block was empty forever (fixed: counted in samples).

### E3 — the history (2026-11-10)

`index.json` beside the meetings holds each one's summary, folded search text and the
people named in it, stamped with the file's size and date: a meeting written by another
process (the agent server, an older Quill) is indexed again, one file, on the next read.
`learnVoicesFromHistory` at launch reads only meetings with a person not learnt yet.

`meeting-bench history --meetings 200` (200 one-hour meetings, 164 MB, index 12 MB):

| Read | Time |
|---|---|
| Every meeting decoded (1.4.1's list, search and launch) | 1,058 ms |
| List, index built from the files (first launch after the update) | 1,223 ms, once |
| List, index present (a new process: the app or the agent server) | 32 ms |
| Search, index present | 35 ms |
| Search again in the open history window | 4 ms |

The history window now holds summaries and reads only the selected meeting; the agent
tools decode only the meetings they return.

### E5 — live text (2026-11-10)

`meeting-bench latency c2-es --seconds 90`: the others' track fed at the pace a meeting
plays it, each word of the finished transcript timed from the end of its audio to the
first result, draft or final, that showed it.

| Reporting | Median | p90 |
|---|---|---|
| Finished sentences only (1.4.1) | 10.6 s | 16.4 s |
| Drafts | 4.5 s | 9.8 s |
| Drafts, fast | **0.4 s** | **0.8 s** |

What fast costs the finished transcript (`BENCH_REPORTING`, `meeting-bench run --gate`):

| Case | Others WER none / drafts / fast | Me WER none / fast |
|---|---|---|
| c2-es | 3.5 / 3.4 / 3.4 % | 7.2 / 8.9 % |
| c2-es-noise | 4.1 / 4.1 / 4.2 % | 7.2 / 8.9 % |
| c4-similar | 3.1 / 3.8 / 4.0 % | 8.7 / 10.3 % |

All inside the gate. Quill now listens with fast drafts: the live panel shows a sentence
being said, lighter, replaced when it finishes, with the vocabulary of whoever says it.
Logged as a delegated decision `[a revisar]` (C-13): the owner asked for speed; about a
point of WER on the user's own words is the price.

### E4 — people by id, a dictionary that can be taken back (2026-11-10)

- **People.** A typed name resolves with the voice (`MeetingStore.match`): nobody by that
  name → a new person; one person whose samples do not contradict the voice → them; two
  people with the name, or one whose voice is clearly someone else (below 0.6) → the row
  asks "¿Quién es?" with each person (name · role) and "Otra persona". The row keeps the
  person's id once chosen or once a proposal is accepted; renaming unties it. Two voices
  merge only when they are the same person, not the same name. Live names carry the id of
  an accepted proposal into the saved meeting.
- **Dictionary.** A sentence keeps what the transcriber wrote (`heard`) and is always
  written from it, so forgetting or editing a word rewrites the saved meetings that hold
  it, found through the index; a sentence rewritten by hand (`edited`) is left alone.
  Word timings are kept. A correction to an unnamed voice waits on that voice
  (`.voice(meeting, label)`) and moves to its person when it is named; deleting the
  meeting drops it. A single ordinary word of the language (`NSSpellChecker`: "vale" for
  "Valle") is not learnt unless the user presses "Aprenderla igualmente".
- Tests: `PeopleByIDTests`, `ReversibleVocabularyTests`, the index suites; every suite of
  `swift test` green.
- Not verified: a real meeting with two people of the same name (✋).

### E6 — the vocabulary in Settings (2026-11-10)

Settings › Meetings › Vocabulary opens with the whole ("12 palabras que Quill escribe a tu
manera: 3 · Para todos, 4 · Lo que dices tú, 5 · Fran"), then a group per owner — everybody,
the user, each person (with role when two share a name), forgotten people, unnamed voices
— each word with its count, edit and delete. "Añadir palabra…" asks what Quill hears, how
it is written and who says it; saving rewrites the saved meetings that contain it.
New strings pass `copy-audit --profile tool --strict` in both languages.

### E7 — a meeting driven from Claude (2026-11-10, J-16)

`quill-mcp` gains five tools, each handed to the running app over its socket:
`list_meeting_apps`, `start_listening(app_id?, language?, stop_when_call_ends?)`,
`get_listening_status(lines?)`, `stop_listening`, `wait_for_meeting(seconds?)`. With them
an agent goes from "transcribe this call" to the saved meeting's id, then
`get_transcript` and `synthesize_meeting` as before. `stop_when_call_ends` stops and saves
when the app has let go of the microphone for 20 s. The live panel shows whoever started
it; agent access stays off until the user turns it on (mac-apps-mcp DESIGN, updated).

`Scripts/meetings-agent.sh c4-similar`: a stand-in meeting app (`MeetingPlayer.app`,
its own bundle id, as Teams has) plays the case; the debug Quill on a scratch folder
transcribes it, muted, without the microphone; `meetings-agent.py` talks to `quill-mcp`
over stdio exactly as Claude Code does.

| Check | Result |
|---|---|
| The 13 tools listed; idle state read | ✓ |
| `start_listening` on the app by id; a second start refused | ✓ |
| Live lines through `get_listening_status` | first finished line 16.6 s after playing began (3 s of it silence) |
| Sentence being said shown | 101 of 139 status reads |
| `stop_listening` | 3.3 s to separate the voices and save a 4.5-minute meeting |
| `wait_for_meeting`, `get_transcript`, `list_meetings` on the saved id | ✓ |
| The saved meeting against the case | others WER 3.8 % (gate 5 %), words to the right person 72.2 % (gate 72 %), at the right moment 97.9 % (gate 95 %) — 12/12 tool checks |

The DER of a saved meeting is not comparable with the gate's (the meeting keeps
sentences, not the diarizer's turns), so the script scores without `--gate`.
`Scripts/mcp-audit.py` (the owner's installed Quill) now expects 13 tools.

Screenshots of the new surfaces, from the debug build (`MeetingSnapshots`):
[live panel with a sentence being said](qa/meetings-live.png),
[an ordinary word held back](qa/meetings-meeting.png),
[two people called Fran](qa/meetings-people-choose.png),
[the vocabulary by owner](qa/meetings-vocabulary.png).

### E8 — dictate and rewrite (2026-11-10, J-17)

- **⌃⌥D** (Settings → General, next to the rewrite shortcut) opens a panel that never
  takes focus: "Escuchando", the words as they are said with the ones the engine may
  still change lighter, "⌃⌥D otra vez para reescribirlo" and Cancelar. The second press
  finishes (at most 4 s), and the text goes through the picker as a Services capture of
  the app that was in front when dictation began (`Trigger.dictated`): profiles, direct
  apply where the app has it, the result pasted where the cursor is.
- The engine is Ámbar's `SpeechSession` (VoiceKit) in Quill's process, so it works without
  Ámbar. With Ámbar installed, `~/Library/Application Support/Ambar/dictionary.json`
  biases the engine (contextual strings) and corrects the text (its rules), live and at
  the end; the panel says "Diccionario de Ámbar".
- Harvest (C-27): `DictionaryEntry`, the file's reader and ranking (`DictationDictionary`)
  and `VocabularyCorrector` moved from Ámbar's app into VoiceKit; Ámbar uses them and
  deleted its copy; the corrector's tests moved with it and a file round-trip test was
  added. Ámbar's suites green (VoiceKit 123, Ámbar 285).
- Tests: `DictationRewriteTests` — a scripted engine (words live, Ámbar's correction,
  delivered to the app in front at the start, nothing delivered on silence or cancel,
  a missing model explained and retried, Quill never its own target) and **the real
  engine on a spoken Spanish sentence** read from a file, with a dictionary rule applied.
- In the debug app (`QUILL_DICTATE_RUN`, `QUILL_DICTATE_FILE`): a sentence spoken by the
  system's Spanish voice reached the picker word for word ("Oye, mañana revisamos el
  presupuesto con el equipo y te mando el resumen por la tarde");
  [listening](qa/dictation-listening.png), [the picker on it](qa/dictation-picker.png).
- New strings pass `copy-audit --profile tool --strict` in both languages.

**Revision after the owner's first try (J-18).**

- *Why the picker warned.* "No se pudo comprobar el formato y podría perderse" is guard
  G11 on a capture whose formatting is unknown: the dictated capture was built as a
  Services capture of the field, and the field's selection (empty) never matched the
  words said, so formatting stayed unknown and editability uncertain — hence "Revisa los
  avisos" and "Usar igualmente". Worse, at paste time the selection check compared the
  field with the words said and the result went to the clipboard
  (`copiedSelectionChanged`). Now the field is read when the keys go down
  (`DictationTarget.locate`: element, selection, editability, cursor rectangle), the
  capture says what the field had selected (`Capture.fieldSelection`, used by the
  selection check) and carries `.plain` formatting: no warning, and the words are inserted
  at the cursor. A replace test covers the insertion and the old failure.
- *One shortcut.* ⌃⌥D is gone. ⌃⌥R released before 450 ms rewrites the selection as
  always; held past it, the microphone opens (the model loads from the moment the keys go
  down, without the microphone); letting go after ≥ 0.9 s of listening finishes (push to
  talk), letting go sooner keeps listening hands-free until the next press
  (`ShortcutGesture`, four tests). The menu's "Dictar y reescribir" starts hands-free.
- *The panel.* A glass capsule (`DictationPanelController`) just below the cursor — or low
  in the middle of the screen when the app reports no cursor — with a five-bar voice
  meter driven by the microphone's level (new `SpeechSession.setLevelHandler` and
  `AudioLevel` in VoiceKit), the newest two lines of what is said (older words leave by
  the start, provisional ones a step lighter), and one line: "Suelta para reescribir"
  while held, "⌃⌥R para terminar" hands-free. It fades in and out and follows its content;
  Reduce Motion turns the meter and the fades off. The picker then opens at the same
  cursor.
- Checked: the real engine moves the meter (level above 0.3 on a spoken sentence); in
  the debug app over a TextEdit document, the cursor was found, the capsule showed beside
  it and the sentence reached the picker whole ([capsule](qa/dictation-listening.png),
  [picker](qa/dictation-picker.png)). Quill 622, VoiceKit 124, Ámbar 285 tests green.

**Second revision (the owner: "una ventana central como entrecortada, rara").** Seen on
the owner's portrait screen over the Claude app, whose composer reports no cursor: the
five meter bars at rest read as a dotted, broken line; the window grew and shrank as the
words reached a second line (a refit every 120 ms); and with no cursor it sat low in the
middle of the screen while the picker opened somewhere else. Now: one line at a fixed
46 pt, a true capsule (radius = half the height), the words truncated at the start so the
newest stay in view, a filled microphone circle whose halo swells with the voice (no dots;
still with Reduce Motion), and a short tag ("Suelta" while held, "⌃⌥R" hands-free). The
field's frame is read too (`AXFrame`, `SelectionOperations.frame`), so in apps that report
a field but not its cursor the capsule sits just above the field and the picker opens at
the same place. Checked in screen context over TextEdit and the Claude app
([capsule](qa/dictation-listening.png)); Quill 622, VoiceKit 124, Ámbar 285 tests green.

**Third revision (J-19).** Push to talk is gone: holding the shortcut past the
threshold starts dictation, letting go never stops it, and the next press of the
shortcut finishes and sends the words to the picker (`ShortcutGesture`, its tests
rewritten). The shortcut is whatever the user recorded in Settings → General: it is
registered with its press and its release (a test records a custom ⇧⌘E and checks
both reach Quill), and the capsule's tag, the menu and Settings name that combination.
Checked in the debug app over TextEdit: held, released, still listening, pressed again,
the sentence reached the picker whole.

## Still open

- ✋ The owner's trial on a real call: live text speed, the person choice, the vocabulary
  in Settings, and a meeting started and synthesised from Claude (E4–E7); dictating for
  real with ⌃⌥D into Mail or Teams (E8).
- Memory of an hour-long meeting (1.47 GB peak, the diarizer's): a windowed separation,
  measured against naming accuracy.
- Installed over `/Applications/Quill.app` on 2026-11-10 for the owner's trial (by J-05,
  the owner's "Sí, instálala"): release build of commit 725653684, same team signature,
  still reading 1.4.1; the 1.4.1 bundle is kept in `native/quill/build/rollback-2026-11-10/`
  of the main checkout. Checked after installing: the app runs, the installed `quill-mcp`
  lists 13 tools and answers `get_listening_status`, `list_meeting_apps` and
  `list_meetings` on the owner's data. Not published.
- Installed again on 2026-11-10 with E8 (commit d582251c6, the owner's "Sí, instálala"):
  no shortcut error logged at launch, so ⌃⌥D registered; the MCP still answers; Ámbar's
  dictionary is present for the panel to use. The E1–E7 build is kept beside the 1.4.1
  one in `native/quill/build/rollback-2026-11-10/`.
- Installed again on 2026-11-10 with the J-18 revision (commit c240beb90, the owner's
  "Sí, instálala"): no shortcut error at launch, the MCP answers. The ⌃⌥D build is kept
  as `Quill-E8-ctrl-opt-D.app` beside the others.
- Installed again on 2026-11-10 with the steady capsule (commit 2a7e122c2): no shortcut
  error at launch, the MCP answers; the previous build is kept as
  `Quill-J18-hold-first.app`.
- Installed again on 2026-11-10 with J-19 (commit b97549d08): no shortcut error at
  launch, the MCP answers; the previous build is kept as `Quill-J18-steady-capsule.app`.
