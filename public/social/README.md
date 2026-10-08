# Nostalgex social media assets

Permanent, publicly downloadable images and videos for the social scheduler
(Buffer). Everything in this folder is served from the production site at
`https://www.nostalgex.app/social/<folder>/<file>` and must stay reachable at
that URL for the life of the post that references it.

Buffer and other social schedulers download the file by direct URL when they
publish, so if a URL changes or 404s the scheduled post fails.

## Convention

One folder per campaign, named `YYYY-MM-campaign`.

```
public/social/
  2026-10-scream/
    scream-01.jpg
    ...
  2026-10-montage/
    nostalgex-cable-montage.mp4
    cover.jpg
```

- `YYYY-MM` is the month the campaign goes out, not the shoot date.
- `campaign` is a short kebab-case slug (`scream`, `montage`, `holiday`, ...).
- Keep images as `.jpg` or `.png` and video as `.mp4`. These are the formats
  Buffer, Instagram, and X all accept without transcoding.
- Keep each file under ~100 MB so git stays usable. Instagram caps feed video
  at 60 seconds and 100 MB anyway.

## Current URLs

Images:

- `https://www.nostalgex.app/social/2026-10-scream/scream-01.jpg`
- `https://www.nostalgex.app/social/2026-10-scream/scream-02.jpg`
- `https://www.nostalgex.app/social/2026-10-scream/scream-03.jpg`
- `https://www.nostalgex.app/social/2026-10-scream/scream-04.jpg`
- `https://www.nostalgex.app/social/2026-10-scream/scream-05.jpg`
- `https://www.nostalgex.app/social/2026-10-scream/scream-06.jpg`
- `https://www.nostalgex.app/social/2026-10-scream/story-01-october-banner.jpg`
- `https://www.nostalgex.app/social/2026-10-scream/story-02-web-tuner.jpg`
- `https://www.nostalgex.app/social/2026-10-montage/cover.jpg`

Video:

- `https://www.nostalgex.app/social/2026-10-montage/nostalgex-cable-montage.mp4`

## Rules

- **Do not rename or delete a file that's referenced by a live Buffer post.**
  If a post is still scheduled, pending, or in a loop, the URL has to keep
  resolving to the exact same file. Rename or remove only after every post
  that uses it has gone out and you don't need it in the archive.
- **Do not put sensitive, private, or unreleased material in here.** Anything
  committed to this folder is served publicly from the production site the
  moment it deploys, and the folder is in `robots.txt` as `Disallow: /social/`
  but that only discourages well-behaved crawlers. Treat the folder as public.
- **Keep the content types right.** Vercel sets `Content-Type` from the
  extension, so `.jpg` serves `image/jpeg` and `.mp4` serves `video/mp4`. Do
  not rename an mp4 to `.mov` or a jpg to `.jpeg2000`.
- **Do not add these files to `public/sitemap.xml`.** They aren't pages and
  shouldn't be crawled or indexed as such.

## Adding a new campaign

1. Create `public/social/YYYY-MM-campaign/`.
2. Drop the final-cut images and video in with the names you want in the URL.
3. Commit, open a PR, and once it's on `main` and Vercel has deployed, the
   files are live at `https://www.nostalgex.app/social/YYYY-MM-campaign/<file>`.
4. Paste those URLs into Buffer when you schedule the posts.
