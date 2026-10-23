# Porting from Nostalgex

Upstream: [chadMueller/Nostalgex](https://github.com/chadMueller/Nostalgex)
(MIT). Its tvOS app and web tuner share one channel config and one schedule
algorithm. This port is a third consumer of both.

## What comes from where

Upstream keeps its schedule and filter engines in two standalone JS modules,
which it holds identical to the Swift with golden vectors made by the real
Swift. Those modules are the port's source. They are small, self-contained
and already pinned to the Apple TV.

| Upstream | Here | State |
|----------|------|-------|
| `channels.json`, `channels-memberships.json` | `data/`, unchanged | symlinks to the repo root; `scripts/stage.sh` copies the files into the package |
| `scripts/nostalgex-daily-manifest.js` (Swift: `SchedulePoolOrdering.swift`, `DailyManifestScheduler.swift`) | `source/schedule/DailyManifest.brs` | ported, passing on device |
| `scripts/nostalgex-channel-filter.cjs` (Swift: `AppState+Channels.swift` `filterItems`) | `source/filter/ChannelFilter.brs` | ported, passing on device |
| `plex-tuner.html`: `getTimeFilteredPool`, bundles, `minItems` | BrightScript | with the guide |
| `plex-tuner.html` PIN sign-in and server discovery | `source/plex/PlexApi.brs` | ported; HTTPS only (below) |
| `QRCodeView` beside the PIN (`SettingsView.swift`): the plex.tv/link address with the code, 200 px, "SCAN TO CONNECT" | `source/util/QrCode.brs`, `addQr` in `components/ConnectView.brs` | ported; encoded on the TV (level M, as Core Image's), since a QR service would see the code. Every mask's matrix matches a reference encoder (`tests/gen-qr.mjs`, `tests/vectors/qr.json`). Upstream scanned it off a Streaming Stick Plus and signed in with a phone (Discussion #8, 2026-10-20) |
| `ServerPickerView` (`Plex90App.swift`): CHOOSE YOUR LIBRARIES after sign-in when the account lists more than one server; owned servers on, all of them when none is owned | `components/ServerPickerView.*`, `source/plex/ServerChoice.brs`, Settings › CONNECTION | ported; cases in `tests/ServerChoiceTests.brs`. Not yet seen on a TV (one-server account). Unlike upstream, no server is checked before it, as the maintainer asked |
| `PlexAPIService.bestReachableURI`: one verified address per server, best of local, remote, relay | `source/plex/ServerResolve.brs` | ported for the servers on, every address at once, an answer counting only if `/identity` names that server; saved, not re-checked on later launches. Cases in `tests/ServerResolveTests.brs` |
| `LoadingView`, `LibraryLoadStepRail`, `LibraryLoadPhase` (`Plex90App.swift`) | `components/LoadingView.*`, phases from `components/LibraryTask.brs` | ported; Collections is always a step, as every scan reads them |
| `SettingsPageView` order and `CollectionAccordionHeaderRow` (`BundleManagerView.swift`); `toggleBundle`, `rebuildLineupAfterBundleChange` (`AppState+Channels.swift`) | `components/SettingsView.*`, `rebuildForBundles` in `components/LibraryTask.brs` | ported; no rating, tips, stream quality or language rows. A package switch builds only its own channels, behind Settings; its pools matched a full rebuild's on the 43S45 |
| `PlayerView`, `MiniChannelStrip`, `NowPlayingPanel`, `SleepGracePrompt`, `SleepTimerLogic` | `components/GuideView.brs`, `components/MiniStripView.*`, `components/NowPlayingView.*`, `source/guide/SleepTimer.brs` | ported (differences below); sleep-timer cases in `tests/SleepTimerTests.brs` |
| `plex-tuner.html` `scanOnePlexServer` and helpers; `parseMusicVideoFromPlex` | `source/plex/PlexLibrary.brs` | ported; checked live against upstream (below) |
| The connect screens after the Apple TV sign-in redesign (upstream `signin-redesign`, `03f4cd3`): `SettingsView.swift`, `SignInFlow.swift`, `OnboardingStyle.swift` | `components/ConnectView.*`, `source/mediabrowser/SignInFlow.brs`, `components/MediaBrowserSignInTask.*`, `images/look/ob_*.9.png` | ported; `SignInFlowTests.swift`'s cases in `tests/SignInFlowTests.brs`, passing on device; walked and press-counted on a stick with `scripts/deploy.sh --tour`. Differences in [The connect screens](#the-connect-screens) |
| `plex-tuner.html` `fetchJellyfinLibraryFromServer`; sign-in, playback and stop after `JellyfinAPIService.swift`, `EmbyAPIService.swift` and the web connect page | `source/mediabrowser/`, `components/ConnectView.*`, `components/MediaBrowserSignInTask.*` | ported; the scan held to upstream's own function (`tests/vectors/mediabrowser.json`); BoxSets not yet. Differences and the TV results in [JELLYFIN-EMBY.md](JELLYFIN-EMBY.md) |
| MusicBrainz/Deezer music-video enrichment | — | not yet; affects music videos only |
| `scripts/nostalgex-enrichment.js` (Swift: `EnrichmentService.swift`): TMDB/OMDb enrichment through upstream's shared cache and relay (web, since 43f6ee7) | `source/enrich/` | ported; in a build only when `.env` turns it on (below) |
| `scripts/nostalgex-franchise-builder.js` and `franchises.json` (Swift: `FranchiseChannelBuilder.swift`): a channel per film series (since 43f6ee7) | `source/franchise/FranchiseBuilder.brs`, `data/franchises.json` unchanged | ported, passing on device |
| `AppState+Franchises.swift`, `materializeDynamicChannels` and `applyBundleFilter` (`AppState+Channels.swift`): franchise channels in the guide, and the franchise list under FRANCHISES in Settings | `source/guide/Franchises.brs`, `source/guide/FranchiseChoices.brs`, `components/` | ported, after the Apple TV app (below); cases transcribed from `FranchiseSettingsTests.swift` and `FranchiseNumberingTests.swift` |
| `scripts/nostalgex-collections.js`: server collections as channels from CH 500 (web, since 43f6ee7), collections of shows included (4b37674); MY COLLECTIONS in Settings (`plex-tuner.html` `renderCollectionList`) | `source/collections/Collections.brs`, `components/` | ported, Plex only; checked live against upstream (below). On both TVs (2026-10-16) the load reads 67 collections and lists 26; a CH 500 channel hasn't been seen |
| `FranchiseCollectionFold.swift` (`applyFranchiseFolds`, `AppState+Franchises.swift`): a collection that is a franchise the package carries folds into it | `source/collections/Collections.brs` | ported, after the Apple TV app (below); cases transcribed from `CollectionShowsTests.swift` and `FranchiseSettingsTests.swift` |
| Playback | BrightScript | Roku's Video node over Plex, Jellyfin or Emby; with the guide |
| The fallback ladder in `AppState+Playback.swift` (`fallbackToTranscode`, `retryLoad`, `handleWatchdogNoPicture`, `handleStarvation`), `PlaybackWatchdog`, `PlaybackStarvation`, `ChannelFailureRun`, `PlaybackFailure`, `PlaybackFailureCard`, `StreamFailureProbe` | `source/guide/Fallback.brs`, `components/GuideView.*`, `components/StreamProbeTask.*` | ported (issues #57 and #59; differences in [When a programme won't play](#when-a-programme-wont-play)); cases in `tests/FallbackTests.brs`; measured on a 43S45 against Emby |
| Guide remote: the vertical wrap in `ChannelGuideView.swift` (`66033f6`) | `source/guide/GuideNav.brs` | ported: Down off the last channel wraps to channel one, Up off channel one does not; cases in `tests/GuideNavTests.brs`. Not yet pressed on a TV |
| `SubtitleSelectionLogic.swift`; the SUBTITLES setting (`BundleManagerView.swift`) and CC toggle (`NowPlayingPanel.swift`) | `source/subtitles/`, `components/` | ported; cases transcribed from `SubtitleSelectionLogicTests.swift`. CC is the ★ key in fullscreen, and a row of the Now Playing panel. No language picker, as Plex sends one track (below) |
| Guide look: the Apple TV app's TunerView, InfoPanelView, ChannelGuideView, CRTOverlayView, StaticScreenView, PlayerView's ChannelOSD (upstream f51e72b) | `components/GuideView.*`, `images/look/` from `scripts/look-images.py` | recreated to its measurements (below); DM Mono and VT323 bundled (`THIRD-PARTY-LICENSES.md`). The logo, home-screen icons and splash are the nostalgex.app wordmark from upstream's `logo/png/` (`scripts/icons.sh`), as the maintainer asked ([Discussion #8](https://github.com/chadMueller/Nostalgex/discussions/8#discussioncomment-19003344)); the Apple TV app itself still shows its earlier lightning-bolt logo |
| RETRO MODE (`AppState.retroMode`, on by default; `BundleManagerView`) | `source/guide/RetroMode.brs`, Settings › RETRO MODE | ported: the guide's video cropped to 4:3 under the CRT overlay, full screen under it too, at upstream's `RetroLook` values (e48cdc1: scanlines 0.18, a darker vignette, more flicker and tracking) |
| `scripts/nostalgex-season.js` (Swift: `ChannelBundle.swift` `isInSeason`, `SeasonalPrompt.swift`, `GuideChannelOrder.swift` `seasonalLeadIDs`); `SeasonalInviteRow` | `source/guide/SeasonalPrompt.brs`, the row above channel one, the guide's lead, Settings' SPOTLIGHTED note | ported, `seasonStart` included (TIS THE SEASON from a week before US Thanksgiving); upstream's `scripts/season-golden.json` vendored and passing, plus cases transcribed from `SeasonalPromptTests.swift`. A switched-on seasonal package builds in every month, as upstream's `staticChannelIDsForPoolBuild` (8160f04) |

Start-up follows upstream's cached-library path. The last build's guide is
saved on the TV and shown at once when a fresh build would give the same
result: same local day, same UTC day (the pool shuffle's seed), same packages
and same build. A build is the app version and a hash of the zip's files
that `scripts/deploy.sh` writes into the manifest (`nx_build`), since a
sideload keeps the version:
installed over another build, one with new channel data or filter rules
would otherwise have kept the old one's results. The library is then refreshed in the background, and
the guide is swapped only if it changed.

The library itself is saved too, after the Apple TV app's
`LibrarySnapshotStore.swift` (`source/plex/LibrarySnapshot.brs`): each
server's items and collections in 2,000-item chunk files under
`cachefs:/nostalgex-library/`, with the meta file written last so a save cut
off part way leaves the last one readable. The build task keeps the library
it loaded in memory, and a package switched in Settings is built from that at
once, behind Settings, reusing every pool already in the guide; a franchise
or collection switch is built the same way on leaving Settings. Only a server
switch rebuilds the channels from the saved library, reading only a server it
doesn't have (Discussion #8, item 7). When the OS has cleared a server's save,
the next switch writes it again from memory, the enrichment cache with it.
Switches queued behind a build are answered by one more build, or none when
the guide already has them. A build whose pools match the guide on screen
on the same day keeps its schedules, and writes the saved guide and pools
only when they would change. A launch's background
refresh asks each server for its section list first and skips the scan while
the library signature (`LibraryChangeSignature.swift`: each section's
`updatedAt` and `contentChangedAt`) is unchanged and the save is under a day
old, as the Apple TV app's `refreshLibraryIfChanged` does. Saved items drop
the filter cache, the enrichment record and the artwork paths, which nothing
after the scan reads. Sign-out deletes them with the rest. The build task stays running with the
pools and is asked to re-check schedules every 30 seconds, as upstream's
`rebuildAllSchedules` runs, so time restrictions and day changes re-pack as
they would upstream; it schedules again only when the local hour or day has
moved, the only inputs besides the pools.

A launch whose servers all come from their saves reuses the last build's
filter results (kept in the saved pools file), as a package switch does,
except for channels whose rules read the clock to the day
(`addedWithinDays`, `releasedWithinMonths`); the file's key holds the month,
which is all the rest read.

Not ported from the schedule module: its manifest cache (`localStorage`).
The caller keeps a day's blocks in memory instead (`NxManifestCache`),
cleared on a library load as the web tuner's is and kept through a package
switch as the Apple TV's `DailyManifestStore` is.

A day starts at local midnight as `setHours(0, 0, 0, 0)` has it, also on the
days the clocks change, when the clock's time since midnight is an hour off
the real one (`NxLocalDay`). `lineup.json`'s `dst` cases hold the port to
upstream in America/New_York either side of each change. A day runs to the
next local midnight, the start of the day 36 hours after its start
(`NxStartOfNextLocalDaySec`), and yesterday is the day 12 hours before its
midnight (`NxPreviousLocalDayKey`), as upstream has had since `901a99a`: a
25-hour day has no empty last hour, a 23-hour day doesn't run into tomorrow,
and the day after one reads the right yesterday. Upstream's
`scripts/schedule-dst-golden.json`, vendored unchanged and read by
`tests/ScheduleDSTGoldenTests.brs` as `nostalgex-schedule-dst-smoke.mjs`
reads it, holds the port to that in ten zones, with each zone's offsets from
the tz database (`tests/gen-dst.mjs`).

Not ported from the filter module: `filterPool`'s `shows` summary and the
animation flags on its rows, which only devtools read. Two changes don't
affect results:

- The clock is an argument. Upstream reads `new Date()` for the current year
  and the `releasedWithinMonths` cutoff. The port takes the local date and
  time from `NxFilterClock`, so tests can pin it. JS's month arithmetic,
  where Mar 31 minus one month is Mar 3, is reproduced with day serials.
- Rule lists are lowercased and title patterns compiled once per channel
  (`NxFilterChannel`), and item fields once per item (`NxFilterItem`).
  Upstream redoes both on every call.

Franchise channels follow the Apple TV app, not the web tuner. The web tuner
doesn't call the franchise builder yet (upstream `docs/DEVLOG.md`: wiring waits
on its enrichment work), and the maintainer asked for the Roku to follow the
Apple TV app ([Discussion #8](https://github.com/chadMueller/Nostalgex/discussions/8#discussioncomment-18953180)). While the FRANCHISES package is on,
a film series the dictionary gives a classic (CH 100-106) joins that channel's
pool, The Mandalorian on STAR WARS for example, unless another channel owns the
item. Every other series the library has gets a switch in Settings under
FRANCHISES and, when on, a channel from CH 300. STAR TREK and FAST & FURIOUS
start on and the rest start off, as upstream's do. Each classic has a switch
too.

Server collections follow the web tuner's `nostalgex-collections.js`, and
`tests/vectors/collections.json` holds the port to it. The library load reads
each server's collections from its movie and TV sections. A collection with
3 or more films or episodes gets a row under MY COLLECTIONS in Settings. A
collection of shows counts every episode of each show the library has. Every
row starts off. A row that is switched on airs from CH 500, alphabetical, up
to CH 699. A collection channel belongs to no package, as on the web, and
airs its collection unshuffled. Not ported: Jellyfin and Emby BoxSets, and
the Apple TV app's split into FRANCHISES and OTHER COLLECTIONS
(`CollectionClassifier`), which the web tuner doesn't have either.

While the FRANCHISES package is on, a collection that is a franchise the
package already carries folds into it. It leaves the list and never gets a
channel. This follows the Apple TV app's `FranchiseCollectionFold`, since
franchises here do. The web tuner's `foldTarget` takes the stock classics
only, with the name match, the manifest overlap and 60% of the collection
already in the pool. The Apple TV app adds the found franchises (CH 300 up,
switched on or not) and the dictionary: enrichment's TMDB collection ids
first, then the collection's title. A collection that holds shows folds only
into a franchise that already airs an episode of each show. Given the stock
classics and no dictionary, the port answers as `foldTarget`, which the
vectors check. With the package off, nothing folds.

In a build without enrichment a film has no TMDB collection id, so only the
dictionary's film titles and name tokens place films, and no franchise is
found that the dictionary doesn't list. Text is walked by code point with letter ranges
written out, where upstream uses grapheme clusters and `\p{Alphabetic}` (the
file header has the details). No result in the golden file or the generated
edge cases differs.

Enrichment follows the web tuner's `nostalgex-enrichment.js`: the
local cache, then upstream's shared Supabase cache, then TMDB and OMDb
through upstream's relay, asked as `X-Nostalgex-Client: roku`, which the
maintainer agreed to ([Discussion #8](https://github.com/chadMueller/Nostalgex/discussions/8#discussioncomment-18953180)). Records attach as
`item.enrichment`, which the filter and the franchise builder already read.
The library load builds the guide from the caches first and rebuilds only if
the relay or OMDb added anything. Where it differs from upstream, and why, is
in the header of `source/enrich/Enrichment.brs`.

It is in a build only when `.env` sets `NOSTALGEX_ENRICHMENT=on` with
`NOSTALGEX_SUPABASE_URL` and `NOSTALGEX_SUPABASE_ANON_KEY`. `scripts/deploy.sh`
then writes them to `data/enrichment.json` in the zip, never in the repo.
Builds use the web tuner's Supabase project
([Discussion #8](https://github.com/chadMueller/Nostalgex/discussions/8#discussioncomment-18982798)),
and the relay is asked only on a cache miss, since OMDb's free tier is 1,000
requests a day across every client
([the same thread](https://github.com/chadMueller/Nostalgex/discussions/8#discussioncomment-18961197)).
Without that, rules that need enrichment behave as on an Apple TV with no
record: keyword and network matches don't fire, production companies match on
Plex's studio alone, and the IMDb gates leave FOREIGN FILMS and CULT CLASSICS
empty.

First run on a TV, 2026-10-15, with the Supabase project from the live web
tuner's meta tags: of 894 TMDB ids, 880 came from the shared cache and 14
through the relay as `roku`, none failed, and the remote step took 1.7 s.
FOREIGN FILMS appeared on screen. CULT CLASSICS stayed hidden, which is
`minItems` at work if fewer than three cult-keyword films have 30,000 IMDb votes.
OMDb found 0 candidates for its 2 gated channels, so the relay's `omdb/`
route is still untried. On a first launch the console prints `ReadAsciiFile:
file open for read failed` from `NxEnrichFileCache`. That is the firmware
noting the local cache file doesn't exist yet, and the code treats it as
empty.

**Cost on device:** about 0.16 ms per item-channel check (186,144 in 29.7 s on
a TCL 55R617). A 5,000-item library across 131 channels is roughly 100 s, so
the app filters in a Task node, and keeps the last build's guide and pools
between launches (`components/LibraryTask.brs`): a day-old guide is
rescheduled from the saved pools in seconds while the full build runs behind.

## When a programme won't play

After upstream's ladder (issue #57). A start that errors, or shows no
picture by its deadline (15 s direct play, 20 s a server stream, 40 s for a
4K one), moves down a rung at the same point in the airing: direct play to
the server stream; a server stream that errors gets one retry, unless
direct play came first; a server stream with no picture goes to the 1080p
stream (Plex 12 Mb/s with no HEVC, Jellyfin and Emby 8 Mb/s at 1920 wide).
When nothing is left, a card says why for five seconds, amber for the
server and red for the file or the TV, and the next programme starts. The
fifth failure in a row on a channel stops it with "Nothing on this channel
will play right now" until the viewer tunes; OK on it tries again.

Where it differs:
- A picture is the Video node reaching `playing`. Roku reports no decoded
  frames, so a stream that plays sound over black counts as a picture.
  Upstream's 4 s `play()` nudge isn't ported.
- The retry waits 3 s, not 300 ms, as the port's one retry always has.
- Roku's player gives no HTTP status (an HTTP error read `errcode` 2) and,
  with the server stopped, no error at all: it buffered until each deadline.
  So the server is asked, as upstream's `StreamFailureProbe` does, before a
  no-picture step and before the card: a refusal or no answer ends the
  ladder there, with that as the reason. An error steps down at once, so a
  refusal that lasts a moment still gets its retry.
- A server stream Emby couldn't make (its file gone) ended as `finished`,
  which the guide otherwise takes for a join past the end of a short file.
  It is asked about first, and hands over only if the server answers.
- Starvation after a picture: below.

Measured on the 43S45 against the lab Emby (2026-10-23), with 10-minute
clips, on this build:
- Emby stopped mid-programme: the programme already playing errored (-5,
  the connection cut mid-file), and its server stream ended unplayed with a
  probe answering -7 (couldn't connect). On the build before the rebase
  onto #80 it never errored, and buffered until its slot ended (a stall
  after the picture, issue #59); two runs on earlier builds errored as this
  one did. Either way each later start gave up after its 15 s deadline and
  a -7 probe, card "Can't reach your server", and the fifth stopped the
  channel. While stopped it tuned and probed nothing in 20 s; with Emby
  back, OK showed a picture in 0.8 s (0.9 s before the rebase). A build
  without the probe took about a minute a programme on the same test,
  through the 1080p stream, and blamed a slow server.
- A file taken off the disk: direct play errored (-1), the server stream
  ended unplayed, and the probe walked master 200, variant 200, segment
  500: card "Your server wouldn't start this one", then the next programme.
  Emby answers 500, not 404, for the missing file.
- The 1080p rung's request, sent to Emby for a 4K H.264 file, came back
  re-encoded to 1920x1080 4:2:0 with stereo AAC; a 4:4:4 file, on an
  earlier build, came back 4:2:0 as well. On the TV it wasn't reached by
  codec: the 43S45's player ran 4K 10-bit H.264, 4K AV1 and 4K 4:4:4 H.264
  as stored, position advancing (the screen wasn't seen).
- Not exercised on a TV: the retry (no first server stream errored), the
  40 s 4K deadline, and Plex or Jellyfin.
- Once, on the build without the probe and with Emby stopped, the render
  thread stalled for about ten minutes during a 1080p start (the guide's
  clock stopped; no BrightScript was running). It came back after Emby was
  started again, and didn't recur in the later runs.

**A stream that starves after its picture** (issue #59, after upstream's
`PlaybackStarvation` and `handleStarvation`). Once a start has played, the
playhead is read once a second: under 0.25 s of progress for 3 s is a stall,
and three stalls in 120 s, or one of 20 s, is starving (not in the first
second of progress, nor in an item's last 5 s). Direct play then moves to
the server stream and a server stream to the 1080p one, from where it got
to; the 1080p stream starving too gets "Your server couldn't keep up" with
no probe, upstream's first-ranked card. Each start gets a new monitor. As
upstream, the playhead decides, not `bufferingStatus`.

Measured on the 43S45 against the lab Emby (2026-10-23), on this build,
with Emby limited to one CPU through its cgroup's `cpu.max`, and a 10-minute
4K H.264 clip at 23.8 Mb/s with Opus audio swapped into the Lab, so it went
through the server re-encoded at 3840:
- Re-encoding that clip on one CPU, measured off the TV, ran at 0.63x real
  time at 4K and 0.67x at 1080p (two CPUs: 1.12x and 1.24x). Decoding the
  4K source is most of the work, so the 1080p rung barely helps on it.
- Started under the limit: the 4K stream starved at 105 s (2 stalls, the
  longest 20 s), the 1080p stream took over from 105 s and starved at
  235 s, card "Your server couldn't keep up", then the next programme.
- The limit lifted as the 1080p stream started (from 39 s, after the 4K
  one starved there): Emby re-encoded at 1920x1080, `-maxrate` 8 Mb/s, and
  it played on with no further stall for 3 minutes, position advancing.
- A programme already playing when the limit came on didn't starve: Emby
  had re-encoded the rest of it at full speed before the limit.
- Not exercised: a slow network (no root on the test box to slow it), so
  direct play starving, and Plex or Jellyfin.

Home leaves a server stream running until the next launch stops it (the
stop address is kept in the registry). An exit hook in `source/main.brs`
was tried and sent nothing, on Home or on Back: the app is gone before
the screen-closed event is acted on.

## The connect screens

Ported from upstream's sign-in redesign: the same screens, order, focus
defaults, words and colours, and the same number of presses or fewer
(measured on a Streaming Stick Plus, 2026-10-21, typing counted as 2 presses,
open and close, as upstream counts):

| Path | Apple TV | Roku |
|---|---|---|
| Plex (code entered at plex.tv/link) | 1 | 1 |
| Jellyfin, Quick Connect | 2 | 2 |
| Jellyfin, password | 8 | 8 |
| Emby, server found on the network | 7 (4 with no password) | 7 (4) |
| Emby, typed address | 11 (8) | 10 (7) |

The Roku counts in brackets, for a user with no password, follow from the code
(the tile press signs in); the test server had no such user.

Where the Roku does it differently:
- **Text fields.** The field is drawn as upstream's (a dark well with a cyan
  frame and glow when focused, a dim well with a grey edge when not); OK on it
  opens the TV's own keyboard (`StandardKeyboardDialog`), as a Roku channel
  can't take text any other way. Closing the keyboard moves on as on the
  Apple TV: its OK is upstream's Done (on the password it signs in), Back
  keeps what was typed and moves to the next control. Long text is cut at the
  end, not the start.
- **Shapes.** Rounded corners and glows are nine-patch art
  (`scripts/look-images.py`), tinted on the TV. Focus moves at once: the
  slab's growth isn't animated. Labels have no letter spacing on Roku, so
  captions and buttons sit a little tighter; the sign-in codes are spaced
  digit by digit.
- **The search.** One limited broadcast to 255.255.255.255:7359, for 3 s.
  Upstream also sends a directed broadcast to each interface's subnet. Roku
  has no Local Network prompt, so there is no second search after one.
- **No demo mode.** The store's test credentials stand in for it.
- **The logo** is the port's own wordmark.
- **The Plex library picker** starts on CONTINUE and has the connect screens'
  look, as upstream's now does.
- **Words** say Roku where upstream's say Apple TV, and "Wi-Fi" has a plain hyphen.
- **plex.tv unreachable at launch.** With a saved sign-in and the guide up, the
  launch check keeps its own line ("then press OK to try again"): that screen
  isn't the connect screen, and OK is its retry. Every Plex error during
  sign-in shows on the first screen, as upstream.

## The guide's look

The guide follows the Apple TV app's views at upstream f51e72b, measured at
1920x1080, where both draw 1:1. Since c2f32e6 upstream changed nothing on
that screen except its App Store rating banner, which a Roku has no use for.
What SceneGraph can't draw is an image from `scripts/look-images.py`: the
rounded outlines and their glow, tinted per channel with `blendColor`, the
badges' rounded frames, the CRT scanlines, vignette and tracking glitch, the
tuning snow and the OSD's gradient. The bolt, gear and star are drawn there
too, since SF Symbols can't be bundled and no bundled font has a star.
SwiftUI's letter spacing (`.tracking`) is a Label per character, which works
because both fonts are monospace.

RETRO MODE's 4:3 crop: Roku's Video only letterboxes, so in the guide it is
sized 16:9 at the box's height, centred on the box, with the panel drawn over
its left overflow and the right running off the screen. A 4:3 file fills the
box exactly.

Three differences are on purpose:

- On the Apple TV the grid's header overflows (220 + 12 + 4 x (425 + 14) =
  1988 px), which centres the rows about 30 px right of where
  ChannelGuideView's comments put them. The port keeps rows and header lined
  up at the 220 px column.
- Full screen follows PlayerView's remote: Left and Right change channel,
  Up opens the mini channel strip, Down the Now Playing panel, Back closes
  either, then returns to the guide. The panel has CC, auto subtitles, the
  audio tracks, RETRO MODE, the sleep timer and playback information; it
  leaves out stream quality, the language pickers and OPEN IN PLEX, which
  have nothing to act on here. OK flashes the OSD rather than leaving.
- An airing hands over as `advanceToNextItem` does: when its file ends,
  the next one starts from its beginning, so an episode running past its
  whole-minute slot plays to the end (`source/guide/Advance.brs`, cases in
  `tests/AdvanceTests.brs`). Unlike upstream, the clock takes over anyway
  five minutes past the slot, so a stream that never reports finishing
  can't hold the channel.

## Parity is proven, not eyeballed

When someone built a Fire TV fork, upstream checked its ordering and day-packing
against the JS "byte for byte". Its channel filter diverged on 22 channels, and
upstream asked for filter golden vectors before deciding where the fork would
live (upstream `docs/DEVLOG.md`, 2026-10). This port does the same from the start:

- `tests/gen-vectors.mjs` runs upstream's own engine from the repo the port
  lives in (`roku/..`; `$NOSTALGEX_DIR` overrides it) and writes
  `tests/vectors/schedule.json`. It carries upstream's Swift-made vectors
  verbatim, refusing to run if the JS no longer agrees with them, and adds
  its own: the RNG on its own, premiere slots (non-ASCII keys included), every
  ordering stage on a pool built to reach each branch, and twelve whole days
  through `packDay`, filler loop and both seams included. `tests/gen-filter.mjs`
  writes `tests/vectors/filter.json`: every real channel, plus synthetic ones
  from upstream's filter smoke test, over a library built from the channels'
  own rules (a match, a near miss and real manifest claims for each), under
  two pinned clocks, the second as an Emby library (Dolby Vision profile 5
  goes on no channel there). It reaches every reachable line of upstream's
  filter.
- Reaching a line is not telling two rules apart: at 805c33e the generated
  filter vectors passed with the old substring locks as well as the
  whole-word, own-title ones. Upstream's `scripts/filter-golden.json`,
  vendored unchanged as `tests/vectors/filter-golden.json` and read by
  `tests/FilterGoldenTests.brs` as `nostalgex-filter-golden-smoke.mjs`
  reads it, does: the old locks fail two of its cases (Santana on HIGH
  ROTATION, "Holidays (2016)" on FRIGHT NIGHT).
- Franchises are checked against upstream's own golden file,
  `scripts/franchise-golden.json`, copied unchanged by `gen-vectors.mjs` to
  `tests/vectors/franchise-golden.json` and read as upstream's
  `nostalgex-franchise-smoke.mjs` reads it. `tests/gen-franchise.mjs` adds
  `tests/vectors/franchise.json` from upstream's builder: non-ASCII titles and
  tokens, combining marks, full-width digits, case mapping across Latin,
  Greek, Cyrillic, Armenian and full-width scripts, and found names that only
  sort and upper-case right by code point.
- `tests/gen-enrichment.mjs` writes `tests/vectors/enrichment.json` from
  upstream's enrichment module: TMDB, OMDb and Supabase parsing over odd
  documents, work items, the OMDb gates from the real channels and the UTC
  quota clock. `tests/EnrichmentTests.brs` adds the cases of upstream's
  `nostalgex-enrichment-smoke.mjs` (batching, the caches and TTLs, the OMDb
  budget and backoff, end to end) over a stub network.
- `tests/gen-mediabrowser.mjs` lifts `fetchJellyfinLibraryFromServer` out
  of the repo's `plex-tuner.html` and runs it with `fetch` stubbed over the
  saved server answers in `tests/fixtures/mediabrowser-server.json`, writing
  `tests/vectors/mediabrowser.json`: the requests and items the port's scan
  must match.
- `tests/run.sh` runs upstream's franchise, filter-golden, collections and
  season smoke tests, regenerates every vector from the same tree as
  `data/`, then runs them in the off-device interpreter. Nothing is pinned: a
  change to the engine or the data that the port doesn't follow fails the
  run, and the `roku` CI job. `tests/tools/check-includes.py` fails it when a
  component calls an `Nx` function none of its scripts load, which
  BrightScript only finds when the call runs.
- `scripts/deploy.sh --test` runs the same suite on each TV in `ROKU_HOSTS`.
  **The TV run is the one that counts**, for the reason below.
- A divergence is a bug here, never a fix to the vectors. The vectors are
  never edited or committed; they always come from upstream's code.

## Checked live, against the real server

Vectors prove the logic. They can't prove that the TV reads Plex the way the
web tuner does, so `tests/live/` checks that against a real server:

- `tests/live/plex-link.mjs` links this computer to Plex by plex.tv/link code
  and keeps the token in `.env` (git-ignored, mode 600).
- `scripts/deploy.sh --live` puts `tests/live/LiveMain.brs` on the TV. It
  loads the signed-in library and prints fingerprints: a SHA-1 prefix per
  item, and one per channel for its pool and today's schedule. It prints no
  token, URL or metadata.
- `tests/live/compare.mjs` runs upstream's own loader, lifted unchanged from
  `plex-tuner.html`, against the same server, then upstream's filter and
  schedule at the TV's clock, and diffs the two.

The loader differs from upstream only where no result depends on it. Items
carry a server index, not the server's token, and no `serverID`: server
collections key items by the index instead. The display string `meta` is
built by the guide. Shows' episodes are fetched five at a time, as
upstream's are, and kept in show order; other requests run one at a time. Like upstream, it asks
Plex for `includeGuids=1`, which is what gives items a TMDB id for the
membership manifest, and episodes take their show's id.

`compare.mjs` runs upstream from the repo the port lives in (`roku/..`), the
same tree `data/` links to.

`tests/live/collections.mjs` checks server collections without a TV. It loads
the library with upstream's loader and reads the collections with upstream's
module, recording every response. It builds the list and channels as the web
tuner does, with every collection switched on. Then it replays the responses
through the port in the off-device interpreter (`tests/live/LiveCollections.brs`)
and diffs the two line for line. The recording goes to
`out/live-collections.json`. It checks how the port reads the responses and
the port's collection logic. It does not check the TV's own requests.

First run, 2026-10-16: 67 collections on one server, all in the movie
library, none holding shows. 26 had 3 or more films. 11 of those folded into
a classic, and 15 became channels from CH 500. The port matched line for
line. Collections of shows are checked only by the vectors and the transcribed
cases until a server has one.

The maintainer's device report (Discussion #8) was checked on both TVs on
2026-10-16, at `f237f6c`. With 70 channels built from 5,363 items, saving the
pools used 16% of the app's memory limit, and 35% while the saved guide was also
showing. The pools file was 30 MB, too big for `ReadAsciiFile`, because
`k <> "basePool"` never matched an iterated key (they come back lowercased)
and every pool was written twice. Fixed, it is 3.5 MB (1.6 MB with 39
channels), and restoring a day's guide from it took 5.6 s at 34% of the limit. Deep links sent over ECP for channels 1 to 8 tuned seven of them fullscreen; the one for 5 tuned nothing, unexplained. A
transcoded film joined 70 minutes in had Plex's transcode window at minutes
70 to 81, not at 0:00. Still unseen: the SERVER rows (both TVs reach one
server, so the rows don't show) and the sign-in code changing after 5 minutes.
`*` in the guide was pressed on a TV and did nothing, as intended.

[The Channel Store bar](https://github.com/chadMueller/Nostalgex/discussions/8#discussioncomment-18982978), on the 43S45 (Roku OS 16.0.4), 2026-10-16
at `6f05937` with 5,363 items on one server:

- **No rescan on a switch:** with the saved library there, a package switch
  read it in 0.9 s and asked the server nothing (a full read is 11 s, plus
  6 s of collections). A relaunch read it in 2.8 s after one section-list
  request. Once, the saved library and the enrichment cache were both gone
  between a relaunch and a switch, so that switch scanned: Roku may empty
  `cachefs:` whenever it wants the space. Six transcoded channels had been
  tuned in between.
- **Every package on:** 133 channels built in 123 s, franchises 13.6 s;
  saving the pools peaked at 22% of the app's memory limit (3.7 MB file). No
  crash.
- **Converted channels, joined mid-programme:** picture 1.8, 3.0, 3.5, 6.5,
  9.4 and 13.2 s after the press. The 13.2 s one spent 12.75 s in Roku's own
  VODStart, waiting for Plex's segments, not in the app.
- **First run, the default lineup (NOSTALGEX only, 19 channels):** guide on
  screen 37.7 s after a plex.tv/link sign-in, at `8974f6e`: library read 7.7 s
  (5,363 items), collections 4.7 s, channels built 16.8 s. A larger lineup,
  70 channels with FRANCHISES on, took 131.3 s on the 55R617.
- **Channel build, at `3c1e79f`:** the same 39-channel lineup built in 35.3 s
  before and 11.4 s after, from the saved library on the 43S45. Off-device,
  `tests/bench/` over the same 5,363 items built all 131 channels 3.7x faster,
  every pool identical. The franchise step (about 15 s) is now the larger part.
- **Franchise step:** off-device, `tests/bench/run.sh franchise` over the same
  library ran it 24x faster (189.3 s to 7.7 s), all 27 franchises, their
  movies and shows, and every stock pool identical. On the 55R617 it took
  0.7 s, down from about 15 s.
- **First run, FRANCHISES on (61 channels), at `5a0cead`:** guide on screen
  102.6 s after sign-in on the 55R617, down from 131.3 s: library read 57.7 s
  (one request timed out and was retried), collections 4.0 s, 61 channels
  built 26.7 s, franchises 0.7 s.
- **Server check, at `db64ce2`, on the 43S45:** 51 ms after a plex.tv/link
  sign-in, guide on screen 24.2 s after it; the library was still saved, so
  not a first run.
- **Package switch, at `fb27b56`, on the 43S45:** an 8-channel package built
  in 9.4 s on and 4.7 s off, behind Settings, its pools fingerprint equal to a
  full rebuild's both ways.
- **This round, at `a18a256`, on the 43S45 (2026-10-19), 5,367 items:**
  - Launch: the saved pools up in 0.9 s (AppLaunchComplete 1.9 s), tomorrow
    added 0.7 s later. A relaunch reused all 19 channels' filter results:
    built in 18 ms against 6.2 s, fingerprint `41ca239378f2` both ways.
  - Six packages on, one at a time (19 to 82 channels): 6.4 to 12.0 s each,
    scheduling 0.7 to 1.9 s. ADVENTURELAND off and on three times: memory 36
    to 39%, off 5.7 s (built in 48 ms), on 9.3 s.
  - A franchise switched on in Settings built in place in 6.1 s on Back, the
    guide still on CH 2. Seven switches in a row built once.
  - Every test passed on the TV.
- **Collections step, on the 55R617:** 457 s at `d2e276d`, where the progress
  screen rebuilt itself on each of three updates per collection (25 collections'
  updates took 66 s, then 136 s, against a 1.1 s fetch); 10.3 s once a change
  that keeps the layout only updates the detail line and bar.

## BrightScript notes

- **64-bit math.** The RNG and premiere hash are unsigned 64-bit in Swift.
  BrightScript's `LongInteger` is signed, has no XOR, and its `<<` / `>>` gave
  wrong answers in the off-device interpreter (`>> 30` of a negative value
  returned `1`; `<< 13` truncated to 32 bits). The port relies only on wrapping
  multiply and add, `and` / `or` / `not`, and integer division, and builds the
  logical shifts and XOR from those (`NxShl`, `NxShr`, `NxXor`). The stock
  `brs` package is worse: it misparses `&h…&` literals and doesn't wrap. Use
  `@rokucommunity/brs`.
- `m` is the implicit `this` object, so a variable or parameter named `m`
  is an AA, not what was assigned to it. `pos` is a reserved word.
- Regex patterns must mean the same in PCRE (device) and JS (interpreter):
  no `\z`, so "absolute end" is `(?![\s\S])`.
- `ParseJson` keeps key case on the TV, so Plex's `guid` (a string) and
  `Guid` (a list) stay two keys; read them by exact key (`raw["Guid"]`). The
  off-device interpreter folds them into one, so its run skips the vectors
  that hold both, and the TV run checks them.
- AAs ignore key case unless `SetModeCaseSensitive()` is called. Swift groups
  shows case-sensitively ("The Wire" and "the wire" are two groups), so every
  AA keyed on titles or ratingKeys sets it.
- Key case in AAs you build: the TV stores an unquoted literal key lowercase
  (`{ imdbRating: x }` holds `imdbrating`), and the off-device interpreter
  does the same for a key first set with a dot. Lookups ignore case either
  way, but `FormatJson`, `Keys()` and `for each k in aa` show it, so where
  case reaches JSON the port quotes the key (`{ "imdbRating": x }`) or sets
  `aa["imdbRating"]`, and a loop compares `LCase(k)` (`k <> "basePool"` never
  matched, and doubled the saved pools file).
- `ReadAsciiFile` returns "" with "file is too big" for a 30 MB file;
  `roByteArray.ReadFile` then `ToAsciiString` read it in under a second.
- The off-device interpreter's `CSng()` truncates to a whole number. On the
  TV, a modulus done in Doubles through `Int()` gave wrong values where the
  same in `LongInteger` was right; keep exact integer arithmetic in
  `LongInteger`.
- `Abs()` returns a Float. Array indexes must be `Integer`, not `LongInteger`.
- A `for each` nested inside a `for each` over the same array shares its
  place on a TV, so the outer loop ends when the inner one does. The
  interpreter keeps them apart. Loop the inner one by index (`b9543c7`).
- The TV's compiler rejects a statement that calls a method on a function's
  result, `F(x).list.Push(y)` (compile error `&h02`, and the app drops back to
  the home screen). The off-device interpreter accepts it, so assign the
  result first: `b = F(x)`, then `b.list.Push(y)`.
- Every Task node already has a `state` field (`init`/`run`/`stop`/`done`).
  An interface field of the same name never reaches its observer, so use
  another name (`status`).
- `LongInteger / Integer` divides as integers, so a fraction comes out 0;
  convert to a Float first. Node fields such as `translation` reject a Double,
  so use `!` (Float) variables for anything a node receives.
- Plex: send one `X-Plex-Session-Identifier` per install with every stream.
  With a new one per stream, Plex refuses to restart a file for 2-4 minutes
  after stopping it (HTTP 400), which breaks flipping back to a channel. It
  also refuses a second stream from a device while one runs, so the app stops
  the last stream (and remembers it across launches) before starting the next.
- Plex's transcode playlist (`start.m3u8?offset=N`) spans the whole file
  from 0:00 whatever the offset: offset=1800 gave 5758 one-second segments
  for a 96-minute film (2026-10-16). Transcoded streams need `PlayStart`
  set to the offset, as direct play does, or they start from 0:00.
- Plex also fixes its transcode decision for a playback session the first
  time it sees it, so the session ID is per decoding profile. On a TV that
  decodes HEVC, `X-Plex-Client-Profile-Extra` with
  `add-transcode-target-codec(...videoCodec=hevc)` makes Plex copy HEVC rather
  than re-encode it. An equivalent hint for AAC audio was ignored, so audio
  still converts to MP3, which costs little.
- Plex subtitles: `subtitles=auto` with
  `add-transcode-target(type=subtitleProfile&…&container=webvtt&subtitleCodec=webvtt)`
  sends text subtitles as a WebVTT rendition rather than burning them in.
  Plex offers only the track the Plex account has selected for the file. It
  ignores `subtitleStreamID` on the request, and choosing a track is a PUT to
  `/library/parts` that changes the account's selection, so the app doesn't.
  Image subtitles (PGS, VobSub) are still burned in. `/library/streams/<id>`
  serves external subtitle files only (501 for embedded ones), and
  direct-played files get no subtitles.
- Roku draws subtitles only while the TV-wide caption mode is On. The app
  turns it on while they show and puts it back after, saving the old value
  (`captionModeBefore`) so a launch after leaving with Home restores it.
- `LCase` on the TV isn't JS `toLowerCase` beyond ASCII. It leaves
  full-width letters (`Ｓ`) and Roman numerals (`Ⅻ`) alone, maps `Έ` to `ҽ`,
  and never gives a final `ς`. The off-device interpreter uses JS's, so it
  hides this. Text that has to match upstream goes through
  `NxFranchiseLower`.
- `step` is a reserved word, like `pos`. `run` passes the off-device
  interpreter but not a TV, which takes it for the builtin `Run()`: a
  parameter of that name stopped a 43S45 compiling the app ("Builtin
  function call expected"). `tests/run.sh` fails on it.
- `cachefs:` is a cache: on a 43S45 it was emptied between two runs of the
  app, saved library and enrichment cache together, and on a Streaming Stick
  Plus twice in 25 minutes while the app ran. Roku keeps it in RAM unless
  there is an SD card, so a restart empties it too. Everything kept there
  must be rebuildable.
- `Int()` takes a Float: a Double past 2^24 is rounded to float32 first
  (Jellyfin dates 47 s off on a stick). `NxFloorDouble` floors exactly.
- `roUrlTransfer` is task-only on Roku OS 16: created on the render thread
  it is `invalid` (OS 15 allowed it), so `NxUrlEncode` encodes by hand.
- System fonts go on a Label's `font` attribute. A `<Font uri="font:…">`
  child draws nothing: the label goes blank with no error.

## Alternatives considered

- **[Tunarr](https://github.com/chrisbenincasa/tunarr):** builds channels server-side and shows
  them through Plex's own Live TV guide. It works on any Plex client with no
  app, but it has Plex's look, not Nostalgex's. That look is the reason this
  port exists.
