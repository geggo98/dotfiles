# Build order

Seven phases. Do them in this order. The ordering is not stylistic: each phase
is cheap to change and expensive to change later, and phase 2 decides the whole
shape of the project, so getting to it before you have drawn anything is the
single most useful thing this file tells you.

The recurring failure is building the scenery first. It is the fun part, it looks
like progress, and it locks in a layout before you know what the layout has to
show. You end up with a beautiful town whose roads do not match the algorithm.

---

## Phase 1 — Find the metaphor

You need a **place** whose natural structure already matches the system's
structure. Not a theme painted over it — a genuine structural match.

Ask what shape the process is, then pick a place with that shape:

| The system is | The place is | Because |
|---|---|---|
| a linear pipeline | a factory line, a postal route | one thing moves, stations act on it |
| a pipeline with a repeated block | a city with a ring road | the loop is literally a loop |
| a request with a branch | a town with a junction | the branch is a fork in the road |
| a hierarchy | a valley with tributaries | flow converges |
| a store with lookups | a warehouse with aisles | address = position |
| a negotiation between parties | a market square | parties face each other |

Test the metaphor with three questions. If any answer is "it doesn't", find
another metaphor — do not paper over it with a label.

1. **Where does repetition live?** A stack of N transformer layers must be a road
   the vehicle drives round N times, not N buildings in a row.
2. **Where does branching live?** A cache hit that skips the origin must be a
   junction the vehicle turns at, so the reader *sees* the saving as a shorter
   route.
3. **What does the vehicle carry?** There must be a single travelling piece of
   state. If your system has no such thing, an isometric explainer is the wrong
   form — you probably want a diagram.

Worked examples: a transformer as a city, where a convoy is the hidden state and
the layer stack is a ring road. An F1 power unit as a factory, where a carrier is
the part under construction and each station adds to it. A web request as a town,
where a van is the request and the cache is a depot with a junction.

Name the places concretely — "Tokenizer Docks", "Certificate Vault", "Records
Hall". A name that sounds like somewhere is worth more than a technically precise
one.

## Phase 2 — Write `model.js` first

**This is the lesson. Everything else is presentation.** Write it before there is
anything to look at, and make it correct on its own.

Rules:

- Real arithmetic, real algorithm, reduced scale. 12 dimensions instead of 4,096.
  Six cylinders, real bore and stroke. Ten TCP segments, real congestion window.
- Take inputs, return derived values. No drawing, no DOM, no globals beyond the
  one export. It should be testable in `node` with a couple of `console.log`s —
  do that before you go further.
- **No lookup tables of results, ever.** If the panel changes because a lerp
  moved, the explainer is a lie. Every displayed number must be computed from
  inputs.
- Comment the boundary as you write it: which constants are mandated, which are
  assumed, which are guesses. That comment becomes the fidelity ledger, and
  writing it later means reverse-engineering your own decisions.

Scale down until you can *see* it. The reader must be able to watch twelve
numbers change; they cannot watch four thousand. Choose the smallest size that
still demonstrates the mechanism, then say what the real number is.

Where you have to fake something to keep the output legible, fake it in the
narrowest possible place and declare it. TokenTown's weights are random, so a
pure hidden-state projection would emit noise; it blends in a bigram prior from a
fixed corpus so the text reads, and says so in three places. The mechanism stays
real; only the scenery text is scaffolded.

## Phase 3 — Map stations onto the model

Now connect the two. In `world.js`:

- **Routes** are polylines: `Iso.makeRoute([[x, y, z], ...])`. One route per leg
  of the journey. Each route knows its own length and `cum[i]`, the distance to
  waypoint `i`.
- **Stations** are distances along a route that fire a model step. Anchor them to
  waypoint indices — `station(OUT, 3, 'secure')` — never to hand-measured
  distances, or every layout tweak silently moves your stations.
- In `sim.js`, the `OPS` table maps a station id to the model call it performs.
  Each op advances the model and records what it cost. That table should read
  like a summary of the algorithm.

Get the sequence right before you place a single building. At the end of this
phase you should be able to log the station order and see your algorithm.

Branches live in `advanceRoute()` — one `if` per fork. Keep them there; scattering
route changes through the ops is how a state machine becomes unfollowable.

## Phase 4 — Lay out the world

Only now does geometry matter. Grid space: `x` grows toward the lower-right, `y`
toward the lower-left, `z` up.

- Place the districts along the routes, one per station, with a radius `r` for
  hit-testing.
- Give each district a landmark that *means something*. Silos for a cache,
  because one silo per cached item shows the cache growing. Drums for a database.
  A vault door for TLS. A gantry the road passes under for a handshake. Generic
  boxes teach nothing.
- Set big buildings **back** from the road. See the occlusion rule in
  `isometric-drawing.md`; it is the one layout mistake that is invisible until
  you watch a vehicle disappear behind a shed.
- Scatter background blocks and props so the place reads as a place, but keep
  them dull. The eye must land on the landmarks.

Check the layout by fitting the whole world on screen (the ⤢ button) and asking
whether the *shape of the algorithm* is legible from the road pattern alone.

## Phase 5 — Write the narration

One `tag`, one `short`, one `body` per district. This is where the teaching
happens, and it is worth as much care as the code. See `references/narration.md`.

Write it after the layout, because what you can point at changes what is worth
saying: "the beams over the warehouse are the actual softmax weights" is only
available once there are beams and a warehouse.

## Phase 6 — Wire the panel

`ui.js` shows the numbers the canvas cannot. Waterfalls, bar lists, vectors,
build sheets. Every widget reads `Sim.state` or calls the model directly —
**never** store a number twice, or the panel and the map will eventually
disagree and the reader will believe the wrong one.

Sliders wire to real model parameters and take effect immediately. A slider that
only changes the animation is worse than no slider.

Add one sentence of live interpretation. Not just "270 ms" but "latency-bound:
more bandwidth would change nothing here". That sentence, recomputed from the
current inputs, is often the most valuable text on the page.

## Phase 7 — Polish, and then verify

- The About modal, with the full fidelity ledger.
- The README, with the same ledger, the station table, and the file map.
- Mobile: the panel becomes a bottom sheet, the sliders hide behind a gear. Check
  landscape on a phone — it is the worst case and the easiest to forget.
- Run the smoke test. Read the console output. **Look at the screenshot.**
- Walk `references/checklist.md`.

Then watch one full first-visit tour, start to finish, at 1×, without touching
anything. It is the only way to find a stop that is too short to read, a station
whose write-up says nothing, or a camera that misses the thing it is narrating.
