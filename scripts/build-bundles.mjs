// Build the channel guide: /channels plus one page per bundle.
//
// Everything on these pages is computed from channels.json at build time, so
// the site cannot drift from the app. Bundles reference channel `id`; the
// pages label channels by `number`. Counts, bundle order and channel names all
// come from the data, never from a literal in this file.
//
// The human copy (intro, meta description, FAQ) lives in
// content/bundles/<bundle-id>.md, next to the blog posts. A bundle with no
// content file is skipped with a warning so the site still builds while the
// copy is being written; pass --strict (or run under CI) to turn that into a
// failure instead.
//
// Shape mirrors scripts/build-blog.mjs: a loader, a renderer that returns a
// map of dist paths to HTML, a writeBundlesToDist() that the emitBundles
// plugin in vite.config.js calls during closeBundle, and a main() that
// refreshes public/sitemap.xml and public/llms.txt in the repo.
//
// Two things make this more than a template fill:
//
//   1. Legal holds (scripts/legal-hold.json). Some channel names are brand or
//      near brand names and are waiting on a legal answer. A held bundle still
//      builds, but noindex and out of the sitemap. A held channel's name only
//      ever appears on a held page; indexed pages omit it from the list, the
//      title, the meta and the JSON-LD, and say how many are missing so the
//      counts stay true.
//   2. Copy checks. Visible copy carries no dashes of any kind, no held brand
//      names on an indexed page, no Emby, and none of the phrases that make
//      marketing copy read like a machine wrote it. Every one of those fails
//      the build with the file and the offending text.

import { readFile, writeFile, mkdir, readdir, copyFile, stat } from "node:fs/promises";
import { existsSync, readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { Marked } from "marked";
import matter from "gray-matter";
import {
  SITE_ORIGIN,
  DEFAULT_OG_IMAGE,
  APPLE_TV_URL,
  APP_ID,
  escapeHtml,
  escapeAttr,
  renderNav,
  renderFooter,
  renderHead,
  resolveViteAssetHrefs,
} from "./site-chrome.mjs";
import { bundleStyle } from "./bundle-style.mjs";
import {
  resolveImage,
  resolveClip,
  renderCover,
  renderClip,
  markedImageRenderer,
  unwrapFigures,
  mediaText,
  isRemote,
} from "./site-media.mjs";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const SCRIPTS_DIR = path.join(ROOT, "scripts");
const CHANNELS_PATH = path.join(ROOT, "channels.json");
const CONTENT_DIR = path.join(ROOT, "content", "bundles");
const PUBLIC_DIR = path.join(ROOT, "public");
const SITEMAP_PATH = path.join(PUBLIC_DIR, "sitemap.xml");
const LLMS_PATH = path.join(PUBLIC_DIR, "llms.txt");
const LEGAL_HOLD_PATH = path.join(SCRIPTS_DIR, "legal-hold.json");
const LASTMOD_PATH = path.join(SCRIPTS_DIR, "bundle-lastmod.json");

const HUB_PATH = "/channels";
const HUB_CANONICAL = `${SITE_ORIGIN}${HUB_PATH}`;
const WEBSITE_ID = `${SITE_ORIGIN}/#website`;

const TITLE_MAX = 60;
const META_MIN = 120;
const META_MAX = 155;
const INTRO_MIN_WORDS = 300;
const INTRO_MAX_WORDS = 600;
const FAQ_MIN = 3;
const FAQ_MAX = 5;

// Static pages cannot compute the channel count, so their prose says "130+
// channels" and never needs editing when a channel is added. The check keeps
// that honest: an "N+ channels" claim may not exceed what channels.json has,
// a bare count of 100 or more must be the real one, and plex.html and
// jellyfin.html must still link the guide with "browse all N+ channels".
// Blog posts are scanned too. Generated regions (LINEUP, CHANGELOG and the like) are skipped: their
// numbers come from data, and old changelog entries keep old counts.
const COUNT_PAGES = ["index.html", "plex.html", "jellyfin.html", "emby.html", "public/llms.txt", "README.md"];
const GUIDE_LINK_PAGES = ["plex.html", "jellyfin.html"];
const GUIDE_LINK_RE = /browse all (\d+)\+ channels/;
const COUNT_CLAIM_RE = /(?<![\d.,])(\d{3})(\+?)\s+(?:live\s+|TV\s+|themed\s+)*channels\b/gi;

/** Every "N channels" / "N+ channels" claim outside generated regions. Exported for the tests. */
export function channelCountClaims(text) {
  const visible = text.replace(/<!--\s*([A-Z-]+):START[\s\S]*?<!--\s*\1:END[^>]*-->/g, "");
  return [...visible.matchAll(COUNT_CLAIM_RE)].map((m) => ({ n: Number(m[1]), plus: m[2] === "+", text: m[0] }));
}

// The affiliation line that every held bundle page carries, from the handoff.
const AFFILIATION_DISCLAIMER =
  "Channel names describe the kind of titles that can air from your own library. Nostalgex is not affiliated with or endorsed by any studio, network, or streaming service.";

// ---------------------------------------------------------------------------
// Copy rules
// ---------------------------------------------------------------------------

// Em dash, en dash, the figure/quotation dash range, the minus sign, the small
// and fullwidth variants, and the plain ASCII hyphen. None of them belong in
// visible copy; the rule is to rewrite the sentence instead ("sci fi", "all
// day", "80s and 90s").
const DASH_RE = /[‐-―−﹘﹣－-]/;

const BANNED_PHRASES = [
  "dive into",
  "elevate",
  "seamless",
  "curated experience",
  "unlock",
  "whether you're",
  "look no further",
  "in today's",
  "nostalgia tv",
];

// Brand and near brand names live in scripts/legal-hold.json, not here, so one
// file decides what is held: the bundles, the channels and the words. None of
// the held words may appear in the visible copy, meta or JSON-LD of a page that
// search engines index. "Apple TV" the device is fine, which is why Apple TV+
// is matched with its plus.

// Channel names that need a hand written display form. The generic rule below
// already turns any hyphen into a space, so this map is for the cases where
// the result should read a particular way. channels.json is never edited for
// presentation: the app and the web tuner keep the raw names.
const CHANNEL_DISPLAY_OVERRIDES = {
  "SCI-FI": "SCI FI",
  "STAND-UP": "STAND UP",
};

// Kept upper case when a name is title cased. Everything else gets ordinary
// Title Case, and the small words below stay lower unless they lead.
const KEEP_UPPER = new Set([
  "HBO",
  "TV",
  "VHS",
  "MTV",
  "LOL",
  "Y2K",
  "DVD",
  "HQ",
  "R",
  "SNL",
  "PG",
]);
const SMALL_WORDS = new Set([
  "a",
  "an",
  "and",
  "as",
  "at",
  "but",
  "by",
  "for",
  "in",
  "nor",
  "of",
  "on",
  "or",
  "the",
  "to",
  "with",
]);

function titleCaseToken(token, index) {
  if (!token) return token;
  // "APPLE TV+" and "PARAMOUNT+" keep the plus; title case the word in front.
  const plus = token.endsWith("+") ? "+" : "";
  const core = plus ? token.slice(0, -1) : token;
  if (!core) return token;
  // "20TH" to "20th", "90S" to "90s", "60S" to "60s".
  const ordinal = core.match(/^(\d+)(ST|ND|RD|TH|S)$/i);
  if (ordinal) return `${ordinal[1]}${ordinal[2].toLowerCase()}${plus}`;
  if (KEEP_UPPER.has(core.toUpperCase())) return core.toUpperCase() + plus;
  const lower = core.toLowerCase();
  if (index > 0 && SMALL_WORDS.has(lower)) return lower + plus;
  return lower.charAt(0).toUpperCase() + lower.slice(1) + plus;
}

// Title Case that leaves the acronyms alone: KIDZ ZONE to Kidz Zone, TIS THE
// SEASON to Tis the Season, APPLE TV+ to Apple TV+, THE 90S to The 90s.
export function titleCase(text) {
  return String(text)
    .split(/\s+/)
    .filter(Boolean)
    .map(titleCaseToken)
    .join(" ");
}

// Channel names stay upper case, matching the homepage lineup, the app guide
// and the web tuner. The only presentation change is dropping hyphens, which
// the visible-copy dash check forbids.
export function displayChannelName(rawName) {
  const raw = String(rawName);
  if (CHANNEL_DISPLAY_OVERRIDES[raw]) return CHANNEL_DISPLAY_OVERRIDES[raw];
  return raw.replace(/-/g, " ");
}

export function displayBundleName(rawName) {
  return titleCase(String(rawName).replace(/-/g, " "));
}

// ---------------------------------------------------------------------------
// Data
// ---------------------------------------------------------------------------

// legal-hold.json and bundle-lastmod.json are tiny and are read from inside
// synchronous helpers, so they use the sync reader rather than threading async
// through the hold lookup and the lastmod cache.
function readJson(file) {
  return JSON.parse(readFileSync(file, "utf8"));
}

export function loadLegalHold() {
  if (!existsSync(LEGAL_HOLD_PATH)) {
    return { heldBundles: new Set(), heldChannels: new Set(), heldBrands: [] };
  }
  const raw = readJson(LEGAL_HOLD_PATH);
  return {
    heldBundles: new Set(raw.heldBundles || []),
    heldChannels: new Set((raw.heldChannels || []).map(Number)),
    // Empty means nothing is enforced: the names are cleared for publication.
    heldBrands: raw.heldBrands || [],
  };
}

export async function loadChannelData() {
  const data = JSON.parse(await readFile(CHANNELS_PATH, "utf8"));
  const byId = new Map((data.channels || []).map((c) => [c.id, c]));
  const hold = loadLegalHold();

  const bundles = (data.bundles || [])
    .map((bundle) => {
      // Bundles reference channel id; the page labels use number.
      const channels = (bundle.channelIDs || [])
        .map((id) => byId.get(id))
        .filter(Boolean)
        .map((channel) => ({
          id: channel.id,
          number: channel.number,
          rawName: channel.name,
          name: displayChannelName(channel.name),
          held: hold.heldChannels.has(Number(channel.number)),
          raw: channel,
        }));
      const style = bundleStyle(bundle.id);
      return {
        id: bundle.id,
        rawName: bundle.name,
        name: displayBundleName(bundle.name),
        // channels.json's own description is generated copy, used for llms.txt
        // only. Visible page copy comes from the content file.
        dataDescription: String(bundle.description || ""),
        color: style.color,
        styleDesc: style.desc,
        channels,
        count: channels.length,
        held: hold.heldBundles.has(bundle.id),
        raw: bundle,
      };
    })
    .filter((bundle) => bundle.count > 0)
    // Lowest channel number first, so the guide reads like a real channel
    // guide rather than channels.json's authoring order.
    .sort((a, z) => a.channels[0].number - z.channels[0].number);

  // Future channel pages live at /channels/<number>-<slug>, which always
  // starts with a digit. A bundle id that started with a digit could collide
  // with one, so refuse to build rather than ship an ambiguous URL space.
  const digitLed = bundles.filter((b) => /^[0-9]/.test(b.id));
  if (digitLed.length) {
    throw new Error(
      `channels.json: bundle id${digitLed.length === 1 ? "" : "s"} ${digitLed
        .map((b) => `"${b.id}"`)
        .join(", ")} start${digitLed.length === 1 ? "s" : ""} with a digit, which would collide with the ` +
        "/channels/<number>-<slug> channel pages. Rename the bundle id.",
    );
  }

  const totalChannels = bundles.reduce((n, b) => n + b.count, 0);
  return { bundles, totalChannels, bundleCount: bundles.length, hold };
}

function requireField(frontmatter, key, file) {
  const value = frontmatter[key];
  if (value == null || value === "") {
    throw new Error(`${file}: missing required frontmatter field "${key}"`);
  }
  return value;
}

// Rough word count of the intro: drop code fences, images and link targets so
// a markdown link counts as its label and a URL does not inflate the total.
function countWords(markdown) {
  const text = String(markdown)
    .replace(/```[\s\S]*?```/g, " ")
    .replace(/`[^`]*`/g, " ")
    .replace(/!\[[^\]]*\]\([^)]*\)/g, " ")
    .replace(/\[([^\]]+)\]\([^)]*\)/g, "$1")
    .replace(/[#>*_|]/g, " ")
    .replace(/https?:\/\/\S+/g, " ");
  return text.split(/\s+/).filter((w) => /[A-Za-z0-9]/.test(w)).length;
}

export async function loadBundleContent(bundles) {
  const content = new Map();
  const missing = [];
  for (const bundle of bundles) {
    const file = path.join(CONTENT_DIR, `${bundle.id}.md`);
    if (!existsSync(file)) {
      missing.push(bundle.id);
      continue;
    }
    const raw = await readFile(file, "utf8");
    const parsed = matter(raw);
    const fm = parsed.data || {};
    const rel = path.relative(ROOT, file);

    const description = String(requireField(fm, "description", rel));
    const faqRaw = Array.isArray(fm.faq) ? fm.faq : [];
    const faq = faqRaw.map((item, i) => {
      const q = item && item.q != null ? String(item.q).trim() : "";
      const a = item && item.a != null ? String(item.a).trim() : "";
      if (!q || !a) {
        throw new Error(`${rel}: faq entry ${i + 1} needs both "q" and "a"`);
      }
      return { q, a };
    });

    content.set(bundle.id, {
      file: rel,
      raw,
      titleOverride: fm.title ? String(fm.title) : null,
      // The on page H1. Defaults to the <title> without the brand suffix: the
      // bundle name alone ("Marquee") is internal vocabulary, and a visitor
      // arriving from a search needs the heading to confirm they are in the
      // right place. The name and the count move to the line underneath.
      heading: fm.heading ? String(fm.heading) : null,
      description,
      // The hub shows a short line per bundle. The meta description is written
      // for a search result and reads as boilerplate when 14 of them sit in a
      // column, so `blurb` carries the human version. Falls back to the meta.
      blurb: fm.blurb ? String(fm.blurb) : description,
      // Optional media. `image` is the hero under the H1; `og_image` is the
      // 1200x630 social card, falling back to the hero and then to the shared
      // default. Both are validated now so a bad path fails the build rather
      // than shipping a broken page.
      image: resolveImage(fm, { file: rel, rootDir: ROOT }),
      ogImage: resolveImage(fm, {
        file: rel,
        rootDir: ROOT,
        keys: {
          src: "og_image",
          alt: "og_image_alt",
          width: "og_image_width",
          height: "og_image_height",
        },
      }),
      clip: resolveClip(fm, { file: rel }),
      faq,
      markdown: parsed.content.replace(/<!--[\s\S]*?-->/g, "").trim(),
      words: countWords(parsed.content),
    });
  }
  return { content, missing };
}

// ---------------------------------------------------------------------------
// Titles
// ---------------------------------------------------------------------------

// Three shapes, in order, first one that fits inside 60 characters. A `title`
// in the content file wins outright.
export function bundleTitle(bundle, titleOverride) {
  if (titleOverride) return titleOverride;
  const candidates = [
    `${bundle.name} Bundle: ${bundle.count} Channels for Plex and Jellyfin | Nostalgex`,
    `${bundle.name} Bundle: ${bundle.count} Channels for Plex and Jellyfin`,
    `${bundle.name}: ${bundle.count} Retro TV Channels | Nostalgex`,
  ];
  return candidates.find((t) => t.length <= TITLE_MAX) || candidates.at(-1);
}

// The H1. A `heading` in the content file wins; otherwise the page title minus
// the brand suffix, which is already written to say what the page is about.
export function bundleHeading(bundle, copy) {
  if (copy && copy.heading) return copy.heading;
  return bundleTitle(bundle, copy ? copy.titleOverride : null).replace(/\s*\|\s*Nostalgex$/, "");
}

// ---------------------------------------------------------------------------
// Visible text extraction, for the copy checks
// ---------------------------------------------------------------------------

const NAMED_ENTITIES = {
  amp: "&",
  lt: "<",
  gt: ">",
  quot: '"',
  apos: "'",
  nbsp: " ",
  middot: "·",
  rarr: "→",
  larr: "←",
  rsquo: "’",
  lsquo: "‘",
  rdquo: "”",
  ldquo: "“",
  hellip: "…",
  mdash: "—",
  ndash: "–",
  minus: "−",
  hyphen: "‐",
};

function decodeEntities(text) {
  return String(text)
    .replace(/&#x([0-9a-f]+);/gi, (_, hex) =>
      String.fromCodePoint(parseInt(hex, 16)),
    )
    .replace(/&#(\d+);/g, (_, dec) => String.fromCodePoint(Number(dec)))
    .replace(/&([a-z]+);/gi, (m, name) => {
      const key = name.toLowerCase();
      return key in NAMED_ENTITIES ? NAMED_ENTITIES[key] : m;
    });
}

// What a reader actually sees. The head (title, meta, JSON-LD) is checked
// separately with its own rules, scripts and styles never render, svg carries
// path data rather than words, and tag soup takes every attribute with it. A
// URL that survives as link text is dropped last: slugs like tis-the-season
// are addresses, not copy.
export function visibleText(html) {
  let s = String(html);
  s = s.replace(/<head[\s\S]*?<\/head>/gi, " ");
  s = s.replace(/<script[\s\S]*?<\/script>/gi, " ");
  s = s.replace(/<style[\s\S]*?<\/style>/gi, " ");
  s = s.replace(/<svg[\s\S]*?<\/svg>/gi, " ");
  s = s.replace(/<!--[\s\S]*?-->/g, " ");
  s = s.replace(/<[^>]*>/g, " ");
  s = decodeEntities(s);
  s = s.replace(/https?:\/\/\S+/g, " ");
  return s.replace(/\s+/g, " ").trim();
}

// The JSON-LD blocks as one flat string with every URL removed, so the brand
// check reads the names, descriptions and FAQ answers but not the @id values,
// the canonical, or the App Store link.
function jsonLdText(html) {
  const blocks = [
    ...html.matchAll(
      /<script type="application\/ld\+json">([\s\S]*?)<\/script>/g,
    ),
  ].map((m) => m[1]);
  return blocks
    .join(" ")
    .replace(/https?:\/\/[^"\s]*/g, " ")
    .replace(/[{}[\]",:]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function escapeRegex(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

// One matcher per held term. Word boundaries keep ordinary words out of it, so
// "Nick" does not fire on "nickname". Apple TV+ is matched with its plus,
// which is what separates it from "Apple TV" the device.
function buildHeldMatchers(heldChannelNames, heldBrands = []) {
  // Case insensitive dedupe: a held channel's raw name (HARRY POTTER) and its
  // display name (Harry Potter) and the brand term (Harry Potter) are one
  // rule, and one rule should report once.
  const seen = new Map();
  for (const term of [...heldBrands, ...heldChannelNames]) {
    const key = term.toLowerCase();
    if (!seen.has(key)) seen.set(key, term);
  }
  const terms = [...seen.values()];
  return terms.map((term) => {
    const body = escapeRegex(term).replace(/\\?\s+/g, "\\s+");
    const trailing = /[A-Za-z0-9]$/.test(term) ? "\\b" : "";
    return { term, re: new RegExp(`\\b${body}${trailing}`, "i") };
  });
}

function findHeldTerms(text, matchers) {
  const hits = [];
  for (const { term, re } of matchers) {
    const m = re.exec(text);
    if (m) hits.push({ term, match: m[0] });
  }
  return hits;
}

// Enough of the surrounding sentence to find the problem in the source.
function excerpt(text, index, span = 60) {
  const start = Math.max(0, index - span);
  const end = Math.min(text.length, index + span);
  return `${start > 0 ? "..." : ""}${text.slice(start, end)}${end < text.length ? "..." : ""}`;
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

function channelListItems(bundle, { showHeld }) {
  const shown = showHeld ? bundle.channels : bundle.channels.filter((c) => !c.held);
  const hidden = bundle.count - shown.length;
  return { shown, hidden };
}

function moreChannelsLine(hidden) {
  // The spec wording is "plus {n} more channels in the app". Singular reads
  // wrong, so one held channel says "channel".
  return `plus ${hidden} more channel${hidden === 1 ? "" : "s"} in the app`;
}

function renderBreadcrumb(items) {
  const lis = items
    .map((item, i) => {
      const last = i === items.length - 1;
      const inner = last
        ? `<span aria-current="page">${escapeHtml(item.name)}</span>`
        : `<a href="${escapeAttr(item.href)}">${escapeHtml(item.name)}</a>`;
      return `          <li class="channels-crumb">${inner}</li>`;
    })
    .join("\n");
  return `        <nav class="channels-breadcrumb" aria-label="Breadcrumb">
          <ol class="channels-crumbs">
${lis}
          </ol>
        </nav>`;
}

function breadcrumbJsonLd(canonical, items) {
  return {
    "@type": "BreadcrumbList",
    "@id": `${canonical}#breadcrumb`,
    itemListElement: items.map((item, i) => ({
      "@type": "ListItem",
      position: i + 1,
      name: item.name,
      item: item.url,
    })),
  };
}

// The hub's own title and meta. Hand written rather than built from the counts,
// so the search result leads with what the page is instead of a number. The
// counts still carry the H1 and the body. Exported so the copy checks test the
// same strings the page carries rather than a second copy.
export function hubMeta() {
  return {
    title: "Retro TV Channel Guide for Plex and Jellyfin | Nostalgex",
    description:
      "Browse every Nostalgex channel and bundle. Free, open source live TV from your own Plex or Jellyfin library on Apple TV, with no manual scheduling.",
  };
}

// The hub has no content file, so its hero is named here. It uses the bundles
// screen from the Apple TV set the home page ships, which is app UI rather than a
// frame from somebody's film.
//
// Measured on first use, not at import. The self-host build imports this module
// from vite.config.js but never renders the site, and its Docker context carries
// only the two tuner pages, so measuring at import made the image build fail on
// a missing screenshot.
let hubImage = null;
function hubImageRef() {
  if (!hubImage) {
    hubImage = resolveImage(
      {
        image: "/screens/atv-05-1280.webp",
        image_alt:
          "The Nostalgex Settings screen on Apple TV, listing the channel bundles with how many channels each adds and a switch for each",
      },
      { file: "scripts/build-bundles.mjs (hub)", rootDir: ROOT },
    );
  }
  return hubImage;
}

function renderHubPage(model, assetHrefs) {
  const { bundles, totalChannels, bundleCount, content } = model;
  const { title, description } = hubMeta(model);

  const crumbs = [
    { name: "Home", href: "/", url: `${SITE_ORIGIN}/` },
    { name: "Channel Guide", href: HUB_PATH, url: HUB_CANONICAL },
  ];

  const jsonLd = {
    "@context": "https://schema.org",
    "@graph": [
      {
        "@type": "CollectionPage",
        "@id": `${HUB_CANONICAL}#webpage`,
        url: HUB_CANONICAL,
        name: title,
        description,
        isPartOf: { "@id": WEBSITE_ID },
        about: { "@id": APP_ID },
        breadcrumb: { "@id": `${HUB_CANONICAL}#breadcrumb` },
        mainEntity: { "@id": `${HUB_CANONICAL}#bundles` },
      },
      breadcrumbJsonLd(HUB_CANONICAL, crumbs),
      {
        "@type": "ItemList",
        "@id": `${HUB_CANONICAL}#bundles`,
        name: `Nostalgex channel bundles`,
        numberOfItems: bundles.length,
        itemListElement: bundles.map((bundle, i) => ({
          "@type": "ListItem",
          position: i + 1,
          name: `${bundle.name} (${bundle.count} channels)`,
          item: `${SITE_ORIGIN}${HUB_PATH}/${bundle.id}`,
        })),
      },
    ],
  };

  // Each bundle is one row of the guide: the row head carries the name, the
  // count and the blurb, and the strip beside it holds the channel cells. The
  // strip scrolls sideways on a wide screen and stacks into a plain list below
  // 640px, so the whole lineup is real, selectable text either way.
  const rows = bundles
    .map((bundle) => {
      const href = `${HUB_PATH}/${bundle.id}`;
      // The hub is indexed, so it never shows a held channel name even when it
      // links to a held bundle: the bundle names themselves are generic.
      const { shown, hidden } = channelListItems(bundle, { showHeld: false });
      const cells = shown
        .map(
          (channel) =>
            `            <li class="guide-cell" data-channel-number="${escapeAttr(channel.number)}"><span class="guide-cell-num">Ch ${escapeHtml(channel.number)}</span> <span class="guide-cell-name">${escapeHtml(channel.name)}</span></li>`,
        )
        .join("\n");
      const moreCell = hidden
        ? `\n            <li class="guide-cell guide-cell--more">${escapeHtml(moreChannelsLine(hidden))}</li>`
        : "";
      const blurb = content.get(bundle.id)?.blurb;
      const blurbHtml = blurb
        ? `\n            <p class="guide-row-blurb">${escapeHtml(blurb)}</p>`
        : "";
      return `        <section class="guide-row" style="--guide-accent: ${escapeAttr(bundle.color)};" aria-labelledby="row-${escapeAttr(bundle.id)}">
          <div class="guide-row-head">
            <h2 class="guide-row-name" id="row-${escapeAttr(bundle.id)}"><a href="${escapeAttr(href)}">${escapeHtml(bundle.name)}</a></h2>
            <p class="guide-row-count">${escapeHtml(bundle.count)} channels</p>${blurbHtml}
          </div>
          <ul class="guide-row-strip" tabindex="0" aria-label="${escapeAttr(`${bundle.name} channels`)}">
${cells}${moreCell}
          </ul>
        </section>`;
    })
    .join("\n");

  const appScript = assetHrefs.appScriptHref || "/app.js";

  return `${renderHead({
    title,
    description,
    canonical: HUB_CANONICAL,
    ogImage: `${SITE_ORIGIN}${hubImageRef().src}`,
    ogImageAlt: hubImageRef().alt,
    ogImageWidth: hubImageRef().width,
    ogImageHeight: hubImageRef().height,
    ogType: "website",
    jsonLd,
    extraMeta: `<link rel="stylesheet" href="/channels.css">`,
    stylesHref: assetHrefs.stylesHref,
    appScriptHref: appScript,
  })}
<body class="page-channels">
${renderNav()}

  <main id="top" class="channels-main">
    <div class="container">
${renderBreadcrumb(crumbs)}
      <header class="channels-head">
        <h1>Channel Guide: ${escapeHtml(totalChannels)} Channels in ${escapeHtml(bundleCount)} Bundles</h1>
        <p class="channels-dek">Every channel here is a rule, not a playlist. Point the app at your own Plex or Jellyfin server and the channels with enough matching titles switch themselves on, grouped into the ${escapeHtml(bundleCount)} bundles below. This is the whole lineup, so you can see what the guide would look like before you install anything.</p>
      </header>
      ${renderCover(hubImageRef(), { className: "channels-cover" })}

      <div class="channels-guide">
${rows}
      </div>

      <section class="channels-cta" aria-labelledby="channels-cta-heading">
        <h2 id="channels-cta-heading">Start watching</h2>
        <p>Nostalgex is free and open source. Set it up with <a href="/plex">Nostalgex for Plex</a> or <a href="/jellyfin">Nostalgex for Jellyfin</a>, get the <a href="${escapeAttr(APPLE_TV_URL)}" target="_blank" rel="noopener">Apple TV app from the App Store</a>, or try it in the browser with the <a href="/web-tuner">free web tuner</a>.</p>
      </section>
    </div>
  </main>

${renderFooter({ includeEmby: false })}

  <script type="module" src="${escapeAttr(appScript)}"></script>
</body>
</html>
`;
}

function renderBundlePage(bundle, model, assetHrefs) {
  const { bundles, content } = model;
  const copy = content.get(bundle.id);
  const canonical = `${SITE_ORIGIN}${HUB_PATH}/${bundle.id}`;
  const title = bundleTitle(bundle, copy.titleOverride);
  const description = copy.description;
  const robots = bundle.held ? "noindex, follow" : "index, follow";

  const crumbs = [
    { name: "Home", href: "/", url: `${SITE_ORIGIN}/` },
    { name: "Channel Guide", href: HUB_PATH, url: HUB_CANONICAL },
    { name: bundle.name, href: `${HUB_PATH}/${bundle.id}`, url: canonical },
  ];

  // A held page is the only place a held channel name is allowed to appear.
  const { shown, hidden } = channelListItems(bundle, { showHeld: bundle.held });

  const jsonLd = {
    "@context": "https://schema.org",
    "@graph": [
      {
        "@type": "CollectionPage",
        "@id": `${canonical}#webpage`,
        url: canonical,
        name: title,
        description,
        isPartOf: { "@id": WEBSITE_ID },
        about: { "@id": APP_ID },
        breadcrumb: { "@id": `${canonical}#breadcrumb` },
        mainEntity: { "@id": `${canonical}#channels` },
      },
      breadcrumbJsonLd(canonical, crumbs),
      {
        "@type": "ItemList",
        "@id": `${canonical}#channels`,
        name: `Channels in ${bundle.name}`,
        numberOfItems: shown.length,
        itemListElement: shown.map((channel, i) => ({
          "@type": "ListItem",
          position: i + 1,
          name: channel.name,
        })),
      },
      {
        "@type": "FAQPage",
        "@id": `${canonical}#faq`,
        mainEntity: copy.faq.map((item) => ({
          "@type": "Question",
          name: item.q,
          acceptedAnswer: { "@type": "Answer", text: item.a },
        })),
      },
    ],
  };

  const channelItems = shown
    .map(
      (channel) =>
        `            <li class="bundle-channel" data-channel-number="${escapeAttr(channel.number)}"><span class="bundle-channel-num">Ch ${escapeHtml(channel.number)}</span> <span class="bundle-channel-name">${escapeHtml(channel.name)}</span></li>`,
    )
    .join("\n");
  const moreItem = hidden
    ? `\n            <li class="bundle-channel bundle-channel--more">${escapeHtml(moreChannelsLine(hidden))}</li>`
    : "";

  const faqHtml = copy.faq
    .map(
      (item) => `          <div class="bundle-faq-item">
            <h3>${escapeHtml(item.q)}</h3>
            <p>${escapeHtml(item.a)}</p>
          </div>`,
    )
    .join("\n");

  const others = bundles.filter((b) => b.id !== bundle.id);
  const moreBundles = others
    .map(
      (other) =>
        `            <li><a href="${escapeAttr(`${HUB_PATH}/${other.id}`)}">${escapeHtml(other.name)}</a> <span class="bundle-more-count">${escapeHtml(other.count)} channels</span></li>`,
    )
    .join("\n");

  // On every bundle page, not just the held ones. A page that prints a studio
  // or franchise channel name is exactly the page that needs to say nobody is
  // endorsing anybody, and now that the holds are lifted that is most of them.
  const disclaimer = `
        <p class="bundle-disclaimer">${escapeHtml(AFFILIATION_DISCLAIMER)}</p>`;

  // A fresh Marked instance per page. The image renderer closes over the file
  // name so a missing alt names the content file that caused it, and
  // marked.use() on the shared instance would stack one closure per page.
  const introHtml = new Marked({
    renderer: markedImageRenderer({ file: copy.file, rootDir: ROOT }),
  }).parse(copy.markdown);
  const introHtmlFinal = unwrapFigures(introHtml);
  const appScript = assetHrefs.appScriptHref || "/app.js";

  // The social card prefers its own 1200x630 file, then the hero, then the
  // shared default. A site relative file has to become absolute: a scraper
  // reads og:image without a page to resolve it against.
  const card = copy.ogImage || copy.image;
  const cardUrl = card ? (isRemote(card.src) ? card.src : `${SITE_ORIGIN}${card.src}`) : null;

  return `${renderHead({
    title,
    description,
    canonical,
    ogImage: cardUrl || DEFAULT_OG_IMAGE,
    ogImageAlt: card ? card.alt : undefined,
    ogImageWidth: card ? card.width : null,
    ogImageHeight: card ? card.height : null,
    ogType: "website",
    jsonLd,
    robots,
    extraMeta: `<link rel="stylesheet" href="/channels.css">`,
    stylesHref: assetHrefs.stylesHref,
    appScriptHref: appScript,
  })}
<body class="page-channels">
${renderNav()}

  <main id="top" class="channels-main">
    <div class="container container-narrow">
${renderBreadcrumb(crumbs)}
      <header class="channels-head">
        <h1>${escapeHtml(bundleHeading(bundle, copy))}</h1>
        <p class="channels-dek channels-dek--bundle">The ${escapeHtml(bundle.name)} bundle. ${escapeHtml(bundle.count)} channels, built from your own library.</p>
      </header>
${copy.image ? `      ${renderCover(copy.image, { className: "channels-cover" })}\n` : ""}
      <div class="bundle-intro">
${introHtmlFinal}
      </div>${copy.clip ? renderClip(copy.clip) : ""}

      <section class="bundle-channels" aria-labelledby="bundle-channels-heading">
        <h2 id="bundle-channels-heading">Channels in ${escapeHtml(bundle.name)}</h2>
        <ul class="bundle-channel-list">
${channelItems}${moreItem}
        </ul>${disclaimer}
      </section>

      <section class="bundle-faq" aria-labelledby="bundle-faq-heading">
        <h2 id="bundle-faq-heading">${escapeHtml(bundle.name)} FAQ</h2>
        <div class="bundle-faq-list">
${faqHtml}
        </div>
      </section>

      <section class="bundle-cta" aria-labelledby="bundle-cta-heading">
        <h2 id="bundle-cta-heading">Start watching</h2>
        <p>Nostalgex is free and open source. Set it up with <a href="/plex">Nostalgex for Plex</a> or <a href="/jellyfin">Nostalgex for Jellyfin</a>, get the <a href="${escapeAttr(APPLE_TV_URL)}" target="_blank" rel="noopener">Apple TV app from the App Store</a>, or see the whole lineup on the <a href="${escapeAttr(HUB_PATH)}">channel guide</a>.</p>
      </section>

      <section class="bundle-more" aria-labelledby="bundle-more-heading">
        <h2 id="bundle-more-heading">More bundles</h2>
        <ul class="bundle-more-list">
${moreBundles}
        </ul>
      </section>
    </div>
  </main>

${renderFooter({ includeEmby: false })}

  <script type="module" src="${escapeAttr(appScript)}"></script>
</body>
</html>
`;
}

// ---------------------------------------------------------------------------
// Build checks
// ---------------------------------------------------------------------------

class CheckLog {
  constructor() {
    this.failures = [];
  }
  fail(file, rule, detail) {
    this.failures.push({ file, rule, detail });
  }
  throwIfFailed() {
    if (!this.failures.length) return;
    const lines = this.failures.map(
      (f) => `  ${f.file} [${f.rule}]\n    ${f.detail}`,
    );
    throw new Error(
      `channel guide: ${this.failures.length} copy check failure${this.failures.length === 1 ? "" : "s"}\n${lines.join("\n")}`,
    );
  }
}

function checkDashes(log, file, label, text) {
  const i = text.search(DASH_RE);
  if (i === -1) return;
  log.fail(
    file,
    "dash in visible copy",
    `${label} contains "${text[i]}" (U+${text.codePointAt(i).toString(16).toUpperCase().padStart(4, "0")}): ${excerpt(text, i)}`,
  );
}

function checkBannedPhrases(log, file, text) {
  const lower = text.toLowerCase();
  for (const phrase of BANNED_PHRASES) {
    const i = lower.indexOf(phrase);
    if (i !== -1) {
      log.fail(
        file,
        "banned phrase",
        `"${phrase}": ${excerpt(text, i)}`,
      );
    }
  }
}

function checkHeldNames(log, file, label, text, matchers) {
  for (const hit of findHeldTerms(text, matchers)) {
    const i = text.toLowerCase().indexOf(hit.match.toLowerCase());
    log.fail(
      file,
      "held brand name on an indexed page",
      `${label} names "${hit.term}" (matched "${hit.match}"): ${excerpt(text, Math.max(0, i))}`,
    );
  }
}

function checkEmby(log, file, html) {
  const i = html.search(/emby/i);
  if (i !== -1) {
    log.fail(
      file,
      "Emby on a generated page",
      `the channel guide says "Plex or Jellyfin" only: ${excerpt(html, i, 40)}`,
    );
  }
}

async function checkHardCodedCounts(log, totalChannels) {
  const blogDir = path.join(ROOT, "content", "blog");
  const blogPosts = existsSync(blogDir)
    ? (await readdir(blogDir)).filter((f) => f.endsWith(".md")).map((f) => `content/blog/${f}`)
    : [];
  for (const page of [...COUNT_PAGES, ...blogPosts]) {
    const file = path.join(ROOT, page);
    if (!existsSync(file)) continue;
    const text = await readFile(file, "utf8");
    for (const claim of channelCountClaims(text)) {
      if (claim.plus && claim.n > totalChannels) {
        log.fail(page, "channel count overclaims",
          `"${claim.text}" but channels.json has ${totalChannels}.`);
      } else if (!claim.plus && claim.n !== totalChannels) {
        log.fail(page, "hard coded channel count drifted",
          `"${claim.text}" but channels.json has ${totalChannels}. Write "${Math.floor(totalChannels / 10) * 10}+ channels" ` +
            "so the sentence does not go stale again.");
      }
    }
    if (GUIDE_LINK_PAGES.includes(page) && !GUIDE_LINK_RE.test(text)) {
      log.fail(page, "guide link missing",
        `no "browse all N+ channels" link to ${HUB_PATH} found.`);
    }
  }
}

// ---------------------------------------------------------------------------
// lastmod
// ---------------------------------------------------------------------------

function gitLastCommitDate(relPath) {
  try {
    const out = execFileSync("git", ["log", "-1", "--format=%cs", "--", relPath], {
      cwd: ROOT,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
    return /^\d{4}-\d{2}-\d{2}$/.test(out) ? out : null;
  } catch {
    return null;
  }
}

function loadLastmodCache() {
  if (!existsSync(LASTMOD_PATH)) return {};
  try {
    const raw = readJson(LASTMOD_PATH);
    return raw && typeof raw === "object" ? raw : {};
  } catch {
    return {};
  }
}

// lastmod is the date of the last commit that touched the bundle: its object in
// channels.json, its channels, or its content file. Resolving that exactly
// would mean walking history per bundle on every build, so instead the inputs
// are hashed and the answer cached in scripts/bundle-lastmod.json. A hash that
// is already in the cache keeps its date; a new hash asks git for the newest
// commit date of channels.json and the content file. The build date is never
// stamped: if git cannot answer, the URL ships without a lastmod rather than
// with a lie.
function resolveLastmods(bundles, content) {
  const cache = loadLastmodCache();
  const dates = new Map();
  let cacheChanged = false;

  for (const bundle of bundles) {
    const copy = content.get(bundle.id);
    const fingerprint = JSON.stringify({
      bundle: bundle.raw,
      channels: bundle.channels.map((c) => c.raw),
      content: copy ? copy.raw : null,
    });
    const hash = createHash("sha256").update(fingerprint).digest("hex").slice(0, 16);
    const key = `${bundle.id}:${hash}`;

    let date = cache[key] || null;
    if (!date) {
      const inputs = [
        gitLastCommitDate("channels.json"),
        copy ? gitLastCommitDate(copy.file) : null,
      ];
      const known = inputs.filter(Boolean);
      date = known.length ? known.slice().sort().at(-1) : null;
      // Only cache an answer git could fully account for. A content file that
      // is still untracked has no commit date, so the bundle falls back to
      // channels.json's date for now and asks again next build rather than
      // freezing that fallback into the cache.
      const complete = inputs.every(Boolean);
      if (date && complete) {
        cache[key] = date;
        cacheChanged = true;
      }
    }
    dates.set(bundle.id, date);
  }

  const all = [...dates.values()].filter(Boolean).sort();
  return { dates, hubDate: all.length ? all.at(-1) : null, cache, cacheChanged };
}

// ---------------------------------------------------------------------------
// sitemap.xml and llms.txt
// ---------------------------------------------------------------------------

const SITEMAP_START = "<!-- CHANNELS:START (generated) -->";
const SITEMAP_END = "<!-- CHANNELS:END (generated) -->";

export function applySitemapBlock(raw, urls) {
  const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const cleaned = raw.replace(
    new RegExp(`\\s*${escapeRe(SITEMAP_START)}[\\s\\S]*?${escapeRe(SITEMAP_END)}`, "g"),
    "",
  );
  const urlXml = urls
    .map((entry) =>
      entry.lastmod
        ? `  <url><loc>${entry.loc}</loc><lastmod>${entry.lastmod}</lastmod></url>`
        : `  <url><loc>${entry.loc}</loc></url>`,
    )
    .join("\n");
  const block = `${SITEMAP_START}\n${urlXml}\n  ${SITEMAP_END}`;
  const out = cleaned.replace(/\n?<\/urlset>\s*$/, `\n${block}\n</urlset>\n`);
  if (out === cleaned) {
    throw new Error("sitemap.xml: could not find </urlset> to insert into");
  }
  return out;
}

// One generated line per indexed bundle. Held bundles are left out entirely,
// and the descriptions come from channels.json so they stay generic. Nothing
// else in llms.txt is touched.
export function applyLlmsSection(raw, section) {
  const heading = "## Channels";
  const start = raw.indexOf(heading);
  if (start !== -1) {
    const rest = raw.slice(start + heading.length);
    const nextIdx = rest.search(/\n## /);
    if (nextIdx === -1) {
      return `${raw.slice(0, start)}${section}\n`;
    }
    const end = start + heading.length + nextIdx + 1;
    return `${raw.slice(0, start)}${section}\n\n${raw.slice(end)}`;
  }
  const blogIdx = raw.indexOf("\n## Blog");
  if (blogIdx !== -1) {
    return `${raw.slice(0, blogIdx + 1)}${section}\n\n${raw.slice(blogIdx + 1)}`;
  }
  return `${raw.replace(/\s*$/, "")}\n\n${section}`;
}

function buildLlmsSection(model) {
  const { bundles, totalChannels, bundleCount } = model;
  const indexed = bundles.filter((b) => !b.held);
  const lines = indexed.map((bundle) => {
    // channels.json descriptions are generated copy, so any dash in one is
    // smoothed here rather than by hand editing the data.
    const desc = bundle.dataDescription.replace(/[‐-―−-]/g, " ").replace(/\s+/g, " ").trim();
    const tail = desc ? `${desc} ` : "";
    return `- [${bundle.name}](${SITE_ORIGIN}${HUB_PATH}/${bundle.id}): ${tail}(${bundle.count} channels)`;
  });
  return [
    "## Channels",
    "",
    `- [Channel Guide](${HUB_CANONICAL}): all ${totalChannels} channels in ${bundleCount} bundles`,
    "",
    "### Bundles",
    "",
    ...lines,
  ].join("\n");
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

function isStrict(options = {}) {
  if (options.strict != null) return options.strict;
  return process.argv.includes("--strict") || Boolean(process.env.CI);
}

export async function loadBundleModel(options = {}) {
  const strict = isStrict(options);
  const data = await loadChannelData();
  const { content, missing } = await loadBundleContent(data.bundles);

  if (missing.length) {
    const list = missing.map((id) => `content/bundles/${id}.md`).join(", ");
    if (strict) {
      throw new Error(
        `channel guide: ${missing.length} missing content file${missing.length === 1 ? "" : "s"}: ${list}\n` +
          "  Each bundle needs frontmatter (description, faq) and a 300 to 600 word intro.",
      );
    }
    console.warn(
      `channels: skipping ${missing.length} bundle${missing.length === 1 ? "" : "s"} with no content file: ${list}`,
    );
  }

  return {
    ...data,
    content,
    missing,
    strict,
    renderable: data.bundles.filter((b) => content.has(b.id)),
  };
}

// Returns a Map of dist-relative path to HTML, after every copy check has
// passed. renderBundles() is the one place that knows the output file names.
export async function renderBundles(assetHrefs = {}, options = {}) {
  const model = await loadBundleModel(options);
  const { bundles, renderable, totalChannels } = model;

  const heldChannelNames = [];
  for (const bundle of bundles) {
    for (const channel of bundle.channels) {
      if (channel.held) heldChannelNames.push(channel.rawName, channel.name);
    }
  }
  const matchers = buildHeldMatchers(heldChannelNames, loadLegalHold().heldBrands);

  const assets = new Map();
  const pages = [];

  const hubHtml = renderHubPage({ ...model, bundles }, assetHrefs);
  assets.set("channels.html", hubHtml);
  pages.push({
    file: "dist/channels.html",
    html: hubHtml,
    ...hubMeta(model),
    indexed: true,
    // The hub has no content file, so there is no intro to count.
    words: null,
  });

  for (const bundle of renderable) {
    const copy = model.content.get(bundle.id);
    const html = renderBundlePage(bundle, model, assetHrefs);
    assets.set(`channels/${bundle.id}.html`, html);
    pages.push({
      file: `dist/channels/${bundle.id}.html`,
      source: copy.file,
      html,
      title: bundleTitle(bundle, copy.titleOverride),
      description: copy.description,
      indexed: !bundle.held,
      words: copy.words,
      faq: copy.faq,
      bundle,
    });
  }

  const log = new CheckLog();
  const seenTitles = new Map();
  const seenDescriptions = new Map();

  for (const page of pages) {
    const where = page.source ? `${page.file} (${page.source})` : page.file;
    // Alt text and the aria-label on a clip are read by screen readers and by
    // Google, so the dash, held brand and banned phrase rules apply to them the
    // same as to body copy. visibleText() drops attributes, so add them back.
    const altText = [...page.html.matchAll(/(?:alt|aria-label)="([^"]*)"/g)]
      .map((m) => m[1])
      .filter(Boolean)
      .join(" ");
    const visible = `${visibleText(page.html)} ${decodeEntities(altText)}`.trim();

    // 1. No dash of any kind in visible copy, the title or the meta.
    checkDashes(log, where, "visible copy", visible);
    checkDashes(log, where, "title", page.title);
    checkDashes(log, where, "meta description", page.description);

    // 5. Nothing the channel guide generates mentions Emby.
    checkEmby(log, where, page.html);

    // 6. Banned phrases, on visible copy.
    checkBannedPhrases(log, where, visible);

    // 4. Unique, length capped titles and meta descriptions.
    if (page.title.length > TITLE_MAX) {
      log.fail(
        where,
        "title too long",
        `${page.title.length} chars (max ${TITLE_MAX}): "${page.title}"`,
      );
    }
    // Titles are hand written in the content files now, so the generated shape
    // no longer guarantees any of this: every one has to carry the brand, and
    // none should fall back to the old "Bundle: 19 Channels" pattern.
    if (!page.title.endsWith(" | Nostalgex")) {
      log.fail(where, "title missing the brand suffix", `"${page.title}" should end with " | Nostalgex"`);
    }
    if (/:\s*\d+\s+Channels/i.test(page.title)) {
      log.fail(where, "title still carries the channel count", `"${page.title}"`);
    }
    if (/Nostalgia TV/i.test(page.title)) {
      log.fail(where, "title says Nostalgia TV", `"${page.title}"`);
    }
    if (seenTitles.has(page.title)) {
      log.fail(
        where,
        "duplicate title",
        `"${page.title}" is already used by ${seenTitles.get(page.title)}`,
      );
    } else {
      seenTitles.set(page.title, where);
    }
    if (page.description.length > META_MAX) {
      log.fail(
        where,
        "meta description too long",
        `${page.description.length} chars (max ${META_MAX}): "${page.description}"`,
      );
    } else if (page.description.length < META_MIN) {
      log.fail(
        where,
        "meta description too short",
        `${page.description.length} chars (min ${META_MIN}): "${page.description}"`,
      );
    }
    if (seenDescriptions.has(page.description)) {
      log.fail(
        where,
        "duplicate meta description",
        `already used by ${seenDescriptions.get(page.description)}`,
      );
    } else {
      seenDescriptions.set(page.description, where);
    }

    // 3. Intro word count.
    if (page.words != null && (page.words < INTRO_MIN_WORDS || page.words > INTRO_MAX_WORDS)) {
      log.fail(
        where,
        "intro word count",
        `${page.words} words, needs ${INTRO_MIN_WORDS} to ${INTRO_MAX_WORDS}`,
      );
    }

    // FAQ shape.
    if (page.faq && (page.faq.length < FAQ_MIN || page.faq.length > FAQ_MAX)) {
      log.fail(
        where,
        "faq length",
        `${page.faq.length} question${page.faq.length === 1 ? "" : "s"}, needs ${FAQ_MIN} to ${FAQ_MAX}`,
      );
    }

    // 2. No held channel name and no brand from the hold list on an indexed
    // page, in visible copy, meta, or JSON-LD.
    if (page.indexed) {
      checkHeldNames(log, where, "visible copy", visible, matchers);
      checkHeldNames(log, where, "title", page.title, matchers);
      checkHeldNames(log, where, "meta description", page.description, matchers);
      checkHeldNames(log, where, "JSON-LD", jsonLdText(page.html), matchers);
    }
  }

  await checkHardCodedCounts(log, totalChannels);
  log.throwIfFailed();

  return { assets, model, pages };
}

async function writeAssets(assets, outDir) {
  for (const [relPath, html] of assets) {
    const target = path.join(outDir, relPath);
    await mkdir(path.dirname(target), { recursive: true });
    await writeFile(target, html, "utf8");
  }
}

async function copyTree(src, dest) {
  const entries = await readdir(src, { withFileTypes: true });
  await mkdir(dest, { recursive: true });
  for (const entry of entries) {
    const from = path.join(src, entry.name);
    const to = path.join(dest, entry.name);
    if (entry.isDirectory()) {
      await copyTree(from, to);
    } else if (entry.isFile()) {
      const existing = await stat(to).catch(() => null);
      if (existing) continue;
      await copyFile(from, to);
    }
  }
}

export async function writeBundlesToDist(distDir, options = {}) {
  const assetHrefs = await resolveViteAssetHrefs(distDir);
  const { assets, model } = await renderBundles(assetHrefs, options);
  await writeAssets(assets, distDir);

  // The footer logo is referenced absolutely (/logo/...), and the project-root
  // logo/ directory is outside public/, so Vite never copies it. The blog
  // emitter mirrors it for the same reason; copyTree skips files that are
  // already there, so running both is harmless.
  const srcLogo = path.join(ROOT, "logo");
  if (existsSync(srcLogo)) {
    await copyTree(srcLogo, path.join(distDir, "logo"));
  }

  return {
    bundles: model.renderable.length,
    indexed: model.renderable.filter((b) => !b.held).length,
    held: model.renderable.filter((b) => b.held).length,
    skipped: model.missing,
    totalChannels: model.totalChannels,
  };
}

async function updateSitemap(model, lastmods) {
  const raw = await readFile(SITEMAP_PATH, "utf8");
  const indexed = model.renderable.filter((b) => !b.held);
  const urls = [
    { loc: HUB_CANONICAL, lastmod: lastmods.hubDate },
    ...indexed.map((bundle) => ({
      loc: `${SITE_ORIGIN}${HUB_PATH}/${bundle.id}`,
      lastmod: lastmods.dates.get(bundle.id),
    })),
  ];
  await writeFile(SITEMAP_PATH, applySitemapBlock(raw, urls), "utf8");
  return urls.length;
}

async function updateLlms(model) {
  const raw = await readFile(LLMS_PATH, "utf8");
  await writeFile(LLMS_PATH, applyLlmsSection(raw, buildLlmsSection(model)), "utf8");
}

async function main() {
  const { model, pages } = await renderBundles({});
  const lastmods = resolveLastmods(model.renderable, model.content);

  const urlCount = await updateSitemap(model, lastmods);
  await updateLlms(model);
  if (lastmods.cacheChanged) {
    await writeFile(
      LASTMOD_PATH,
      `${JSON.stringify(lastmods.cache, null, 2)}\n`,
      "utf8",
    );
  }

  const indexed = model.renderable.filter((b) => !b.held);
  const held = model.renderable.filter((b) => b.held);
  console.log(
    `channels: ${model.renderable.length} bundle page${model.renderable.length === 1 ? "" : "s"} + hub, ` +
      `${indexed.length} indexed, ${held.length} held, ${model.totalChannels} channels total`,
  );
  if (held.length) {
    console.log(`channels: held (noindex, out of sitemap and llms.txt): ${held.map((b) => b.id).join(", ")}`);
  }
  for (const page of pages) {
    if (page.words != null) {
      console.log(`channels: ${page.file} intro ${page.words} words`);
    }
  }
  console.log(`channels: sitemap updated with ${urlCount} url${urlCount === 1 ? "" : "s"}, llms.txt Channels section rewritten`);
}

const entryPath = process.argv[1] ? path.resolve(process.argv[1]) : "";
const selfPath = path.resolve(fileURLToPath(import.meta.url));

if (entryPath === selfPath) {
  main().catch((err) => {
    console.error(err.message || err);
    process.exit(1);
  });
}
