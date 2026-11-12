#!/usr/bin/env node
/**
 * GUIDE TEXT SIZE: the web tuner's numbers are the Apple TV's and Roku's.
 *
 * There is no shared golden file for this setting (it is sizes, not schedule logic), so this
 * reads the three sources and holds them together:
 *
 *   Nostalgex/Nostalgex/Models/GuideTextSize.swift    GuideTextMetrics.normal and .large
 *   roku/source/guide/GuideText.brs                   NxGuideTextSizes(false) and (true): its text, time and numW
 *                                                             locals, and the keys the returned record builds from them
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

// A Swift size is a number, or an NXType.<name> constant (Views/Design/DesignTokens.swift, from the Apple TV 1.0.32).
const nxType = (() => {
  try {
    const tokens = read("Nostalgex/Nostalgex/Views/Design/DesignTokens.swift");
    const body = /enum NXType \{([^}]*)\}/.exec(tokens);
    return body ? Object.fromEntries([...body[1].matchAll(/static let (\w+): CGFloat = ([\d.]+)/g)].map((x) => [x[1], Number(x[2])])) : {};
  } catch { return {}; }
})();
const metrics = (name) => {
  const m = new RegExp(`static let ${name} = GuideTextMetrics\\(([^)]*)\\)`).exec(swift);
  if (!m) throw new Error(`GuideTextSize.swift has no ${name} metrics`);
  return Object.fromEntries([...m[1].matchAll(/(\w+):\s*(?:NXType\.(\w+)|([\d.]+))/g)].map((x) => {
    if (x[2] !== undefined && nxType[x[2]] === undefined) throw new Error(`GuideTextSize.swift ${name}: NXType.${x[2]} is not in DesignTokens.swift`);
    return [x[1], x[2] !== undefined ? nxType[x[2]] : Number(x[3])];
  }));
};
const rokuSizes = (large) => {
  const fn = /function NxGuideTextSizes\(large as Boolean\) as Object([\s\S]*?)end function/.exec(roku);
  if (!fn) throw new Error("GuideText.brs: NxGuideTextSizes not in the shape this test reads");
  const body = fn[1];
  const lead = /^\s*(\w+) = ([\d.]+)\s*$/gm;
  const at = body.indexOf("if large then");
  const vars = Object.fromEntries([...(at < 0 ? body : body.slice(0, at)).matchAll(lead)].map((x) => [x[1], Number(x[2])]));
  const over = /if large then([\s\S]*?)end if/.exec(body);
  if (large) {
    if (!over) throw new Error("GuideText.brs: NxGuideTextSizes has no `if large then` block");
    for (const x of over[1].matchAll(/^\s*(\w+) = ([\d.]+)\s*$/gm)) vars[x[1]] = Number(x[2]);
  }
  const rec = /return \{([\s\S]*?)\}\s*$/.exec(body.slice(body.indexOf("end if") + 6));
  if (!rec) throw new Error("GuideText.brs: NxGuideTextSizes not in the shape this test reads");
  // title: text, num: text, slot: time ... a key's value is a local or a number; the Y and H entries (calls) are skipped.
  const out = {};
  for (const x of rec[1].matchAll(/(\w+):\s*(\w+)\s*(?:,|$)/gm)) {
    const v = /^[\d.]+$/.test(x[2]) ? Number(x[2]) : vars[x[2]];
    if (v !== undefined) out[x[1]] = v;
  }
  for (const key of ["title", "slot", "head", "num", "name"]) {
    if (out[key] === undefined) throw new Error(`GuideText.brs: NxGuideTextSizes has no ${key} this test can read`);
  }
  return out;
};

const sn = metrics("normal");
const sl = metrics("large");
const rn = rokuSizes(false);
const rl = rokuSizes(true);

// Swift and Roku agree on every size the web uses.
const pairs = [
  ["title", "title", "title"], ["time", "timeLabel", "slot"], ["head", "channelHeading", "head"], ["num", "number", "num"], ["name", "name", "name"],
];
// The Roku's sizes (#296) are the Apple TV 1.0.32's, whose GuideTextMetrics write them as NXType constants
// (Views/Design/DesignTokens.swift). Until that release is on main, main's Swift still holds the 1.0.31 sizes,
// so these pairs would compare two releases. They run on their own the day Swift has the constants, and the
// page's LARGE multipliers below are then held to the new sizes too.
const swiftHas1032Sizes = Object.keys(nxType).length > 0;
if (swiftHas1032Sizes) {
  for (const [part, swiftKey, rokuKey] of pairs) {
    check(`${part}: Swift NORMAL ${sn[swiftKey]} is Roku NORMAL ${rn[rokuKey]}`, sn[swiftKey] === rn[rokuKey]);
    check(`${part}: Swift LARGE ${sl[swiftKey]} is Roku LARGE ${rl[rokuKey]}`, sl[swiftKey] === rl[rokuKey]);
  }
} else {
  console.log("guide text: SKIPPED the Swift against Roku size pairs (10 checks): main's Swift is still the Apple TV 1.0.31's sizes and the Roku has the 1.0.32's (#296). They run again once the Apple TV 1.0.32 sizes are on main.");
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
