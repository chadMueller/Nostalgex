// Smoke test for the announcement bar's validator, markup and inline guard.
//   npm run test:announcements
// No browser: the guard is run against a stub document and a stub localStorage.

import { validate, renderBar, GUARD, DISMISS_KEY } from "./announcements.mjs";

let passed = 0;
let failed = 0;
function check(ok, label) {
  if (ok) passed++;
  else {
    failed++;
    console.error(`FAIL  ${label}`);
  }
}

const base = { id: "launch-note", enabled: true, text: "Nostalgex is on the Roku Channel Store." };
const accepts = (patch) => {
  try {
    validate({ messages: [{ ...base, ...patch }] });
    return true;
  } catch {
    return false;
  }
};

// Links: https or a site path, never another site.
for (const link of ["https://my.roku.com/account/add/NOSTALGEX", "/roku", "/blog/some-post"]) {
  check(accepts({ link }), `link ${link} is allowed`);
}
for (const link of [
  "/\\evil.example", // a browser reads /\ as //, an address on another site
  "/a\\b",
  "//evil.example",
  "https://example.com\\@evil.example",
  "http://example.com",
  "javascript:alert(1)",
  "data:text/html,x",
  "roku",
  "https://a b.example",
  "/x\"onmouseover=\"y",
]) {
  check(!accepts({ link }), `link ${JSON.stringify(link)} is refused`);
}

// Text rules.
check(accepts({}), "a plain message is allowed");
check(!accepts({ text: "On the store \u2014 add it" }), "an em dash is refused");
check(!accepts({ text: "On the store \u2013 add it" }), "an en dash is refused");
check(!accepts({ text: "On the store \u{1F4FA}" }), "an emoji is refused");
check(!accepts({ text: "x".repeat(141) }), "text over 140 characters is refused");
check(accepts({ text: "x".repeat(140) }), "text of exactly 140 characters is allowed");
check(!accepts({ text: "Coming soon to Roku" }), "a coming soon promise is refused");
check(!accepts({ text: "Free forever on Roku" }), "a free forever promise is refused");
check(!accepts({ text: "" }), "empty text is refused");
check(!accepts({ text: " padded " }), "padded text is refused");

// Ids, keys, dates.
check(!accepts({ id: "X" }), "a bad id is refused");
check(!accepts({ extra: 1 }), "an unknown key is refused");
check(!accepts({ enabled: "yes" }), "enabled must be a boolean");
check(accepts({ startsAt: "2026-11-09T00:00:00-05:00", endsAt: "2026-12-07T00:00:00-05:00" }), "ISO dates with an offset are allowed");
check(!accepts({ endsAt: "2026-12-07" }), "a date without a time and offset is refused");
check(!accepts({ startsAt: "2026-12-07T00:00:00Z", endsAt: "2026-11-09T00:00:00Z" }), "an end before the start is refused");
let dup = false;
try {
  validate({ messages: [base, { ...base }] });
} catch {
  dup = true;
}
check(dup, "two messages with the same id are refused");

// Markup: the text is in the page once, and a new-tab note only on external links.
const bar = renderBar([{ ...base, link: "https://my.roku.com/account/add/NOSTALGEX" }]);
check(bar.split(base.text).length === 2, "the message text appears once in the markup");
check(bar.includes('target="_blank" rel="noopener"') && bar.includes("(opens in a new tab)"), "an external link opens in a new tab and says so");
check(!renderBar([{ ...base, link: "/roku" }]).includes("(opens in a new tab)"), "a site link has no new-tab note");
check(bar.includes('class="announce-pause"') && bar.includes('aria-pressed="false"') && bar.includes('aria-label="Pause scrolling"'), "the pause button is there, named, with a state");
check(bar.includes('class="announce-close"'), "the close button is there");
check(renderBar([]) === "", "no enabled messages renders nothing");

// The inline guard: hides the bar when nothing is live, and only trusts an array.
function runGuard({ stored, starts = null, ends = null }) {
  const bar = { hidden: false, querySelectorAll: () => [{ getAttribute: (n) => ({ "data-id": "roku-store-launch", "data-starts": starts, "data-ends": ends })[n] }] };
  const document = { getElementById: (id) => (id === "announce" ? bar : null) };
  const localStorage = { getItem: (k) => (k === DISMISS_KEY ? stored : null) };
  new Function("document", "localStorage", GUARD)(document, localStorage);
  return bar.hidden;
}
check(runGuard({ stored: null }) === false, "guard: nothing stored shows the bar");
check(runGuard({ stored: '["roku-store-launch"]' }) === true, "guard: a closed id hides the bar");
check(runGuard({ stored: '["something-else"]' }) === false, "guard: another closed id leaves the bar");
check(runGuard({ stored: '"roku-store-launch"' }) === false, "guard: a stored string is not a list, so it does not count as closed");
check(runGuard({ stored: "{\"roku-store-launch\":1}" }) === false, "guard: a stored object does not count as closed");
check(runGuard({ stored: "not json" }) === false, "guard: unreadable storage shows the bar");
check(runGuard({ stored: null, ends: "2020-01-01T00:00:00-05:00" }) === true, "guard: an ended message hides the bar");
check(runGuard({ stored: null, starts: "2999-01-01T00:00:00-05:00" }) === true, "guard: a message that has not started hides the bar");

console.log(`announcements smoke: ${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
