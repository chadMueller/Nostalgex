#!/usr/bin/env node
// The refresh rules of an open page (LibrarySnapshotStore, AppState+Schedule, LibraryChangeSignature).
await import("./nostalgex-library-refresh.js");
const R = globalThis.NostalgexLibraryRefresh;
let passed = 0; const failures = [];
const check = (label, ok, detail = "") => { if (ok) passed += 1; else failures.push(`${label}${detail ? `: ${detail}` : ""}`); };
check("the numbers are the Apple TV's", R.REFRESH_AFTER_SECONDS === 21600 && R.CHECK_EVERY_SECONDS === 900 && R.HARD_CAP_SECONDS === 86400);
check("signature: sections sorted, updatedAt and contentChangedAt", R.signature("srv", [{ key: "2", updatedAt: 5, contentChangedAt: 7 }, { key: "1", updatedAt: 3 }]) === "srv:1=u3/c0,2=u5/c7");
check("signature ignores scannedAt", R.signature("srv", [{ key: "1", updatedAt: 3, scannedAt: 99 }]) === R.signature("srv", [{ key: "1", updatedAt: 3, scannedAt: 100 }]));
check("a section with neither field: no signature", R.signature("srv", [{ key: "1", updatedAt: 3 }, { key: "2" }]) === null);
check("no sections: no signature", R.signature("srv", []) === null);
check("combine sorts, and one server without a signature means none", R.combine(["b:1", "a:2"]) === "a:2;b:1" && R.combine(["a:1", null]) === null && R.combine([]) === null);
check("unchanged and under the cap: skip", R.shouldSkipRefresh(3600, "x", "x", 86400));
check("changed: no skip", !R.shouldSkipRefresh(3600, "x", "y", 86400));
check("the cap passed: no skip even if unchanged", !R.shouldSkipRefresh(86400, "x", "x", 86400) && !R.shouldSkipRefresh(90000, "x", "x"));
check("nothing stored or nothing observed: no skip", !R.shouldSkipRefresh(10, null, "x") && !R.shouldSkipRefresh(10, "x", null));
check("due after 6 hours, not before", !R.isDue(21599, 0, 0) && R.isDue(21600, 0, 0));
check("a check 1 hour ago holds it back", !R.isDue(30000, 0, 26400) && R.isDue(30000, 0, 8400));
if (failures.length) { console.error(`library refresh smoke: ${failures.length} failed, ${passed} passed`); for (const f of failures) console.error("  FAIL " + f); process.exit(1); }
console.log(`library refresh smoke: ${passed} checks passed`);
