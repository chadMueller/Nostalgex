#!/usr/bin/env node
/**
 * Holds the Android TV section off until Google Play shows the app.
 *
 * content/android.json says "playLive": false while nothing can be installed. This fails when anything
 * public has started to point at Android TV anyway: a root android.html, an /android link in a page or
 * the shared footer, a sitemap or llms.txt line, a vercel rewrite, or a Play or beta link. It also fails
 * if "playLive" is flipped to true without a Play URL, so the flip cannot go out half done.
 *
 * Runs as part of `npm test`. When the section goes live, this file is updated as the last step of the
 * checklist in content/android.json.
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const cfg = JSON.parse(fs.readFileSync(path.join(ROOT, 'content/android.json'), 'utf8'));
const read = (p) => fs.readFileSync(path.join(ROOT, p), 'utf8');
const failures = [];

if (cfg.playLive === true) {
  if (!/^https:\/\/play\.google\.com\/store\/apps\/details\?id=com\.muellhaus\.nostalgex/.test(cfg.playUrl || '')) {
    failures.push('android.json says playLive: true but playUrl is not the Play listing for com.muellhaus.nostalgex');
  }
  console.log(`android-section-check: live. Update this check for the live state. ${failures.length ? 'FAILED' : 'OK'}`);
} else {
  if (cfg.playUrl !== null) failures.push('android.json has a playUrl while playLive is false');
  if (fs.existsSync(path.join(ROOT, 'android.html'))) failures.push('android.html exists at the repo root while the section is off');
  const pages = fs.readdirSync(ROOT).filter((f) => f.endsWith('.html'));
  for (const f of pages) {
    if (/href="\/android"/.test(read(f))) failures.push(`${f} links to /android while the section is off`);
  }
  for (const f of ['scripts/site-chrome.mjs', 'public/sitemap.xml', 'public/llms.txt', 'vercel.json']) {
    if (/\/android\b/.test(read(f))) failures.push(`${f} mentions /android while the section is off`);
  }
  const everyPublicFile = [...pages, 'public/llms.txt', 'README.md'];
  for (const f of everyPublicFile) {
    if (/play\.google\.com\/apps\/testing|play\.google\.com\/store\/apps\/details\?id=com\.muellhaus\.nostalgex/.test(read(f))) {
      failures.push(`${f} has a Google Play link while the section is off`);
    }
  }
  console.log(`android-section-check: section is off (playLive false). ${failures.length ? 'FAILED' : 'Nothing public points at it. OK'}`);
}

if (failures.length) {
  for (const f of failures) console.error(`  ${f}`);
  process.exit(1);
}
