#!/usr/bin/env node
/**
 * channels.json, checked before it can be deployed.
 *
 * Every app (Apple TV, Roku, Android) and the web tuner fetch https://www.nostalgex.app/channels.json, so a bad file
 * pushed to main reaches every device on its next fetch. This is the pre-deploy gate, in `npm test` and CI:
 *
 *   1. It parses, and has a version, bundles and channels.
 *   2. Every channel has the fields the loaders need (id, number, name, colorHex, category, minItems, rules) of the
 *      right kind. The optional ones (timeRestrictions, isPremiereChannel) are the loaders' own.
 *   3. Ids are unique and numbers are unique, each on its own (a channel's id is not always its number).
 *   4. Every bundle has an id, a name, a description and channelIDs that are real channel ids, each channel in a bundle
 *      that exists, and a channel's category is a bundle.
 *   5. Every key a channel's rules use, and every key in exclusiveRules, is one that all four loaders know: the Swift
 *      Channel model, the JS filter (scripts/nostalgex-channel-filter.cjs), the Roku filter and the Android filter. A key one
 *      of them has never heard of would be dropped there without a word, so the channel would air different titles on
 *      each surface. Teach the loaders first (Swift and JS together, with the shared golden file), then the data.
 *      The channel and bundle fields (not the rules') are held to the known lists below, which each loader's own source is
 *      searched for.
 *   6. `version` is a whole number that is not lower than the copy deployed now (www.nostalgex.app/channels.json). Offline
 *      this is skipped with a line saying so, unless NX_CHANNELS_REQUIRE_PREVIOUS=1 (CI sets it), when an unreachable
 *      copy fails the check. NX_CHANNELS_PREVIOUS=/path/to/channels.json compares against a file instead (tests).
 *   7. `formatVersion`, if it is there, is a whole number from 1 up that is at most 1, the newest format this build of the
 *      apps reads (FORMAT_VERSION_MAX; raise it with the loaders).
 *
 * It reuses what scripts/ already checks: the filter smoke (test:filter) holds the JS filter to every rule field, and the
 * rule key list here is read from the data and searched for in the loaders, not copied. Run: `npm run channels:json:check`.
 */
import { readFileSync, existsSync, readdirSync, statSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { join } from "node:path";

const repo = fileURLToPath(new URL("../", import.meta.url));
const FORMAT_VERSION_MAX = 1;
const LIVE_URL = "https://www.nostalgex.app/channels.json";

/** The channel's own fields, and what each must be. */
const CHANNEL_FIELDS = {
  id: "integer", number: "integer", name: "string", colorHex: "color", category: "string", minItems: "integer", rules: "object",
  timeRestrictions: "any", isPremiereChannel: "boolean",
};
const CHANNEL_REQUIRED = ["id", "number", "name", "colorHex", "category", "minItems", "rules"];
const BUNDLE_REQUIRED = ["id", "name", "description", "channelIDs"];
const BUNDLE_OPTIONAL = ["activeMonths", "seasonStart"];
/** A channel's category is a bundle's id, or this: the franchise channels are gathered into their bundle by the app. */
const EXTRA_CATEGORIES = ["franchise"];
/** The top level of the file. */
const TOP_FIELDS = ["version", "formatVersion", "exclusiveRules", "bundles", "channels"];

/** Where each loader reads a channel's rules. A rule key has to be in all four. */
const RULE_LOADERS = {
  Swift: ["Nostalgex/Nostalgex/Models/Channel.swift"],
  JS: ["scripts/nostalgex-channel-filter.cjs"],
  Roku: ["roku/source/filter/ChannelFilter.brs"],
  Android: ["android/engine/src/main/kotlin/com/muellhaus/nostalgex/engine/ChannelFilter.kt"],
};
/** Where each loader reads the fields around the rules (the optional channel and bundle fields): its whole source. */
const FIELD_LOADERS = {
  Swift: { dirs: ["Nostalgex/Nostalgex"], ext: [".swift"] },
  JS: { dirs: ["scripts"], ext: [".js", ".cjs"], prefix: "nostalgex-" },
  Roku: { dirs: ["roku/source", "roku/components"], ext: [".brs"] },
  Android: { dirs: ["android/engine/src/main"], ext: [".kt"] },
};

const problems = [];
const fail = (msg) => problems.push(msg);
const where = (c, i) => `channel ${c && c.id !== undefined ? `id ${c.id}` : `#${i}`}${c && c.name ? ` (${c.name})` : ""}`;

export function validateChannels(doc, { loaderText, previous, previousError, requirePrevious, warnings = [] } = {}) {
  const out = [];
  const bad = (m) => out.push(m);
  const warn = (m) => warnings.push(m);
  if (!doc || typeof doc !== "object" || Array.isArray(doc)) { bad("channels.json is not an object"); return out; }
  for (const k of Object.keys(doc)) if (!TOP_FIELDS.includes(k)) bad(`unknown top-level key "${k}" (known: ${TOP_FIELDS.join(", ")})`);
  if (!Number.isInteger(doc.version) || doc.version < 1) bad(`version must be a whole number from 1 up, got ${JSON.stringify(doc.version)}`);
  if (!Array.isArray(doc.channels) || !doc.channels.length) bad("channels must be a non-empty list");
  if (!Array.isArray(doc.bundles) || !doc.bundles.length) bad("bundles must be a non-empty list");
  if ("formatVersion" in doc) {
    const f = doc.formatVersion;
    if (!Number.isInteger(f) || f < 1) bad(`formatVersion must be a whole number from 1 up, got ${JSON.stringify(f)}`);
    else if (f > FORMAT_VERSION_MAX) bad(`formatVersion is ${f}, and the apps in the store read up to ${FORMAT_VERSION_MAX}: a newer format has to ship in the apps before the file uses it`);
  }
  if (!Array.isArray(doc.channels) || !Array.isArray(doc.bundles)) return out;

  const kind = { integer: Number.isInteger, string: (v) => typeof v === "string" && v.trim() !== "", boolean: (v) => typeof v === "boolean",
    object: (v) => v && typeof v === "object" && !Array.isArray(v), color: (v) => typeof v === "string" && /^#[0-9A-Fa-f]{6}$/.test(v), any: () => true };
  const ids = new Map(), numbers = new Map();
  doc.channels.forEach((c, i) => {
    const w = where(c, i);
    if (!c || typeof c !== "object") { bad(`${w} is not an object`); return; }
    for (const f of CHANNEL_REQUIRED) if (!(f in c)) bad(`${w}: missing "${f}"`);
    for (const [f, v] of Object.entries(c)) {
      if (!(f in CHANNEL_FIELDS)) bad(`${w}: unknown field "${f}" (no loader reads it)`);
      else if (!kind[CHANNEL_FIELDS[f]](v)) bad(`${w}: "${f}" should be ${CHANNEL_FIELDS[f] === "color" ? "a #RRGGBB colour" : `a ${CHANNEL_FIELDS[f]}`}, got ${JSON.stringify(v)}`);
    }
    if (Number.isInteger(c.id)) { if (ids.has(c.id)) bad(`${w}: id ${c.id} is also used by ${ids.get(c.id)}`); else ids.set(c.id, w); }
    if (Number.isInteger(c.number)) { if (numbers.has(c.number)) bad(`${w}: number ${c.number} is also used by ${numbers.get(c.number)}`); else numbers.set(c.number, w); }
    if (Number.isInteger(c.minItems) && c.minItems < 1) bad(`${w}: minItems must be at least 1`);
  });

  const bundleIds = new Set();
  const inBundle = new Set();
  doc.bundles.forEach((b, i) => {
    const w = `bundle ${b && b.id !== undefined ? `"${b.id}"` : `#${i}`}`;
    if (!b || typeof b !== "object") { bad(`${w} is not an object`); return; }
    for (const f of BUNDLE_REQUIRED) if (!(f in b)) bad(`${w}: missing "${f}"`);
    for (const f of Object.keys(b)) if (!BUNDLE_REQUIRED.includes(f) && !BUNDLE_OPTIONAL.includes(f)) bad(`${w}: unknown field "${f}" (known: ${[...BUNDLE_REQUIRED, ...BUNDLE_OPTIONAL].join(", ")})`);
    if (typeof b.id !== "string" || !b.id) bad(`${w}: id must be a non-empty string`);
    else if (bundleIds.has(b.id)) bad(`${w}: id used twice`); else bundleIds.add(b.id);
    if (typeof b.name !== "string" || !b.name) bad(`${w}: name must be a non-empty string`);
    if (!Array.isArray(b.channelIDs)) bad(`${w}: channelIDs must be a list`);
    else {
      const seen = new Set();
      for (const id of b.channelIDs) {
        if (!ids.has(id)) bad(`${w}: channelIDs has ${JSON.stringify(id)}, which is not a channel id`);
        if (seen.has(id)) bad(`${w}: channelIDs lists ${id} twice`);
        seen.add(id); inBundle.add(id);
      }
    }
  });
  for (const c of doc.channels) if (c && typeof c.category === "string" && !bundleIds.has(c.category) && !EXTRA_CATEGORIES.includes(c.category)) bad(`${where(c)}: category "${c.category}" is not a bundle id (or ${EXTRA_CATEGORIES.join(", ")})`);

  // Rules keys, all four loaders.
  const ruleKeys = new Map();   // key -> first place it is used
  doc.channels.forEach((c, i) => {
    if (c && c.rules && typeof c.rules === "object") for (const k of Object.keys(c.rules)) if (!ruleKeys.has(k)) ruleKeys.set(k, where(c, i));
  });
  if (doc.exclusiveRules !== undefined) {
    if (!Array.isArray(doc.exclusiveRules)) bad("exclusiveRules must be a list");
    else doc.exclusiveRules.forEach((r, i) => {
      if (!r || typeof r !== "object") return bad(`exclusiveRules[${i}] is not an object`);
      if (!Array.isArray(r.channelIDs)) bad(`exclusiveRules[${i}]: channelIDs must be a list`);
      else for (const id of r.channelIDs) if (!ids.has(id)) warn(`exclusiveRules[${i}]: channelIDs has ${JSON.stringify(id)}, which is not a channel id (the loaders skip it)`);
      for (const k of Object.keys(r)) if (k !== "channelIDs" && !ruleKeys.has(k)) ruleKeys.set(k, `exclusiveRules[${i}]`);
    });
  }
  if (loaderText) {
    const knows = (text, key) => new RegExp(`(^|[^A-Za-z0-9_])${key}([^A-Za-z0-9_]|$)`).test(text);
    for (const [key, firstSeen] of ruleKeys) {
      const missing = Object.keys(RULE_LOADERS).filter((p) => !RULE_LOADERS[p].some((f) => loaderText.files[f] !== undefined && knows(loaderText.files[f], key)));
      if (missing.length) bad(`rule key "${key}" (first used by ${firstSeen}) is not known to the ${missing.join(", ")} loader${missing.length > 1 ? "s" : ""}: it would be ignored there. Add it to the loader first`);
    }
    const optional = [["timeRestrictions", "channel field", (d) => d.channels.some((c) => c && "timeRestrictions" in c)],
      ["isPremiereChannel", "channel field", (d) => d.channels.some((c) => c && "isPremiereChannel" in c)],
      ...BUNDLE_OPTIONAL.map((k) => [k, "bundle field", (d) => d.bundles.some((b) => b && k in b)])];
    for (const [key, what, used] of optional) {
      if (!used(doc)) continue;
      const missing = Object.keys(FIELD_LOADERS).filter((p) => !(loaderText.sources[p] || []).some((t) => knows(t, key)));
      if (missing.length) bad(`${what} "${key}" is not known to the ${missing.join(", ")} loader${missing.length > 1 ? "s" : ""}`);
    }
  }

  // The copy deployed now.
  if (previous) {
    if (Number.isInteger(previous.version) && Number.isInteger(doc.version) && doc.version < previous.version) {
      bad(`version ${doc.version} is lower than the deployed copy's ${previous.version}: devices keep the higher one, so this file would never be picked up. Raise it above ${previous.version - 1}`);
    }
  } else if (requirePrevious) {
    bad(`the deployed copy could not be read (${previousError || "no answer"}), so the version could not be compared`);
  }
  return out;
}

function walk(dir, ext, prefix, out) {
  if (!existsSync(dir)) return;
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) { if (!/^(node_modules|build|out|\.)/.test(name)) walk(p, ext, prefix, out); continue; }
    if (ext.some((e) => name.endsWith(e)) && (!prefix || name.startsWith(prefix)) && !/smoke|test/i.test(name)) out.push(readFileSync(p, "utf8"));
  }
}

function readLoaders() {
  const files = {};
  for (const list of Object.values(RULE_LOADERS)) for (const f of list) {
    const p = join(repo, f);
    files[f] = existsSync(p) ? readFileSync(p, "utf8") : undefined;
    if (files[f] === undefined) fail(`loader source ${f} is missing, so its rule keys cannot be checked`);
  }
  const sources = {};
  for (const [platform, spec] of Object.entries(FIELD_LOADERS)) {
    sources[platform] = [];
    for (const d of spec.dirs) walk(join(repo, d), spec.ext, spec.prefix, sources[platform]);
  }
  return { files, sources };
}

async function previousCopy() {
  if (process.env.NX_CHANNELS_PREVIOUS) {
    try { return { doc: JSON.parse(readFileSync(process.env.NX_CHANNELS_PREVIOUS, "utf8")) }; } catch (e) { return { error: `${process.env.NX_CHANNELS_PREVIOUS}: ${e.message}` }; }
  }
  try {
    const res = await fetch(`${LIVE_URL}?check=${Date.now()}`, { signal: AbortSignal.timeout(10000), headers: { "Cache-Control": "no-cache" } });
    if (!res.ok) return { error: `HTTP ${res.status} from ${LIVE_URL}` };
    return { doc: await res.json() };
  } catch (e) { return { error: `${LIVE_URL}: ${e.message}` }; }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  let doc = null;
  try { doc = JSON.parse(readFileSync(join(repo, "channels.json"), "utf8")); } catch (e) { fail(`channels.json does not parse: ${e.message}`); }
  if (doc) {
    const requirePrevious = process.env.NX_CHANNELS_REQUIRE_PREVIOUS === "1";
    const { doc: previous, error } = await previousCopy();
    if (!previous && !requirePrevious) console.log(`channels-json-check: the deployed copy could not be read (${error}); the version comparison is skipped`);
    const warnings = [];
    problems.push(...validateChannels(doc, { loaderText: readLoaders(), previous, previousError: error, requirePrevious, warnings }));
    for (const w of warnings) console.log(`channels-json-check: note: ${w}`);
    if (!problems.length) {
      console.log(`channels-json-check: channels.json version ${doc.version}${doc.formatVersion ? `, format ${doc.formatVersion}` : ""}: ${doc.channels.length} channels, ${doc.bundles.length} bundles, ids and numbers unique, every rule key known to Swift, JS, Roku and Android${previous ? `, not lower than the deployed ${previous.version}` : ""}`);
    }
  }
  if (problems.length) {
    console.error(`channels-json-check: channels.json must not be deployed as it is. ${problems.length} problem${problems.length > 1 ? "s" : ""}:`);
    for (const p of problems) console.error(`  - ${p}`);
    process.exit(1);
  }
}
