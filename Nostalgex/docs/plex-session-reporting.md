# Playback reporting and watched counts

## Current Settings

Apple TV: Settings > PLAYBACK & PICTURE > WATCH HISTORY > **SHOW NOW PLAYING ON <SERVER>** and
**MARK WATCHED ON <SERVER>**. The server name is Plex, Jellyfin or Emby.
Web tuner: Settings > PLAYBACK > **Show Now Playing** and **Mark Watched**.
The controls are hidden in the native demo and never report demo playback.

| Show Now Playing | Mark Watched | Behavior |
|---|---|---|
| Off | Off | No session reports or watched writes. Local watch accounting continues. |
| On | Off | Show the current program without an explicit watched update. |
| Off | On | Count qualifying watches without publishing a live session. |
| On | On | Show the current program and count qualifying watches. |

Both controls default off for a new install. This preserves the previous opt-in
default; it does not change an existing viewer's explicit choice. An old Report
Playback ON becomes ON/ON and OFF becomes OFF/OFF. An explicit new value,
including off, wins over the legacy key. The source has these independent
controls; the 1.0.26 release used the combined switch described in the historical
reference below.

Native migration materializes a legacy choice once, but leaves untouched new
install defaults absent so they do not overwrite delayed household iCloud values.
The complete pair syncs through the existing opt-in **SYNC WITH MY OTHER APPLE
TVS** setting. While sync is off, no cloud reads or writes run. Existing household
values retain precedence when enabling sync. The legacy key projects ON only
when both controls are ON, so an older client cannot turn a Now Playing-only
choice into permission to mark watched. Mixed-version and real multi-TV iCloud
behavior still need acceptance testing.

Changing a control applies to the current tracked program without retuning or
resetting its watch clock. Turning a choice off invalidates queued writes from
current and outgoing channels; turning it on again does not revive stale work.
Already-attempted sessions keep their exact final stops and required cleanup.
No pause UI or change to continuous channel playback is added.

## Qualification and reporting

Mark Watched uses the existing gates: join within the first 15% of the program
and accumulate at least 75% of its runtime in the tracker. Crossing the threshold
or stopping an eligible session evaluates the watch. Neither control changes
these thresholds. Existing buffering/recovery/sleep watch-clock accounting and
scrobble acknowledgement/retry behavior are separate follow-ups.

Plex Show Now Playing sends `PUT /:/timeline` with `ratingKey`, the metadata
`key`, player `state` and `X-Plex-Session-Identifier`, with no `time` or `duration`.
A final position-free `stopped` removes that session from Now Playing. Mark
Watched uses `GET /:/scrobble` with the bare rating key and library identifier.
Now Playing-only makes no scrobble or history-restoration writes and needs no
prior episode-state read. Mark-only episodes still capture the show's prior
Continue Watching membership before a possible scrobble.

Jellyfin/Emby reports have watch-state side effects. Before any session report or
watched write, the tracker must read the original UserData. If that read fails,
it skips reporting and watched updates for that program, without changing either
saved setting. Cleanup with no baseline is a no-op, never a position-zero reset.
For a readable baseline, qualifying Mark Watched is explicit even with Now
Playing off or beyond 90% of the runtime. Session stops are capped below automatic
completion so the server does not count the same watch twice.

## Continue Watching and cleanup

Reporting calls and cleanup share one serial queue, including outgoing channels.
Cleanup runs after attempted reports and marks. Transcode lifecycle calls remain
separate; turning reporting off never stops the media stream.

| Backend and prior state | Result |
|---|---|
| Plex Now Playing-only | No resume/history writes or cleanup needed. |
| Plex counted episode, show absent before tune-in | Remove its newly generated next-episode entry, with bounded lookup retries. |
| Plex show already present or prior membership unreadable | Preserve the existing entry rather than remove real viewing activity. |
| Jellyfin/Emby readable, no counted watch | Restore prior position, count, played flag and last-played state. A never-played item is reset through DELETE PlayedItems. |
| Jellyfin/Emby readable, counted watch | Restore position zero, Played true and prior count plus one. |
| Jellyfin/Emby unreadable | Skip session reports, watched writes and cleanup for that program. |

Failed reports back off their ten-second pulses, skipping 1, 2, 4 and up to 30
pulses; an answered report resets the backoff. Failure never changes a saved
setting. Exact final stops and cleanup remain eligible, including the native
background grace period. Restoration is best effort: network loss, force quit or
background expiration can prevent it. This is not a guarantee that server state
is immutable while a Jellyfin/Emby session is active or that cleanup always lands.

## Validation and remaining acceptance

Native and web tests use synthetic clocks and transports. They cover all four
modes, legacy migration, explicit-off precedence, delayed cloud delivery,
outgoing queue revocation, in-flight stops, position-free Plex requests,
next-episode cleanup and unreadable Jellyfin/Emby baselines without writes.
Both surfaces read `scripts/watch-cleanup-golden.json` for cleanup parity.

Physical Apple TV Settings layout/focus/VoiceOver, real browser integration,
live Plex/Jellyfin/Emby sessions and delayed persistence, failure cleanup, and
real multi-TV/mixed-client iCloud remain unverified for these controls. Earlier
fork measurements and the historical server measurements below do not validate
this exact integrated version. No app version or release claim is made here.

---

## Historical reporting design and measurements

The record below is preserved from main before the independent controls. Its
single-switch Settings paths, unreadable-state position-zero fallback, original
endpoint plan and shipped-version statements describe earlier behavior. Use the
current sections above for this version's controls and policy.

**Status:** Shipped in 1.0.9 (June 2026). Off by default since 1.0.11. Jellyfin and Emby use the same switch and the same 75% watch rule.  
**Why:** Keep watch history accurate while Nostalgex is in use. Rewatchables filters on real play counts from whichever server is connected.

Timeline reporting and scrobbling ship in the tvOS app, implemented in `Services/PlaybackTracker.swift`. Plex uses its timeline and scrobble endpoints. Jellyfin and Emby use their session reports, and the app reads `PlayCount` back when it loads the library. Rewatchables filters on `viewCount >= 3` for all three.

**Activity sync defaults to OFF.** The user turns it on in Settings under PLAYBACK & PICTURE (WATCH HISTORY). Nothing is reported until they do. Plays they already made in Plex, Jellyfin, or Emby still count toward Rewatchables, because those counts live on the server.

**Reporting never fills Continue Watching (2026-10-11).** Turning it on means "my server sees what's playing and a real watch counts", not "every channel I surf past lands in Continue Watching". Settings copy, both surfaces: *"Off by default. When on, your server sees what's playing and a film you watch most of counts as watched. Channel surfing never fills your Continue Watching."*

---

## Continue Watching guard

Code: `Services/PlaybackTracker.swift` + `Services/WatchStateGuard.swift` (tvOS), the tracker in `plex-tuner.html` + `scripts/nostalgex-watch-state.js` (web). The decision table is shared through `scripts/watch-cleanup-golden.json`; `WatchStateGuardTests` and `npm run test:watch-state` both read it. One switch, REPORT PLAYBACK TO <SERVER>, off by default, on both surfaces.

**Plex: position-free reports (2026-10-13, from community PR #18 by w6trp).**

1. Every timeline report is `PUT /:/timeline?ratingKey={rk}&key=/library/metadata/{rk}&state={playing|paused|buffering|stopped}` with the session in `X-Plex-Session-Identifier` and **no `time` or `duration`**. Plex lists the session in Now Playing at offset 0 and stores nothing, so a surf never reaches Continue Watching and needs no cleanup. `stopped` takes it out of Now Playing. The state follows the player (tvOS `timeControlStatus`, web video pause/play), so a pause shows as a pause.
2. A qualifying watch (entry in the first 15%, at least 75% active) is scrobbled with the bare rating key. Plex then adds the show's **next episode** to Continue Watching; the tracker removes it (`PUT /actions/removeFromContinueWatching?ratingKey={next}`) unless the show already had an entry before tune-in. For an episode the tracker reads `GET /library/metadata/{rk}` and `GET /hubs/continueWatching/items` before the first report to learn that; films are never read. The removal looks up to three times, a second apart, because Plex adds the entry about a second after the scrobble.
3. Nothing else is undone or restored on Plex: no unscrobble, no `/:/progress`, no prior-state capture for films.

**Jellyfin/Emby: restore.** Position-free does not work there (measured below), so reports keep the position and the tracker puts UserData back:

| Server | Before | Session | Cleanup |
|---|---|---|---|
| Jellyfin/Emby | never played | surfed | `DELETE /Users/{uid}/PlayedItems/{id}` |
| Jellyfin/Emby | anything else | surfed | `POST /Users/{uid}/Items/{id}/UserData` with the prior position, PlayCount, Played, LastPlayedDate |
| Jellyfin/Emby | known | counted | `UserData` position 0, Played, PlayCount = prior + 1 |
| Jellyfin/Emby | unreadable | either | `UserData` position 0 only |

The capture runs before the first report and the cleanup when the session ends (channel change, advance, disconnect, app backgrounded, reporting turned off), all through one serial queue so the cleanup lands after the last report. Transcode lifecycle calls (`Sessions/Playing/Stopped` with only a `PlaySessionId`) are separate and unchanged.

**Failures never change the setting.** A report that fails or times out makes the tracker skip more of its 10 second pulses (1, 2, 4 ... up to 30, about five minutes); any answered report resets that. Starts, stops, scrobbles and cleanup always go out. Only the user turns reporting off. Turning it off mid-program sends Plex one position-free stop (Now Playing clears) and restores Jellyfin/Emby UserData. On tvOS, backgrounding asks the OS for a few seconds so the final stop and cleanup reach the server (PR #18); a force quit or network loss can still drop them.

### Measured 2026-10-13

- Plex (real server): `PUT /:/timeline` with `state=playing` and no `time`/`duration` puts the item in `/status/sessions` with `viewOffset` 0, writes no resume point and adds nothing to Continue Watching; `state=stopped` with no time removes it from Now Playing. `GET /:/scrobble?key=/library/metadata/{rk}` is still a 404; the bare key works. An episode scrobble still adds the next episode; `removeFromContinueWatching` on it removes it.
- **Emby 4.10.1, position-free:** `/Sessions/Playing` without `PositionTicks` shows the item in Now Playing (Emby extrapolates the position itself) and writes no resume point, but the start report alone takes PlayCount 0 -> 1 and sets LastPlayedDate, and `/Sessions/Playing/Stopped` without `PositionTicks` marks the item **Played with PlayCount 2**. So Emby keeps the restore approach. Jellyfin shares the session code it was forked from and was not re-measured; it keeps the same approach. The item was put back with `DELETE PlayedItems` + `UserData` and read back identical.

### Measured 2026-10-11 (the restore design Plex used before position-free reports)

A real Plex Media Server, Emby 4.10.1.0, Jellyfin 12.2.0 (local, test library):

- Plex: `playing` timeline reports write `viewOffset` immediately (the item is in `/hubs/continueWatching/items` after the first one). `stopped` with `time=0` and `/:/progress` with `time=0`, `1` or `-1` change nothing. `/:/progress` with a real time sets that exact offset. `removeFromContinueWatching` hides the entry and keeps the offset. `/:/unscrobble` clears offset, `viewCount` and `lastViewedAt`. A scrobble clears the offset, but the next nonzero report writes a new one on the now-watched item; reports at `time=0` do not. An episode scrobble adds the show's next episode to Continue Watching within a second.
- **Plex `/:/scrobble` with `key=/library/metadata/{rk}` returns 404.** Only the bare rating key works. Both surfaces had sent the path form since 1.0.9, so no Nostalgex watch had ever been counted on Plex. Fixed.
- Emby and Jellyfin both increment `PlayCount` on the `/Sessions/Playing` start report (a 30 second surf counted as a play) and store the stop position as a resume point. `POST .../UserData` restores position, PlayCount, Played and a non-null LastPlayedDate exactly; it cannot null LastPlayedDate, which is why a never-played item is reset with `DELETE .../PlayedItems/{id}` instead. Both servers answer the `/Users/{uid}/...` routes (Jellyfin keeps them beside `/UserItems`). The transcode cleanup's `Sessions/Playing/Stopped` with only a `PlaySessionId` does not touch user data.
- Jellyfin 12.2 rejects `api_key` in the query string (401); the `Authorization: MediaBrowser ... Token=` header works on both.
- End to end, through the real tvOS tracker on a fake clock (`LiveContinueWatchingTests`, skipped unless `TEST_RUNNER_NOSTALGEX_LIVE_*` is set): a two minute surf on an unwatched Plex film (in Continue Watching mid-surf) and a counted Plex episode leave the Continue Watching row identical and the items' metadata back to their original state; the same surf plus a counted watch on Emby and Jellyfin leave Resume unchanged and UserData exact.

Not verified: Jellyfin/Emby **Next Up** after a counted episode (the Emby server measured has no TV library and the local Jellyfin test library has no shows). Next Up is a separate row from Resume on both, and a counted episode is a real watch, so it is left alone.

---

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

- `key` = `{ratingKey}` (the bare key; `/library/metadata/{ratingKey}` is answered with 404, measured 2026-10-11)
- `identifier` = `com.plexapp.plugins.library`

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

Reporting is **off unless the user turns it on** (Settings → CONNECTION → REPORT PLAYBACK; web tuner: Settings → PLAYBACK). Channel surfing tunes past far more programs than a user deliberately starts. Since 2026-10-11 the Continue Watching guard above means turning it on no longer buries the household's real Continue Watching row either. Consequence for the Rewatchables channel: `viewCount` stays as reliable as it ever was, but Nostalgex only adds to it for users who opted in.

---

## Future: Rewatchables channel

Once scrobble data flows, Plex `viewCount` becomes reliable. Rewatchables filters on **rewatch count** (`viewCount >= N`) — **not year range**. Channel rules already support `rewatched` / `watchedOnly`; they need accurate Plex stats first.

---

## Related

- Daily manifest scheduling (Nostalgex-internal freshness) is separate — does not use Plex `viewCount`
