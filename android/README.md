# Nostalgex for Android TV

A native Android TV app (Kotlin, Compose for TV, Media3 ExoPlayer), built for
the NVIDIA SHIELD first, for Plex, Jellyfin and Emby. There is no store
listing; it installs over `adb`.

## What it does today

- The Apple TV's connect screens: CONNECT TO PLEX, or JELLYFIN or EMBY.
  Plex signs in with the code and a QR for plex.tv/link, then asks every
  address of every server at once and takes the best that answers as soon as
  nothing better can (home network, remote HTTPS, remote plain, relay), turning
  down an address that answers as another Plex server. Jellyfin and Emby
  find the server on the network (UDP 7359) or take a typed address, then
  sign in the shortest way the server allows: Quick Connect when Jellyfin
  has it on, WHO'S WATCHING? tiles when the server lists its users, else a
  name and password.
- Plex reads the servers chosen at sign-in into programmes, in library
  order. When the account reaches more than one server, sign-in asks which
  (the Apple TV's server picker), with your own servers ticked, or every
  server if you own none. Jellyfin and Emby read the one server signed
  in to, as the web tuner's `fetchJellyfinLibraryFromServer`. The library is
  saved, so a launch opens on it and reads the servers again behind the guide.
  While the guide is up it reads them again every 6 hours, as the Apple TV
  does; on Plex a library whose sections haven't changed is skipped until its
  last scan is a day old.
- Builds the channels from the root's `channels.json` and
  `channels-memberships.json` (symlinked into `app/src/main/assets/`), with
  the package you had on, or the packages with content if that one fills
  nothing.
- Airs the Apple TV's schedule: the same programme at the same minute.
- Plays through ExoPlayer: the file as stored (direct play) first, the
  server's HLS transcode if that fails or a track has no decoder on the
  device. On Jellyfin and Emby the server is asked how to stream it first
  (PlaybackInfo, as on the Apple TV): it copies or re-encodes the video, burns
  in a forced subtitle track in your SUBTITLE LANGUAGE, and the stream carries
  the audio track in your AUDIO LANGUAGE. A burned-in stream is used only once
  its first segment is served; a server that refuses it gets the film without
  the forced lines. The hand-built stream is used if it fails to answer in 12 s. The stream carries no start time and the player
  seeks, as on the Apple TV.
- Opens on the Apple TV's tuner, at its measurements: the info panel for the
  focused channel, the picture in a 4:3 box, and the timeline guide below
  (two hours, a half hour at a time with Left and Right, the now line, the
  bolt on the live row). OK on the live row goes full screen, OK on another
  tunes it; Back goes to the live row, then leaves the app.
- Full screen: Left and Right change channel, OK shows the channel banner,
  Up opens the mini channel strip and Down the Now Playing panel (CC,
  SUBTITLE LANGUAGE, AUTO SUBTITLES, audio tracks, AUDIO LANGUAGE, RETRO MODE,
  STREAM QUALITY, the sleep timer and PLAYBACK INFORMATION), Back closes a
  picker, then the overlay, then returns to the tuner.
- GUIDE TEXT SIZE (NORMAL or LARGE) under PLAYBACK: bigger programme titles,
  times and channel names in the guide, the Apple TV's and Roku's LARGE sizes;
  rows and blocks never move.
- RETRO MODE's look: scanlines, flicker, vignette and the tracking line over
  the picture, and tuning snow when a start takes longer than 0.75 s.
- Settings (SETTINGS above the guide, or the top of the package sidebar that
  Left opens at the guide's first half hour), as the Apple TV's rail: PLAYBACK &
  PICTURE, CHANNELS & BUNDLES (CHANNEL PACKAGES with an amber count of channels
  still short of content, MISSING CHANNELS with each one's rules in plain words
  and how many titles match, FRANCHISES, MY COLLECTIONS and WATERSHED), SERVERS &
  ACCOUNTS (servers,
  libraries, RESCAN LIBRARY, DISCONNECT) and ABOUT. Up and Down on the rail swap
  the pane; Right or OK goes into the rows; Left comes back to the category;
  Back steps out one level at a time. The sidebar jumps to a package's first
  channel, in guide order.
- Franchises and server collections, as on the Apple TV 1.0.29. The FRANCHISES
  page: the package switch, ADD ALL / REMOVE ALL, and one A to Z list of the
  classics (CH 300-306), the film series found in the library and the server's
  franchise collections (COLLECTION). While the package is on, a classic also
  carries the shows the dictionary puts on it (The Mandalorian on STAR WARS),
  and a server collection that is a franchise already on offer folds away. MY
  COLLECTIONS lists the other collections, saying when one is mostly on another
  channel already. Found franchises and franchise collections share CH 310-399,
  other collections CH 400-499; every collection starts off. Collections are
  Plex's from its movie and TV sections, and a Jellyfin or Emby server's
  BoxSets, read with every library load and rescan. Without enrichment no film
  has a TMDB collection id, so only the dictionary's titles find a franchise.
- Library selection: after sign-in, a server with more than one library offers
  CHOOSE YOUR LIBRARIES; a library left off (there or later in Settings) is
  never scanned. A Plex music library adds nothing on either app (Plex lists
  artists, with no running time), so switching it off only saves its requests.
- The loading screen's step rail, with what the scan is reading and a progress
  bar, and START OVER (it asks first) for the whole load. After two loads in a
  row that never finished, the next launch asks LOADING DIDN'T FINISH: TRY
  AGAIN or START OVER. A scan that goes quiet for a minute offers STOP WAITING,
  and one quiet for 210 s is abandoned on its own; either way the libraries
  already read whole make the guide, with the pages already read of a Jellyfin
  or Emby movie library (which reports after every page, as Plex does), and
  with none the load says why. The TV stays awake on the loading screen.
- WATCH HISTORY under PLAYBACK & PICTURE, both off by default: SHOW NOW
  PLAYING ON PLEX (or Jellyfin, Emby) tells the server what is on, and MARK
  WATCHED counts a programme tuned in during its first 15% and 75% watched.
  Nothing is left in Continue Watching, Resume or On Deck: Plex reports carry no
  position, and a Jellyfin or Emby item's watch state is read first and put
  back when its session ends (`scripts/nostalgex-watch-state.js`).
- The seasonal invite: while SCREAM (October) or TIS THE SEASON (from a week
  before US Thanksgiving to December 31) is in season and switched off, a row
  above channel one offers it. YES, TURN IT ON adds the package; NOT THIS YEAR
  is quiet until the season ends; DON'T ASK AGAIN is for good. A seasonal
  package is never switched on any other way (`scripts/season-golden.json`).
- demo mode, under EMBY on the first screen: the Apple TV's five sample
  channels with no account or server, every channel playing Apple's public
  sample stream at the clock's place in the programme. Not saved: the next
  launch, or DISCONNECT, goes back to the first screen.
- WATERSHED (off by default): R, NC-17 and TV-MA titles wait for 9 PM on every
  channel but VHS VAULT, which holds its own. A channel with nothing else to
  show says BROADCASTS WILL RESUME AT 9 PM, and comes on at 9.
- TMDB and OMDb enrichment, in a build that turns it on (below): the keywords,
  networks, production companies and IMDb ratings that channels like TEEN
  MOVIES, MUSICALS, TRUE CRIME and CULT CLASSICS match on. A full load waits on
  it as the METADATA step; a launch from the saved library builds the guide from
  the local cache and asks the network behind it. Without it, those rules match
  only on the server's own genres, as on an Apple TV with no enrichment.

## Differences from the Apple TV app

The aim is the Apple TV app, screen for screen. Where this app differs, it is
listed here.

Everything on the Apple TV is ported, apart from what is listed below as different.

Different on purpose, because the Apple TV's version has no counterpart here:
- No SUPPORT NOSTALGEX (App Store ratings and tips), no NOSTALGEX PRO (hidden on
  the Apple TV too) and no iCloud sync.
- The Settings rail shows each category's pixel icon where the Apple TV uses an
  SF Symbol, which Android doesn't have.
- No SCAN MY COLLECTIONS button: collections are read with every load and
  RESCAN LIBRARY, as on the Roku.
- The loading screen's rail is LINEUP, LIBRARY, COLLECTIONS, METADATA, CHANNELS,
  READY (METADATA only in a build with enrichment): the Apple TV's MUSIC step has
  no work behind it here yet.
- Enrichment asks the Nostalgex relay as `X-Nostalgex-Client: android`. Until
  the deployed relay accepts that value it answers 403, and the first 403 ends
  the TMDB and OMDb steps for that load (as on the Roku), so the app runs on
  the shared Supabase cache alone and fetches nothing new.
- No reinstall check: Android deletes an app's data with the app (and backup is
  off), so a reinstall can't find an old sign-in the way tvOS's keychain can.
- The Apple TV's fixes for its own player don't apply: getting 4K Dolby Vision
  MKVs and their EAC3 audio through Plex's HLS repackaging, ORIGINAL (LOCAL
  PLEX) quality, and the channel overlay stuck after a stall. This app plays
  the stored file directly first, MKV included.
- MATCH TV LANGUAGE where the Apple TV says MATCH APPLE TV LANGUAGE.
- A Jellyfin or Emby transcode asks for its audio track (`AudioStreamIndex`)
  as the Roku does (`NxMbChosenAudioIndex`, issue #62): AUDIO LANGUAGE first,
  then English, then the file's default. The Apple TV counts English as one of
  the wanted languages, so a German viewer gets an English 5.1 mix over German
  stereo, and a Norwegian one Kon-Tiki in English (measured on the emulator).
- The PlaybackInfo device profile asks for the stream this app's hand-built
  request already plays, H.264 and AAC in MPEG-TS, where the Apple TV asks for
  fMP4 with HEVC (AVPlayer shows HEVC only from fMP4). It offers no direct play
  back: this app decides that by trying the file, and asks the server only
  once it has decided not to.
- In demo mode a package switch in Settings does nothing and saves nothing:
  the demo channels belong to no package. The Apple TV's switch is not guarded
  there (not checked on an Apple TV).
- The wordmark in the nav bar, as the Roku port uses at the maintainer's
  request; the Apple TV still shows its earlier logo.
- CH+ and CH- change channel and INFO shows the banner, for Android remotes
  that have those buttons. The Siri Remote has none of them.

Different in the detail:
- The failure card says "this TV" where the Apple TV's says "Apple TV", as
  the Roku's says "this Roku". Its classification reads ExoPlayer's errors
  (HTTP status, unreachable, decoder failure, first frame) in place of
  AVPlayer's error log, plus what each request answered when the watchdog
  gives up without a player error.
- The recovery ladder is the Apple TV's (startup watchdog, starvation monitor,
  one retry capped at 1080p, then the card), with two numbers that differ. A
  stall counts from 2 s, not 3: on a source at 0.67x real time ExoPlayer stops
  for 2.6 to 2.9 s every 8 to 9 s and carries on, where AVPlayer froze for good,
  so 3 s never fired (measured on the emulator; healthy rebuffers there peaked at
  0.5 s). The capped retry asks Jellyfin and Emby
  for H.264 in TS, as this app's first transcode does.
- The guide header keeps in line with the rows, where the Apple TV's runs 12
  points wide (as the Roku port also chose).
- An episode's summary gets one line in the info panel, where SwiftUI shrinks
  the stack to fit two.
- LAN discovery uses the address the server reports. A server in Docker
  reports the container's own address, which the TV can't reach; type the
  host's address instead.

## Parity

`engine/` is plain Kotlin with no Android in it: the schedule
(`DailyManifest.kt`, from `scripts/nostalgex-daily-manifest.js`), the channel
filter and Watershed (`ChannelFilter.kt`, from
`scripts/nostalgex-channel-filter.cjs`), stream quality (`StreamQuality.kt`),
seasonal packages (`Season.kt`), the Jellyfin and Emby library scan
(`MediaBrowserLibrary.kt`, from `plex-tuner.html`'s
`fetchJellyfinLibraryFromServer`), TMDB and OMDb enrichment
(`EnrichmentService.kt`, from `scripts/nostalgex-enrichment.js`), and
franchises and server collections (`FranchiseBuilder.kt`, `Collections.kt`,
`CollectionClassifier.kt` and `FranchiseLineup.kt`, from
`scripts/nostalgex-franchise-builder.js`, `nostalgex-collections.js` and
`nostalgex-franchise-lineup.js`, and `CollectionClassifier.swift`). Its tests read the Apple TV's golden files
from `scripts/` and run on the JVM:

```sh
./gradlew :engine:test
```

`scripts/schedule-parity-golden.json` is compared field for field with the
Apple TV's answers, each day packed across the guide's lineup so one title is
never on two channels at once (`ScheduleLineupTest` holds the properties of
`scripts/nostalgex-schedule-lineup-smoke.mjs`), and `scripts/filter-golden.json` case for case against the
shipped `channels.json`; `scripts/stream-quality-golden.json`,
`scripts/season-golden.json` and `scripts/watershed-golden.json` hold the
quality table, the package seasons and Watershed's hold to the same answers.
The scan is compared item for item with the web
tuner's, run by `engine/scripts/gen-mediabrowser-vectors.mjs` over the Roku
port's fixture server (`roku/tests/fixtures/mediabrowser-server.json`).
Enrichment's parsers, Supabase rows, OMDb gates and quota clock are compared
with the web tuner's over the Roku port's fixture documents
(`engine/scripts/gen-enrichment-vectors.mjs`, from
`roku/tests/gen-enrichment.mjs`), and its caches, batching, relay and OMDb
budget run the cases of `scripts/nostalgex-enrichment-smoke.mjs`. Franchises
and collections are held to `scripts/franchise-golden.json`, to
`scripts/franchise-lineup-golden.json` (whole lineups the Apple TV computed:
found franchises, classic pools, Settings rows, folds, numbers and the guide),
and to vectors run from the web tuner's own modules over the Roku port's
fixtures (`roku/tests/gen-franchise.mjs`, `gen-collections.mjs`). The engine
tests need Node. Change the JS engines and these have to follow.

## Build and install on a SHIELD

Needs the Android SDK (`local.properties` with `sdk.dir`, or `ANDROID_HOME`).
Gradle downloads the JDK it runs on.

1. On the SHIELD: Settings > Device Preferences > About, press Build seven
   times. Then Device Preferences > Developer options: turn on Network
   debugging, and note the address it shows.
2. On the computer:

   ```sh
   adb connect <shield-address>:5555   # accept the prompt on the TV
   ./gradlew :app:installRelease
   ```

   The release build runs much faster on the TV than `installDebug` (no
   debugger hooks). Both are signed with this computer's debug key, so either
   installs over the other and keeps the sign-in.

A build for Google Play is signed with the upload key, which stays with whoever
uploads. Give its keystore as Gradle properties (`-P`, or
`~/.gradle/gradle.properties`) or as environment variables of the same names:
`NOSTALGEX_UPLOAD_STORE_FILE`, `NOSTALGEX_UPLOAD_STORE_PASSWORD`,
`NOSTALGEX_UPLOAD_KEY_ALIAS` and `NOSTALGEX_UPLOAD_KEY_PASSWORD`, then run
`./gradlew :app:bundleRelease`. A PKCS12 keystore, `keytool`'s default, has one
password, so the key password is the store password. With any of the four
missing, the release build is signed with the debug key as above.

3. Nostalgex appears in the apps row.

Enrichment is off unless `local.properties` (which git ignores) turns it on and
names the Supabase project the maintainer gives for native builds:

```properties
nostalgex.enrichment=on
nostalgex.supabaseUrl=https://<project>.supabase.co
nostalgex.supabaseAnonKey=<anon key>
```

They go into the build, never into the repo; the Roku's `.env` carries the same
three. `nostalgex.relayUrl` points the build at a stand-in for the relay, for
testing only; without it the build asks the real one. Only TMDB and IMDb ids leave the TV, never titles or server details.

What each programme did is logged: `adb logcat -s Nostalgex` shows each
DIRECT PLAY or TRANSCODE, why a direct play fell back, how long a programme
took to start, and how long the library load and channel build took.
