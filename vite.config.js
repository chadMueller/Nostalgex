import { resolve } from 'path'
import { readdirSync, mkdirSync, copyFileSync } from 'fs'
import { defineConfig } from 'vite'
import { writeBlogToDist } from './scripts/build-blog.mjs'

// The browser-loaded helper scripts (scripts/nostalgex-*.js|.cjs) are referenced
// by plex-tuner.html with a plain <script src>. Vite can't bundle non-module scripts,
// and they live outside public/, so the default build leaves them out of dist and
// production 404s them — which breaks the entire library load. Copy them into dist/scripts.
function copyBrowserScripts() {
  return {
    name: 'copy-browser-scripts',
    closeBundle() {
      const srcDir = resolve(__dirname, 'scripts')
      const outDir = resolve(__dirname, 'dist', 'scripts')
      mkdirSync(outDir, { recursive: true })
      for (const file of readdirSync(srcDir)) {
        if (/^(nostalgex-.*\.(js|cjs)|newsletter\.js)$/.test(file)) {
          copyFileSync(resolve(srcDir, file), resolve(outDir, file))
        }
      }
    },
  }
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

export default defineConfig({
  plugins: [copyBrowserScripts(), emitBlog()],
  build: {
    rollupOptions: {
      input: {
        main: resolve(__dirname, 'index.html'),
        'web-tuner': resolve(__dirname, 'web-tuner.html'),
        'apple-tv': resolve(__dirname, 'apple-tv.html'),
        'plex-tuner': resolve(__dirname, 'plex-tuner.html'),
        privacy: resolve(__dirname, 'privacy.html'),
        support: resolve(__dirname, 'support.html'),
        plex: resolve(__dirname, 'plex.html'),
        jellyfin: resolve(__dirname, 'jellyfin.html'),
        emby: resolve(__dirname, 'emby.html'),
        '404': resolve(__dirname, '404.html'),
      },
    },
  },
})
