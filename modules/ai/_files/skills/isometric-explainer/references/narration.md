# Narration

The copy is half the product. The animation earns attention; the writing spends
it. A beautiful explainer with vague captions teaches nothing.

## Three fields per district

```js
{
  id: 'transfer', name: 'Return Road', x: 30, y: 31, r: 5.0, color: C.brick,
  tag: 'Slow start',
  short: 'A fresh connection does not get your bandwidth. It has to earn it.',
  body: 'TCP will not fire a large response down a new connection at full speed. ...'
}
```

| Field | Length | Job |
|---|---|---|
| `name` | 2–3 words | A place. "Certificate Vault", not "TLS Handshake Stage". |
| `tag` | 2–4 words | The transformation. Often `X → Y`. Shown on the chip and the plate. |
| `short` | one sentence | Readable while the vehicle is still slowing down. The single most important sentence in the project. |
| `body` | 60–110 words | The paragraph the reading stop is timed against. |

`short` should survive being read alone. Assume a reader who skims every `short`
and reads three `body`s — make that a coherent experience.

Over 110 words and `readSeconds` saturates at its 26-second ceiling, so the stop
is no longer long enough for the text. If a station needs more, split it.

## Voice

**Concrete over abstract.** Name the number.

> 12 → 24 → 12 here, typically 4× in real models.

not "the dimension is expanded and then reduced".

**Anchor to real scale, every time.**

> This city uses 12 numbers per token so you can watch them; GPT-class models use
> 4,000–16,000.

**Say why it exists, not just what it does.** The mechanism is the easy half.

> Attention is permutation-blind: without a position signal, "dog bites man" and
> "man bites dog" are literally the same input.

That sentence teaches more than any description of sinusoidal encoding.

**Point at what is on screen.** This is the form's unique advantage — use it.

> The beams arcing over the warehouse are the real weights being computed for this
> token, right now.

> Watch the map, not just the number — the cache hit is the shape of the route
> changing.

**Invite the reader to poke it.** Name the slider and the expected outcome.

> Drag Bandwidth up on a 200 ms link and watch this bar refuse to move.

> Toggle the version and watch the bar: on a 200 ms link, that one saved round
> trip is worth more than any amount of extra bandwidth.

An instruction plus a prediction turns a slider into an experiment.

**Name the consequence.** Explain why anyone should care.

> This is also why long contexts get expensive: the warehouse grows linearly with
> tokens and layers, and it lives in GPU memory.

**Correct the obvious misreading.** Every metaphor mislabels something; say so.

> This is not a loop in code: it is a stack of distinct blocks, each with its own
> weights.

**Prose, not bullets.** These are paragraphs to be read at a stop, not slides.
Full sentences, no lists inside `body`.

**No hype.** No "amazing", no "magic", no exclamation marks. The dry register is
what makes the surprising parts land.

## Other copy

**HUD note** — one line, present tense, explains the current mode. See
`pacing.md`.

**Live interpretation in the panel** — one sentence, recomputed each frame, saying
what the numbers *mean*:

> Latency-bound: the response spends 240 ms opening the congestion window and only
> 115 ms actually pushing bytes. More bandwidth would change nothing.

Often the most valuable text on the page, because it says which of two plausible
readings is the right one *for the current settings*.

**The done card** — do not just say "finished". Land the lesson:

> The last request cost 367 ms, against 725 ms for the first one. Nothing about
> the network changed between them. The difference is entirely DNS, the connection
> and the cache being warm the second time.

**Tooltips** — reuse `short`. Do not write a fourth register.

**Fine print** under a widget — what the reader is looking at and its limits:

> 12 numbers standing in for the 4,096+ a real model carries. Blue is negative,
> warm is positive.

## The README

Not an afterthought — for many readers it arrives before the page does.

Include: a one-paragraph description of the journey; how to run it; the controls
table; the pacing explanation with the actual timings; a table of every station
and its step; **the full fidelity ledger**; the file map; and one paragraph of
architecture — the non-obvious thing a person modifying it needs to know first
(the occlusion rule, where the state machine branches, what `routes` and
`stations` mean).

## Checks

- Read every `short` in sequence. Does it read as a coherent summary of the whole
  system?
- Does every `body` contain at least one number?
- Does every `body` say why the stage exists, not only what it does?
- Would a reader who knows the domain find anything to disagree with? If yes, it
  is either wrong or belongs in the ledger.
- Read it aloud. Awkwardness you skim past on screen is obvious out loud.
