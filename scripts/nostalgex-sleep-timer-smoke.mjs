#!/usr/bin/env node
/**
 * Sleep timer for the web tuner. Two halves:
 *
 *   1. scripts/nostalgex-sleep-timer.js against the Apple TV app's own vectors
 *      (NostalgexTests/NowPlayingPanelLogicTests.swift) and a fake clock: arm, expiry
 *      through the 20 second "Still watching?" grace, cancel before and during the grace,
 *      keep watching, re-arming, and catching up after a throttled (hidden) tab.
 *   2. The tuner's own sleep section from plex-tuner.html, run in a VM against a small
 *      fake DOM: the rail, drawer, picker and Settings rows, the grace prompt, what expiry
 *      does to playback, and re-tuning the same channel afterwards.
 *
 * Run: `npm run test:sleep-timer`
 */
import { readFileSync } from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";
import "./nostalgex-sleep-timer.js";

const ST = globalThis.NostalgexSleepTimer;
let passed = 0;
const failures = [];
async function check(label, fn) {
  try { await fn(); passed += 1; } catch (e) { failures.push(`${label}: ${e.stack || e.message}`); }
}

// ── 1. The module ──────────────────────────────────────────────────────────

await check("presets match tvOS", () => assert.deepEqual(ST.PRESETS, [15, 30, 60]));
await check("grace matches tvOS", () => assert.equal(ST.GRACE_SECONDS, 20));
for (const [m, want] of [[15, "15 MIN"], [45, "45 MIN"], [60, "1 HR"], [120, "2 HR"], [90, "1 HR 30 MIN"], [0, "OFF"], [-5, "OFF"]]) {
  await check(`label(${m})`, () => assert.equal(ST.label(m), want));
}
for (const [secs, want] of [[9, "0:09"], [754, "12:34"], [3661, "1:01:01"], [0, "0:00"], [899.6, "15:00"], [59.4, "0:59"]]) {
  await check(`countdownLabel(${secs})`, () => assert.equal(ST.countdownLabel(secs), want));
}
for (const [armed, want] of [[null, [15, 30, 60]], [30, [15, 30, 60]], [45, [15, 30, 45, 60]], [90, [15, 30, 60, 90]], [5, [5, 15, 30, 60]], [0, [15, 30, 60]], [-30, [15, 30, 60]]]) {
  await check(`offeredMinutes(${armed})`, () => assert.deepEqual(ST.offeredMinutes(armed), want));
}
await check("remaining is clamped and null when off", () => {
  assert.equal(ST.remaining(null, 5), null);
  assert.equal(ST.remaining(10000, 4000), 6);
  assert.equal(ST.remaining(10000, 20000), 0);
  assert.equal(ST.isExpired(null, 1), false);
  assert.equal(ST.isExpired(1000, 999), false);
  assert.equal(ST.isExpired(1000, 1000), true);
});

// A fake clock with real timer ordering: advance(ms) fires every timer that is due.
function clock() {
  let now = 1_000_000;
  let seq = 0;
  const timers = new Map();
  return {
    now: () => now,
    setTimeout: (fn, ms) => { const id = ++seq; timers.set(id, { at: now + ms, fn }); return id; },
    clearTimeout: (id) => { timers.delete(id); },
    pending: () => timers.size,
    advance(ms) {
      const end = now + ms;
      for (;;) {
        const due = [...timers.entries()].filter(([, t]) => t.at <= end).sort((a, b) => a[1].at - b[1].at)[0];
        if (!due) break;
        timers.delete(due[0]);
        now = due[1].at;
        due[1].fn();
      }
      now = end;
    },
    // A throttled tab: time passes, nothing fires.
    skip(ms) { now += ms; },
  };
}
function timerWith(c) {
  const events = [];
  const timer = ST.createSleepTimer({
    now: c.now, setTimeout: c.setTimeout, clearTimeout: c.clearTimeout,
    onGraceStart: () => events.push("grace"), onExpire: () => events.push("expire"),
  });
  return { timer, events };
}

await check("expiry: 15 minutes, then 20 seconds of grace, then one expiry", () => {
  const c = clock(); const { timer, events } = timerWith(c);
  timer.start(15);
  assert.equal(timer.state().armed, true);
  assert.equal(timer.state().minutes, 15);
  assert.equal(ST.countdownLabel(timer.state().remainingSeconds), "15:00");
  c.advance(15 * 60000 - 1);
  assert.deepEqual(events, []);
  assert.equal(ST.countdownLabel(timer.state().remainingSeconds), "0:00");
  c.advance(1);
  assert.deepEqual(events, ["grace"]);
  assert.equal(timer.state().graceActive, true);
  assert.equal(ST.countdownLabel(timer.state().graceRemainingSeconds), "0:20");
  c.advance(19999);
  assert.deepEqual(events, ["grace"]);
  c.advance(1);
  assert.deepEqual(events, ["grace", "expire"]);
  assert.equal(timer.state().armed, false);
  assert.equal(timer.state().graceActive, false);
  assert.equal(c.pending(), 0);
  c.advance(3600000);
  assert.deepEqual(events, ["grace", "expire"], "expires once");
});
await check("cancel before the end: no grace, no expiry, no timers left", () => {
  const c = clock(); const { timer, events } = timerWith(c);
  timer.start(30); c.advance(10 * 60000); timer.cancel();
  assert.equal(timer.state().armed, false);
  assert.equal(c.pending(), 0);
  c.advance(2 * 3600000);
  assert.deepEqual(events, []);
});
await check("cancel during the grace: playback is not stopped", () => {
  const c = clock(); const { timer, events } = timerWith(c);
  timer.start(15); c.advance(15 * 60000 + 5000); timer.cancel();
  c.advance(60000);
  assert.deepEqual(events, ["grace"]);
  assert.equal(timer.state().graceActive, false);
});
await check("OFF (start(0)) cancels a running timer", () => {
  const c = clock(); const { timer, events } = timerWith(c);
  timer.start(60); timer.start(0); c.advance(2 * 3600000);
  assert.deepEqual(events, []);
  assert.equal(timer.state().armed, false);
});
await check("any input in the grace keeps watching and uses the timer up", () => {
  const c = clock(); const { timer, events } = timerWith(c);
  timer.start(15); c.advance(15 * 60000 + 3000);
  assert.equal(timer.keepAwake(), true);
  assert.equal(timer.state().armed, false);
  assert.equal(timer.state().graceActive, false);
  c.advance(3600000);
  assert.deepEqual(events, ["grace"]);
  assert.equal(timer.keepAwake(), false, "outside a grace it does nothing");
});
await check("arming again replaces the running timer", () => {
  const c = clock(); const { timer, events } = timerWith(c);
  timer.start(15); c.advance(10 * 60000); timer.start(30);
  c.advance(25 * 60000);
  assert.deepEqual(events, [], "the first 15 minutes no longer count");
  c.advance(5 * 60000);
  assert.deepEqual(events, ["grace"]);
});
await check("arming during the grace dismisses it and starts over", () => {
  const c = clock(); const { timer, events } = timerWith(c);
  timer.start(15); c.advance(15 * 60000 + 1000); timer.start(30);
  assert.equal(timer.state().graceActive, false);
  c.advance(25000);
  assert.deepEqual(events, ["grace"]);
  assert.equal(timer.state().minutes, 30);
});
await check("a hidden tab that slept past the end gets its grace on revalidate", () => {
  const c = clock(); const { timer, events } = timerWith(c);
  timer.start(15); c.skip(16 * 60000);
  timer.revalidate();
  assert.deepEqual(events, ["grace"]);
  c.skip(21000);
  timer.revalidate();
  assert.deepEqual(events, ["grace", "expire"]);
  assert.equal(timer.state().armed, false);
});
await check("revalidate before the end changes nothing", () => {
  const c = clock(); const { timer, events } = timerWith(c);
  timer.start(15); c.advance(60000); timer.revalidate();
  assert.deepEqual(events, []);
  assert.equal(timer.state().armed, true);
});

// ── 2. The tuner's sleep section, against a fake DOM ───────────────────────

const tuner = readFileSync(new URL("../plex-tuner.html", import.meta.url), "utf8");
const moduleSource = readFileSync(new URL("./nostalgex-sleep-timer.js", import.meta.url), "utf8");
const htmlIds = new Set([...tuner.matchAll(/\bid=["']([^"']+)["']/g)].map((m) => m[1]));
function between(start, end) {
  const a = tuner.indexOf(start), b = tuner.indexOf(end, a);
  assert(a >= 0 && b > a, `production source anchors: ${start}`);
  return tuner.slice(a, b);
}

class FakeElement {
  constructor(tag, id = "") {
    this.tagName = tag.toUpperCase(); this.id = id; this.hidden = false; this.children = [];
    this.parentNode = null; this.dataset = {}; this.attrs = {}; this.listeners = {}; this._text = "";
    this.className = ""; this._classes = new Set();
    const self = this;
    this.classList = {
      add: (c) => self._classes.add(c), remove: (c) => self._classes.delete(c), contains: (c) => self._classes.has(c),
      toggle: (c, on) => { const want = on === undefined ? !self._classes.has(c) : !!on; if (want) self._classes.add(c); else self._classes.delete(c); return want; },
    };
  }
  get classes() { return new Set([...this.className.split(/\s+/).filter(Boolean), ...this._classes]); }
  get textContent() { return this._text + this.children.map((c) => c.textContent).join(""); }
  set textContent(v) { this._text = String(v); this.children.forEach((c) => { c.parentNode = null; }); this.children = []; }
  appendChild(child) { if (child.parentNode) child.parentNode.children = child.parentNode.children.filter((c) => c !== child); child.parentNode = this; this.children.push(child); return child; }
  append(...kids) { kids.forEach((k) => this.appendChild(k)); }
  setAttribute(k, v) { this.attrs[k] = String(v); }
  getAttribute(k) { return this.attrs[k] ?? null; }
  addEventListener(name, fn) { (this.listeners[name] ||= []).push(fn); }
  dispatch(name, event = {}) { (this.listeners[name] || []).forEach((fn) => fn({ type: name, preventDefault() {}, stopPropagation() {}, ...event })); }
  click() { this.dispatch("click"); }
  focus() { doc.activeElement = this; }
  descendants() { return this.children.flatMap((c) => [c, ...c.descendants()]); }
  matches(sel) {
    if (sel === "button") return this.tagName === "BUTTON";
    const classes = sel.split(".").filter(Boolean);
    return sel.startsWith(".") && classes.every((c) => this.classes.has(c));
  }
  querySelectorAll(sel) { return this.descendants().filter((e) => e.matches(sel)); }
  querySelector(sel) { return this.querySelectorAll(sel)[0] || null; }
}
let doc;
function tunerFixture({ channel = 7, fullscreen = false, transform = (src) => src } = {}) {
  const elements = new Map();
  const body = new FakeElement("body");
  const calls = { stopVideo: 0, showGuide: 0, switched: [], exitFullscreen: 0 };
  const windowKeydown = [];
  const intervals = new Map();
  let intervalSeq = 0;
  const c = clock();
  doc = {
    body, activeElement: null, hidden: false, fullscreenElement: null, listeners: {},
    getElementById(id) {
      assert(htmlIds.has(id), `fixture element exists in production HTML: ${id}`);
      if (!elements.has(id)) {
        const tag = ["sleep-grace", "pi-back", "tb-sleep"].includes(id) ? "button" : "div";
        const el = new FakeElement(tag, id);
        // Everything that starts hidden in the page starts hidden here.
        if (new RegExp(`id="${id}"[^>]*\\shidden[\\s>]`).test(tuner)) el.hidden = true;
        body.appendChild(el);
        elements.set(id, el);
      }
      return elements.get(id);
    },
    createElement: (tag) => new FakeElement(tag),
    querySelector(sel) {
      const [scope, rest] = sel.split(" ");
      return this.getElementById(scope.slice(1)).querySelector(rest);
    },
    contains: () => true,
    addEventListener(name, fn) { (this.listeners[name] ||= []).push(fn); },
    exitFullscreen() { calls.exitFullscreen++; doc.fullscreenElement = null; return Promise.resolve(); },
  };
  const context = {
    console: { log() {}, warn() {} },
    document: doc, Date: { now: c.now },
    setTimeout: c.setTimeout, clearTimeout: c.clearTimeout,
    setInterval: (fn, ms) => { const id = ++intervalSeq; intervals.set(id, fn); return id; },
    clearInterval: (id) => intervals.delete(id),
    addEventListener: (name, fn, capture) => { if (name === "keydown" && capture) windowKeydown.push(fn); },
    matchMedia: () => ({ matches: false }),
    currentChannel: channel, guideVisible: false, sleepStoppedPlayback: false, playbackInfo: null,
    stopVideo: () => { calls.stopVideo++; }, showGuide: () => { calls.showGuide++; context.guideVisible = true; },
    switchChannel: (id) => { calls.switched.push({ id, from: context.currentChannel, stopped: context.sleepStoppedPlayback }); },
    playbackInfoRows: () => [],
  };
  context.window = context;
  vm.createContext(context);
  const section = between("  /* ══════════════════════════════════════\n     SLEEP TIMER\n", "  // Reflect retro state across every control");
  // The module, with its timers bound to the fake clock, then the production section.
  vm.runInContext(moduleSource + "\n" + transform(section).replace(
    "NostalgexSleepTimer.createSleepTimer({",
    "NostalgexSleepTimer.createSleepTimer({ now: Date.now, setTimeout, clearTimeout,"), context);
  if (fullscreen) doc.fullscreenElement = doc.getElementById("video-container");
  const tickAll = () => [...intervals.values()].forEach((fn) => fn());
  const key = (k) => {
    const event = { key: k, prevented: false, stopped: false, preventDefault() { this.prevented = true; },
      stopPropagation() { this.stopped = true; }, stopImmediatePropagation() { this.stopped = true; } };
    windowKeydown.forEach((fn) => fn(event));
    return event;
  };
  return { context, c, calls, el: (id) => doc.getElementById(id), tickAll, key, intervals };
}
const chipTexts = (f) => f.el("cfg-sleep-chips").children.map((b) => `${b.textContent}${b.classList.contains("active") ? "*" : ""}`);
const rowTexts = (f) => f.el("sleep-rows").children.map((b) => `${b.children[0].textContent}|${b.children[1].textContent}`);

await check("tuner: off at load, OFF everywhere, OFF row marked ACTIVE", () => {
  const f = tunerFixture();
  assert.equal(f.el("tb-sleep-val").textContent, "OFF");
  assert.equal(f.el("tb-sleep-val").classList.contains("off"), true);
  assert.equal(f.el("dw-sleep-val").textContent, "OFF");
  assert.deepEqual(chipTexts(f), ["OFF*", "15 MIN", "30 MIN", "1 HR"]);
  assert.deepEqual(rowTexts(f), ["OFF|ACTIVE", "15 MIN|", "30 MIN|", "1 HR|"]);
  assert.equal(f.intervals.size, 0, "nothing ticks while off");
});
await check("tuner: choosing 30 MIN in the picker arms it, closes the picker and shows the countdown", () => {
  const f = tunerFixture();
  f.context.openSleepDialog();
  assert.equal(f.el("sleep-dialog").hidden, false);
  f.el("sleep-rows").children[2].click();
  assert.equal(f.el("sleep-dialog").hidden, true);
  assert.equal(f.el("tb-sleep-val").textContent, "30:00");
  assert.equal(f.el("tb-sleep-val").classList.contains("off"), false);
  assert.deepEqual(chipTexts(f), ["OFF", "15 MIN", "30 MIN 30:00*", "1 HR"]);
  f.c.advance(61000); f.tickAll();
  assert.equal(f.el("dw-sleep-val").textContent, "28:59");
  assert.deepEqual(rowTexts(f), ["OFF|", "15 MIN|", "30 MIN|28:59", "1 HR|"]);
  assert.equal(f.el("tb-sleep").getAttribute("aria-label"), "Sleep timer, 28:59 left");
});
await check("tuner: OFF in Settings cancels, and the countdown stops", () => {
  const f = tunerFixture();
  f.el("cfg-sleep-chips").children[3].click();
  // Capped at 59:59 so the half-width rail button never shows hours.
  assert.equal(f.el("tb-sleep-val").textContent, "59:59");
  f.el("cfg-sleep-chips").children[0].click();
  assert.equal(f.el("tb-sleep-val").textContent, "OFF");
  assert.equal(f.intervals.size, 0);
  f.c.advance(2 * 3600000);
  assert.equal(f.calls.stopVideo, 0);
  assert.equal(f.el("sleep-grace").hidden, true);
});
await check("tuner: at zero the prompt shows, counts down, and after 20 s playback stops", () => {
  const f = tunerFixture();
  f.el("cfg-sleep-chips").children[1].click();
  f.c.advance(15 * 60000);
  assert.equal(f.el("sleep-grace").hidden, false);
  assert.equal(f.el("sleep-grace-count").textContent, "SLEEPING IN 0:20");
  assert.equal(f.el("sleep-grace-hint").textContent, "CLICK OR PRESS ANY KEY TO KEEP WATCHING");
  f.c.advance(5000); f.tickAll();
  assert.equal(f.el("sleep-grace-count").textContent, "SLEEPING IN 0:15");
  assert.equal(f.calls.stopVideo, 0);
  f.c.advance(15000);
  assert.equal(f.calls.stopVideo, 1, "stopVideo: reports the stop, pauses, drops the server stream");
  assert.equal(f.el("sleep-grace").hidden, true);
  assert.equal(f.el("sleep-ended").hidden, false);
  assert.equal(f.calls.showGuide, 1);
  assert.equal(f.context.sleepStoppedPlayback, true);
  assert.equal(f.el("tb-sleep-val").textContent, "OFF");
  assert.equal(f.intervals.size, 0);
});
await check("tuner: expiry leaves full screen, and the prompt is drawn inside the full screen element", () => {
  const f = tunerFixture({ fullscreen: true });
  f.el("cfg-sleep-chips").children[1].click();
  f.c.advance(15 * 60000);
  assert.equal(f.el("sleep-grace").parentNode, f.el("video-container"));
  f.c.advance(20000);
  assert.equal(f.calls.exitFullscreen, 1);
});
await check("tuner: a key in the grace keeps watching and never reaches the shortcuts", () => {
  const f = tunerFixture();
  f.el("cfg-sleep-chips").children[1].click();
  f.c.advance(15 * 60000 + 2000);
  const ev = f.key("ArrowRight");
  assert.equal(ev.prevented, true);
  assert.equal(ev.stopped, true);
  assert.equal(f.el("sleep-grace").hidden, true);
  f.c.advance(3600000);
  assert.equal(f.calls.stopVideo, 0);
  assert.equal(f.el("tb-sleep-val").textContent, "OFF");
  const later = f.key("ArrowRight");
  assert.equal(later.stopped, false, "outside a grace keys pass through");
});
await check("tuner: a click (a TV remote's OK) on the prompt keeps watching", () => {
  const f = tunerFixture();
  f.el("cfg-sleep-chips").children[1].click();
  f.c.advance(15 * 60000 + 2000);
  f.el("sleep-grace").click();
  f.c.advance(60000);
  assert.equal(f.calls.stopVideo, 0);
  assert.equal(f.el("sleep-grace").hidden, true);
});
await check("tuner: after expiry, picking the same channel in the guide tunes it again", () => {
  const f = tunerFixture({ channel: 7 });
  f.context.tuneFromGuide(7);
  assert.deepEqual(f.calls.switched, [{ id: 7, from: 7, stopped: false }], "normally a same-channel pick is left to switchChannel's no-op");
  f.el("cfg-sleep-chips").children[1].click();
  f.c.advance(15 * 60000 + 20000);
  f.context.tuneFromGuide(7);
  assert.deepEqual(f.calls.switched[1], { id: 7, from: null, stopped: true }, "currentChannel cleared so switchChannel tunes");
});

// Negative controls: break the production section in memory and the matching check must
// fail on its own assertion. The file on disk is never touched.
function replaceOnce(source, before, after) {
  if (source.split(before).length !== 2) throw new Error(`negative control needs one target: ${before}`);
  return source.replace(before, after);
}
await check("negative control: expiry without stopVideo is caught", () => {
  const f = tunerFixture({ transform: (src) => replaceOnce(src, "    stopVideo();\n    sleepStoppedPlayback = true;", "    sleepStoppedPlayback = true;") });
  f.el("cfg-sleep-chips").children[1].click();
  f.c.advance(15 * 60000 + 20000);
  assert.equal(f.calls.stopVideo, 0);
});
await check("negative control: without the window key capture a key in the grace is not taken", () => {
  const f = tunerFixture({ transform: (src) => replaceOnce(src,
    "window.addEventListener('keydown', (e) => { if (sleepTimer.state().graceActive) keepWatchingFromGrace(e); }, true);", "") });
  f.el("cfg-sleep-chips").children[1].click();
  f.c.advance(15 * 60000 + 2000);
  assert.equal(f.key("ArrowRight").stopped, false);
  f.c.advance(20000);
  assert.equal(f.calls.stopVideo, 1);
});

if (failures.length) {
  console.error(`sleep-timer: ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error("  " + f);
  process.exit(1);
}
console.log(`sleep-timer: ${passed} passed`);
