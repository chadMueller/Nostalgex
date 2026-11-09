// Renders the generated regions of the /roku page from content/roku.json.
//
// Same arrangement as render-self-host.mjs: the data lives in content/, the page
// keeps marked regions, and this script rewrites what is between the markers in
// place. `npm run build` runs it before vite, and `npm test` runs it with
// --check, so the committed HTML and the built HTML never disagree.
//
// Three regions in roku.html:
//
//   ROKU-HERO-CTA   the hero button
//   ROKU-BETA       the whole "Join the beta" section
//   ROKU-POST       a link to the announcement post, once there is one
//
// `storeLive` is the first switch. True, the app is on the Roku Channel Store:
// the hero button is the store add link and the beta section is gone from the
// page. False, the beta page is rendered and `betaFull` decides how.
//
// `betaFull` is the switch for when Roku's 20 beta spots are taken. Open, the
// hero button and step 1 go to the Roku add link and the access code is shown.
// Full, the add link and the code come off the page and both places lead with
// the Discord. Nothing else on the page depends on it.
//
//   node scripts/render-roku.mjs            rewrite roku.html
//   node scripts/render-roku.mjs --check    fail if roku.html is out of date

import { readFile, writeFile } from "node:fs/promises";

const DATA = new URL("../content/roku.json", import.meta.url);
const PAGE = new URL("../roku.html", import.meta.url);
const CHECK = process.argv.includes("--check");

function escapeHtml(text) {
  return String(text)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function replaceBetweenMarkers(text, name, replacement) {
  const start = `<!-- ${name}:START (auto-generated) -->`;
  const end = `<!-- ${name}:END (auto-generated) -->`;
  const startIdx = text.indexOf(start);
  const endIdx = text.indexOf(end);
  if (startIdx === -1 || endIdx === -1 || endIdx < startIdx) {
    throw new Error(`roku.html: ${name} markers not found, or they are in the wrong order.`);
  }
  return text.slice(0, startIdx + start.length) + replacement + text.slice(endIdx);
}

function validate(data) {
  const fail = (msg) => {
    throw new Error(`content/roku.json: ${msg}`);
  };
  if (typeof data.storeLive !== "boolean") fail("storeLive must be true or false.");
  if (!/^[A-Z0-9]{4,20}$/.test(data.storeCode || "")) {
    fail(`storeCode "${data.storeCode}" should be the channel's 4 to 20 letters and digits.`);
  }
  if (!String(data.storeAddUrl || "").startsWith("https://my.roku.com/")) {
    fail("storeAddUrl must be a https://my.roku.com/ link.");
  }
  if (!String(data.storeAddUrl).includes(data.storeCode)) {
    fail("storeAddUrl does not contain storeCode. Did one change without the other?");
  }
  if (typeof data.betaFull !== "boolean") fail("betaFull must be true or false.");
  if (!/^[A-Z0-9]{4,20}$/.test(data.accessCode || "")) {
    fail(`accessCode "${data.accessCode}" should be Roku's 4 to 20 letters and digits.`);
  }
  if (!String(data.addUrl || "").startsWith("https://my.roku.com/")) {
    fail("addUrl must be a https://my.roku.com/ link.");
  }
  if (!String(data.addUrl).includes(data.accessCode)) {
    fail("addUrl does not contain accessCode. Did one change without the other?");
  }
  if (!String(data.discordUrl || "").startsWith("https://discord.gg/")) {
    fail("discordUrl must be a https://discord.gg/ invite.");
  }
}

const external = 'target="_blank" rel="noopener"';

// What the page says while the beta is full. The hero and the beta card both
// use it. Chad's wording (roku page handoff, section D), so keep it as written.
const BETA_FULL_LINE =
  "The beta is full right now. Join the Discord and you'll hear first when spots open or when it lands in the Roku Channel Store.";

// ── the hero button ──────────────────────────────────────────────────────────

// What sits under the store button. Marketing's words (launch copy, 1c).
const STORE_NOTE = "Opens your Roku account add page. Code NOSTALGEX.";

function renderHeroCta(data) {
  if (data.storeLive) {
    return [
      "",
      '            <div class="cta-row">',
      `              <a class="btn btn-ink btn-lg" href="${escapeHtml(data.storeAddUrl)}" ${external}>Add Nostalgex on Roku</a>`,
      "            </div>",
      `            <p class="roku-add-note">${STORE_NOTE}</p>`,
      "            ",
    ].join("\n");
  }
  if (data.betaFull) {
    return [
      "",
      `            <p class="roku-full-note">${BETA_FULL_LINE}</p>`,
      '            <div class="cta-row">',
      `              <a class="btn btn-ink btn-lg" href="${escapeHtml(data.discordUrl)}" ${external}>Join the Discord</a>`,
      "            </div>",
      "            ",
    ].join("\n");
  }
  return [
    "",
    '            <div class="cta-row">',
    `              <a class="btn btn-ink btn-lg" href="${escapeHtml(data.addUrl)}" ${external}>Join the Roku beta</a>`,
    "            </div>",
    "            ",
  ].join("\n");
}

// ── the beta card ────────────────────────────────────────────────────────────

const BETA_BODY =
  "Roku allows 20 testers per beta, so spots are limited. You'll need a Roku and your own " +
  "Plex, Jellyfin or Emby server with some movies and shows on it.";
// The has-room state keeps a hint for anyone who finds the beta full anyway.
const BETA_ROOM_NOTE = "If the beta is full, join the Discord for news on spots.";

function discordButton(data, style) {
  return `<a class="btn ${style} btn-lg" href="${escapeHtml(data.discordUrl)}" ${external}>Join the Discord</a>`;
}

// The card is wrapped in its section here, so the store page can drop the
// whole section and leave no empty band behind.
function renderBeta(data) {
  if (data.storeLive) return "\n    ";
  const section = (card) =>
    [
      "",
      '    <section class="section roku-beta" id="beta">',
      '      <div class="container container-narrow">',
      card,
      "      </div>",
      "    </section>",
      "    ",
    ].join("\n");
  return section(renderBetaCard(data));
}

function renderBetaCard(data) {
  const code = escapeHtml(data.accessCode);
  const addUrl = escapeHtml(data.addUrl);
  // A break point after each slash, so a phone wraps the link between path parts
  // instead of through the middle of the access code.
  const addLabel = escapeHtml(data.addUrl.replace(/^https:\/\//, "")).replaceAll("/", "/<wbr>");
  const discord = escapeHtml(data.discordUrl);

  if (data.betaFull) {
    return [
      '        <div class="cta-card cta-card--pink roku-beta-card is-full reveal">',
      "          <h2>Join the beta</h2>",
      `          <p class="roku-full-lead">${BETA_FULL_LINE}</p>`,
      '          <div class="cta-row roku-beta-actions">',
      `            ${discordButton(data, "btn-ink")}`,
      "          </div>",
      `          <p class="roku-beta-body">${BETA_BODY}</p>`,
      "        </div>",
    ].join("\n");
  }

  return [
    '        <div class="cta-card cta-card--yellow roku-beta-card reveal">',
    "          <h2>Join the beta</h2>",
    `          <p class="roku-beta-body">${BETA_BODY}</p>`,
    '          <ol class="quickstart-steps">',
    `            <li><span class="qs-num">1</span><p>Go to <a href="${addUrl}" ${external}>${addLabel}</a> and sign in with your Roku account. Or enter access code <code class="roku-code">${code}</code> under Add channel with a code.</p></li>`,
    '            <li><span class="qs-num">2</span><p>The Nostalgex channel shows up on your Roku within a day. Checking for system updates can bring it in sooner: <strong>Settings &gt; System &gt; Software update</strong>, or <strong>System update</strong> on older menus.</p></li>',
    `            <li><span class="qs-num">3</span><p>Tell us how it runs in our <a href="${discord}" ${external}>Discord</a>.</p></li>`,
    "          </ol>",
    '          <div class="cta-row roku-beta-actions">',
    `            ${discordButton(data, "btn-ink")}`,
    "          </div>",
    `          <p class="roku-beta-note">${BETA_ROOM_NOTE}</p>`,
    "        </div>",
  ].join("\n");
}

// ── the announcement post ────────────────────────────────────────────────────

async function renderPost(data) {
  if (!data.announcementPost) return "\n          ";
  const slug = String(data.announcementPost);
  // Loaded only when there is a post to link, so the usual render needs no blog deps.
  const { loadPosts } = await import("./build-blog.mjs");
  const posts = await loadPosts();
  const post = posts.find((p) => p.slug === slug);
  if (!post) {
    throw new Error(
      `content/roku.json: announcementPost "${slug}" is not a live post in content/blog/ ` +
        "(missing, or still draft: true).",
    );
  }
  return [
    "",
    `          <p class="roku-post-link"><a href="/blog/${escapeHtml(slug)}">${escapeHtml(post.title)}</a></p>`,
    "          ",
  ].join("\n");
}

// ── run ──────────────────────────────────────────────────────────────────────

const data = JSON.parse(await readFile(DATA, "utf8"));
validate(data);

const before = await readFile(PAGE, "utf8");
let after = before;
after = replaceBetweenMarkers(after, "ROKU-HERO-CTA", renderHeroCta(data));
after = replaceBetweenMarkers(after, "ROKU-BETA", renderBeta(data));
after = replaceBetweenMarkers(after, "ROKU-POST", await renderPost(data));

if (CHECK) {
  if (after !== before) {
    console.error("roku: roku.html is out of date with content/roku.json. Run `npm run roku:render`.");
    process.exit(1);
  }
  console.log("roku: generated regions match content/roku.json");
} else {
  if (after !== before) await writeFile(PAGE, after, "utf8");
  console.log(`roku: rendered roku.html, storeLive=${data.storeLive}, betaFull=${data.betaFull}`);
}
