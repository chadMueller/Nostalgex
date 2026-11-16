// The weather channel's engine (Trello I-016). Pure logic, no DOM, no network: the page (or a test)
// passes in the forecast document, the place list loader and the clock.
//
// A 24/7 local-forecast channel the app draws itself, four screens in a loop:
//   CURRENT CONDITIONS, TODAY'S FORECAST (the next four six-hour periods), 5-DAY FORECAST, RADAR.
//
// THE WEB TUNER IS THE REFERENCE. Apple TV, Roku and Android port this file's rules, not its code:
// scripts/weather-golden.json holds the same inputs and answers for all four (the Swift, BrightScript
// and Kotlin tests read it as scripts/*-golden.json files are read today).
//
// DATA
//   Forecast   MET Norway Locationforecast 2.0 `complete`, through the relay at nostalgex.app/api/weather
//              (api/weather.js). CC BY 4.0. Credit on screen: DATA FROM MET NORWAY.
//   Places     GeoNames (CC BY 4.0), built into static files by scripts/build-weather-data.mjs and served
//              from /weather/places/ (and shipped inside the Docker image).
//   Radar      NOAA MRMS composites for the United States, Environment Canada GeoMet for Canada, DWD for Germany.
//              Nowhere else yet: RADAR NOT AVAILABLE IN YOUR AREA.
//   Music      one bundled, original loop (weather/music/local-forecast.m4a and .mp3, see THIRD-PARTY-LICENSES.md),
//              played quietly under the screens and muted with the page's SOUND control.
//
// USAGE (browser: plain <script>; node: import it)
//   const W = globalThis.NostalgexWeather;
//   const model = W.buildModel(metJson, place, nowMs);   // current, periods, days
//   W.fmtTemp(model.current.tempC, W.unitsFor(place, 'auto'));
(function (global) {
  'use strict';

  // ── The channel ────────────────────────────────────────────────────────────
  // CH 299, just before the FRANCHISES package (300-309), the franchise and collection blocks (310-499) and HIGH ROTATION (500-519):
  // the closest number below the music videos that nothing owns. channels.json uses ids 1-425 and numbers 1-513 (id and number differ
  // for 123 channels), the Apple TV reserves packages 1-199, FRANCHISES 300-309, found franchises 310-399, other collections 400-499
  // and HIGH ROTATION 500-519, and 200-299 is unused. The id sits in the next free dynamic block (found franchises 1,000,000,
  // franchise collections 1,010,000, collections 1,020,000), so a channel the viewer makes later (the next id is the highest plus one)
  // can never take it.
  const CHANNEL_NUMBER = 299;
  const CHANNEL_ID = 1030000;
  const CHANNEL_NAME = 'LOCAL WEATHER';
  const CHANNEL_COLOR = '#00D4FF';

  // The loop, in seconds. Radar is longest: it plays its frames over and over.
  const SCREENS = [
    { id: 'current', title: 'CURRENT CONDITIONS', seconds: 15 },
    { id: 'today', title: "TODAY'S FORECAST", seconds: 15 },
    { id: 'week', title: '5-DAY FORECAST', seconds: 15 },
    { id: 'radar', title: 'RADAR', seconds: 20 },
  ];
  const LOOP_SECONDS = SCREENS.reduce((n, s) => n + s.seconds, 0);

  /** Which screen is up at `nowMs` and how far into it: the loop runs on the wall clock, so every viewer sees the same one. */
  function screenAt(nowMs) {
    let t = ((nowMs / 1000) % LOOP_SECONDS + LOOP_SECONDS) % LOOP_SECONDS;
    for (let i = 0; i < SCREENS.length; i++) {
      if (t < SCREENS[i].seconds) return { index: i, screen: SCREENS[i], elapsed: t, remaining: SCREENS[i].seconds - t };
      t -= SCREENS[i].seconds;
    }
    return { index: 0, screen: SCREENS[0], elapsed: 0, remaining: SCREENS[0].seconds };
  }

  // ── Units ──────────────────────────────────────────────────────────────────
  /** °F where the place's country is the US, otherwise °C, unless the viewer chose: 'auto', 'F' or 'C'. */
  function unitsFor(place, setting) {
    if (setting === 'F' || setting === 'C') return setting;
    return place && String(place.cc || '').toUpperCase() === 'US' ? 'F' : 'C';
  }
  const noNegZero = (n) => (Object.is(n, -0) || n === 0 ? 0 : n);
  function fmtTemp(c, units) {
    if (c == null || !Number.isFinite(c)) return '--';
    return String(noNegZero(Math.round(units === 'F' ? c * 9 / 5 + 32 : c)));
  }
  /** mph on °F, km/h on °C (the MET value is metres per second). */
  function fmtWind(ms, units) {
    if (ms == null || !Number.isFinite(ms)) return '--';
    return units === 'F' ? `${Math.round(ms * 2.2369363)} MPH` : `${Math.round(ms * 3.6)} KM/H`;
  }
  function fmtPressure(hpa, units) {
    if (hpa == null || !Number.isFinite(hpa)) return '--';
    return units === 'F' ? `${(hpa * 0.0295300).toFixed(2)} IN` : `${Math.round(hpa)} HPA`;
  }
  /** Rain and snow melt: inches to 2 places, or millimetres to 1 below 10 and whole above. */
  function fmtPrecip(mm, units) {
    if (mm == null || !Number.isFinite(mm)) return '--';
    if (units === 'F') return `${(mm / 25.4).toFixed(2)} IN`;
    return `${mm < 10 ? mm.toFixed(1) : Math.round(mm)} MM`;
  }
  const COMPASS = ['N', 'NNE', 'NE', 'ENE', 'E', 'ESE', 'SE', 'SSE', 'S', 'SSW', 'SW', 'WSW', 'W', 'WNW', 'NW', 'NNW'];
  function compass(deg) {
    if (deg == null || !Number.isFinite(deg)) return '';
    return COMPASS[Math.round((((deg % 360) + 360) % 360) / 22.5) % 16];
  }

  // ── Symbols ────────────────────────────────────────────────────────────────
  // MET's `symbol_code` is `<family>[_day|_night|_polartwilight]`. We draw 18 icons.
  const ICONS = ['sun', 'moon', 'fair-day', 'fair-night', 'partly-day', 'partly-night', 'cloud', 'fog',
    'drizzle', 'rain', 'heavy-rain', 'showers-day', 'showers-night', 'sleet', 'snow', 'flurries-day', 'flurries-night', 'thunder'];

  /** { icon, text, night } for a MET symbol code. Unknown codes read as cloud, never as a blank. */
  function symbolInfo(code) {
    const raw = String(code || '');
    const m = /^(.*?)(?:_(day|night|polartwilight))?$/.exec(raw);
    const base = m[1];
    const night = m[2] === 'night';
    const intensity = /^light/.test(base) ? 'light' : /^heavy/.test(base) ? 'heavy' : 'mid';
    const family = base.replace(/^(light|heavy)/, '');
    const dn = (d, n) => (night ? n : d);
    if (/thunder/.test(family)) {
      return { icon: 'thunder', text: /snow/.test(family) ? 'THUNDER SNOW' : 'THUNDERSTORMS', night };
    }
    switch (family) {
      case 'clearsky': return { icon: dn('sun', 'moon'), text: dn('SUNNY', 'CLEAR'), night };
      case 'fair': return { icon: dn('fair-day', 'fair-night'), text: dn('MOSTLY SUNNY', 'MOSTLY CLEAR'), night };
      case 'partlycloudy': return { icon: dn('partly-day', 'partly-night'), text: 'PARTLY CLOUDY', night };
      case 'cloudy': return { icon: 'cloud', text: 'CLOUDY', night };
      case 'fog': return { icon: 'fog', text: 'FOG', night };
      case 'rain': return { icon: intensity === 'light' ? 'drizzle' : intensity === 'heavy' ? 'heavy-rain' : 'rain', text: intensity === 'light' ? 'LIGHT RAIN' : intensity === 'heavy' ? 'HEAVY RAIN' : 'RAIN', night };
      case 'rainshowers': return { icon: dn('showers-day', 'showers-night'), text: intensity === 'light' ? 'LIGHT SHOWERS' : intensity === 'heavy' ? 'HEAVY SHOWERS' : 'SHOWERS', night };
      case 'sleet': case 'sleetshowers': return { icon: 'sleet', text: `${intensity === 'light' ? 'LIGHT ' : intensity === 'heavy' ? 'HEAVY ' : ''}${family === 'sleet' ? 'SLEET' : 'SLEET SHOWERS'}`, night };
      case 'snow': return { icon: 'snow', text: intensity === 'light' ? 'LIGHT SNOW' : intensity === 'heavy' ? 'HEAVY SNOW' : 'SNOW', night };
      case 'snowshowers': return { icon: dn('flurries-day', 'flurries-night'), text: intensity === 'light' ? 'FLURRIES' : intensity === 'heavy' ? 'HEAVY SNOW SHOWERS' : 'SNOW SHOWERS', night };
      default: return { icon: 'cloud', text: 'CLOUDY', night };
    }
  }

  /** The daytime form of a symbol code: the 5-day screen shows the day, so no moon on a day's icon. */
  function dayForm(code) {
    return String(code || '').replace(/_(night|polartwilight)$/, '_day');
  }

  // ── Time in the place's time zone ──────────────────────────────────────────
  // MET gives UTC only. The place's IANA zone (GeoNames) turns a step into a local date and hour.
  const fmtCache = new Map();
  const DOW = ['SUN', 'MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT'];
  const DOW_INDEX = { Sun: 0, Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6 };
  function localParts(ms, tz) {
    let f = fmtCache.get(tz);
    if (!f) {
      f = new Intl.DateTimeFormat('en-US', { timeZone: tz, hourCycle: 'h23', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', weekday: 'short' });
      fmtCache.set(tz, f);
    }
    const p = {};
    for (const part of f.formatToParts(new Date(ms))) p[part.type] = part.value;
    const h = Number(p.hour) % 24;
    return { y: Number(p.year), mo: Number(p.month), d: Number(p.day), h, mi: Number(p.minute), dow: DOW_INDEX[p.weekday], key: `${p.year}-${p.month}-${p.day}` };
  }
  function validZone(tz) {
    try { new Intl.DateTimeFormat('en-US', { timeZone: tz }); return true; } catch (e) { return false; }
  }
  /** "4:00 PM", the way the guide prints times. */
  function fmtClock(ms, tz) {
    const p = localParts(ms, tz);
    return `${p.h % 12 || 12}:${String(p.mi).padStart(2, '0')} ${p.h >= 12 ? 'PM' : 'AM'}`;
  }

  // ── The forecast document ──────────────────────────────────────────────────
  const r1 = (n) => (Number.isFinite(n) ? Math.round(n * 10) / 10 : null);
  const PERIOD_NAMES = ['OVERNIGHT', 'MORNING', 'AFTERNOON', 'EVENING'];   // local 00-06, 06-12, 12-18, 18-24

  function stepSymbol(step) {
    const d = step && step.data;
    if (!d) return null;
    for (const k of ['next_1_hours', 'next_6_hours', 'next_12_hours']) {
      const c = d[k] && d[k].summary && d[k].summary.symbol_code;
      if (c) return c;
    }
    return null;
  }
  /** The symbol for a period starting at a step: the 6 hour one first, then 12, then 1. */
  function periodSymbol(step) {
    const d = step && step.data;
    if (!d) return null;
    for (const k of ['next_6_hours', 'next_12_hours', 'next_1_hours']) {
      const c = d[k] && d[k].summary && d[k].summary.symbol_code;
      if (c) return c;
    }
    return null;
  }
  function stepPrecip(step) {
    const d = step.data;
    if (d.next_1_hours && d.next_1_hours.details && Number.isFinite(d.next_1_hours.details.precipitation_amount)) return d.next_1_hours.details.precipitation_amount;
    if (d.next_6_hours && d.next_6_hours.details && Number.isFinite(d.next_6_hours.details.precipitation_amount)) return d.next_6_hours.details.precipitation_amount;
    return 0;
  }
  const inst = (step) => (step.data && step.data.instant && step.data.instant.details) || {};

  /**
   * The channel's numbers from one `complete` forecast document.
   *   place  { name, cc, tz, lat, lon }
   *   nowMs  the clock
   * Returns { updatedMs, tz, current, periods[4], days[1-5] } in metric; format with fmtTemp and the rest.
   * Throws an Error whose `code` is 'EMPTY' when the document holds nothing from now on.
   */
  function buildModel(met, place, nowMs) {
    const tz = place && place.tz && validZone(place.tz) ? place.tz : 'UTC';
    const series = ((met && met.properties && met.properties.timeseries) || [])
      .map((s) => ({ t: Date.parse(s.time), data: s.data }))
      .filter((s) => Number.isFinite(s.t) && s.data && s.data.instant)
      .sort((a, b) => a.t - b.t);
    // The step the clock is in: the last one that has begun, else the first.
    let cur = -1;
    for (let i = 0; i < series.length; i++) if (series[i].t <= nowMs) cur = i; else break;
    if (cur < 0) cur = 0;
    if (!series.length || series[series.length - 1].t < nowMs) {
      const e = new Error('The forecast holds nothing from now on'); e.code = 'EMPTY'; throw e;
    }
    const meta = (met.properties.meta || {});

    // CURRENT CONDITIONS: the step the clock is in.
    const step = series[cur];
    const d = inst(step);
    const sym = stepSymbol(step);
    const nowLocal = localParts(nowMs, tz);
    const info = symbolInfo(sym);
    const isDay = sym && /_(day|night|polartwilight)$/.test(sym) ? !info.night : (nowLocal.h >= 6 && nowLocal.h < 18);
    const nh = step.data.next_1_hours && step.data.next_1_hours.details;
    const current = {
      timeMs: step.t,
      tempC: r1(d.air_temperature),
      feelsC: r1(Number.isFinite(d.apparent_air_temperature) ? d.apparent_air_temperature : d.air_temperature),
      humidity: Number.isFinite(d.relative_humidity) ? Math.round(d.relative_humidity) : null,
      dewC: r1(d.dew_point_temperature),
      windMs: r1(d.wind_speed),
      windDir: Number.isFinite(d.wind_from_direction) ? Math.round(d.wind_from_direction) : null,
      pressureHpa: r1(d.air_pressure_at_sea_level),
      cloud: Number.isFinite(d.cloud_area_fraction) ? Math.round(d.cloud_area_fraction) : null,
      uv: Number.isFinite(d.ultraviolet_index_clear_sky) && isDay ? Math.round(d.ultraviolet_index_clear_sky) : null,
      precipNextHourMm: nh && Number.isFinite(nh.precipitation_amount) ? r1(nh.precipitation_amount) : null,
      symbol: sym,
      isDay,
    };

    // TODAY'S FORECAST: the next four six-hour periods on the place's wall clock, the first from now.
    // MET sends nothing for hours already gone, so "the full day" is the 24 hours ahead, in the
    // four blocks a day is spoken in. A block is named for its hours; the second line says TODAY or TOMORROW.
    const groups = [];
    for (let i = cur; i < series.length && groups.length <= 4; i++) {
      const p = localParts(series[i].t, tz);
      const key = `${p.key}|${Math.floor(p.h / 6)}`;
      const last = groups[groups.length - 1];
      if (last && last.key === key) last.steps.push(series[i]);
      else groups.push({ key, date: p.key, block: Math.floor(p.h / 6), steps: [series[i]] });
    }
    const periods = groups.slice(0, 4).map((g) => {
      const mid = g.steps[Math.floor((g.steps.length - 1) / 2)];
      const md = inst(mid);
      const winds = g.steps.map((s) => inst(s).wind_speed).filter(Number.isFinite);
      const first = g.steps[0];
      // Hourly steps each carry their own hour's rain; a six-hourly step carries the next six.
      const hourly = g.steps.every((s) => s.data.next_1_hours);
      const precip = hourly ? g.steps.reduce((n, s) => n + stepPrecip(s), 0) : stepPrecip(first);
      const dayWord = g.date === nowLocal.key ? 'TODAY' : 'TOMORROW';
      return {
        name: PERIOD_NAMES[g.block],
        day: dayWord,
        startMs: first.t,
        tempC: r1(md.air_temperature),
        symbol: periodSymbol(first),
        precipMm: r1(precip),
        windMs: winds.length ? r1(winds.reduce((a, b) => a + b, 0) / winds.length) : null,
        windDir: Number.isFinite(md.wind_from_direction) ? Math.round(md.wind_from_direction) : null,
      };
    });

    // 5-DAY FORECAST: steps grouped by the place's local date. The high and low are the extremes of the
    // temperatures and of the six-hour maxima and minima MET gives; the icon is the step nearest 1 PM.
    const byDate = new Map();
    for (let i = cur; i < series.length; i++) {
      const p = localParts(series[i].t, tz);
      if (!byDate.has(p.key)) byDate.set(p.key, { key: p.key, dow: p.dow, steps: [] });
      byDate.get(p.key).steps.push({ s: series[i], h: p.h });
    }
    // A date needs two steps (past the first three days MET sends one every six hours).
    const dates = [...byDate.values()].filter((g) => g.steps.length >= 2);
    // Today with under six hours left (from 6 PM) is not a day of the 5 when there is a sixth day to use: start tomorrow.
    let start = 0;
    if (dates.length && dates[0].key === nowLocal.key && nowLocal.h >= 18 && dates.length > 5) start = 1;
    const days = dates.slice(start, start + 5).map((g) => {
      const temps = [];
      const winds = [];
      let precip = 0;
      let pick = null;
      for (const { s, h } of g.steps) {
        const dd = inst(s);
        if (Number.isFinite(dd.air_temperature)) temps.push(dd.air_temperature);
        const six = s.data.next_6_hours && s.data.next_6_hours.details;
        if (six) {
          if (Number.isFinite(six.air_temperature_max)) temps.push(six.air_temperature_max);
          if (Number.isFinite(six.air_temperature_min)) temps.push(six.air_temperature_min);
        }
        if (Number.isFinite(dd.wind_speed)) winds.push(dd.wind_speed);
        precip += s.data.next_1_hours ? stepPrecip(s) : (six && Number.isFinite(six.precipitation_amount) ? six.precipitation_amount : 0);
        if (periodSymbol(s) && (!pick || Math.abs(h - 13) < Math.abs(pick.h - 13))) pick = { s, h };
      }
      const code = pick ? periodSymbol(pick.s) : null;
      return {
        date: g.key,
        label: g.key === nowLocal.key ? 'TODAY' : DOW[g.dow],
        highC: temps.length ? r1(Math.max(...temps)) : null,
        lowC: temps.length ? r1(Math.min(...temps)) : null,
        // Today keeps its real symbol (it may be night); the days after show the daytime one.
        symbol: g.key === nowLocal.key ? code : dayForm(code),
        precipMm: r1(precip),
        windMaxMs: winds.length ? r1(Math.max(...winds)) : null,
      };
    });

    return {
      updatedMs: Date.parse(meta.updated_at) || null,
      tz,
      current,
      periods,
      days,
    };
  }

  // ── Radar ──────────────────────────────────────────────────────────────────
  // Region-limited on purpose: no open source covers the world and allows commercial use without a key.
  //   DE   DWD Niederschlagsradar (maps.dwd.de), CC BY 4.0 with a source note: see the provider below.
  //   US   NOAA MRMS base reflectivity composites, https://opengeo.ncep.noaa.gov/geoserver/www/index.html
  //        (public domain: weather.gov/disclaimer). CONUS, Alaska, Hawaii, the Caribbean and Guam.
  //   CA   Environment and Climate Change Canada GeoMet, RADAR_1KM_RRAI (rain) and RADAR_1KM_RSNO (snow)
  //        (a licence that allows commercial use, credit "Data Source: Environment and Climate Change Canada").
  const NOAA_HOST = 'https://opengeo.ncep.noaa.gov/geoserver';
  const ECCC_HOST = 'https://geo.weather.gc.ca/geomet';
  const DWD_HOST = 'https://maps.dwd.de/geoserver/dwd';

  function noaaLayer(lat, lon) {
    if (lon >= 140 && lon <= 150 && lat >= 10 && lat <= 22) return 'guam';
    if (lat >= 15 && lat <= 20 && lon >= -68 && lon <= -63) return 'carib';
    if (lat >= 18 && lat <= 23 && lon >= -161 && lon <= -154) return 'hawaii';
    if (lat > 51 && (lon <= -129 || lon >= 170)) return 'alaska';
    return 'conus';
  }

  /** The radar source for a place, or null: the card says RADAR NOT AVAILABLE IN YOUR AREA. */
  function radarProvider(place) {
    const cc = place && String(place.cc || '').toUpperCase();
    if (cc === 'US') {
      const ws = noaaLayer(place.lat, place.lon);
      const layer = `${ws}_bref_qcd`;
      return {
        id: 'noaa',
        credit: 'RADAR: NOAA NATIONAL WEATHER SERVICE',
        layers: [layer],
        stepMinutes: 10,
        frames: 8,
        capabilitiesUrl: () => `${NOAA_HOST}/${ws}/${layer}/ows?service=WMS&version=1.3.0&request=GetCapabilities`,
        mapUrl: (lyr, bbox, w, h, time) => `${NOAA_HOST}/${ws}/${lyr}/ows?service=WMS&version=1.3.0&request=GetMap&layers=${lyr}&styles=&crs=CRS:84&bbox=${bbox.join(',')}&width=${w}&height=${h}&format=image/png&transparent=true${time ? `&time=${encodeURIComponent(wmsTime(time))}` : ''}`,
      };
    }
    if (cc === 'CA') {
      return {
        id: 'eccc',
        credit: 'DATA SOURCE: ENVIRONMENT AND CLIMATE CHANGE CANADA',
        layers: ['RADAR_1KM_RRAI', 'RADAR_1KM_RSNO'],
        stepMinutes: 6,
        frames: 6,
        capabilitiesUrl: (lyr) => `${ECCC_HOST}?service=WMS&version=1.3.0&request=GetCapabilities&layer=${lyr}`,
        mapUrl: (lyr, bbox, w, h, time) => `${ECCC_HOST}?service=WMS&version=1.3.0&request=GetMap&layers=${lyr}&styles=&crs=CRS:84&bbox=${bbox.join(',')}&width=${w}&height=${h}&format=image/png&transparent=true${time ? `&time=${encodeURIComponent(wmsTime(time))}` : ''}`,
      };
    }
    if (cc === 'DE') {
      // DWD's precipitation radar composite, one layer, a 5 minute step. Its capabilities for this layer alone are 41 KB (the whole server's
      // is 983 KB). The time range runs past now (nowcast), so frames stop `lagMinutes` short of the clock. The style paints the area with no
      // echo white, outside the radars grey, and the edge of the radar coverage in magenta, which is the colour of our EXTREME band, so that
      // band is dropped: a real extreme echo shows as SEVERE.
      return {
        id: 'dwd',
        // DWD's own wording for changed data (vorlagen_quellenangabe): the picture is the radar raster in our colours.
        credit: 'Datenbasis: Deutscher Wetterdienst, Rasterdaten bildlich wiedergegeben',
        layers: ['Niederschlagsradar'],
        stepMinutes: 10,
        frames: 8,
        lagMinutes: 10,
        ignoreBands: [4],
        capabilitiesUrl: () => `${DWD_HOST}/Niederschlagsradar/wms?service=WMS&version=1.3.0&request=GetCapabilities`,
        mapUrl: (lyr, bbox, w, h, time) => `${DWD_HOST}/wms?service=WMS&version=1.3.0&request=GetMap&layers=dwd:${lyr}&styles=&crs=CRS:84&bbox=${bbox.join(',')}&width=${w}&height=${h}&format=image/png&transparent=true${time ? `&time=${encodeURIComponent(wmsTime(time))}` : ''}`,
      };
    }
    return null;
  }

  /**
   * The map window: `spanLat` degrees tall, centred on the place, as wide as the picture needs so
   * that a degree of longitude is drawn cos(latitude) as wide as a degree of latitude (a flat map
   * that is not stretched). [minLon, minLat, maxLon, maxLat], CRS:84 order.
   */
  function radarBBox(lat, lon, aspect, spanLat) {
    const span = spanLat || 6;
    const spanLon = span * aspect / Math.max(0.2, Math.cos(lat * Math.PI / 180));
    const r = (n) => Math.round(n * 1000) / 1000;
    return [r(lon - spanLon / 2), r(lat - span / 2), r(lon + spanLon / 2), r(lat + span / 2)];
  }

  /** A time for a WMS TIME parameter: whole seconds, "2026-11-15T17:00:00Z", never "...:00.000Z". Environment Canada's server
   *  rejects a fraction; the shared parser below writes toISOString, which always has one. */
  function wmsTime(t) {
    return String(t).replace(/\.\d+Z$/, 'Z');
  }

  /** The times inside a WMS time dimension: "a,b,c" or "start/end/PT6M". Newest last. */
  function parseTimeDimension(xml) {
    const m = /<Dimension[^>]*name="time"[^>]*>([^<]*)</.exec(String(xml || ''));
    if (!m) return [];
    const text = m[1].trim();
    if (!text) return [];
    if (text.includes('/') && !text.includes(',')) {
      const [a, b, step] = text.split('/');
      const start = Date.parse(a), end = Date.parse(b);
      const dur = /^PT(?:(\d+)H)?(?:(\d+)M)?$/.exec(step || '');
      const ms = dur ? ((Number(dur[1] || 0) * 60) + Number(dur[2] || 0)) * 60000 : 0;
      if (!Number.isFinite(start) || !Number.isFinite(end) || !ms) return Number.isFinite(end) ? [new Date(end).toISOString()] : [];
      const out = [];
      for (let t = start; t <= end; t += ms) out.push(new Date(t).toISOString());
      return out;
    }
    return text.split(',').map((s) => s.trim()).filter((s) => Number.isFinite(Date.parse(s))).map((s) => new Date(Date.parse(s)).toISOString());
  }

  /** `count` frames ending at the newest time, about `stepMinutes` apart, oldest first. Times after `notAfterMs` (when given) are not used. */
  function pickFrameTimes(allTimes, count, stepMinutes, notAfterMs) {
    const times = Number.isFinite(notAfterMs) ? allTimes.filter((t) => Date.parse(t) <= notAfterMs) : allTimes;
    if (!times.length) return [];
    const ms = times.map((t) => Date.parse(t));
    const out = [times[times.length - 1]];
    let want = ms[ms.length - 1];
    for (let n = 1; n < count; n++) {
      want -= stepMinutes * 60000;
      let best = -1;
      for (let i = 0; i < ms.length; i++) if (best < 0 || Math.abs(ms[i] - want) < Math.abs(ms[best] - want)) best = i;
      if (best >= 0 && times[best] !== out[0] && Math.abs(ms[best] - want) <= stepMinutes * 30000) out.unshift(times[best]);
    }
    return out;
  }

  /**
   * One radar pixel, from the source's colours to our five bands. Both sources draw light echoes blue,
   * then green, yellow, orange, red and magenta. Returns 0 (light) to 4 (extreme), or -1 for a pixel
   * that is not an echo (white, grey, black and near-white).
   */
  function radarBand(r, g, b) {
    const max = Math.max(r, g, b), min = Math.min(r, g, b);
    if (max - min < 28) return -1;
    let h;
    const d = max - min;
    if (max === r) h = ((g - b) / d) % 6; else if (max === g) h = (b - r) / d + 2; else h = (r - g) / d + 4;
    h = (h * 60 + 360) % 360;
    if (h >= 190 && h < 280) return 0;      // blue: light
    if (h >= 90 && h < 190) return 1;       // green and cyan: moderate
    if (h >= 40 && h < 90) return 2;        // yellow: heavy
    if (h >= 12 && h < 40) return 3;        // orange and red: severe (orange sits at the top of this band)
    if (h >= 280 && h < 345) return 4;      // magenta and purple: extreme
    return 3;                               // red
  }
  const RADAR_BANDS = [
    { name: 'LIGHT', color: '#00D4FF' },
    { name: 'MODERATE', color: '#FFE500' },
    { name: 'HEAVY', color: '#FFB020' },
    { name: 'SEVERE', color: '#FF2244' },
    { name: 'EXTREME', color: '#FF2DB4' },
  ];

  // ── Places ─────────────────────────────────────────────────────────────────
  const PLAIN_RE = /[^a-z0-9]/g;
  const plain = (s) => String(s).normalize('NFKD').replace(/[̀-ͯ]/g, '').toLowerCase().replace(PLAIN_RE, '');
  const round2 = (n) => Math.round(Number(n) * 100) / 100;
  const MAX_RESULTS = 8;

  function placeLabel(p) {
    return [p.name, p.region, p.cc].filter(Boolean).join(', ').toUpperCase();
  }
  function rowToPlace(row, meta, kind) {
    const [name, a, b, lat, lon, tzi] = row;
    const place = kind === 'city'
      ? { name, cc: a, region: b, lat, lon, tz: meta.tz[tzi] || 'UTC', kind }
      // GeoNames names some codes with their landmarks in brackets ("DOWNTOWN TORONTO (CN TOWER / ...)"): keep the name.
      : { name: String(row[1]).replace(/\s*\(.*$/, '').trim() || row[1], cc: null, region: row[2], lat, lon, tz: meta.tz[tzi] || 'UTC', kind, code: row[0] };
    return place;
  }

  /** The key a postcode is looked up by, in each country's shard set, or null when the text cannot be one of its codes. */
  function postcodeLookup(cc, text) {
    const t = String(text).toUpperCase().replace(/[^A-Z0-9 ]/g, '').trim();
    const squashed = t.replace(/\s+/g, '');
    switch (cc) {
      case 'US': case 'DE': return /^\d{3,5}$/.test(squashed) ? squashed : null;
      case 'AU': return /^\d{3,4}$/.test(squashed) ? squashed : null;
      case 'CA': return /^[A-Z]\d[A-Z]/.test(squashed) ? squashed.slice(0, 3) : null;
      case 'GB': {
        if (!/^[A-Z]{1,2}\d/.test(squashed)) return null;
        // A full postcode ends in digit-letter-letter: the outward part is what is before it.
        const full = /^([A-Z]{1,2}\d[A-Z\d]?)\d[A-Z]{2}$/.exec(squashed);
        return full ? full[1] : (t.includes(' ') ? t.split(/\s+/)[0] : squashed);
      }
      default: return null;
    }
  }

  /**
   * A place finder over the static place files. `io.load(path)` resolves the parsed JSON of a path under
   * /weather/ (for example 'places/meta.json') or null when there is no such file.
   *   const idx = W.createPlaceIndex({ load });
   *   const { places, hint } = await idx.search('toronto');   // up to 8, most people first
   */
  function createPlaceIndex(io) {
    let metaP = null;
    const shards = new Map();
    const load = (path) => {
      if (!shards.has(path)) shards.set(path, Promise.resolve(io.load(path)).catch(() => null));
      return shards.get(path);
    };
    const meta = () => (metaP || (metaP = load('places/meta.json')));

    async function search(query) {
      const q = String(query || '').trim();
      const m = await meta();
      if (!m || !q) return { places: [], hint: q ? 'PLACE LIST NOT AVAILABLE' : '' };
      const out = [];
      const seen = new Set();
      const push = (p) => {
        const k = `${p.kind}|${p.name}|${p.region}|${p.cc}|${p.code || ''}`;
        if (seen.has(k) || out.length >= MAX_RESULTS) return;
        seen.add(k);
        out.push({ ...p, label: p.kind === 'postcode' ? `${p.code} ${p.name}, ${[p.region, p.cc].filter(Boolean).join(', ')}`.toUpperCase() : placeLabel(p) });
      };

      // A postcode: digits, or a letter-digit pattern, looked up in every country it could belong to.
      // A whole code (2000 is Sydney) comes before the longer codes that only begin with it (20001 is Washington).
      const zips = [];
      for (const cc of m.postcodes || []) {
        const code = postcodeLookup(cc, q);
        if (!code) continue;
        const rows = await load(`places/z/${cc}/${code.slice(0, 2)}.json`);
        if (!Array.isArray(rows)) continue;
        for (const row of rows) {
          if (String(row[0]).startsWith(code)) zips.push({ place: { ...rowToPlace(row, m, 'postcode'), cc }, whole: row[0] === code ? 0 : 1 });
        }
      }
      zips.sort((a, b) => a.whole - b.whole);
      for (const z of zips) push(z.place);

      // A city: "toronto", or "springfield il" / "portland, or" with the state, province or country after it.
      const attempts = [];
      const comma = q.indexOf(',');
      if (comma > 0) attempts.push([q.slice(0, comma), q.slice(comma + 1).trim()]);
      attempts.push([q, '']);
      const words = q.split(/\s+/);
      if (words.length > 1) attempts.push([words.slice(0, -1).join(' '), words[words.length - 1]]);
      let hint = '';
      for (const [nameQ, qual] of attempts) {
        const key = plain(nameQ);
        if (key.length < 2) continue;
        let shard = key.slice(0, 2);
        if ((m.split || []).includes(shard)) {
          if (key.length < 3) { hint = 'KEEP TYPING'; continue; }
          shard = key.slice(0, 3);
        }
        const rows = await load(`places/c/${shard}.json`);
        if (!Array.isArray(rows)) continue;
        const qualN = plain(qual);
        for (const row of rows) {
          if (!plain(row[0]).startsWith(key)) continue;
          if (qualN && !(plain(row[2]).startsWith(qualN) || plain(row[1]) === qualN)) continue;
          push(rowToPlace(row, m, 'city'));
        }
        if (out.some((p) => p.kind === 'city')) break;
      }
      return { places: out, hint: out.length ? '' : hint };
    }
    return { search };
  }

  /** A place read back from storage, or null if it is not usable. Coordinates are kept at 2 decimals. */
  function normalizePlace(p) {
    if (!p || typeof p !== 'object') return null;
    const lat = Number(p.lat), lon = Number(p.lon);
    if (!Number.isFinite(lat) || !Number.isFinite(lon) || Math.abs(lat) > 90 || Math.abs(lon) > 180) return null;
    if (!p.name || typeof p.name !== 'string') return null;
    return {
      name: p.name.slice(0, 80),
      region: typeof p.region === 'string' ? p.region.slice(0, 60) : '',
      cc: typeof p.cc === 'string' ? p.cc.toUpperCase().slice(0, 2) : '',
      lat: round2(lat),
      lon: round2(lon),
      tz: typeof p.tz === 'string' && validZone(p.tz) ? p.tz : 'UTC',
      kind: p.kind === 'postcode' ? 'postcode' : 'city',
      code: typeof p.code === 'string' ? p.code.slice(0, 8) : undefined,
    };
  }

  // ── The relay ──────────────────────────────────────────────────────────────
  /** The relay call for a place. Coordinates leave the device rounded to 2 decimals, about 1 km. */
  function forecastUrl(base, place) {
    return `${base}?lat=${round2(place.lat).toFixed(2)}&lon=${round2(place.lon).toFixed(2)}`;
  }
  /** Whether to ask again: never before the document's own Expires, and not more than every `minMs` after the last answer. */
  function forecastDue(entry, nowMs, minMs) {
    if (!entry || !entry.body) return true;
    const gap = Number.isFinite(minMs) ? minMs : 30 * 60000;
    if (Number.isFinite(entry.expiresMs) && nowMs < entry.expiresMs) return false;
    return nowMs - entry.savedMs >= gap;
  }
  /** How old the forecast is, for the card: "UPDATED 2:18 PM", or STALE when it is over 6 hours old. */
  function forecastAge(updatedMs, nowMs, tz) {
    if (!Number.isFinite(updatedMs)) return { text: '', stale: false };
    const stale = nowMs - updatedMs > 6 * 3600000;
    return { text: `UPDATED ${fmtClock(updatedMs, tz)}`, stale };
  }

  // ── The guide row and the info panel ───────────────────────────────────────
  /** Hour-long guide blocks for the channel's row, `hours` of them from the top of the hour before now. */
  function guideBlocks(placeName, nowMs, hours) {
    const hourMs = 3600000;
    const start = Math.floor(nowMs / hourMs) * hourMs - hourMs;
    const out = [];
    for (let i = 0; i < (hours || 26); i++) {
      const s = start + i * hourMs;
      out.push({ startSec: s / 1000, endSec: (s + hourMs) / 1000, item: {
        title: CHANNEL_NAME,
        episodeTitle: placeName || '',
        summary: 'Current conditions, today\u2019s forecast, the 5-day forecast and radar, in a loop.',
        ratingKey: null, duration: 3600,
      } });
    }
    return out;
  }
  /** The line the info panel shows under the place: "Cloudy, 6\u00B0C. Feels like 3\u00B0. High 7\u00B0, low 5\u00B0. Wind NNW 17 km/h." */
  function infoSummary(model, units) {
    if (!model) return '';
    const c = model.current;
    const t = (v) => `${fmtTemp(v, units)}\u00B0`;
    const cond = symbolInfo(c.symbol).text;
    const parts = [`${cond.charAt(0)}${cond.slice(1).toLowerCase()}, ${t(c.tempC)}${units}.`, `Feels like ${t(c.feelsC)}.`];
    const first = model.days[0];
    if (first && first.highC != null) parts.push(`High ${t(first.highC)}, low ${t(first.lowC)}.`);
    if (c.windMs != null) parts.push(`Wind ${compass(c.windDir)} ${fmtWind(c.windMs, units).toLowerCase()}.`.replace('Wind  ', 'Wind '));
    return parts.join(' ');
  }

  const api = {
    CHANNEL_NUMBER, CHANNEL_ID, CHANNEL_NAME, CHANNEL_COLOR, SCREENS, LOOP_SECONDS, screenAt,
    unitsFor, fmtTemp, fmtWind, fmtPressure, fmtPrecip, compass,
    ICONS, symbolInfo, dayForm,
    localParts, fmtClock, validZone,
    buildModel,
    radarProvider, radarBBox, parseTimeDimension, pickFrameTimes, radarBand, RADAR_BANDS,
    createPlaceIndex, postcodeLookup, normalizePlace, placeLabel,
    forecastUrl, forecastDue, forecastAge,
    guideBlocks, infoSummary,
  };

  global.NostalgexWeather = api;
  if (typeof module !== 'undefined' && typeof module.exports !== 'undefined') {
    module.exports = api;
  }
})(typeof window !== 'undefined' ? window : globalThis);
