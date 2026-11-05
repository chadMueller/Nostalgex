import { resolve } from 'path'
import { readdirSync, mkdirSync, copyFileSync } from 'fs'
import { defineConfig, loadEnv } from 'vite'
import { writeBlogToDist } from './scripts/build-blog.mjs'
import { selfhostPlugins, hostedMarkerPlugin } from './scripts/selfhost-build.mjs'
import { writeBundlesToDist } from './scripts/build-bundles.mjs'
import { resolveTunerVersion, tunerVersionPlugin } from './scripts/tuner-version.mjs'

// Browser-loaded scripts referenced with a plain <script src>. Vite can't bundle
// non-module scripts, and they live outside public/, so the default build leaves them
// out of dist and production 404s them, which breaks the entire library load. Copy
// them into dist/scripts: the tuner's engine (scripts/nostalgex-*.js|.cjs) from the
// tuner build, the site's newsletter.js from the site build.
function copyBrowserScripts(pattern) {
  return {
    name: 'copy-browser-scripts',
    closeBundle() {
      const srcDir = resolve(__dirname, 'scripts')
      const outDir = resolve(__dirname, 'dist', 'scripts')
      mkdirSync(outDir, { recursive: true })
      for (const file of readdirSync(srcDir)) {
        if (pattern.test(file)) {
          copyFileSync(resolve(srcDir, file), resolve(outDir, file))
        }
      }
    },
  }
}

// The web tuner's two pages, built on their own: `vite build --mode tuner`, after the
// site build, into the same dist/ (npm run build runs both). No public/, its own
// assets folder, none of the site's plugins, and the site build doesn't see these
// pages, so nothing on the marketing site can change what the tuner ships (Chad,
// 2026-10-21). scripts/tuner-isolation-check.mjs holds that in place.
export const TUNER_PAGES = {
  'web-tuner': resolve(__dirname, 'web-tuner.html'),
  'plex-tuner': resolve(__dirname, 'plex-tuner.html'),
}

// Render content/blog/*.md into static pages at dist/blog/index.html and
// dist/blog/<slug>.html. See scripts/build-blog.mjs for the full renderer;
// this plugin just hooks it into the Vite build so the posts ship with the
// rest of the site.
function emitBlog() {
  return {
    name: 'nostalgex-blog',
    async closeBundle() {
      const distDir = resolve(__dirname, 'dist')
      const posts = await writeBlogToDist(distDir)
      // eslint-disable-next-line no-console
      console.log(`blog: emitted ${posts.length} post${posts.length === 1 ? '' : 's'} to dist/blog/`)
    },
  }
}

// Render the channel guide into dist/channels.html and
// dist/channels/<bundle-id>.html from channels.json plus content/bundles/*.md.
// Same arrangement as emitBlog above: real files, so no rewrites, and nothing
// added to rollupOptions.input. See scripts/build-bundles.mjs.
function emitBundles() {
  return {
    name: 'nostalgex-bundles',
    async closeBundle() {
      const distDir = resolve(__dirname, 'dist')
      const summary = await writeBundlesToDist(distDir)
      // eslint-disable-next-line no-console
      console.log(
        `channels: emitted the hub + ${summary.bundles} bundle page${summary.bundles === 1 ? '' : 's'} ` +
          `(${summary.indexed} indexed, ${summary.held} held) to dist/channels/`,
      )
      if (summary.skipped.length) {
        // eslint-disable-next-line no-console
        console.warn(`channels: no content file yet for ${summary.skipped.join(', ')}`)
      }
    },
  }
}

// plex-tuner.html reads VITE_SUPABASE_URL, VITE_SUPABASE_ANON_KEY and
// VITE_TMDB_RELAY_URL through Vite's %VITE_...% HTML replacement (see .env.example).
// The Supabase pair is meant to be set; left unset, the placeholders stay in the page
// and TMDB enrichment turns itself off. The relay override is for local testing only,
// so it defaults to empty rather than warning on every build. process.env outranks
// .env files in Vite, so it is only filled in when no env file sets it.
const fileEnv = { ...loadEnv('development', __dirname, 'VITE_'), ...loadEnv('production', __dirname, 'VITE_') }
if (!('VITE_TMDB_RELAY_URL' in fileEnv)) process.env.VITE_TMDB_RELAY_URL = ''

// The web tuner's version: package.json "tunerVersion", or the Docker build arg
// NOSTALGEX_TUNER_VERSION when it is set. Both builds write it into the tuner pages
// and Settings shows it. See scripts/tuner-version.mjs.
const tunerVersion = resolveTunerVersion(process.env, __dirname)

// `vite build --mode selfhost` is the Docker web tuner: the two tuner pages only,
// with every outside script and font vendored. See scripts/selfhost-build.mjs.
// Any other mode is the hosted site, unchanged.
export default defineConfig(({ mode }) => {
  if (mode === 'selfhost') {
    return {
      base: './',
      publicDir: false,
      plugins: [
        ...selfhostPlugins({ root: __dirname, version: tunerVersion }),
        tunerVersionPlugin(tunerVersion),
      ],
      build: {
        rollupOptions: { input: TUNER_PAGES },
      },
    }
  }

  if (mode === 'tuner') {
    return {
      publicDir: false,
      plugins: [hostedMarkerPlugin(), tunerVersionPlugin(tunerVersion), copyBrowserScripts(/^nostalgex-.*\.(js|cjs)$/)],
      build: {
        emptyOutDir: false,
        assetsDir: 'tuner-assets',
        rollupOptions: { input: TUNER_PAGES },
      },
    }
  }

  return {
    plugins: [hostedMarkerPlugin(), copyBrowserScripts(/^newsletter\.js$/), emitBlog(), emitBundles()],
    build: {
      rollupOptions: {
        input: {
          main: resolve(__dirname, 'index.html'),
          'apple-tv': resolve(__dirname, 'apple-tv.html'),
          privacy: resolve(__dirname, 'privacy.html'),
          terms: resolve(__dirname, 'terms.html'),
          support: resolve(__dirname, 'support.html'),
          'how-channels-work': resolve(__dirname, 'how-channels-work.html'),
          'self-host': resolve(__dirname, 'self-host.html'),
          plex: resolve(__dirname, 'plex.html'),
          jellyfin: resolve(__dirname, 'jellyfin.html'),
          emby: resolve(__dirname, 'emby.html'),
          roku: resolve(__dirname, 'roku.html'),
          '404': resolve(__dirname, '404.html'),
        },
      },
    },
  }
})
