# Pacing

The mechanism that makes these explainers teach rather than merely play. It is
about forty lines in `sim.js`, and it is the part most worth copying verbatim.

## The problem it solves

An animation of a complex process is either too fast to learn from or too slow to
watch. Both failures are fatal, and they pull in opposite directions, so a single
speed cannot fix them.

The resolution: **the same run is slow the first time and fast afterwards.** The
first pass is a guided tour, paced by how much there is to read. Once every
station has been explained there is nothing new on screen, so the run speeds up
into something watchable. The reader never chooses between learning and watching,
and never has to pause to keep up.

## Reading stops

The first time the vehicle reaches a station it stops for as long as that
station's write-up takes to read:

```js
function readSeconds(stationId) {
  var d = DISTRICT_BY_ID[STATION_TO_DISTRICT[stationId] || stationId];
  if (!d) return 9;
  var words = (d.short + ' ' + d.body).split(/\s+/).length;
  return Math.min(26, Math.max(9, words / 3.8 + 3.5));
}
```

- **228 words/minute** (`words / 3.8` seconds) is a slow-ish silent reading pace,
  chosen deliberately: the reader is also looking at a moving picture.
- **+3.5 s** of settling time — noticing the panel changed, finding the start of
  the sentence.
- **Floor 9 s** so a one-line station is still on screen long enough to register.
- **Ceiling 26 s** so the longest write-up does not park the vehicle for a
  minute. If a station wants more than 26 seconds, the write-up is too long —
  split the station or cut the copy.

These numbers are tuned; do not change them without watching a full tour at 1×.

A total in the region of **4–6 minutes for the first complete pass** is the
target. Under three minutes and the reader is being rushed; over eight and they
leave.

Always show the stop's remaining time as a progress bar under the panel text.
Without it, a 20-second stop reads as a frozen page, and readers reload.

## Later visits

Every subsequent visit uses the station's own short `dwell` (0.5–2.8 s), divided
by the dwell boost. Long enough to see the numbers land, short enough not to
annoy.

The distinction is keyed on the **district**, not the station:

```js
var topic = World.stationToDistrict[st.id] || st.id;
var firstTime = !tour.seen[topic];
```

Two stations that display the same write-up must not charge the reader for a
second read. TokenTown's `norm1` and `norm2` are separate model steps sharing one
LayerNorm explanation; without this indirection the reader reads the same
paragraph twice on the first lap.

## The two boosts

```js
function travelBoost() {
  return (state.fastForward ? 2.4 : 1) * (state.tourDone ? 3.0 : 1);
}
function dwellBoost() {
  return (state.fastForward ? 2.2 : 1) * (state.tourDone ? 1.4 : 1);
}
```

- `fastForward` — this pass is a repeat of one already shown at full detail. The
  second through eighth transformer layer are the same road with different
  weights; the second HTTP request is the same town with warm caches. Show the
  first at full pace and speed up the rest.
- `tourDone` — every district has been explained, so nothing on screen is new.

Travel is boosted harder than dwell, because stops still carry *changing
numbers* even after their text has been read.

## The one rule that is easy to break

```js
if (van.dwell > 0) {
  van.dwell -= dt * state.speed;    // NOT * travelBoost()
  ...
}
```

**A reading stop is scaled by the speed slider alone.** Multiply it by a travel
boost and a first-time stop gets cut short exactly when the reader needed it —
and the bug is nearly invisible, because it only shows up on the pass where
`fastForward` happens to be on.

## The tour survives a reset

```js
var tour = { seen: Object.create(null), done: false };
```

Declared outside the run state, so `reset()` does not clear it. Re-reading eight
paragraphs because you pressed the wrong button is infuriating.

That gives you two distinct buttons, and they must be labelled differently:

- **Run** — new run, keep what has been read. Fast.
- **Reset (⟲)** — replay the slow tour. Calls `replayTour()`, which clears
  `tour.seen`.

## Transport controls

| Control | Behaviour |
|---|---|
| **Space** / ❚❚ | Play/pause. Holds a reading stop **indefinitely** — the escape hatch for a slow reader. |
| **S** / ⇥ | Advance exactly one station, then pause. Sets `stepMode`; the station handler pauses on arrival. Also zeroes the current dwell so it does not have to be waited out. |
| **R** / ⟲ | Reset and replay the tour. |
| Speed | 0.4×–8×, scales everything including reading stops. Default 1. |

## Tell the reader what mode they are in

A HUD note, always:

```
⏸ holding here so you can read the panel
⏩ fast-forwarding the remaining layers: same road, different weights
⏩ every district explained, running the rest at speed (drag Speed down to slow it)
↩ cache hit: the van turns for home without going inland
```

Unexplained speed changes read as a bug. One line of text turns the same
behaviour into a feature the reader understands and trusts.
