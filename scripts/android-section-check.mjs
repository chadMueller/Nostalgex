#!/usr/bin/env node
/**
 * Holds the Android TV page honest. The page (android.html) is public, but nothing can be installed
 * from Google Play yet, so the site must not carry a Play link, a beta or join link, or a date.
 *
 * content/android.json says "playLive": false until the Play listing is public. While it is false this
 * fails when:
 *   - android.html, its /android footer link on the other pages, its sitemap line, its vite input or its
 *     vercel rewrite are missing;
 *   - any public page, llms.txt or the README has a Play store link or a Play testing (join) link;
 *   - android.html says "beta", has a button pointing at a placeholder, or carries a year/month date.
 * When "playLive" is true it wants playUrl to be the Play listing for com.muellhaus.nostalgex and the
 * page to link to exactly that. Flip this check as the last step of the checklist in content/android.json.
 *
 * Runs as part of `npm test`.
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const read = (p) => fs.readFileSync(path.join(ROOT, p), 'utf8');
const cfg = JSON.parse(read('content/android.json'));
const failures = [];

const pages = fs.readdirSync(ROOT).filter((f) => f.endsWith('.html'));
const PLAY_LINK = /play\.google\.com\/(?:store\/apps|apps\/testing|apps\/internaltest)/;
const page = read('android.html');

// The page, and everything that points at it.
for (const f of pages.filter((f) => !['android.html', 'privacy.html', 'terms.html', '404.html', 'web-tuner.html', 'plex-tuner.html'].includes(f))) {
  if (!/href="\/android">Android TV<\/a>/.test(read(f))) failures.push(`${f} has no Android TV footer link`);
}
if (!/href="\/android">Android TV<\/a>/.test(read('scripts/site-chrome.mjs'))) failures.push('scripts/site-chrome.mjs has no Android TV footer link');
if (!/nostalgex\.app\/android</.test(read('public/sitemap.xml'))) failures.push('public/sitemap.xml has no /android line');
if (!/android: resolve\(__dirname, 'android\.html'\)/.test(read('vite.config.js'))) failures.push('vite.config.js does not build android.html');
if (!/"source": "\/android"/.test(read('vercel.json'))) failures.push('vercel.json has no /android rewrite');
if (!/href="\/android"/.test(read('index.html'))) failures.push('index.html has no Android TV tile');

if (cfg.playLive === true) {
  if (!/^https:\/\/play\.google\.com\/store\/apps\/details\?id=com\.muellhaus\.nostalgex/.test(cfg.playUrl || '')) {
    failures.push('android.json says playLive: true but playUrl is not the Play listing for com.muellhaus.nostalgex');
  } else if (!page.includes(`href="${cfg.playUrl.replaceAll('&', '&amp;')}"`) && !page.includes(`href="${cfg.playUrl}"`)) {
    failures.push('android.html does not link to playUrl');
  }
} else {
  if (cfg.playUrl !== null) failures.push('android.json has a playUrl while playLive is false');
  for (const f of [...pages, 'public/llms.txt', 'README.md']) {
    if (PLAY_LINK.test(read(f))) failures.push(`${f} has a Google Play link while playLive is false`);
  }
  if (/PLAY_URL/.test(page)) failures.push('android.html has a PLAY_URL placeholder');
  if (/\bbeta\b/i.test(page.replace(/<!--[\s\S]*?-->/g, ''))) failures.push('android.html says beta');
  if (/\b(20\d\d|january|february|march|april|may \d|june|july|august|september|october|november|december)\b/i.test(page.replace(/<!--[\s\S]*?-->/g, '').replace(/<(script|style)[\s\S]*?<\/\1>/g, '').replace(/<[^>]+>/g, ' '))) {
    failures.push('android.html shows a date');
  }
}
if (/contributor|owenvoke|owen\b/i.test(page.replace(/<!--[\s\S]*?-->/g, ''))) failures.push('android.html names a contributor');

console.log(`android-section-check: page live, Play ${cfg.playLive ? 'link set' : 'link absent'}. ${failures.length ? 'FAILED' : 'OK'}`);
if (failures.length) {
  for (const f of failures) console.error(`  ${f}`);
  process.exit(1);
}
