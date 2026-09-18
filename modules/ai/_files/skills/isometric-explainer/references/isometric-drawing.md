# Isometric drawing on canvas 2D

No WebGL, no z-buffer, no 3D library. One projection function and a sort. That is
the whole technique, and it is why these projects stay readable.

## The projection

```js
var TW = 30;   // half tile width  — px per grid unit on screen-x
var TH = 15;   // half tile height — px per grid unit on screen-y
var TZ = 20;   // px per grid unit of height

function project(x, y, z) {
  return { x: (x - y) * TW, y: (x + y) * TH - (z || 0) * TZ };
}
```

Grid space: **x grows toward the lower-right, y toward the lower-left, z up.**
`TH = TW / 2` is the classic 2:1 pixel-art isometric; it keeps every edge on a
clean half-pixel slope and avoids the shimmer a true 30° dimetric gives you.

Inverse projection, for hit-testing, only needs the ground plane:

```js
function unproject(sx, sy) {
  var a = sx / TW, b = sy / TH;
  return { x: (a + b) / 2, y: (b - a) / 2 };
}
```

Pick objects in **grid space** against a radius, not in pixels against sprites:
one `unproject` plus a few distance checks, and it stays correct at any zoom.

## The sorted pass — the whole renderer

Collect everything with a ground footprint into one list, sort by depth, paint
back to front:

```js
function key(o) { return o.x + o.y + ((o.w || 0) + (o.d || 0)) * 0.5; }

items.sort(function (a, b) { return a.k - b.k; });
for (i = 0; i < items.length; i++) items[i].f(items[i].a);
```

`x + y` is distance from the camera in this projection. The half-footprint term
is there because a box's visual depth is its **near** corner, not its origin;
anything drawn from its centre (a vehicle, a tree, a silo) uses plain `x + y`.

**One list.** Not one per category. The moment buildings sort separately from
vehicles, a vehicle passes through a wall.

### Things the road goes under

A structure the vehicle passes through must be registered as **separate pieces**:

```js
put({ kind: 'gatePost', x: gx, y: gy - 1.7, color: c });   // far post
put({ kind: 'gateBeam', x: gx, y: gy,       color: c });   // beam overhead
put({ kind: 'gatePost', x: gx, y: gy + 1.7, color: c });   // near post
```

One key for the whole gantry puts the near post behind a vehicle that should be
driving under it. Three keys and each piece sorts on its own depth.

### Things that are not in the pass

Ground, district washes and roads are painted **before** the sorted pass, in that
order — they are flat, they never occlude, and putting them in the sort only
creates opportunities for them to be wrong. Elevated-road pillars go here too, so
the deck covers their tops rather than a pillar capping the deck.

Overlays that must sit on top of everything (an emit burst, attention beams
arcing over rooftops, a flash) are painted **after** the pass.

## The occlusion rule

**The one layout landmine.** In this projection, a solid standing at `(mx, my)`
hides the road point at `(mx, by)` when half its footprint exceeds its setback:

```
(w + d) / 2  >  my - by      →  it swallows the vehicle
```

A 6×3.4 shed needs `(6 + 3.4) / 2 = 4.7` grid units of clearance from the road.
Put it 2.4 units back and the thing the reader is watching vanishes behind it
exactly when it arrives at the station that shed represents.

This is why big halls stand well back, why an oven sits further off the line than
its neighbours, and why props near the road are filtered by
`distToRoutes(x, y) < 2.6`.

Test it by watching a vehicle traverse the whole route at 1×. Nothing else finds
it.

## Faces and light

```js
var TOP = 1.0, RIGHT = 0.89, LEFT = 0.76;
```

Gentle steps, not dramatic ones. Pale surfaces keep their colour and the scene
reads as a paper model rather than a render. The night-scene values (0.5 / 0.6)
turn a pale cylinder nearly black — if a solid looks muddy, this is why.

For an arbitrary footprint, shade from the face's own outward normal:

```js
var nx = -ey / el, ny = ex / el;
if (nx + ny <= 0) continue;                    // back-face cull
shade = 0.80 + 0.09 * nx - 0.06 * ny;          // matches box()'s faces
```

Both +x and +y lean toward the camera, so a face is visible only when
`nx + ny > 0`. Culling the other two halves the work per solid.

Every solid gets a soft pencil outline, `rgba(88,78,64,0.30)`. It is what makes
the scene read as a drawn diagram rather than a flat render, and it is the single
highest-value stylistic choice in the whole renderer.

## Painting on a wall

A door, a dial, a sign painted on a face needs the wall's screen angle and the
screen length of a grid unit along it:

```js
var FACE_ANG = Math.atan2(Iso.TH, Iso.TW);      // ~26.57°
var FACE_U   = Math.hypot(Iso.TW, Iso.TH);      // px per grid unit along the wall
```

Then `ctx.translate(p.x, p.y); ctx.rotate(FACE_ANG);` and draw in local
coordinates. Vertical extent uses `TZ`, not `FACE_U` — height does not foreshorten.

Guessing pixel offsets instead is how face decoration ends up floating next to the
building instead of on it, and it breaks differently at every zoom level.

## Labels

Plates are drawn in **screen space** — but with the dpr transform, not the
identity transform:

```js
ctx.setTransform(cam.dpr, 0, 0, cam.dpr, 0, 0);
var ax = p.x * cam.scale + cam.ox;
var ay = p.y * cam.scale + cam.oy;
```

`cam.ox` and `cam.scale` come from `innerWidth` and `getBoundingClientRect`, so
they are **CSS** pixels. Under an identity transform they are read as device
pixels, and on a 2× display every plate lands at half its true position and
drifts against the world as the camera moves.

Three more things that matter:

- **Sit the plate on its bottom edge**, a constant number of screen pixels above
  its anchor, with a leader line down to it. Plates do not shrink with the world
  (they stay legible when zoomed out), so a plate centred on its anchor swallows
  the landmark it names.
- **De-collide.** Measure every plate, place them highest-priority first, and
  nudge each later one upward until it clears what is already placed. Cap the
  attempts — a stuck loop is worse than an overlap. The live, changing plate
  (the vehicle's readout) gets top priority; static names give way.
- **Declutter below ~0.34 zoom.** Every plate at once is an unreadable pile on a
  phone. Show only the active one.

## Determinism

```js
function hash2(x, y, s) { /* integer hash → [0,1) */ }
```

All scenery variation — window lights, grass tufts, crate colours, tree size —
comes from a hash of the object's own coordinates. **Never `Math.random()` in a
draw call.** It is re-evaluated every frame, so the whole world shimmers, and it
is one of those bugs that looks like a canvas problem for an hour.

Cache derived colours, and **quantise before caching**:

```js
f = Math.round(f * 64) / 64;
```

Anything animated feeds `shade()` a continuously varying factor. Without
quantising, every call misses the cache and the cache grows without bound for as
long as the page is open.

## Camera

- **Start close on the vehicle and follow it.** The tour is about what the vehicle
  is doing. Opening on the whole world shows a pretty map and no mechanism.
- **Look ahead** ~2.5 grid units along the direction of travel, so the reader sees
  where it is going. Small enough that a stopped vehicle still sits centred.
- **Ease, frame-rate independently:**
  ```js
  var k = 1 - Math.pow(0.05, dt);      // ~0.3 s time constant
  cam.x += (target.x - cam.x) * k;
  ```
  `cam.x += (target - cam.x) * 0.1` is tempting and wrong: it makes the camera
  speed depend on frame rate, so it feels different on a 144 Hz monitor.
- **Fitting the whole world is a deliberate act** — the ⤢ button, a double-click,
  or the scroll wheel. Never automatic.
- **Aim at the visible rectangle, not the window.** Measure the panels from the
  DOM and offset the camera by them, or the subject sits behind a panel on
  somebody else's screen. A `ResizeObserver` on the panels keeps it honest;
  guard the CSS-variable writes against re-entry or you get an observer loop.
- **A drag turns follow off.** The reader has asked to look somewhere else.
