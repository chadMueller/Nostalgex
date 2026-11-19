// Renders the generated regions of the /self-host page from content/self-host.json.
//
// Same arrangement as render-changelog.mjs: the data lives in content/, the page
// keeps marked regions, and this script rewrites what is between the markers in
// place. `npm run build` runs it before vite, so the committed HTML and the built
// HTML never disagree.
//
// Three files, one source:
//
//   self-host.html      the device table, the robots meta, the pre-launch note, and the
//                       web tuner and Docker release notes (from content/tuner-releases.json)
//   public/sitemap.xml  the /self-host entry
//   public/llms.txt     the /self-host line under "Get it"
//
// `published: false` in the data file keeps the page out of search, out of the
// sitemap and out of llms.txt, and puts a short note at the top saying the image
// is not on GHCR yet. Flipping it to true and running the build publishes the
// page. That is the whole switch.
//
//   node scripts/render-self-host.mjs            rewrite the files
//   node scripts/render-self-host.mjs --check    fail if they are out of date

import { readFile, writeFile } from "node:fs/promises";

const DATA = new URL("../content/self-host.json", import.meta.url);
const RELEASES = new URL("../content/tuner-releases.json", import.meta.url);
const PAGE = new URL("../self-host.html", import.meta.url);
const SITEMAP = new URL("../public/sitemap.xml", import.meta.url);
const LLMS = new URL("../public/llms.txt", import.meta.url);

const PAGE_URL = "https://www.nostalgex.app/self-host";
const CHECK = process.argv.includes("--check");

const STATES = new Set(["ok", "unconfirmed", "unknown", "na"]);

function escapeHtml(text) {
  return String(text)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function replaceBetweenMarkers(text, name, replacement, file) {
  const start = `<!-- ${name}:START (auto-generated) -->`;
  const end = `<!-- ${name}:END (auto-generated) -->`;
  const startIdx = text.indexOf(start);
  const endIdx = text.indexOf(end);
  if (startIdx === -1 || endIdx === -1 || endIdx < startIdx) {
    throw new Error(`${file}: ${name} markers not found, or they are in the wrong order.`);
  }
  return text.slice(0, startIdx + start.length) + replacement + text.slice(endIdx);
}

// ── the device table ─────────────────────────────────────────────────────────

function renderDevices(data) {
  const rows = data.devices
    .map((d) => {
      if (!STATES.has(d.state)) {
        throw new Error(
          `content/self-host.json: "${d.surface}" has state "${d.state}". ` +
            `Use one of: ${[...STATES].join(", ")}.`,
        );
      }
      const detail = d.detail ? `<span class="sh-device-detail">${escapeHtml(d.detail)}</span>` : "";
      return [
        "            <tr>",
        `              <th scope="row">${escapeHtml(d.surface)}${detail}</th>`,
        `              <td data-label="Status"><span class="sh-pill sh-pill--${d.state}">${escapeHtml(d.status)}</span></td>`,
        `              <td data-label="What that means">${escapeHtml(d.note)}</td>`,
        "            </tr>",
      ].join("\n");
    })
    .join("\n");

  return [
    "",
    '        <div class="sh-table-wrap">',
    '          <table class="sh-table">',
    "            <thead>",
    "              <tr>",
    '                <th scope="col">Where</th>',
    '                <th scope="col">Status</th>',
    '                <th scope="col">What that means</th>',
    "              </tr>",
    "            </thead>",
    "            <tbody>",
    rows,
    "            </tbody>",
    "          </table>",
    "        </div>",
    `        <p class="sh-table-stamp">Last updated ${escapeHtml(data.devicesUpdated)}. ` +
      'Anything not listed here has not been tried. Tell me what you ran it on and this table gets another row.</p>',
    "        ",
  ].join("\n");
}

// ── robots, and the note that comes off at launch ────────────────────────────

function renderRobots(data) {
  const value = data.published ? "index, follow" : "noindex, follow";
  return `\n<meta name="robots" content="${value}">\n`;
}

function renderPreviewNote(data) {
  if (data.published) return "\n        ";
  return [
    "",
    '        <div class="doc-note">',
    "          <p><strong>Not published yet.</strong> The image is built and running, but it is not on",
    "          GitHub Container Registry yet, so the <code>docker pull</code> below will not find it today.",
    "          This page is here so it is ready the day it goes up. Watch",
    '          <a href="https://github.com/chadMueller/Nostalgex/releases" target="_blank" rel="noopener">releases</a>',
    '          or the <a href="https://discord.gg/FgnZcr5bDT" target="_blank" rel="noopener">Discord</a>.</p>',
    "        </div>",
    "        ",
  ].join("\n");
}

// ── release notes (web tuner and Docker are one product) ──────────────────────

function renderReleases(releases) {
  const list = (items) =>
    ["            <ul>", ...items.map((i) => `              <li>${escapeHtml(i)}</li>`), "            </ul>"].join("\n");
  const entries = releases.entries.map((e) => {
    const sections = [
      ["New channels", e.newChannels],
      ["Fixes", e.fixes],
    ].filter(([, items]) => Array.isArray(items) && items.length > 0);
    return [
      '          <div class="sh-release">',
      `            <p class="sh-release-meta"><strong>${escapeHtml(e.version)}</strong> ${escapeHtml(e.date)}</p>`,
      `            <h3>${escapeHtml(e.title)}</h3>`,
      list(e.bullets),
      ...sections.flatMap(([label, items]) => [`            <h4>${label}</h4>`, list(items)]),
      "          </div>",
    ].join("\n");
  });
  return ["", ...entries, "        "].join("\n");
}

// ── sitemap and llms.txt ─────────────────────────────────────────────────────

function renderSitemap(data) {
  if (!data.published) return "\n";
  return `\n  <url><loc>${PAGE_URL}</loc><lastmod>${data.devicesUpdated}</lastmod></url>\n`;
}

// llms.txt is served as text/plain, so marker comments would be visible to anyone
// reading it. Anchor on the web tuner line instead: drop any existing /self-host
// line, then add one back after the anchor when the page is published.
const LLMS_ANCHOR = "- [Web tuner](https://www.nostalgex.app/web-tuner)";
const LLMS_LINE =
  `- [Self-host the web tuner](${PAGE_URL}): the same tuner as a Docker container on ` +
  "your own machine, over plain http on your network, so a Jellyfin or Emby server with " +
  "no https address is reachable from a browser";

function applyLlms(text, data) {
  const lines = text.split("\n").filter((l) => !l.startsWith(`- [Self-host the web tuner](${PAGE_URL})`));
  if (!data.published) return lines.join("\n");
  const at = lines.findIndex((l) => l.startsWith(LLMS_ANCHOR));
  if (at === -1) throw new Error(`public/llms.txt: the web tuner line is gone, so there is nothing to anchor to.`);
  lines.splice(at + 1, 0, LLMS_LINE);
  return lines.join("\n");
}

// ── run ──────────────────────────────────────────────────────────────────────

const data = JSON.parse(await readFile(DATA, "utf8"));
if (!Array.isArray(data.devices) || data.devices.length === 0) {
  throw new Error("content/self-host.json: devices is empty.");
}

const releases = JSON.parse(await readFile(RELEASES, "utf8"));
if (!Array.isArray(releases.entries) || releases.entries.length === 0) {
  throw new Error("content/tuner-releases.json: entries is empty.");
}

const jobs = [
  {
    file: PAGE,
    name: "self-host.html",
    regions: [
      ["ROBOTS", renderRobots(data)],
      ["PREVIEW-NOTE", renderPreviewNote(data)],
      ["DEVICES", renderDevices(data)],
      ["TUNER-RELEASES", renderReleases(releases)],
    ],
  },
  { file: SITEMAP, name: "public/sitemap.xml", regions: [["SELFHOST", renderSitemap(data)]] },
  { file: LLMS, name: "public/llms.txt", regions: [], rewrite: (t) => applyLlms(t, data) },
];

const stale = [];
for (const job of jobs) {
  const before = await readFile(job.file, "utf8");
  let after = before;
  for (const [name, replacement] of job.regions) {
    after = replaceBetweenMarkers(after, name, replacement, job.name);
  }
  if (job.rewrite) after = job.rewrite(after);
  if (after === before) continue;
  if (CHECK) stale.push(job.name);
  else await writeFile(job.file, after, "utf8");
}

if (CHECK && stale.length) {
  console.error(
    `self-host: ${stale.join(", ")} out of date with content/self-host.json. ` +
      "Run `npm run selfhost:render`.",
  );
  process.exit(1);
}

console.log(
  CHECK
    ? "self-host: generated regions match content/self-host.json"
    : `self-host: rendered ${data.devices.length} device rows, published=${data.published}`,
);
