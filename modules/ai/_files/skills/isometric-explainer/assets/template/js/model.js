/* model.js: what a web request actually costs.
 *
 * THIS IS THE LESSON. Write this file first, before any scenery exists, and
 * make it runnable on its own. Every number the panel shows comes out of
 * compute() below; nothing here is a table of pre-baked results, so the panel
 * moves because the arithmetic moved.
 *
 * The honest boundary, restated in the About modal and the README:
 *
 *   Genuinely computed  the whole waterfall — handshake round trips, TCP slow
 *                       start, transfer time, time to first byte, the total.
 *   Assumed             the resolver sits as far away as the edge; the origin
 *                       sits twice as far; headers cost 800 bytes.
 *   Indicative          parse-and-paint time, which depends on the page more
 *                       than on the network.
 */
(function (global) {
  'use strict';

  var MSS = 1460;              // bytes of payload per segment on a 1500 B MTU
  var INIT_CWND = 10 * MSS;    // 14,600 B: the initial window Linux has shipped
                               // since 2011 (RFC 6928)
  var HEADER_BYTES = 800;      // ASSUMED: request + response headers, compressed
  var ORIGIN_FACTOR = 2;       // ASSUMED: the origin is twice as far as the edge

  /* How many round trips the response takes to get out of slow start.
     Congestion window doubles each round: 10, 20, 40 ... segments, so after
     n rounds the sender has been allowed (2^n - 1) * INIT_CWND bytes. */
  function slowStartRounds(bytes) {
    if (bytes <= INIT_CWND) return 1;
    return Math.ceil(Math.log2(bytes / INIT_CWND + 1));
  }

  function bandwidthMs(bytes, mbps) {
    return bytes * 8 / (mbps * 1e6) * 1000;
  }

  /* p = {rttMs, mbps, payloadKB, tls13, warmDns, reuse, edgeHit, serverMs,
   *      dbQueries, dbMs}
   * Returns a waterfall: one entry per station, in the order the request
   * visits them, plus the derived totals.
   */
  function compute(p) {
    var rtt = p.rttMs;
    var originRtt = rtt * ORIGIN_FACTOR;
    var payloadBytes = p.payloadKB * 1024;
    var wireBytes = payloadBytes + HEADER_BYTES;

    var phases = [];
    var trips = 0;

    function phase(id, label, ms, roundTrips, note) {
      phases.push({ id: id, label: label, ms: ms, trips: roundTrips || 0, note: note });
      trips += roundTrips || 0;
      return ms;
    }

    /* --- getting a connection ------------------------------------------- */

    phase('resolve', 'DNS lookup',
      p.warmDns ? 0 : rtt,
      p.warmDns ? 0 : 1,
      p.warmDns ? 'already in the OS cache' : 'one round trip to the resolver');

    phase('connect', 'TCP handshake',
      p.reuse ? 0 : rtt,
      p.reuse ? 0 : 1,
      p.reuse ? 'connection reused, no handshake' : 'SYN, SYN-ACK, then data rides the ACK');

    phase('secure', 'TLS handshake',
      p.reuse ? 0 : (p.tls13 ? rtt : 2 * rtt),
      p.reuse ? 0 : (p.tls13 ? 1 : 2),
      p.reuse ? 'session resumed' : (p.tls13 ? 'TLS 1.3: one round trip' : 'TLS 1.2: two round trips'));

    /* --- asking for the thing -------------------------------------------- */

    phase('edge', 'Request to edge', rtt / 2, 0.5,
      p.edgeHit ? 'the edge already has it' : 'the edge has to go and get it');

    /* --- the part a cache hit skips entirely ------------------------------ */

    if (p.edgeHit) {
      phase('origin', 'Origin fetch', 0, 0, 'skipped: served from the edge');
      phase('records', 'Database', 0, 0, 'skipped: served from the edge');
    } else {
      phase('origin', 'Origin fetch', originRtt + p.serverMs, ORIGIN_FACTOR,
        'edge to origin and back, plus ' + p.serverMs + ' ms of application work');
      phase('records', 'Database',
        p.dbQueries * p.dbMs, 0,
        p.dbQueries + ' quer' + (p.dbQueries === 1 ? 'y' : 'ies') + ' at ' + p.dbMs + ' ms');
    }

    /* --- the bytes coming back ------------------------------------------- */

    var rounds = slowStartRounds(wireBytes);
    var bwMs = bandwidthMs(wireBytes, p.mbps);
    var startupMs = (rounds - 1) * rtt;
    /* Slow start and the pipe's width overlap: on a fat pipe the round trips
       dominate, on a thin one the bytes do. Take whichever binds. */
    var transferMs = Math.max(bwMs, startupMs);

    phase('transfer', 'Response transfer', rtt / 2 + transferMs, 0.5 + (rounds - 1),
      rounds === 1
        ? 'fits in the initial window: one burst'
        : rounds + ' slow-start rounds to open the window');

    phase('render', 'Parse and paint', 25 + p.payloadKB * 0.12, 0,
      'indicative: depends on the page, not the network');

    /* --- derived ---------------------------------------------------------- */

    var total = 0, ttfb = 0, i;
    for (i = 0; i < phases.length; i++) {
      if (phases[i].id === 'transfer') ttfb = total + rtt / 2;
      if (phases[i].id === 'render') break;
      total += phases[i].ms;
    }
    var renderMs = phases[phases.length - 1].ms;
    var handshake = phases[0].ms + phases[1].ms + phases[2].ms;

    return {
      phases: phases,
      ttfb: ttfb,
      total: total + renderMs,
      network: total,
      handshake: handshake,
      handshakeShare: total ? handshake / total : 0,
      roundTrips: trips,
      rounds: rounds,
      wireBytes: wireBytes,
      bandwidthMs: bwMs,
      startupMs: startupMs,
      effectiveMbps: total ? wireBytes * 8 / (total / 1000) / 1e6 : 0
    };
  }

  function fmtMs(ms) {
    if (ms >= 1000) return (ms / 1000).toFixed(2) + ' s';
    if (ms >= 100) return Math.round(ms) + ' ms';
    return (Math.round(ms * 10) / 10) + ' ms';
  }

  function fmtBytes(b) {
    if (b >= 1048576) return (b / 1048576).toFixed(2) + ' MB';
    if (b >= 1024) return (b / 1024).toFixed(1) + ' KB';
    return b + ' B';
  }

  global.Net = {
    MSS: MSS,
    INIT_CWND: INIT_CWND,
    HEADER_BYTES: HEADER_BYTES,
    ORIGIN_FACTOR: ORIGIN_FACTOR,
    slowStartRounds: slowStartRounds,
    bandwidthMs: bandwidthMs,
    compute: compute,
    fmtMs: fmtMs,
    fmtBytes: fmtBytes
  };
})(window);
