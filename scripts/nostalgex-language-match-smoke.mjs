#!/usr/bin/env node
/**
 * Language matching in the web tuner (N-014). Jellyfin and Emby label a track with a
 * three-letter ISO 639-2 code ("spa", "ger", "ces"); the viewer's setting is a two-letter
 * ISO 639-1 one ("es", "de", "cs"). The page used to compare the first letters, so "est"
 * (Estonian) passed as Spanish, "arm" (Armenian) as Arabic, "jav" (Javanese) as Japanese and
 * "slo" (Slovak) as Slovenian, and "ces" (Czech) missed "cs".
 *
 * The fix is one ISO 639-2 table and an exact compare. The table is the Roku app's
 * NxIso639Table (issue #119); the Apple TV app carries the same string. This smoke reads the
 * Roku file and holds scripts/nostalgex-language.js to it, character for character, so the
 * three apps reduce every code the same way.
 *
 * Runs the page's own langMatches, pickAudioStream, pickSubtitle and shouldAutoEnableSubs,
 * cut out of plex-tuner.html, so what is checked here is what the viewer gets.
 *
 * Run: `npm run test:language-match`. Point TUNER / ROKU / LANG_MODULE at other files for a negative
 * control (TUNER=<the page from before the fix> reproduces the bug).
 */
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import { fileURLToPath, pathToFileURL } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const tunerPath = process.env.TUNER || path.join(root, "plex-tuner.html");
const rokuPath = process.env.ROKU || path.join(root, "roku/source/subtitles/SubtitleSettings.brs");
const langPath = process.env.LANG_MODULE || path.join(root, "scripts/nostalgex-language.js");
const tuner = fs.readFileSync(tunerPath, "utf8");
const roku = fs.readFileSync(rokuPath, "utf8");
const langSource = fs.existsSync(langPath) ? fs.readFileSync(langPath, "utf8") : null;
await import(pathToFileURL(path.join(root, "scripts/nostalgex-jellyfin-urls.js")).href);
const JU = globalThis.NostalgexJellyfinUrls;

let passed = 0;
const failures = [];
async function check(label, fn) {
  try {
    await fn();
    passed += 1;
  } catch (e) {
    failures.push(`${label}: ${e.message}`);
  }
}
function assert(ok, msg) {
  if (!ok) throw new Error(msg);
}
const list = (items, max = 12) => `${items.slice(0, max).join(", ")}${items.length > max ? `, and ${items.length - max} more` : ""}`;

// Cut a top-level-in-script function out of the page by matching braces, skipping strings,
// template literals and comments.
function extractFunction(src, name) {
  const start = src.search(new RegExp(`(async\\s+)?function\\s+${name}\\s*\\(`));
  if (start < 0) throw new Error(`${name} not found in ${path.basename(tunerPath)}`);
  let i = src.indexOf("{", src.indexOf(")", start));
  let depth = 0;
  const stack = [];
  for (; i < src.length; i++) {
    const c = src[i], n = src[i + 1];
    const mode = stack[stack.length - 1];
    if (mode === "line") { if (c === "\n") stack.pop(); continue; }
    if (mode === "block") { if (c === "*" && n === "/") { stack.pop(); i++; } continue; }
    if (mode === "'" || mode === '"') { if (c === "\\") i++; else if (c === mode) stack.pop(); continue; }
    if (mode === "`") {
      if (c === "\\") i++;
      else if (c === "`") stack.pop();
      else if (c === "$" && n === "{") { stack.push("${"); depth++; i++; }
      continue;
    }
    if (c === "/" && n === "/") { stack.push("line"); i++; continue; }
    if (c === "/" && n === "*") { stack.push("block"); i++; continue; }
    if (c === "'" || c === '"' || c === "`") { stack.push(c); continue; }
    if (c === "{") depth++;
    if (c === "}") {
      depth--;
      if (mode === "${") stack.pop();
      if (depth === 0) return src.slice(start, i + 1);
    }
  }
  throw new Error(`${name}: unbalanced braces`);
}

// The page's language code, as one script for a vm context: the module when it exists (the
// fixed page calls it), the old page's own table when it has one, then langMatches.
function pageLanguageCode() {
  const oldTable = (/const ISO6391_TO_6392 = \{[\s\S]*?\};/.exec(tuner) || [""])[0];
  return `${oldTable}\n${extractFunction(tuner, "langMatches")}`;
}
function pageContext(extra = {}) {
  const ctx = { NostalgexJellyfinUrls: JU, ...extra };
  vm.createContext(ctx);
  if (langSource) vm.runInContext(langSource, ctx);
  return ctx;
}
const matcher = (() => {
  const ctx = pageContext();
  vm.runInContext(`${pageLanguageCode()}; this.m = langMatches;`, ctx);
  return ctx.m;
})();

// ---- the Roku table, read from the repo ----

const rokuPairsString = (/pairs = "([^"]+)"/.exec(roku) || [])[1];
const rokuPairs = (rokuPairsString || "").split(" ").filter(Boolean).map(p => p.split(":"));
const twoLetters = new Set(rokuPairs.map(([, two]) => two));

await check("the Roku table is where this smoke expects it", () => {
  assert(rokuPairsString, `NxIso639Table's pairs string not found in ${rokuPath}`);
  assert(rokuPairs.length >= 200, `only ${rokuPairs.length} pairs, want both forms of every ISO 639-1 language`);
  assert(rokuPairs.some(([a, b]) => a === "cze" && b === "cs") && rokuPairs.some(([a, b]) => a === "ces" && b === "cs"), "no cze:cs and ces:cs");
});

// ---- the module ----

const Lang = (() => {
  if (!langSource) return null;
  const ctx = {};
  vm.createContext(ctx);
  vm.runInContext(langSource, ctx);
  return ctx.NostalgexLanguage || null;
})();

await check("scripts/nostalgex-language.js exists and defines NostalgexLanguage", () => {
  assert(langSource, `${langPath} does not exist`);
  assert(Lang && typeof Lang.primaryLanguage === "function" && typeof Lang.sameLanguage === "function", "no NostalgexLanguage.primaryLanguage and sameLanguage");
});
await check("the module's table is the Roku table, character for character", () => {
  assert(Lang, "no module");
  assert(Lang.ISO639_PAIRS === rokuPairsString, "ISO639_PAIRS differs from NxIso639Table in SubtitleSettings.brs");
});
await check("every pair in the Roku table reduces the same way here", () => {
  assert(Lang, "no module");
  const wrong = rokuPairs.filter(([three, two]) => Lang.primaryLanguage(three) !== two).map(([three, two]) => `${three}->${Lang.primaryLanguage(three)} (want ${two})`);
  assert(wrong.length === 0, `${wrong.length} disagree: ${list(wrong)}`);
});
await check("the page loads the module with a plain script tag", () => {
  assert(/<script src="scripts\/nostalgex-language\.js"><\/script>/.test(tuner), "no <script src=\"scripts/nostalgex-language.js\"> in the page");
});
await check("the page keeps no table of its own and compares no first letters", () => {
  assert(!/ISO6391_TO_6392/.test(tuner), "plex-tuner.html still has ISO6391_TO_6392");
  const fn = extractFunction(tuner, "langMatches");
  assert(!/startsWith|endsWith|substr|substring|slice|indexOf/.test(fn), "langMatches still shortens or prefix-compares a code");
});

// ---- langMatches: the look-alikes ----

// A code whose first two letters spell another language's two-letter code: "est" -> "es".
const lookalikes = rokuPairs
  .map(([three, two]) => ({ three, two, like: three.slice(0, 2) }))
  .filter(p => p.like !== p.two && twoLetters.has(p.like));

await check("the table has look-alikes to test (the Apple TV count is 66)", () => {
  assert(lookalikes.length >= 60, `only ${lookalikes.length}`);
});
await check("no three-letter code matches the language its first two letters spell", () => {
  const matched = lookalikes.filter(p => matcher(p.three, p.like)).map(p => `${p.three} as ${p.like}`);
  assert(matched.length === 0, `${matched.length} of ${lookalikes.length} look-alikes matched: ${list(matched)}`);
});
await check("the named look-alikes: est/es, arm/ar, jav/ja, slo/sl, rum/ru, swe/sw", () => {
  const matched = [["est", "es"], ["arm", "ar"], ["jav", "ja"], ["slo", "sl"], ["rum", "ru"], ["swe", "sw"]]
    .filter(([t, p]) => matcher(t, p)).map(([t, p]) => `${t} as ${p}`);
  assert(matched.length === 0, `matched: ${matched.join(", ")}`);
});
await check("every code in the table, in either form, matches its own viewer", () => {
  const missed = rokuPairs.filter(([three, two]) => !matcher(three, two)).map(([three, two]) => `${three} for ${two}`);
  assert(missed.length === 0, `${missed.length} of ${rokuPairs.length} codes missed their own viewer: ${list(missed)}`);
});
await check("Czech and Slovak match in both forms (ces and cze, slk and slo)", () => {
  const missed = [["ces", "cs"], ["cze", "cs"], ["slk", "sk"], ["slo", "sk"]].filter(([t, p]) => !matcher(t, p)).map(([t, p]) => `${t} for ${p}`);
  assert(missed.length === 0, `missed: ${missed.join(", ")}`);
});
await check("the look-alike's own viewer still gets it (est for et, arm for hy, jav for jv)", () => {
  const missed = [["est", "et"], ["arm", "hy"], ["hye", "hy"], ["jav", "jv"], ["slo", "sk"], ["rum", "ro"], ["swe", "sv"]].filter(([t, p]) => !matcher(t, p)).map(([t, p]) => `${t} for ${p}`);
  assert(missed.length === 0, `missed: ${missed.join(", ")}`);
});

// ---- langMatches: the everyday cases still work ----

await check("common languages still match, with regions on either side", () => {
  const cases = [
    ["eng", "en"], ["en", "en"], ["en-US", "en"], ["eng", "en-GB"], ["spa", "es"], ["spa", "es-MX"], ["fre", "fr"], ["fra", "fr-CA"],
    ["ger", "de"], ["deu", "de"], ["ita", "it"], ["por", "pt"], ["por", "pt-BR"], ["jpn", "ja"], ["kor", "ko"], ["chi", "zh"],
    ["zho", "zh"], ["zh-Hans", "zh"], ["rus", "ru"], ["dut", "nl"], ["nld", "nl"], ["pol", "pl"], ["swe", "sv"], ["tur", "tr"],
    ["gre", "el"], ["ell", "el"], ["ara", "ar"], ["dan", "da"], ["fin", "fi"], ["nor", "no"], ["ENG", "EN"], [" eng ", "en"], ["pt_BR", "pt"],
  ];
  const missed = cases.filter(([t, p]) => !matcher(t, p)).map(([t, p]) => `${t} for ${p}`);
  assert(missed.length === 0, `${missed.length} missed: ${missed.join(", ")}`);
});
await check("different languages still do not match", () => {
  const matched = [["spa", "en"], ["ger", "en"], ["eng", "es"], ["fra", "de"], ["jpn", "ko"], ["chi", "ja"], ["por", "es"], ["ita", "es"], ["dut", "de"]]
    .filter(([t, p]) => matcher(t, p)).map(([t, p]) => `${t} as ${p}`);
  assert(matched.length === 0, `matched: ${matched.join(", ")}`);
});
await check("a code the table lacks matches only itself, the way Roku and Apple TV do (yue)", () => {
  assert(matcher("yue", "yue"), "yue vs yue");
  assert(matcher("yue-HK", "yue"), "yue-HK vs yue");
  assert(!matcher("qaa", "qa") && !matcher("yue", "zh"), "an unknown code matched a different one");
});
await check("und, mul, zxx, mis, empty and missing match nothing, not even each other", () => {
  for (const code of ["und", "mul", "zxx", "mis", "", null, undefined]) {
    assert(!matcher(code, "en") && !matcher("eng", code) && !matcher(code, code), `${JSON.stringify(code)} matched`);
  }
});

// ---- the page's own picks ----

function pageFlows(source, { audioLanguage = "__system__", autoSubs = true, subtitleLanguage = "__system__" } = {}) {
  const ctx = pageContext({ navigator: { language: "en-US" } });
  vm.runInContext(
    `var audioLanguage = ${JSON.stringify(audioLanguage)}; var subtitleLanguage = ${JSON.stringify(subtitleLanguage)}; var autoSubsForeignAudio = ${autoSubs};
${pageLanguageCode()}
${["resolveSubtitleLanguage", "pickSubtitle", "pickAudioStream", "resolveAudioLanguage", "shouldAutoEnableSubs"].map(n => extractFunction(source, n)).join("\n")}
this.pickAudioStream = pickAudioStream; this.pickSubtitle = pickSubtitle; this.shouldAutoEnableSubs = shouldAutoEnableSubs;`,
    ctx,
  );
  return ctx;
}
const audio = (lang, index = 1) => ({ index, lang, channels: 2 });
const sub = (lang, index = 1, forced = false) => ({ index, lang, forced, codec: "subrip" });

await check("audio pick, Spanish viewer: the Spanish track wins over an Estonian one listed first", () => {
  const p = pageFlows(tuner, { audioLanguage: "es" }).pickAudioStream([audio("est", 1), audio("spa", 2)]);
  assert(p && p.index === 2, `picked ${JSON.stringify(p)}`);
});
await check("audio pick, Estonian viewer: the Estonian track", () => {
  const p = pageFlows(tuner, { audioLanguage: "et" }).pickAudioStream([audio("spa", 1), audio("est", 2)]);
  assert(p && p.index === 2, `picked ${JSON.stringify(p)}`);
});
await check("audio pick, Czech viewer: ces and cze both found", () => {
  for (const code of ["ces", "cze"]) {
    const p = pageFlows(tuner, { audioLanguage: "cs" }).pickAudioStream([audio("hun", 1), audio(code, 2)]);
    assert(p && p.index === 2, `${code}: picked ${JSON.stringify(p)}`);
  }
});
await check("audio pick, Arabic and Japanese viewers: Armenian and Javanese are not picked", () => {
  assert(pageFlows(tuner, { audioLanguage: "ar" }).pickAudioStream([audio("arm", 1)]) === null, "arm picked for ar");
  assert(pageFlows(tuner, { audioLanguage: "ja" }).pickAudioStream([audio("jav", 1)]) === null, "jav picked for ja");
});
await check("subtitle pick, Spanish viewer: the Spanish track wins over an Estonian one listed first", () => {
  const p = pageFlows(tuner, { subtitleLanguage: "es" }).pickSubtitle([sub("est", 1), sub("spa", 2)]);
  assert(p && p.index === 2, `picked ${JSON.stringify(p)}`);
});
await check("subtitle pick, German viewer: ger is found (the old compare knew it only through a table)", () => {
  const p = pageFlows(tuner, { subtitleLanguage: "de" }).pickSubtitle([sub("eng", 1), sub("ger", 2)]);
  assert(p && p.index === 2, `picked ${JSON.stringify(p)}`);
});
await check("subtitle pick: only look-alike tracks means no subtitles, not the wrong language", () => {
  assert(pageFlows(tuner, { subtitleLanguage: "es" }).pickSubtitle([sub("est", 1)]) === null, "est picked for es");
});
await check("foreign audio: an Estonian-only file is foreign to a Spanish viewer, so subtitles come on", () => {
  assert(pageFlows(tuner, { audioLanguage: "es" }).shouldAutoEnableSubs([audio("est")]) === true, "est counted as Spanish");
});
await check("foreign audio: a Spanish track keeps subtitles off for a Spanish viewer, Czech too", () => {
  assert(pageFlows(tuner, { audioLanguage: "es" }).shouldAutoEnableSubs([audio("est"), audio("spa")]) === false, "spa not found");
  assert(pageFlows(tuner, { audioLanguage: "cs" }).shouldAutoEnableSubs([audio("ces")]) === false, "ces not found for cs");
});
await check("the browser's own language (navigator.language) picks through the same compare", () => {
  const p = pageFlows(tuner, { subtitleLanguage: "__system__" }).pickSubtitle([sub("eng", 1), sub("spa", 2)]);
  assert(p && p.index === 1, `picked ${JSON.stringify(p)}`);
});

if (failures.length) {
  console.error(`language-match: ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error("  " + f);
  process.exit(1);
}
console.log(`language-match: ${passed} passed (${rokuPairs.length} table codes, ${lookalikes.length} look-alikes)`);
