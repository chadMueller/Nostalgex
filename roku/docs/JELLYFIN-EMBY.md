# Jellyfin and Emby

Discussion #8, item 4. Upstream's Apple TV app (1.0.26) and web tuner
(tuner-v1.0.1) read Jellyfin and Emby as well as Plex, and so does the port.
This is what upstream does, how the port fits it in, where it differs, and
what was measured.

## What upstream does

Read from upstream `origin/main` at 8a55386:

- `Nostalgex/Services/JellyfinAPIService.swift`, `EmbyAPIService.swift` and
  `JellyfinPlaybackResolver.swift`.
- Their tests.
- `scripts/nostalgex-jellyfin-urls.js` and `plex-tuner.html`.

Jellyfin is a fork of Emby, and upstream drives both through one MediaBrowser
code path.

**Sign-in**

- Header on every request:
  `Authorization: MediaBrowser Client=…, Device=…, DeviceId=…, Version=…, Token=…`.
- Password: `POST /Users/AuthenticateByName` with `{Username, Pw}`. The answer
  carries `AccessToken` and `User.Id`.
- Jellyfin also has Quick Connect: the TV shows a code, and you approve it in
  Jellyfin's web or phone app. The calls are `GET /QuickConnect/Initiate` (the
  port sends a POST, which Jellyfin 12.2 needs; below), then
  poll `GET /QuickConnect/Connect?Secret=` every 2 s, then
  `POST /Users/AuthenticateWithQuickConnect`. A 401 on Initiate means the server
  has Quick Connect switched off.
- Servers answer a UDP broadcast on port 7359 (`who is JellyfinServer?` or
  `who is EmbyServer?`), so the TV can find them without anyone typing an
  address.
- Before anyone types, the app asks the address who it is, as upstream's
  sign-in redesign does (`source/mediabrowser/SignInFlow.brs`):
  `/System/Info/Public` (which server, and Jellyfin or Emby), then
  `/QuickConnect/Enabled` on Jellyfin (a bare `true` or `false`; Emby 4.10
  answers 404) and `/Users/Public` (the users the server shows on its own
  login screen). A Jellyfin server with Quick Connect on opens straight on
  the code; listed users show as tiles, and one with no password signs in on
  the press. Nothing from these is saved.

**Library**

- The libraries come from `/UserViews?userId=` on Jellyfin and
  `/Users/{id}/Views` on Emby. Emby answers 404 to the first.
  With INCLUDE LIBRARIES HIDDEN ON JELLYFIN on (#231, SERVERS & ACCOUNTS, off
  by default, `source/mediabrowser/HiddenLibraries.brs`), Jellyfin's request
  ends `&includeHidden=true` and lists the libraries the user hides from the
  home screen; a library the user has no access to is in neither answer.
  Emby's request is the same either way. Pressed on the 55R617
  (2026-11-10) against the lab Jellyfin 12.2.0, a user hiding Shows: 834
  items off, 5,589 on, 834 off again; a library the user can't open was read
  in neither.
- Items: `GET /Items?userId=&ParentId=&Recursive=true&IncludeItemTypes=` with
  the `Fields` list (`ProviderIds,Genres,Studios,MediaSources,ProductionYear,PremiereDate,DateCreated,UserData`),
  in pages of 200. A library of type `musicvideos` is asked for
  `IncludeItemTypes=Movie,MusicVideo`, because both servers file its videos as
  `MusicVideo`; a `movies` library, and a mixed one (no type, or one not
  listed), is asked for `Movie`. A library with no videos in it (`playlists`,
  `music`, `boxsets`, `books`, `audiobooks`, `photos`, `homevideos`, `livetv`,
  `trailers`, `folders`, `channels`) is never asked: Jellyfin's Playlists
  library answers any request with its playlists, whatever `IncludeItemTypes`
  says, and a playlist read as a film aired on VHS VAULT (#205). A row whose
  `Type` is not one of the types asked for is dropped; a row with no `Type` is
  kept. The rules are upstream's `scripts/jellyfin-library-golden.json`.
- TV shows: list the series, then each series' episodes, several series at a
  time. Each episode takes its show's genres, TMDB id, year, studio and
  ratings, because the channel rules match on the show.
- Runtime is `RunTimeTicks` (10,000,000 per second). Items with none are
  dropped.
- Collections are `BoxSet` items. Jellyfin lists a collection's series; Emby
  lists their episodes instead.
- There is no library-changed signature. Upstream rescans Jellyfin and Emby in
  full every time.

**Playback**

- Direct play: `/Videos/{id}/stream.mp4?Static=true&MediaSourceId=`.
- Otherwise: `POST /Items/{id}/PlaybackInfo` with a device profile, and the
  server's `TranscodingUrl` (HLS).
- If neither works, a hand-built `/Videos/{id}/master.m3u8`. Emby needs a
  `PlaySessionId` on it or every segment fails with 400.
- **Never put `StartTimeTicks` on an HLS address**: Jellyfin then rejects every
  segment with 400. Joining a channel part-way through a programme means
  starting the stream at 0 and seeking on the client.
- To stop a stream: `DELETE /Videos/ActiveEncodings?deviceId=&playSessionId=`.
- Reporting what was watched back to the server is off by default upstream.

**Emby differs from Jellyfin** in these places:

1. the libraries call;
2. no Quick Connect;
3. `PlaySessionId` on the hand-built HLS address;
4. the retry after a failed direct play has to turn off both direct play and
   direct stream;
5. collection members (episodes rather than series);
6. how the server name is found;
7. a Dolby Vision profile 5 file goes on no channel. Emby names the profile
   in the video stream's `ExtendedVideoSubType` ("DoviProfile50"), and 4.10.1
   sends it in a form drawn green and purple (upstream `5d6d65f`,
   `ccb6854`). It stays in the library; only the channels leave it out.
   On a Roku whose display doesn't show Dolby Vision (`GetDisplayProperties`
   `DolbyVision` false), profile 5 goes on no channel from Plex or Jellyfin
   either (#69): such a TV draws it green and purple whichever server sends
   it. Jellyfin names the profile in the stream's `DvProfile` (10.10.7), Plex
   in `DOVIProfile`, which its section listing leaves out, so the scan asks
   each section once more for `dovi=1` items with their streams
   (`NxPlexDoviProfiles`). The shared rule above and its golden cases don't
   change: this is a Roku step before it (`source/guide/DolbyVision.brs`).

## What we checked on test servers

Jellyfin 12.2 and Emby 4.10.1 in containers, each reading a test library
read-only.

- **The token can stay in a header for streams.** On both servers a static
  stream answered 206 with the token only in the `Authorization` header. The
  Roku player sends a content node's `HttpHeaders` with every request, as the
  Plex path already does. So the token never goes in an address, and the maintainer's new
  Roku privacy text ("your token travels in a request header, not in the
  address") stays true. Upstream puts `api_key` in addresses because AVPlayer
  can't add headers. We don't need to.
  - HLS too (2026-10-18). Emby wants the token on the master playlist and
    not on segments. Jellyfin wants it on the master, the variant and every
    segment (401 without it). With the header alone, every stream in the spike
    below played on the TV, and Jellyfin logged no rejected request.
- **Signing in again cancels the device's previous token on Jellyfin** (not on
  Emby). A token stopped working the moment the same `DeviceId` signed in
  elsewhere. The app has to keep one `DeviceId` per install (the Plex client id
  already is one) and must never sign in again in the background while a
  stream is using the old token.
- **Jellyfin burns subtitles into the picture unless told not to.** Two MKVs
  came back from PlaybackInfo with `SubtitleMethod=Encode`
  (`SubtitleCodecNotSupported`), which means a full video transcode. Even with
  `SubtitleStreamIndex: -1` in the body, the `TranscodingUrl` still named a
  subtitle stream. The app needs `SubtitleProfiles` in its device profile (text
  subtitles delivered as HLS or External), or it has to drop those parameters.
- **Jellyfin serves a static stream to anyone who knows the item id**: it
  answered 206 with no token at all. Emby answered 401. That is the server's
  business, not ours, but it is worth knowing when reading logs.
- Jellyfin's `/System/Info/Public` answered in camelCase before its first-start
  setup and in PascalCase after. BrightScript's associative arrays ignore case,
  so the app is safe either way.

## On a TV (2026-10-18)

The build (roku `49c628d`) ran on a 1080p TCL Roku TV against the test
servers, driven over ECP.

**Jellyfin 12.2**

- The broadcast found the server.
- Quick Connect signed in.
- 5,133 items read in 10 s.
- The guide was on screen 21 s after sign-in, with 15 channels. The same
  library through Plex gives 16.
- Tuning seven channels:
  - MP4 and MKV played directly, joined part-way, picture in 1.4 to 3.3 s.
  - One HLS stream had a picture in 1.7 s.
  - Leaving the HLS channel sent `DELETE /Videos/ActiveEncodings`, which
    answered 204.
- A relaunch went straight back to the Jellyfin guide.

**Emby 4.10**

- Typed address, then username and password.
- 5,422 items read in 7 s.
- The guide was on screen 18 s after sign-in.
- An HLS channel had a picture in 2.6 s.
- Only 3 channels, because the test server's libraries had no metadata
  fetchers (3 of 943 titles had genres). The app read what the server had.

**Found on the TV**, each now fixed:

- **Two components called a function their scripts don't load.** BrightScript
  only finds out when the call runs, so the tests passed.
  `tests/tools/check-includes.py` now fails the run when this happens.
- **Quick Connect needs a POST.** Jellyfin 12.2 answers
  `GET /QuickConnect/Initiate` with 405; `POST` works. Upstream's Apple TV app
  and web tuner sent the GET then. Told upstream, both start with a POST since
  2026-10-19 (`1f1a55f`, `180fbd7`, in Docker `tuner-v1.0.2`).
- **A string compared with an object stopped the sign-in task.** BrightScript
  raises a type mismatch where JavaScript would answer false.
- **The password keyboard closed as soon as it opened.** The username
  keyboard's closing notice arrived after the password keyboard was up.
- **A sign-in the server now refuses** left the saved guide up with nothing
  playable. A launch now checks the token (`GET /Users/{id}`); on a 401 it
  signs out and says why, as a refused Plex token does.

- **Emby restarted its transcode over and over after a mid-file join over
  fMP4, and doesn't over TS** (2026-10-19, Emby 4.10.1, Discussion #8;
  TS measured 2026-11-02). Joined 335 s into an MKV whose audio it
  converts, the 43S45 fetched each segment once, but Emby started ffmpeg
  again for each one ("segmentGap is 53 … requestedIndex=55", then 54, 55,
  …: 26 restarts in 11 s). curl alone does the same. The port asked for
  fMP4 segments then, which Emby cuts with ffmpeg's `hls` muxer. For TS it
  uses the `segment` muxer, and the restarts stop. Against the lab Emby,
  curl asked as the port asks and fetched 15 segments back to back from
  30 min into a 2-hour H.264 file, its Opus track converted:
  - fMP4: five ffmpeg starts, at `-start_number` 900, 903, 906, 909 and
    912;
  - TS: one, at `-segment_start_number 900`; one each also for two HEVC
    files over 20 Mb/s, re-encoded, joined 30 s in.

  The port has asked for TS since 2026-10-22 (below). In Emby's logs from
  2026-10-31 to 11-02, nine joins by the 43S45 and the 55" TCL (Roku OS
  16.0.4 and 15.3.4), 12 to 79 minutes into that file, each ran one ffmpeg
  over 23 to 92 segments. Two sessions in the same logs did start ffmpeg
  twice, both on 2026-11-01 on a 60.03 s Lab clip cut into 2 s segments,
  but not mid-file: the TV read segments 0 to 29 within about
  1.5 s, by when the first ffmpeg, a remux, had finished the file. Asked
  for segment 30, the file's last 0.03 s, Emby started another ("Starting
  transcoding because currentTranscodingIndex=null", `-ss 00:01:00`).
  The restarts fit the maintainer's 500s ("Error
  starting ffmpeg") and repeated fetches. `StartTimeTicks` on the playlist is
  dropped from the segment requests, so it was no way round it.
- **What that restart costs is sync, upstream found** (Discussion #8,
  2026-10-20). With the video copied and the audio converted, fMP4 stamps
  both tracks from zero, so on their Apple TV the sound ran early by up to a
  GOP (H.264 + DTS joined at 247 s: -1,720 ms on fMP4, +35 ms on TS). TS
  segments carry the source timestamps. The port asked Emby for TS when
  the video was H.264, as upstream's `embySegmentContainer` (`72c844d`),
  and fMP4 for a file that may be HEVC, until fMP4 turned out silent on a
  Roku (below); now it asks for TS everywhere. Upstream tried it on a Streaming Stick
  Plus against Emby 4.10.1 (Discussion #8, 2026-10-20): an H.264 + DTS file
  joined 48 s in asked for `SegmentContainer=ts`, Emby copied the video and
  converted DTS to AAC, and the picture came up in 1.6 s.
- **The TS stream is in sync after a join; fMP4 is not** (measured
  2026-10-20 against the lab Emby 4.10.1, H.264 + 5.1 DTS MKV). The stream
  was asked for as the port asks, and the first segment from each join was
  taken. Each track was then placed in the source: the copied video's
  packets matched the file's frame for frame, and the AAC was
  cross-correlated with the file's own audio. Sound against picture:
  - TS, joined at 247 s (no seek, `segment` muxer, `-copyts`): 0 ms;
  - TS, joined at 1,500 s (`-ss 00:25:00`, picture from the keyframe 7.5 s
    earlier): -1 ms;
  - fMP4, joined at 247 s (`hls` muxer, both tracks from zero): -2,048 ms,
    the sound early, as upstream found.

  Each track's start is its first packet's pts. Not yet watched on a Roku.
- **Dolby audio and fMP4 segments played silent** (Discussion #8,
  2026-10-22, a Streaming Stick Plus set to Stereo, Emby 4.10.1). Two
  causes. The request offered `AudioCodec=aac,ac3,eac3` at 6 channels, so
  the server copied AC3 and E-AC-3 as stored to a TV that says no to them
  (the player: error -5, "Unsupported audio format: Dolby Digital Plus").
  And the player reported no audio from any fMP4 stream, even stereo AAC
  copied as stored, on Emby and on Jellyfin 12.2's public demo; over TS
  the same audio played (`aac_adts`). The request now offers AC3 and E-AC-3
  only when the TV decodes them, caps at 2 channels unless it decodes 5.1
  AAC (`NxMbAudioQuery`), and asks for TS on both servers, HEVC included.
  Against the lab Emby 4.10.1 and Jellyfin 12.2, the old request's first
  segment carried the Dolby track as stored and the new one stereo AAC, at
  the start and joined part-way in. HEVC copied into TS played on the
  stick. Its sync after a join, measured as above but on 5 ms loudness
  envelopes, so to the nearest 5 ms (HEVC 10-bit + E-AC-3 5.1, joined
  about 30 min in): in sync on Emby and on Jellyfin, the sound within 5 ms
  of where its timestamps put it. Not yet heard on a Roku.
- **A 4K remux through the server stopped with error -3** (issue #58,
  2026-10-22, a Streaming Stick Plus set to Stereo, Emby 4.10.1, a 4K HEVC
  Dolby Vision remux at 29 Mb/s with AC3): "Requested reservation
  (11065599+56589021) is larger than the entire buffer", over TS and fMP4.
  Both servers cut 6 s segments unless asked, and with the video copied a
  6 s piece of a remux is tens of MB. The request now asks for
  `SegmentLength=2`. On the lab Emby, a 60 s 4K HEVC clip at 43 Mb/s with a
  keyframe every second: 6 s segments averaged 33 MB (largest 44 MB), 2 s
  ones 11 MB (16 MB), 1 s ones 5.5 MB (8.3 MB); the 2 s ones checked held
  2 s of video each. On Jellyfin 12.2, `SegmentLength=2` on a 4K HEVC file
  gave segments of 1.96 s. The server can cut only at a keyframe: a 4K x265
  encode with keyframes about 10 s apart gave "6 s" segments holding 10.4 s
  and 20.7 s (74.7 MB), so asking for less can't shorten them.
  On a TCL 43S45 (4K, Roku OS 16.0.4), a throwaway player asking as the
  port asks, from the start, against the lab Emby and Jellyfin 12.2 alike:
  the 4K clip and a 1080p one at 73 Mb/s stopped with error -3 at 6 s
  segments, "Requested reservation (11065599+…) is larger than the entire
  buffer (31616000)", and played at 2 s, segments of up to 25.5 MB
  included. On Emby a 1080p clip with keyframes 10 s apart failed at 2 s
  too. The port at 2 s
  joined two films part-way through Emby with picture in 1.4 and 3.0 s and
  no stall.
  Short segments weren't enough for Chad's file: The Matrix Revolutions
  (4K, Dolby Vision 8.1) has keyframes 6 s apart on average and up to 10 s,
  at 41 to 55 Mb/s in the stretch measured, and Emby's `SegmentLength=1`
  still gave 53 MB pieces (#55, where the remux he first reported is
  29 Mb/s). So over 20 Mb/s the request now asks for
  `AllowVideoStreamCopy=false`, and always for
  `VideoBitrate=40000000`, the Apple TV's Auto ceiling
  (`StreamQuality`), where it asked for 120 Mb/s so the server would always
  copy (`NxMbVideoQuery`), with `MaxWidth=3840`, or the TV's width when
  it re-encodes (below). Re-encoded, Emby makes H.264 with a keyframe at
  every segment. Measured on the lab Emby and the 43S45 with one-minute 4K
  HDR10 clips, keyframes 10 s apart, one cut from 12 Angry Men (46 Mb/s)
  and two from La La Land (41.8 and 26.5 Mb/s, film grain):
  - Copied at 2 s segments, the 46 and the 26.5 Mb/s clips stopped with
    the same error.
  - The ceiling alone doesn't re-encode the 26.5 Mb/s clip: Emby decides by
    the file's average bitrate, so 40 Mb/s copied it, and copied the real
    4K 12 Angry Men (19 Mb/s). With `AllowVideoStreamCopy=false` both
    re-encoded at 4K, and the 26.5 Mb/s clip played in the port (the test
    file swapped in for every Emby airing), picture in 2.1 to 2.8 s over
    four tunes, no error.
  - 12 Angry Men played copied, from the start, 10 minutes in and an hour
    in, pieces up to 31.9 MB, which is why the line is 20 Mb/s and not
    lower.
  - Without `MaxWidth`, Emby re-encoded to 1080p (at 20 and 40 Mb/s); the
    La La Land clip came out at about 1.6 Mb/s, soft and blocky next to the
    original on the TV. At 4K (about 4.6 Mb/s out, set by Emby's own CRF 23
    and `veryfast`, whatever the ceiling) it looked a little less sharp
    than the original, with a little more compression; the film grain may
    be part of that.
  - Emby re-encoded 4K to 4K at about 4× real time on an i7-12700K,
    software only (to 1080p, 5 to 8×). The 8-bit H.264 keeps the HDR10
    tags without tone mapping: fine on the 43S45, unseen on a TV without
    HDR. Jellyfin untried.
- **MaxWidth from the TV** (Chad on #77: his stick is 1080p, and a 4K
  re-encode costs about four times a 1080p one). A file re-encoded anyway,
  over 20 Mb/s, asks for the width of the TV's video mode
  (`NxMaxWidthFor`, from `GetVideoMode`: 1920 at 1080 lines, 1280 below,
  3840 at 2160 or when the mode can't be read; the 43S45 reads `2160p60`,
  where ECP's `ui-resolution` says 1080p). A file that may be copied
  keeps 3840: a narrower `MaxWidth` makes Emby re-encode what it would
  copy. On the lab Emby (2026-10-23), with the ceiling above the file, a
  46 Mb/s 4K HEVC clip came back copied at 3840 and as 1080p H.264 at
  3.5 Mb/s at 1920.
  - No fixed 1080p bitrate: Emby runs libx264 at CRF 23 with the
    request's `VideoBitrate` only as `-maxrate`. The 26.5 Mb/s La La Land
    clip at 1920 came out at 2.0 Mb/s with a 40 Mb/s ceiling and with an
    8 Mb/s one (at 3840, 5.9 Mb/s). The soft 1080p above was seen on a 4K
    TV.
  - HDR: every re-encode measured, at 3840 and 1920, was 8-bit `yuv420p`
    still tagged `smpte2084` and `bt2020`; Emby's chain has no tone
    mapping. The app prints the TV's video mode and
    `GetDisplayProperties` at launch, so a tester's console shows whether
    the display takes HDR.

## How it fits the app

Channels, filtering, enrichment, the guide, saved libraries and package
switches work on scanned items, and a Jellyfin or Emby item is made into the
same shape as a Plex one, so none of them changed. What does differ by server:

| Step | Plex | Jellyfin and Emby |
|---|---|---|
| Sign-in | `PlexSignInTask`, the plex.tv/link code | `components/ConnectView.*` and `MediaBrowserSignInTask`: the 7359 broadcast or a typed address, the address asked who it is, then Quick Connect (Jellyfin), a user tile, or a username and password |
| Saved server | registry `plex` section, `servers` | the same list, one server with `kind`, `uri`, `userId`, `accessToken`, keyed by the server's `Id`; `kind` in the section too (`source/mediabrowser/ServerKind.brs`) |
| Library | `NxPlexScanServer` | `NxMbScanServer` (`MediaBrowserLibrary.brs`), chosen by `NxScanServerFor` |
| Change signature | section stamps | none, as upstream, so each load scans |
| Collections | `NxCollectionsFetchPlex` | `NxCollectionsFetchBoxSets` (`source/collections/Collections.brs`) |
| Playback | `NxPlexStreamContent` | `NxMbStreamContent` (`MediaBrowserPlayback.brs`), both through `NxStreamContent` and `NxApplyStreamAuth` |
| Stop | Plex's transcode stop | `DELETE /Videos/ActiveEncodings`, through `NxStopStream` |
| Launch check | plex.tv account | `GET /Users/{id}`; a 401 signs out to CONNECT YOUR SERVER with the reason |

**One kind at a time, as upstream does.** The Apple TV app holds one
`backend_kind`: a TV is signed in to Plex, or to one Jellyfin server, or to
one Emby server. Mixing them would mean channels that cross backends, which
upstream doesn't do.

**HLS built on the TV, not taken from PlaybackInfo.** That would be a POST
before every tune, and PlaybackInfo had Jellyfin burn subtitles into the
picture (above). Direct play when the TV decodes the file (MKV only on the
home network), else `master.m3u8` copying the video. "Decodes" is the TV's
own answer, as for Plex: `CanDecodeVideo` with the codec and profile and
`CanDecodeAudio` with the codec, then with the channel count
(`source/util/DirectPlay.brs`), so a Main 10 file on a TV that takes only
8-bit HEVC goes to the server, and so does 5.1 AAC on a TV that says no to
6 channels: a Streaming Stick Plus played that as stored with no sound.

**The audio track is picked, not left to the file (issue #78).** The
server hands over the track a file marks default, and plenty of files mark a
dub: O Brother, Where Art Thou? came through in Portuguese. As the Apple
TV's `JellyfinPlaybackResolver.preferredAudioIndex` does, a file with more
than one audio track gets a track in the TV's language or English, most
channels first, then the default, then the first (`NxMbPreferredAudioIndex`
in `MediaBrowserPlayback.brs`). Since #62 the language is Settings > AUDIO
LANGUAGE, the TV's until chosen, and a track in it comes before English
(`NxMbChosenAudioIndex`): a German viewer gets the German stereo track over
an English 5.1 one, where upstream's order, which wants both, takes the 5.1.
A track the server titles a commentary ("commentary" anywhere in its Title or
DisplayTitle, any case) is dropped before any of those steps while the file
has another audio track (`NxMbSkipCommentary`, as the Apple TV's
`skippingCommentary`; #236, from #153: a commentary marked default, or with
more channels than the film's track, was picked). So a German viewer's film
with a German commentary and an English film track plays the English track.
A file of commentaries alone picks among them. The player-side picks do the
same by the track's Name (`NxAudioTrackForLanguage`, which a Plex stream goes
by, and `NxAudioTrackToSelect`'s short list). A direct play's pick the player
names a commentary beside another track goes to a film track
(`NxAudioTrackPastCommentary`, #246): Emby 4.10.1.0 kept no title for a lab MP4's
audio tracks, so its pick can be a commentary the Roku names one. On the 43S45 (2026-11-10, lab Jellyfin
12.2.0) The Hills Have Eyes (1977), English mono beside three English stereo
commentaries, played a commentary on main on both a direct play and a server
stream, and the film's track with this. The scan keeps those files' tracks
(`NxMbAudioTracks`; one-track files keep nothing extra). The server stream
asks for the pick with `AudioStreamIndex`, and direct play is decided on the
picked track's codec, so an English Opus track behind a dubbed AAC default
goes to the server rather than playing the dub as stored. On a direct play
the player selects the pick from `availableAudioTracks` (`NxAudioTrackToSelect`),
once the first picture is up: switching while the start still buffered ended
it on a TCL 43S45 and stalled it 15 s on a Streaming Stick, and the switch
after it costs one rebuffer (2.4 to 2.9 s on a full film in #106, 0.5 s on a
60 s lab clip). It sets only a track the player isn't on: on the 43S45,
setting the one it was on caused no rebuffer. It picks
by position when it lists as many tracks as the file has, else by language:
once, on a full library, the 55R617 below listed one track for a file the
scan said had more (which file, and so why, wasn't recorded).

On a TCL 55R617 (Roku OS 15.3.4, English) against the test Emby, 2026-10-23,
with 60 s lab clips whose tracks carry different tones: a Portuguese AAC
default ahead of English Opus 5.1 came back from Emby as English
(`-map 0:2`), where the old request mapped the Portuguese `0:1`. On direct
play the Roku listed the tracks in the file's order (`2=por 3=eng`) and
already played English on its own, whether the Portuguese default came
first (AAC, and E-AC-3 5.1 as on O Brother) or the English default came
first, so it picks by its language and not by the default flag; the
selection agreed each time. That run was the build before the by-language
fallback; only the by-position path ran on the TV. Against the test
Jellyfin (12.2), server only: the same request without an index returned
the Portuguese default for AAC, E-AC-3 and Opus clips alike, and with
`AudioStreamIndex=2` the English track.

**A track's language is one code (issue #119).** Every pick reads a
track's language through `NxSubComparableTag`: the language without its
region, and a three-letter code as its two-letter one from ISO 639-2, both
forms. Comparing first letters made `est` (Estonian) Spanish, `arm`
Arabic and `jav` Japanese, and left `cze` not Czech. A code with no
two-letter form, such as `yue` (Cantonese), stays as it is, so a Cantonese
film still counts as foreign for FOREIGN AUDIO; `und`, `mul`, `zxx` and
`mis` match nothing. On a TCL 43S45 (Roku OS 16.0.4) against the test Emby,
2026-10-27, AUDIO LANGUAGE on SPANISH, with 120 s lab clips holding an
Estonian 5.1 default (500 Hz) and a Spanish stereo track (1,500 Hz): the
server stream asked for `-map 0:2`, the Spanish track, and direct play
selected track 3 (`spa`). Main without the change, same settings, took the
Estonian `0:1` and track 2.

**Forced subtitles come as a sidecar (issue #63).** A film's forced track
in SUBTITLE LANGUAGE (the lines it always shows, such as dialogue in
another language) is shown whatever SUBTITLES says, as on the Apple TV. The
scan keeps a file's forced text tracks (`NxMbForcedSubs`); at tune the
content carries the first in SUBTITLE LANGUAGE as the server's SRT
(`/Videos/{id}/{source}/Subtitles/{index}/0/Stream.srt`, which both servers
answer without a token), and `applySubtitles` selects it when no full
track is showing, over the guide too, as a burned-in line would be. With
SUBTITLES on, a full track in the language comes first, as
`pickLegibleOption`. Measured on a TCL 55R617 against the test Emby,
2026-10-26:

- The Roku doesn't list a forced track inside the file: of *American Dad!*
  "Pilot"'s 23 SRT tracks it listed 22, all but the forced one, and of
  *Little Amélie*'s four, three. So a direct play can't show it from the
  file.
- The sidecar showed: a dev screenshot at 4:59 caught the forced line
  ("Foolish round-eye, your failure will blossom like a thousand cherry
  trees."), the server's cue word for word. The player renames the track
  `<dev_3_0>http://…` and keeps its Description.
- It never held up the picture: 3.3 s with the file ready, 4.0 s while Emby
  was still making it.
- The player waits 30 s for the file, twice, then plays without it; a
  refused file (Emby's 500, or the empty 200 it gives a wrong index) it
  asks once and plays on at once. A
  server makes the file from the whole video the first time: Emby 330 s
  for a 6.6 GB film (96 s when asked again after its copy was deleted),
  27 s for a 165 MB episode just read by a failed burn-in; Jellyfin 48 s
  for that episode. After that each server answers from its own copy in
  milliseconds. So every 5 minutes the guide asks for the files of airings
  on now or within the hour, once each and one at a time
  (`NxForcedWarmList`, `SubtitleWarmTask`). The console prints each
  file's answer and time; the list of files asked starts again past 500.
- Burning the track in, as the Apple TV does
  (`SubtitleStreamIndex=<index>&SubtitleMethod=Encode` on the stream), works
  on Jellyfin and not on Emby: Emby's ffmpeg reads the whole file for the
  subtitle before its first segment, and Emby stops it after 15 s
  ("Error starting ffmpeg", HTTP 500). With the file just read, a 165 MB
  episode made it in 12.9 s.
- Image tracks (PGS, VobSub) aren't kept: as SRT Emby answers an empty
  file. On the test Emby 297 items have an English forced track, 28 of them
  only as an image; those play without it.

**With SUBTITLES on ALWAYS, a server stream's full track is a sidecar too
(issue #120).** A server stream's playlist lists no subtitles: on Emby 4.10
the app's request for *Wuthering Heights* (28 SRT tracks) gives 0 renditions,
and still 0 with `SubtitleStreamIndex=2&SubtitleMethod=Hls`. Jellyfin 12.2
lists them with that query (37 for *28 Years Later*), but each address
carries the token as `ApiKey` in the URL, which the port keeps out of URLs.
So the full track comes the way the forced one does: the scan keeps a
file's other text tracks, the first per language (`NxMbFullSubs`), and on a
server stream with ALWAYS the one in SUBTITLE LANGUAGE (`NxMbFullSub`) goes
beside the stream as the server's SRT (`NxMbSubtitleSidecars`), which
`applySubtitles` picks as it would the file's own. A direct play lists the
file's own and gets none. When the file has no track in the language,
nothing is added: the Apple TV falls back to the first track
(`preferredTrackIndex`), which can be a commentary or a language nobody
picked. Only on ALWAYS, so a server makes the file only for a viewer who
reads it; the warm-up asks for it too, for airings this TV won't play as
stored (`NxMbDirectPlays`, STREAM QUALITY's ceiling included, so a file
LOW sends to the server is warmed too). Measured on a TCL 55R617 (Roku OS 15.3.4)
against the test Emby, 2026-10-28, with silent lab clips:

- *Lab Forced Opus* (English forced and full tracks; a Portuguese AAC and
  an English Opus track, so with AUDIO LANGUAGE English a server stream),
  ALWAYS, English: two sidecars, picture in 2.2 s, and a dev screenshot at
  0:21.5 caught the full track's line. Emby's log has the full file asked
  on every start. On the two `item:` starts from another film it was the
  only request, so the forced sidecar, attached but not picked, wasn't
  fetched. On three `item:` links that started the same film again while
  it played, the forced file was asked about 1.5 s before the full one,
  though the app didn't pick it (no `forced subtitles` line); why isn't
  known. When the app showed the forced track over the guide, its file was
  asked then. With SUBTITLES OFF, one sidecar, the forced one, and one
  request for it. With SUBTITLE LANGUAGE on French, none and no request.
  Jellyfin 12.2 the same way: two sidecars, picture in 2.4 s, the full line
  on screen at 0:21.
- *Lab Full Big Opus* (3.6 GB, 2 hours), cold: picture in 2.1 s; Emby made
  the SRT in 1.5 s from local disk, so this didn't stand in for a slow NAS.
- A file the server is slow to make, or refuses: on a throwaway build whose
  full sidecar pointed at a stand-in server, a file answered after 90 s,
  a 500 and an empty file each left the picture at 2.1 to 2.4 s and the
  clip playing. The slow one was asked twice, 30 s apart, and not again, as
  a forced file is.

**No reporting to the server.** The Roku app sends Plex nothing about what you
watch, and its privacy policy says so; Jellyfin and Emby are the same, which
also leaves out upstream's watch-state restore.

## Playback spike (2026-10-18)

Before building the rest: a throwaway app on a 1080p TCL Roku TV (OS 16.0.4)
played each case with `PlayStart = 1200` (20 minutes in) and the token only in
`HttpHeaders`.

| Case | Playing after | Rebuffers in 60 s |
|---|---|---|
| Jellyfin MP4 H.264, direct | 2.6 s | 0 |
| Jellyfin MP4 HEVC 10-bit (`hev1`), direct | 1.5 s | 0 |
| Jellyfin MKV HEVC 10-bit, direct | 3.6 s | 0 |
| Jellyfin MKV HEVC, PlaybackInfo HLS, fMP4 | 2.6 s | 0 |
| Jellyfin MKV H.264, PlaybackInfo HLS, TS | 3.3 s | 0 |
| Jellyfin MKV HEVC, hand-built HLS, fMP4 | 5.7 s | 0 |
| Emby MP4 HEVC 10-bit, direct | 1.7 s | 0 |
| Emby MKV HEVC, PlaybackInfo HLS, fMP4 | 1.6 s | 0 |
| Emby MKV H.264, hand-built HLS with `PlaySessionId`, TS | 3.0 s | 0 |

- **How each row was checked.** The player reached `playing`, and its
  position advanced about 55 s per minute from 1200. Developer screenshots
  don't capture the video plane, so the picture itself wasn't seen.
- **Seeking on the client works.** HLS joins needed no `StartTimeTicks`: the
  player asks for the segment at the offset, and both servers start there
  within a second or two.
- **Direct MKV joined fine here**, unlike the MKV crawl seen through Plex.
  That was over HTTPS and this was plain HTTP on the LAN, so it isn't the same
  comparison.

## Tests

- **The scan:** `tests/gen-mediabrowser.mjs` runs upstream's own
  `fetchJellyfinLibraryFromServer` over `tests/fixtures/mediabrowser-server.json`
  (answers trimmed from a Jellyfin 12.2 server, plus made-up cases), and
  `tests/MediaBrowserTests.brs` holds `NxMbScanServer` to its requests and
  items. It also covers dates, typed addresses, `/System/Info/Public` and
  sign-in answers, and the audio pick: upstream's
  `AudioTrackSelectionTests.swift` cases transcribed, which track direct
  play is decided on, and which listed track a direct play selects.
- **On the TV:** the rest was checked by driving a TV over ECP (above):
  sign-in each way, a guide build, joining part-way, a channel change stopping
  the stream, sign-out, and a refused sign-in.
