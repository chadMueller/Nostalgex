# Nostalgex - App Store Metadata

_Last updated: 2026-09-02. Current App Store version: 1.0.11 (live since Aug 21, 2026). tvOS 18.0+. Free._

## App Name
Nostalgex

## Subtitle (30 chars max)
Plex, Jellyfin & Emby live TV

_(29 characters. The live subtitle is still the older "Retro channel guide for Plex" and should be replaced with this on the next submission.)_

## Category
Entertainment

## Price
Free

---

## Description

Nostalgex turns your Plex, Jellyfin, or Emby library into live TV. No more scrolling through a thousand titles trying to pick one. Turn it on, flip through channels, land on something.

Your movies and shows get sorted into themed channels like a real cable lineup. Rewatchables, Saturday Morning Cartoons, 90s Sitcoms, Kids & Family, True Crime, Arthouse, music video channels, and a lot more. Every channel runs a continuous daily schedule, so there is always something already playing when you tune in.

How it works:
- Connect your Plex, Jellyfin, or Emby server
- Pick the channel packages you want in Settings
- Start watching

Channels are built from what is actually in your library. If it is on your server, it can show up on a channel. Nostalgex does not host or supply any video. Everything plays from your own server.

Features:
- 131 themed channels in 14 packages
- Plex, Jellyfin, and Emby, with more than one server at a time
- EPG-style channel guide with live schedules
- Channel surfing with Siri Remote swipe gestures
- Retro mode with CRT scanlines and 4:3 framing, or turn it off for a clean picture
- Now Playing panel while you watch, with closed captions, subtitle and audio language, stream quality, and a sleep timer
- Open in Plex to jump the current program into the Plex app
- Music video channels that build themselves from your music videos
- Your collections become their own channels
- Multi-part movies play straight through
- Kids and family channels with mature content filtered out
- Optional playback reporting, off by default, so Continue Watching and play counts stay accurate on Plex, Jellyfin, or Emby if you want them to
- Your sign-in survives restarts, updates, and restores

Requires your own Plex, Jellyfin, or Emby server. Nostalgex is a client. It does not provide any media of its own.

Not affiliated with Plex, Jellyfin, Emby, or Apple.

---

## Keywords (100 chars max)
plex,jellyfin,emby,live tv,channels,retro,cable,epg,guide,nostalgia,media server,tuner,90s

_(90 characters.)_

## What's New in This Version (1.0.23)
REWATCHABLES now works on Jellyfin and Emby, not only Plex. Movies and episodes you have played 3 or more times show up on those channels.

Playback reporting is available for Jellyfin and Emby too. It stays off until you turn it on, and it only writes to your own server.

Audio goes to the AirPlay speakers you already selected on the Apple TV.

In the guide, Play takes what's already on to full screen from any row. Menu jumps back to that channel. Settings is in the package list.

---

## Age Rating

**Rating: 17+**
Content is user-generated (it depends on what is in their own library). The app itself contains no objectionable content, but users may have R-rated or mature content on their servers.

Applicable content descriptions:
- Frequent/Intense Mature/Suggestive Themes (user content)
- Frequent/Intense Horror/Fear Themes (user content)
- Frequent/Intense Realistic Violence (user content)

---

## Privacy Policy URL
https://www.nostalgex.app/privacy

## Support URL
https://www.nostalgex.app/support

_(The repo is public as of 2026-09-28. Marketing URL can point at https://github.com/chadMueller/Nostalgex; keep Support URL on the site so users land on the FAQ first.)_

## Support Email
support@nostalgex.app

---

## Privacy Nutrition Label

The app ships TelemetryDeck analytics. See `PRIVACY_POLICY.md` for the full, accurate description. Short version for the App Store questionnaire:

- **Collected:** anonymous product interaction and diagnostic events (seven events total), plus an anonymous, hashed, vendor-scoped device identifier used only to group one device's events.
- **Not collected:** name, email, account details, server credentials, server address, library contents, titles, watch history, advertising identifiers.
- **Not used for tracking** across apps or websites owned by other companies. No advertising, no data brokers, no selling.
- The website (nostalgex.app) runs its own analytics separately from the app.

---

## Screenshots Needed (tvOS)

Required: 1920x1080 (at least 1, up to 10)

Recommended shots:
1. Channel guide (EPG view) with channels playing
2. Full screen playback with OSD overlay
3. Now Playing panel over live video
4. Retro mode with CRT effect
5. Settings page showing channel packages

To capture: run in simulator, use Cmd+S in the Simulator app, or Window > Screenshot.

---

## App Review Notes

**Quickest path to review: tap "DEMO MODE" on the first screen.** This loads the app with bundled sample channels and requires no account, no network, and no server connection. The full tuner UI, channel guide, channel surfing, and settings are all reachable from Demo Mode. (Playback is disabled in Demo Mode since the sample channels have no real media files. Please evaluate playback using the Plex sign-in path below.)

Nostalgex is a client for a media server the user already runs. It supports **Plex, Jellyfin, and Emby**. The app does not host, stream, or provide any media content of its own. All content comes from the user's own personal media library on their own server.

How to test with real content (demo Plex account credentials are in the App Store Connect "App Review Information" fields):
1. Launch the app on Apple TV
2. Select "CONNECT TO PLEX"
3. The app displays a 4-character PIN code
4. Visit https://plex.tv/link on any browser and enter the PIN
5. Sign in with the provided demo Plex account credentials
6. The app discovers the server and loads the library
7. Channels populate based on the library's content

Jellyfin and Emby are reached from the same connect screen by entering a server URL and signing in directly on that server. No demo Jellyfin or Emby server is provided, so please use the Plex path above to evaluate playback.

If sign-in with the provided demo account fails for any reason (network, server unreachable, expired token), tap **DEMO MODE** on the connect screen to evaluate the app's UI and functionality with sample content.

The app connects to:
- The user's own Plex, Jellyfin, or Emby server (library and playback)
- plex.tv (Plex sign-in only, via Plex's official PIN auth flow)
- TMDB and OMDb (public movie and TV metadata, used to sort titles onto channels)
- MusicBrainz (public music metadata for the music video channels)
- Supabase (a metadata cache we run, keyed on public TMDB identifiers)
- TelemetryDeck (anonymous usage analytics, described in the privacy policy)

No credentials, server addresses, or library contents are transmitted to us.
