#!/usr/bin/env node
/**
 * The web tuner's 8-bit faces (the guide and the now-playing window): VT323 and Press Start 2P.
 *
 * Source checks (always): plex-tuner.html asks Google Fonts for both, and the hosted CSP lets that stylesheet and its font files
 * through. The guide and the window are set in them.
 * Build checks (`--builds`, after `npm run build` and `npm run build:selfhost`): the hosted page still has that request, and the
 * self-host build (the Docker image) has no request to Google at all, links its own vendor/fonts/tuner.css, and that sheet's @font-face
 * rules for the two families name font files that are all in the output.
 *
 * Run: `npm run test:arcade-fonts` (source), `npm run test:arcade-fonts:builds`.
 */
import { readFileSync, existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const BUILDS = process.argv.includes("--builds");
const root = fileURLToPath(new URL("../", import.meta.url));
const read = (rel) => readFileSync(join(root, rel), "utf8");

let pass = 0;
const failures = [];
const check = (name, ok, detail = "") => { if (ok) pass++; else failures.push(`${name}${detail ? `: ${detail}` : ""}`); };

const FAMILIES = ["VT323", "Press Start 2P"];
const page = read("plex-tuner.html");
const link = /<link href="(https:\/\/fonts\.googleapis\.com\/css2\?[^"]*)" rel="stylesheet">/.exec(page);
check("plex-tuner.html asks Google Fonts for a stylesheet", !!link);
const query = link ? decodeURIComponent(link[1]).replace(/\+/g, " ") : "";
for (const f of FAMILIES) check(`that request names ${f}`, query.includes(`family=${f}`), query);

const vercel = JSON.parse(read("vercel.json"));
const csp = JSON.stringify(vercel);
check("the hosted CSP lets the Google Fonts stylesheet through (style-src)", /style-src[^;]*https:\/\/fonts\.googleapis\.com/.test(csp));
check("and the font files (font-src)", /font-src[^;]*https:\/\/fonts\.gstatic\.com/.test(csp));

const used = (family) => (page.match(new RegExp(`font-family:\\s*'${family}'`, "g")) || []).length;
check("the guide and the window are set in VT323", used("VT323") >= 10, String(used("VT323")));
check("and Press Start 2P for the channel line, the badges and the CHANNEL heading", used("Press Start 2P") >= 3, String(used("Press Start 2P")));

if (BUILDS) {
  const hosted = existsSync(join(root, "dist/plex-tuner.html")) ? read("dist/plex-tuner.html") : null;
  check("dist/plex-tuner.html exists (run npm run build first)", !!hosted);
  if (hosted) {
    const m = /fonts\.googleapis\.com\/css2\?([^"]*)"/.exec(hosted);
    const q = m ? decodeURIComponent(m[1]).replace(/\+/g, " ") : "";
    check("dist/: the hosted page asks Google Fonts for both faces", FAMILIES.every((f) => q.includes(`family=${f}`)), q);
  }
  const dockerPage = existsSync(join(root, "dist-selfhost/plex-tuner.html")) ? read("dist-selfhost/plex-tuner.html") : null;
  check("dist-selfhost/plex-tuner.html exists (run npm run build:selfhost first)", !!dockerPage);
  if (dockerPage) {
    check("dist-selfhost/: the Docker page makes no request to Google Fonts", !/fonts\.(googleapis|gstatic)\.com/.test(dockerPage));
    const sheet = /<link[^>]*href="(\.\/)?(vendor\/fonts\/tuner\.css)"[^>]*>/.exec(dockerPage);
    check("dist-selfhost/: it links its own vendor/fonts/tuner.css", !!sheet);
    const sheetPath = join(root, "dist-selfhost/vendor/fonts/tuner.css");
    check("dist-selfhost/vendor/fonts/tuner.css exists", existsSync(sheetPath));
    if (existsSync(sheetPath)) {
      const css = readFileSync(sheetPath, "utf8");
      for (const f of FAMILIES) {
        const rules = [...css.matchAll(/@font-face\s*\{[^}]*\}/g)].map((x) => x[0]).filter((r) => r.includes(`font-family: '${f}'`) || r.includes(`font-family: "${f}"`));
        check(`the sheet has @font-face rules for ${f}`, rules.length > 0, String(rules.length));
        const files = rules.flatMap((r) => [...r.matchAll(/url\(([^)]+)\)/g)].map((x) => x[1].replace(/['"]/g, "")));
        const missing = files.filter((u) => !existsSync(resolve(dirname(sheetPath), u)));
        check(`every font file ${f} names is in the output (${files.length})`, files.length > 0 && missing.length === 0, missing.slice(0, 3).join(", "));
      }
    }
  }
}

if (failures.length) {
  console.error(`arcade fonts: ${failures.length} failed, ${pass} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`arcade fonts: ${pass} checks passed${BUILDS ? " (source and both builds)" : ""}`);
