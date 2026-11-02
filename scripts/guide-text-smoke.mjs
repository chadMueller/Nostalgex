#!/usr/bin/env node
/**
 * GUIDE TEXT SIZE: the web tuner's numbers are the Apple TV's and Roku's.
 *
 * There is no shared golden file for this setting (it is sizes, not schedule logic), so this
 * reads the three sources and holds them together:
 *
 *   Nostalgex/Nostalgex/Models/GuideTextSize.swift    GuideTextMetrics.normal and .large
 *   roku/source/guide/GuideText.brs                   NxGuideTextSizes(false) and (true)
 *   plex-tuner.html                                   the --gt-* multipliers on .guide-grid
 *
 * Swift and Roku must agree with each other, and the page's multiplier for each part of the
 * guide must be the Swift LARGE size over its NORMAL size. NORMAL must be 1 everywhere, so the
 * guide draws exactly what it drew before the setting existed, and no guide rule may carry a
 * raw font size that would escape the multiplier. The storage key is the Apple TV's.
 *
 * The page's one deliberate exception, the time labels on a phone, is named below.
 *
 * Run: `npm run test:guide-text`
 */
import { readFileSync } from "node:fs";

const root = new URL("../", import.meta.url);
const read = (p) => readFileSync(new URL(p, root), "utf8");
const swift = read("Nostalgex/Nostalgex/Models/GuideTextSize.swift");
const roku = read("roku/source/guide/GuideText.brs");
const html = read("plex-tuner.html");

let passed = 0;
const failures = [];
const check = (label, ok, detail = "") => { if (ok) passed += 1; else failures.push(`${label}${detail ? `: ${detail}` : ""}`); };

const metrics = (name) => {
  const m = new RegExp(`static let ${name} = GuideTextMetrics\\(([^)]*)\\)`).exec(swift);
  if (!m) throw new Error(`GuideTextSize.swift has no ${name} metrics`);
  return Object.fromEntries([...m[1].matchAll(/(\w+):\s*([\d.]+)/g)].map((x) => [x[1], Number(x[2])]));
};
const rokuSizes = (large) => {
  const body = new RegExp(`if large then\\s*return \\{([^}]*)\\}`).exec(roku);
  const other = new RegExp(`end if\\s*return \\{([^}]*)\\}`).exec(roku);
  const text = large ? (body && body[1]) : (other && other[1]);
  if (!text) throw new Error("GuideText.brs: NxGuideTextSizes not in the shape this test reads");
  return Object.fromEntries([...text.matchAll(/(\w+):\s*([\d.]+)/g)].map((x) => [x[1], Number(x[2])]));
};

const sn = metrics("normal");
const sl = metrics("large");
const rn = rokuSizes(false);
const rl = rokuSizes(true);

// Swift and Roku agree on every size the web uses.
const pairs = [
  ["title", "title", "title"], ["time", "timeLabel", "slot"], ["head", "channelHeading", "head"], ["num", "number", "num"], ["name", "name", "name"],
];
for (const [part, swiftKey, rokuKey] of pairs) {
  check(`${part}: Swift NORMAL ${sn[swiftKey]} is Roku NORMAL ${rn[rokuKey]}`, sn[swiftKey] === rn[rokuKey]);
  check(`${part}: Swift LARGE ${sl[swiftKey]} is Roku LARGE ${rl[rokuKey]}`, sl[swiftKey] === rl[rokuKey]);
}

// The page's multipliers.
const cssBlock = (selector) => {
  const at = html.indexOf(selector);
  if (at < 0) throw new Error(`plex-tuner.html has no ${selector} rule`);
  return html.slice(at, html.indexOf("}", at));
};
const vars = (block) => Object.fromEntries([...block.matchAll(/--gt-(\w+):\s*([\d.]+)/g)].map((x) => [x[1], Number(x[2])]));
const normalVars = vars(cssBlock("  .guide-grid {\n    --gt-"));
const largeVars = vars(cssBlock("  body.guide-text-large .guide-grid {\n    --gt-"));

for (const [part, swiftKey] of pairs) {
  check(`${part}: NORMAL multiplier is 1`, normalVars[part] === 1, String(normalVars[part]));
  const want = sl[swiftKey] / sn[swiftKey];
  check(`${part}: LARGE multiplier ${largeVars[part]} is Swift LARGE over NORMAL (${want.toFixed(4)})`,
    Math.abs(largeVars[part] - want) < 0.001, String(largeVars[part]));
}

// The one exception: four time columns on a phone are 72px wide, and a wider label pushes the
// header off the screen (measured 2026-11-02: 1.07 is the last size that fits at 390 wide).
const phone = /@media \(max-width: 560px\) \{\s*body\.guide-text-large \.guide-grid \{ --gt-time: ([\d.]+); \}/.exec(html);
check("phone: the time labels grow less, and by no more than 1.07", !!phone && Number(phone[1]) > 1 && Number(phone[1]) <= 1.07, phone ? phone[1] : "no phone rule");

// No guide rule carries a font size the multiplier would miss.
const guideSelectors = [".grid-channel-col", ".grid-time-slot", ".grid-ch-num", ".grid-ch-name", ".grid-program"];
let raw = [];
for (const rule of html.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
  const selectors = rule[1].split(",").map((x) => x.trim()).filter((x) => guideSelectors.includes(x));
  if (!selectors.length) continue;
  for (const decl of rule[2].matchAll(/(font-size|min-width):\s*([^;]+);/g)) {
    const value = decl[2].trim();
    if (!/var\(--gt-/.test(value)) raw.push(`${selectors.join(", ")} { ${decl[1]}: ${value} }`);
  }
}
// .grid-ch-name / .grid-program also appear in rules with other properties only; a raw
// min-width on a number box would be missed, so the list above stays empty.
check("every guide font size and number box goes through a --gt- multiplier", raw.filter((r) => r.includes("font-size") || r.includes(".grid-ch-num")).length === 0, raw.join(" | "));

// The key and what counts as LARGE.
const key = /static let storageKey = "([^"]+)"/.exec(swift)[1];
check(`the page saves under the Apple TV's key (${key})`, html.includes(`const GUIDE_TEXT_KEY = '${key}'`));
check("only exactly 'large' is LARGE, like GuideTextSize.init(stored:) and NxGuideTextFrom",
  html.includes("localStorage.getItem(GUIDE_TEXT_KEY) === 'large' ? 'large' : 'normal'")
  && /stored == GuideTextSize\.large\.rawValue \? \.large : \.normal/.test(swift)
  && /return saved = "large"/.test(roku));

if (failures.length) {
  console.error(`guide text: ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`guide text: ${passed} checks passed`);
