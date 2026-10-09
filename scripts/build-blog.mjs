// Build the static blog.
//
// Reads Markdown posts from content/blog/, renders them into HTML pages that
// share the site's styles and chrome, generates /blog (index) and
// /blog/<slug> (one per post), and rewrites public/sitemap.xml so Vercel
// picks the posts up for SEO.
//
// Why a plain Node script instead of a Vite plugin? vite.config.js already
// has a hand-rolled rollupOptions.input list of HTML entries and a
// closeBundle hook that copies browser scripts into dist/. A sibling plugin
// (`emitBlog`) in that file calls into this module during `closeBundle` so
// posts land in dist/blog/, and `npm run build` also runs this directly to
// keep sitemap.xml fresh in the repo (same way `npm run changelog:render`
// updates index.html before `vite build`).

import { readFile, writeFile, readdir, mkdir, copyFile, stat } from "node:fs/promises";
import { existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { marked } from "marked";
import matter from "gray-matter";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const CONTENT_DIR = path.join(ROOT, "content", "blog");
const PUBLIC_DIR = path.join(ROOT, "public");
const SITEMAP_PATH = path.join(PUBLIC_DIR, "sitemap.xml");

const SITE_ORIGIN = "https://www.nostalgex.app";
const DEFAULT_OG_IMAGE = `${SITE_ORIGIN}/og-image.png`;
const APPLE_TV_URL = "https://apps.apple.com/app/nostalgex/id6762563534";

const BLOG_TITLE = "Nostalgex Blog";
const BLOG_DESCRIPTION =
  "Nostalgia lists and setup guides for turning your Plex, Jellyfin or Emby library into live TV channels with Nostalgex.";

function escapeHtml(text) {
  return String(text)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function escapeAttr(text) {
  return escapeHtml(text);
}

function formatIsoDate(value) {
  const d = new Date(value);
  if (Number.isNaN(d.getTime())) {
    throw new Error(`Invalid date: ${value}`);
  }
  return d.toISOString().slice(0, 10);
}

function formatHumanDate(value) {
  const d = new Date(`${value}T00:00:00Z`);
  if (Number.isNaN(d.getTime())) return value;
  return d.toLocaleDateString("en-US", {
    year: "numeric",
    month: "long",
    day: "numeric",
    timeZone: "UTC",
  });
}

function requireField(frontmatter, key, file) {
  const value = frontmatter[key];
  if (value == null || value === "") {
    throw new Error(`${file}: missing required frontmatter field "${key}"`);
  }
  return value;
}

function sanitizeSlug(slug, file) {
  if (!/^[a-z0-9][a-z0-9-]*$/.test(slug)) {
    throw new Error(
      `${file}: slug "${slug}" must be lowercase a-z, 0-9 and -`,
    );
  }
  return slug;
}

// Strip the first leading H1 if its text matches the frontmatter title. Posts
// may or may not include an in-body H1; the template always renders one from
// the title, so we drop a duplicate to avoid two H1s on the page.
function stripLeadingH1(markdown, title) {
  const trimmed = markdown.replace(/^\s+/, "");
  const h1Match = trimmed.match(/^#\s+(.+?)\s*\n/);
  if (!h1Match) return trimmed;
  const h1Text = h1Match[1].trim();
  if (h1Text === title.trim()) {
    return trimmed.slice(h1Match[0].length).replace(/^\s+/, "");
  }
  return trimmed;
}

// Remove HTML comment blocks (build notes, link-back reminders) so they never
// reach the rendered page. These are standalone <!-- ... --> blocks in the
// posts; marked otherwise passes them straight through into the HTML source.
function stripHtmlComments(markdown) {
  return markdown.replace(/<!--[\s\S]*?-->/g, "");
}

// Collapse a snippet of Markdown to plain text for use in JSON-LD values.
// Turns [label](url) into label, drops emphasis/backticks, and flattens
// whitespace so FAQ answers are clean strings a validator will accept.
function markdownToText(markdown) {
  return markdown
    .replace(/!\[[^\]]*\]\([^)]*\)/g, "") // images
    .replace(/\[([^\]]+)\]\([^)]*\)/g, "$1") // links -> label
    .replace(/[*_`]/g, "") // emphasis / code marks
    .replace(/\s+/g, " ")
    .trim();
}

// Pull the "## FAQ" section apart into { question, answer } pairs: each "### "
// is a question, and the prose until the next "###" or "##" is its answer.
// Returns [] when the post has no FAQ section, so FAQPage is only emitted for
// posts that actually carry one.
function extractFaq(markdown) {
  const lines = markdown.split("\n");
  let i = lines.findIndex((l) => /^##\s+FAQ\s*$/i.test(l.trim()));
  if (i === -1) return [];

  const items = [];
  i += 1;
  let question = null;
  let answerLines = [];
  const flush = () => {
    if (question) {
      const answer = markdownToText(answerLines.join("\n"));
      if (answer) items.push({ question, answer });
    }
    question = null;
    answerLines = [];
  };

  for (; i < lines.length; i += 1) {
    const line = lines[i];
    if (/^##\s+/.test(line) && !/^###\s+/.test(line)) {
      // next top-level section ends the FAQ
      break;
    }
    const q = line.match(/^###\s+(.+?)\s*$/);
    if (q) {
      flush();
      question = markdownToText(q[1]);
      continue;
    }
    if (question) answerLines.push(line);
  }
  flush();
  return items;
}

// Wrap each rendered <table> in a scroll container so wide comparison tables
// scroll horizontally on phones instead of crushing their columns. marked
// emits bare <table> tags, so a string wrap is simpler and more
// version-proof than overriding the renderer.
function wrapTables(html) {
  return html
    .replace(/<table>/g, '<div class="blog-table-wrap"><table>')
    .replace(/<\/table>/g, "</table></div>");
}

function buildFaqJsonLd(faqItems) {
  if (!faqItems.length) return null;
  return {
    "@context": "https://schema.org",
    "@type": "FAQPage",
    mainEntity: faqItems.map((item) => ({
      "@type": "Question",
      name: item.question,
      acceptedAnswer: {
        "@type": "Answer",
        text: item.answer,
      },
    })),
  };
}

function renderNav() {
  return `
  <header class="nav" id="nav">
    <div class="nav-inner">
      <a class="brand" href="/" aria-label="Nostalgex home">
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
          <svg viewBox="0 0 24 24" aria-hidden="true" fill="currentColor"><path d="M17.05 12.54c-.03-2.89 2.36-4.28 2.47-4.35-1.35-1.97-3.44-2.24-4.18-2.27-1.78-.18-3.47 1.05-4.37 1.05-.9 0-2.29-1.02-3.77-.99-1.94.03-3.73 1.13-4.72 2.86-2.02 3.5-.52 8.67 1.45 11.51.96 1.39 2.1 2.95 3.6 2.9 1.45-.06 1.99-.93 3.74-.93s2.24.93 3.77.9c1.56-.03 2.54-1.41 3.49-2.81 1.1-1.61 1.55-3.17 1.58-3.25-.04-.02-3.03-1.16-3.06-4.62zM14.16 4.06c.8-.97 1.34-2.31 1.19-3.65-1.15.05-2.55.77-3.37 1.73-.74.86-1.39 2.23-1.22 3.54 1.29.1 2.6-.65 3.4-1.62z"/></svg>
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

function renderFooter() {
  return `
  <footer class="footer">
    <div class="container footer-inner">
      <div class="footer-brand">
        <img src="/logo/nostalgex-black.svg" alt="Nostalgex" width="545" height="72" class="footer-logo footer-logo-day" loading="lazy">
        <img src="/logo/nostalgex-white.svg" alt="Nostalgex" width="545" height="72" class="footer-logo footer-logo-nite" loading="lazy">
        <p>Retro cable TV for your own library.</p>
      </div>
      <nav class="footer-links" aria-label="Footer">
        <a href="${APPLE_TV_URL}" target="_blank" rel="noopener">Apple TV app</a>
        <a href="/web-tuner">Web tuner</a>
        <a href="/plex">Plex</a>
        <a href="/jellyfin">Jellyfin</a>
        <a href="/emby">Emby</a>
        <a href="/blog">Blog</a>
        <a href="/support">Support</a>
        <a href="/privacy">Privacy</a>
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
      <p class="footer-note">Not affiliated with Plex, Jellyfin, Emby, or Apple.</p>
    </div>
  </footer>`;
}

function renderThemeBoot() {
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

function renderHead({
  title,
  description,
  canonical,
  ogImage,
  ogType,
  jsonLd,
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
    `<script defer src="https://data-haus.vercel.app/track.js" data-site="f5b3399a2c57176a"></script>`,
    `<script defer data-site="nostalgex" src="https://statsngraphs.lol/s.js"></script>`,
  ].join("\n");

  // jsonLd may be a single object or an array; emit one script tag per entry.
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
<meta name="robots" content="index, follow">
<link rel="canonical" href="${escapeAttr(canonical)}">
<link rel="icon" type="image/png" href="/logo/favicon.png">

<meta property="og:title" content="${escapeAttr(title)}">
<meta property="og:description" content="${escapeAttr(description)}">
<meta property="og:type" content="${escapeAttr(ogType)}">
<meta property="og:url" content="${escapeAttr(canonical)}">
<meta property="og:site_name" content="Nostalgex">
<meta property="og:image" content="${escapeAttr(ogImage)}">
<meta property="og:image:alt" content="Nostalgex retro TV logo">

<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="${escapeAttr(title)}">
<meta name="twitter:description" content="${escapeAttr(description)}">
<meta name="twitter:image" content="${escapeAttr(ogImage)}">
${extraMeta}
${scripts}
${jsonLdBlocks}
</head>`;
}

function renderPostCta() {
  return `
      <section class="blog-post-cta" aria-labelledby="blog-post-cta-heading">
        <h2 id="blog-post-cta-heading">Try Nostalgex tonight</h2>
        <p>Nostalgex turns your own Plex, Jellyfin or Emby library into live channels with a retro TV guide. It's free and open source.</p>
        <div class="cta-row cta-center">
          <a class="btn btn-ink btn-lg" href="/web-tuner">Try the free web tuner</a>
          <a class="btn btn-paper btn-lg" href="${APPLE_TV_URL}" target="_blank" rel="noopener">Free on Apple TV</a>
        </div>
        <p class="blog-post-cta-discord"><a href="https://discord.gg/FgnZcr5bDT" target="_blank" rel="noopener"><svg viewBox="0 0 24 24" aria-hidden="true" fill="currentColor"><path d="M20.317 4.37a19.79 19.79 0 0 0-4.885-1.515.07.07 0 0 0-.075.035c-.21.375-.444.864-.608 1.25a18.27 18.27 0 0 0-5.487 0 12.64 12.64 0 0 0-.617-1.25.077.077 0 0 0-.079-.035A19.736 19.736 0 0 0 3.68 4.37a.07.07 0 0 0-.032.027C.533 9.046-.32 13.58.099 18.058a.082.082 0 0 0 .031.056 19.9 19.9 0 0 0 5.993 3.03.078.078 0 0 0 .084-.028c.462-.63.874-1.295 1.226-1.994a.076.076 0 0 0-.041-.106 13.1 13.1 0 0 1-1.872-.892.077.077 0 0 1-.008-.128c.126-.094.252-.192.372-.291a.074.074 0 0 1 .077-.01c3.927 1.793 8.18 1.793 12.061 0a.073.073 0 0 1 .078.01c.12.099.246.198.373.292a.077.077 0 0 1-.006.127c-.598.35-1.22.645-1.873.893a.076.076 0 0 0-.04.106c.36.698.772 1.362 1.225 1.993a.076.076 0 0 0 .084.029 19.84 19.84 0 0 0 6.002-3.03.077.077 0 0 0 .032-.055c.5-5.177-.838-9.673-3.549-13.662a.06.06 0 0 0-.031-.028zM8.02 15.33c-1.183 0-2.157-1.085-2.157-2.419 0-1.333.955-2.418 2.157-2.418 1.21 0 2.176 1.094 2.157 2.418 0 1.334-.955 2.419-2.157 2.419zm7.975 0c-1.183 0-2.157-1.085-2.157-2.419 0-1.333.955-2.418 2.157-2.418 1.21 0 2.176 1.094 2.157 2.418 0 1.334-.946 2.419-2.157 2.419z"/></svg>Join the Discord</a></p>
      </section>`;
}

function renderPostPage(post, assetHrefs = {}) {
  const canonical = `${SITE_ORIGIN}/blog/${post.slug}`;
  const ogImage = post.coverUrl
    ? (post.coverUrl.startsWith("http") ? post.coverUrl : `${SITE_ORIGIN}${post.coverUrl}`)
    : DEFAULT_OG_IMAGE;

  const seoTitle = post.seoTitle || post.title;
  const pageTitle = `${seoTitle} | Nostalgex Blog`;
  const dateModified = post.updatedIso || post.dateIso;

  const articleJsonLd = {
    "@context": "https://schema.org",
    "@type": "Article",
    headline: post.title,
    description: post.description,
    image: [ogImage],
    datePublished: post.dateIso,
    dateModified,
    author: post.author
      ? { "@type": "Person", name: post.author }
      : { "@type": "Organization", name: "Nostalgex", url: SITE_ORIGIN },
    publisher: {
      "@type": "Organization",
      name: "Muell Haus Inc.",
      url: "https://www.muellhaus.com/",
      logo: {
        "@type": "ImageObject",
        url: `${SITE_ORIGIN}/logo/nostalgex-black.svg`,
      },
    },
    about: {
      "@type": "SoftwareApplication",
      "@id": `${SITE_ORIGIN}/#app`,
    },
    mainEntityOfPage: {
      "@type": "WebPage",
      "@id": canonical,
    },
    url: canonical,
  };

  const jsonLd = [articleJsonLd, ...post.extraSchema, buildFaqJsonLd(post.faq)];

  const extraMeta = [
    `<meta property="article:published_time" content="${escapeAttr(post.dateIso)}">`,
    `<meta property="article:modified_time" content="${escapeAttr(dateModified)}">`,
  ].join("\n");

  const coverBlock = post.coverUrl
    ? `
        <img class="blog-post-cover" src="${escapeAttr(post.coverUrl)}" alt="" loading="eager" decoding="async">`
    : "";

  const bodyHtml = wrapTables(marked.parse(stripLeadingH1(post.markdown, post.title)));

  const appScript = assetHrefs.appScriptHref || "/app.js";

  return `${renderHead({
    title: pageTitle,
    description: post.description,
    canonical,
    ogImage,
    ogType: "article",
    jsonLd,
    extraMeta,
    stylesHref: assetHrefs.stylesHref,
    appScriptHref: appScript,
  })}
<body>
${renderNav()}

  <main id="top" class="blog-main">
    <article class="blog-post">
      <div class="container container-narrow">
        <p class="blog-post-eyebrow"><a href="/blog">Nostalgex Blog</a></p>
        <h1 class="blog-post-title">${escapeHtml(post.title)}</h1>
        <p class="blog-post-meta">${post.author ? `By ${escapeHtml(post.author)} &middot; ` : ""}<time datetime="${escapeAttr(post.dateIso)}">${escapeHtml(post.dateHuman)}</time></p>${coverBlock}
        <div class="blog-post-body">
${bodyHtml}
        </div>
${renderPostCta()}
      </div>
    </article>
  </main>

${renderFooter()}

  <script type="module" src="${escapeAttr(appScript)}"></script>
</body>
</html>
`;
}

function renderIndexPage(posts, assetHrefs = {}) {
  const canonical = `${SITE_ORIGIN}/blog`;
  const pageTitle = `${BLOG_TITLE} | Nostalgia lists and setup guides`;

  const jsonLd = {
    "@context": "https://schema.org",
    "@type": "Blog",
    name: BLOG_TITLE,
    description: BLOG_DESCRIPTION,
    url: canonical,
    publisher: {
      "@type": "Organization",
      name: "Muell Haus Inc.",
      url: "https://www.muellhaus.com/",
    },
    blogPost: posts.map((post) => ({
      "@type": "BlogPosting",
      headline: post.title,
      description: post.description,
      datePublished: post.dateIso,
      url: `${SITE_ORIGIN}/blog/${post.slug}`,
    })),
  };

  const cardsHtml = posts
    .map((post) => {
      const href = `/blog/${post.slug}`;
      const cover = post.coverUrl
        ? `<img class="blog-card-cover" src="${escapeAttr(post.coverUrl)}" alt="" loading="lazy" decoding="async">`
        : "";
      return `          <li class="blog-card">
            <a class="blog-card-link" href="${escapeAttr(href)}">
              ${cover}
              <div class="blog-card-body">
                <p class="blog-card-meta"><time datetime="${escapeAttr(post.dateIso)}">${escapeHtml(post.dateHuman)}</time></p>
                <h2 class="blog-card-title">${escapeHtml(post.title)}</h2>
                <p class="blog-card-dek">${escapeHtml(post.description)}</p>
                <span class="blog-card-cta">Read &rarr;</span>
              </div>
            </a>
          </li>`;
    })
    .join("\n");

  const emptyState = `          <li class="blog-card blog-card--empty">
            <p>No posts yet. New nostalgia lists are on the way.</p>
          </li>`;

  const appScript = assetHrefs.appScriptHref || "/app.js";

  return `${renderHead({
    title: pageTitle,
    description: BLOG_DESCRIPTION,
    canonical,
    ogImage: DEFAULT_OG_IMAGE,
    ogType: "website",
    jsonLd,
    stylesHref: assetHrefs.stylesHref,
    appScriptHref: appScript,
  })}
<body>
${renderNav()}

  <main id="top" class="blog-main">
    <section class="blog-index">
      <div class="container container-narrow">
        <header class="blog-index-head">
          <p class="blog-post-eyebrow">${escapeHtml(BLOG_TITLE)}</p>
          <h1>Nostalgia lists and setup guides.</h1>
          <p class="blog-index-dek">${escapeHtml(BLOG_DESCRIPTION)}</p>
        </header>
        <ul class="blog-list">
${posts.length ? cardsHtml : emptyState}
        </ul>
      </div>
    </section>
  </main>

${renderFooter()}

  <script type="module" src="${escapeAttr(appScript)}"></script>
</body>
</html>
`;
}

export async function loadPosts() {
  if (!existsSync(CONTENT_DIR)) return [];

  const entries = await readdir(CONTENT_DIR, { withFileTypes: true });
  const files = entries
    .filter((entry) => entry.isFile() && entry.name.endsWith(".md"))
    .map((entry) => entry.name)
    .sort();

  const seenSlugs = new Set();
  const posts = [];
  for (const file of files) {
    const fullPath = path.join(CONTENT_DIR, file);
    const raw = await readFile(fullPath, "utf8");
    const parsed = matter(raw);
    const fm = parsed.data || {};

    const title = String(requireField(fm, "title", file));
    const description = String(requireField(fm, "description", file));
    const slug = sanitizeSlug(String(requireField(fm, "slug", file)), file);
    const dateIso = formatIsoDate(requireField(fm, "date", file));
    const dateHuman = formatHumanDate(dateIso);
    const coverUrl = fm.cover ? String(fm.cover) : null;
    const seoTitle = fm.seo_title ? String(fm.seo_title) : null;
    const draft = fm.draft === true;
    const author = fm.author ? String(fm.author) : null;
    const updatedIso = fm.updated ? formatIsoDate(fm.updated) : null;

    // Optional extra JSON-LD: a `schema` list in frontmatter. Each entry is
    // emitted verbatim as its own <script type="application/ld+json"> next to
    // the Article and auto-generated FAQPage tags. None of today's posts use
    // it; it's here so a future post can carry HowTo, ItemList, etc.
    let extraSchema = [];
    if (fm.schema != null) {
      extraSchema = Array.isArray(fm.schema) ? fm.schema : [fm.schema];
    }

    if (seenSlugs.has(slug)) {
      throw new Error(`${file}: duplicate slug "${slug}"`);
    }
    seenSlugs.add(slug);

    const markdown = stripHtmlComments(parsed.content);
    const faq = extractFaq(markdown);

    posts.push({
      file,
      title,
      description,
      slug,
      dateIso,
      dateHuman,
      coverUrl,
      seoTitle,
      draft,
      author,
      updatedIso,
      extraSchema,
      faq,
      markdown,
    });
  }

  posts.sort((a, b) => (a.dateIso < b.dateIso ? 1 : a.dateIso > b.dateIso ? -1 : a.slug.localeCompare(b.slug)));
  // A draft stays in content/blog/ (so it's still validated above) but gets no
  // dist page, index card, or sitemap URL until its `draft: true` is removed.
  return posts.filter((post) => !post.draft);
}

export function renderBlogAssets(posts, assetHrefs = {}) {
  const assets = new Map();
  // Emit the index as /blog.html (served at /blog by Vercel's cleanUrls)
  // instead of /blog/index.html. Both work on Vercel, but the file-level
  // variant also behaves correctly under `vite preview`, which otherwise
  // falls through to a SPA-style index when a bare /blog is requested.
  assets.set("blog.html", renderIndexPage(posts, assetHrefs));
  for (const post of posts) {
    assets.set(`blog/${post.slug}.html`, renderPostPage(post, assetHrefs));
  }
  return assets;
}

async function writeAssets(assets, outDir) {
  for (const [relPath, html] of assets) {
    const target = path.join(outDir, relPath);
    await mkdir(path.dirname(target), { recursive: true });
    await writeFile(target, html, "utf8");
  }
}

async function updateSitemap(posts) {
  const raw = await readFile(SITEMAP_PATH, "utf8");

  // Rip out any previously generated blog block (idempotent), then re-insert.
  const START = "<!-- BLOG:START (generated) -->";
  const END = "<!-- BLOG:END (generated) -->";
  const escapeRegex = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  let cleaned = raw.replace(
    new RegExp(`\\s*${escapeRegex(START)}[\\s\\S]*?${escapeRegex(END)}`, "g"),
    "",
  );

  const urls = [
    {
      loc: `${SITE_ORIGIN}/blog`,
      changefreq: "weekly",
      priority: "0.6",
      lastmod: posts[0]?.dateIso,
    },
    ...posts.map((post) => ({
      loc: `${SITE_ORIGIN}/blog/${post.slug}`,
      changefreq: "monthly",
      priority: "0.6",
      lastmod: post.dateIso,
    })),
  ];

  const urlXml = urls
    .map((entry) => {
      const bits = [
        "  <url>",
        `    <loc>${entry.loc}</loc>`,
        entry.lastmod ? `    <lastmod>${entry.lastmod}</lastmod>` : null,
        `    <changefreq>${entry.changefreq}</changefreq>`,
        `    <priority>${entry.priority}</priority>`,
        "  </url>",
      ].filter(Boolean);
      return bits.join("\n");
    })
    .join("\n");

  const block = `${START}\n${urlXml}\n  ${END}`;

  const insertion = cleaned.replace(
    /\n?<\/urlset>\s*$/,
    `\n${block}\n</urlset>\n`,
  );

  if (insertion === cleaned) {
    throw new Error("sitemap.xml: could not find </urlset> to insert into");
  }

  await writeFile(SITEMAP_PATH, insertion, "utf8");
}

// Vite emits a hashed CSS asset (dist/assets/app-<hash>.css) and a hashed
// JS entry (dist/assets/app-<hash>.js). Blog pages aren't declared as
// rollupOptions.input entries, so Vite doesn't rewrite their asset refs for
// them. Read the dist directory to find the real hashed filenames and pass
// them in so the generated pages load the production bundle instead of a
// bare /styles.css / /app.js (which don't ship in dist/).
async function resolveViteAssetHrefs(distDir) {
  const assetsDir = path.join(distDir, "assets");
  if (!existsSync(assetsDir)) return {};
  const entries = await readdir(assetsDir);
  const css = entries.find((f) => /^app-.*\.css$/.test(f));
  const js = entries.find((f) => /^app-.*\.js$/.test(f));
  return {
    stylesHref: css ? `/assets/${css}` : "/styles.css",
    appScriptHref: js ? `/assets/${js}` : "/app.js",
  };
}

export async function writeBlogToDist(distDir) {
  const posts = await loadPosts();
  const assetHrefs = await resolveViteAssetHrefs(distDir);
  const assets = renderBlogAssets(posts, assetHrefs);
  await writeAssets(assets, distDir);

  // Also copy any public/blog/<slug>/ images into dist/. Vite copies the
  // public/ tree on its own, but this plugin runs in closeBundle alongside
  // copyBrowserScripts, so belt-and-braces: make sure the blog images survive
  // even if someone adds a `public/blog/` directory after the public copy pass.
  const srcBlogAssets = path.join(PUBLIC_DIR, "blog");
  if (existsSync(srcBlogAssets)) {
    await copyTree(srcBlogAssets, path.join(distDir, "blog"));
  }

  // Mirror the project-root logo/ directory into dist/logo/. The marketing
  // pages reference logo images with a relative path (./logo/...), so Vite
  // inlines them as data URLs during HTML processing. Blog pages are generated
  // after Vite finishes, so they reference /logo/... absolutely and need the
  // raw files present at that path on disk.
  const srcLogo = path.join(path.dirname(PUBLIC_DIR), "logo");
  if (existsSync(srcLogo)) {
    await copyTree(srcLogo, path.join(distDir, "logo"));
  }
  return posts;
}

async function copyTree(src, dest) {
  const entries = await readdir(src, { withFileTypes: true });
  await mkdir(dest, { recursive: true });
  for (const entry of entries) {
    const from = path.join(src, entry.name);
    const to = path.join(dest, entry.name);
    if (entry.isDirectory()) {
      await copyTree(from, to);
    } else if (entry.isFile()) {
      // Don't overwrite a generated HTML (blog/index.html) with any
      // index.html that might have snuck into public/blog/ by mistake.
      const existing = await stat(to).catch(() => null);
      if (existing) continue;
      await copyFile(from, to);
    }
  }
}

async function main() {
  const posts = await loadPosts();
  await updateSitemap(posts);
  console.log(
    `blog: rendered ${posts.length} post${posts.length === 1 ? "" : "s"}, sitemap updated`,
  );
}

const entryPath = process.argv[1] ? path.resolve(process.argv[1]) : "";
const selfPath = path.resolve(fileURLToPath(import.meta.url));

if (entryPath === selfPath) {
  main().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}
