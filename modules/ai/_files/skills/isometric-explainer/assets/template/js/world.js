/* world.js: the static place — routes, stations, districts, buildings, props.
 *
 * Nothing here animates and nothing here computes the lesson. This file only
 * answers "where is everything, and what does each place mean".
 *
 * Two contracts the rest of the code depends on:
 *   routes[name]      a polyline the van drives, parameterised by distance
 *   stations[name]    distances along that polyline that fire a model step
 * A station's `id` is a model step. A district's `id` is a topic. They are
 * usually the same, but stationToDistrict lets several steps share one write-up
 * so a repeated stop does not charge the reader for a second read.
 */
(function (global) {
  'use strict';

  var Iso = global.Iso;
  var makeRoute = Iso.makeRoute;

  /* ---- routes ------------------------------------------------------------ */

  /* The outbound road. The van leaves the desk and works east. */
  var OUT = makeRoute([
    [7, 8],        // 0 browser desk — where a request begins
    [17, 8],       // 1 name registry
    [26, 8],       // 2 handshake yard
    [35, 8],       // 3 certificate vault
    [44, 8],       // 4 corner
    [44, 14]       // 5 edge depot
  ]);

  /* The trip inland, which a cache hit skips entirely. Starts and ends at the
     depot, so the depot is the only junction the return road has to know. */
  var INLAND = makeRoute([
    [44, 14],      // 0 depot
    [51, 14],      // 1 corner
    [51, 20],      // 2 origin works
    [51, 26],      // 3 corner
    [46, 26],      // 4 records hall
    [41, 26],      // 5 corner
    [41, 17],      // 6 corner
    [44, 14]       // 7 back at the depot, carrying the response
  ]);

  /* The return road is elevated, so it can fly over the origin loop instead of
     crossing it, and so the response is visibly a different journey. */
  var BACK = makeRoute([
    [44, 14, 0],
    [44, 18, 1.6],   // up the ramp
    [44, 31, 3],     // over the top of the inland loop
    [30, 31, 3],     // 3 return road: the transfer itself happens here
    [12, 31, 3],
    [8, 28, 1.4],    // down the ramp
    [7, 14, 0.2],
    [7, 8, 0]        // 7 back at the desk
  ]);

  /* `dwell` is how long the van waits once the reader has already read this
     district. The much longer first-visit stop is derived from the length of
     the write-up; see readSeconds() below. */
  function station(route, idx, id, dwell) {
    return { dist: route.cum[idx], id: id, dwell: dwell == null ? 0.8 : dwell };
  }

  var STATIONS = {
    out: [
      station(OUT, 1, 'resolve', 1.4),
      station(OUT, 2, 'connect', 1.4),
      station(OUT, 3, 'secure', 1.4),
      station(OUT, 5, 'edge', 1.8)
    ],
    inland: [
      station(INLAND, 2, 'origin', 1.6),
      station(INLAND, 4, 'records', 1.4)
    ],
    back: [
      station(BACK, 3, 'transfer', 2.0),
      station(BACK, 7, 'render', 1.6)
    ]
  };

  /* Several model steps can share one write-up. Here they map one to one, but
     keep the indirection: the moment you add a second pass over the same road
     (a retry, a second layer, a redirect) you need it. */
  var STATION_TO_DISTRICT = {
    resolve: 'resolve', connect: 'connect', secure: 'secure', edge: 'edge',
    origin: 'origin', records: 'records', transfer: 'transfer', render: 'render'
  };

  /* ---- palette ----------------------------------------------------------- */

  /* A printed-diagram palette: muted, low-chroma hues that stay legible on a
     pale ground and read as ink rather than light. */
  var C = {
    steel:  '#4a7a9b',
    violet: '#6f63a8',
    ochre:  '#c2913c',
    stone:  '#7d8b96',
    rose:   '#b05470',
    sage:   '#6d9068',
    teal:   '#3f8a86',
    orange: '#c07a3c',
    brick:  '#a85a44',
    moss:   '#5f8a52',
    plum:   '#8b5f96',
    ink:    '#4a4540',
    paper:  '#e5e1d5',
    road:   '#c9c4b6',
    roadTop:'#d8d3c6'
  };

  /* ---- districts (clickable, narrated) ----------------------------------- */

  /* `tag` is three or four words. `short` is one sentence a reader can take in
     while the van is still slowing down. `body` is the paragraph the reading
     stop is timed against: concrete, numbered, and honest about what it is
     leaving out. */
  var DISTRICTS = [
    {
      id: 'render', name: 'Browser Desk', x: 7, y: 8, r: 4.4, color: C.steel,
      tag: 'Parse and paint',
      short: 'Where the request starts, and where the page finally appears.',
      body: 'The browser begins with a URL and nothing else: no address, no connection, no bytes. Everything that follows exists to turn that string into pixels. When the response does land here it still has to be parsed, laid out and painted, and that cost belongs to the page rather than to the network — it is the one bar on this panel that is an estimate rather than a calculation.'
    },
    {
      id: 'resolve', name: 'Name Registry', x: 17, y: 8, r: 4.2, color: C.violet,
      tag: 'Name → address',
      short: 'A hostname is not an address. Something has to look it up first.',
      body: 'The browser asks the operating system, which asks a resolver, which may in turn ask the root servers, the .com servers and finally the authoritative server for the domain. Warm, this is free: the answer is already cached, sometimes for days. Cold, it is a whole round trip spent before one byte of your actual request has left the building — which is most of why the first visit to a site feels slower than every visit after it.'
    },
    {
      id: 'connect', name: 'Handshake Yard', x: 26, y: 8, r: 4.2, color: C.ochre,
      tag: 'TCP: three packets',
      short: 'A connection costs a full round trip before it can carry anything.',
      body: 'SYN out, SYN-ACK back, and the request rides along with the final ACK. That is one round trip spent agreeing to talk. None of it depends on bandwidth: a fibre line and a phone on the far side of the world exchange exactly the same three packets, and only the distance between them decides the bill. This is why the Round trip slider moves almost every bar on the chart at once.'
    },
    {
      id: 'secure', name: 'Certificate Vault', x: 35, y: 8, r: 4.2, color: C.plum,
      tag: 'TLS: prove it',
      short: 'Encryption is negotiated before the request is sent, and it is not free.',
      body: 'The server presents a certificate chain, both sides agree on a cipher suite and derive session keys. TLS 1.2 needs two round trips for that. TLS 1.3 folded it into one, and a resumed session can put application data in the very first flight. Toggle the version and watch the bar: on a 200 ms link, that one saved round trip is worth more than any amount of extra bandwidth.'
    },
    {
      id: 'edge', name: 'Edge Depot', x: 44, y: 14, r: 4.6, color: C.teal,
      tag: 'CDN cache',
      short: 'The nearest copy wins, and a hit here ends the journey early.',
      body: 'A content delivery network keeps copies of your bytes close to the people asking for them. On a hit the depot answers from a drum on its own floor and the van never goes inland: no origin, no application code, no database. On a miss it has to go and fetch, and every cost beyond this point is paid on top of what has already been spent getting here. Watch the map, not just the number — the cache hit is the shape of the route changing.'
    },
    {
      id: 'origin', name: 'Origin Works', x: 51, y: 20, r: 4.2, color: C.orange,
      tag: 'The application',
      short: 'The one machine that can actually build an answer nobody has yet.',
      body: 'Behind the cache sits the code you wrote. Reaching it costs distance again, because the origin usually sits further away than the edge does, plus however long the application takes to assemble the response. This is the only station where your own work appears in the total — and on a slow page it is very often not the largest bar on the chart.'
    },
    {
      id: 'records', name: 'Records Hall', x: 46, y: 26, r: 4.0, color: C.sage,
      tag: 'Queries add up',
      short: 'Each query is small. The number of them in a row is what hurts.',
      body: 'A single indexed lookup is a millisecond or two. Twenty of them, each one waiting for the answer to the last, is a visible fraction of the page load. Drag the query count up: nothing about the network changed, but the bar grows anyway. Serial round trips are the same problem inside a data centre as they are across an ocean, just three orders of magnitude smaller.'
    },
    {
      id: 'transfer', name: 'Return Road', x: 30, y: 31, r: 5.0, color: C.brick,
      tag: 'Slow start',
      short: 'A fresh connection does not get your bandwidth. It has to earn it.',
      body: 'TCP will not fire a large response down a new connection at full speed. It sends about 14 KB — ten segments — waits for the acknowledgement, then doubles the window, and doubles again. A 400 KB page therefore needs several round trips just to get up to speed, and on a long link it is those round trips, not the width of the pipe, that decide the transfer time. Drag Bandwidth up on a 200 ms link and watch this bar refuse to move.'
    }
  ];

  var DISTRICT_BY_ID = {};
  DISTRICTS.forEach(function (d) { DISTRICT_BY_ID[d.id] = d; });

  /* First-visit stop, in seconds, scaled to how much there is to read. The
     floor keeps a one-line district on screen long enough to notice; the
     ceiling stops the longest write-up parking the van for a minute. */
  function readSeconds(stationId) {
    var d = DISTRICT_BY_ID[STATION_TO_DISTRICT[stationId] || stationId];
    if (!d) return 9;
    var words = (d.short + ' ' + d.body).split(/\s+/).length;
    return Math.min(26, Math.max(9, words / 3.8 + 3.5));
  }

  /* ---- buildings and props ----------------------------------------------- */

  var buildings = [];
  var props = [];

  function put(o) { buildings.push(o); return o; }

  /* A background block: something with windows that makes the place read as a
     place. Deliberately dull — the eye must land on the landmarks. */
  function block(x, y, o) {
    put({
      x: x, y: y, z: 0, w: o.w, d: o.d, h: o.h, color: o.color,
      roof: o.roof, roofH: o.roofH,
      windows: { cols: o.cols || 3, seed: Math.round(x * 7 + y * 13), color: o.lit }
    });
  }

  /* How far (x, y) is from the nearest road, so scenery can be scattered
     without landing on the carriageway. */
  function distToRoutes(x, y) {
    var best = 1e9;
    [OUT, INLAND, BACK].forEach(function (r) {
      r.segs.forEach(function (s) {
        var vx = s.b.x - s.a.x, vy = s.b.y - s.a.y;
        var t = ((x - s.a.x) * vx + (y - s.a.y) * vy) / (vx * vx + vy * vy);
        t = Math.max(0, Math.min(1, t));
        var d = Math.hypot(x - (s.a.x + vx * t), y - (s.a.y + vy * t));
        if (d < best) best = d;
      });
    });
    return best;
  }

  /* The cache drums on the depot floor: one per object the edge is holding. */
  var CACHE_COLS = 4, CACHE_MAX = 12;
  function cachePos(i) {
    var col = i % CACHE_COLS, row = (i / CACHE_COLS) | 0;
    return { x: 47.2 + col * 1.5, y: 10.6 + row * 1.5 };
  }

  function build() {
    if (buildings.length) return;

    /* -- Browser Desk: a small house with a screen on the desk outside ----- */
    block(3.0, 4.4, { w: 3.0, d: 2.4, h: 2.4, color: '#c3d0d9', cols: 3, lit: C.steel, roof: '#9aa8b2', roofH: 0.7 });
    block(3.4, 10.6, { w: 3.4, d: 2.6, h: 2.0, color: '#b9c9d4', cols: 3, lit: C.steel, roof: '#9aa8b2', roofH: 0.6 });
    put({ kind: 'screen', x: 8.6, y: 4.6, color: C.steel });
    block(9.4, 10.8, { w: 2.4, d: 2.2, h: 1.8, color: '#c8d3da', cols: 2, lit: C.steel });

    /* -- Name Registry: a filing tower and a dish that asks upstream ------- */
    block(14.6, 3.6, { w: 3.2, d: 2.6, h: 4.6, color: '#c4bedb', cols: 3, lit: C.violet });
    block(18.6, 3.8, { w: 2.4, d: 2.4, h: 2.6, color: '#b6afd0', cols: 2, lit: C.violet });
    put({ kind: 'dish', x: 20.4, y: 11.0, color: C.violet });
    block(15.0, 10.8, { w: 3.6, d: 2.2, h: 1.8, color: '#cec9e0', cols: 4, lit: C.violet });

    /* -- Handshake Yard: the road runs under a three-bay gantry ------------
       Structures the road passes through are registered one piece at a time so
       each pillar sorts on its own depth. One key for the whole gantry puts the
       near post behind a van that should be driving under it. */
    [24.0, 26.0, 28.0].forEach(function (gx) {
      put({ kind: 'gatePost', x: gx, y: 6.3, color: C.ochre });
      put({ kind: 'gateBeam', x: gx, y: 8.0, color: C.ochre });
      put({ kind: 'gatePost', x: gx, y: 9.7, color: C.ochre });
    });
    block(23.0, 3.4, { w: 2.6, d: 2.2, h: 2.2, color: '#ddc79a', cols: 3, lit: C.ochre });
    block(28.2, 11.0, { w: 2.8, d: 2.2, h: 1.8, color: '#ddc79a', cols: 3, lit: C.ochre });

    /* -- Certificate Vault: a strongroom with a sealed door ---------------- */
    put({ kind: 'vault', x: 35.0, y: 4.4, color: C.plum });
    block(31.8, 10.8, { w: 2.6, d: 2.2, h: 2.4, color: '#cbb6d3', cols: 2, lit: C.plum });
    block(37.0, 11.0, { w: 3.0, d: 2.2, h: 1.8, color: '#d5c3da', cols: 3, lit: C.plum });

    /* -- Edge Depot: a wide shed, with the cached copies on the floor ------
       Set well back from the road. In this projection a solid at (mx, my)
       hides the road point at (mx, by) once half its footprint, (w + d) / 2,
       exceeds its setback my - by. */
    put({
      x: 46.4, y: 16.4, z: 0, w: 6.0, d: 3.4, h: 2.6, color: '#a9c4c2',
      panels: { cols: 6, seed: 5, color: '#cfe0de' }, rooftop: C.teal
    });
    block(39.0, 16.6, { w: 2.6, d: 2.2, h: 2.0, color: '#b6cdcb', cols: 2, lit: C.teal });
    put({ kind: 'dish', x: 40.2, y: 11.2, color: C.teal });

    /* -- Origin Works: the hall that actually builds a response ------------ */
    put({
      x: 53.0, y: 18.6, z: 0, w: 3.0, d: 4.4, h: 3.2, color: '#d9b491',
      panels: { cols: 4, seed: 9, color: '#eed7bd' }, rooftop: C.orange
    });
    put({ kind: 'stack', x: 53.2, y: 23.6, color: C.orange });
    block(47.6, 18.8, { w: 2.2, d: 2.6, h: 2.6, color: '#e0c1a2', cols: 2, lit: C.orange });

    /* -- Records Hall: drums, because that is what a database looks like --- */
    put({ kind: 'drums', x: 46.0, y: 29.0, color: C.sage });
    block(49.6, 28.8, { w: 2.4, d: 2.2, h: 2.2, color: '#b9cdb4', cols: 2, lit: C.sage });
    block(42.0, 29.0, { w: 2.6, d: 2.2, h: 1.8, color: '#c3d4bd', cols: 3, lit: C.sage });

    /* -- Return Road: the flyover's pillars are NOT registered as buildings.
       They belong to the road layer, which is painted before the sorted pass,
       so the deck covers their tops instead of a pillar capping the deck. --- */
    block(28.0, 34.6, { w: 3.4, d: 2.2, h: 1.8, color: '#d6b8ac', cols: 4, lit: C.brick });
    block(20.0, 34.8, { w: 2.6, d: 2.0, h: 2.2, color: '#cfaea1', cols: 3, lit: C.brick });

    /* -- scenery ----------------------------------------------------------- */
    var spots = [
      [12, 3], [21, 14], [31, 14], [38, 3], [42, 3], [12, 16], [16, 20],
      [24, 20], [32, 20], [22, 25], [14, 25], [30, 25], [8, 21], [50, 32],
      [54, 24], [36, 26], [34, 34], [10, 34], [48, 8], [52, 10]
    ];
    spots.forEach(function (s, i) {
      if (distToRoutes(s[0], s[1]) < 2.6) return;
      var n = Iso.hash2(s[0], s[1], 3);
      if (n < 0.34) {
        block(s[0], s[1], {
          w: 1.8 + n * 1.6, d: 1.6 + n, h: 1.4 + n * 1.6,
          color: n < 0.18 ? '#d8cfbe' : '#cfc7b6', cols: 2, lit: '#8b9aa4',
          roof: '#b09a86', roofH: 0.5
        });
      } else {
        props.push({ kind: n < 0.72 ? 'tree' : 'lamp', x: s[0], y: s[1], seed: i });
      }
    });
    /* Lamps down the outbound road, alternating sides at a fixed setback so
       they never occlude the van. Sparse on purpose: a dense row of poles
       reads as clutter and competes with the landmarks for attention. */
    for (var k = 0; k < 4; k++) {
      var lx = 13 + k * 9;
      props.push({ kind: 'lamp', x: lx, y: k % 2 ? 10.1 : 5.9, seed: lx });
    }
  }

  /* Where the flyover stands. Drawn with the roads, not with the buildings. */
  var PILLARS = [[44, 22], [44, 27], [38, 31], [26, 31], [18, 31], [12, 31]];

  global.World = {
    GW: 58, GH: 38,
    routes: { out: OUT, inland: INLAND, back: BACK },
    pillars: PILLARS,
    stations: STATIONS,
    districts: DISTRICTS,
    districtById: DISTRICT_BY_ID,
    stationToDistrict: STATION_TO_DISTRICT,
    readSeconds: readSeconds,
    buildings: buildings,
    props: props,
    palette: C,
    cachePos: cachePos, CACHE_MAX: CACHE_MAX,
    distToRoutes: distToRoutes,
    build: build
  };
})(window);
