#!/usr/bin/env node
/**
 * The web tuner's start screen (GitHub #254): its words are the Apple TV's and the Roku's, and the hosted page's one
 * line about the https limit is on the hosted page only.
 *
 * Source checks (always):
 *   - the headline and the one sentence on web-tuner.html are, character for character, the ones the Apple TV
 *     (SettingsView.swift) and the Roku (mediabrowser/SignInFlow.brs, NxSignInCopy) put on their first screen;
 *   - the https line sits inside a selfhost strip block: the hosted build keeps it, the self-host build (the Docker
 *     image) deletes it without a trace, and the script removes it on any http page;
 *   - none of it has an em dash;
 *   - nothing in the shared stylesheets is for the line (its styling is inline, inside the strip block), so the
 *     Docker image's CSS has no trace of it either.
 * Build checks (`--builds`, after `npm run build` and `npm run build:selfhost`): dist/ carries the line, dist-selfhost/
 * does not in any file (pages, scripts, CSS), and both carry the headline and sentence.
 *
 * Negative controls: a one-character change to the web's words, and a copy of the page with the line outside its strip
 * block, are both caught by the same checks.
 *
 * The page itself, at three sizes, is scripts/first-run-browser-smoke.mjs. Run: `npm run test:first-run`.
 */
import { readFileSync, existsSync, readdirSync, statSync } from "node:fs";
import { applySelfhostMarkers, stripMarkerLines } from "./selfhost-build.mjs";

const BUILDS = process.argv.includes("--builds");
const read = (rel) => readFileSync(new URL(`../${rel}`, import.meta.url), "utf8");

let pass = 0;
const failures = [];
function check(name, ok, detail = "") {
  if (ok) pass++;
  else failures.push(`${name}${detail ? `: ${detail}` : ""}`);
}

// ── The three first screens' words ──
const swift = read("Nostalgex/Nostalgex/Views/SettingsView.swift");
const brs = read("roku/source/mediabrowser/SignInFlow.brs");
const web = read("web-tuner.html");

const appleTitle = (/Text\("(CONNECT YOUR SERVER)"\)/.exec(swift) || [])[1];
const appleBody = (/Text\("(Nostalgex builds a retro channel guide[^"]*)"\)/.exec(swift) || [])[1];
const rokuTitle = (/screenTitle:\s*"([^"]*)"/.exec(brs) || [])[1];
const rokuBody = (/screenBody:\s*"([^"]*)"/.exec(brs) || [])[1];
const webTitleOf = (html) => (/<h1 class="connect-title">([^<]*)<\/h1>/.exec(html) || [])[1];
const webBodyOf = (html) => (/<p class="connect-lede">([^<]*)<\/p>/.exec(html) || [])[1];

check("the Apple TV's first screen has a headline and one sentence to read", !!appleTitle && !!appleBody, JSON.stringify({ appleTitle, appleBody }));
check("the Roku's first screen has a headline and one sentence to read", !!rokuTitle && !!rokuBody, JSON.stringify({ rokuTitle, rokuBody }));
check("the Apple TV and the Roku say the same thing", appleTitle === rokuTitle && appleBody === rokuBody, JSON.stringify({ appleTitle, rokuTitle, appleBody, rokuBody }));

const sameWords = (html) => webTitleOf(html) === appleTitle && webBodyOf(html) === appleBody;
check("web-tuner.html's headline is the Apple TV's, character for character", webTitleOf(web) === appleTitle, `${webTitleOf(web)} vs ${appleTitle}`);
check("web-tuner.html's sentence is the Apple TV's, character for character", webBodyOf(web) === appleBody, `${webBodyOf(web)} vs ${appleBody}`);
check("negative control: one character changed on the web is caught", !sameWords(web.replace("retro channel guide", "retro channel guidx")));
check("negative control: the old web words are caught", !sameWords(web.replace(appleTitle, "Your library as live TV.")));

// ── The https line ──
const NOTE = /<p class="signin-hint" id="picker-https-note"[^>]*>([\s\S]*?)<\/p>/;
const noteOf = (html) => NOTE.exec(html);
const textOf = (inner) => inner.replace(/<[^>]*>/g, "");
const note = noteOf(web);
check("web-tuner.html has the https line", !!note);
check("the line says what the limit is and how to get round it", !!note && /Jellyfin and Emby need an https address/.test(textOf(note[1])) && /run the tuner yourself/.test(textOf(note[1])), note ? textOf(note[1]) : "");
check("the line links to the self-host page", !!note && /<a href="\/self-host"[^>]*>run the tuner yourself<\/a>/.test(note[1]));
check("the line is there once", (web.match(/id="picker-https-note"/g) || []).length === 1);

const hosted = stripMarkerLines(web);
const docker = applySelfhostMarkers(web, "web-tuner.html");
check("the hosted build keeps the line", !!noteOf(hosted));
check("the self-host (Docker) build deletes the line", !noteOf(docker) && !/picker-https-note|signin-https-note/.test(docker));
check("the self-host build leaves no word of it behind (comment included)", !/need an https address|run the tuner yourself|plain-http server cannot be reached/.test(docker));
check("both builds keep the headline and the sentence", sameWords(hosted) && sameWords(docker));
check("the script removes the line on an http page, where any address can be reached", /const CAN_FIND = location\.protocol === 'http:';\s*[\s\S]{0,200}if \(CAN_FIND && \$\('picker-https-note'\)\) \$\('picker-https-note'\)\.remove\(\);/.test(web));

// negative control: the line outside its strip block would reach Docker.
{
  const leaky = web.replace(/[ \t]*<!-- selfhost:strip:start -->\r?\n([ \t]*<!-- The hosted page is https)/, "$1").replace(/(<p class="signin-hint" id="picker-https-note"[^\n]*\n)[ \t]*<!-- selfhost:strip:end -->\r?\n/, "$1");
  check("negative control: the line outside its strip block would reach the Docker page", leaky !== web && !!noteOf(applySelfhostMarkers(leaky, "leaky")));
}

// ── No stylesheet rule for the line: it would ship in Docker ──
for (const css of ["tuner/signin.css", "tuner/connect.css", "tuner/fonts.css"]) {
  check(`${css} has no rule for the https line`, !/https-note/.test(read(css)));
}
check("the line styles itself inline (margin, and the link's colour), inside the strip block", !!note && /style="[^"]*margin/.test(note[0]) && /<a href="\/self-host" style="[^"]*color/.test(note[1]));

// ── Words ──
const startScreen = (/<div class="connect-brand">[\s\S]*?<\/div>/.exec(web) || [""])[0] + (note ? note[0] : "");
check("no em dash on the start screen or in the line", !/[—–]/.test(startScreen));

// ── The builds ──
if (BUILDS) {
  const page = (dir, name) => (existsSync(new URL(`../${dir}/${name}`, import.meta.url)) ? read(`${dir}/${name}`) : null);
  const hostedBuilt = page("dist", "web-tuner.html");
  check("dist/web-tuner.html exists (run npm run build first)", !!hostedBuilt);
  if (hostedBuilt) {
    check("dist/: the hosted page carries the line", !!noteOf(hostedBuilt));
    check("dist/: the headline and sentence are the Apple TV's", sameWords(hostedBuilt));
  }
  // Every text file the Docker image would serve: nothing of the line, in markup, script or CSS.
  const treeRoot = new URL("../dist-selfhost/", import.meta.url);
  if (existsSync(treeRoot)) {
    const files = readdirSync(treeRoot, { recursive: true }).filter((f) => /\.(html|css|js|json|mjs|cjs)$/.test(f) && statSync(new URL(f, treeRoot)).isFile());
    const MARKERS = ["picker-https-note", "signin-https-note", "run the tuner yourself", "On this page Jellyfin and Emby need an https address"];
    const hits = [];
    for (const f of files) {
      const text = readFileSync(new URL(f, treeRoot), "utf8");
      for (const m of MARKERS) if (text.includes(m)) hits.push(`${f}: ${m}`);
    }
    check(`dist-selfhost/: none of ${files.length} pages, scripts and stylesheets has any trace of the https line`, files.length > 10 && hits.length === 0, hits.slice(0, 4).join(" | "));
    check("dist-selfhost/: that includes at least one stylesheet", files.some((f) => f.endsWith(".css")));
  }
  for (const name of ["web-tuner.html", "index.html"]) {
    const built = page("dist-selfhost", name);
    check(`dist-selfhost/${name} exists (run npm run build:selfhost first)`, !!built);
    if (!built) continue;
    check(`dist-selfhost/${name}: the Docker page does not carry the line`, !/picker-https-note|signin-https-note|need an https address, ?\s*To use any address|run the tuner yourself/.test(built));
    check(`dist-selfhost/${name}: the headline and sentence are the Apple TV's`, sameWords(built));
  }
}

if (failures.length) {
  console.error(`first-run copy: ${failures.length} failed, ${pass} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`first-run copy: ${pass} checks passed${BUILDS ? " (source and both builds)" : ""}`);
