// The weather channel's four screens, drawn on a 1920 x 1080 canvas (Trello I-016).
//
// Everything is drawn: no DOM, no images of ours. The numbers below are the layout the Apple TV, Roku and
// Android ports copy: coordinates are for a 1920 x 1080 picture, type sizes are in the same points the
// Apple TV uses (DM Mono 25 / 29 / 34 / 44, VT323 for the big digits), colours are the app's.
//
//   CURRENT CONDITIONS   an icon and the temperature on the left, six rows of detail on the right
//   TODAY'S FORECAST     four cards, the next four six-hour periods
//   5-DAY FORECAST       five cards, a high and a low each
//   RADAR                a drawn map (coastlines, lakes, borders) with the radar frames looping over it
//
// Fonts: DM Mono (Regular and Medium) and VT323. The page loads them before the first draw.
// GUIDE TEXT SIZE: `state.textScale` (1 NORMAL, 1.16 LARGE, the Apple TV's 25 to 29 step) grows the text and
// never the layout.
//
// USAGE
//   NostalgexWeatherScreens.render(ctx, state)
//   state: { nowMs, place, units, textScale, status: 'noplace' | 'loading' | 'error' | 'ready', model,
//            updatedMs, stale, screen?, radar: { status: 'none' | 'loading' | 'error' | 'ready', provider,
//            frames: [{ timeMs, canvas }], base } }
(function (global) {
  'use strict';

  const W = 1920;
  const H = 1080;
  const SAFE_X = 90;
  const SAFE_Y = 56;

  // The app's colours (DesignTokens.swift) and the brief's five.
  const C = {
    bg0: '#0A0A1A', bg1: '#0D0D20',
    panel: '#0A0F1E', row: '#141B33', outline: '#3A4670',
    text: '#FFFFFF', text2: '#B9C3DE', dim: '#80879A',
    cyan: '#00D4FF', yellow: '#FFE500', pink: '#FF2DB4', red: '#FF2244', amber: '#FFB020',
  };
  const ACCENT = { current: C.cyan, today: C.yellow, week: C.pink, radar: C.amber };

  const mono = (px, weight) => `${weight || 400} ${Math.round(px)}px "DM Mono", ui-monospace, Menlo, monospace`;
  const pixel = (px) => `${Math.round(px)}px "VT323", ui-monospace, Menlo, monospace`;

  // ── Icons: 18 pixel pictures on a 24 x 24 grid ─────────────────────────────
  // Letters: . clear, Y yellow, y amber, M moon, W/w/g cloud light/mid/shadow, C cyan, c deep cyan, S snow.
  const ICON_COLORS = { Y: '#FFE500', y: '#FFB020', M: '#FFF1A8', W: '#EAF0FF', w: '#B9C3DE', g: '#7A86AD', C: '#00D4FF', c: '#0A9FCC', S: '#FFFFFF' };
  const blank = () => Array.from({ length: 24 }, () => Array(24).fill('.'));
  const put = (g, x, y, ch) => { x = Math.round(x); y = Math.round(y); if (x >= 0 && x < 24 && y >= 0 && y < 24) g[y][x] = ch; };
  function disk(g, cx, cy, r, ch) {
    for (let y = 0; y < 24; y++) for (let x = 0; x < 24; x++) {
      if ((x + 0.5 - cx) ** 2 + (y + 0.5 - cy) ** 2 <= r * r) g[y][x] = ch;
    }
  }
  function sun(g, cx, cy, r, rays) {
    disk(g, cx, cy, r, 'Y');
    for (let k = 0; k < 8; k++) {
      const a = k * Math.PI / 4;
      const diag = k % 2 === 1;
      for (let d = r + 1.4; d <= r + (rays || 2.6); d += 0.5) put(g, cx - 0.5 + Math.cos(a) * d, cy - 0.5 + Math.sin(a) * d, diag ? 'y' : 'Y');
    }
  }
  function moon(g, cx, cy, r) {
    const m = blank();
    disk(m, cx, cy, r, 'M');
    disk(m, cx + r * 0.62, cy - r * 0.5, r * 0.82, '.');
    for (let y = 0; y < 24; y++) for (let x = 0; x < 24; x++) if (m[y][x] !== '.') g[y][x] = m[y][x];
  }
  // A cloud: a high round top, two lower shoulders and a flat base, lit from above (light, mid, shadow by row).
  function cloud(g, ox, oy, s, flat) {
    const m = blank();
    const circles = [[10, 6.4, 5.2], [5.2, 9.2, 3.6], [15.6, 8.6, 4.3], [18.8, 10.2, 2.6], [2.8, 10.2, 2.4]];
    for (const [cx, cy, r] of circles) disk(m, cx * s + ox, cy * s + oy, r * s, 'x');
    for (let y = Math.round(9.4 * s + oy); y <= Math.round(13 * s + oy) - 1; y++) for (let x = Math.round(2.8 * s + ox); x <= Math.round(19.8 * s + ox); x++) put(m, x, y, 'x');
    let top = 99, bottom = -1;
    for (let y = 0; y < 24; y++) for (let x = 0; x < 24; x++) if (m[y][x] === 'x') { top = Math.min(top, y); bottom = Math.max(bottom, y); }
    for (let y = 0; y < 24; y++) for (let x = 0; x < 24; x++) {
      if (m[y][x] !== 'x') continue;
      const t = (y - top) / Math.max(1, bottom - top);
      g[y][x] = flat === 'back' ? 'g' : flat ? (t < 0.5 ? 'w' : 'g') : (t < 0.45 ? 'W' : t < 0.8 ? 'w' : 'g');
    }
  }
  const drops = (g, xs, y0, len, ch, slant) => { for (const x of xs) for (let i = 0; i < len; i++) put(g, x + (slant ? Math.floor(i / 2) * -1 : 0), y0 + i, ch); };
  const flake = (g, x, y) => { put(g, x, y, 'S'); put(g, x - 1, y, 'S'); put(g, x + 1, y, 'S'); put(g, x, y - 1, 'S'); put(g, x, y + 1, 'S'); };

  const MAKERS = {
    'sun': (g) => sun(g, 12, 12, 5.2, 3.2),
    'moon': (g) => { moon(g, 12, 12, 7.4); put(g, 4, 5, 'W'); put(g, 19, 4, 'W'); put(g, 20, 17, 'W'); put(g, 3, 17, 'w'); },
    'fair-day': (g) => { sun(g, 9, 9, 3.6, 2.4); cloud(g, 9.5, 12, 0.62); },
    'fair-night': (g) => { moon(g, 9, 9, 5); cloud(g, 9.5, 12, 0.62); },
    'partly-day': (g) => { sun(g, 8, 8, 3.8, 2.4); cloud(g, 3, 9, 0.95); },
    'partly-night': (g) => { moon(g, 8, 8, 5.2); cloud(g, 3, 9, 0.95); },
    'cloud': (g) => { cloud(g, 9.5, 3, 0.62, 'back'); cloud(g, 1.2, 8, 1); },
    'fog': (g) => {
      cloud(g, 2.5, 1.5, 0.9);
      for (let x = 3; x <= 20; x++) put(g, x, 15, 'w');
      for (let x = 6; x <= 22; x++) put(g, x, 18, 'g');
      for (let x = 3; x <= 17; x++) put(g, x, 21, 'w');
    },
    'drizzle': (g) => { cloud(g, 2, 1.5, 0.95); drops(g, [8, 12, 16], 15, 2, 'C'); drops(g, [10, 14], 19, 2, 'c'); },
    'rain': (g) => { cloud(g, 2, 1.5, 0.95); drops(g, [6, 10, 14, 18], 15, 3, 'C', true); drops(g, [8, 12, 16], 19, 2, 'c', true); },
    'heavy-rain': (g) => { cloud(g, 2, 1.5, 0.95, true); drops(g, [5, 8, 11, 14, 17, 20], 14, 3, 'C', true); drops(g, [6, 9, 12, 15, 18], 18, 3, 'c', true); },
    'showers-day': (g) => { sun(g, 17, 6, 3, 2); cloud(g, 1, 4, 0.95); drops(g, [7, 11, 15], 16, 3, 'C', true); },
    'showers-night': (g) => { moon(g, 17, 6, 4.2); cloud(g, 1, 4, 0.95); drops(g, [7, 11, 15], 16, 3, 'C', true); },
    'sleet': (g) => { cloud(g, 2, 1.5, 0.95); drops(g, [6, 14], 15, 3, 'C', true); put(g, 10, 16, 'S'); put(g, 10, 19, 'S'); put(g, 18, 17, 'S'); put(g, 8, 21, 'S'); put(g, 16, 21, 'S'); },
    'snow': (g) => { cloud(g, 2, 1.5, 0.95); flake(g, 6, 17); flake(g, 12, 20); flake(g, 18, 17); },
    'flurries-day': (g) => { sun(g, 17, 6, 3, 2); cloud(g, 1, 4, 0.95); flake(g, 7, 18); flake(g, 14, 20); },
    'flurries-night': (g) => { moon(g, 17, 6, 4.2); cloud(g, 1, 4, 0.95); flake(g, 7, 18); flake(g, 14, 20); },
    'thunder': (g) => {
      cloud(g, 2, 1, 0.95, true);
      for (const [x, y] of [[13, 13], [14, 13], [12, 14], [13, 14], [11, 15], [12, 15], [10, 16], [11, 16], [12, 16], [13, 16], [12, 17], [13, 17], [11, 18], [12, 18], [11, 19], [10, 20], [10, 21]]) put(g, x, y, 'Y');
      drops(g, [6, 18], 16, 3, 'C', true);
    },
  };
  const ICON_GRIDS = {};
  for (const name of Object.keys(MAKERS)) {
    const g = blank();
    MAKERS[name](g);
    ICON_GRIDS[name] = g.map((row) => row.join(''));
  }
  // Icon slots and cell sizes (Chad, 2026-11-16: "all like 15% smaller"). A slot is the square the icon used to fill, a cell is one pixel of
  // the 24 x 24 picture; the icon is drawn in whole-pixel cells and centred in its slot, so nothing around it moves.
  //   screen          slot   cell was  cell now   drawn size now
  //   CURRENT         336    14        12         288 (86% of 336)
  //   TODAY periods   192     8         7         168 (88% of 192)
  //   5-DAY days      168     7         6         144 (86% of 168)
  const ICON = { current: { slot: 336, cell: 12 }, today: { slot: 192, cell: 7 }, week: { slot: 168, cell: 6 } };
  /** Draws an icon in the square slot at (x, y), `size` pixels, in whole-pixel cells of `cell` pixels (default: the slot filled), centred. */
  function drawIcon(ctx, name, x, y, size, cellSize) {
    const grid = ICON_GRIDS[name] || ICON_GRIDS.cloud;
    const cell = cellSize || Math.max(1, Math.round(size / 24));
    const ox = Math.round(x + (size - cell * 24) / 2);
    const oy = Math.round(y + (size - cell * 24) / 2);
    for (let r = 0; r < 24; r++) {
      for (let c = 0; c < 24; c++) {
        const ch = grid[r][c];
        if (ch === '.') continue;
        ctx.fillStyle = ICON_COLORS[ch];
        ctx.fillRect(ox + c * cell, oy + r * cell, cell, cell);
      }
    }
  }

  // ── Text ───────────────────────────────────────────────────────────────────
  function text(ctx, str, x, y, font, color, align, maxWidth) {
    ctx.font = font;
    ctx.fillStyle = color;
    ctx.textAlign = align || 'left';
    ctx.textBaseline = 'alphabetic';
    if (maxWidth) ctx.fillText(str, x, y, maxWidth); else ctx.fillText(str, x, y);
  }
  function measure(ctx, str, font) { ctx.font = font; return ctx.measureText(str).width; }
  /** Words wrapped to `maxWidth`, at most `maxLines` lines (the last one is shortened with a dot if it still overflows). */
  function wrap(ctx, str, font, maxWidth, maxLines) {
    ctx.font = font;
    const words = String(str).split(' ');
    const lines = [];
    let line = '';
    for (const w of words) {
      const t = line ? `${line} ${w}` : w;
      if (ctx.measureText(t).width <= maxWidth || !line) line = t;
      else { lines.push(line); line = w; }
    }
    if (line) lines.push(line);
    return lines.slice(0, maxLines);
  }
  /**
   * A big temperature in VT323 with a drawn degree ring (the font's own degree sign floats away from its
   * digits at this size). Returns the right edge of what it drew.
   */
  function bigTemp(ctx, value, x, baseline, size, color, align, unit) {
    const font = pixel(size);
    const dw = measure(ctx, value, font);
    const ring = Math.round(size * 0.125);
    const gap = Math.round(size * 0.03);
    const ufont = pixel(size * 0.42);
    const uw = unit ? measure(ctx, unit, ufont) + gap : 0;
    const total = dw + gap + ring + uw;
    const left = align === 'center' ? x - total / 2 : align === 'right' ? x - total : x;
    text(ctx, value, left, baseline, font, color, 'left');
    const rx = Math.round(left + dw + gap);
    const ry = Math.round(baseline - size * 0.6);
    const t = Math.max(2, Math.round(size * 0.035));
    ctx.fillStyle = color;
    ctx.fillRect(rx, ry, ring, t);
    ctx.fillRect(rx, ry + ring - t, ring, t);
    ctx.fillRect(rx, ry, t, ring);
    ctx.fillRect(rx + ring - t, ry, t, ring);
    if (unit) text(ctx, unit, rx + ring + gap, baseline - size * 0.2, ufont, color, 'left');
    return left + total;
  }
  function roundRect(ctx, x, y, w, h, r) {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.arcTo(x + w, y, x + w, y + h, r);
    ctx.arcTo(x + w, y + h, x, y + h, r);
    ctx.arcTo(x, y + h, x, y, r);
    ctx.arcTo(x, y, x + w, y, r);
    ctx.closePath();
  }
  function card(ctx, x, y, w, h, accent) {
    roundRect(ctx, x, y, w, h, 12);
    ctx.fillStyle = C.row;
    ctx.fill();
    ctx.lineWidth = 1.5;
    ctx.strokeStyle = C.outline;
    ctx.stroke();
    if (accent) { ctx.fillStyle = accent; ctx.fillRect(x + 12, y, w - 24, 8); }
  }

  // ── Frame: the header strip and the footer ─────────────────────────────────
  function background(ctx) {
    const g = ctx.createLinearGradient(0, 0, W, H);
    g.addColorStop(0, C.bg0);
    g.addColorStop(1, C.bg1);
    ctx.fillStyle = g;
    ctx.fillRect(0, 0, W, H);
  }
  function header(ctx, st, title, accent) {
    const x = SAFE_X, y = SAFE_Y, w = W - 2 * SAFE_X, h = 76;
    roundRect(ctx, x, y, w, h, 12);
    ctx.fillStyle = C.panel;
    ctx.fill();
    ctx.lineWidth = 1.5;
    ctx.strokeStyle = C.outline;
    ctx.stroke();
    ctx.fillStyle = accent;
    ctx.fillRect(x, y + 12, 10, h - 24);
    const blink = Math.floor(st.nowMs / 1000) % 2 === 0;
    text(ctx, blink ? '●' : '○', x + 34, y + 52, pixel(40), C.cyan, 'left');
    text(ctx, `CH ${st.channelNumber || NW().CHANNEL_NUMBER}`, x + 72, y + 51, pixel(40), C.cyan, 'left');
    text(ctx, title, x + 190, y + 51, mono(40, 500), C.text, 'left');
    // Right: the place and the local time.
    const tz = st.place && st.place.tz ? st.place.tz : null;
    const clock = tz && global.NostalgexWeather ? global.NostalgexWeather.fmtClock(st.nowMs, tz) : '';
    const place = st.place ? placeTitle(st.place) : '';
    const clockW = clock ? measure(ctx, clock, pixel(44)) + 28 : 0;
    const maxPlace = Math.max(200, w - 190 - measure(ctx, title, mono(40, 500)) - 80 - clockW);
    if (clock) text(ctx, clock, x + w - 24, y + 52, pixel(44), C.yellow, 'right');
    if (place) text(ctx, place, x + w - 24 - clockW, y + 50, mono(Math.round(30 * Math.min(1, st.textScale || 1)), 500), C.text, 'right', maxPlace);
  }
  function placeTitle(p) {
    const base = String(p.name || '').toUpperCase();
    const region = p.region && p.cc && (p.cc === 'US' || p.cc === 'CA' || p.cc === 'AU') ? `, ${String(p.region).toUpperCase()}` : (p.cc ? `, ${String(p.cc).toUpperCase()}` : '');
    return base + region;
  }
  // The credits and the age of the forecast: one small stack at the bottom left, the least prominent thing on any screen (Chad,
  // 2026-11-16). 16 px at 1080 (60% of the 25 px it was; 16 is the floor for attribution to stay legible across a room), the app's text2
  // at 70% (about 5.5:1 on the screen's navy), lines 22 px apart, the last line's baseline on the safe area's bottom edge. Top to bottom:
  // the radar source's credit (radar screen only), DATA FROM MET NORWAY, UPDATED hh:mm. The credits are required by MET, NOAA, ECCC and
  // DWD: smaller, never hidden. An old forecast says so in amber, in the same size.
  const FOOTER = { size: 16, lineHeight: 22, x: SAFE_X, baseline: H - SAFE_Y - 6, color: 'rgba(185,195,222,0.7)' };
  function footer(ctx, st, screenIds, screenIndex, extraCredit) {
    const lines = [];
    if (extraCredit) lines.push([extraCredit, FOOTER.color]);
    lines.push(['DATA FROM MET NORWAY', FOOTER.color]);
    if (st.updatedMs && global.NostalgexWeather && st.place) {
      const age = global.NostalgexWeather.forecastAge(st.updatedMs, st.nowMs, st.place.tz);
      lines.push([age.stale ? `OLD FORECAST FROM ${age.text.replace('UPDATED ', '')}` : age.text, age.stale ? C.amber : FOOTER.color]);
    }
    lines.forEach(([t, color], i) => text(ctx, t, FOOTER.x, FOOTER.baseline - (lines.length - 1 - i) * FOOTER.lineHeight, mono(FOOTER.size), color, 'left'));
    // The loop's pips, bottom right.
    // One pip per screen of the loop that is playing: three where the place has no radar.
    const ids = screenIds;
    const pips = ids.length;
    const pw = 44, gap = 10;
    let px = W - SAFE_X - (pips * pw + (pips - 1) * gap);
    for (let i = 0; i < pips; i++) {
      ctx.fillStyle = i === screenIndex ? ACCENT[ids[i]] : C.outline;
      ctx.fillRect(px, FOOTER.baseline - 12, pw, 10);
      px += pw + gap;
    }
  }

  // ── Cards without data ─────────────────────────────────────────────────────
  function message(ctx, title, sub, color) {
    const w = 1300, h = 340, x = (W - w) / 2, y = 300;
    card(ctx, x, y, w, h, color);
    const lines = wrap(ctx, title, mono(56, 500), w - 120, 2);
    let ty = y + 130 - (lines.length - 1) * 34;
    for (const l of lines) { text(ctx, l, W / 2, ty, mono(56, 500), color, 'center'); ty += 70; }
    if (sub) {
      const subLines = wrap(ctx, sub, mono(29), w - 140, 2);
      let sy = y + h - 80 - (subLines.length - 1) * 20;
      for (const l of subLines) { text(ctx, l, W / 2, sy, mono(29), C.text2, 'center'); sy += 42; }
    }
  }

  // ── The four screens ───────────────────────────────────────────────────────
  const CARD_TOP = 172;
  const CARD_H = 770;
  const NW = () => global.NostalgexWeather;

  function screenCurrent(ctx, st) {
    const M = NW();
    const s = st.textScale || 1;
    const cur = st.model.current;
    const u = st.units;
    const info = M.symbolInfo(cur.symbol);
    // Left panel: the icon, the temperature, the condition.
    const lx = SAFE_X, lw = 860;
    card(ctx, lx, CARD_TOP, lw, CARD_H, C.cyan);
    drawIcon(ctx, info.icon, lx + 44, CARD_TOP + 80, ICON.current.slot, ICON.current.cell);
    const temp = M.fmtTemp(cur.tempC, u);
    bigTemp(ctx, temp, lx + 400, CARD_TOP + 380, 340, C.text, 'left', u);
    const condLines = wrap(ctx, info.text, mono(44 * s, 500), lw - 80, 2);
    let cy = CARD_TOP + 540;
    for (const l of condLines) { text(ctx, l, lx + 40, cy, mono(44 * s, 500), C.cyan, 'left'); cy += 56 * s; }
    text(ctx, `FEELS LIKE ${M.fmtTemp(cur.feelsC, u)}°`, lx + 40, Math.max(cy + 14, CARD_TOP + 650), mono(34 * s, 500), C.text, 'left');
    text(ctx, `AS OF ${M.fmtClock(cur.timeMs, st.place.tz)}`, lx + 40, CARD_TOP + CARD_H - 44, mono(25 * s), C.text2, 'left');

    // Right: rows, the app's row spec (76 high, 12 radius, the resting outline).
    const rows = [
      ['WIND', `${M.compass(cur.windDir)} ${M.fmtWind(cur.windMs, u)}`.trim()],
      ['HUMIDITY', cur.humidity == null ? '--' : `${cur.humidity}%`],
      ['DEW POINT', `${M.fmtTemp(cur.dewC, u)}°`],
      ['PRESSURE', M.fmtPressure(cur.pressureHpa, u)],
      ['CLOUD COVER', cur.cloud == null ? '--' : `${cur.cloud}%`],
      cur.uv == null ? null : ['UV INDEX', String(cur.uv)],
      ['NEXT HOUR', cur.precipNextHourMm == null ? '--' : M.fmtPrecip(cur.precipNextHourMm, u)],
    ].filter(Boolean);
    const rx = lx + lw + 30, rw = W - SAFE_X - rx;
    const rowH = 88, gap = 14;
    const total = rows.length * rowH + (rows.length - 1) * gap;
    let ry = CARD_TOP + (CARD_H - total) / 2;
    for (const [label, value] of rows) {
      roundRect(ctx, rx, ry, rw, rowH, 12);
      ctx.fillStyle = C.row; ctx.fill();
      ctx.lineWidth = 1.5; ctx.strokeStyle = C.outline; ctx.stroke();
      text(ctx, label, rx + 28, ry + 56, mono(29 * s), C.text2, 'left');
      text(ctx, value, rx + rw - 28, ry + 56, mono(34 * s, 500), C.text, 'right', rw - 56 - measure(ctx, label, mono(29 * s)) - 20);
      ry += rowH + gap;
    }
  }

  function screenToday(ctx, st) {
    const M = NW();
    const s = st.textScale || 1;
    const u = st.units;
    const n = Math.max(1, st.model.periods.length);
    const gap = 30;
    const cw = (W - 2 * SAFE_X - (n - 1) * gap) / n;
    st.model.periods.forEach((p, i) => {
      const x = SAFE_X + i * (cw + gap);
      const info = M.symbolInfo(p.symbol);
      card(ctx, x, CARD_TOP, cw, CARD_H, C.yellow);
      const cx = x + cw / 2;
      text(ctx, p.name, cx, CARD_TOP + 76, mono(38 * s, 500), C.text, 'center', cw - 30);
      text(ctx, p.day, cx, CARD_TOP + 118, mono(25 * s), C.text2, 'center');
      drawIcon(ctx, info.icon, cx - ICON.today.slot / 2, CARD_TOP + 148, ICON.today.slot, ICON.today.cell);
      bigTemp(ctx, M.fmtTemp(p.tempC, u), cx, CARD_TOP + 520, 200, C.text, 'center');
      const lines = wrap(ctx, info.text, mono(29 * s, 500), cw - 40, 2);
      let ty = CARD_TOP + 590;
      for (const l of lines) { text(ctx, l, cx, ty, mono(29 * s, 500), C.cyan, 'center'); ty += 38 * s; }
      text(ctx, `WIND ${M.compass(p.windDir)} ${M.fmtWind(p.windMs, u)}`.replace(/\s+/g, ' '), cx, CARD_TOP + CARD_H - 84, mono(25 * s), C.text2, 'center', cw - 24);
      text(ctx, `PRECIP ${M.fmtPrecip(p.precipMm, u)}`, cx, CARD_TOP + CARD_H - 40, mono(25 * s), p.precipMm > 0 ? C.yellow : C.text2, 'center', cw - 24);
    });
  }

  function screenWeek(ctx, st) {
    const M = NW();
    const s = st.textScale || 1;
    const u = st.units;
    const n = Math.max(1, st.model.days.length);
    const gap = 24;
    const cw = (W - 2 * SAFE_X - (n - 1) * gap) / n;
    st.model.days.forEach((d, i) => {
      const x = SAFE_X + i * (cw + gap);
      const info = M.symbolInfo(d.symbol);
      card(ctx, x, CARD_TOP, cw, CARD_H, C.pink);
      const cx = x + cw / 2;
      text(ctx, d.label, cx, CARD_TOP + 78, mono(40 * s, 500), C.text, 'center');
      drawIcon(ctx, info.icon, cx - ICON.week.slot / 2, CARD_TOP + 104, ICON.week.slot, ICON.week.cell);
      text(ctx, 'HIGH', cx, CARD_TOP + 336, mono(25 * s), C.text2, 'center');
      bigTemp(ctx, M.fmtTemp(d.highC, u), cx, CARD_TOP + 440, 150, C.text, 'center');
      text(ctx, 'LOW', cx, CARD_TOP + 486, mono(25 * s), C.text2, 'center');
      bigTemp(ctx, M.fmtTemp(d.lowC, u), cx, CARD_TOP + 566, 100, C.cyan, 'center');
      const lines = wrap(ctx, info.text, mono(25 * s, 500), cw - 32, 2);
      let ty = CARD_TOP + 630;
      for (const l of lines) { text(ctx, l, cx, ty, mono(25 * s, 500), C.cyan, 'center'); ty += 34 * s; }
      text(ctx, d.precipMm > 0 ? M.fmtPrecip(d.precipMm, u) : 'DRY', cx, CARD_TOP + CARD_H - 36, mono(25 * s), d.precipMm > 0 ? C.yellow : C.text2, 'center');
    });
  }

  // ── Radar ──────────────────────────────────────────────────────────────────
  const MAP = { x: SAFE_X, y: CARD_TOP, w: W - 2 * SAFE_X, h: 700 };
  /** The aspect the map window is asked for. */
  const MAP_ASPECT = MAP.w / MAP.h;
  const FRAME_MS = 450;
  const HOLD_MS = 1500;

  /**
   * The basemap, decoded and cut to one window: [{ layer, pts: Float32Array [lon, lat, ...] }] and the nearby cities.
   * The page calls it when the place or the window changes, not on every draw.
   */
  function prepareBasemap(basemap, bbox) {
    if (!basemap || !basemap.layers) return null;
    const unit = basemap.unit || 1000;
    const [minLon, minLat, maxLon, maxLat] = bbox;
    const padLon = (maxLon - minLon) * 0.05, padLat = (maxLat - minLat) * 0.05;
    const lines = [];
    for (const layer of ['lakes', 'states', 'borders', 'coast']) {
      for (const flat of basemap.layers[layer] || []) {
        const pts = [];
        let x = flat[0], y = flat[1];
        let inside = false;
        const push = () => {
          pts.push(x / unit, y / unit);
          const lo = x / unit, la = y / unit;
          if (lo >= minLon - padLon && lo <= maxLon + padLon && la >= minLat - padLat && la <= maxLat + padLat) inside = true;
        };
        push();
        for (let i = 2; i < flat.length; i += 2) { x += flat[i]; y += flat[i + 1]; push(); }
        if (inside) lines.push({ layer, pts: Float32Array.from(pts) });
      }
    }
    const cities = (basemap.cities || []).filter(([, la, lo]) => lo > minLon && lo < maxLon && la > minLat && la < maxLat);
    return { bbox, lines, cities };
  }
  const project = (bbox, lon, lat) => [MAP.x + (lon - bbox[0]) / (bbox[2] - bbox[0]) * MAP.w, MAP.y + (bbox[3] - lat) / (bbox[3] - bbox[1]) * MAP.h];

  function drawBase(ctx, base, place) {
    const STYLE = { lakes: ['rgba(0,212,255,0.45)', 2], states: ['rgba(185,195,222,0.38)', 1.5], borders: ['rgba(255,45,180,0.85)', 3], coast: ['rgba(0,212,255,0.95)', 3] };
    ctx.save();
    ctx.beginPath(); ctx.rect(MAP.x, MAP.y, MAP.w, MAP.h); ctx.clip();
    ctx.lineJoin = 'round'; ctx.lineCap = 'round';
    for (const layer of ['lakes', 'states', 'borders', 'coast']) {
      ctx.strokeStyle = STYLE[layer][0]; ctx.lineWidth = STYLE[layer][1];
      ctx.beginPath();
      for (const l of base.lines) {
        if (l.layer !== layer) continue;
        for (let i = 0; i < l.pts.length; i += 2) {
          const [px, py] = project(base.bbox, l.pts[i], l.pts[i + 1]);
          if (i === 0) ctx.moveTo(px, py); else ctx.lineTo(px, py);
        }
      }
      ctx.stroke();
    }
    ctx.restore();
  }
  function drawCities(ctx, base, place) {
    const placed = [];
    const mine = project(base.bbox, place.lon, place.lat);
    ctx.save();
    ctx.beginPath(); ctx.rect(MAP.x, MAP.y, MAP.w, MAP.h); ctx.clip();
    let shown = 0;
    for (const [name, la, lo] of base.cities) {
      if (shown >= 9) break;
      const [px, py] = project(base.bbox, lo, la);
      const w = measure(ctx, name.toUpperCase(), pixel(34)) + 26;
      const box = [px - 6, py - 30, px + w, py + 10];
      if (Math.hypot(px - mine[0], py - mine[1]) < 70) continue;
      if (px < MAP.x + 20 || px + w > MAP.x + MAP.w - 10 || py < MAP.y + 40 || py > MAP.y + MAP.h - 20) continue;
      if (placed.some((b) => !(box[2] < b[0] || box[0] > b[2] || box[3] < b[1] || box[1] > b[3]))) continue;
      placed.push(box);
      ctx.fillStyle = C.text2;
      ctx.fillRect(px - 4, py - 4, 8, 8);
      text(ctx, name.toUpperCase(), px + 14, py + 8, pixel(34), C.text2, 'left');
      shown++;
    }
    ctx.restore();
  }
  function drawPin(ctx, base, place, nowMs) {
    const [px, py] = project(base.bbox, place.lon, place.lat);
    const pulse = Math.floor(nowMs / 500) % 2 === 0;
    ctx.fillStyle = C.pink;
    ctx.fillRect(px - 9, py - 9, 18, 18);
    ctx.lineWidth = 3; ctx.strokeStyle = C.text;
    ctx.strokeRect(px - 9, py - 9, 18, 18);
    if (pulse) { ctx.strokeStyle = C.pink; ctx.lineWidth = 3; ctx.strokeRect(px - 20, py - 20, 40, 40); }
    const label = String(place.name || '').toUpperCase();
    const lw = measure(ctx, label, pixel(42));
    const right = px + 30 + lw < MAP.x + MAP.w - 10;
    const lx = right ? px + 30 : px - 30;
    ctx.fillStyle = 'rgba(10,10,26,0.78)';
    ctx.fillRect(right ? lx - 8 : lx - lw - 8, py - 28, lw + 16, 40);
    text(ctx, label, lx, py + 4, pixel(42), C.yellow, right ? 'left' : 'right');
  }

  function screenRadar(ctx, st, elapsedMs) {
    const M = NW();
    const R = st.radar || { status: 'none' };
    ctx.fillStyle = '#070C18';
    ctx.fillRect(MAP.x, MAP.y, MAP.w, MAP.h);
    // The loop has no radar screen where there is no coverage (`hasRadar`), so there is no slide for it; this only holds the map's colour.
    if (R.status === 'none') return null;
    if (R.status === 'loading' && !(R.frames && R.frames.length)) { message(ctx, 'LOADING RADAR', 'THE MAP DRAWS AS SOON AS THE FRAMES ARRIVE', C.amber); return R.provider ? R.provider.credit : null; }
    if (R.status === 'error' && !(R.frames && R.frames.length)) { message(ctx, 'RADAR UNAVAILABLE RIGHT NOW', 'TRYING AGAIN SOON', C.amber); return R.provider ? R.provider.credit : null; }
    const frames = R.frames || [];
    // The map under the echoes: the drawn coastlines, lakes and borders.
    if (R.base) drawBase(ctx, R.base, st.place);
    if (frames.length) {
      const cycle = frames.length * FRAME_MS + HOLD_MS;
      const t = elapsedMs % cycle;
      const idx = Math.min(frames.length - 1, Math.floor(t / FRAME_MS));
      ctx.save();
      ctx.beginPath(); ctx.rect(MAP.x, MAP.y, MAP.w, MAP.h); ctx.clip();
      ctx.imageSmoothingEnabled = false;
      ctx.globalAlpha = 0.9;
      ctx.drawImage(frames[idx].canvas, MAP.x, MAP.y, MAP.w, MAP.h);
      ctx.restore();
      st._radarFrame = idx;
    }
    if (R.base) { drawCities(ctx, R.base, st.place); drawPin(ctx, R.base, st.place, st.nowMs); }
    ctx.lineWidth = 3; ctx.strokeStyle = C.outline; ctx.strokeRect(MAP.x, MAP.y, MAP.w, MAP.h);
    // The legend row under the map: the five bands, and the frame's time.
    const ly = MAP.y + MAP.h + 20;
    let lx = MAP.x;
    text(ctx, 'RAIN AND SNOW', lx, ly + 24, mono(25), C.text2, 'left');
    lx += 245;
    M.RADAR_BANDS.forEach((b) => {
      ctx.fillStyle = b.color; ctx.fillRect(lx, ly + 4, 26, 26);
      text(ctx, b.name, lx + 38, ly + 26, mono(25), C.text, 'left');
      lx += 38 + measure(ctx, b.name, mono(25)) + 34;
    });
    if (frames.length && st.place) {
      const f = frames[st._radarFrame || 0];
      const ago = Math.max(0, Math.round((st.nowMs - f.timeMs) / 60000));
      text(ctx, `${M.fmtClock(f.timeMs, st.place.tz)}  ${ago} MIN AGO`, MAP.x + MAP.w, ly + 28, pixel(40), C.yellow, 'right');
    }
    return R.provider ? R.provider.credit : null;
  }

  // ── The picture ────────────────────────────────────────────────────────────
  /** Draws the channel for `st.nowMs`. Returns { screen, index, extra } for the page and the tests. */
  function render(ctx, st) {
    const M = NW();
    st.textScale = st.textScale || 1;
    // The loop for this place: no radar screen where there is no radar coverage (GitHub #332).
    const withRadar = M.hasRadar(st.place);
    const loop = M.activeScreens(withRadar);
    const at = M.screenAt(st.nowMs, withRadar);
    let index = at.index;
    let elapsed = at.elapsed;
    if (st.screen) { index = loop.findIndex((s) => s.id === st.screen); if (index < 0) index = 0; elapsed = st.elapsed != null ? st.elapsed : 4; }
    const screen = loop[index];
    ctx.save();
    ctx.setTransform(ctx.canvas.width / W, 0, 0, ctx.canvas.height / H, 0, 0);
    background(ctx);
    // With nothing to show yet the header says what the channel is; the four screens' names come with the data.
    const hasData = st.status !== 'noplace' && !!st.model;
    header(ctx, st, hasData ? screen.title : M.CHANNEL_NAME, hasData ? ACCENT[screen.id] : C.cyan);
    let extra = null;
    if (st.status === 'noplace') message(ctx, 'SET YOUR LOCATION IN SETTINGS', 'SETTINGS, PLAYBACK AND PICTURE, WEATHER, LOCATION', C.cyan);
    else if (st.status === 'loading' && !st.model) message(ctx, 'LOADING THE FORECAST', null, C.cyan);
    else if (st.status === 'error' && !st.model) message(ctx, 'FORECAST UNAVAILABLE RIGHT NOW', 'TRYING AGAIN SOON', C.amber);
    else if (!st.model) message(ctx, 'LOADING THE FORECAST', null, C.cyan);
    else if (screen.id === 'current') screenCurrent(ctx, st);
    else if (screen.id === 'today') screenToday(ctx, st);
    else if (screen.id === 'week') screenWeek(ctx, st);
    else if (screen.id === 'radar' && st.place) extra = screenRadar(ctx, st, elapsed * 1000);
    footer(ctx, st, loop.map((s) => s.id), index, screen.id === 'radar' && st.status !== 'noplace' ? extra : null);
    // The change between screens: a quick wipe from the left.
    const WIPE = 0.4;
    if (elapsed < WIPE && !st.screen) {
      const x = Math.round(W * (elapsed / WIPE));
      ctx.fillStyle = C.bg0;
      ctx.fillRect(x, 0, W - x, H);
      ctx.fillStyle = ACCENT[screen.id];
      ctx.fillRect(x - 10, 0, 10, H);
    }
    ctx.restore();
    return { screen: screen.id, index, extra };
  }

  /**
   * Sound cue for the page: how long to wait before the next draw. The picture only moves on the radar
   * screen and during the wipe; elsewhere once a second keeps the clock and the pulse right.
   */
  function nextDelay(nowMs, withRadar = true) {
    const at = global.NostalgexWeather.screenAt(nowMs, withRadar);
    if (at.elapsed < 0.45) return 50;
    if (at.screen.id === 'radar') return 120;
    return 500;
  }

  /**
   * Recolors a radar image's pixels from the source's colours to our five bands (cyan, yellow, amber, red,
   * pink), in place. Anything that is not an echo becomes clear. `imageData` is an ImageData.
   */
  function recolorRadar(imageData, ignoreBands) {
    const d = imageData.data;
    const rgb = C_BANDS();
    for (let i = 0; i < d.length; i += 4) {
      if (d[i + 3] < 40) { d[i + 3] = 0; continue; }
      const band = NW().radarBand(d[i], d[i + 1], d[i + 2]);
      if (band < 0 || (ignoreBands && ignoreBands.includes(band))) { d[i + 3] = 0; continue; }
      d[i] = rgb[band][0]; d[i + 1] = rgb[band][1]; d[i + 2] = rgb[band][2]; d[i + 3] = 235;
    }
    return imageData;
  }
  function C_BANDS() {
    return NW().RADAR_BANDS.map((b) => [parseInt(b.color.slice(1, 3), 16), parseInt(b.color.slice(3, 5), 16), parseInt(b.color.slice(5, 7), 16)]);
  }

  const api = {
    W, H, FOOTER, MAP, MAP_ASPECT, FRAME_MS, HOLD_MS, COLORS: C, ACCENT, ICON_GRIDS, ICON_COLORS, ICON,
    render, nextDelay, prepareBasemap, recolorRadar, drawIcon,
  };
  global.NostalgexWeatherScreens = api;
  if (typeof module !== 'undefined' && typeof module.exports !== 'undefined') module.exports = api;
})(typeof window !== 'undefined' ? window : globalThis);
