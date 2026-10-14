# Quill meetings — test audit and plan

> Audit 2026-10-08, after the first two real calls. Owner's brief: test the feature in
> a way that is **verifiable** (a number against a known answer, not "it looked fine")
> and **realistic** (real voices, real devices, real failure modes).

## 1. What the suite tests today

36 tests across `ListenKitTests`, `SynthesisKitTests` and `MeetingKitTests`, all green.

| Area | Tests | What they exercise |
|---|---|---|
| Speaker assignment | 6 | Splitting segments at hand-written turn boundaries |
| Stall check, output route | 7 | The watchdog's arithmetic, the route table |
| Roles, prompt, chunking | 9 | Prompt text and transcript chunks |
| Synthesis document | 5 | Parsing three model outputs from S3 |
| Store, apps | 9 | JSON round-trips, retention, search, people, which app is in a call |

**Every one of them is pure logic over inputs written by hand.** None touches audio,
the speech model, the diarizer, a device, the coordinator or the window's model.

## 2. Findings

1. **The suite was green while the feature was broken.** The first real call saved two
   people as one (both captures dead) and the second turned the call down to a whisper
   (voice-processing ducking). Both bugs lived in code no test reaches: `ProcessTap`,
   `MicrophoneCapture`, `ListenSession`. A suite that cannot fail for the failures that
   happen is measuring the wrong thing.
2. **The quality numbers are one-offs.** S1 (4.1 % WER) and S2 (2/2 voices) were measured
   once, by hand, on 38 s of two synthetic voices taking clean turns: no overlap, no
   noise, no interruptions, no quiet speaker, no device change, never longer than a
   minute. Nothing re-measures them, and nothing would notice if an OS update or a
   FluidAudio bump made them worse.
3. **The branch that silently skipped diarization is untested.** `finish()` separates
   voices only if the others' channel has segments and samples; with a dead capture it
   skipped without a word. No test covers the coordinator.
4. **Untested and load-bearing:** `ChannelTranscriber` (format conversion, timestamps,
   `padSilence` alignment between channels), `AudioAccumulator`, `SpeakerSeparator`,
   `Transcript.rendered()` (the synthesis input), `MeetingFlowModel.commitPeople` (the
   double-counting fixed today), `OutputRoute.current()` on real hardware.
5. **What is good and stays:** the prompt-injection test on participant names, the
   chunking invariant (no lost or split turns), the parser tests built from real model
   outputs.

## 3. The plan: five tiers, each with a number to beat

| Tier | Runs where | Needs | Measures |
|---|---|---|---|
| **T1** unit gaps | CI, any Mac | nothing | The load-bearing code of finding 4, with real AVAudio buffers |
| **T2** meeting bench, offline | This Mac | speech model + diarizer models, corpus | WER, DER, speaker-attributed WER, speaker count, turn drift |
| **T3** live capture | This Mac, silent | corpus; the screen untouched | The real tap under steady play, a device switch mid-call, the app restarting, an hour of audio |
| **T4** owner protocol | A person | 10 minutes of the owner | The microphone: "me" WER, others leaking into "me", headphones vs speakers |
| **T5** synthesis | Paid | a budget | Decisions, owners and dates against ground truth, and that each answer parses into the window's sections |

### T2 corpus — real voices with a known answer

| Case | Audio | Why |
|---|---|---|
| **C1** synthetic | Mónica + Paulina (`say`), the S1 script | Smoke test; fast |
| **C2** Spanish, real voices | Five real speakers from OpenSLR 61/71–75 (crowdsourced Latin-American Spanish, CC BY-SA 4.0), composed into an eight-minute meeting from the bench's meeting script: mixed genders and accents, pauses, interruptions and short overlaps, one quiet speaker, and a variant with background noise | Real timbres, so diarization is tested on what it will meet; the composition keeps the exact text and speaker of every second |
| **C3** a real meeting | AMI ES2004a (English, CC BY 4.0): four people in a room, unscripted, with real overlap and reference annotations | The only case nobody arranged: the honest upper bound of difficulty |

The bench writes a JSON report per case and compares it with a locked gate, as
QuillBench already does for rewrites: the first run calibrates, later runs must not be
worse.

### T3 scenarios

1. Steady: the C2 meeting played and captured through the real tap (muted). Others'
   seconds ≥ 98 % of the audio, and WER within 2 points of the offline run — proof that
   capture does not degrade the transcript.
2. Device switch: the default output is changed mid-meeting. Must recover within 5 s,
   with silence padded and the channels still aligned.
3. Restart: the playing process is killed and a new one starts.
4. Long: an hour of audio — memory of the kept samples, diarization time, drift.

## 4. Results so far (2026-10-08)

### T2 — the meeting bench (`tools/MeetingBench`, `meeting-bench run --gate`)

Corpus in `~/Library/Caches/QuillMeetingBench` (outside the repo: other people's voices
under their own licences), fetched by `fetch_corpus.py` (≈ 63 MB of clips read from the
OpenSLR ZIPs by range, not the 4 GB of ZIPs) and `fetch_ami.py` (≈ 32 MB).

| Case | Audio | Others WER | Me WER | DER | Voices | Words to the right person | Words at the right moment |
|---|---|---|---|---|---|---|---|
| C2 `c2-es` | 10 min, 5 real voices + me | 3.4 % | 7.2 % | 15.8 % | 5 of 5 | 89.6 % | 97.5 % |
| C2 `c2-es-noise` | same, noise at 15 dB SNR | 4.1 % | 7.2 % | 12.0 % | 5 of 5 | 94.6 % | 97.6 % |
| C3 `c3-ami` | 17.5 min, real meeting (English) | not measured¹ | — | 23.9 % | 4 of 4 | — | — |

¹ The English speech model is not installed on this Mac; the case scores the voices only.
Its DER is mostly missed overlapped speech (20.3 %; confusion 1.7 %), in line with what
is published for this diarizer on AMI — which is also the check that the metric code
measures what it says.

A 10-minute meeting is processed in about 12 s.

**What the bench found on its first day:**

1. *The reference has to say where the voice is.* Read speech carries long pauses (in two
   of the five volunteers, more than half of each clip is silence). Scored as speech,
   they showed a 33 % "missed" rate that was the reference's error, not the diarizer's.
   The C2 reference now marks voiced regions per sentence, as forced alignment would.
2. *The diarizer invents people at interruptions.* Five real voices came out as seven;
   the two extra held 5–7 s each, almost all of it overlap. Voiceprints cannot assign
   them (two different real women were more alike, 0.55, than either ghost to its
   source). `SpeakerTurn.absorbingMinorVoices` folds a voice that is both under 5 % of the
   speech and under 15 s into the voice it overlaps, or the nearest: 7 → 5 voices,
   DER 16.2 → 15.8 %, and no change on the noisy case or AMI. Adopted in the product.
   (First set at 2.5 %; the live capture, T3 below, produced a 13 s ghost at 4.2 %
   holding a little of all five people, so the share went to 5 %. The 15 s cap is what
   protects a real person in a long meeting.)
3. *Quiet speakers lose words, not identity.* The speaker composed 10 dB quieter keeps
   their own cluster; their misses are the largest per-person share.

`gate.json` locks the first run plus a margin; `--gate` exits 1 when a case gets worse
(checked by running it against an impossible limit).

### T3 — live capture (`Scripts/meetings-live.sh`)

The C2 meeting played by `afplay` (with 3 s of silence in front) and captured through
Quill's real process tap, muted, from the debug app; scored by `meeting-bench score`
with the same numbers, after finding the start offset that lines the voices up.

| Run | Captured | Others WER | DER | Voices | Words to the right person | Words at the right moment | Tap rebuilds |
|---|---|---|---|---|---|---|---|
| Steady | 100 % | 3.6 % | 18.5 % | 5 of 5 | 86.8 % | 97.3 % | 0 |
| Capture killed at 4:00 | 100 % | 4.4 % | 19.5 % | 5 of 5 | 86.6 % | 97.4 % | 1 |

- **Capture does not degrade the words** (3.6 % live vs 3.4 % offline) and costs the
  voices a little (DER 18.5 % vs 15.8 %).
- **Recovery works end to end.** The killed capture was noticed and rebuilt by the
  watchdog; the words after it are still placed at the right moment (97.4 %), which is
  the silence padding doing its job — without it everything after 4:00 would shift. The
  price is the few seconds before the rebuild (WER +0.8 points).
- Both runs were captured with the 2.5 % rule and rescored with the 5 % one (the scorer
  applies the product's current rule); the probe now uses 5 % too.
- "Captured" counts padded silence, so it reads 100 % even after a loss; the rebuild
  count is what shows the loss.

### Live naming — `meeting-bench incremental <case>`

Diarization passes every two minutes over what was heard so far, labelled by
`SpeakerLabeler`, scored as the share of each pass's speech whose label points at the
person the final pass gives it (a name given at minute 2 must still be right at the end).

| Case | 2 min | 4 min | 6 min | 8 min | end |
|---|---|---|---|---|---|
| C2 `c2-es` | 81 % | 74 % | 76 % | 90 % | 91 % |
| C2 noise | 75 % | 79 % | 79 % | 95 % | 95 % |
| C3 AMI | 87 % | 94 % | 91 % | 88 % | 83 % |

A pass costs 1–7 s on a 10–17 minute meeting. Found while measuring: the two similar
voices of C2 stay merged until minute 8, and the one that splits off gets a new number
— it had no evidence of its own before, so no labelling can do better; the live panel
lets every name be corrected, and so does the meeting window.

### T1 — added

Real `AVAudioPCMBuffer`s through `AudioAccumulator` padding; the transcript the
synthesis reads (`rendered()`, two channels finishing out of order); the minor-voice
rule; the metric definitions themselves (WER, Hungarian mapping, DER with overlap);
`MeetingRecord.silentChannels` and decoding of older meetings.

### Product changes from the audit

- **A meeting now says when a side was not heard.** It keeps the seconds each channel
  received; when one heard under 80 % of the meeting, the window shows "Apenas llegó
  audio de Teams en esta reunión…". The first real call would have said so instead of
  reading as a one-person meeting.
- Minor voices folded (finding 2 above).

## 5. Status

| Tier | State |
|---|---|
| T1 | Gaps of §2.4 covered, except `ChannelTranscriber` (needs the speech model; covered by T2) and `MeetingFlowModel` (needs the app's environment) |
| T2 | Running, gated: C2, C2-noise, C3 (voices only until the English model is installed) |
| T3 | `Scripts/meetings-live.sh [case] [--break-at s]`: green, steady and with the capture killed mid-meeting. Not yet: a real output-device switch (it changes a system setting, so it waits for the owner), an hour-long run |
| T4 | `Scripts/meetings-owner.sh`: the owner reads `owner-script.txt` while the meeting plays; scores "me" WER and leak. Needs the owner, twice: headphones and speakers |
| T5 | QuillBench S3 exists; the parse check and a budget pending |
