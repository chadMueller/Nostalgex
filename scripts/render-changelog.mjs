import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";

const ROOT = new URL("..", import.meta.url);
const CHANGELOG_PATH = new URL("../content/changelog.json", import.meta.url);
const TARGETS = ["index.html"];

function escapeHtml(text) {
  return text
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function renderEntries(entries) {
  return entries
    .map((entry, idx) => {
      const isLatest = idx === 0;
      const classes = isLatest
        ? 'changelog__entry changelog__entry--latest'
        : "changelog__entry";

      const bullets = (entry.bullets ?? [])
        .map((b) => `        <li>${b}</li>`)
        .join("\n");

      return [
        `    <div class="${classes}">`,
        `      <div class="changelog__meta"><span class="changelog__version">${escapeHtml(
          entry.version,
        )}</span><span class="changelog__date">${escapeHtml(entry.date)}</span></div>`,
        `      <h3>${escapeHtml(entry.title)}</h3>`,
        "      <ul>",
        bullets,
        "      </ul>",
        "    </div>",
      ].join("\n");
    })
    .join("\n");
}

function replaceBetweenMarkers(html, replacement) {
  const start = "<!-- CHANGELOG:START (auto-generated) -->";
  const end = "<!-- CHANGELOG:END (auto-generated) -->";

  const startIdx = html.indexOf(start);
  const endIdx = html.indexOf(end);
  if (startIdx === -1 || endIdx === -1 || endIdx < startIdx) {
    throw new Error("Changelog markers not found (or misordered).");
  }

  const before = html.slice(0, startIdx + start.length);
  const after = html.slice(endIdx);
  return `${before}\n${replacement}\n    ${after}`;
}

const changelogRaw = await readFile(CHANGELOG_PATH, "utf8");
const changelog = JSON.parse(changelogRaw);
// The marketing site only ever speaks about the version people can install from the
// App Store today. A build that is on TestFlight or waiting for review carries
// `released: false` and is left out here; it still feeds the GitHub release notes and the
// Discord post, where the next version belongs in the conversation.
const entries = (Array.isArray(changelog.entries) ? changelog.entries : [])
  .filter((e) => e.released !== false);

if (entries.length === 0) {
  throw new Error("No changelog entries found in content/changelog.json");
}

const rendered = renderEntries(entries);

for (const file of TARGETS) {
  const fileUrl = new URL(`../${file}`, import.meta.url);
  const html = await readFile(fileUrl, "utf8");
  const next = replaceBetweenMarkers(html, rendered);
  if (next !== html) {
    await writeFile(fileUrl, next, "utf8");
  }
}

// eslint-disable-next-line no-console
console.log(
  `Rendered ${entries.length} changelog entries into ${TARGETS.join(", ")}`,
);

