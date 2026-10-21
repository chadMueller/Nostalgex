// Self-host build mode for the web tuner (`npm run build:selfhost` -> dist-selfhost/).
//
// The Docker image serves the same web-tuner.html and plex-tuner.html as
// nostalgex.app. The differences live here, at build time, plus a few
// `location.protocol` checks in the shared source:
//
//   - only the two tuner pages are built (web-tuner.html is also index.html)
//   - hls.js, qrcodejs and the fonts come from npm and ship in vendor/, so the
//     page makes no CDN or Google Fonts requests
//   - analytics are removed
//   - marketing chrome, the newsletter and the email promo are cut out between
//     selfhost markers in the source (see below)
//   - asset URLs are relative (base './'), so a subpath reverse proxy works
//
// Markers. A line that is only a marker comment:
//
//   <!-- selfhost:strip:start -->   or   // selfhost:strip:start
//   <!-- selfhost:strip:end -->     or   // selfhost:strip:end
//   <!-- selfhost:only: <p>...</p> -->   or   // selfhost:only: code();
//
// The hosted build deletes every marker line and nothing else, so dist/ is byte
// for byte what it was before the markers went in. The self-host build deletes
// each strip block (markers included) and unwraps each `only` line.

import { resolve, dirname, basename } from 'path'
import { readFileSync, writeFileSync, mkdirSync, copyFileSync, existsSync, readdirSync } from 'fs'
import { fileURLToPath } from 'url'

// Vendored files come straight from node_modules (several packages do not export
// their dist or LICENSE paths, so require.resolve cannot reach them).
const NODE_MODULES = resolve(dirname(fileURLToPath(import.meta.url)), '..', 'node_modules')
const mod = (spec) => {
  const p = resolve(NODE_MODULES, spec)
  if (!existsSync(p)) throw new Error(`self-host build: ${spec} is missing. Run npm ci.`)
  return p
}

const MARKER_LINE = /^[ \t]*(?:<!--|\/\/) selfhost:(?:strip:start|strip:end|only:).*\r?\n/gm
const STRIP_START = /^[ \t]*(?:<!--|\/\/) selfhost:strip:start\b.*$/
const STRIP_END = /^[ \t]*(?:<!--|\/\/) selfhost:strip:end\b.*$/
const ONLY_HTML = /^([ \t]*)<!-- selfhost:only: (.*) -->[ \t]*$/
const ONLY_JS = /^([ \t]*)\/\/ selfhost:only: (.*)$/

/** Hosted build: drop the marker lines, keep everything between them. */
export function stripMarkerLines(html) {
  return html.replace(MARKER_LINE, '')
}

/** Self-host build: drop each strip block, unwrap each `only` line. Throws on unbalanced markers. */
export function applySelfhostMarkers(html, file = 'page') {
  const lines = html.split('\n')
  const out = []
  let inStrip = false
  let startLine = 0
  lines.forEach((line, i) => {
    if (STRIP_START.test(line)) {
      if (inStrip) throw new Error(`${file}:${i + 1}: nested selfhost:strip:start (opened at ${startLine})`)
      inStrip = true
      startLine = i + 1
      return
    }
    if (STRIP_END.test(line)) {
      if (!inStrip) throw new Error(`${file}:${i + 1}: selfhost:strip:end without a start`)
      inStrip = false
      return
    }
    if (inStrip) return
    const only = ONLY_HTML.exec(line) || ONLY_JS.exec(line)
    out.push(only ? only[1] + only[2] : line)
  })
  if (inStrip) throw new Error(`${file}:${startLine}: selfhost:strip:start never closed`)
  return out.join('\n')
}

// ── CDN to vendor/ ───────────────────────────────────────────────────────────

const SCRIPT_VENDOR = [
  {
    pkg: 'hls.js',
    re: /<script src="https:\/\/cdn\.jsdelivr\.net\/npm\/hls\.js@([\d.]+)\/dist\/hls\.min\.js"[^>]*><\/script>/g,
    from: 'hls.js/dist/hls.min.js',
    to: 'vendor/hls.min.js',
    license: 'hls.js/LICENSE',
  },
  {
    pkg: 'qrcodejs',
    re: /<script src="https:\/\/cdn\.jsdelivr\.net\/npm\/qrcodejs@([\d.]+)\/qrcode\.min\.js"[^>]*><\/script>/g,
    from: 'qrcodejs/qrcode.min.js',
    to: 'vendor/qrcode.min.js',
    license: 'qrcodejs/LICENSE',
  },
]

// Google Fonts stylesheets, keyed by a family that only that stylesheet asks for.
const FONT_SHEETS = [
  {
    key: 'VT323',
    out: 'vendor/fonts/tuner.css',
    css: [
      { file: '@fontsource/vt323/400.css' },
      { file: '@fontsource/press-start-2p/400.css' },
      { file: '@fontsource/silkscreen/400.css' },
      { file: '@fontsource/silkscreen/700.css' },
    ],
  },
  {
    key: 'Bricolage+Grotesque',
    out: 'vendor/fonts/site.css',
    css: [
      // Google serves the opsz axis; the fontsource-variable opsz file is the same font.
      { file: '@fontsource-variable/bricolage-grotesque/opsz.css', family: ['Bricolage Grotesque Variable', 'Bricolage Grotesque'] },
      { file: '@fontsource/space-mono/400.css' },
      { file: '@fontsource/space-mono/700.css' },
    ],
  },
]
const FONT_LICENSES = [
  '@fontsource/vt323/LICENSE',
  '@fontsource/press-start-2p/LICENSE',
  '@fontsource/silkscreen/LICENSE',
  '@fontsource-variable/bricolage-grotesque/LICENSE',
  '@fontsource/space-mono/LICENSE',
]

const GOOGLE_FONTS_LINK = /<link href="https:\/\/fonts\.googleapis\.com\/css2\?([^"]*)" rel="stylesheet">/g
const PRECONNECT = /^[ \t]*<link rel="preconnect" href="https:\/\/fonts\.(?:googleapis|gstatic)\.com"[^>]*>\r?\n/gm
const ANALYTICS = /^[ \t]*<script[^>]*src="https:\/\/statsngraphs\.lol\/[^"]*"[^>]*><\/script>\r?\n/gm
// Anything that would still make the page load code or styles from elsewhere.
const REMOTE_SUBRESOURCE = /<(?:script|link|img|iframe|source|video|audio)\b[^>]*\s(?:src|href)="(?:https?:)?\/\/[^"]*"[^>]*>/g

function pkgVersion(name) {
  return JSON.parse(readFileSync(mod(`${name}/package.json`), 'utf8')).version
}

/** Rewrite one built tuner page for self-host. Throws if a remote subresource survives. */
export function rewriteForSelfhost(html, file = 'page') {
  let out = html
  for (const v of SCRIPT_VENDOR) {
    out = out.replace(v.re, (_, cdnVersion) => {
      const have = pkgVersion(v.pkg)
      if (cdnVersion !== have) {
        throw new Error(`${file}: page loads ${v.pkg}@${cdnVersion} from the CDN but package.json pins ${have}. Bump one to match the other.`)
      }
      // The version query lets nginx cache vendor/ for a long time and still pick up a bump.
      return `<script src="${v.to}?v=${have}"></script>`
    })
  }
  out = out.replace(PRECONNECT, '')
  out = out.replace(ANALYTICS, '')
  out = out.replace(GOOGLE_FONTS_LINK, (tag, query) => {
    const sheet = FONT_SHEETS.find((s) => query.includes(`family=${s.key}`))
    if (!sheet) throw new Error(`${file}: no vendored font sheet for Google Fonts query "${query}"`)
    return `<link rel="stylesheet" href="${sheet.out}">`
  })
  // Lets the shared scripts tell the two builds apart (enrichment relay, music lookups).
  out = out.replace(/<meta charset="UTF-8">/i, (m) => `${m}\n<meta name="nostalgex-build" content="selfhost">`)
  if (!out.includes('name="nostalgex-build"')) throw new Error(`${file}: no <meta charset> to put the build marker after`)
  // The hosted pages load analytics from an inline loader after the load event, which
  // REMOTE_SUBRESOURCE cannot see. web-tuner.html keeps it between strip markers; this
  // catches it if those markers ever go missing.
  if (/statsngraphs/i.test(out)) throw new Error(`${file}: analytics left in the self-host build`)
  const remote = out.match(REMOTE_SUBRESOURCE)
  if (remote) throw new Error(`${file}: remote subresource left in the self-host build:\n  ${remote.join('\n  ')}`)
  return out
}

// ── Files ────────────────────────────────────────────────────────────────────

function copyInto(outDir, from, to) {
  const dest = resolve(outDir, to)
  mkdirSync(dirname(dest), { recursive: true })
  copyFileSync(from, dest)
}

/** Concatenate the fontsource sheets for one page and copy only the font files they name. */
function writeFontSheet(outDir, sheet) {
  const outFile = resolve(outDir, sheet.out)
  const parts = []
  for (const entry of sheet.css) {
    const cssPath = mod(entry.file)
    let css = readFileSync(cssPath, 'utf8')
    if (entry.family) css = css.split(`'${entry.family[0]}'`).join(`'${entry.family[1]}'`)
    css = css.replace(/url\(\.\/files\/([^)]+)\)/g, (_, name) => {
      copyInto(outDir, resolve(dirname(cssPath), 'files', name), `vendor/fonts/files/${name}`)
      return `url(./files/${name})`
    })
    parts.push(`/* ${entry.file} */\n${css.trim()}\n`)
  }
  mkdirSync(dirname(outFile), { recursive: true })
  writeFileSync(outFile, parts.join('\n'))
}

/** Local stylesheets and scripts a built page links (not http(s), data: or protocol-relative). */
export function pageLocalRefs(html) {
  const refs = [
    ...[...html.matchAll(/<link[^>]*\srel="stylesheet"[^>]*\shref="([^"]+)"/g)].map((m) => m[1]),
    ...[...html.matchAll(/<link[^>]*\shref="([^"]+)"[^>]*\srel="stylesheet"/g)].map((m) => m[1]),
    ...[...html.matchAll(/<script[^>]*\ssrc="([^"]+)"/g)].map((m) => m[1]),
  ]
  return [...new Set(refs)]
    .filter((r) => !/^(?:[a-z]+:|\/\/)/i.test(r))
    .map((r) => r.replace(/^\.?\//, '').replace(/[?#].*$/, ''))
}

/** The `scripts/...` files a page loads with a plain <script src>. */
function pageScripts(html) {
  return [...html.matchAll(/<script[^>]*\ssrc="(?:\.\/)?(scripts\/[^"]+)"/g)].map((m) => m[1])
}

export function selfhostPlugins({ root, version }) {
  let outDir
  let wroteBundle = false
  return [
    {
      name: 'nostalgex-selfhost-markers',
      transformIndexHtml: {
        order: 'pre',
        handler(html, ctx) {
          return applySelfhostMarkers(html, basename(ctx.filename))
        },
      },
    },
    {
      name: 'nostalgex-selfhost-vendor',
      configResolved(config) {
        outDir = resolve(config.root, config.build.outDir)
        wroteBundle = false
      },
      transformIndexHtml: {
        order: 'post',
        handler(html, ctx) {
          return rewriteForSelfhost(html, basename(ctx.filename))
        },
      },
      writeBundle() {
        wroteBundle = true
      },
      closeBundle() {
        // closeBundle runs whether the build succeeded or failed. Throwing here
        // after a failure replaces the real error with "did not emit
        // web-tuner.html", which sends you looking in the wrong place: the
        // actual cause was a missing dependency, reported and then swallowed.
        if (!wroteBundle) return
        const pages = ['web-tuner.html', 'plex-tuner.html']
        for (const page of pages) {
          if (!existsSync(resolve(outDir, page))) throw new Error(`self-host build did not emit ${page}`)
        }
        // The connect page is the front door.
        copyFileSync(resolve(outDir, 'web-tuner.html'), resolve(outDir, 'index.html'))

        // Helper scripts: exactly the ones the two pages load.
        const scripts = new Set(pages.flatMap((p) => pageScripts(readFileSync(resolve(outDir, p), 'utf8'))))
        for (const s of scripts) copyInto(outDir, resolve(root, s), s)

        // Data the tuner fetches. franchises.json is optional.
        for (const f of ['channels.json', 'channels-memberships.json', 'franchises.json']) {
          const src = resolve(root, 'public', f)
          if (existsSync(src)) copyInto(outDir, src, f)
          else if (f !== 'franchises.json') throw new Error(`self-host build: public/${f} is missing`)
        }

        for (const v of SCRIPT_VENDOR) {
          copyInto(outDir, mod(v.from), v.to)
          copyInto(outDir, mod(v.license), `vendor/licenses/${v.pkg}.txt`)
        }
        for (const sheet of FONT_SHEETS) writeFontSheet(outDir, sheet)
        for (const lic of FONT_LICENSES) {
          copyInto(outDir, mod(lic), `vendor/licenses/${lic.split('/')[1]}.txt`)
        }

        // Defaults for running dist-selfhost/ without the container. In the image,
        // docker/40-config.sh writes the real one from the environment at start.
        writeFileSync(
          resolve(outDir, 'config.json'),
          JSON.stringify({ tunerVersion: version, musicLookups: false, enrichment: true }, null, 2) + '\n',
        )

        // Every local file a page links has to be in the output. A stylesheet Vite can't
        // find is only a warning ("will remain unchanged to be resolved at runtime"), and
        // the Docker context is an allowlist (.dockerignore), so tuner.css once shipped as
        // a link to nothing: the sign-in screens unstyled in the container.
        for (const page of pages) {
          const html = readFileSync(resolve(outDir, page), 'utf8')
          for (const ref of pageLocalRefs(html)) {
            if (!existsSync(resolve(outDir, ref))) {
              throw new Error(`self-host build: ${page} links ${ref}, which is not in the output (missing from the build context? see .dockerignore)`)
            }
          }
        }

        const shipped = readdirSync(outDir).sort()
        // eslint-disable-next-line no-console
        console.log(`selfhost: ${shipped.join(', ')}; scripts: ${[...scripts].map((s) => basename(s)).join(', ')}`)
      },
    },
  ]
}

/** Hosted build only: remove marker lines so dist/ is unchanged by their presence. */
export function hostedMarkerPlugin() {
  return {
    name: 'nostalgex-strip-selfhost-markers',
    transformIndexHtml: {
      order: 'pre',
      handler: (html) => stripMarkerLines(html),
    },
  }
}
