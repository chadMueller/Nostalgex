#!/usr/bin/env node
/**
 * The README's platform headings carry the release that is live, and fail here when it moves.
 *
 *   ## [App Store badge] Apple TV app `1.0.28`     the newest `released: true` Apple TV entry in
 *                                                  content/changelog.json (the App Store version:
 *                                                  an entry in review is `released: false`)
 *   ## [icon] Web tuner `1.0.13`                   package.json "tunerVersion"
 *   ## [icon] Docker container `1.0.13`            package.json "tunerVersion"
 *
 * and the Docker section's "Latest: `tuner-vX.Y.Z`" line, which is the same number. The README is
 * written by hand, so this is the one thing that notices when a release changes a number and not
 * the heading: bump `tunerVersion`, or flip an Apple TV entry to `released: true`, and `npm test`
 * says which heading to edit. Each heading keeps its icon or badge (an <img>), which is also
 * checked. A Roku heading is not here yet: it arrives with the public listing.
 *
 * Runs as part of `npm test`.
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const readme = fs.readFileSync(path.join(ROOT, 'README.md'), 'utf8');
const pkg = JSON.parse(fs.readFileSync(path.join(ROOT, 'package.json'), 'utf8'));
const { entries } = JSON.parse(fs.readFileSync(path.join(ROOT, 'content/changelog.json'), 'utf8'));

// The App Store version: the newest Apple TV entry that has shipped. (The web tuner's own entry
// is versioned "WEB TUNER", not a number, so it never matches.)
const appleTv = (entries.find((e) => e.released === true && /^\d+\.\d+\.\d+$/.test(String(e.version))) || {}).version;
const tuner = pkg.tunerVersion;

const failures = [];
const want = [
  { label: 'Apple TV app', version: appleTv, source: 'the newest `released: true` Apple TV entry in content/changelog.json' },
  { label: 'Web tuner', version: tuner, source: 'package.json "tunerVersion"' },
  { label: 'Docker container', version: tuner, source: 'package.json "tunerVersion"' },
];
if (!appleTv) failures.push('content/changelog.json has no released Apple TV entry');
if (!/^\d+\.\d+\.\d+$/.test(String(tuner))) failures.push(`package.json "tunerVersion" is "${tuner}", not a release number`);

for (const w of want) {
  const heading = readme.split('\n').find((l) => /^## /.test(l) && l.replace(/<[^>]*>/g, '').includes(w.label));
  if (!heading) { failures.push(`README has no "## ... ${w.label}" heading`); continue; }
  const got = (/`(\d+\.\d+\.\d+)`\s*$/.exec(heading) || [])[1];
  if (got !== w.version) failures.push(`README heading "${w.label}" says ${got ? `\`${got}\`` : 'no version'}, ${w.source} says \`${w.version}\`. Edit the heading.`);
  if (!/<img /.test(heading)) failures.push(`README heading "${w.label}" lost its icon or badge (the <img>)`);
}

const latest = (/\*\*Latest: `tuner-v(\d+\.\d+\.\d+)`\.\*\*/.exec(readme) || [])[1];
if (latest !== tuner) failures.push(`README "Latest: \`tuner-v${latest}\`" line disagrees with package.json "tunerVersion" (${tuner}). Edit it.`);

if (failures.length) {
  console.error(`readme versions: ${failures.length} problem(s)`);
  for (const f of failures) console.error(`  ${f}`);
  process.exit(1);
}
console.log(`readme versions: Apple TV app ${appleTv}, Web tuner ${tuner}, Docker container ${tuner}, Latest tuner-v${latest}. OK`);
