# Web tuner feature reference

Entry point: `plex-tuner.html`. All features here are **web tuner only** unless noted.

---

## Backend support matrix

| Feature | Plex | Jellyfin | Emby |
|---------|------|----------|------|
| Sign in on the connect page | Connect with Plex | Connect with Jellyfin (password or Quick Connect) | Connect with Emby (password) |
| Channel guide + schedules | Yes | Yes | Yes |
| Video playback | Yes | Yes | Yes |
| Subtitles | No | Yes | Yes |
| Audio language selection | No | Yes | Yes |
| Playback scrobbling (mark watched) | Yes | Yes | Yes |
| Bookmark / saved auth | Yes | Yes | Yes |
| Sleep timer | Yes | Yes | Yes |
| Stream quality | Yes | Yes | Yes |
| Playback information | Yes | Yes | Yes |

One backend at a time. Jellyfin and Emby share the MediaBrowser code path; the few places Emby differs are listed under Emby below. Subtitles and audio language use the `MediaStreams` list and the `AudioStreamIndex` parameter, which both Jellyfin and Emby have (an external `.srt` came back as WebVTT from Emby 4.10.1.0). Plex handles these in its own player.

---

## Emby

Its own choice on the connect page: **Connect with Emby**, username and password (Emby has no Quick Connect). On nostalgex.app the address has to be https, like Jellyfin; in the Docker container a plain `http://` address works. Settings > SERVER says EMBY SERVER.

What is different from Jellyfin, mirroring `Nostalgex/Nostalgex/Services/EmbyAPIService.swift` (helpers and tests in `scripts/nostalgex-jellyfin-urls.js`):

- **Libraries** come from `/Users/{id}/Views`. `/UserViews?userId=` is Jellyfin's spelling and answers 404 on Emby 4.8.11, 4.9.5 and 4.10.1 (measured), so Emby never loaded in the web tuner through the Jellyfin option.
- **Retry after a failed direct play**: PlaybackInfo is asked with `EnableDirectPlay: false` and `EnableDirectStream: false`. With direct play off alone, Emby 4.10.1 still offers the file and no TranscodingUrl. Jellyfin's body is unchanged.
- **Hand-built HLS** carries a `PlaySessionId` (shared with Jellyfin since 2026-10-13; Emby refuses every segment without one).
- **Server name** comes from `/System/Info/Public`, because Emby's sign-in result has no `User.ServerName`.
- Same as Jellyfin: the `MediaBrowser` Authorization header, `AuthenticateByName` with `{ Username, Pw }`, `/Items`, the static `stream.mp4` URL, subtitle VTT, `/Users/{id}/...` watch state, and `DELETE /Videos/ActiveEncodings`, which ends an Emby encode within a second on its own.

**Sign-ins saved before the Emby option.** Emby users used to sign in through Connect with Jellyfin and were saved with `backend: 'jellyfin'`. They are migrated, not asked to sign in again: at start-up the tuner reads `/System/Info/Public` (Jellyfin says `ProductName: "Jellyfin Server"`, Emby has no ProductName and lists `LocalAddresses`) and switches the saved sign-in to `emby`. If that answer can't be read, a 404 on `/UserViews` followed by a 200 on `/Users/{id}/Views` does the same. The same check runs at sign-in, so Emby entered through the Jellyfin button (or the other way round) is saved as what it really is. Collections switched on before keep their keys (`jellyfin:<id>` for both).

---

## Sleep timer

Same as the Apple TV app (`SleepTimerLogic` and the SLEEP TIMER rows of the Now Playing panel). Code: `scripts/nostalgex-sleep-timer.js`, wired in the SLEEP TIMER section of `plex-tuner.html`.

- **Choices:** OFF, 15 MIN, 30 MIN, 1 HR.
- **Where:** SLEEP in the rail (desktop, TV browsers, tablets) and SLEEP TIMER in the phone drawer both open a small picker; Settings > General > PLAYBACK has the same choices inline. The rail and drawer show the time left (`29:41`; capped at `59:59`, so a 1 HR timer starts there and the half-width rail button never shows hours), the picker shows ACTIVE on OFF or the time left on the running choice, as on Apple TV.
- **At zero:** a "STILL WATCHING?" prompt with SLEEPING IN 0:20 counting down. Any click, tap or key keeps watching and uses the timer up (the key never reaches the shortcuts, so it can't change channel). Left alone for 20 seconds, playback stops the way tvOS does it: the server is told playback stopped, the video stops, the server's stream is ended, full screen closes and the guide shows. The picture says SLEEP TIMER ENDED / "Pick a channel to start watching again."; picking any channel, including the same one, starts again. Background library refreshes never restart it.
- Survives channel changes. Not saved: a reload turns it off, like a relaunch on Apple TV. A hidden tab's late timers are caught up when it is visible again.
- Works with clicks alone (TV Bro on Google TV), touch, mouse and keyboard. In full screen the prompt is drawn inside the full-screen element; iPhone's own player is closed first so the prompt can be seen.
- No keyboard shortcut.

---

## Stream quality

The Apple TV's STREAM QUALITY (`StreamQuality.swift`), for every channel: Auto, Maximum, High (1080p, 12 Mbps), Medium (720p, 4 Mbps), Low (480p, 1.5 Mbps). Code: `scripts/nostalgex-stream-quality.js`, wired in the STREAM QUALITY section of `plex-tuner.html`. The table is shared with the Apple TV through `scripts/stream-quality-golden.json`.

- **Where:** QUALITY in the rail (beside SETTINGS, the two share a row) and STREAM QUALITY in the phone drawer both open a small picker; Settings > General > PLAYBACK has the five choices inline. Saved in this browser (`nostalgex_stream_quality`). A change applies from the next program, on every channel.
- **Auto and Maximum change nothing.** The web has always asked for the top (Jellyfin and Emby 120 Mbps, Plex no ceiling), so those two levels leave every request exactly as it was. The Apple TV's Auto and Maximum ask for 4K at 40 Mbps and differ only in a remote direct-play ceiling the browser cannot know it needs.
- **High, Medium and Low add a ceiling.** Plex: `maxVideoBitrate`, `videoQuality`, `videoResolution` and `autoAdjustQuality=0` on the transcode URL. Jellyfin and Emby: `MaxStreamingBitrate` in PlaybackInfo and `VideoBitrate` and `MaxWidth` on the fallback URL.
- **Direct play:** a file whose known bitrate is above the level's ceiling goes through the server's transcoder, on any connection. The Apple TV only does that for remote Plex servers. A file with no known bitrate direct plays.
- Playback Information shows the level (High, Medium, Low) in QUALITY AT TUNE; at Auto and Maximum it shows what it always showed.

---

## Playback information

Same panel as the Apple TV app (PR #26: `PlaybackInformation.swift`). INFO in the rail (beside SLEEP, the two share a row), the I key, PLAYBACK INFO in the phone drawer, and Settings > General > PLAYBACK > Playback information > VIEW. Not in full screen: full screen is the browser's own. Refreshes every second while open; BACK, Escape or I closes it. Code: `scripts/nostalgex-playback-info.js`.

| Row | Web tuner value |
|-----|-----------------|
| BACKEND | Plex, Jellyfin or Emby |
| PLAYBACK | Direct Play or Server stream once the video element is playing, Loading before |
| QUALITY AT TUNE | What the browser asked for: Server default on Plex (no limit sent), Up to 120 Mbps on Jellyfin and Emby. The web tuner has no quality setting |
| RECOVERY REQUEST | Never shown: the web tuner has no 1080p compatibility retry |
| PLAYER SIZE | `videoWidth × videoHeight` of the video element, once playing |
| SOURCE METADATA | Video and audio codec from the library, allowlisted labels only (Plex items now keep `videoCodec` and `audioCodec` from the scan) |
| FALLBACK | No fallback used. / Server streaming was selected for this source. / Direct Play failed. Trying a server stream. / The player could not open the stream. Retrying it once. (an hls.js recovery) |

It never shows a URL, token, server address, session id or item id: the model only accepts fixed labels and bounded numbers. Each programme has a generation and each try at playing it an attempt; only the current attempt of the current programme can mark it ready, so a late event from an earlier programme or a replaced attempt can't describe the new one (tests in `web-tune-ownership-smoke.mjs`, with a negative control).

---

## Subtitles (Jellyfin and Emby, fullscreen only)

Toggle with the **C** key while in fullscreen. Off by default.

Subtitle track selection uses language preference (see Language settings below). The tuner:
1. Fetches the subtitle stream from Jellyfin or Emby as WebVTT (server transcodes any format)
2. Wraps it in a blob URL and attaches as an HTML `<track>` element
3. Clears on fullscreen exit

**Why fullscreen-only:** mirrors the tvOS behavior; subtitles in windowed mode are distracting at guide scale.

**Language matching:** Jellyfin stores track language as ISO 639-2/B 3-letter codes (`spa`, `eng`, `fra`). The tuner maps these from the ISO 639-1 2-letter user preference (`es`, `en`, `fr`) via a built-in lookup table. All Spanish regional variants (`spa`, `spa-419`, etc.) match the `es` preference.

---

## Audio language (Jellyfin and Emby)

Set in **Settings → General → Language → Audio language**. Default is Auto (server picks the default track).

When a preferred language is set:
- The matching audio stream index is passed to the server's `PlaybackInfo` endpoint for transcoded content
- For direct-play streams, `AudioStreamIndex` is appended to the stream URL
- Changing the language while watching restarts the current item with the new track

Uses the same ISO 639-1/639-2 mapping as subtitle matching.

---

## Language settings UI

Settings → General tab → LANGUAGE section.

| Setting | Key | Default |
|---------|-----|---------|
| Audio language | `plex90_audio_language` | `__system__` (Auto) |
| Subtitle language | `plex90_subtitle_language` | `__system__` (browser locale) |

Both are stored in `localStorage` and persist across sessions.

---

## Saved auth / bookmark support

Auth is persisted to `localStorage` under `plex90_saved_auth` (set on first connect, cleared on sign out). This lets users:
- Bookmark `plex-tuner.html` directly and land straight in the guide
- Close and reopen the tab without reconnecting

`web-tuner.html` (the connect/landing page) auto-redirects to `plex-tuner.html` if valid saved auth is found.

Saved auth shape:
- **Plex**: `{ backend, token, userToken, serverUrl, serverName }`
- **Jellyfin**: `{ backend, token, serverUrl, serverName, jellyfinUserId, jfUrl, jfUser }`
- **Emby**: the Jellyfin shape with `backend: 'emby'` (`jellyfinUserId` holds the Emby user id)

---

## Keyboard shortcuts

| Key | Action |
|-----|--------|
| Up / Down | Browse the guide. Down on the last channel wraps to channel one, Up on channel one wraps to the last |
| Enter | Tune the highlighted channel |
| M | Mute / unmute |
| F | Fullscreen |
| B | Toggle retro mode (4:3 + CRT scanlines) |
| C | Toggle subtitles (Jellyfin and Emby, fullscreen only) |
| G | Fullscreen + guide overlay |
| H | Open settings |
| Left / Right | Change channel (wraps at both ends). In Settings, switch tabs |

---

## Retro mode

Toggle with **B** or Settings → General → Display → Retro mode.

Applies: 4:3 aspect ratio, CRT scanlines, vignette, VHS tracking glitch animation.

Stored in `localStorage` as `plex90_retro_mode`.

---

## Channel bundles

Users can enable/disable individual channel bundles (and individual channels within them) in Settings → Channels. Config persisted in `plex90_channel_config`. A CONFIG_VERSION integer gates migrations — bump it when the default bundle set changes significantly.

---

## Franchises and collections

The same franchise channels and the same FRANCHISES / OTHER COLLECTIONS split as the Apple TV (1.0.29) and the Roku (1.0.8). Settings → Bundles has a FRANCHISES section and a MY COLLECTIONS section under the packages.

| What | Where it airs |
|------|---------------|
| The seven classics (Star Wars, Marvel, Harry Potter, Jurassic Park, Lord of the Rings, Mission: Impossible, Jason Bourne), from `channels.json` | CH 300-306 |
| Franchises found in the library, and the server's movie-series collections | CH 310-399, one pool of 90, numbered A to Z by name |
| Every other server collection (actors, directors, your own sets) | CH 400-499, the first 100 switched on |
| HIGH ROTATION | CH 500 and up |

- **One switch for the lot, one for each.** The FRANCHISES package switch heads the section: off, no classic, found franchise or franchise collection airs. Under it ADD ALL and REMOVE ALL (real buttons, since a TV browser has no keys) and one alphabetical list. A classic starts on, a found franchise starts off except STAR TREK and FAST & FURIOUS (`defaultOn` in `franchises.json`). Choices are kept by stable id (`dict:STAR WARS`, `tmdb:99999`) in `nostalgex_enabled_franchises` and `nostalgex_disabled_franchises`, never by channel number. A choice is kept for a franchise whether or not the library has it.
- **Found franchises** come from TMDB's own collections (a film's `franchiseID`, which needs enrichment) and the dictionary, `franchises.json`. Three films make a channel. What a classic covers joins that classic's pool, so The Mandalorian airs on CH 300; it does not join a pool another channel owns (a manifest lock or an exclusive rule).
- **Server collections** are classified FRANCHISES (movie series: a shared TMDB collection, a known name, a keyword like "saga", a repeated word or title prefix) or OTHER COLLECTIONS. A collection that is the same franchise as a classic or a found one is folded into it and listed nowhere else. A collection holding shows folds only into a franchise that airs those shows.
- **When more are on than fit** in CH 310-399, the ones with the most films stay, then the kept ones are numbered by name. Settings says how many are on but not shown.
- **One engine.** `scripts/nostalgex-franchise-builder.js` groups the library, `scripts/nostalgex-collections.js` classifies and numbers, `scripts/nostalgex-franchise-lineup.js` puts them together in the Apple TV's order. `scripts/franchise-lineup-golden.json` holds them to the Apple TV's answers; the Swift test (`FranchiseLineupGoldenTests`) wrote those answers from the app's own code, and the Roku tests read a copy. `npm run test:franchise-lineup` checks this engine, `npm run test:franchise-channels:browser` drives the page.

---

## Playback scrobbling

Reports "Now Playing" to the server and marks an item watched when the user has:
- Tuned in during the first 15% of the program (entry gate), AND
- Accumulated ≥ 75% of total runtime as active watch time

This keeps real Plex/Jellyfin play counts accurate, which feeds the REWATCHABLES channels (3+ views threshold). Works for both backends.

---

## Promo rows (in-guide)

Two promotional rows appear in the channel guide:
- **~67% down**: Buy Me a Coffee link (solo dev support)
- **~85% down**: Email signup (only shown if 20+ channels enabled, to avoid back-to-back placement)

These are inserted in `renderGrid()` and use `data-promo` attributes so they participate in keyboard navigation without interfering with channel tuning.
