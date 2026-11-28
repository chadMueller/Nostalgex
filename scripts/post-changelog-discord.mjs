#!/usr/bin/env node
/**
 * Posts a changelog entry to Discord.
 *
 * content/changelog.json stays the single source of release notes: the site renders from
 * it (render-changelog.mjs), and so does this. Writing the notes twice is how the website
 * and the announcement drift apart.
 *
 *   node scripts/post-changelog-discord.mjs              # preview the newest entry
 *   node scripts/post-changelog-discord.mjs --post       # send it
 *   node scripts/post-changelog-discord.mjs --version 1.0.22 --post
 *
 * Needs DISCORD_WEBHOOK_URL (channel settings -> Integrations -> Webhooks). Treat it as a
 * secret: anyone holding it can post as you. Env var or CI secret, never the repo.
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2);
const POST = args.includes('--post');
const wanted = args.includes('--version') ? args[args.indexOf('--version') + 1] : null;

const { entries } = JSON.parse(fs.readFileSync(path.join(ROOT, 'content/changelog.json'), 'utf8'));
const entry = wanted ? entries.find(e => e.version === wanted) : entries[0];
if (!entry) { console.error(`No changelog entry${wanted ? ` for ${wanted}` : ''}.`); process.exit(1); }

/** Discord embed. Keeps the bullets as a list and the version as the title. */
const embed = {
  title: `Nostalgex ${entry.version} — ${entry.title}`,
  description: [
    entry.bullets.map(b => `• ${b}`).join('\n\n'),
    ...[['New channels', entry.newChannels], ['Fixes', entry.fixes]]
      .filter(([, items]) => Array.isArray(items) && items.length > 0)
      .map(([label, items]) => `**${label}**\n` + items.map(b => `• ${b}`).join('\n\n')),
  ].join('\n\n'),
  color: 0x06ed8d,
  footer: { text: entry.date },
  url: 'https://nostalgex.app',
};

if (!POST) {
  console.log(`--- preview: ${entry.version} (${entry.date}) ---\n`);
  console.log(embed.title + '\n');
  console.log(embed.description);
  console.log('\n--- dry run. add --post to send ---');
  process.exit(0);
}

const url = process.env.DISCORD_WEBHOOK_URL;
if (!url) { console.error('Set DISCORD_WEBHOOK_URL.'); process.exit(1); }
const res = await fetch(url, {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ embeds: [embed] }),
});
if (!res.ok) { console.error(`Discord returned ${res.status}: ${await res.text()}`); process.exit(1); }
console.log(`Posted ${entry.version} to Discord.`);
