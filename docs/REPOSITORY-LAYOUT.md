# Nostalgex repository layout

This repo is intentionally **one project, three surfaces**. Everything that ships to users should live **in this GitHub repo** (`chadMueller/Nostalgex`). Do not treat another monorepo as the source of truth for Nostalgex.

## Surfaces

| Surface | Role | Typical entry |
|--------|------|----------------|
| **Public site** | Marketing + Plex connect; routes users into the tuner | `/` → `index.html` |
| **Web app (tuner)** | Full in-browser guide + playback | `plex-tuner.html` |
| **tvOS app** | Native Apple TV experience | Xcode: `Nostalgex/Nostalgex.xcodeproj` |

**User flow:** landing → connect Plex → **web tuner** on the same origin. The **tvOS app** shares `channels.json` and filter semantics; release it via Xcode / App Store Connect, not Vercel.

## Canonical paths (repo root)

| Path | Purpose |
|------|---------|
| `index.html` | Public landing (SEO, newsletter, footer, Plex link flow) |
| `plex-tuner.html` | Web app (guide, player, settings) |
| `channels.json` | Channel + bundle definitions (shared contract) |
| `public/channels.json` | Mirror/symlink for static hosting — keep in sync with root or generate in build |

**tvOS builds:** `Nostalgex.xcodeproj` runs a **Sync channel config** script that copies `channels.json` and `channels-memberships.json` from the repo root into every `.app` (simulator and Apple TV). After rule changes, build with destination **My Apple TV** (not only Simulator), then **Rescan library** on device.

To confirm the build picked up the current config, filter the Xcode console for `[Plex90] CONFIG:`. Against `channels.json` v24 the line reads:

```
[Plex90] CONFIG: bundled - v24, 121 ch, CH132=NETFLIX, CH65 title rules=31
```

(example from an older config; the channel count in a current build is 131, see below)

A stale build shows an older version number or a different channel name. Regenerate the expected values from the config rather than trusting this doc: the diagnostic is built in `AppState+Channels.swift` (`configDiagnostic`), and its two channel labels are **mislabeled** for historical reasons. `CH132=` actually prints the name of channel **id 122**, and `CH65 title rules=` counts `titleContains` on channel **id 65**. Channel `id` and channel `number` are **not the same value** for 81 of the 131 channels, so read these as ids: id 122 is CH121 NETFLIX, and id 65 is CH77 SUPERHERO MOVIES. `channels-memberships.json` also keys off `id`, never `number`.
| `CHANNELS.md` | Human-readable channel reference (keep near `channels.json`) |
| `api/` | Vercel serverless (e.g. newsletter `subscribe`) |
| `vercel.json` | Headers / routing; **web only** |
| `Nostalgex/` | Xcode project + Swift sources + assets |

The nested folder `Nostalgex/Nostalgex/` (app target inside the project) is normal for Xcode; **web files still live at the repo root.**

## Shared logic

- **Filtering / schedules:** Keep `plex-tuner.html` (JS) aligned with `Nostalgex/.../AppState.swift` (Swift). Shared data lives in `channels.json`; duplicated rule semantics should be updated together.
- **Secrets:** TMDB / Supabase / OMDb keys stay in ignored files (see repo `.gitignore`) and Vercel env vars — never commit real credentials.

## Deployment

| Surface | Builds where |
|--------|----------------|
| Web | **Vercel** — GitHub integration on this repo, `main` → production |
| tvOS | **Xcode** — Archive → App Store Connect |

Vercel must not attempt to compile the Xcode project.

## Working alongside other repos (e.g. Muell Haus assistant workspace)

If you keep a **separate checkout** of this repo inside a larger folder (for local convenience):

- Use a **normal clone** of `https://github.com/chadMueller/Nostalgex.git` next to other work, **or** a **submodule** if a monorepo truly needs a pointer.
- **Do not** `git add` the Nostalgex tree into a different repository’s history — it breaks Vercel’s Git link and duplicates source.

The Muell Haus `vibing` repo intentionally **gitignores** `My Assistant/projects/plex-90/` so a local Nostalgex folder does not get committed there by mistake.

## Restoring a full tree

If you only see part of the repo (e.g. Xcode project only), run `git pull origin main` from a clean clone of **this** repository.
