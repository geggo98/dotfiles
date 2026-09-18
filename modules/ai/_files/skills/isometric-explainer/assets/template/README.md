# PacketPost

An isometric town that runs one web request in real time. A van leaves the
browser desk carrying nothing but a URL: it gets an address at the Name Registry,
a connection at the Handshake Yard and keys at the Certificate Vault, asks the
Edge Depot for the page, and — only if the depot does not already have it —
drives inland to the Origin Works and the Records Hall. Then it comes home over
the elevated Return Road, which is where the bytes are actually transferred.

Three requests run in a row. The second and third are dramatically cheaper, and
nothing about the network changed between them.

Pure static site. No build step, no dependencies, no network calls.

> **This is the reference example for the `isometric-explainer` skill.** It is a
> complete, working explainer, not a scaffold. Copy the directory and replace
> `js/model.js`, `js/world.js`, the landmark functions in `js/render.js` and the
> panels in `js/ui.js` with your own subject. `js/iso.js`, `js/sim.js` and
> `js/main.js` are engine — copy them unchanged.

## Run it

Open `index.html` in a browser. That's it.

If you'd rather serve it:

```
python -m http.server 8000
# → http://localhost:8000
```

## Controls

| | |
|---|---|
| **Space** | play / pause (holds a reading stop indefinitely) |
| **S** | advance exactly one station |
| **R** | reset and replay the slow tour |
| **F** | toggle camera follow |
| **L** | toggle labels |
| drag | pan · scroll: zoom · double-click: fit the whole town |
| **+ − ⤢** | zoom controls on the left edge; **⤢** shows the whole town |
| click a station | pin its write-up (click empty ground to resume) |

The view starts zoomed in on the van and follows it, since that is where
everything happens. Zooming out to the whole town is deliberate: the **⤢**
button, a double-click, or the scroll wheel. Turning off **Follow** lets you pan
around independently.

The sliders change **speed** (0.4×–8×), **round trip** (5–300 ms), **bandwidth**
(1–200 Mbps), **page size** (5 KB–2 MB), **server work** (0–400 ms) and
**database queries** (0–40). The **TLS 1.3** and **Cache hit** toggles change the
route the van takes. Everything feeds the real model, so the waterfall moves
because the arithmetic moved.

## Pacing

It is built to be read, not raced. The first time the van reaches a station it
stops for 9–26 seconds, scaled to the length of that station's write-up, and a
progress bar under the panel text shows how much of the stop is left. The first
request therefore takes about **two and a half minutes**: that is the guided tour.

After every station has been explained there is nothing new to read, so the town
switches to a watchable pace, and the warm second and third requests run faster
still since their handshake stations cost nothing. The HUD says which mode you
are in. The Speed slider scales everything, reading stops included; **Reset** (⟲)
replays the slow tour, while **Run** keeps what you have already read.

## The stations

| Station | Step |
|---|---|
| Browser Desk | the URL goes out; the page is parsed and painted on the way back |
| Name Registry | DNS: hostname → address |
| Handshake Yard | TCP: SYN, SYN-ACK, ACK |
| Certificate Vault | TLS: certificate chain, cipher suite, session keys |
| Edge Depot | CDN cache — a hit here ends the journey early |
| Origin Works | the application assembles a response |
| Records Hall | database queries, one after another |
| Return Road | the transfer itself, gated by TCP slow start |

## How much of it is real

**Genuinely computed, live, in the browser:** the whole waterfall. DNS, TCP and
TLS are charged in round trips at whatever latency you dial in; TLS 1.3 costs one
round trip and 1.2 costs two; the origin leg is charged at twice the edge
distance; database time is queries × per-query cost; and the response transfer is
the larger of the time the pipe needs for the bytes and the time TCP slow start
needs to open the congestion window — starting from a ten-segment initial window
(RFC 6928) and doubling each round. Time to first byte, the completion time, the
round-trip count and the latency-bound / bandwidth-bound verdict all fall out of
that arithmetic. It lives in `js/model.js`, about 120 lines, and it is worth
reading on its own.

**Assumed:** that the resolver sits as far away as the server; that the origin
sits twice as far as the edge; that headers cost 800 bytes compressed; that one
connection carries everything. A real page opens several connections and fetches
dozens of files over them — this is one request, deliberately.

**Indicative:** parse and paint. It depends far more on the page than on the
network, and it is the one bar here that is a guess. It is flagged as such in the
panel.

**Scenery:** the buildings, the trees, the road markings. They are there so the
mechanism has somewhere to happen. Treat the town as an illustration and the
numbers on the panel as the lesson.

## Layout

```
index.html          markup, controls, the About modal with the fidelity ledger
css/styles.css      light, print-like UI
js/iso.js           isometric projection, solid primitives, route helpers
js/model.js         the latency model: round trips, slow start, the waterfall
js/world.js         routes, stations, districts, buildings, props
js/sim.js           the state machine that walks one request through the town
js/render.js        canvas 2D painter's-algorithm renderer
js/ui.js            panels, narration, controls
js/main.js          camera, input, frame loop
```

`World.routes` holds the polylines the van drives and `World.stations` maps
distances along them to station ids. `Sim` fires a station handler when the van
arrives, which is where the model is charged for that stage. The van's gauge is
drawn from `elapsedMs / plan.total`, so it is the actual budget spent, and the
crates in its bed are the actual byte count.

The one branch in the whole town lives in `Sim.advanceRoute()`: on a cache hit
the van leaves the depot onto the return road instead of the inland loop. That is
deliberate — the reader should see the saving as a shorter journey, not just a
smaller number.

One layout rule is worth knowing before moving anything: in this projection a
building standing at `(mx, my)` hides the road point at `(mx, by)` when half its
footprint, `(w + d) / 2`, exceeds its setback `my - by`. That is why the depot and
the origin hall stand well back from the road — anything closer would swallow the
van you are meant to be watching.

## Verifying a change

```
# One file at a time: `node --check js/*.js` only checks the first one.
for f in js/*.js; do node --check "$f" || echo "FAIL $f"; done

# Then serve it and run the skill's smoke test against the URL.
python -m http.server 8000 &
node path/to/isometric-explainer/scripts/smoke.mjs http://localhost:8000/
```

The smoke test fails on any console error, steps the van through every station,
and writes a screenshot. Look at the screenshot: occlusion and label collisions
do not raise errors. It needs Playwright
(`npm i -D playwright && npx playwright install chromium`); without it, just open
`index.html` and watch a full trip.
