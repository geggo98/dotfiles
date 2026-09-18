/* ui.js: DOM panels, controls, narration.
 *
 * The canvas shows the mechanism; this file shows the numbers. Every widget
 * here reads Sim.state or calls Net directly — nothing is stored twice, so the
 * panel can never disagree with the map.
 */
(function (global) {
  'use strict';

  var Sim = global.Sim, World = global.World, Net = global.Net;

  var $ = function (id) { return document.getElementById(id); };

  var el = {};
  var activeDistrict = null;
  var pinnedDistrict = null;      // set when the reader clicks a district
  var lastPaint = 0;
  var flyTo = null;
  var sheetOpen = false;          // mobile bottom sheet

  var STATION_LABEL = {
    resolve: 'DNS', connect: 'TCP', secure: 'TLS', edge: 'cache',
    origin: 'origin', records: 'database', transfer: 'transfer',
    render: 'paint', done: 'done'
  };

  /* ------------------------------------------------------------------ init */

  function init() {
    [
      'stage-chip', 'stage-tag', 'stage-name', 'stage-short', 'stage-body',
      'dwell', 'dwell-bar', 'dwell-hint',
      'wf-list', 'wf-hint', 'sum-ttfb', 'sum-total', 'sum-rt', 'sum-rounds',
      'sum-note', 'district-chips',
      'hud-phase', 'hud-trip', 'hud-elapsed', 'hud-state', 'hud-note',
      'inspector', 'btn-run', 'btn-play', 'play-glyph', 'btn-step', 'btn-reset',
      'speed', 'rtt', 'mbps', 'payload', 'dbq', 'server',
      'v-speed', 'v-rtt', 'v-mbps', 'v-payload', 'v-dbq', 'v-server',
      'tls13', 'edgehit', 'follow', 'labels',
      'btn-about', 'about', 'about-close', 'btn-panel', 'tooltip',
      'sheet-handle', 'btn-tune', 'dock', 'dock-tune'
    ].forEach(function (id) { el[id] = $(id); });

    buildChips();
    wire();
    applyResponsiveLabels();

    Sim.on(function (name, payload) {
      if (name === 'station') onStation(payload);
      if (name === 'reset') { pinnedDistrict = null; paint(true); }
    });
  }

  function buildChips() {
    World.districts.forEach(function (d) {
      var b = document.createElement('button');
      b.textContent = d.name;
      b.dataset.id = d.id;
      b.addEventListener('click', function () {
        showDistrict(d, true);
        flyTo = { x: d.x, y: d.y };
      });
      el['district-chips'].appendChild(b);
    });
  }

  function wire() {
    el['btn-run'].addEventListener('click', function () { Sim.run(); paint(true); });
    el['btn-play'].addEventListener('click', function () { Sim.toggle(); paint(true); });
    el['btn-step'].addEventListener('click', function () { Sim.step(); });
    /* Run keeps what you have already read; Reset starts the slow tour over. */
    el['btn-reset'].addEventListener('click', function () { Sim.replayTour(); Sim.run(); paint(true); });

    bindRange('speed', 'v-speed', function (v) { Sim.state.speed = v; return v.toFixed(2) + '×'; });
    bindRange('rtt', 'v-rtt', function (v) { Sim.state.rttMs = v; return v + ' ms'; });
    bindRange('mbps', 'v-mbps', function (v) { Sim.state.mbps = v; return v + ' Mbps'; });
    bindRange('payload', 'v-payload', function (v) { Sim.state.payloadKB = v; return v + ' KB'; });
    bindRange('dbq', 'v-dbq', function (v) { Sim.state.dbQueries = v | 0; return (v | 0) + ''; });
    bindRange('server', 'v-server', function (v) { Sim.state.serverMs = v; return v + ' ms'; });

    el.tls13.addEventListener('change', function () { Sim.state.tls13 = el.tls13.checked; paint(true); });
    el.edgehit.addEventListener('change', function () { Sim.state.edgeHit = el.edgehit.checked; paint(true); });
    el.labels.addEventListener('change', function () { global.Renderer.setLabels(el.labels.checked); });

    el['btn-about'].addEventListener('click', function () { el.about.hidden = false; });
    el['about-close'].addEventListener('click', function () { el.about.hidden = true; });
    el.about.addEventListener('click', function (e) { if (e.target === el.about) el.about.hidden = true; });

    el['btn-panel'].addEventListener('click', function () {
      var hidden = el.inspector.classList.toggle('hidden');
      el['btn-panel'].setAttribute('aria-expanded', String(!hidden));
      applyResponsiveLabels();
    });
    window.addEventListener('resize', applyResponsiveLabels);

    /* mobile: the sheet expands to show the full write-up */
    el['sheet-handle'].addEventListener('click', function () { setSheet(!sheetOpen); });

    /* mobile: the sliders live behind the gear button */
    el['btn-tune'].addEventListener('click', function () {
      var open = el.dock.classList.toggle('tune-open');
      el['btn-tune'].setAttribute('aria-expanded', String(open));
      el['btn-tune'].title = open ? 'Hide settings' : 'Show settings';
    });
  }

  function isMobile() { return window.matchMedia('(max-width: 900px)').matches; }

  /* A phone cannot fit "About & accuracy" and "Hide panel" side by side, but
     both actions still have to be reachable — in landscape, dismissing the
     sheet is the only way to get a usable canvas. */
  function applyResponsiveLabels() {
    var hidden = el.inspector.classList.contains('hidden');
    var narrow = isMobile();
    el['btn-panel'].textContent = narrow ? (hidden ? 'Panel' : 'Hide')
                                         : (hidden ? 'Show panel' : 'Hide panel');
    el['btn-about'].textContent = narrow ? 'About' : 'About & accuracy';
    /* name the actual key, but a phone has no Space bar */
    el['dwell-hint'].innerHTML = narrow
      ? 'reading stop: tap <b>❚❚</b> below to hold it here'
      : 'reading stop: press <kbd>Space</kbd> to hold it here';
  }

  function setSheet(open) {
    sheetOpen = open;
    el.inspector.classList.toggle('open', open);
    el['sheet-handle'].setAttribute('aria-expanded', String(open));
    if (open) el.inspector.scrollTop = 0;
  }

  function bindRange(id, out, fn) {
    var input = el[id];
    var apply = function () { el[out].textContent = fn(parseFloat(input.value)); };
    input.addEventListener('input', apply);
    apply();
  }

  /* -------------------------------------------------------------- narration */

  function onStation(station) {
    var id = station === 'done' ? null : (World.stationToDistrict[station] || station);
    activeDistrict = id;
    if (!pinnedDistrict && id) {
      var d = World.districtById[id];
      if (d) writeCard(d, station);
    }
    if (station === 'done') writeDone();
    paint(true);
  }

  function writeCard(d, station) {
    el['stage-chip'].textContent = STATION_LABEL[station] || d.id;
    el['stage-chip'].style.color = d.color;
    el['stage-chip'].style.background = global.Iso.rgba(d.color, 0.14);
    el['stage-chip'].style.borderColor = global.Iso.rgba(d.color, 0.3);
    el['stage-tag'].textContent = d.tag;
    el['stage-name'].textContent = d.name;
    el['stage-short'].textContent = d.short;
    el['stage-body'].textContent = d.body;
  }

  function writeDone() {
    var s = Sim.state;
    el['stage-chip'].textContent = 'done';
    el['stage-tag'].textContent = s.requests + ' requests';
    el['stage-name'].textContent = 'Page loaded';
    el['stage-short'].textContent = 'The last request cost ' + Net.fmtMs(s.lastTotal) +
      ', against ' + Net.fmtMs(firstTripCost()) + ' for the first one.';
    el['stage-body'].textContent = 'Nothing about the network changed between them. ' +
      'The difference is entirely DNS, the connection and the cache being warm the second time — ' +
      'which is why a cold first visit is the only one worth measuring. Move a slider and press Run again.';
  }

  /* What the first trip cost, recomputed cold, for the comparison above. */
  function firstTripCost() {
    return Net.compute({
      rttMs: Sim.state.rttMs, mbps: Sim.state.mbps, payloadKB: Sim.state.payloadKB,
      tls13: Sim.state.tls13, warmDns: false, reuse: false, edgeHit: false,
      serverMs: Sim.state.serverMs, dbQueries: Sim.state.dbQueries, dbMs: Sim.state.dbMs
    }).total;
  }

  function showDistrict(d, pin) {
    pinnedDistrict = pin ? d.id : null;
    writeCard(d, Sim.state.station);
    if (pin) {
      el['stage-chip'].textContent = 'pinned';
      el['stage-tag'].textContent = d.tag + ' · tap empty ground to resume';
      if (isMobile()) setSheet(true);
    }
    updateChips();
  }

  function updateChips() {
    var kids = el['district-chips'].children;
    for (var i = 0; i < kids.length; i++) {
      kids[i].classList.toggle('on', kids[i].dataset.id === (pinnedDistrict || activeDistrict));
    }
  }

  /* ------------------------------------------------------------------ paint */

  function paint(force) {
    var now = performance.now();
    if (!force && now - lastPaint < 90) return;
    lastPaint = now;

    var s = Sim.state;
    var plan = s.plan || Sim.planNow();

    el['play-glyph'].textContent = s.paused || s.finished ? '▶' : '❚❚';

    el['hud-phase'].textContent = s.station ? (STATION_LABEL[s.station] || s.station) : 'idle';
    el['hud-trip'].textContent = Math.min(s.requests + (s.finished ? 0 : 1), s.maxRequests) +
      ' / ' + s.maxRequests;
    el['hud-elapsed'].textContent = Net.fmtMs(s.elapsedMs);
    el['hud-state'].textContent = warmth(s);
    el['hud-note'].textContent = hudNote(s);

    var showing = s.reading && s.dwellTotal > 0 && s.dwellLeft > 0;
    el.dwell.hidden = !showing;
    if (showing) {
      el['dwell-bar'].style.width = (s.dwellLeft / s.dwellTotal * 100).toFixed(1) + '%';
    }

    paintWaterfall(s, plan);
    paintSummary(s, plan);
    updateChips();
  }

  function warmth(s) {
    var bits = [];
    if (s.warmDns) bits.push('DNS');
    if (s.reuse) bits.push('conn');
    if (s.warmEdge || s.edgeHit) bits.push('cache');
    return bits.length ? bits.join(' + ') + ' warm' : 'cold';
  }

  function hudNote(s) {
    if (s.finished) return '';
    if (s.reading) return '⏸ holding here so you can read the panel';
    if (!s.running) return 'Press Run to send a request across the town.';
    if (s.station === 'edge' && s.hitThisTrip) return '↩ cache hit: the van turns for home without going inland';
    if (s.fastForward) return '⏩ warm request: the handshake stations cost nothing this time';
    if (s.tourDone) return '⏩ every district explained, running the rest at speed (drag Speed down to slow it)';
    return '';
  }

  function paintWaterfall(s, plan) {
    var max = 1;
    plan.phases.forEach(function (p) { if (p.ms > max) max = p.ms; });

    el['wf-hint'].textContent = s.charged
      ? Object.keys(s.charged).length + ' of ' + plan.phases.length + ' paid'
      : 'projected';

    el['wf-list'].innerHTML = plan.phases.map(function (p) {
      var paid = s.charged && s.charged[p.id] != null;
      var live = s.station === p.id;
      var ms = paid ? s.charged[p.id] : p.ms;
      var zero = ms < 0.05;
      return '<div class="bar' + (paid ? ' paid' : '') + (live ? ' live' : '') + (zero ? ' cut' : '') + '"' +
        ' title="' + escapeHtml(p.note) + '">' +
        '<span class="lbl">' + escapeHtml(p.label) + '</span>' +
        '<span class="track"><span class="fill" style="width:' +
        (ms / max * 100).toFixed(1) + '%"></span></span>' +
        '<span class="val">' + (zero ? '—' : Net.fmtMs(ms)) + '</span></div>';
    }).join('');
  }

  function paintSummary(s, plan) {
    el['sum-ttfb'].textContent = Net.fmtMs(plan.ttfb);
    el['sum-total'].textContent = Net.fmtMs(plan.total);
    el['sum-rt'].textContent = plan.roundTrips.toFixed(1);
    el['sum-rounds'].textContent = plan.rounds;
    /* The one sentence worth taking away, chosen from what actually binds. */
    var note;
    if (plan.startupMs > plan.bandwidthMs) {
      note = 'Latency-bound: the response spends ' + Net.fmtMs(plan.startupMs) +
        ' opening the congestion window and only ' + Net.fmtMs(plan.bandwidthMs) +
        ' actually pushing bytes. More bandwidth would change nothing.';
    } else {
      note = 'Bandwidth-bound: ' + Net.fmtBytes(plan.wireBytes) + ' at ' + s.mbps +
        ' Mbps takes ' + Net.fmtMs(plan.bandwidthMs) + ', more than the ' +
        Net.fmtMs(plan.startupMs) + ' slow start costs. A fatter pipe would help here.';
    }
    note += ' Handshakes are ' + Math.round(plan.handshakeShare * 100) + '% of the network time.';
    el['sum-note'].textContent = note;
  }

  function escapeHtml(str) {
    return String(str).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  /* ---------------------------------------------------------------- exports */

  global.UI = {
    init: init,
    paint: paint,
    run: function () { Sim.run(); paint(true); },
    resetAll: function () { Sim.replayTour(); Sim.run(); paint(true); },
    showDistrict: showDistrict,
    unpin: function () { pinnedDistrict = null; updateChips(); },
    activeDistrict: function () { return pinnedDistrict || activeDistrict; },
    takeFlyTo: function () { var f = flyTo; flyTo = null; return f; },
    el: el
  };
})(window);
