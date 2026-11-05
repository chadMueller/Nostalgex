#!/usr/bin/env node
/**
 * The web tuner stays separate from the marketing site (Chad, 2026-10-21: "anything
 * that touches the marketing site should never affect the web tuner or the docker
 * container").
 *
 *   node scripts/tuner-isolation-check.mjs [repoDir]
 *     Static, in npm test. Fails when a tuner page (web-tuner.html, plex-tuner.html)
 *     loads a site file (styles.css, app.js, logo/, public/ assets, any script but the
 *     tuner's own); when a site generator reads a tuner page; when the hosted build
 *     compiles the tuner pages with the site, or the tuner build takes a site page;
 *     when tuner/ imports anything; when the Docker context lets a site file in; or
 *     when vercel.json's Content-Security-Policy drops a source the tuner loads.
 *
 *   node scripts/tuner-isolation-check.mjs --builds [repoDir]
 *     Builds a temporary copy of the repo (npm run build and build:selfhost), makes
 *     site-only edits (styles.css, app.js, index.html, site-chrome.mjs, a public/ file),
 *     builds again, and fails unless every file the tuner ships hashes the same: both
 *     tuner pages and everything they load from dist/, and all of dist-selfhost/.
 *     repoDir defaults to this checkout; point it at an older checkout to see the check
 *     fail there (the negative control). The copy holds only files git tracks or would
 *     track: nothing gitignored (.env files, Secrets.xcconfig and the like) leaves the
 *     checkout, and a secret-looking path stops the run.
 */
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { appendFileSync, copyFileSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, readlinkSync, rmSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const TUNER_PAGES = ["web-tuner.html", "plex-tuner.html"];

/** Local files a page loads: stylesheets, icons, scripts, images, media. Not page links. */
export function loadedRefs(html) {
  const refs = [];
  for (const m of html.matchAll(/<link\b[^>]*>/gi)) {
    const tag = m[0];
    const rel = /\srel="([^"]+)"/i.exec(tag)?.[1] || "";
    if (/stylesheet|icon|manifest|modulepreload|preload/i.test(rel)) refs.push(/\shref="([^"]+)"/i.exec(tag)?.[1]);
  }
  for (const m of html.matchAll(/<(?:script|img|source|video|audio|iframe)\b[^>]*\ssrc="([^"]+)"/gi)) refs.push(m[1]);
  return refs.filter(Boolean).filter((r) => !/^(?:[a-z][a-z0-9+.-]*:|\/\/|#)/i.test(r));
}

/** Where a tuner page may load local files from. */
const ALLOWED = [/^tuner\//, /^scripts\/nostalgex-[a-z0-9-]+\.(?:js|cjs)$/, /^vendor\//];

function staticChecks(root) {
  const failures = [];
  const read = (p) => readFileSync(join(root, p), "utf8");
  // 1. The tuner pages load only the tuner's own files.
  for (const page of TUNER_PAGES) {
    const html = read(page);
    // selfhost:only lines are HTML comments in the source; they become tags in the Docker build.
    const withSelfhostOnly = html.replace(/<!-- selfhost:only: (.*) -->/g, "$1");
    for (const ref of loadedRefs(withSelfhostOnly)) {
      const path = ref.replace(/^\.?\//, "").replace(/[?#].*$/, "");
      if (!ALLOWED.some((re) => re.test(path))) failures.push(`${page} loads ${ref}, which is not the tuner's (tuner/, scripts/nostalgex-*, vendor/)`);
      else if (!path.startsWith("vendor/") && !existsSync(join(root, path))) failures.push(`${page} loads ${ref}, which does not exist`);
    }
  }
  // 2. tuner/ is self-contained.
  const tunerDir = join(root, "tuner");
  if (!existsSync(tunerDir)) failures.push("there is no tuner/ folder for the tuner's own files");
  for (const f of existsSync(tunerDir) ? readdirSync(tunerDir).filter((n) => /\.(css|js)$/.test(n)) : []) {
    const src = readFileSync(join(tunerDir, f), "utf8");
    if (/@import\b|^\s*import\b|\bimport\s*\(|require\(/m.test(src)) failures.push(`tuner/${f} imports another file`);
  }
  // 3. No site generator reads a tuner page.
  for (const gen of ["scripts/site-chrome.mjs", "scripts/build-blog.mjs", "scripts/build-bundles.mjs", "scripts/site-media.mjs"]) {
    if (!existsSync(join(root, gen))) continue;
    const src = read(gen);
    if (/(?:web|plex)-tuner\.html|['"`]tuner\//.test(src)) failures.push(`${gen} reads a tuner page or tuner/ file`);
  }
  // 4. The builds: the site build never compiles a tuner page; the tuner build takes only them.
  const vite = read("vite.config.js");
  const siteInput = vite.slice(vite.indexOf("return {\n    plugins: [hostedMarkerPlugin()"));
  if (!/mode === 'tuner'/.test(vite)) failures.push("vite.config.js has no tuner build (--mode tuner)");
  if (/(?:web|plex)-tuner\.html/.test(siteInput)) failures.push("vite.config.js: the site build's input includes a tuner page");
  const pages = /export const TUNER_PAGES = \{([\s\S]*?)\}/.exec(vite)?.[1] || "";
  const listed = [...pages.matchAll(/'([a-z0-9-]+\.html)'/g)].map((m) => m[1]).sort();
  if (listed.join() !== [...TUNER_PAGES].sort().join()) failures.push(`vite.config.js TUNER_PAGES is ${listed.join(", ") || "missing"}, want ${TUNER_PAGES.join(", ")}`);
  const pkg = JSON.parse(read("package.json"));
  if (!/vite build --mode tuner/.test(pkg.scripts.build || "")) failures.push("package.json build does not run the tuner build");
  // 5. The Docker context takes no site file.
  const ignore = read(".dockerignore").split("\n").map((l) => l.trim()).filter((l) => l.startsWith("!"));
  for (const site of ["!styles.css", "!app.js", "!logo/", "!index.html", "!site-chrome.mjs"]) {
    if (ignore.includes(site)) failures.push(`.dockerignore lets ${site.slice(1)} into the Docker build`);
  }
  // 6. The CSP still allows what the tuner loads (vercel.json is shared with the site).
  const csp = JSON.parse(read("vercel.json")).headers.flatMap((h) => h.headers).find((h) => h.key === "Content-Security-Policy")?.value || "";
  const directive = (name) => (new RegExp(`(?:^|;)\\s*${name}\\s+([^;]*)`).exec(csp)?.[1] || "").split(/\s+/);
  const need = {
    // api.deezer.com: the music video genre lookup loads its answer as a script (JSONP).
    "script-src": ["'self'", "'unsafe-inline'", "https://cdn.jsdelivr.net", "https://api.deezer.com"],
    "style-src": ["'self'", "'unsafe-inline'", "https://fonts.googleapis.com"],
    "font-src": ["'self'", "https://fonts.gstatic.com"],
    "connect-src": ["'self'", "https:", "wss:"],
    "media-src": ["'self'", "blob:", "https:"],
    "img-src": ["'self'", "data:", "https:"],
    "worker-src": ["blob:"],
  };
  for (const page of TUNER_PAGES) {
    for (const m of read(page).matchAll(/<script\b[^>]*\ssrc="(https:\/\/[^/"]+)/g)) {
      if (!need["script-src"].includes(m[1])) need["script-src"].push(m[1]);
    }
  }
  for (const [name, sources] of Object.entries(need)) {
    const have = directive(name);
    for (const s of sources) if (!have.includes(s)) failures.push(`vercel.json CSP ${name} lacks ${s}, which the tuner needs`);
  }
  return failures;
}

// ── --builds: hashes of everything the tuner ships, before and after site-only edits ──

function walk(dir) {
  return readdirSync(dir).flatMap((n) => {
    const p = join(dir, n);
    return statSync(p).isDirectory() ? walk(p) : [p];
  });
}
function sha(path) { return createHash("sha256").update(readFileSync(path)).digest("hex").slice(0, 16); }

function tunerHashes(copy) {
  const out = {};
  const dist = join(copy, "dist");
  for (const page of TUNER_PAGES) {
    const file = join(dist, page);
    out[`dist/${page}`] = sha(file);
    for (const ref of loadedRefs(readFileSync(file, "utf8"))) {
      const p = ref.startsWith("/") ? join(dist, ref) : join(dist, ref.replace(/^\.\//, ""));
      const clean = p.replace(/[?#].*$/, "");
      out[`dist/${relative(dist, clean)}`] = existsSync(clean) ? sha(clean) : "missing";
    }
  }
  const self = join(copy, "dist-selfhost");
  for (const f of walk(self)) out[`dist-selfhost/${relative(self, f)}`] = sha(f);
  return out;
}

function build(copy) {
  const run = (args) => execFileSync("npm", ["run", ...args], { cwd: copy, stdio: ["ignore", "ignore", "pipe"] });
  run(["build"]);
  run(["build:selfhost"]);
}

/** Paths that may hold secrets. None of them is ever copied, even if git would track it. */
const SECRET_PATH = /(?:^|\/)(?:\.env|\.vercel\/|Secrets|[^/]*\.secret|[^/]*\.p12$|[^/]*\.p8$|AuthKey_)/i;

/**
 * Copies the files git tracks, or would track (untracked but not ignored), into `copy`.
 * Anything gitignored stays behind: .env files, Secrets.xcconfig, node_modules, builds.
 * The tvOS app is left out too; the web build never reads it.
 */
function copyRepo(repo, copy) {
  const listed = execFileSync("git", ["-C", repo, "ls-files", "-z", "--cached", "--others", "--exclude-standard"])
    .toString().split("\0").filter(Boolean);
  const files = [...new Set(listed)].filter((f) => !f.startsWith("Nostalgex/") && !SECRET_PATH.test(f));
  for (const f of files) {
    const src = join(repo, f);
    if (!existsSync(src) && !isSymlink(src)) continue; // tracked but deleted in this checkout
    const dst = join(copy, f);
    mkdirSync(dirname(dst), { recursive: true });
    if (isSymlink(src)) symlinkSync(readlinkSync(src), dst);
    else copyFileSync(src, dst);
  }
  const leaked = walk(copy).map((p) => relative(copy, p)).filter((p) => SECRET_PATH.test(p));
  if (leaked.length) throw new Error(`refusing to build: secret-looking files copied: ${leaked.join(", ")}`);
  return files.length;
}
function isSymlink(p) { try { return lstatSync(p).isSymbolicLink(); } catch { return false; } }

function buildsCheck(repo) {
  const copy = mkdtempSync(join(tmpdir(), "nx-tuner-isolation-"));
  try {
    copyRepo(repo, copy);
    symlinkSync(join(repo, "node_modules"), join(copy, "node_modules"));
    build(copy);
    const before = tunerHashes(copy);
    // Site-only edits: what a marketing change looks like.
    appendFileSync(join(copy, "styles.css"), "\n.nx-site-only-edit { color: #f0f; }\n");
    appendFileSync(join(copy, "app.js"), "\n/* site-only edit */ window.nxSiteOnlyEdit = true;\n");
    writeFileSync(join(copy, "index.html"), readFileSync(join(copy, "index.html"), "utf8").replace("</body>", "<!-- site-only edit -->\n</body>"));
    if (existsSync(join(copy, "scripts/site-chrome.mjs"))) appendFileSync(join(copy, "scripts/site-chrome.mjs"), "\n// site-only edit\n");
    writeFileSync(join(copy, "public/site-only-edit.txt"), "site-only edit\n");
    build(copy);
    const after = tunerHashes(copy);
    const keys = [...new Set([...Object.keys(before), ...Object.keys(after)])].sort();
    const changed = keys.filter((k) => before[k] !== after[k]);
    return { files: keys.length, changed };
  } finally {
    rmSync(copy, { recursive: true, force: true });
  }
}

const args = process.argv.slice(2);
if (args[0] === "--builds") {
  const repo = resolve(args[1] || join(here, ".."));
  const { files, changed } = buildsCheck(repo);
  if (changed.length) {
    console.error(`tuner isolation (builds): a site-only edit changed ${changed.length} of ${files} tuner files`);
    for (const c of changed.slice(0, 20)) console.error(`  CHANGED ${c}`);
    process.exit(1);
  }
  console.log(`tuner isolation (builds): ${files} tuner files hash the same after site-only edits`);
} else {
  const failures = staticChecks(resolve(args[0] || join(here, "..")));
  if (failures.length) {
    console.error(`tuner isolation: ${failures.length} failed`);
    for (const f of failures) console.error(`  FAIL ${f}`);
    process.exit(1);
  }
  console.log("tuner isolation: the tuner pages load only tuner files; the builds, Docker context and CSP keep it that way");
}
