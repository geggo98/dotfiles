# The fidelity ledger

A visual explainer that does not say which of its numbers are real is not a
teaching tool — it is a plausible-looking picture, and a reader who trusts the
wrong number has been actively misled. The ledger is the honesty mechanism, and
it belongs in **two** places: the About modal and the README.

It is also, in practice, the most-quoted part of these projects. Readers who know
the domain go looking for it first.

## The four buckets

Sort every quantity into exactly one.

### Genuinely computed, live, in the browser

The real arithmetic, running now. Be specific and enumerate — the list is the
credential.

> Genuinely computed, live: the tokenizer split; the embedding lookup; sinusoidal
> positional encoding; LayerNorm; 2-head scaled dot-product attention with causal
> masking over a real, growing KV cache; the residual adds; a GELU feed-forward;
> temperature and top-p sampling. The bars on the truck are the actual vector. The
> beams over the warehouse are the actual softmax weights, and they sum to exactly
> 1.

"They sum to exactly 1" is the kind of detail that earns trust. Point at the file:
"all of it lives in `js/spec.js`".

### Scaled down

Real mechanism, smaller numbers. Always give both.

> 12 dimensions instead of thousands, 2 heads instead of dozens, 2–12 layers
> instead of 80, a few hundred vocabulary items instead of 100k+.

### Assumed / modelled

Real arithmetic on top of a number nobody published. Say what you assumed, why
you had to, and roughly how much it matters.

> Modelled: the engine's output. Teams do not publish engine maps. This one
> assumes a flat 48% brake thermal efficiency and a fuel flow that rises with
> engine speed until it meets the regulation cap, which lands the ICE near 400 kW
> at the limiter — the figure the paddock generally assumes. It is a sanity-check
> model, not an engine map.

### Deliberately faked

Something is not the real mechanism, and the reader would assume it was. This is
the bucket that matters most, and the one people leave out.

> The weights are random; nothing here was trained, so a pure random-weight model
> would emit noise. To keep the output legible the final logits blend the real
> hidden-state projection with a bigram prior built from a small fixed corpus.
> Attention scores are also sharpened and given a small first-token ("sink") and
> recency bias so the map resembles the patterns trained models actually produce.
> **Treat the text the city writes as scenery; treat the mechanism as the lesson.**

That last sentence is the pattern to reach for: it tells the reader exactly where
to point their attention.

## Also worth naming

**Indicative** — dimensions of machinery, part counts, tolerances quoted in
write-ups, anything that is plausible rather than sourced.

> Indicative: the materials split, the part counts, the tolerances quoted in the
> station write-ups, and every dimension of the machinery on the floor. Real
> engine shops do not publish their process sheets. Treat the numbers on the panel
> as the lesson and the factory itself as an illustration.

**Integrated, not animated** — worth calling out when a motion is genuinely
simulated rather than keyframed, because readers assume the opposite:

> The launch at the end of the line. The car accelerates on
> `a = min(tyre grip, power / (mass × speed)) − drag`, stepped forward every frame
> from the combined output on the build sheet. That is why the run barely changes
> when you drag the MGU-K slider: off the line the car is held back by what the
> rear tyres can take, and deployment only tells once it is already moving.

That explains a *surprising behaviour* by naming the physics that causes it —
exactly what a good explainer is for.

## Where it goes

**About modal** (`index.html`) — headed "How much of it is real", `<strong>`ed
bucket names, one paragraph each.

**README** — the same content, plus the source file for each claim.

**Panel** — flag estimates inline where the number appears, not only in the modal.
A reader looking at one number should not have to open a dialog to learn it is a
guess.

**Code comments** — write the boundary into `model.js` as you write the model:

```js
var REG = {
  boreMM: 80,               // mandated exactly
  strokeMM: 53,             // what 1.6 litres over six 80 mm bores leaves you
  rodMM: 102,               // ASSUMED: teams do not publish this
  thermalEff: 0.48          // ASSUMED for the ICE model
};
```

`// ASSUMED` at the point of definition is what makes the ledger writable later
without reverse-engineering your own decisions.

## The test

For every number on screen, could you answer "where does that come from?" with a
file and a line?

If not, either compute it or move it into a declared bucket. There is no third
option — an undeclared invented number is the one failure mode that makes the
whole project worse than not building it.
