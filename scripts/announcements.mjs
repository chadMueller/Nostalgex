// The announcement bar: the slim strip above the nav on the marketing pages.
//
// content/announcements.json is the one source. This module reads and validates
// it and renders the bar's markup. Two things use it:
//
//   scripts/render-announcements.mjs  writes the bar into the static pages, between
//                                     ANNOUNCE markers, and checks them in `npm test`
//   scripts/site-chrome.mjs           renderNav() puts it in front of the nav on the
//                                     generated pages (blog, channel guide)
//
// The bar's behaviour (the scrolling ticker, rotation, pause on hover, focus and
// the pause button, the close button) is in app.js, its look in styles.css under
// `.announce`. Nothing here is read by the web tuner or the Docker build.

import { readFileSync } from "node:fs";

const DATA = new URL("../content/announcements.json", import.meta.url);

// Where a visitor's closed messages are kept: a JSON array of ids. app.js and the
// small inline script below both read it, so the name lives here once.
export const DISMISS_KEY = "nostalgex-announce-v1";

const ID_RE = /^[a-z0-9][a-z0-9-]{1,48}$/;
const ISO_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2})?(?:Z|[+-]\d{2}:\d{2})$/;
const KEYS = new Set(["id", "enabled", "text", "link", "startsAt", "endsAt"]);
const MAX_TEXT = 140;
// https://... or a site path. No backslash anywhere: a browser reads "/\x" as "//x", an
// address on another site. A path may not start with "//" either.
const LINK_RE = /^(?:https:\/\/[^\s"<>\\]+|\/(?![/\\])[^\s"<>\\]*)$/;
// The house copy rules, so a message that breaks them fails the build, not review.
const FUTURE_PROMISE = /coming soon|free forever|stays? free|no ads|forever free/i;

function escapeHtml(text) {
  return String(text)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

/** Throws with a plain message when the file breaks a rule. Returns the messages. */
export function validate(data) {
  const fail = (msg) => {
    throw new Error(`content/announcements.json: ${msg}`);
  };
  if (!data || !Array.isArray(data.messages)) fail('"messages" must be an array.');
  const seen = new Set();
  for (const [i, m] of data.messages.entries()) {
    const at = `messages[${i}]${m && m.id ? ` (${m.id})` : ""}`;
    if (!m || typeof m !== "object") fail(`${at} must be an object.`);
    for (const key of Object.keys(m)) if (!KEYS.has(key)) fail(`${at} has an unknown key "${key}".`);
    if (!ID_RE.test(m.id || "")) fail(`${at}: id must be a slug (lowercase letters, digits, hyphens, 2 to 49 characters).`);
    if (seen.has(m.id)) fail(`${at}: the id is used twice.`);
    seen.add(m.id);
    if (typeof m.enabled !== "boolean") fail(`${at}: enabled must be true or false.`);
    if (typeof m.text !== "string" || !m.text.trim()) fail(`${at}: text is empty.`);
    if (m.text !== m.text.trim() || /[\r\n\t]/.test(m.text)) fail(`${at}: text has stray whitespace or a line break.`);
    if (m.text.length > MAX_TEXT) fail(`${at}: text is ${m.text.length} characters, the limit is ${MAX_TEXT}.`);
    if (/[\u2013\u2014]/.test(m.text)) fail(`${at}: text has a dash used as a stop (em or en dash). Use a full stop or a comma.`);
    if (/\p{Extended_Pictographic}/u.test(m.text)) fail(`${at}: text has an emoji.`);
    if (FUTURE_PROMISE.test(m.text)) fail(`${at}: text promises something about the future ("${m.text.match(FUTURE_PROMISE)[0]}").`);
    if (m.link !== undefined && !LINK_RE.test(m.link)) {
      fail(`${at}: link must be a https:// address or a path starting with a single /, with no backslash.`);
    }
    for (const key of ["startsAt", "endsAt"]) {
      if (m[key] !== undefined && (!ISO_RE.test(m[key]) || Number.isNaN(Date.parse(m[key])))) {
        fail(`${at}: ${key} must be ISO 8601 with an offset, like 2026-11-09T00:00:00-05:00.`);
      }
    }
    if (m.startsAt && m.endsAt && Date.parse(m.endsAt) <= Date.parse(m.startsAt)) fail(`${at}: endsAt is not after startsAt.`);
  }
  return data.messages;
}

/** The messages that are switched on. Dates are not applied here: the browser does that. */
export function loadEnabled() {
  return validate(JSON.parse(readFileSync(DATA, "utf8"))).filter((m) => m.enabled);
}

/** Enabled messages whose endsAt is already past, for a note from the check. */
export function loadEnded(now = Date.now()) {
  return loadEnabled().filter((m) => m.endsAt && Date.parse(m.endsAt) <= now);
}

// Runs right after the bar's markup, before the page paints below it. If every
// message is closed, not started or ended, the bar is hidden here so a visitor
// who closed it never sees it flash and the page jump. app.js applies the same
// rule when it takes over, and works on its own if this script never ran.
// Every storage read is wrapped, so a browser with storage off still gets a bar.
export const GUARD =
  "(function(){try{var b=document.getElementById(\"announce\"),d=[];" +
  `try{d=JSON.parse(localStorage.getItem("${DISMISS_KEY}")||"[]")}catch(e){}` +
  "if(!Array.isArray(d))d=[];" +
  "var n=Date.now(),l=0;[].forEach.call(b.querySelectorAll(\".announce-msg\"),function(m){" +
  "var s=Date.parse(m.getAttribute(\"data-starts\")),e=Date.parse(m.getAttribute(\"data-ends\"));" +
  "if(d.indexOf(m.getAttribute(\"data-id\"))<0&&!(s>n)&&!(e<=n))l++});if(!l)b.hidden=true}catch(e){}})();";

/**
 * The bar. The text of each message appears once. The first is shown, the rest
 * start hidden and app.js rotates through them. Returns "" when nothing is on,
 * so no bar and no reserved space.
 */
export function renderBar(messages = loadEnabled()) {
  if (!messages.length) return "";
  const msgs = messages
    .map((m, i) => {
      const attrs =
        `data-id="${escapeHtml(m.id)}"` +
        (m.startsAt ? ` data-starts="${escapeHtml(m.startsAt)}"` : "") +
        (m.endsAt ? ` data-ends="${escapeHtml(m.endsAt)}"` : "") +
        (i === 0 ? "" : " hidden");
      // The track is what app.js scrolls. It holds the one real copy of the text; the script adds
      // aria-hidden copies and bullets beside it, so the message is read once.
      const track = `<span class="announce-track"><span class="announce-text">${escapeHtml(m.text)}</span></span>`;
      const external = /^https:/.test(m.link || "");
      const body = m.link
        ? `<a class="announce-link" href="${escapeHtml(m.link)}"${external ? ' target="_blank" rel="noopener"' : ""}>${track}${external ? '<span class="visually-hidden"> (opens in a new tab)</span>' : ""}</a>`
        : track;
      return `      <p class="announce-msg" ${attrs}>${body}</p>`;
    })
    .join("\n");
  return [
    '<div class="announce" id="announce" role="region" aria-label="Announcement">',
    '  <div class="announce-inner">',
    '    <div class="announce-msgs">',
    msgs,
    "    </div>",
    '    <button class="announce-pause" type="button" aria-pressed="false" aria-label="Pause scrolling">',
    '      <svg class="announce-ico-pause" viewBox="0 0 24 24" aria-hidden="true" fill="currentColor"><path d="M7 5h3.5v14H7zM13.5 5H17v14h-3.5z"/></svg>',
    '      <svg class="announce-ico-play" viewBox="0 0 24 24" aria-hidden="true" fill="currentColor"><path d="M8 5l11 7-11 7z"/></svg>',
    "    </button>",
    '    <button class="announce-close" type="button" aria-label="Close announcement">',
    '      <svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"><path d="M5 5l14 14M19 5L5 19"/></svg>',
    "    </button>",
    "  </div>",
    `  <script>${GUARD}</script>`,
    "</div>",
  ].join("\n");
}
