# Quill — voices and dictionary

The owner's field report after several real meetings (2026-10-25): two people
sometimes come out as one voice; the people Quill knows are remembered by name,
not by voice; and there is no way to correct a transcript or teach Quill words.
Decisions: J-01–J-08 in the owner's decision journal (JOURNAL.md, kept out of the public export).

## What exists (read 2026-10-25)

- **Separation**: `SpeakerKit.SpeakerSeparator` runs FluidAudio's offline
  pipeline (pyannote community-1, VBx) with `OfflineDiarizerConfig.default`:
  AHC cut `clustering.threshold = 0.6` (larger merges more), no speaker count.
  `expectedSpeakers` exists but only the debug probe passes it.
  `SpeakerTurn.absorbingMinorVoices` folds a voice under 5 % and under 15 s.
- **Memory**: `MeetingKit.Person` is `id, name, roleID, meetings, lastSeen`,
  deduplicated **by name** (`MeetingStore.remember(name:)`). No voiceprint is
  kept; `SpeakerSeparator.separate` returns them and nobody stores them.
- **Transcript**: read-only (`MeetingTranscriptView` has search only).
  `ChannelTranscriber` uses `SpeechTranscriber` with no `AnalysisContext`.
- **Bench**: `tools/MeetingBench`, cases C2 (five distinct Spanish voices),
  C2-noise, C3 (AMI). No case with similar voices; no cross-meeting case.

## Slices

| Slice | Builds | Done when (machine-checked) | Stop |
|---|---|---|---|
| S0 | A bench case that reproduces the field failure: C4, voices chosen as the most alike pairs of a candidate pool by voiceprint (C5, the same people in two meetings, moves to S2 where it is scored) | Baseline numbers recorded below; `--gate` still green on C2/C3 | — |
| S1 | "Es otra persona" on a sentence: it moves to a new voice, and from the second mark on Quill proposes the sentences that sound like it (`VoiceSplit.peelingOff`, on per-sentence WeSpeaker voiceprints computed when the meeting ends — the audio is not kept). No clustering retune, no "how many of you?" hint: measured useless (Results) | Split tests; C4 baseline locked in the gate; separability numbers below | ✋ owner tries a real meeting |
| S2 | Voice profiles (J-02): own id, colour, usual role, voiceprint samples, migration from name-keyed `Person`; after a meeting, "¿Es Jesús · Product Owner?" (J-03) with accept / "no, es otra persona"; voiceprints deletable in Settings | C5: recognition rate and false suggestions at the chosen threshold; store migration tests | ✋ clickable mock before UI, then a real meeting |
| S3 | Editable transcript, live and after; each word-level correction extracted and offered as a dictionary entry; dictionary used as `AnalysisContext` hints and as a post-transcription substitution | Correction-diff and substitution tests; a spike proves `SpeechTranscriber` honours the hints (or the hints are dropped and said so) | — |
| S4 | Scopes: global and per profile (J-04), applied to the speaker's segments; the same correction in two profiles offers "global"; a profile's vocabulary as a tie-breaker in recognition | Scope and promotion tests; C5 with vocabulary | ✋ owner uses it for a few days |

## Results

### S0 — the failure reproduced (2026-10-25)

Pool of twelve OpenSLR voices (six men, six women, Colombian and Peruvian), each measured
on 12 clips. Most alike: women `pef_00610`·`pef_01208` 0.76 (cosine of voiceprints), men
`com_00610`·`com_02121` 0.58; every other pair ≤ 0.57. C4 = those two pairs plus "me",
4.5 min.

| Case | DER | Voices found | Merged | Words to the right person |
|---|---|---|---|---|
| c2-es | 15.8 % | 5 of 5 | none | 89.6 % |
| c2-es-noise | 12.0 % | 5 of 5 | none | 94.6 % |
| c3-ami | 23.9 % | 4 of 4 | none | — |
| **c4-similar** | **35.3 %** | 3 of 4 | **the two women** | **74.7 %** |

C2 is unchanged by the composer refactor (same numbers as 2026-10-08).

### S1 — what separates alike voices (2026-10-25)

Tried on C4, nothing un-merges the two women:

| Knob | Values | C4 |
|---|---|---|
| AHC cut `clustering.threshold` (default 0.6) | 0.55 … 0.35 | still merged; C2 worse below 0.45 |
| VBx `warmStartFb` (0.8) | 0.6 … 0.1 | still merged |
| VBx `warmStartFa` (0.07) | 0.15, 0.3 | still merged |
| Speaker count forced to 4 (`numSpeakers`) | 4 | still merged (3 voices out) |

Sentence by sentence (`meeting-bench separability`, one voiceprint per clip of ~4 s):

| Pair | Cosine of averages | Blind split in two | Marking 1 / 2 / 3 / 5 sentences of the other person | Both people marked, 3 each | Every other sentence known |
|---|---|---|---|---|---|
| `pef_00610`·`pef_01208` | 0.88 | 56 % | 63 / 73 / 72 / 74 % | 73 % | 82 % |
| `com_00610`·`com_02121` | 0.86 | 68 % | 38 / 83 / 86 / 97 % | 100 % | 90 % |
| `cof_00610`·`pef_02121` | 0.77 | 87 % | 67 / 80 / 94 / 94 % | 100 % | 95 % |

With FluidAudio's streaming embedding model instead (WeSpeaker, `SpeakerEmbedder`,
`BENCH_EMBEDDER=wespeaker`), the same clips:

| Pair | Cosine of averages | Blind split | Marking 1 / 2 / 3 / 5 of the other person | Every other sentence known |
|---|---|---|---|---|
| `pef_00610`·`pef_01208` | 0.73 | 100 % | 53 / 80 / 98 / 100 % | 100 % |
| `com_00610`·`com_02121` | 0.57 | 100 % | 92 / 98 / 100 / 100 % | 100 % |
| `cof_00610`·`pef_02121` | 0.53 | 100 % | 100 % | 100 % |

Caveat: each OpenSLR volunteer recorded on their own device, and part of what separates
them may be the microphone. In a call each remote person has their own microphone too, so
that is real signal there; two people sharing one microphone in a room is not covered.

End to end (`meeting-bench split <case>`: the case through the product's pipeline, each
sentence measured as `finish()` does, then k sentences of the hidden person moved and
Quill's proposal accepted; scored on the merged voice's other sentences):

| Case | Voiceprints | Measuring | 1 mark | 2 marks | 3 marks |
|---|---|---|---|---|---|
| c4-similar (the two women, 18 sentences) | offline pipeline | 5.9 s / 36 | 60 % | 50 % | 46 % |
| c4-similar | **WeSpeaker** | **2.1 s / 36** | 65 % | **100 %** | **100 %** |

Tried and dropped: Quill noticing a merged voice on its own (blind split of every voice,
flag when the halves are far apart). On C2 it flagged a voice that holds interruption
leftovers of four people at 0.86 and missed C4's merged voice; not reliable, so the user's
two marks start the split.

In the app (debug build, C4 seeded, `QUILL_OPEN_MEETING_MOVES=12,16`): after the second
sentence moved, the banner reads "3 frases más suenan como Persona 4. ¿Se las paso?", the
three are highlighted and the transcript scrolls to them. Known limit: a segment that
holds both people (the transcriber did not pause between them, e.g. "¿Quién dirige la
película? La vigencia de tu tarjeta…") moves whole; splitting a line belongs to S3's
editing.

Reading: the merge is in the diarizer's voiceprints, not in a threshold; a blind split is a coin toss
on the alike pair, but two or three sentences the user attributes are enough for the rest
to follow at 73–97 %. One mark is not enough — so Quill moves the marked sentence at once
and only proposes the others from the second mark. 2-means re-estimated from the marks was
worse (it drifts back towards one voice) and is not used. Voice profiles (S2) give the
same "known sentences" for free when both people were met before.
