# Privacy Policy

Effective: October 30, 2026

Nostalgex turns your own Plex, Jellyfin, or Emby library into live TV channels. We do not host, supply, or stream any media. Everything you watch comes off your own server.

This policy covers three separate things: the Nostalgex app on Apple TV, the Nostalgex app on Roku, and the nostalgex.app website. They collect different things, so they are described separately.

## Summary

- No accounts. Nothing is sold or rented to anyone.
- Your server address and login token stay on your Apple TV or Roku.
- The Apple TV app sends a small, fixed list of anonymous usage events so we can tell whether things are working. No names, no library contents, no titles. The Roku app sends none.
- The website uses two lightweight analytics scripts to count page visits.
- Nothing we collect follows you into other companies' apps or across the web.

## The app: what it sends

Nostalgex sends anonymous usage events to [TelemetryDeck](https://telemetrydeck.com), a privacy-focused analytics service, so we can tell whether the app is working: how often it installs and connects, whether playback starts and stays up, and which settings people actually use. Every event carries a `demo` flag so demo-mode exploration can be filtered out of the real numbers.

This is the complete list of events the app can send. Not every occurrence is sent: within one visit the app sends the first of each kind (for example one playback error per server type and reason code) and adds up the rest as counts on the end-of-visit event below.

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
- Playback stopped, with the channel number, the backend, the delivery mode, the channel identity above, and the accumulated active watch time (a number of seconds — no titles, no scenes, no timestamps). Sent once per channel stay of at least a minute, with programmes on the same channel added together, when the user changes channel, disconnects, backgrounds the app, or the sleep timer stops playback
- Playback errored, with the channel number, the backend, and one of a short fixed list of reason codes: `no_playable_source`, `transcoding_unavailable`, `player_failed`, `watchdog_skip`, `stalled`
- Playback fell back to a server-side transcode after direct play failed, with the channel number and the backend

**Session length**

- The app moved to the background, carrying the number of wall-clock seconds it spent in the foreground since the last launch or return-to-foreground. No screen, activity, or content details — just the length of the visit. Used to measure total time in the app. It also carries, as ranges (0, 1, 2-5, 6-20, 21-50, 51-200, 201+), how many channel changes, playback starts and playback errors happened in the visit and how many events were counted but not sent, plus which kind of server (Plex, Jellyfin, Emby, or demo) was in use

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

The web tuner itself does not load it. Once you are connected and watching, no analytics script is running on the page, so nothing about your library or what you play is measured. To sort titles onto channels, the web tuner looks up public movie and TV metadata the same way the app does: through the shared Supabase cache and the relay described below, sending only public TMDB and IMDb ids. No library titles, account, or server details are sent with them. For the music video channels it also looks up genres and years on MusicBrainz, then Deezer for any it can't place, the same as the app: for each music video your browser searches by song title and artist name. Nothing about you, your account or your server goes with it. The answers are kept in your browser, so it doesn't ask again every time you open it. The privacy policy page does not load them either. All of this is separate from the app, and nothing from the app is joined to anything from the website.

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
- TMDB (The Movie Database) and OMDb, for public movie and TV metadata used to sort titles onto the right channels. TMDB and OMDb lookups go through a small relay on nostalgex.app so the app never carries an API key. The relay forwards the public TMDB or IMDb id of the title being looked up and nothing else: no library titles, no account, no device or server details, and it keeps no log of what was asked.
- MusicBrainz, then Deezer for any it can't place, to find the genres and years of your music videos for the music video channels. For each music video the app searches by song title and artist name, straight from your Apple TV. Nothing about you, your account, your server or your Apple TV goes with it. The answers are kept on your Apple TV, so it doesn't ask again every time it opens.
- iCloud, only if you turn on SYNC WITH MY OTHER APPLE TVS in Settings under SERVERS & ACCOUNTS. It is off by default and set on each Apple TV separately. When it is on, your channel packages, collections and franchises, retro mode, guide text size, subtitle, audio and stream quality settings, and the two playback reporting switches are stored in your own iCloud account, so your other Apple TVs on the same Apple ID match. That goes to Apple, not to us. Server addresses, tokens, user IDs and everything in the Keychain stay on each Apple TV, and so does the sync switch itself.
- A Supabase database we run, which caches the metadata above so it does not have to be fetched again on every device

These lookups use public identifiers and titles for the purpose of matching metadata. The Supabase cache is keyed on public TMDB identifiers and holds metadata about films and shows. It does not record who asked for it, and it holds no account, device, or server information.

## Sign-in

Plex sign-in on the Apple TV runs through Plex's own PIN system. We never see your Plex username or password. Jellyfin and Emby sign-in goes straight from the app to the server you typed in. Tokens are held in the Keychain on your Apple TV and are never sent to us. On Roku, Plex sign-in offers the same PIN code, entered at plex.tv/link, or your Plex email and password typed on the TV, sent straight to plex.tv and never to us; either way only the token plex.tv returns is kept, never your password. Jellyfin and Emby sign-in goes straight from the TV to your server, and tokens are kept in the app's own storage on the TV.

## Playback reporting

The Apple TV app and the web tuner can report what you are watching back to your own Plex, Jellyfin, or Emby server. There are two separate switches, and both are **off** by default. On the Apple TV they are SHOW NOW PLAYING ON and MARK WATCHED ON, each followed by your server's name, in Settings under PLAYBACK & PICTURE, in the WATCH HISTORY section. In the web tuner they are Show Now Playing and Mark Watched, in Settings under PLAYBACK. You can use either one on its own.

- Show Now Playing lets your server show what is playing.
- Mark Watched counts a film or episode as watched when you join it in its first 15% and watch at least 75% of it.

With both off, nothing is reported and nothing in your library changes. Channel surfing never fills your Continue Watching row. On Plex the reports carry no position, so nothing is left half watched. On Jellyfin and Emby the app first reads the watch state your server already has and puts it back when the program ends, except that a watch Mark Watched counts stays counted; if it can't read it, it reports nothing for that program. When a switch is on, the reports go only to the server you connected. They do not come to us. If you have turned on iCloud sync on your Apple TVs, the two switches are shared between them through your iCloud account.

## The Roku app

The Nostalgex app for Roku works with Plex, Jellyfin and Emby. It does not send usage analytics, and it does not use Roku's advertising identifier.

It connects to:

- plex.tv, to sign you in to Plex and to find your servers. Two ways: the plex.tv/link code, entered at plex.tv/link or scanned from the QR code on screen (the QR code is drawn on the TV itself, so it is not sent to any QR service, and the TV never sees your Plex password this way), or your Plex email and password typed on the TV and sent straight to plex.tv over HTTPS, never to us. Either way the TV keeps only the token plex.tv returns; your password is never saved to the TV's storage or sent anywhere else.
- Your own Plex server, for your library and for playback. On your home network the app may reach the server at its local address over plain HTTP, the way Plex's own apps do at home. It only does that for a private home-network address, and your token travels in a request header, not in the address. Otherwise it uses HTTPS.
- Your own Jellyfin or Emby server, for sign-in, your library and playback. To find it, the app sends a short broadcast on your home network asking which Jellyfin or Emby servers are there (UDP port 7359), which only devices on that network receive. You can also type the server's address. Jellyfin can sign in with a Quick Connect code you approve in Jellyfin. Jellyfin and Emby can both sign in with a username and password, which go straight to your server and are not saved on the TV; the app keeps only the access token your server sends back. The same rules apply as for Plex: HTTPS, or plain HTTP only to a private home-network address, and the token travels in a request header, not in the address.
- The metadata relay on nostalgex.app and the Supabase cache described above, to sort titles onto channels. It sends only public TMDB and IMDb ids. Metadata it fetches is written back to the cache under the title's TMDB id, the same as the Apple TV app and the web tuner. No library titles, account, server or device details go with it.

The Roku app can report what you are watching back to your own Plex, Jellyfin or Emby server. There are two separate switches, SHOW NOW PLAYING ON and MARK WATCHED ON, each followed by Plex, Jellyfin or Emby, in Settings, and both are off by default. SHOW NOW PLAYING lets your server show what is playing. MARK WATCHED counts a programme as watched when you join it in its first 15% and watch at least 75% of it. You can use either one on its own. With both off, the app does not report what you watch and does not change anything in your library. On Plex the reports carry no position, so nothing is left half watched, and when MARK WATCHED counts an episode the app removes the show from Continue Watching again, unless it was already there. On Jellyfin and Emby the app first reads the watch state your server already has and puts it back when the programme ends or you change channel, except that a watch MARK WATCHED counts stays counted; if it can't read it, it reports nothing for that programme. When a switch is on, the reports go only to your server. They do not come to us. When you leave a channel your server was converting, the app asks the server to stop that conversion. When a programme won't play, the app asks the same server for it again: converted, then at 1080p. When STREAM QUALITY is set to HIGH, MEDIUM or LOW, the app asks your server to send no more than that level's picture size and bitrate. For a film with forced subtitles (the lines it always shows, such as dialogue in another language), the app asks your Jellyfin or Emby server for that subtitle file. It also asks ahead of time for films airing within the hour, so your server has the file ready. Those requests carry no token.

On the TV it keeps your sign-in (your Plex token, or your Jellyfin or Emby server's address, your user ID there and its access token), a random ID for this install (your server uses it to tell this TV apart in its list of devices), your server list, your channel packages and other settings, and a saved copy of your library and guide so it opens quickly. Signing out in Settings removes the token, the install ID, the server list, the saved library and guide, and the metadata cache. Removing the app removes your sign-in and settings; the saved copies sit in the Roku's own cache, which the Roku clears when it needs the room, so sign out first if you want them gone straight away.

If the TV warns that the app is running low on memory, the app writes a note to the TV's own debug log. Those notes stay on the TV and are not sent anywhere.

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
