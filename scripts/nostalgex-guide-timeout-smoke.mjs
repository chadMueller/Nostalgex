#!/usr/bin/env node
// GUIDE TIMEOUT: the default, the cycle and the clock (GuideTimeout.swift).
await import("./nostalgex-guide-timeout.js");
const G = globalThis.NostalgexGuideTimeout;
let passed = 0; const failures = [];
const check = (label, ok, detail = "") => { if (ok) passed += 1; else failures.push(`${label}${detail ? `: ${detail}` : ""}`); };
check("the key is the Apple TV's", G.STORAGE_KEY === "nostalgex_guide_timeout");
check("nothing stored is 5 MIN", G.parse(null) === "5m" && G.parse(undefined) === "5m" && G.parse("") === "5m");
check("garbage is 5 MIN", G.parse("30m") === "5m" && G.parse("OFF") === "5m" && G.parse("1") === "5m");
check("the three values read back", G.parse("off") === "off" && G.parse("5m") === "5m" && G.parse("15m") === "15m");
check("one press goes OFF, 5 MIN, 15 MIN and round", G.next("off") === "5m" && G.next("5m") === "15m" && G.next("15m") === "off");
check("labels", G.label("off") === "OFF" && G.label("5m") === "5 MIN" && G.label("15m") === "15 MIN");
check("seconds", G.seconds("off") === 0 && G.seconds("5m") === 300 && G.seconds("15m") === 900);
check("5 MIN is due at 5 minutes, not before", !G.isDue("5m", 0, 299999) && G.isDue("5m", 0, 300000));
check("15 MIN is due at 15 minutes", !G.isDue("15m", 0, 899999) && G.isDue("15m", 0, 900000));
check("OFF is never due", !G.isDue("off", 0, 1e12));
if (failures.length) { console.error(`guide timeout smoke: ${failures.length} failed, ${passed} passed`); for (const f of failures) console.error("  FAIL " + f); process.exit(1); }
console.log(`guide timeout smoke: ${passed} checks passed`);
