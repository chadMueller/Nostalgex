#!/usr/bin/env node
/**
 * Says whether the public App Store page shows a version yet. The site speaks only about
 * the version people can install today, so the Apple TV flip (changelog entry
 * `released: true`, README heading, the apple-tv page) waits for this to pass.
 *
 *   node scripts/store-gate.mjs appletv 1.0.33
 *
 * Exit 0: the iTunes lookup for the app (id 6762563534, US store) shows exactly that version.
 * Exit 1: it shows something else, or the lookup failed. Nothing is changed either way.
 *
 * App Store Connect saying "Ready for Sale" is not enough: the public lookup can lag by hours.
 * There is no gate for Roku or Android here; Chad confirms those by eye (Roku Channel Store page,
 * Play listing).
 */
const [, , surface, want] = process.argv;
if (surface !== 'appletv' || !/^\d+\.\d+\.\d+$/.test(want || '')) {
  console.error('usage: node scripts/store-gate.mjs appletv <version>');
  process.exit(2);
}
let got = null;
try {
  const res = await fetch('https://itunes.apple.com/lookup?id=6762563534&country=us', { headers: { 'cache-control': 'no-cache' } });
  const json = await res.json();
  got = json.results?.[0]?.version ?? null;
} catch (e) {
  console.error(`store-gate: lookup failed (${e.message})`);
  process.exit(1);
}
if (got === want) {
  console.log(`store-gate: the App Store shows ${got}. The Apple TV flip can go.`);
  process.exit(0);
}
console.log(`store-gate: the App Store shows ${got ?? 'nothing'}, not ${want}. Hold the Apple TV flip.`);
process.exit(1);
