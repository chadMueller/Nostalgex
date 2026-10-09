# Nostalgex blog

A tiny static blog served at `/blog` and `/blog/<slug>` on
[nostalgex.app](https://www.nostalgex.app). Nothing dynamic, no CMS, no
database. Each post is one Markdown file in [`content/blog/`](../content/blog)
and the site build renders them into pages that match the rest of the site.

## Adding a post

1. **Pick a slug.** Lowercase, letters and digits and dashes only. It becomes
   the URL path (`/blog/<slug>`) and the file name.
2. **Create `content/blog/<slug>.md`.** The slug in the frontmatter and the
   file name should match, but the frontmatter wins.
3. **Add frontmatter** (see [Frontmatter fields](#frontmatter-fields) below).
4. **Write the post in Markdown.** Standard GitHub Flavored Markdown.
   Headings, lists, bold/italics, blockquotes, links, inline code, and images
   all work.
5. **Drop any images in `public/blog/<slug>/`.** Reference them from the post
   as `/blog/<slug>/image-name.jpg`. They'll be served at that exact URL on
   production. See [Images](#images).
6. **Build the site locally with `npm run build`** and open
   `http://localhost:4173/blog/<slug>` with `npm run preview` to check
   it. The build also updates `public/sitemap.xml` with the new entry.
7. **Commit and PR.** When the PR merges to `main`, Vercel deploys and the
   post is live.

## Frontmatter fields

```markdown
---
title: "Public page title and <h1>"
description: "One or two sentences for the <meta description>, OG and Twitter cards."
slug: public-page-title-and-h1
date: 2026-10-08
# optional:
seo_title: "Shorter SEO tuned <title> if the display title is long or awkward in SERPs"
cover: /blog/public-page-title-and-h1/cover.jpg
cover_alt: "What the cover image shows, in one plain sentence"
author: "Chad Mueller"
updated: 2026-10-12
---
```

| Field         | Required | Notes                                                                     |
| ------------- | -------- | ------------------------------------------------------------------------- |
| `title`       | yes      | Rendered as the page `<h1>` and inside `<title>`.                         |
| `description` | yes      | Used verbatim for `<meta description>`, OpenGraph and Twitter cards.      |
| `slug`        | yes      | Lowercase `a-z0-9-`. Final URL is `/blog/<slug>`.                         |
| `date`        | yes      | ISO date (`YYYY-MM-DD`). Also used in Article JSON-LD and the sitemap.    |
| `seo_title`   | no       | Overrides the `<title>` only; the page `<h1>` still uses `title`. The build adds " \| Nostalgex", so keep it to about 48 characters. |
| `cover`       | no       | Absolute URL path to a cover image. Falls back to `/og-image-1200.png` for OG. |
| `cover_alt`   | no       | Alt text for the cover image, also used as `og:image:alt`. Leave it out and the cover gets an empty alt and the default card alt. |
| `author`      | no       | Renders a "By ..." byline. JSON-LD always credits Chad Mueller (the shared `#chad` Person) unless this names someone else. |
| `updated`     | no       | ISO date of the last real content change. Becomes `dateModified`, `article:modified_time` and the sitemap `lastmod`. Defaults to `date`. |
| `schema`      | no       | Extra JSON-LD nodes (a list). Each is merged into the page's single `@graph`, with any `@context` dropped. |
| `draft`       | no       | `true` keeps the post out of the index, `dist/`, and the sitemap. The file stays in `content/blog/` and is still validated by the build. |

The build script validates these and fails loudly if a required field is
missing, dates don't parse, or slugs collide. See
[`scripts/build-blog.mjs`](../scripts/build-blog.mjs).

## Images

Put images for a post in `public/blog/<slug>/`. Vite copies the `public/` tree
to `dist/` verbatim, and the files are then served at
`https://www.nostalgex.app/blog/<slug>/<file>`.

Reference them from the Markdown with an absolute path:

```markdown
![Nostalgex guide in October](/blog/90s-slasher-movies-halloween-marathon/hero.jpg)
```

Optimise before you commit (TinyPNG, Squoosh, ffmpeg, whatever's handy). PNG
or JPG is fine. Try to keep hero and cover images under ~400 KB and inline images
under ~200 KB.

If you set `cover:` in the frontmatter, the same image is used as the
OpenGraph/Twitter card image.

## What the build does

`npm run build` runs:

1. `npm run changelog:render` renders `content/changelog.json` into
   `index.html`.
2. `npm run blog:render` rewrites `public/sitemap.xml` to include each
   post. (Idempotent; the generated block is marked with
   `<!-- BLOG:START ... -->` and `<!-- BLOG:END ... -->`.)
3. `vite build` builds the main site pages into `dist/`.
4. The `nostalgex-blog` Vite plugin (in [`vite.config.js`](../vite.config.js))
   runs after Vite finishes and emits:
   - `dist/blog.html`, the blog index page, served at `/blog` by Vercel's
     `cleanUrls` (see below).
   - `dist/blog/<slug>.html`, one page per post.

   The plugin reads the hashed CSS and JS filenames Vite emitted into
   `dist/assets/` so blog pages load the same production bundle as the rest
   of the site.

## URL layout on Vercel

[`vercel.json`](../vercel.json) sets `cleanUrls: true`, so Vercel maps:

- `dist/blog.html` → `https://www.nostalgex.app/blog`
- `dist/blog/<slug>.html` → `https://www.nostalgex.app/blog/<slug>`

No new rewrites or redirects are needed, and the existing CSP applies.

## SEO defaults

Every post is rendered with:

- A unique `<title>` (uses `seo_title` if present, else `title`).
- A unique `<meta name="description">`.
- A `<link rel="canonical" href="https://www.nostalgex.app/blog/<slug>">`.
- OpenGraph `og:*` and Twitter `twitter:*` tags (image falls back to
  `/og-image-1200.png` if the post has no `cover`).
- `<meta property="article:published_time">` and `article:modified_time`.
- One JSON-LD `@graph` holding the `Article` (Person author `#chad`,
  publisher `#org`, `about` the app `#app`), a `BreadcrumbList` of Home, Blog
  and the post, the Person and Organization nodes, and a `FAQPage` built from
  the post's `## FAQ` section when it has one.

The `<title>` is the `seo_title` (or `title`) plus " | Nostalgex".

The index page gets one `@graph` with the `Blog` node (and a `BlogPosting`
summary per post) plus a Home > Blog `BreadcrumbList`, along with its own
canonical and OG/Twitter tags.

Each post ends with a shared CTA pointing at
[`/web-tuner`](https://www.nostalgex.app/web-tuner) and the Apple TV app.

The blog index and each post are added to `public/sitemap.xml` automatically.
Don't edit entries by hand inside the `<!-- BLOG:START ... -->` and `<!-- BLOG:END ... -->`
markers.

## Previewing locally

```bash
npm run build       # renders blog, builds site into dist/
npm run preview     # vite preview, served at http://localhost:4173
```

Open `http://localhost:4173/blog` for the index and
`http://localhost:4173/blog/<slug>` for a post.
