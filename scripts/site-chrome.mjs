// Shared site chrome for the generated pages.
//
// The blog (scripts/build-blog.mjs) and the channel guide
// (scripts/build-bundles.mjs) both render full HTML documents outside Vite's
// rollupOptions.input list, so they have to produce the site's head, nav and
// footer themselves. That markup used to live as a private copy inside
// build-blog.mjs, and the blog header drifted away from the global one once
// already. One module, imported by both generators, is the fix: a change to
// the nav or the footer lands on every generated page at once.
//
// Nothing here reads content. It is markup, the shared JSON-LD identity nodes,
// and the helper that finds Vite's hashed asset filenames in dist/.

import { readFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import path from "node:path";

import { renderBar } from "./announcements.mjs";

export const SITE_ORIGIN = "https://www.nostalgex.app";
export const DEFAULT_OG_IMAGE = `${SITE_ORIGIN}/og-image-1200.png`;
export const DEFAULT_OG_ALT =
  "The Nostalgex channel guide: a grid of live channels built from your own library";
export const APPLE_TV_URL = "https://apps.apple.com/app/nostalgex/id6762563534";

// Shared JSON-LD nodes. The @id values match the ones on the static pages
// (index.html etc.), so search engines join the blog to the same app, person
// and organization.
export const ORG_ID = `${SITE_ORIGIN}/#org`;
export const APP_ID = `${SITE_ORIGIN}/#app`;
export const AUTHOR_ID = `${SITE_ORIGIN}/#chad`;
export const AUTHOR_NODE = {
  "@type": "Person",
  "@id": AUTHOR_ID,
  name: "Chad Mueller",
  url: "https://github.com/chadMueller",
  worksFor: { "@id": ORG_ID },
};
export const ORG_NODE = {
  "@type": "Organization",
  "@id": ORG_ID,
  name: "Muell Haus Inc.",
  url: "https://www.muellhaus.com/",
  logo: `${SITE_ORIGIN}/logo/nostalgex-512.png`,
};

export function escapeHtml(text) {
  return String(text)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

export function escapeAttr(text) {
  return escapeHtml(text);
}

// The announcement bar (content/announcements.json) sits in front of the nav, so
// every generated page gets it from here. The static pages carry the same markup
// in an ANNOUNCE region that scripts/render-announcements.mjs keeps current.
export function renderNav() {
  const bar = renderBar();
  const announce = bar ? `\n  ${bar.split("\n").join("\n  ")}\n` : "";
  return `${announce}
  <header class="nav" id="nav">
    <div class="nav-inner">
      <a class="brand" href="/" aria-label="Nostalgex, home">
        <span class="brand-word" role="img" aria-label="Nostalgex">N<svg class="brand-o" viewBox="0 0 126 111" aria-hidden="true"><defs><linearGradient id="brandSun" x1="0" y1="0" x2="1" y2="0.35"><stop offset="0.05" stop-color="#f838ac"/><stop offset="0.5" stop-color="#ff8a3d"/><stop offset="0.95" stop-color="#ffd91c"/></linearGradient></defs><rect x="6" y="6" width="114" height="99" rx="30" fill="url(#brandSun)" stroke="currentColor" stroke-width="11"/><path d="M12 43 H114" stroke="currentColor" stroke-width="4" stroke-linecap="round" opacity="0.55"/><path d="M12 70 H114" stroke="currentColor" stroke-width="4" stroke-linecap="round" opacity="0.55"/></svg>STALGEX</span>
      </a>
      <nav class="nav-links" aria-label="Main">
        <a href="/#how">How it works</a>
        <a href="/#guide">The guide</a>
        <a href="/#lineup">Lineup</a>
        <a href="/#top" data-changelog-home>What's new</a>
      </nav>
      <div class="nav-actions">
        <a class="btn btn-outline btn-sm btn-icon" href="/web-tuner" aria-label="Web app" title="Web app">
          <svg viewBox="0 0 24 24" aria-hidden="true" fill="currentColor"><path d="M8 5v14l11-7z"/></svg>
          <span class="btn-icon-text">Web app</span>
        </a>
        <a class="btn btn-ink btn-sm btn-icon" href="${APPLE_TV_URL}" target="_blank" rel="noopener" aria-label="Get the tvOS app" title="Get the tvOS app">
          <svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="2.5" y="7.5" width="19" height="13" rx="2.5"/><path d="M8 3.5l4 4 4-4"/></svg>
          <span class="btn-icon-text">Get the tvOS app</span>
        </a>
        <div class="nav-social" aria-label="Nostalgex elsewhere">
          <a class="social-icon" href="https://github.com/chadMueller/Nostalgex" target="_blank" rel="noopener" aria-label="GitHub" title="GitHub">
            <svg viewBox="0 0 16 16" aria-hidden="true" fill="currentColor"><path fill-rule="evenodd" clip-rule="evenodd" d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.01 8.01 0 0 0 16 8c0-4.42-3.58-8-8-8z"/></svg>
          </a>
          <a class="social-icon" href="https://discord.gg/FgnZcr5bDT" target="_blank" rel="noopener" aria-label="Discord" title="Discord">
            <svg viewBox="0 0 24 24" aria-hidden="true" fill="currentColor"><path d="M20.317 4.37a19.79 19.79 0 0 0-4.885-1.515.07.07 0 0 0-.075.035c-.21.375-.444.864-.608 1.25a18.27 18.27 0 0 0-5.487 0 12.64 12.64 0 0 0-.617-1.25.077.077 0 0 0-.079-.035A19.736 19.736 0 0 0 3.68 4.37a.07.07 0 0 0-.032.027C.533 9.046-.32 13.58.099 18.058a.082.082 0 0 0 .031.056 19.9 19.9 0 0 0 5.993 3.03.078.078 0 0 0 .084-.028c.462-.63.874-1.295 1.226-1.994a.076.076 0 0 0-.041-.106 13.1 13.1 0 0 1-1.872-.892.077.077 0 0 1-.008-.128c.126-.094.252-.192.372-.291a.074.074 0 0 1 .077-.01c3.927 1.793 8.18 1.793 12.061 0a.073.073 0 0 1 .078.01c.12.099.246.198.373.292a.077.077 0 0 1-.006.127c-.598.35-1.22.645-1.873.893a.076.076 0 0 0-.04.106c.36.698.772 1.362 1.225 1.993a.076.076 0 0 0 .084.029 19.84 19.84 0 0 0 6.002-3.03.077.077 0 0 0 .032-.055c.5-5.177-.838-9.673-3.549-13.662a.06.06 0 0 0-.031-.028zM8.02 15.33c-1.183 0-2.157-1.085-2.157-2.419 0-1.333.955-2.418 2.157-2.418 1.21 0 2.176 1.094 2.157 2.418 0 1.334-.955 2.419-2.157 2.419zm7.975 0c-1.183 0-2.157-1.085-2.157-2.419 0-1.333.955-2.418 2.157-2.418 1.21 0 2.176 1.094 2.157 2.418 0 1.334-.946 2.419-2.157 2.419z"/></svg>
          </a>
          <a class="social-icon" href="https://instagram.com/nostalgex_" target="_blank" rel="noopener" aria-label="Instagram" title="Instagram">
            <svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="1.8"><rect x="3" y="3" width="18" height="18" rx="5"/><circle cx="12" cy="12" r="4.2"/><circle cx="17.3" cy="6.7" r="0.9" fill="currentColor" stroke="none"/></svg>
          </a>
          <a class="social-icon" href="https://buymeacoffee.com/chadmueller" target="_blank" rel="noopener" aria-label="Buy me a coffee" title="Buy me a coffee">
            <svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M4 8h12v5a4 4 0 0 1-4 4H8a4 4 0 0 1-4-4V8z"/><path d="M16 9h2a2 2 0 0 1 0 4h-2"/><path d="M7 3v2M11 3v2"/></svg>
          </a>
        </div>
        <button class="theme-toggle" id="themeToggle" type="button" aria-pressed="true" aria-label="Switch to day mode" title="Switch to day mode">
          <svg class="tt-icon tt-sun" viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round">
            <circle cx="12" cy="12" r="4.2"/>
            <path d="M12 2.5v2.2M12 19.3v2.2M4.2 4.2l1.6 1.6M18.2 18.2l1.6 1.6M2.5 12h2.2M19.3 12h2.2M4.2 19.8l1.6-1.6M18.2 5.8l1.6-1.6"/>
          </svg>
          <svg class="tt-icon tt-moon" viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            <path d="M20 14.5A8.2 8.2 0 0 1 9.5 4a8.3 8.3 0 1 0 10.5 10.5z"/>
          </svg>
        </button>
        <button class="nav-toggle" id="navToggle" type="button" aria-expanded="false" aria-controls="mobileMenu" aria-label="Open menu">
          <svg class="nt-icon nt-burger" viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M3 6h18M3 12h18M3 18h18"/></svg>
          <svg class="nt-icon nt-close" viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M5 5l14 14M19 5L5 19"/></svg>
        </button>
      </div>
    </div>
  <div class="mobile-menu" id="mobileMenu">
    <nav class="mobile-menu-links" aria-label="Mobile">
      <a href="/#how">How it works</a>
      <a href="/#guide">The guide</a>
      <a href="/#lineup">Lineup</a>
      <a href="/#top" data-changelog-home>What's new</a>
    </nav>
    <div class="mobile-menu-social" aria-label="Nostalgex elsewhere">
      <a class="social-icon" href="https://github.com/chadMueller/Nostalgex" target="_blank" rel="noopener" aria-label="GitHub" title="GitHub">
        <svg viewBox="0 0 16 16" aria-hidden="true" fill="currentColor"><path fill-rule="evenodd" clip-rule="evenodd" d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.01 8.01 0 0 0 16 8c0-4.42-3.58-8-8-8z"/></svg>
      </a>
      <a class="social-icon" href="https://discord.gg/FgnZcr5bDT" target="_blank" rel="noopener" aria-label="Discord" title="Discord">
        <svg viewBox="0 0 24 24" aria-hidden="true" fill="currentColor"><path d="M20.317 4.37a19.79 19.79 0 0 0-4.885-1.515.07.07 0 0 0-.075.035c-.21.375-.444.864-.608 1.25a18.27 18.27 0 0 0-5.487 0 12.64 12.64 0 0 0-.617-1.25.077.077 0 0 0-.079-.035A19.736 19.736 0 0 0 3.68 4.37a.07.07 0 0 0-.032.027C.533 9.046-.32 13.58.099 18.058a.082.082 0 0 0 .031.056 19.9 19.9 0 0 0 5.993 3.03.078.078 0 0 0 .084-.028c.462-.63.874-1.295 1.226-1.994a.076.076 0 0 0-.041-.106 13.1 13.1 0 0 1-1.872-.892.077.077 0 0 1-.008-.128c.126-.094.252-.192.372-.291a.074.074 0 0 1 .077-.01c3.927 1.793 8.18 1.793 12.061 0a.073.073 0 0 1 .078.01c.12.099.246.198.373.292a.077.077 0 0 1-.006.127c-.598.35-1.22.645-1.873.893a.076.076 0 0 0-.04.106c.36.698.772 1.362 1.225 1.993a.076.076 0 0 0 .084.029 19.84 19.84 0 0 0 6.002-3.03.077.077 0 0 0 .032-.055c.5-5.177-.838-9.673-3.549-13.662a.06.06 0 0 0-.031-.028zM8.02 15.33c-1.183 0-2.157-1.085-2.157-2.419 0-1.333.955-2.418 2.157-2.418 1.21 0 2.176 1.094 2.157 2.418 0 1.334-.955 2.419-2.157 2.419zm7.975 0c-1.183 0-2.157-1.085-2.157-2.419 0-1.333.955-2.418 2.157-2.418 1.21 0 2.176 1.094 2.157 2.418 0 1.334-.946 2.419-2.157 2.419z"/></svg>
      </a>
      <a class="social-icon" href="https://instagram.com/nostalgex_" target="_blank" rel="noopener" aria-label="Instagram" title="Instagram">
        <svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="1.8"><rect x="3" y="3" width="18" height="18" rx="5"/><circle cx="12" cy="12" r="4.2"/><circle cx="17.3" cy="6.7" r="0.9" fill="currentColor" stroke="none"/></svg>
      </a>
      <a class="social-icon" href="https://buymeacoffee.com/chadmueller" target="_blank" rel="noopener" aria-label="Buy me a coffee" title="Buy me a coffee">
        <svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M4 8h12v5a4 4 0 0 1-4 4H8a4 4 0 0 1-4-4V8z"/><path d="M16 9h2a2 2 0 0 1 0 4h-2"/><path d="M7 3v2M11 3v2"/></svg>
      </a>
    </div>
  </div>
  </header>`;
}

// The footer is shared by every generated page. `includeEmby` exists for the
// channel guide only: those pages are not allowed to say Emby anywhere (a
// build check in build-bundles.mjs enforces it), so they drop the /emby link
// and the server list in the affiliation note. The live /emby page and the
// blog footer are unchanged.
export function renderFooter({ includeEmby = true } = {}) {
  const embyLink = includeEmby
    ? `
        <a href="/emby">Emby</a>`
    : "";
  const notAffiliated = includeEmby
    ? "Not affiliated with Plex, Jellyfin, Emby, or Apple. Apple, the Apple logo, Apple TV and App Store are trademarks of Apple Inc., registered in the U.S. and other countries."
    : "Not affiliated with Plex, Jellyfin, or Apple. Apple, the Apple logo, Apple TV and App Store are trademarks of Apple Inc., registered in the U.S. and other countries.";
  return `
  <footer class="footer">
    <div class="container footer-inner">
      <div class="footer-brand">
        <img src="/logo/nostalgex-black.svg" alt="Nostalgex" width="545" height="72" class="footer-logo footer-logo-day" loading="lazy">
        <img src="/logo/nostalgex-white.svg" alt="Nostalgex" width="545" height="72" class="footer-logo footer-logo-nite" loading="lazy">
        <p>Retro cable TV for your own library.</p>
      </div>
      <nav class="footer-links" aria-label="Footer">
        <a href="/apple-tv">Apple TV</a>
        <a href="/roku">Roku</a>
        <a href="/web-tuner">Web tuner</a>
        <a href="/plex">Plex</a>
        <a href="/jellyfin">Jellyfin</a>${embyLink}
        <a href="/channels">Channel Guide</a>
        <a href="/blog">Blog</a>
        <a href="/support">Support</a>
        <a href="/privacy">Privacy</a>
        <a href="/terms">Terms</a>
        <a href="/#faq">FAQ</a>
        <a href="/#top">What's new</a>
        <a href="https://buymeacoffee.com/chadmueller" target="_blank" rel="noopener">Buy me a coffee</a>
      </nav>
      <div class="footer-signup">
        <p class="footer-signup-label">Update emails, when there's something to say</p>
        <form class="subscribe-form js-subscribe-form" novalidate>
          <label class="visually-hidden" for="footerEmail">Email address</label>
          <input class="subscribe-input" id="footerEmail" type="email" name="email" placeholder="you@somewhere.tv" autocomplete="email" maxlength="254" required>
          <button class="btn btn-ink btn-sm subscribe-btn" type="submit">Sign up</button>
        </form>
        <p class="subscribe-msg" role="status" aria-live="polite"></p>
      </div>
      <p class="footer-note">${notAffiliated}</p>
    </div>
  </footer>`;
}

export function renderThemeBoot() {
  return `
<script>
  (function () {
    var DEFAULT_THEME = "dark";
    var theme = null;
    try { theme = localStorage.getItem("nostalgex-theme-v2"); } catch (e) {}
    var q = /[?&]theme=(dark|light)/.exec(location.search);
    if (q) theme = q[1];
    if (theme !== "dark" && theme !== "light") theme = DEFAULT_THEME;
    document.documentElement.setAttribute("data-theme", theme);
  })();
</script>`;
}

export function renderHead({
  title,
  description,
  canonical,
  ogImage,
  ogType,
  ogImageAlt = DEFAULT_OG_ALT,
  // Facebook, LinkedIn and Slack lay the card out before the image arrives, so
  // every og:image states its size, not just the shared default.
  ogImageWidth = null,
  ogImageHeight = null,
  jsonLd,
  // Pages held back from search pass "noindex, follow": the channel guide
  // builds bundle pages that are waiting on a legal answer, and they should
  // still pass their link equity on while they stay out of the index.
  robots = "index, follow",
  extraMeta = "",
  stylesHref = "/styles.css",
  appScriptHref = "/app.js",
}) {
  const scripts = [
    renderThemeBoot(),
    `<link rel="preconnect" href="https://fonts.googleapis.com">`,
    `<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>`,
    `<link href="https://fonts.googleapis.com/css2?family=Bricolage+Grotesque:opsz,wght@12..96,400;12..96,500;12..96,600;12..96,800&family=Space+Mono:wght@400;700&display=swap" rel="stylesheet">`,
    `<link rel="stylesheet" href="${escapeAttr(stylesHref)}">`,
    `<script>
  /* Analytics loads after the page has, so a slow third party never holds up the load event. */
  window.addEventListener("load", function () {
    var s = document.createElement("script");
    s.src = "https://statsngraphs.lol/s.js";
    s.async = true;
    s.setAttribute("data-site", "nostalgex");
    document.head.appendChild(s);
  });
</script>`,
  ].join("\n");

  // jsonLd may be a single object or an array; emit one script tag per entry.
  // Pages pass one @graph object today, so each page carries one block.
  const jsonLdBlocks = (Array.isArray(jsonLd) ? jsonLd : [jsonLd])
    .filter(Boolean)
    .map(
      (block) =>
        `<script type="application/ld+json">\n${JSON.stringify(block, null, 2)}\n</script>`,
    )
    .join("\n");

  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>${escapeHtml(title)}</title>
<meta name="description" content="${escapeAttr(description)}">
<meta name="robots" content="${escapeAttr(robots)}">
<link rel="canonical" href="${escapeAttr(canonical)}">
<link rel="icon" type="image/png" sizes="48x48" href="/logo/favicon-48.png">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">

<meta property="og:title" content="${escapeAttr(title)}">
<meta property="og:description" content="${escapeAttr(description)}">
<meta property="og:type" content="${escapeAttr(ogType)}">
<meta property="og:url" content="${escapeAttr(canonical)}">
<meta property="og:site_name" content="Nostalgex">
<meta property="og:image" content="${escapeAttr(ogImage)}">
${ogImage === DEFAULT_OG_IMAGE ? `<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
` : ogImageWidth && ogImageHeight ? `<meta property="og:image:width" content="${ogImageWidth}">
<meta property="og:image:height" content="${ogImageHeight}">
` : ""}<meta property="og:image:alt" content="${escapeAttr(ogImageAlt)}">

<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="${escapeAttr(title)}">
<meta name="twitter:description" content="${escapeAttr(description)}">
<meta name="twitter:image" content="${escapeAttr(ogImage)}">
${extraMeta}
${scripts}
${jsonLdBlocks}
</head>`;
}

// The generated pages (blog, channel guide) aren't Vite inputs, so they need the
// hashed filenames of the site's one stylesheet and one script. Vite names those
// chunks after whatever happens to import them first (app-<hash>.css while every
// page loaded app.js, styles-<hash>.css once one page did not), so guessing from
// the name is fragile. Take them from the built home page instead, which links
// both, and fail the build if either is missing rather than falling back to a
// /styles.css or /app.js that dist doesn't have.
export async function resolveViteAssetHrefs(distDir) {
  const indexPath = path.join(distDir, "index.html");
  if (!existsSync(indexPath)) {
    throw new Error(`resolveViteAssetHrefs: ${indexPath} is missing, so the site's built stylesheet can't be found.`);
  }
  const html = await readFile(indexPath, "utf8");
  const css = html.match(/<link\b[^>]*rel="stylesheet"[^>]*href="(\/assets\/[^"]+\.css)"/);
  const js = html.match(/<script\b[^>]*type="module"[^>]*src="(\/assets\/[^"]+\.js)"/);
  if (!css || !js) {
    throw new Error(
      `resolveViteAssetHrefs: dist/index.html does not link a built ${!css ? "stylesheet" : "module script"} under /assets/.`,
    );
  }
  for (const href of [css[1], js[1]]) {
    if (!existsSync(path.join(distDir, href))) {
      throw new Error(`resolveViteAssetHrefs: dist/index.html links ${href}, which is not in dist.`);
    }
  }
  return { stylesHref: css[1], appScriptHref: js[1] };
}
