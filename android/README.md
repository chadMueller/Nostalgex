# Nostalgex for Android TV

A native Android TV app (Kotlin, Compose for TV, Media3 ExoPlayer), built for
the NVIDIA SHIELD first, for Plex, Jellyfin and Emby. There is no store
listing; it installs over `adb`.

## What it does today

- The Apple TV's connect screens: CONNECT TO PLEX, or JELLYFIN or EMBY.
  Plex signs in with the code and a QR for plex.tv/link. Jellyfin and Emby
  find the server on the network (UDP 7359) or take a typed address, then
  sign in the shortest way the server allows: Quick Connect when Jellyfin
  has it on, WHO'S WATCHING? tiles when the server lists its users, else a
  name and password.
- Plex reads every owned server (every server if none is owned) into
  programmes, in library order; Jellyfin and Emby read the one server signed
  in to, as the web tuner's `fetchJellyfinLibraryFromServer`. The library is
  saved, so a launch opens on it and reads the servers again behind the guide.
- Builds the channels from the root's `channels.json` and
  `channels-memberships.json` (symlinked into `app/src/main/assets/`), with
  the package you had on, or the packages with content if that one fills
  nothing.
- Airs the Apple TV's schedule: the same programme at the same minute.
- Plays through ExoPlayer: the file as stored (direct play) first, the
  server's HLS transcode if that fails or a track has no decoder on the
  device. On Jellyfin and Emby the transcode carries no start time and the
  player seeks, as on the Apple TV.
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
- RETRO MODE's look: scanlines, flicker, vignette and the tracking line over
  the picture, and tuning snow when a start takes longer than 0.75 s.
- Settings (SETTINGS above the guide, or the top of the package sidebar that
  Left opens at the guide's first half hour): servers, libraries, RESCAN
  LIBRARY, DISCONNECT, the playback settings, the channel packages with their
  availability, and WATERSHED. The sidebar jumps to a package's first channel.
- Library selection: after sign-in, a server with more than one library offers
  CHOOSE YOUR LIBRARIES; a library left off (there or later in Settings) is
  never scanned.
- The loading screen's step rail, with what the scan is reading and a progress
  bar, and START OVER (it asks first) for the whole load. After two loads in a
  row that never finished, the next launch asks LOADING DIDN'T FINISH: TRY
  AGAIN or START OVER.
- WATERSHED (off by default): R, NC-17 and TV-MA titles wait for 9 PM on every
  channel but VHS VAULT, which holds its own. A channel with nothing else to
  show says BROADCASTS WILL RESUME AT 9 PM, and comes on at 9.

## Differences from the Apple TV app

The aim is the Apple TV app, screen for screen. Where this app differs, it is
listed here.

Not ported yet: server collections, found franchises and MY COLLECTIONS;
TMDB enrichment; SHOW NOW PLAYING and MARK WATCHED; the seasonal invite row
above channel one; demo mode; the Apple TV's playback recovery ladder
(watchdog, stalls, compatibility retry) and the loading screen's STOP WAITING
when a scan goes quiet; the
PlaybackInfo handshake on Jellyfin and Emby (this app asks for the stored
file, then the hand-built HLS stream, which is the Apple TV's fallback path).

Different on purpose, because the Apple TV's version has no counterpart here:
- No SUPPORT NOSTALGEX (App Store ratings and tips) and no iCloud sync.
- The loading screen's rail is LINEUP, LIBRARY, CHANNELS, READY: the Apple TV's
  COLLECTIONS, METADATA and MUSIC steps have no work behind them here yet.
- No reinstall check: Android deletes an app's data with the app (and backup is
  off), so a reinstall can't find an old sign-in the way tvOS's keychain can.
- MATCH TV LANGUAGE where the Apple TV says MATCH APPLE TV LANGUAGE.
- The wordmark in the nav bar, as the Roku port uses at the maintainer's
  request; the Apple TV still shows its earlier logo.
- CH+ and CH- change channel and INFO shows the banner, for Android remotes
  that have those buttons. The Siri Remote has none of them.

Different in the detail:
- The failure card says "this TV" where the Apple TV's says "Apple TV", as
  the Roku's says "this Roku". Its classification reads ExoPlayer's errors
  (HTTP status, unreachable, decoder failure, first frame) in place of
  AVPlayer's error log; the starvation ladder that feeds "couldn't keep up"
  isn't ported, so that verdict comes only from late or silent servers.
- The guide header keeps in line with the rows, where the Apple TV's runs 12
  points wide (as the Roku port also chose).
- An episode's summary gets one line in the info panel, where SwiftUI shrinks
  the stack to fit two.
- Plex titles with a byte that isn't UTF-8 are not repaired yet.
- LAN discovery uses the address the server reports. A server in Docker
  reports the container's own address, which the TV can't reach; type the
  host's address instead.

## Parity

`engine/` is plain Kotlin with no Android in it: the schedule
(`DailyManifest.kt`, from `scripts/nostalgex-daily-manifest.js`), the
channel filter (`ChannelFilter.kt`, from `scripts/nostalgex-channel-filter.cjs`)
and the Jellyfin and Emby library scan (`MediaBrowserLibrary.kt`, from
`plex-tuner.html`'s `fetchJellyfinLibraryFromServer`).
Its tests read the Apple TV's golden files from `scripts/` and run on the JVM:

```sh
./gradlew :engine:test
```

`scripts/schedule-parity-golden.json` is compared field for field with the
Apple TV's answers, and `scripts/filter-golden.json` case for case against the
shipped `channels.json`. The scan is compared item for item with the web
tuner's, run by `engine/scripts/gen-mediabrowser-vectors.mjs` over the Roku
port's fixture server (`roku/tests/fixtures/mediabrowser-server.json`), so the
engine tests need Node. Change the JS engines and these have to follow.

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

3. Nostalgex appears in the apps row.

What each programme did is logged: `adb logcat -s Nostalgex` shows each
DIRECT PLAY or TRANSCODE, why a direct play fell back, how long a programme
took to start, and how long the library load and channel build took.
