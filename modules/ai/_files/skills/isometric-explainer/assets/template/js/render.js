/* render.js: a canvas 2D painter's-algorithm renderer.
 *
 * There is no z-buffer and no 3D library. Everything with a footprint on the
 * ground goes into one list, that list is sorted by x + y (distance from the
 * camera in this projection), and it is painted back to front. Get that one
 * pass right and the scene composites correctly for free.
 *
 * Layers, in order: sky, ground, district washes, roads, THE SORTED PASS,
 * overlays that are meant to sit on top of everything, then screen-space
 * labels with the world transform removed.
 */
(function (global) {
  'use strict';

  var Iso = global.Iso, World = global.World, Sim = global.Sim, Net = global.Net;
  var P = Iso.project;

  var cam = null, ctx = null, t = 0;
  var labels = [];
  var showLabels = true;
  var C = World.palette;

  /* ------------------------------------------------------------------ sky */

  function drawSky(w, h) {
    var g = ctx.createLinearGradient(0, 0, 0, h);
    g.addColorStop(0, '#eef3f6');
    g.addColorStop(0.55, '#e9eef0');
    g.addColorStop(1, '#e3e6e2');
    ctx.fillStyle = g;
    ctx.fillRect(0, 0, w, h);
  }

  /* --------------------------------------------------------------- ground */

  function plate(inset, z) {
    return [
      P(inset, inset, z), P(World.GW - inset, inset, z),
      P(World.GW - inset, World.GH - inset, z), P(inset, World.GH - inset, z)
    ];
  }

  var GRASS = ['#8aa96a', '#93b073', '#83a463', '#9ab77c'];

  function drawGround() {
    /* a shadow skirt, so the plate reads as a solid object on the sky */
    ctx.fillStyle = 'rgba(120,124,110,0.30)';
    Iso.poly(ctx, plate(-0.9, -0.35));

    ctx.fillStyle = '#93b073';
    Iso.poly(ctx, plate(0, 0));

    /* Deterministic tufts: hash2, never Math.random(), or the whole field
       shimmers on every frame. */
    for (var gx = 1; gx < World.GW; gx += 2) {
      for (var gy = 1; gy < World.GH; gy += 2) {
        var n = Iso.hash2(gx, gy, 17);
        if (n < 0.45) continue;
        ctx.fillStyle = GRASS[(n * 4) | 0];
        Iso.disc(ctx, gx + n, gy + (1 - n), 0, 0.7 + n * 0.5);
      }
    }

    ctx.strokeStyle = 'rgba(74,69,64,0.28)';
    ctx.lineWidth = 1.4;
    Iso.polyLine(ctx, plate(0, 0), true);
  }

  /* A wash under the district being narrated, so the eye knows where to look
     even when the label is off screen. */
  function drawZones(activeId) {
    for (var i = 0; i < World.districts.length; i++) {
      var d = World.districts[i];
      var on = d.id === activeId;
      ctx.fillStyle = Iso.rgba(d.color, on ? 0.16 : 0.055);
      Iso.disc(ctx, d.x, d.y, 0.01, d.r);
      if (on) {
        ctx.strokeStyle = Iso.rgba(d.color, 0.5);
        ctx.lineWidth = 1.6;
        ctx.beginPath();
        var p = P(d.x, d.y, 0.01);
        ctx.ellipse(p.x, p.y, d.r * Iso.TW * 1.41421, d.r * Iso.TH * 1.41421, 0, 0, 6.2832);
        ctx.stroke();
      }
    }
  }

  /* ---------------------------------------------------------------- roads */

  function roadQuad(a, b, width, dz) {
    var dx = b.x - a.x, dy = b.y - a.y;
    var len = Math.hypot(dx, dy) || 1;
    var nx = -dy / len * width / 2, ny = dx / len * width / 2;
    var za = (a.z || 0) + (dz || 0), zb = (b.z || 0) + (dz || 0);
    Iso.poly(ctx, [
      P(a.x + nx, a.y + ny, za), P(b.x + nx, b.y + ny, zb),
      P(b.x - nx, b.y - ny, zb), P(a.x - nx, a.y - ny, za)
    ]);
  }

  /* The near fascia of an elevated deck: the side facing the camera, dropped
     by the deck's thickness. Without it the road reads as a floating ribbon. */
  function deckFascia(a, b, width, thick) {
    var dx = b.x - a.x, dy = b.y - a.y;
    var len = Math.hypot(dx, dy) || 1;
    var nx = -dy / len * width / 2, ny = dx / len * width / 2;
    /* pick the edge closer to the camera: larger x + y */
    var s = (nx + ny) > 0 ? 1 : -1;
    var ax = a.x + nx * s, ay = a.y + ny * s;
    var bx = b.x + nx * s, by = b.y + ny * s;
    var za = a.z || 0, zb = b.z || 0;
    ctx.fillStyle = '#a49c8c';
    Iso.poly(ctx, [
      P(ax, ay, za), P(bx, by, zb), P(bx, by, zb - thick), P(ax, ay, za - thick)
    ]);
  }

  function drawRoute(route, opts) {
    var width = opts.width, i, s;
    var elevated = false;
    for (i = 0; i < route.segs.length; i++) {
      if ((route.segs[i].a.z || 0) > 0.25) { elevated = true; break; }
    }

    /* soft ground shadow under an elevated deck */
    if (elevated) {
      ctx.fillStyle = 'rgba(90,88,78,0.16)';
      for (i = 0; i < route.segs.length; i++) {
        s = route.segs[i];
        Iso.ribbon(ctx, s.a.x + 0.5, s.a.y + 0.5, s.b.x + 0.5, s.b.y + 0.5, width, 0.02);
      }
    }

    if (elevated) {
      for (i = 0; i < route.segs.length; i++) {
        s = route.segs[i];
        if ((s.a.z || 0) > 0.25 || (s.b.z || 0) > 0.25) deckFascia(s.a, s.b, width, 0.34);
      }
    }

    ctx.fillStyle = opts.shoulder || C.road;
    for (i = 0; i < route.segs.length; i++) {
      s = route.segs[i];
      roadQuad(s.a, s.b, width + 0.5, 0);
      Iso.disc(ctx, s.a.x, s.a.y, s.a.z || 0, (width + 0.5) / 2);
    }
    var last = route.pts[route.pts.length - 1];
    Iso.disc(ctx, last.x, last.y, last.z || 0, (width + 0.5) / 2);

    ctx.fillStyle = opts.surface || C.roadTop;
    for (i = 0; i < route.segs.length; i++) {
      s = route.segs[i];
      roadQuad(s.a, s.b, width, 0.005);
      Iso.disc(ctx, s.a.x, s.a.y, (s.a.z || 0) + 0.005, width / 2);
    }
    Iso.disc(ctx, last.x, last.y, (last.z || 0) + 0.005, width / 2);

    /* centre dashes, so travel direction and distance are both legible */
    ctx.strokeStyle = opts.dash || 'rgba(96,90,78,0.35)';
    ctx.lineWidth = 1.3;
    ctx.setLineDash([6, 7]);
    ctx.beginPath();
    for (i = 0; i < route.pts.length; i++) {
      var p = P(route.pts[i].x, route.pts[i].y, (route.pts[i].z || 0) + 0.01);
      if (i === 0) ctx.moveTo(p.x, p.y); else ctx.lineTo(p.x, p.y);
    }
    ctx.stroke();
    ctx.setLineDash([]);
  }

  function drawPillars() {
    for (var i = 0; i < World.pillars.length; i++) {
      var p = World.pillars[i];
      var here = nearestOn(World.routes.back, p[0], p[1]);
      Iso.cylinder(ctx, { x: p[0], y: p[1], z: 0, r: 0.45, h: Math.max(0.4, here - 0.2), color: '#b3ab9a' });
    }
  }

  /* The deck height above a given point, so a pillar is exactly as tall as it
     needs to be rather than a guessed constant. */
  function nearestOn(route, x, y) {
    var best = 1e9, z = 0;
    for (var i = 0; i < route.segs.length; i++) {
      var s = route.segs[i];
      var vx = s.b.x - s.a.x, vy = s.b.y - s.a.y;
      var tt = ((x - s.a.x) * vx + (y - s.a.y) * vy) / (vx * vx + vy * vy);
      tt = Math.max(0, Math.min(1, tt));
      var d = Math.hypot(x - (s.a.x + vx * tt), y - (s.a.y + vy * tt));
      if (d < best) { best = d; z = (s.a.z || 0) + ((s.b.z || 0) - (s.a.z || 0)) * tt; }
    }
    return z;
  }

  function drawRoads() {
    drawRoute(World.routes.out, { width: 2.6 });
    drawRoute(World.routes.inland, { width: 2.2, surface: '#d2ccbd' });
    drawPillars();
    drawRoute(World.routes.back, { width: 2.4, surface: '#dcd2c4', dash: 'rgba(168,90,68,0.45)' });
  }

  /* ----------------------------------------------------------- landmarks  */

  /* One function per custom `kind` in world.js. Each takes the building record
     and draws in grid space; the sorted pass decides when. */

  function drawScreen(b) {
    Iso.box(ctx, { x: b.x - 0.9, y: b.y - 0.7, z: 0, w: 1.8, d: 1.4, h: 0.5, color: '#b9b2a2' });
    Iso.box(ctx, { x: b.x - 0.15, y: b.y - 0.1, z: 0.5, w: 0.3, d: 0.3, h: 0.7, color: '#8e8878' });
    /* the panel itself, standing up across the view */
    Iso.orientedBox(ctx, {
      x: b.x, y: b.y, z: 1.2, hx: 1, hy: -1, len: 2.6, wid: 0.18, h: 1.6,
      color: '#f4f1e6'
    });
    var lit = Sim.state.requests > 0;
    Iso.orientedBox(ctx, {
      x: b.x, y: b.y, z: 1.35, hx: 1, hy: -1, len: 2.2, wid: 0.06, h: 1.25,
      color: lit ? Iso.mix('#dfe9ef', b.color, 0.45) : '#cfd6d8', edge: false
    });
  }

  function drawDish(b) {
    Iso.cylinder(ctx, { x: b.x, y: b.y, z: 0, r: 0.4, h: 1.6, color: '#b6b0a0' });
    var p = P(b.x, b.y, 1.6);
    ctx.fillStyle = Iso.shade(b.color, 1.02);
    ctx.beginPath();
    ctx.ellipse(p.x, p.y - 10, 20, 11, -0.5, 0, 6.2832);
    ctx.fill();
    ctx.strokeStyle = 'rgba(74,69,64,0.4)';
    ctx.lineWidth = 1;
    ctx.stroke();
    ctx.fillStyle = Iso.rgba('#ffffff', 0.5);
    ctx.beginPath();
    ctx.ellipse(p.x - 3, p.y - 13, 7, 4, -0.5, 0, 6.2832);
    ctx.fill();
  }

  function drawGatePost(b) {
    Iso.box(ctx, { x: b.x - 0.28, y: b.y - 0.28, z: 0, w: 0.56, d: 0.56, h: 3.1, color: b.color });
  }

  function drawGateBeam(b) {
    Iso.box(ctx, { x: b.x - 0.3, y: b.y - 1.85, z: 3.1, w: 0.6, d: 3.7, h: 0.42, color: Iso.mix(b.color, '#ffffff', 0.25) });
  }

  /* The angle of a wall in screen space, and how long a grid unit is along it.
     Anything painted onto a face — a door, a dial, a sign — needs these, and
     guessing pixel offsets instead is how face decoration ends up floating
     next to the building rather than on it. */
  var FACE_ANG = Math.atan2(Iso.TH, Iso.TW);
  var FACE_U = Math.hypot(Iso.TW, Iso.TH);

  function drawVault(b) {
    Iso.box(ctx, { x: b.x - 2.2, y: b.y - 1.6, z: 0, w: 4.4, d: 3.2, h: 2.9, color: '#c7b6d0',
      panels: { cols: 5, seed: 4, color: '#e2d5ea' } });

    /* the round door, on the face the road runs past (+y, the left wall) */
    var p = P(b.x, b.y + 1.6, 1.45);
    var rx = 1.15 * FACE_U, ry = 1.3 * Iso.TZ;
    ctx.fillStyle = Iso.shade(b.color, 0.95);
    ctx.beginPath();
    ctx.ellipse(p.x, p.y, rx, ry, FACE_ANG, 0, 6.2832);
    ctx.fill();
    ctx.strokeStyle = 'rgba(60,52,64,0.5)';
    ctx.lineWidth = 1.4;
    ctx.stroke();

    /* spokes, turning only while the van is actually stopped here */
    var spin = Sim.state.station === 'secure' ? t * 1.1 : 0;
    ctx.save();
    ctx.translate(p.x, p.y);
    ctx.rotate(FACE_ANG);
    ctx.strokeStyle = 'rgba(60,52,64,0.55)';
    ctx.lineWidth = 1.8;
    for (var i = 0; i < 4; i++) {
      var a = spin + i * Math.PI / 4;
      ctx.beginPath();
      ctx.moveTo(-Math.cos(a) * rx * 0.72, -Math.sin(a) * ry * 0.72);
      ctx.lineTo(Math.cos(a) * rx * 0.72, Math.sin(a) * ry * 0.72);
      ctx.stroke();
    }
    ctx.fillStyle = 'rgba(255,255,255,0.6)';
    ctx.beginPath();
    ctx.ellipse(0, 0, rx * 0.22, ry * 0.22, 0, 0, 6.2832);
    ctx.fill();
    ctx.restore();
  }

  function drawStack(b) {
    Iso.cylinder(ctx, { x: b.x, y: b.y, z: 0, r: 0.7, h: 5.2, color: '#cbbfae', ring: 0.25 });
    /* a slow plume, because a running machine should look like it is running */
    var busy = Sim.state.station === 'origin';
    for (var i = 0; i < 4; i++) {
      var ph = (t * 0.35 + i * 0.25) % 1;
      var p = P(b.x, b.y, 5.2 + ph * 3.4);
      ctx.fillStyle = Iso.rgba('#ffffff', (busy ? 0.5 : 0.24) * (1 - ph));
      ctx.beginPath();
      ctx.arc(p.x - ph * 12, p.y, 5 + ph * 13, 0, 6.2832);
      ctx.fill();
    }
  }

  function drawDrums(b) {
    for (var i = 0; i < 6; i++) {
      var col = i % 3, row = (i / 3) | 0;
      Iso.cylinder(ctx, {
        x: b.x - 1.4 + col * 1.4, y: b.y - 0.7 + row * 1.4, z: 0,
        r: 0.62, h: 1.5 + (i % 2) * 0.4, color: i % 2 ? '#a8c0a2' : '#b6cdb0', ring: 0.4
      });
    }
    /* a query indicator: one lamp per query the model is charged for */
    var s = Sim.state;
    if (s.station === 'records') {
      var n = Math.min(12, s.dbQueries);
      for (var q = 0; q < n; q++) {
        var p = P(b.x - 1.6 + (q % 6) * 0.62, b.y + 1.5 + ((q / 6) | 0) * 0.5, 0.1);
        ctx.fillStyle = Iso.rgba(b.color, 0.35 + 0.45 * Math.abs(Math.sin(t * 3 + q)));
        ctx.beginPath();
        ctx.arc(p.x, p.y, 3.2, 0, 6.2832);
        ctx.fill();
      }
    }
  }

  function drawRooftop(o) {
    var m = 0.5;
    Iso.box(ctx, {
      x: o.x + m, y: o.y + m, z: o.z + o.h, w: Math.max(0.8, o.w - m * 2),
      d: Math.max(0.8, o.d - m * 2), h: 0.4, color: Iso.mix(o.rooftop, '#ffffff', 0.35)
    });
  }

  var KIND = {
    screen: drawScreen, dish: drawDish, gatePost: drawGatePost,
    gateBeam: drawGateBeam, vault: drawVault, stack: drawStack, drums: drawDrums
  };

  /* ----------------------------------------------------------- the cache  */

  function drawCacheDrum(i) {
    var p = World.cachePos(i);
    var pop = Sim.state.station === 'edge' ? 1 : 0;
    Iso.cylinder(ctx, {
      x: p.x, y: p.y, z: 0, r: 0.5, h: 1.1 + pop * 0.12,
      color: i % 2 ? '#8fbab6' : '#a3c7c3', ring: 0.35
    });
  }

  /* -------------------------------------------------------- small props  */

  function drawLamp(p) {
    Iso.cylinder(ctx, { x: p.x, y: p.y, z: 0, r: 0.13, h: 2.7, color: '#9c968a' });
    Iso.box(ctx, { x: p.x - 0.28, y: p.y - 0.22, z: 2.7, w: 0.56, d: 0.44, h: 0.18, color: '#c8c2b2' });
  }

  function drawTree(p) {
    var n = Iso.hash2(p.x, p.y, p.seed || 1);
    Iso.cylinder(ctx, { x: p.x, y: p.y, z: 0, r: 0.18, h: 0.9 + n * 0.4, color: '#8a7358' });
    var r = 0.85 + n * 0.5;
    ctx.fillStyle = n < 0.5 ? '#5f8a52' : '#6d9068';
    Iso.disc(ctx, p.x, p.y, 1.5 + n * 0.8, r);
    ctx.fillStyle = Iso.rgba('#ffffff', 0.16);
    Iso.disc(ctx, p.x - r * 0.25, p.y - r * 0.25, 1.62 + n * 0.8, r * 0.6);
  }

  /* --------------------------------------------------------------- the van
     The point of the vehicle is that it is carrying the state, not that it is
     a vehicle: the gauge on its flank is the millisecond budget spent so far,
     and the crates in the bed are the actual bytes on the wire. */

  function drawVan(v) {
    var s = Sim.state;
    var hx = v.dx, hy = v.dy;
    var z = v.z || 0;

    /* shadow on whatever surface it is driving on */
    ctx.fillStyle = 'rgba(80,76,66,0.22)';
    Iso.disc(ctx, v.x, v.y, z + 0.01, 1.05);

    Iso.orientedBox(ctx, { x: v.x, y: v.y, z: z + 0.16, hx: hx, hy: hy, len: 2.5, wid: 1.25, h: 0.34, color: '#5c6a72' });
    /* box body */
    Iso.orientedBox(ctx, { x: v.x - hx * 0.35, y: v.y - hy * 0.35, z: z + 0.5, hx: hx, hy: hy, len: 1.7, wid: 1.2, h: 1.0, color: '#eae6da' });
    /* cab */
    Iso.orientedBox(ctx, { x: v.x + hx * 0.85, y: v.y + hy * 0.85, z: z + 0.5, hx: hx, hy: hy, len: 0.85, wid: 1.1, h: 0.76, color: '#b8503f' });

    /* The gauge: how much of this trip's total the van has already spent.
       It goes on whichever flank faces the camera — in this projection both +x
       and +y lean toward it, so the side whose perpendicular has px + py > 0 is
       the visible one, and painting on the other is painting on the far wall. */
    var frac = s.plan && s.plan.total ? Math.min(1, s.elapsedMs / s.plan.total) : 0;
    var px = -hy, py = hx;
    var side = (px + py) > 0 ? 1 : -1;
    var gx = v.x - hx * 0.35 + px * side * 0.63;
    var gy = v.y - hy * 0.35 + py * side * 0.63;
    var GLEN = 1.5;
    Iso.orientedBox(ctx, {
      x: gx, y: gy, z: z + 0.72, hx: hx, hy: hy, len: GLEN, wid: 0.03, h: 0.42,
      color: '#6d675c', edge: false
    });
    if (frac > 0) {
      /* Grows from the rear of the van forward, so it fills toward the cab.
         The box is centred, hence the half-of-the-unfilled-part offset. */
      Iso.orientedBox(ctx, {
        x: gx - hx * (GLEN * (1 - frac) / 2), y: gy - hy * (GLEN * (1 - frac) / 2),
        z: z + 0.74, hx: hx, hy: hy, len: Math.max(0.07, GLEN * frac - 0.06),
        wid: 0.05, h: 0.34,
        color: frac > 0.66 ? '#e4643f' : frac > 0.33 ? '#e8b34a' : '#7fc06a', edge: false
      });
    }

    /* the cargo: one crate per 64 KB actually on the wire */
    if (s.cargoBytes > 0) {
      var crates = Math.max(1, Math.min(8, Math.round(s.cargoBytes / 65536)));
      for (var i = 0; i < crates; i++) {
        var row = i % 2, col = (i / 2) | 0;
        Iso.orientedBox(ctx, {
          x: v.x - hx * (0.9 - col * 0.42) + px * (row ? 0.28 : -0.28),
          y: v.y - hy * (0.9 - col * 0.42) + py * (row ? 0.28 : -0.28),
          z: z + 1.5, hx: hx, hy: hy, len: 0.38, wid: 0.4, h: 0.34,
          color: i % 3 === 0 ? '#c2913c' : i % 3 === 1 ? '#a8926a' : '#b8a577'
        });
      }
    }

    /* wheels */
    ctx.fillStyle = '#3f3a34';
    [[0.8, 0.5], [0.8, -0.5], [-0.8, 0.5], [-0.8, -0.5]].forEach(function (o) {
      Iso.disc(ctx, v.x + hx * o[0] + px * o[1], v.y + hy * o[0] + py * o[1], z + 0.14, 0.22);
    });
  }

  /* -------------------------------------------------------------- labels  */

  function drawLabels() {
    /* Screen space, but still dpr-scaled: cam.ox and cam.scale are in CSS
       pixels, so an identity transform would read them as device pixels and
       every plate would land at half its true position on a 2x display. */
    ctx.setTransform(cam.dpr, 0, 0, cam.dpr, 0, 0);
    ctx.textBaseline = 'middle';

    /* Measure every plate first, then place them, because placing needs to
       know what is already on screen. Highest priority is measured first and
       keeps its natural position; the rest give way. */
    labels.sort(function (a, b) { return (b.pri || 0) - (a.pri || 0); });

    var placed = [];
    var i;
    for (i = 0; i < labels.length; i++) {
      var L = labels[i];
      var p = P(L.x, L.y, L.z);
      L.ax = p.x * cam.scale + cam.ox;
      L.ay = p.y * cam.scale + cam.oy;

      /* Plates stay legible instead of shrinking with the town, so they are
         always somewhat oversized when zoomed out. */
      L.px = (L.size || 12) * Math.min(1.15, Math.max(0.92, cam.scale));
      ctx.font = (L.bold ? '600 ' : '') + L.px + 'px ' + fontOf(L);
      var wpx = ctx.measureText(L.text).width;
      var subw = L.sub ? ctx.measureText(L.sub).width * 0.85 : 0;
      L.boxW = Math.max(wpx, subw) + 16;
      L.boxH = L.sub ? L.px * 2.4 : L.px * 1.75;

      /* Because plates are oversized, one centred on its anchor swallows the
         landmark underneath it at low zoom. Sit it on its bottom edge instead,
         a constant gap above the anchor, which reads the same at every zoom. */
      L.sy = L.lift ? L.ay - L.lift - L.boxH / 2 : L.ay;

      /* Two plates on top of each other are worse than one plate slightly out
         of place, so nudge upward until this one is clear. Ten steps, then give
         up and draw it anyway — a stuck loop is worse than an overlap. */
      for (var tries = 0; tries < 10 && overlaps(L, placed); tries++) {
        L.sy -= L.boxH * 0.92;
      }
      placed.push(L);
    }

    for (i = 0; i < labels.length; i++) drawPlate(labels[i]);
  }

  function fontOf(L) {
    return L.mono
      ? 'ui-monospace, Menlo, Consolas, monospace'
      : '"Iowan Old Style", Palatino, "Palatino Linotype", Georgia, serif';
  }

  function overlaps(L, placed) {
    for (var i = 0; i < placed.length; i++) {
      var o = placed[i];
      if (Math.abs(L.ax - o.ax) < (L.boxW + o.boxW) / 2 + 2 &&
          Math.abs(L.sy - o.sy) < (L.boxH + o.boxH) / 2 + 2) return true;
    }
    return false;
  }

  function drawPlate(L) {
    var ax = L.ax, ay = L.ay, sy = L.sy, size = L.px;
    var boxW = L.boxW, boxH = L.boxH;
    ctx.textAlign = 'center';
    ctx.font = (L.bold ? '600 ' : '') + size + 'px ' + fontOf(L);

    /* A leader down to the anchor, so a plate that had to be nudged out of the
       way is still visibly attached to the thing it names. */
    if (L.lift) {
      ctx.strokeStyle = Iso.rgba(L.tint || '#6e6250', 0.6);
      ctx.lineWidth = 1.2;
      ctx.beginPath();
      ctx.moveTo(ax, sy + boxH / 2);
      ctx.lineTo(ax, ay);
      ctx.stroke();
      ctx.fillStyle = Iso.rgba(L.tint || '#6e6250', 0.85);
      ctx.beginPath();
      ctx.arc(ax, ay, 2.4, 0, 6.2832);
      ctx.fill();
    }

    /* a drop shadow lifts the plate off pale roofs and grass alike */
    ctx.fillStyle = 'rgba(96,84,66,0.26)';
    roundRect(ax - boxW / 2 + 1, sy - boxH / 2 + 2.5, boxW, boxH, 5);
    ctx.fill();

    /* Washed with the district's own colour rather than plain white, so a
       plate reads as belonging to the building it points at. */
    ctx.fillStyle = L.tint ? Iso.mix('#fffdf7', L.tint, 0.14) : '#fffdf7';
    roundRect(ax - boxW / 2, sy - boxH / 2, boxW, boxH, 5);
    ctx.fill();
    ctx.strokeStyle = Iso.rgba(L.tint || '#6e6250', 0.85);
    ctx.lineWidth = L.bold ? 1.7 : 1.2;
    roundRect(ax - boxW / 2, sy - boxH / 2, boxW, boxH, 5);
    ctx.stroke();

    ctx.fillStyle = L.color || '#3a352e';
    ctx.fillText(L.text, ax, sy + (L.sub ? -size * 0.42 : 0));
    if (L.sub) {
      ctx.font = (size * 0.85) + 'px ui-monospace, Menlo, Consolas, monospace';
      ctx.fillStyle = 'rgba(88,80,68,0.75)';
      ctx.fillText(L.sub, ax, sy + size * 0.62);
    }
  }

  function roundRect(x, y, w, h, r) {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.arcTo(x + w, y, x + w, y + h, r);
    ctx.arcTo(x + w, y + h, x, y + h, r);
    ctx.arcTo(x, y + h, x, y, r);
    ctx.arcTo(x, y, x + w, y, r);
    ctx.closePath();
  }

  /* ---------------------------------------------------------------- draw  */

  /* Depth key. A box's visual depth is its near corner, not its origin, hence
     the half-footprint term; anything drawn from its centre uses x + y. */
  function key(o) { return o.x + o.y + ((o.w || 0) + (o.d || 0)) * 0.5; }

  function draw(canvas, camera, time, activeDistrict, hoverDistrict) {
    ctx = canvas.getContext('2d');
    cam = camera;
    t = time;
    labels.length = 0;

    var w = canvas.width / cam.dpr, h = canvas.height / cam.dpr;
    ctx.setTransform(cam.dpr, 0, 0, cam.dpr, 0, 0);
    drawSky(w, h);

    ctx.setTransform(cam.scale * cam.dpr, 0, 0, cam.scale * cam.dpr,
                     cam.ox * cam.dpr, cam.oy * cam.dpr);

    drawGround();
    drawZones(activeDistrict);
    drawRoads();

    /* ---- one sorted pass over everything with a footprint ---- */
    var items = [];
    var i, s = Sim.state;

    for (i = 0; i < World.buildings.length; i++) {
      var b = World.buildings[i];
      if (b.kind && KIND[b.kind]) items.push({ k: b.x + b.y, f: KIND[b.kind], a: b });
      else items.push({ k: key(b), f: null, a: b });
    }
    for (i = 0; i < World.props.length; i++) {
      var pr = World.props[i];
      items.push({ k: pr.x + pr.y, f: pr.kind === 'tree' ? drawTree : drawLamp, a: pr });
    }
    for (i = 0; i < s.cachedObjects; i++) {
      var cp = World.cachePos(i);
      items.push({ k: cp.x + cp.y, f: drawCacheDrum, a: i });
    }
    var v = Sim.vanPosition();
    items.push({ k: v.x + v.y + 0.2, f: drawVan, a: v });

    items.sort(function (p, q) { return p.k - q.k; });
    for (i = 0; i < items.length; i++) {
      if (items[i].f) { items[i].f(items[i].a); continue; }
      var o = items[i].a;
      Iso.box(ctx, o);
      if (o.roof) {
        Iso.gableRoof(ctx, {
          x: o.x - 0.08, y: o.y - 0.08, z: o.z + o.h,
          w: o.w + 0.16, d: o.d + 0.16, h: o.roofH || 0.45, color: o.roof
        });
      } else if (o.rooftop) {
        drawRooftop(o);
      }
    }

    /* ---- district plates -------------------------------------------------
       Zoomed far out (where a phone starts) every plate at once is an
       unreadable pile, so show only the live one. */
    if (showLabels) {
      var declutter = cam.scale < 0.34;
      for (i = 0; i < World.districts.length; i++) {
        var d = World.districts[i];
        var isActive = d.id === activeDistrict || d.id === hoverDistrict;
        if (declutter && !isActive) continue;
        /* Once a station has been paid for, its plate carries the price. That
           is the number the reader came for, so it outranks the tagline. */
        var sub = isActive ? d.tag : null;
        if (s.charged && s.charged[d.id] != null) sub = '+' + Net.fmtMs(s.charged[d.id]);
        if (d.id === 'edge' && s.cachedObjects) {
          sub = (sub ? sub + ' · ' : '') + s.cachedObjects + ' cached';
        }
        labels.push({
          x: d.x, y: d.y, z: 0, lift: isActive ? 34 : 26,
          text: d.name, sub: sub,
          color: isActive ? d.color : '#3d3831',
          tint: d.color,
          size: isActive ? 16.5 : 14, bold: isActive,
          pri: isActive ? 2 : 1
        });
      }
    }

    /* The running total, riding above the van. Highest priority: it is the one
       number that changes every frame, so it keeps its place and the static
       plates move out of its way. */
    if (s.running) {
      labels.push({
        x: v.x, y: v.y, z: (v.z || 0) + 2.4, lift: 8,
        text: Net.fmtMs(s.elapsedMs),
        sub: s.cargoBytes ? Net.fmtBytes(s.cargoBytes) + ' aboard' : 'empty',
        color: '#3d3831', tint: '#8a8272', size: 14, bold: true, mono: true,
        pri: 3
      });
    }

    drawLabels();
  }

  global.Renderer = {
    draw: draw,
    setLabels: function (v) { showLabels = v; }
  };
})(window);
