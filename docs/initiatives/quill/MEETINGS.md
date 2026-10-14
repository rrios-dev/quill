# Quill — meeting transcription and synthesis

> Status: **shipped in Quill 1.1.0** (2026-10-14). Tried in real Teams calls in Spanish and
> English; the failures they found (§4.1, §4.2) are fixed and measured in
> `TESTING-MEETINGS.md`. Still open: S5 with the owner's voice (`Scripts/meetings-owner.sh`)
> and an hour-long run.

## 1. The job

The owner spends much of the week in video meetings on whatever the other side uses:
Teams, Google Meet, Zoom. Teams can record and summarise its own calls; Meet and Zoom
each have their own thing, or nothing. The job is **one tool for all of them**:

- listen to the meeting app the user picks, with one click;
- produce a realistic transcript, **per speaker**;
- keep **the transcript, never the audio**;
- synthesise it on demand with a **focus** (work, analysis, brief, or the user's own),
  fine-tuned the way Quill's rewrite profiles are, and re-synthesise later with another.

This is how Quill competes with Apple Intelligence integrated in the system: Apple has
no meeting transcription across third-party apps, and no user-defined focus.

## 2. Principles

| # | Principle | Why |
|---|---|---|
| M-01 | **Everything macOS offers, macOS does**; a third-party piece only where the system has no capability or no optimal result, and only with a measurement that proves it. | Owner's rule (2026-10-07). System frameworks cost nothing, need no download and are maintained by Apple. |
| M-02 | **Audio never touches the disk.** Blocks go to the on-device model and are dropped. The one exception is in memory: the others' channel is kept as 16 kHz mono samples until the meeting ends, for diarization, then handed over once and released. | The value is the transcript. Audio of other people is the liability. |
| M-03 | **Transcription is on the device.** Synthesis uses the provider the user chose, like a rewrite. | Raw speech of a meeting stays on the Mac; what leaves is the text the user decides to send, under the same consent as rewrites. |
| M-04 | **"Me" versus "the others" is exact; telling the others apart is approximate and says so.** | The first comes from hardware (microphone versus app output). The second is a model's guess, and the UI must let the user rename and correct it. |
| M-05 | **Everything lives inside Quill.** | Owner's decision: shared providers, keys, consent and fine-tuning; one app to install. |

## 3. Architecture

| Package | Role | Depends on |
|---|---|---|
| `ListenKit` | Capture (process tap of the meeting app, microphone), on-device transcription per channel, the `Transcript` model, word-to-speaker assignment. | Apple frameworks only. |
| `SpeakerKit` | Diarization of the others' channel. | `ListenKit`, **FluidAudio** (the only third-party dependency). |
| `SynthesisKit` | Focuses (built-in: work, analysis, brief; user-made next), shared rules every focus inherits, chunking at speaker turns for short contexts, synthesis through `ModelKit`. | `ModelKit`. |

### 3.1 What macOS does, what it does not (checked in the macOS 27 SDK)

| Need | macOS | Used |
|---|---|---|
| Capture one app's audio, no driver | **Yes**: Core Audio process taps (`AudioHardwareCreateProcessTap`). macOS 26 adds taps **by bundle ID** with `processRestoreEnabled`, for helpers that restart mid-call. | ✅ |
| Permission | "System Audio Recording" (`NSAudioCaptureUsageDescription`); the microphone (`NSMicrophoneUsageDescription` + the `audio-input` entitlement under the Hardened Runtime). | ✅ |
| Long-form transcription, on device | **Yes**: `SpeechTranscriber` with per-word `audioTimeRange`. Spanish installed (`es_ES`, `es_MX`, `es_US`, `es_CL`). | ✅ |
| Echo cancellation for the microphone | **Yes**: voice processing on the input node. | ✅ (to measure, S5) |
| Voice activity detection | **Yes**: `SpeechDetector`. | If needed |
| **Speaker diarization** | **No.** `Speech` exposes `SpeechTranscriber`, `DictationTranscriber`, `SpeechDetector`; no speaker API anywhere in the SDK. | FluidAudio |
| Synthesis on device | Foundation Models; small context, and measured worse on macOS 27 for rewrites. | Optional, chunked |

### 3.2 FluidAudio, and what it costs

- Apache 2.0. Offline pipeline: pyannote community-1 segmentation and embeddings, VBx
  clustering, on the Neural Engine. Its own benchmark: **10.6% DER** on an AMI subset,
  equal to the PyTorch reference. Streaming variants are "substantially worse" by its
  own account, so Quill diarizes **once, at the end**.
- Models: **21 MB**, downloaded once from huggingface.co/FluidInference; first load 31 s
  including download and compilation.
- The package pulls a 87 MB prebuilt binary (`NemoTextProcessing`) for features Quill
  does not use. Its effect on the shipped app size is **to measure before release**.

## 4. Measured so far

Test material: a synthetic Spanish meeting, two voices (Mónica, es_ES; Paulina, es_MX),
four alternating turns, 38 s, played by `afplay` and captured with the tap **muted**, so
the test is silent. The robotic "Eloquence" voices (Eddy, Flo…) are not usable as test
material: they produce garbage transcripts that measure the voice, not the model.

| Spike | Result |
|---|---|
| **S1** capture + transcription | Tap of another process works from the app bundle. **4.1% WER** (3 of 74 words: "se carga" for "se encarga", "que" for "queda", "10" for "diez"). Session start 0.2 s with the model warm. |
| **S2** diarization | **2 speakers found without being told; 4 of 4 turns attributed.** 44 s separated in 2 s. The transcriber cuts at pauses, not at speaker changes (it put both voices in one segment); per-word timings split them back. |

**S3 — synthesis**, on `tools/QuillBench/data/synthesis/meeting-1.txt` (five people, six
minutes, Spanish) against its ground truth (`meeting-1.facts.json`: 5 decisions, 6
owned actions, 2 disagreements, 3 risks, 3 traps). Focus "work":

| Model | Decisions | Actions with owner and date | Disagreements | Invented | Cost | Time |
|---|---|---|---|---|---|---|
| Claude Sonnet 5.5 | 5/5 | **6/6, exact** | **2/2** | 0 | 0.018 $ | 8 s |
| GPT-6 Luna | 5/5 (merged) | 6/6 | 1/2 | 0 | **0.0008 $** | 68 s |
| Gemini 3.8 Flash | 5/5 | cut off (`length`) | — | — | 0.009 $ | 20 s |
| Apple on-device (4,096 tokens, 3 chunks) | 5/5 with repeats | 3/6 right, 1 wrong owner, 1 invented date ("15 de marzo") | 0/2 | 2 | 0 $ | 54 s |

Findings:
- **The on-device model is not fit for minutes** (M-01 applies: the system does not
  give an optimal result here). Wrong owner and an invented date are exactly the errors
  minutes cannot have. It stays available, labelled as a draft, never the default.
- **Reasoning models need room**: Gemini spent the 2,000-token allowance thinking and
  was cut mid-table; Sonnet's analysis hit the same ceiling. The allowance is now 8,000,
  and a `length` answer must never be shown as a finished synthesis.
- Recommended default: GPT-6 Luna for cost, Claude Sonnet 5.5 for fidelity; the user
  picks, as for rewrites. Spent 0.069 $ (estimated < 0.05 $; the overrun was the
  truncated reasoning outputs).

### 4.1 First real call: two people saved as one (2026-10-08)

A Teams call, the owner and a colleague, on AirPods. The meeting was saved with twelve
segments, all "Yo", all within the first 2 min 18 s of a 37-minute call — so the
diarizer never ran, because there was no "Los demás" to split. The voices had nothing
to do with it: **both captures had died, silently.** Reproduced with the recorded
meeting and the AirPods, then instrumented:

| Run | Others | Me |
|---|---|---|
| Tap only, no microphone | 44 s | — |
| Tap + AirPods microphone | **0 s** | **0 s** |
| Tap built on its own clock (no output device in the aggregate) | 47 s | 0 s, `buffers=0 running=false` |

Two causes, both a device changing under a running capture:

1. **Opening the AirPods microphone switches them to their call profile** (48 kHz
   output becomes a 24 kHz headset). The tap's aggregate device was clocked on the
   output device, which disappeared and took the tap with it. Fixed: the aggregate holds
   only the tap and runs on its own clock (`ProcessTap(tapOnly:)`), so it no longer
   depends on what the output device is.
2. **`AVAudioEngine` stops on a configuration change without an error.** `start()`
   returned fine and no block ever arrived; in the real call, Teams joining the call
   did the same at 2 min 18 s. Fixed: `MicrophoneCapture` rebuilds itself on
   `AVAudioEngineConfigurationChange`.

And because the next device change will be one nobody has seen yet, a **watchdog**
(`ListenSession`) checks every two seconds that each capture still delivers — a
running capture delivers silence too, so nothing for three seconds is a dead capture,
never a quiet meeting. A dead one is rebuilt, the gap is filled with silence so "Yo"
and "Los demás" stay aligned (both channels are timed by what they were fed), and the
live panel says "Se ha perdido el audio de Teams: reconectando…" instead of the meeting
quietly losing a side. The lesson: **a capture that fails must fail loudly**; a meeting
saved with half its people looks like a working feature.

### 4.2 Second call: everyone heard, the meeting turned down (2026-10-08)

With the capture fixed, the retest told the people apart — and the owner heard the call
drop to a very low volume in their AirPods for as long as Quill listened, back to
normal the moment it stopped. The cause is the echo cancellation on the microphone:
Apple's voice-processing unit **ducks every other app's audio while it runs**, and the
meeting is other audio. With headphones there is no echo to cancel (the microphone
cannot hear the meeting), so voice processing is now decided by where the sound goes
(`OutputRoute`): off for Bluetooth and the headphone jack, on for speakers, displays and
anything unknown, and then with ducking set to the minimum the system allows. It is
decided again on every restart, so unplugging the headphones mid-call switches it on.

## 5. Next spikes

| Spike | What | Needs the owner |
|---|---|---|
| **S3b** synthesis, long | A one-hour transcript (~15k tokens): does a hosted model keep 100% of owners and dates at that length? Gemini with the larger allowance. | No (cost asked first) |
| **S4** real apps | `QUILL_LISTEN=list` during a real Teams, Meet (Brave) and Zoom call: which processes play the audio, and whether a tap by bundle ID survives the call. | Yes: be in a call |
| **S5** microphone | The owner's own voice as "me", on headphones and on speakers: does echo cancellation keep the others out of "me"? | Yes: speak |
| **S6** a long meeting | One hour: memory of the kept samples, diarization time, transcript drift between channels. | Yes: a real or long test meeting |

## 6. Product flow

Mockups: the "Quill Reuniones" design canvas (owner review, 2026-10-07).

1. **Offer.** Quill notices a meeting app has the microphone open and offers
   "¿Transcribir esta reunión?": one click or ⌃⌥T. A visible indicator while it listens.
   Which apps count is `MeetingApp.known` (1.1.1: Teams, Zoom, Webex, Slack, FaceTime,
   GoTo, Gather, Discord, WhatsApp, Telegram, Signal and twelve browsers). An app outside
   the list never triggers the offer on its own, because the microphone is also opened by
   dictation and recording apps; "Transcribir una reunión" in the menu offers it instead,
   choosing an app that also plays audio (a call) before one that only records. Preferences
   saved before an app joined the list switch it on when they load (`knownApps`), and a
   new browser follows the browsers' switch.
2. **Live.** Optional panel: elapsed time, "Yo" versus "Los demás", Pause, Hide, Finish.
   People are told apart at the end, and the panel says so.
3. **The meeting window** (redesigned 2026-10-08, `qa/meetings-meeting*.png`). It
   was two steps — name the people, then synthesise — and the second step hid the
   transcript and the people: on the first real meeting the owner named everyone,
   pressed Continue and lost the meeting he was analysing, then read the analysis as a
   wall of Markdown. Now it is one window with three columns, none of them a step:
   - **People** (left): each voice with its colour, a name and a role edited in place
     (saved when the name is finished, never per keystroke), its share of the speaking
     time, how it counts for the chosen focus (click to change it for this meeting), and
     a button that filters the transcript to that person. A notice stays while a voice
     has no name, because tasks would be attributed to "Persona 2".
   - **Analysis** (centre): the meeting before any model — title, app, date, length, a
     timeline of who spoke when (a click scrolls the transcript there) and the share per
     person — then the focus, nuance and model, and the result drawn by kind
     (`SynthesisDocument` + `SynthesisView`): counts of decisions, tasks, risks and
     disagreements at the top; decisions with checks; tasks as owner chip, task and
     date (and "Sin fecha" made visible); risks and disagreements marked; an analysis as
     numbered topics with its options tables and "**Decisión:**"-style callouts; every
     participant's name in their colour. The prompt asks for the Markdown shape the
     reader understands; the text itself is never rewritten.
   - **Transcript** (right, an inspector that can be hidden): turns by person, with
     search and the person filter.
   Synthesise is ⌘↩, not ↩: Return finishes a name and must never send the meeting to a
   paid model.
4. **Focuses.** The rewrite picker's grammar: focus pills, a field for a one-off nuance,
   the model with its cost ("En este Mac" marked as a draft).
5. **History.** Its own window: search across transcripts and minutes, meetings by week,
   each with its people, several syntheses and the transcript.
6. **Settings › Meetings.** Apps to offer in, shortcut, microphone, language (with the
   model's state), diarization, default focus and model, retention, the role catalogue.

## 7. Roles and weight in the synthesis

A meeting is not flat: what the Product Owner settles is a decision, what support adds
is operational context, what an external party asks for is a request. How much each
counts depends on **what the synthesis is for**: minutes for the product team weigh the
Product Owner most; an analysis of support load weighs support most.

### 7.1 Concepts

| Concept | What it is | Where it lives |
|---|---|---|
| **Role** | A named function in meetings: Product Owner, Tech Lead, Soporte, Cliente, Proveedor… User-defined, with a one-line description of what that function is responsible for. | Settings › Meetings › Roles (a catalogue, like profiles). |
| **Person** | A name heard in meetings, with a **default role**. Remembered locally by name, so naming Lucía once makes her Tech Lead in every later meeting. | The meetings store, deletable with the history. |
| **Treatment** | How a role counts in a synthesis. A closed set, so the prompt and the tests can rely on it (below). | Per focus. |
| **Focus** | Objective + guidance (§ SynthesisKit) **+ a role → treatment table**. "Acta de producto": Product Owner *decides*, Tech Lead *decides* on technical matters, Soporte is *context*, Cliente is a *request*. | Focus editor. |
| **Meeting override** | For one meeting: a person's role (Diego was acting as Product Owner today) or a role's treatment (support decides in this incident review). | The participants strip of the synthesis screen; stored with that synthesis. |

### 7.2 Treatments (closed set)

| Treatment | Effect on the synthesis |
|---|---|
| **Decide** | What this role settles or accepts is a **decision**. A proposal from anyone else becomes a decision only when someone with *Decide* accepts it. |
| **Influye** | Proposals and objections are reported with their author and weight the reading; they do not settle anything alone. |
| **Contexto** | Summarised as supporting information (data, operational impact); never presented as a decision or a position to weigh. |
| **Petición** | An external party: what they ask for is recorded as a **request**, distinct from internal agreements. |
| **Mínimo** | Only when it changes a task, a date or a risk; otherwise left out of the synthesis (still in the transcript). |

A focus can scope *Decide* to a domain ("decide on technical matters") in free text; the
model applies it, and the tests check it on cases built for it.

### 7.3 Invariants (no role or focus overrides them)

- **Attribution is never weighted.** Who said and who committed to what is reported
  exactly, whatever their role. Weight changes prominence and what counts as a decision,
  never authorship.
- **Every commitment is listed.** A task accepted by a *Mínimo* person still appears in
  the tasks table: weight decides importance, not existence.
- **A risk is never dropped for low weight.** A risk raised by *Contexto* or *Mínimo*
  that threatens a decision is reported; the reading may rank it lower.
- **The synthesis says how it weighed.** A closing line lists the role map used
  ("Decide: Roberto, Andrés · Contexto: Marta…"), so a reader can tell a weighted
  reading from the transcript.
- Roles and names are data in the prompt, delimited like the transcript; a name or role
  description cannot carry instructions.

### 7.4 How it reaches the model

The prompt gains a **participants block** after the shared rules: one line per person
with name, role, the role's description and the treatment for this focus (after
overrides). The shared rules gain the treatment semantics of §7.2 and the invariants of
§7.3. The transcript is unchanged: roles are not injected into it.

### 7.5 Measuring it

`meeting-1.facts.json` gains roles (Roberto: Product Owner, decide; Lucía and Andrés:
Tech Lead, decide on technical matters; Marta: Soporte, context; Diego: Mobile, influye)
and **role-sensitive expectations**: Marta's preference to launch both platforms
together must appear as an objection, never as a decision; under a "support load" focus
it must lead the reading. Two focuses × the recommended models, scored like S3.

## 8. Open questions

- Q-M1: does the history live in Quill's data folder, with the same reset and export
  rules as profiles? (Proposed: yes.)
- Q-M2: a meeting in two languages: one locale per session today. Detect and switch, or
  let the user pick?
- Q-M3: the landing page: Quill stops being "only rewriting". Rewrite it when the feature
  is real.
- Q-M4: suggest a person's role from what they say ("desde soporte os digo…")? Useful on
  first meetings; only ever a suggestion the user confirms.
