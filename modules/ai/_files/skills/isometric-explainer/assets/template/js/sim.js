/* sim.js: the state machine that walks one request through the town.
 *
 * This is the pacing engine, and it is the part worth copying verbatim into a
 * new explainer. Three ideas do all the work:
 *
 *   1. The van moves along a route by distance, and a station fires when it
 *      passes one. Stations own the model steps; travel owns nothing.
 *   2. The FIRST time a station fires, the van stops for as long as its
 *      write-up takes to read. Every later visit gets a short beat instead.
 *   3. What the reader has already read (`tour`) lives outside the run state,
 *      so a reset replays the run but not the reading.
 */
(function (global) {
  'use strict';

  var Net = global.Net;
  var World = global.World;
  var Iso = global.Iso;

  var BASE_SPEED = 6;        // grid units / second at 1x

  /* Which districts the reader has already had explained. This deliberately
     survives a reset, because nobody wants to re-read the tour. */
  var tour = { seen: Object.create(null), done: false };

  var state = {
    running: false,
    paused: true,
    finished: false,

    station: null,
    stationT: 0,
    stepMode: false,
    speed: 1,

    /* ---- model inputs, wired to the sliders in ui.js ---- */
    rttMs: 60,
    mbps: 25,
    payloadKB: 350,
    tls13: true,
    edgeHit: false,
    serverMs: 40,
    dbQueries: 6,
    dbMs: 3,
    maxRequests: 3,

    /* ---- what the town has learned as it runs ---- */
    warmDns: false,          // the OS resolver cache, after the first lookup
    reuse: false,            // keep-alive, after the first connection
    warmEdge: false,         // the CDN, after the first miss populated it

    /* ---- model output ---- */
    plan: null,              // the whole waterfall for the current trip
    charged: null,           // station id -> ms actually charged this trip
    elapsedMs: 0,            // what the van is carrying
    cargoBytes: 0,
    cachedObjects: 0,
    hitThisTrip: false,
    requests: 0,
    lastTotal: 0,

    /* ---- pacing ---- */
    reading: false,
    dwellLeft: 0,
    dwellTotal: 0,
    fastForward: false,
    tourDone: false
  };

  var van = {
    routeName: 'out',
    dist: 0,
    dwell: 0,
    stationIdx: 0
  };

  var listeners = [];
  function emit(name, payload) {
    for (var i = 0; i < listeners.length; i++) listeners[i](name, payload);
  }

  /* ---- the model ---------------------------------------------------------- */

  /* Recomputed whenever it is needed rather than cached, so dragging a slider
     mid-trip changes the bars that have not been charged yet. Phases already
     paid for keep the number they were charged. */
  function planNow() {
    return Net.compute({
      rttMs: state.rttMs,
      mbps: state.mbps,
      payloadKB: state.payloadKB,
      tls13: state.tls13,
      warmDns: state.warmDns,
      reuse: state.reuse,
      edgeHit: state.edgeHit || state.warmEdge,
      serverMs: state.serverMs,
      dbQueries: state.dbQueries,
      dbMs: state.dbMs
    });
  }

  function phaseOf(plan, id) {
    for (var i = 0; i < plan.phases.length; i++) {
      if (plan.phases[i].id === id) return plan.phases[i];
    }
    return null;
  }

  function charge(id) {
    state.plan = planNow();
    var ph = phaseOf(state.plan, id);
    var ms = ph ? ph.ms : 0;
    state.charged[id] = ms;
    state.elapsedMs += ms;
    return ph;
  }

  /* ---- lifecycle --------------------------------------------------------- */

  function beginTrip() {
    state.charged = Object.create(null);
    state.elapsedMs = 0;
    state.cargoBytes = 0;
    state.station = null;
    state.plan = planNow();
    state.hitThisTrip = state.edgeHit || state.warmEdge;
    state.fastForward = state.requests > 0;
    van.routeName = 'out';
    van.dist = 0;
    van.stationIdx = 0;
    van.dwell = 0;
  }

  function reset() {
    state.finished = false;
    state.requests = 0;
    state.lastTotal = 0;
    state.warmDns = false;
    state.reuse = false;
    state.warmEdge = false;
    state.cachedObjects = 0;
    state.tourDone = tour.done;
    state.reading = false;
    state.dwellLeft = 0;
    state.dwellTotal = 0;
    beginTrip();
  }

  function run() {
    reset();
    state.running = true;
    state.paused = false;
    emit('reset');
  }

  /* ---- per-station work -------------------------------------------------- */

  var OPS = {
    resolve: function () { charge('resolve'); },
    connect: function () { charge('connect'); },
    secure:  function () { charge('secure'); },

    edge: function () {
      charge('edge');
      /* Decided here, not at the start of the trip, so the reader watches the
         route itself change: a hit sends the van straight to the return road. */
      state.hitThisTrip = state.edgeHit || state.warmEdge;
      if (state.hitThisTrip) state.cargoBytes = state.plan.wireBytes;
    },

    origin: function () {
      charge('origin');
    },

    records: function () {
      charge('records');
      /* the response exists now, so the van has something to carry back */
      state.cargoBytes = state.plan.wireBytes;
      /* and the edge keeps a copy of it on the way past */
      if (!state.warmEdge) {
        state.warmEdge = true;
        state.cachedObjects = Math.min(World.CACHE_MAX, state.cachedObjects + 1);
      }
    },

    transfer: function () {
      charge('transfer');
    },

    render: function () {
      charge('render');
      state.requests++;
      state.lastTotal = state.elapsedMs;
      /* One complete trip visits every district, so the tour is over. */
      tour.done = true;
      state.tourDone = true;
      /* Everything a browser keeps between requests is now warm. This is the
         whole reason a second page view is faster than the first. */
      state.warmDns = true;
      state.reuse = true;
      emit('trip', state.requests);
    }
  };

  /* ---- update ------------------------------------------------------------ */

  function routeOf(name) { return World.routes[name]; }

  /* Once every district has been explained there is nothing left to read, so
     the remaining trips run at a watchable pace instead of a readable one. */
  function travelBoost() {
    return (state.fastForward ? 2.4 : 1) * (state.tourDone ? 3.0 : 1);
  }
  function dwellBoost() {
    /* Stops stay generous even after the tour, because their numbers change. */
    return (state.fastForward ? 2.2 : 1) * (state.tourDone ? 1.4 : 1);
  }

  function fire(st) {
    state.station = st.id;
    state.stationT = 0;
    var op = OPS[st.id];
    if (op) op();
    emit('station', st.id);
  }

  function advanceRoute() {
    if (van.routeName === 'out') {
      /* The one branch in the whole town, and the point of the Edge Depot. */
      van.routeName = state.hitThisTrip ? 'back' : 'inland';
      van.dist = 0;
      van.stationIdx = 0;
      van.dwell = state.hitThisTrip ? 0.5 : 0.3;
    } else if (van.routeName === 'inland') {
      van.routeName = 'back';
      van.dist = 0;
      van.stationIdx = 0;
      van.dwell = 0.3;
    } else if (van.routeName === 'back') {
      if (state.requests >= state.maxRequests) {
        state.finished = true;
        state.paused = true;
        state.station = 'done';
        emit('station', 'done');
        return;
      }
      beginTrip();
    }
  }

  function update(dt) {
    state.stationT += dt;
    if (!state.running || state.paused || state.finished) return;

    var sdt = dt * state.speed * travelBoost();

    if (van.dwell > 0) {
      /* A stop is measured in reading seconds, so only the speed slider scales
         it; the travel boosts must never cut a first read short. */
      van.dwell -= dt * state.speed;
      state.dwellLeft = Math.max(0, van.dwell);
      if (van.dwell <= 0) { state.reading = false; state.dwellTotal = 0; }
      return;
    }

    var route = routeOf(van.routeName);
    van.dist += BASE_SPEED * sdt;

    var sts = World.stations[van.routeName];
    if (van.stationIdx < sts.length) {
      var st = sts[van.stationIdx];
      if (van.dist >= st.dist) {
        van.dist = st.dist;
        van.stationIdx++;
        /* Keyed by district, not by station: two stations that show the same
           write-up must not charge the reader for a second read. */
        var topic = World.stationToDistrict[st.id] || st.id;
        var firstTime = !tour.seen[topic];
        fire(st);
        tour.seen[topic] = true;
        van.dwell = firstTime ? World.readSeconds(st.id) : st.dwell / dwellBoost();
        state.reading = firstTime;
        state.dwellTotal = van.dwell;
        state.dwellLeft = van.dwell;
        if (state.stepMode) { state.paused = true; state.stepMode = false; }
        return;
      }
    }

    if (van.dist >= route.total) advanceRoute();
  }

  /* ---- queries used by the renderer and the camera ----------------------- */

  function vanPosition() {
    return Iso.smoothAt(routeOf(van.routeName), van.dist, 0.8);
  }

  global.Sim = {
    state: state,
    van: van,
    run: run,
    reset: function () { reset(); emit('reset'); },
    /* forget which districts have been explained, so the slow tour replays */
    replayTour: function () { tour.seen = Object.create(null); tour.done = false; },
    update: update,
    vanPosition: vanPosition,
    planNow: planNow,
    on: function (fn) { listeners.push(fn); },
    play: function () { if (!state.finished) { state.paused = false; state.running = true; } },
    pause: function () { state.paused = true; },
    toggle: function () { if (state.paused) this.play(); else this.pause(); },
    step: function () {
      if (state.finished) return;
      state.running = true;
      state.stepMode = true;
      state.paused = false;
      if (van.dwell > 0) van.dwell = 0;
    }
  };
})(window);
