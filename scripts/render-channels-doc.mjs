import { readFile, writeFile } from "node:fs/promises";

// Generates CHANNELS.md entirely from channels.json — the same config the tvOS
// app, the web tuner and devtools consume. CHANNELS.md is a BUILD ARTIFACT: do
// not hand-edit it, your edit will be overwritten. Prose that must survive
// regeneration lives in PREAMBLE / EXCLUSIVITY_NOTES below.
//
//   node scripts/render-channels-doc.mjs      (or: npm run channels:doc)
//
// CI check (nothing is written when the file is already current):
//   npm run channels:doc:check
//
// Modelled on scripts/render-lineup.mjs, which renders the same config into
// index.html. Difference: that one splices into markers in an existing file,
// this one owns the whole document.

const CHANNELS_PATH = new URL("../channels.json", import.meta.url);
const OUT_PATH = new URL("../CHANNELS.md", import.meta.url);

const CHECK_ONLY = process.argv.includes("--check");

// ── Hand-written guidance, preserved across regenerations ──────────────────

const PREAMBLE = `# Nostalgex Channel Guide

<!-- GENERATED FILE — do not edit by hand. Run \`npm run channels:doc\` after any
     channels.json change. Source: scripts/render-channels-doc.mjs -->

Quick reference for every channel and bundle. Source of truth: \`channels.json\`.

## Read this before editing a channel

**\`id\` and \`number\` are NOT the same thing.** A channel's \`number\` is what
viewers tune to; its \`id\` is the stable key everything else references. They
drifted apart as channels were renumbered, and today they differ for many
channels — for example \`id\` 40 is **CH{{40}} TRUE CRIME**, and \`id\` 211 is
**CH{{211}} CRITERION**. Get it wrong and you edit a different channel than the one
you meant.

Which key does what:

| Uses \`id\` | Uses \`number\` |
|---|---|
| \`channels-memberships.json\` (the TMDB membership manifest) | The on-screen channel number and guide ordering |
| \`exclusiveRules.channelID\` / \`channelIDs\` | Nothing else |
| \`bundles[].channelIDs\` | |
| Daily EPG manifest cache keys | |

Every table below shows both.

**Pool filter logic must stay aligned across three implementations.**
\`scripts/nostalgex-channel-filter.cjs\` (web tuner + devtools) mirrors
\`Nostalgex/Nostalgex/App/AppState+Channels.swift\` → \`filterItems\` (tvOS).
They do not share code, so a rule change has to land in both or the platforms
drift. TMDB membership manifest: \`channels-memberships.json\`.

**Schedule ordering must stay aligned too.**
\`scripts/nostalgex-daily-manifest.js\` mirrors
\`Nostalgex/Nostalgex/Models/SchedulePoolOrdering.swift\` and
\`Nostalgex/Nostalgex/Services/DailyManifestScheduler.swift\`, bit-for-bit, so
web and Apple TV air the same program at the same time.

**Keyword matches are ADDITIVE.** They broaden what a channel can pull in; they
never gate it. Never gate keywords on a broad genre like Drama — it leaks
unrelated titles. \`keywordGatedGenres\` is the deliberate exception, and it must
only name the channel's own defining genre.

**\`rewatched\` means \`viewCount >= 3\`** in both implementations.
`;

const EXCLUSIVITY_INTRO = `Exclusive rules block a title from EVERY channel except the listed channel
\`id\`s. **Only lock a title to a channel when you are 95%+ sure it belongs
nowhere else — default to overlap.** Over-locking hides content: locking Die
Hard into the holiday channel made it vanish from action for eleven months of
the year.

A lock reads the item's own title (the song for a music video, never the
artist), with any " (YYYY)" suffix ignored. \`editorialTitles\` must match the
whole title exactly. \`titleContains\` matches whole words only, the same rule
as a channel's \`titleContains\`: "Noel" catches Noel, not Noelle, and "Santa
Claus" does not catch Santana. A lock can be scoped with \`type\` and \`source\`;
then it only applies to items of that type from that kind of library. Both filters
implement it (\`ExclusiveRule.matches\` in Swift, \`exclusiveRuleMatches\` in the
web filter) and \`scripts/filter-golden.json\` pins the cases.`;

// Long-form context per exclusive rule, keyed by the sorted channel-id list.
// Keeps the "why" from the hand-written doc alive after regeneration.
const EXCLUSIVITY_NOTES = {
  "130,409,410,411,412,413,414": `Christmas films belong to the TIS THE SEASON channels, including the two TV
  channels, which air half-hour specials stored as films. Films in a movie library
  only (\`type: movie\`, \`source: movie\`), so a show with Santa in its name and a
  Christmas song on a music video stay free. Title words are the ones that measured
  95% or more Christmas across TMDB films with 25+ votes (2026-10-18): "Holiday"
  (66%, Mr. Bean's Holiday, Roman Holiday), "Santa" (87%, Santa Sangre, Santa Fe
  Trail), "Merry", "Snowman", "Grinch", "Scrooge", "Nutcracker" and "Reindeer" were
  dropped, so the channels still match them but no longer lock them away. Die Hard,
  Lethal Weapon, Reindeer Games, Rocky IV, Gremlins, Batman Returns, Trading Places,
  The Family Man, While You Were Sleeping and The Shop Around the Corner are
  deliberately NOT locked: Christmas-set, but they belong on their year-round channels
  too.`,
  "32,60": `Anime is claimed by genre \`Anime\` OR by a TMDB-manifest claim
  (\`manifestExclusive\`), so manifest-claimed anime is blocked from the other
  animation channels even when Plex only tags it "Animation". The manifest
  builder gates these channels with \`requireGenres: ["Animation"]\` +
  \`requireOriginalLanguage: ["ja"]\` + \`autoSweepCollections: false\` so TMDB
  similar/collection noise cannot be claimed — that blocks live-action (Spy Kids)
  AND Western animation (An American Tail, Avatar, Castlevania). Strict Japanese
  anime only. Re-run the keyword tuner to apply changes.`,
  "132,415": `The Scream and Halloween films, by exact title, so SCREAM ADULTS and
  SLASHER own them rather than the other horror channels. It used to match any
  title containing "scream" or "halloween", which hid Kicking & Screaming and
  Hubie Halloween from every channel they belong on.`,
};

// ── Rule summarising ───────────────────────────────────────────────────────

const TYPE_LABEL = { movie: "Movies", episode: "Episodes" };
const SOURCE_LABEL = { movie: "movie library", tv: "TV library", musicVideo: "music videos" };

function list(arr, max = 6) {
  if (!arr?.length) return "";
  if (arr.length <= max) return arr.join("/");
  return `${arr.slice(0, max).join("/")} +${arr.length - max} more`;
}

function yearRange(yr) {
  const min = yr.min ?? "…";
  const max = yr.max ?? "…";
  return `${min}-${max}`;
}

/** Human-readable summary of a channel's rules, in evaluation-ish order. */
function summariseRules(rules) {
  if (!rules) return "no rules (everything qualifies)";
  const parts = [];
  const g = rules.genres || {};

  if (rules.manifestOnly) {
    parts.push(rules.manifestOnlyGenreFallback
      ? "**TMDB manifest + gated genre/keyword fallback**"
      : "**TMDB manifest only**");
  }
  if (rules.episodeTitleContains?.length) parts.push(`episode title words (${rules.episodeTitleContains.length})`);
  if (rules.episodeSeasonalTitleContains?.length) {
    const w = rules.episodeAirWindow || {};
    parts.push(`seasonal title words (${rules.episodeSeasonalTitleContains.length}) if aired ${w.from ?? "?"} to ${w.to ?? "?"}`);
  }
  if (rules.episodeSummaryContains?.length) parts.push(`summary words (${rules.episodeSummaryContains.length})`);
  if (rules.episodeTitleExcludes?.length) parts.push(`episode title blocklist (${rules.episodeTitleExcludes.length})`);
  if (rules.matchTmdbGenres) parts.push("genres include TMDB's");
  if (rules.source) parts.push(`source: ${SOURCE_LABEL[rules.source] || rules.source}`);
  if (g.include?.length) parts.push(`incl ${list(g.include)}`);
  if (g.requireAll?.length) parts.push(`needs ALL ${g.requireAll.join(" + ")}`);
  if (g.exclude?.length) parts.push(`no ${list(g.exclude, 8)}`);
  if (rules.studios?.length) parts.push(`studios ${list(rules.studios, 3)}`);
  if (rules.networks?.length) parts.push(`networks ${list(rules.networks, 3)}`);
  if (rules.productionCompanies?.length) parts.push(`prodCo ${list(rules.productionCompanies, 3)}`);
  if (rules.titleContains?.length) parts.push(`title allowlist (${rules.titleContains.length})`);
  if (rules.titleExcludes?.length) parts.push(`title blocklist (${rules.titleExcludes.length})`);
  if (rules.editorialOverrides?.length) parts.push(`editorial always-in (${rules.editorialOverrides.length})`);
  if (rules.keywords?.length) parts.push(`kw +${rules.keywords.length}`);
  if (rules.keywordsRequireAnyGenre?.length) parts.push(`kw needs genre ${list(rules.keywordsRequireAnyGenre, 4)}`);
  if (rules.keywordGatedGenres?.length) parts.push(`kw-gated genre ${list(rules.keywordGatedGenres, 4)}`);
  if (rules.keywordsExclude?.length) parts.push(`kw excl (${rules.keywordsExclude.length})`);
  if (rules.yearRange) parts.push(yearRange(rules.yearRange));
  if (rules.releasedWithinMonths) parts.push(`released ≤ ${rules.releasedWithinMonths} mo ago`);
  if (rules.addedWithinDays) parts.push(`added ≤ ${rules.addedWithinDays} d ago`);
  if (rules.contentRatings?.length) {
    parts.push(`rated ${list(rules.contentRatings, 8)}${rules.allowUnrated ? "/unrated" : ""}`);
  } else if (rules.allowUnrated) {
    parts.push("unrated allowed");
  }
  if (rules.ratingMin != null) parts.push(`Plex rating ≥ ${rules.ratingMin}`);
  if (rules.imdbRatingMin != null) parts.push(`**IMDb ≥ ${rules.imdbRatingMin}**`);
  if (rules.imdbVotesMin != null) parts.push(`**IMDb votes ≥ ${rules.imdbVotesMin.toLocaleString("en-US")}**`);
  if (rules.rtScoreMin != null) parts.push(`RT ≥ ${rules.rtScoreMin}`);
  if (rules.metacriticMin != null) parts.push(`Metacritic ≥ ${rules.metacriticMin}`);
  if (rules.wonOscar) parts.push("Oscar winner");
  if (rules.durationRange) {
    const { min, max } = rules.durationRange;
    if (min != null && max != null) parts.push(`${min}-${max} min`);
    else if (min != null) parts.push(`≥ ${min} min`);
    else if (max != null) parts.push(`≤ ${max} min`);
  }
  if (rules.rewatched) parts.push("rewatched (viewCount ≥ 3)");
  if (rules.watchedOnly) parts.push("watched only");
  if (rules.unwatchedOnly) parts.push("unwatched only");
  return parts.length ? parts.join(", ") : "no rules (everything qualifies)";
}

function summariseTimeRestrictions(tr) {
  if (!tr) return "";
  const parts = [];
  if (tr.blockRatings) {
    const { ratings = [], blockBefore, blockAfter } = tr.blockRatings;
    const when = [
      blockBefore != null ? `before ${blockBefore}:00` : null,
      blockAfter != null ? `from ${blockAfter}:00` : null,
    ].filter(Boolean).join(" and ");
    parts.push(`blocks ${ratings.join("/")} ${when}`);
  }
  if (tr.tvOnlyBefore != null) parts.push(`TV only before ${tr.tvOnlyBefore}:00`);
  if (tr.onlyAfterHour != null) parts.push(`off air before ${tr.onlyAfterHour}:00`);
  return parts.join("; ");
}

const cell = (s) => String(s ?? "").replaceAll("|", "\\|");

// ── Build ──────────────────────────────────────────────────────────────────

const data = JSON.parse(await readFile(CHANNELS_PATH, "utf8"));
const channels = data.channels || [];
const byId = new Map(channels.map((c) => [c.id, c]));

/** "CH 130–136, 145": channel numbers as runs, so a bundle split across blocks reads right. */
function numberRanges(nums) {
  const sorted = [...nums].sort((a, z) => a - z);
  const runs = [];
  for (const n of sorted) {
    const last = runs[runs.length - 1];
    if (last && n === last[1] + 1) last[1] = n;
    else runs.push([n, n]);
  }
  return `CH ${runs.map(([a, z]) => (a === z ? `${a}` : `${a}–${z}`)).join(", ")}`;
}

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

/** "7 days before US Thanksgiving" for a bundle's `seasonStart`, or "" for none. */
function seasonStartNote(start) {
  if (!start || start.relativeTo !== "usThanksgiving") return "";
  const days = Number.isInteger(start.days) ? start.days : 0;
  const n = Math.abs(days);
  const anchor = "US Thanksgiving (the fourth Thursday of November)";
  if (days === 0) return `on ${anchor}`;
  return `${n} day${n === 1 ? "" : "s"} ${days < 0 ? "before" : "after"} ${anchor}`;
}

/** "Spotlighted Oct, off until switched on, works in any month" for a seasonal bundle. */
function seasonNote(activeMonths, seasonStart) {
  if (!activeMonths?.length) return "";
  const months = activeMonths.map((m) => MONTHS[m - 1]).filter(Boolean).join(", ");
  const early = seasonStartNote(seasonStart);
  const when = early ? `from ${early} through ${months}` : months;
  return `Spotlighted ${when}. Off until switched on, then on in any month.`;
}

const bundles = (data.bundles || [])
  .map((b) => ({
    id: b.id,
    name: b.name,
    description: b.description || "",
    season: seasonNote(b.activeMonths, b.seasonStart),
    chans: (b.channelIDs || [])
      .map((id) => byId.get(id))
      .filter(Boolean)
      .sort((a, z) => a.number - z.number),
  }))
  .filter((b) => b.chans.length > 0)
  // Order bundles the way the guide reads: by lowest channel number.
  .sort((a, z) => a.chans[0].number - z.chans[0].number);

const bundled = new Set(bundles.flatMap((b) => b.chans.map((c) => c.id)));
const orphans = channels.filter((c) => !bundled.has(c.id)).sort((a, z) => a.number - z.number);
const bundledCount = bundles.reduce((n, b) => n + b.chans.length, 0);

const out = [];
// {{id}} in the preamble is that channel's current number, so the examples never go stale.
out.push(PREAMBLE.trimEnd().replace(/\{\{(\d+)\}\}/g, (_, id) => String(byId.get(Number(id))?.number ?? "?")), "");
out.push(
  `**Config version:** ${data.version} · **${channels.length} channels** across ` +
    `**${bundles.length} bundles** · ${channels.filter((c) => c.id !== c.number).length} channels ` +
    `whose \`id\` differs from their \`number\`.`,
  "",
  "---",
  "",
);

// Bundle overview
out.push("## Bundles", "");
out.push("| Bundle | Bundle ID | Channels | Range | Description |", "|---|---|---|---|---|");
for (const b of bundles) {
  const range = numberRanges(b.chans.map((c) => c.number));
  out.push(
    `| ${cell(b.name)} | \`${b.id}\` | ${b.chans.length} | ${range} | ` +
      `${cell([b.description, b.season].filter(Boolean).join(". "))} |`,
  );
}
out.push("", `Bundled channels: ${bundledCount} of ${channels.length}.`, "");
out.push("---", "");

// Channel exclusivity
out.push("## Channel exclusivity", "", EXCLUSIVITY_INTRO, "");
const rules = data.exclusiveRules || [];
if (!rules.length) {
  out.push("_No exclusive rules in this config._", "");
} else {
  out.push("| Locked to | Matches on | Notes |", "|---|---|---|");
  for (const rule of rules) {
    const ids = rule.channelIDs || (rule.channelID != null ? [rule.channelID] : []);
    const owners = ids
      .map((id) => {
        const ch = byId.get(id);
        return ch ? `CH${ch.number} ${ch.name} (id ${id})` : `id ${id} (missing)`;
      })
      .join("<br>");
    const matches = [
      rule.genres?.length ? `genres ${list(rule.genres, 4)}` : null,
      rule.titleContains?.length ? `${rule.titleContains.length} title words` : null,
      rule.editorialTitles?.length ? `${rule.editorialTitles.length} exact titles` : null,
      rule.manifestExclusive ? "TMDB manifest claim (`manifestExclusive`)" : null,
      rule.type || rule.source
        ? `only ${TYPE_LABEL[rule.type]?.toLowerCase() || "items"}${rule.source ? ` from the ${SOURCE_LABEL[rule.source] || rule.source}` : ""}`
        : null,
    ].filter(Boolean).join(", ");
    const note = (EXCLUSIVITY_NOTES[[...ids].sort((a, z) => a - z).join(",")] || "")
      .replace(/\s*\n\s*/g, " ")
      .trim();
    out.push(`| ${cell(owners)} | ${cell(matches)} | ${cell(note)} |`);
  }
  out.push("");
}
out.push("---", "");

// Per-bundle channel tables
out.push("## Channels by bundle", "");
function channelTable(chans) {
  const rows = [
    "| CH | `id` | Name | Color | Type | Min items | Rules |",
    "|---|---|---|---|---|---|---|",
  ];
  for (const ch of chans) {
    const idCell = ch.id === ch.number ? `\`${ch.id}\`` : `**\`${ch.id}\`** ⚠︎`;
    const type = TYPE_LABEL[ch.rules?.type] || "Any";
    let ruleText = summariseRules(ch.rules);
    const tr = summariseTimeRestrictions(ch.timeRestrictions);
    if (tr) ruleText += ` · _time: ${tr}_`;
    rows.push(
      `| ${ch.number} | ${idCell} | ${cell(ch.name)} | \`${ch.colorHex}\` | ${type} | ` +
        `${ch.minItems ?? 50} | ${cell(ruleText)} |`,
    );
  }
  return rows;
}
for (const b of bundles) {
  const range = numberRanges(b.chans.map((c) => c.number));
  out.push(`### ${b.name} · ${range}`, "");
  if (b.description) out.push(`_${b.description}_`, "");
  if (b.season) out.push(b.season, "");
  out.push(...channelTable(b.chans), "");
}
if (orphans.length) {
  out.push("### Not in any bundle", "");
  out.push(...channelTable(orphans), "");
}

// id vs number cheat sheet
const mismatched = channels.filter((c) => c.id !== c.number).sort((a, z) => a.number - z.number);
if (mismatched.length) {
  out.push("---", "", "## `id` ≠ `number`", "");
  out.push(
    `${mismatched.length} channels whose manifest/exclusivity key (\`id\`) is not their ` +
      "on-screen number. Marked ⚠︎ in the tables above.",
    "",
  );
  out.push("| `id` | Airs as | Name |", "|---|---|---|");
  for (const ch of mismatched) {
    out.push(`| \`${ch.id}\` | CH${ch.number} | ${cell(ch.name)} |`);
  }
  out.push("");
}

out.push("---", "");
out.push(
  `_Generated from \`channels.json\` v${data.version} by \`scripts/render-channels-doc.mjs\`. ` +
    "Do not edit by hand._",
);

const markdown = out.join("\n").replace(/\n{3,}/g, "\n\n") + "\n";

if (CHECK_ONLY) {
  let current = null;
  try {
    current = await readFile(OUT_PATH, "utf8");
  } catch {
    /* missing */
  }
  if (current !== markdown) {
    console.error(
      "CHANNELS.md is out of date with channels.json. Run `npm run channels:doc` and commit the result.",
    );
    process.exit(1);
  }
  console.log(`CHANNELS.md is current (v${data.version}, ${channels.length} channels).`);
} else {
  await writeFile(OUT_PATH, markdown, "utf8");
  console.log(
    `Wrote CHANNELS.md — config v${data.version}, ${channels.length} channels, ` +
      `${bundles.length} bundles, ${mismatched.length} id≠number.`,
  );
}
