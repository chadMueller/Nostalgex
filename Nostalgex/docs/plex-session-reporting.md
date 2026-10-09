# Plex Session Reporting & Scrobbling

**Status:** Shipped in 1.0.9 (June 2026). Off by default since 1.0.11. Jellyfin and Emby use the same switch and the same 75% watch rule.  
**Why:** Keep watch history accurate while Nostalgex is in use. Rewatchables filters on real play counts from whichever server is connected.

Timeline reporting and scrobbling ship in the tvOS app, implemented in `Services/PlaybackTracker.swift`. Plex uses its timeline and scrobble endpoints. Jellyfin and Emby use their session reports, and the app reads `PlayCount` back when it loads the library. Rewatchables filters on `viewCount >= 3` for all three.

**Activity sync defaults to OFF.** The user turns it on in Settings under CONNECTION (REPORT PLAYBACK). Nothing is reported until they do. Plays they already made in Plex, Jellyfin, or Emby still count toward Rewatchables, because those counts live on the server.

The rest of this document is the original design, kept because the gates, endpoints, and edge cases below are what actually shipped.

---

## Problem

Nostalgex is a read-only Plex client. Content plays continuously but Plex has no idea anything is being watched. Watch counts, On Deck, and Continue Watching all go stale. A future Rewatchables channel needs reliable watch data to mean anything.

## Goals

1. Report playback status to Plex server in real time (Now Playing)
2. Scrobble (mark watched) items the user actually watched
3. Keep Plex library stats accurate without inflating them from idle playback or late tune-ins

---

## What counts as "watched"? (hybrid rule)

**Both gates must pass:**

1. **Entry gate** — tune in during the **first 15%** of the simulated program  
   `entryFraction = seekOffset / (item.duration × 60) ≤ 0.15`

2. **Active time gate** — accumulate **≥ 75%** of the item’s total duration as **active watch time** from tune-in forward (only while playing on this channel, same session, not backgrounded)

Scrobble does **not** require reaching EOF — crossing 75% active while entry-eligible is enough.

**Examples:**

| Scenario | Scrobble? |
|----------|-----------|
| Join at 5%, watch 80% of runtime | Yes |
| Join at 5%, watch 50%, flip channel | No (below 75%) |
| Join at 90%, watch the last 10% | No (failed entry gate) |
| Join at 10%, watch to natural end | Yes |

The cable TV model still risks inflation if the app auto-advances while nobody is watching. Optional future: “Still watching?” after N auto-advances with no input.

---

## API endpoints

**1. Timeline update** — `PUT /:/timeline` (~every 10s while playing)

- `ratingKey`, `key`, `state` (`playing` / `paused` / `stopped`)
- `time`, `duration` (milliseconds)
- `X-Plex-Session-Identifier` — UUID per tune-in

**2. Scrobble** — `GET /:/scrobble`

- `key` = `/library/metadata/{ratingKey}`
- `identifier` = `com.plexapp.plugins.library`

Verify params against your Plex server before implementation.

---

## Implementation plan

**PlexAPIService:**

- `reportTimeline(...)` — PUT `/:/timeline`
- `scrobble(ratingKey:)` — GET `/:/scrobble`

**PlaybackTracker** (new service or AppState extension):

- Session UUID per tune-in
- Track `activeWatchTimeMs` per item / `loadGeneration`
- Set `eligibleEntry` from entry gate at `loadCurrentItem`
- Timeline timer ~10s while playing
- Evaluate hybrid rule on threshold, channel change, advance, disconnect

**AppState hooks:**

- `loadCurrentItem()` — start tracking
- `advanceToNextItem()` — evaluate outgoing item before advance
- Channel change / `disconnect()` — evaluate + invalidate
- Background — pause active clock, send `stopped`

---

## Edge cases

| Scenario | Behavior |
|----------|----------|
| Join at 80%, watch remaining 20% | No scrobble (entry gate) |
| Join at 10%, watch 80%, change channel | Scrobble on leave |
| Leave room, episodes auto-advance | May inflate — monitor; optional still-watching prompt |
| App backgrounded mid-item | `stopped` timeline; no scrobble unless 75% already hit |
| Network drop on timeline | Fail silently; retry scrobble if important |

---

## Opt-in default

Reporting is **off unless the user turns it on** (Settings → CONNECTION → REPORT PLAYBACK; web tuner: Settings → PLAYBACK). Channel surfing tunes past far more programs than a user deliberately starts, and reporting each one buries the household's real Continue Watching row. Consequence for the Rewatchables channel: `viewCount` stays as reliable as it ever was, but Nostalgex only adds to it for users who opted in.

---

## Future: Rewatchables channel

Once scrobble data flows, Plex `viewCount` becomes reliable. Rewatchables filters on **rewatch count** (`viewCount >= N`) — **not year range**. Channel rules already support `rewatched` / `watchedOnly`; they need accurate Plex stats first.

---

## Related

- Daily manifest scheduling (Nostalgex-internal freshness) is separate — does not use Plex `viewCount`
