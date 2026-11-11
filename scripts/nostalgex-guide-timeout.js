// GUIDE TIMEOUT: a guide left alone goes to a plain full picture so its logo, header and grid lines do not sit still on an OLED
// screen for hours. Parity: Nostalgex/Nostalgex/Services/GuideTimeout.swift (OFF, 5 MIN, 15 MIN; 5 MIN by default; key
// nostalgex_guide_timeout holding "off", "5m" or "15m").
(function (global) {
  'use strict';
  const STORAGE_KEY = 'nostalgex_guide_timeout';
  const VALUES = ['off', '5m', '15m'];
  const DEFAULT = '5m';
  const LABELS = { off: 'OFF', '5m': '5 MIN', '15m': '15 MIN' };
  const SECONDS = { off: 0, '5m': 300, '15m': 900 };

  /** Anything that is not one of the three stored values is the default, as GuideTimeout.init(stored:) has it. */
  function parse(stored) { return VALUES.includes(stored) ? stored : DEFAULT; }
  /** What one press on the row moves to: OFF, 5 MIN, 15 MIN, and round again. */
  function next(value) { return VALUES[(VALUES.indexOf(parse(value)) + 1) % VALUES.length]; }
  const label = (value) => LABELS[parse(value)];
  const seconds = (value) => SECONDS[parse(value)];
  /** Whether a guide untouched since `lastActivityMs` has been left alone long enough at `nowMs`. */
  function isDue(value, lastActivityMs, nowMs) {
    const s = seconds(value);
    return s > 0 && nowMs - lastActivityMs >= s * 1000;
  }

  const api = { STORAGE_KEY, VALUES, DEFAULT, parse, next, label, seconds, isDue };
  global.NostalgexGuideTimeout = api;
  if (typeof module !== 'undefined' && typeof module.exports !== 'undefined') module.exports = api;
})(typeof window !== 'undefined' ? window : globalThis);
