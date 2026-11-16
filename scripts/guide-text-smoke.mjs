#!/usr/bin/env node
/**
 * GUIDE TEXT SIZE: the web tuner's numbers are the Apple TV's and Roku's.
 *
 * There is no shared golden file for this setting (it is sizes, not schedule logic), so this
 * reads the three sources and holds them together:
 *
 *   Nostalgex/Nostalgex/Models/GuideTextSize.swift    GuideTextMetrics.small, .normal (labelled DEFAULT) and .large (LARGER)
 *   roku/source/guide/GuideText.brs                   NxGuideTextSizes(false) and (true): its text, time and numW
 *                                                             locals, and the keys the returned record builds from them
 *   plex-tuner.html                                   the --gt-* multipliers on .guide-grid
 *
 * Swift and Roku must agree with each other, and the page's multiplier for each part of the
 * guide must be the Swift LARGE size over its NORMAL size. NORMAL must be 1 everywhere, so the
 * guide draws exactly what it drew before the setting existed, and no guide rule may carry a
 * raw font size that would escape the multiplier. The storage key is the Apple TV's.
 *
 * The Apple TV has three steps (SMALLER "small", DEFAULT "normal", LARGER "large") and so has the page. SMALLER is the Apple TV's
 * ratio (0.85 and 0.8636); LARGER is no bigger than the page's LARGE always was (1.3182 and 1.16 over the page's own DEFAULT,
 * which did not come down with the Apple TV's). Roku follows; until its sizes are the Apple TV's
 * DEFAULT ones the Swift against Roku pairs below fail on purpose.
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
const ss = metrics("small");
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
// The Roku has them once it has the three steps (NxGuideTextSizesFor, roku/guide-text-three-steps). A tree that carries the Apple TV's
// 1.0.32 sizes without the Roku's (web/round3 does: the Apple TV commit is in it, the Roku's is not) would compare two releases.
const rokuHas1032Sizes = /NxGuideTextSizesFor/.test(roku);
if (swiftHas1032Sizes && rokuHas1032Sizes) {
  for (const [part, swiftKey, rokuKey] of pairs) {
    check(`${part}: Swift NORMAL ${sn[swiftKey]} is Roku NORMAL ${rn[rokuKey]}`, sn[swiftKey] === rn[rokuKey]);
    check(`${part}: Swift LARGE ${sl[swiftKey]} is Roku LARGE ${rl[rokuKey]}`, sl[swiftKey] === rl[rokuKey]);
  }
} else {
  console.log(`guide text: SKIPPED the Swift against Roku size pairs (10 checks): ${swiftHas1032Sizes ? "the Apple TV has its 1.0.32 sizes and the Roku does not yet (#296), so the two would be different releases" : "main's Swift is still the Apple TV 1.0.31's sizes and the Roku has the 1.0.32's (#296)"}. They run once both have the 1.0.32 sizes.`);
}

// The page's multipliers.
const cssBlock = (selector) => {
  const at = html.indexOf(selector);
  if (at < 0) throw new Error(`plex-tuner.html has no ${selector} rule`);
  return html.slice(at, html.indexOf("}", at));
};
const vars = (block) => Object.fromEntries([...block.matchAll(/--gt-(\w+):\s*([\d.]+)/g)].map((x) => [x[1], Number(x[2])]));
const normalVars = vars(cssBlock("  .guide-grid {\n    --gt-"));
const smallVars = vars(cssBlock("  body.guide-text-small .guide-grid {\n    --gt-"));
const largeVars = vars(cssBlock("  body.guide-text-large .guide-grid {\n    --gt-"));

// The page's DEFAULT is the size it has always drawn: the Apple TV's former NORMAL (22 pt row text, 25 pt times, heading and
// placeholder), not the Apple TV's current DEFAULT (20 and 22), which has come down. The web's absolute scale differs from the
// Apple TV's by design, and Chad's rule is that nothing gets larger ("don't make the fonts too big"), so LARGER is Swift LARGE (29)
// over THAT base: 29/22 = 1.3182 and 29/25 = 1.16, what LARGE has always been here. SMALLER is the Apple TV's own step over its
// DEFAULT (17/20, 19/22). The Roku pairs above still hold Roku to the Apple TV.
const WEB_DEFAULT_PT = { title: 22, time: 25, head: 25, num: 22, name: 22 };
for (const [part, swiftKey] of pairs) {
  check(`${part}: NORMAL multiplier is 1`, normalVars[part] === 1, String(normalVars[part]));
  const want = sl[swiftKey] / WEB_DEFAULT_PT[part];
  check(`${part}: LARGER multiplier ${largeVars[part]} is Swift LARGE over the page's DEFAULT size (${want.toFixed(4)}), no bigger than LARGE always was`,
    Math.abs(largeVars[part] - want) < 0.001, String(largeVars[part]));
  const wantSmall = ss[swiftKey] / sn[swiftKey];
  check(`${part}: SMALLER multiplier ${smallVars[part]} is Swift SMALL over NORMAL (${wantSmall.toFixed(4)})`,
    Math.abs(smallVars[part] - wantSmall) < 0.001, String(smallVars[part]));
}

// The row and the header: the same at DEFAULT and SMALLER, and grown at LARGER by the Apple TV's proportions (rowHeight 76 over 64,
// headerHeight 66 over 58 in GuideTextMetrics), so the larger text keeps the room around a line.
const heightOf = (name, key) => Number(new RegExp(`static let ${name} = GuideTextMetrics\\([^)]*${key}: ([\\d.]+)`).exec(swift)?.[1]);
const rowN = heightOf("normal", "rowHeight"), rowL = heightOf("large", "rowHeight"), rowS = heightOf("small", "rowHeight");
const headN = heightOf("normal", "headerHeight"), headL = heightOf("large", "headerHeight"), headS = heightOf("small", "headerHeight");
check("the Apple TV's row is 64 at SMALLER and DEFAULT and 76 at LARGER, the header 58 and 66", rowN === 64 && rowS === 64 && rowL === 76 && headN === 58 && headS === 58 && headL === 66, JSON.stringify({ rowN, rowS, rowL, headN, headS, headL }));
const rowVars = (block) => Object.fromEntries([...block.matchAll(/--gt-(row|header):\s*([\d.]+)/g)].map((x) => [x[1], Number(x[2])]));
const rowNormal = rowVars(cssBlock("  .guide-grid {\n    --gt-"));
const rowLarge = rowVars(cssBlock("  body.guide-text-large .guide-grid {\n    --gt-"));
const rowSmall = rowVars(cssBlock("  body.guide-text-small .guide-grid {\n    --gt-"));
check("the page's row and header multipliers are 1 at DEFAULT and SMALLER", rowNormal.row === 1 && rowNormal.header === 1 && rowSmall.row === undefined && rowSmall.header === undefined, JSON.stringify([rowNormal, rowSmall]));
check(`the page's LARGER row ${rowLarge.row} and header ${rowLarge.header} are the Apple TV's ${(rowL / rowN).toFixed(4)} and ${(headL / headN).toFixed(4)}`,
  Math.abs(rowLarge.row - rowL / rowN) < 0.001 && Math.abs(rowLarge.header - headL / headN) < 0.001, JSON.stringify(rowLarge));

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

// The key and what counts as each step.
const key = /static let storageKey = "([^"]+)"/.exec(swift)[1];
check(`the page saves under the Apple TV's key (${key})`, html.includes(`const GUIDE_TEXT_KEY = '${key}'`));
// Apple TV: three steps; "large" keeps the old LARGE's raw value, "small" is new, anything unknown is DEFAULT ("normal").
check("Apple TV: raw values small, normal, large (the middle step is labelled DEFAULT), unknown reads as normal",
  /case small\s+case normal\s+case large/.test(swift)
  && /stored\.flatMap\(GuideTextSize\.init\(rawValue:\)\) \?\? \.normal/.test(swift)
  && /case \.small: return "SMALLER"[\s\S]*case \.normal: return "DEFAULT"[\s\S]*case \.large: return "LARGER"/.test(swift));
// Roku and the page know two steps: only exactly "large" is LARGE, so the Apple TV's "small" degrades to their normal.
// The page has the three steps too: small, normal, large saved under the Apple TV's key, unknown reads as normal.
check("the page: raw values small, normal, large; unknown reads as normal (the middle step is labelled DEFAULT)",
  /saved === 'large' \|\| saved === 'small' \? saved : 'normal'/.test(html)
  && /lsSet\(GUIDE_TEXT_KEY, size === 'large' \|\| size === 'small' \? size : 'normal'\)/.test(html)
  && />SMALLER<\/button>/.test(html) && />DEFAULT<\/button>/.test(html) && />LARGER<\/button>/.test(html)
  && /classList\.toggle\('guide-text-small'/.test(html) && /classList\.toggle\('guide-text-large'/.test(html));
check("the page's SMALLER block is one place: its five multipliers are the two ratios", Object.keys(smallVars).length === 5);
// Roku knows two steps until it takes the Apple TV's: only exactly "large" is LARGE there, so the Apple TV's "small" degrades to normal.
check("Roku reads only exactly 'large' as LARGE until it has the third step",
  /return saved = "large"/.test(roku) || /small/.test(roku));

if (failures.length) {
  console.error(`guide text: ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`guide text: ${passed} checks passed`);
