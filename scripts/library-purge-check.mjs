#!/usr/bin/env node
/**
 * A library refresh must keep yesterday's stored day (#315).
 *
 * A programme that runs over midnight is on air from yesterday's day file until it ends. `AppState+Library.swift` ends a
 * library refresh by purging old days; when that purge kept only today's, a refresh just after midnight blanked Now Playing
 * and Up Next on every channel whose programme ran over. `DailyManifestStore.purgeStaleDays` keeps today and yesterday,
 * and no test reaches the call site, so this holds it: the refresh calls `purgeStaleDays`, and never `purgeDays(keeping:`
 * with today alone.
 *
 * No dependencies: `node scripts/library-purge-check.mjs`. Part of `npm test`.
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const file = 'Nostalgex/Nostalgex/App/AppState+Library.swift';
const code = fs.readFileSync(path.join(root, file), 'utf8')
  .replace(/\/\*[\s\S]*?\*\//g, '')
  .replace(/\/\/.*$/gm, '');

const problems = [];
if (!/DailyManifestStore\.purgeStaleDays\(/.test(code)) problems.push(`${file} does not call DailyManifestStore.purgeStaleDays(`);
if (/DailyManifestStore\.purgeDays\(/.test(code)) problems.push(`${file} calls DailyManifestStore.purgeDays( directly: that is how yesterday's day got deleted`);

if (problems.length) {
  console.error(`library purge check: ${problems.length} problem(s)`);
  for (const p of problems) console.error(`  ${p}`);
  process.exit(1);
}
console.log('library purge check: the library refresh purges through purgeStaleDays, which keeps yesterday');
