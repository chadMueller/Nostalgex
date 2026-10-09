# Privacy Policy

Effective: October 9, 2026

Nostalgex turns your own Plex, Jellyfin, or Emby library into live TV channels. We do not host, supply, or stream any media. Everything you watch comes off your own server.

This policy covers two separate things: the Nostalgex app on Apple TV, and the nostalgex.app website. They collect different things, so they are described separately.

## Summary

- No accounts. No ads. Nothing is sold or rented to anyone.
- Your server address and login token stay on your Apple TV.
- The app sends a small, fixed list of anonymous usage events so we can tell whether things are working. No names, no library contents, no titles.
- The website uses two lightweight analytics scripts to count page visits.
- Nothing we collect follows you into other companies' apps or across the web.

## The app: what it sends

Nostalgex sends anonymous usage events to [TelemetryDeck](https://telemetrydeck.com), a privacy-focused analytics service, so we can tell whether the app is working: how often it installs and connects, whether playback starts and stays up, and which settings people actually use. Every event carries a `demo` flag so demo-mode exploration can be filtered out of the real numbers.

This is the complete list of events the app can send.

**Launch and credentials**

- App launched, marked as either the first launch on this install or a return launch, so installs can be joined to connect success
- A saved sign-in could not be read back on launch (device data loss), with the keychain status code (a short number, no server or token bytes)
- A fresh sign-in was written to the keychain but could not be verified back (the session will die on relaunch)

**Connecting to a server** — the same event names apply to Plex, Jellyfin, and Emby, with a `backend` parameter naming which one:

- Connect started, with the backend and the method (`pin`, `password`, or `quick_connect`)
- Connect completed, with the backend and the number of reachable servers found
- Connect failed, with the backend and a short reason code (for example `no_reachable_server`, `jellyfin_auth_failed`, `emby_unreachable`)
- Connect cancelled, with the backend and the method (the user tapped Cancel)
- Connect code expired, with the backend and the method (PIN or Quick Connect timed out)
- Server picker confirmed, with the number of servers the user chose to include

**Library**

- A library scan started, and whether it was a background refresh
- A library scan finished, with the number of channels, the number of items, whether it happened in the background, how many milliseconds it took, and whether it was partial (one or more servers only returned some of the library)
- A library scan failed in the foreground, with a short error reason
- A library scan was abandoned, with the item count so far and whether the user asked to stop waiting (`userInitiated=true`) or the stall watchdog gave up (`userInitiated=false`)
- A library scan finished but built no channels (the "no channels found" state)
- The user tapped the STOP WAITING button on the loading screen
- A background library refresh failed (silent to the user), with a short error reason

**Tuning and playback**

Each of the three events below also carries a short "channel identity" that is fixed by the app, not by your library:

- `channelType`: either `static` (a channel Nostalgex ships in its own catalog, the same across every install) or `collection` (a channel that Nostalgex built from a movie collection on your own server)
- `channelID`: only present for `static` channels — a small number from Nostalgex's own catalog
- `channelName`: only present for `static` channels — the display name from the app's own built-in lineup (for example `REWATCHABLES MOVIES`, `KIDZ CARTOONS`, `90S SITCOMS`). This is read from the copy of the channel list that ships inside the app on the App Store, never from any list your server might host, and never from your library
- `bundle`: the fixed bundle key the channel belongs to (`nostalgex`, `kids`, `truecrime`, `essentials`, `premium`, `arthouse`, `adventureland`, `sports`, `decades`, `franchises`, `franchise`, `streamers`, `seasonal`, `high-rotation`, or `collections-franchises` / `collections-actors` / `collections-custom` for user-collection channels)

For channels Nostalgex builds from your own collections, `channelType` is `collection` and none of `channelID`, `channelName`, or the collection's title is sent — only the bundle key, so the app can tell franchise-style collections apart from actor collections apart from custom collections at the group level. The names of collections, servers, and titles from your library never leave the device.

- A channel was tuned to by the user, with the channel number, the backend, the method (`guide`, `mini_strip`, `next`, or `previous`), and the channel identity above. Automatic re-selections (library load, snapshot restore, background refresh, foreground return) never fire this event
- Playback became ready to play, with the channel number, the backend, whether the stream is direct play or a server-side transcode, and the channel identity above
- Playback stopped, with the channel number, the backend, the delivery mode, the channel identity above, and the accumulated active watch time (a number of seconds — no titles, no scenes, no timestamps). Fires when the user changes channel, disconnects, backgrounds the app, or the sleep timer stops playback
- Playback errored, with the channel number, the backend, and one of a short fixed list of reason codes: `no_playable_source`, `transcoding_unavailable`, `player_failed`, `watchdog_skip`, `stalled`
- Playback fell back to a server-side transcode after direct play failed, with the channel number and the backend

**Session length**

- The app moved to the background, carrying the number of wall-clock seconds it spent in the foreground since the last launch or return-to-foreground. No screen, activity, or content details — just the length of the visit. Used to measure total time in the app

**Settings and app use**

- A setting changed. One generic event covers channel package toggles, server toggles, rescan taps, disconnect taps, retro mode, stream quality, subtitle language, audio language, subtitle-in-fullscreen toggle, auto foreign-audio subtitles, Plex playback reporting toggle, and sleep timer minutes. The event carries a short setting key (for example `retro_mode`, `bundle:essentials`, `subtitle_language`) and a short value (`true`/`false`, a language code, or a numeric bucket). No library or server identity is included; server toggles do not include the server's identifier
- The user tapped RATE NOSTALGEX (opens the App Store)

**Update emails**

- The update-emails QR code in Settings was shown, with the backend. Not sent in demo mode

The QR code is a plain link to the signup form on nostalgex.app. You type your email on your phone, not on the Apple TV, and the app never sees it. There is no event for scanning, and nothing links these events to an email address.

## The app: what it never sends

- Your name, email address, or any account details
- Your Plex, Jellyfin, or Emby username, password, or token
- Your server address, hostname, or IP address
- Your library contents. No titles, no filenames, no posters, no watch history
- Any name that came from your library. That includes the names of collections you have on your server, the names of your servers themselves, folder names, and titles. The only channel names that are sent are the built-in ones from Nostalgex's own lineup, read from the copy shipped inside the app
- Any advertising identifier, and nothing that lets anyone track you across other apps or websites

## The app: how events are grouped

Every event carries an anonymous device identifier so one Apple TV's events can be counted as one device instead of many. It comes from Apple's vendor identifier, which is specific to us and is not shared with other developers. It is hashed on your device before it leaves, and TelemetryDeck hashes it again on arrival. It cannot be turned back into you, and it resets if you delete the app.

Alongside each event, the analytics library also records ordinary technical details: app version and build number, tvOS version, Apple TV model, platform and architecture, language and region, and whether the build came from the App Store, TestFlight, or a debug run.

## The website

The marketing pages on nostalgex.app load one analytics script, statsngraphs: the home page, the Plex, Jellyfin and Emby pages, the connect page, the support page, and the blog. It counts page visits, referrers, and basic device and country information. It does not use advertising cookies and does not build a profile of you across other sites.

If you sign up for update emails, your email address goes to Resend, the service that sends them. Along with it we store which signup form or QR code you used (for example the home page, the connect page, or the Apple TV app's settings screen), the page you signed up on, and any campaign tags that were on the link you followed. Nothing else about your visit is stored with it, and it is never joined to app analytics. Every email has an unsubscribe link.

The web tuner itself does not load it. Once you are connected and watching, no analytics script is running on the page, so nothing about your library or what you play is measured. The privacy policy page does not load them either. All of this is separate from the app, and nothing from the app is joined to anything from the website.

## What the app stores on your device

Nostalgex keeps your setup on your Apple TV so you do not have to sign in again:

- Your server address and login token, stored in the device Keychain
- Which server type you connected to, and your Jellyfin or Emby user ID
- Your channel and bundle preferences, retro mode, subtitle and audio language settings, and the date of your last library scan
- A cached copy of your channel guide, and a short list of what is on now for the Apple TV home screen. Both are titles and artwork links from your own library, kept in the app's cache on the device

This stays on your device. It is not synced to us, and it is removed when you delete the app.

## Services the app connects to

- Your own Plex, Jellyfin, or Emby server, for the library and for playback
- plex.tv, for Plex sign-in using Plex's own PIN flow. That is Plex's system, not ours
- TMDB (The Movie Database) and OMDb, for public movie and TV metadata used to sort titles onto the right channels
- MusicBrainz, for public music metadata used by the music video channels
- A Supabase database we run, which caches the metadata above so it does not have to be fetched again on every device

These lookups use public identifiers and titles for the purpose of matching metadata. The Supabase cache is keyed on public TMDB identifiers and holds metadata about films and shows. It does not record who asked for it, and it holds no account, device, or server information.

## Sign-in

Plex sign-in runs through Plex's own PIN system. We never see your Plex username or password. Jellyfin and Emby sign-in goes straight from the app to the server you typed in. Tokens are held in the Keychain on your Apple TV and are never sent to us.

## Playback reporting

The app can report what you are watching back to your own Plex, Jellyfin, or Emby server, so Continue Watching and play counts stay accurate. This is **off by default** and you turn it on in Settings under Playback Reporting. When it is on, the reports go only to the server you connected. They do not come to us.

## Tracking

Nostalgex does not track you across apps or websites owned by other companies, and does not use data for advertising or ad measurement.

## Data retention

Analytics events are held by TelemetryDeck in aggregate and are not tied to an identifiable person. Website analytics are kept as visit counts. Anything stored on your Apple TV stays there until you remove the app, sign out, or reset the device.

## Your choices

- Deleting Nostalgex removes everything the app stored on your Apple TV, including your server token.
- Playback reporting is off unless you turn it on, and you can turn it back off at any time.
- If you want your app analytics removed, email us and we will ask TelemetryDeck to delete them.
- If you contact support, you decide what goes in the message.

## Children's privacy

Nostalgex is not directed at children and does not knowingly collect personal information from anyone, including children.

## Changes to this policy

If this policy changes, we'll update it here with a new effective date.

## Contact

Questions about this policy? Reach us at support@nostalgex.app, or through https://www.nostalgex.app/support

Muell Haus Inc.
