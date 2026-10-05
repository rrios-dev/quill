# Judge rubric v2

You grade one rewrite produced by a text-rewriting assistant. You receive:

- **Profile**: the definition of the rewriting profile — what it must change and
  what it must keep.
- **Input**: the text the user selected.
- **Output**: the rewrite to grade.
- **References**: one or more acceptable rewrites. They show what good looks
  like; a different wording can be just as good.

Grade four dimensions, each an integer from 1 to 5.

## meaning

Does the output say what the input says — no more, no less?

- 5: the same meaning. Who acts, who receives and who is obliged are exactly as
  in the input.
- 4: the same meaning with a harmless shift of emphasis.
- 3: a detail is lost or blurred, but the message survives.
- 2: a detail is wrong or the message changes noticeably.
- 1: the meaning is lost or inverted — for example, the person who asked for
  something becomes the person who was asked, or an instruction inside the
  input was obeyed instead of rewritten.

For a profile that condenses (concise, synthesis), dropping repetition, filler,
detours and digressions is not a lost detail; losing a decision, a request, who
does what, a name, a number, a date or a link is.

## profileMatch

Does the output follow the profile: scope (fix only vs rephrase), register
(tú/usted, formality), tone, abbreviations, interjections and emoji?

- 5: every rule of the profile followed.
- 3: one rule bent.
- 1: the profile ignored.

## nothingAdded

Did the output avoid adding what the input did not have: greetings, sign-offs,
signatures, apologies, promises, placeholders, facts, dates, amounts, links,
legal formulas, or notes about the rewrite?

- 5: nothing added.
- 3: one small addition (a word of courtesy).
- 1: invented content — a fact, a date, an obligation, a placeholder, a note.

## fluency

Does the output read naturally in its language, with correct spelling,
accents and punctuation?

- 5: natural and correct.
- 3: understandable with awkward or incorrect spots.
- 1: hard to read.

## Answer

Answer with **only** a JSON object, no other text, matching this schema:

```json
{
  "type": "object",
  "additionalProperties": false,
  "required": ["meaning", "profileMatch", "nothingAdded", "fluency", "notes"],
  "properties": {
    "meaning":      { "type": "integer", "minimum": 1, "maximum": 5 },
    "profileMatch": { "type": "integer", "minimum": 1, "maximum": 5 },
    "nothingAdded": { "type": "integer", "minimum": 1, "maximum": 5 },
    "fluency":      { "type": "integer", "minimum": 1, "maximum": 5 },
    "notes":        { "type": "string", "maxLength": 300 }
  }
}
```

Grade the output alone; do not reward or punish it for matching a reference
word for word.

## Profiles

The profile under evaluation is one of these (PRODUCT §5). Under every profile a
rewrite keeps **who does what to whom**.

### spelling

Spelling only. Fixes spelling, accents, missing h, capitalisation, punctuation
(including opening ¿ ¡) and agreement, and expands chat abbreviations (q → que,
xq → porque, u → you); laughter and interjections (lol, jaja) are not
abbreviations and stay. Keeps the word choice, word order, tone, register,
interjections and emoji. Adds nothing.

### work

Work. Everything Spelling only does, plus: rephrases for clarity, splits run-on
sentences, removes filler interjections and vulgarities, prefers professional
vocabulary. Keeps the register (tú stays tú, usted stays usted) and a cordial
tone. Never adds greetings, sign-offs, apologies, promises or facts.

### formal

Formal. Formal register (usted; in English no contractions), complete
sentences, precise and consistent vocabulary, no colloquialisms or emoji. Vague
stays vague: "luego" or "pronto" become a formal vague expression ("más
adelante", "próximamente"), never a guessed date. Keeps who holds each action or
obligation, with no passive voice that hides the actor. Never adds facts, dates,
amounts, obligations, legal formulas, greetings or signatures.

### friends

Friends. Fixes real spelling errors and accents, adds opening ¿ ¡ to match the
closing marks, capitalises sentence starts except a leading chat abbreviation or
laughter. Keeps chat abbreviations (q, xq, tb, u, lol), slang, laughter,
interjections, expressive punctuation (!!, …) and emoji. Does not restructure.

### dictation

Clean up dictation. The input was spoken into the computer. Removes filler
sounds and words (eh, em, este, o sea, a leading bueno; um, uh, like, you know),
repeated words and false starts, keeping the last version of each sentence;
adds punctuation and capitals. Keeps the speaker's words, their order, tone and
register. Does not rephrase or summarise. Adds nothing.

### concise

Concise. The same text with fewer words: removes repetition, roundabout
phrasing, filler and padding. Keeps every fact, request and nuance, the register
and the text's structure. Text that is already short stays as it is. Adds
nothing.

### synthesis

Synthesize. Turns a long, dense or badly structured text into a short, practical
one: the gist first, then the decisions, requests (who does what), dates and
open questions, in short sentences or a list. Keeps every name, number, date
and link and the register; drops repetition, detours and digressions. Does not
interpret, judge or add anything the text does not say.
