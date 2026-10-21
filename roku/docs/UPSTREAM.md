# Working with upstream

[Discussion #8 "Roku App"](https://github.com/chadMueller/Nostalgex/discussions/8)
(2026-10-08) asked for Roku. The maintainer replied on 2026-10-09 that it is
not on the roadmap: "Roku needs its own language and I'm one person keeping the
Apple TV app and the web tuner in step." So the port was built as a separate
repo, `tydude001/nostalgex-roku`. On 2026-10-16 they settled that it lives
here in `roku/`, with PRs from the port author's fork (below), and on
2026-10-20 they imported `7bde5df` with its history.

## Reply posted to Discussion #8

[Posted](https://github.com/chadMueller/Nostalgex/discussions/8#discussioncomment-18901675)
on 2026-10-13.

> Hi! Since Roku isn't on the roadmap, I built a port:
> https://github.com/tydude001/nostalgex-roku
>
> It treats Nostalgex as the source of truth. `channels.json` is vendored
> unchanged, and the schedule builder, channel filter and lineup are ported to
> BrightScript and tested against golden vectors generated from your JS. The
> library loader was also compared with `plex-tuner.html` on a real Plex
> library, and the results matched. It signs in with a plex.tv link code and
> has the Apple TV guide layout, packages and playback. It's Plex only, installs
> by sideloading for now, and doesn't have the MusicBrainz/Deezer music-video
> enrichment yet.
>
> It's a separate MIT repo that credits Nostalgex, so it adds nothing to your
> load. Three questions:
>
> 1. Should it stay a separate project, or would you eventually want it in
>    this repo?
> 2. I measured parity against the JS (`plex-tuner.html` and the `scripts/`
>    modules). Is that the reference you want, or the Swift?
> 3. May it use the Nostalgex logo? For now the logo, icon and splash are text.

## The maintainer's answer

[Replied](https://github.com/chadMueller/Nostalgex/discussions/8#discussioncomment-18907140) on
2026-10-13. They read the code, and said checking the filter against vectors
from their filter script is how they want parity checked.

1. **Where it lives:** undecided, so it stays a separate repo for now. Longer
   term they could see it in their repo as `roku/`, reading the same
   `channels.json`, memberships and franchise files directly. If so, the repo
   owner is credited and invited to co-maintain.
2. **Reference:** the JS — `scripts/nostalgex-channel-filter.cjs` and the
   shared JSON files. They pointed at FRANCHISES (`franchises.json`,
   `scripts/nostalgex-franchise-builder.js`, golden file
   `scripts/franchise-golden.json`) as new since the posted snapshot
   (c2f32e6). It is ported, engine only ([PORTING.md](PORTING.md)).
3. **Logo:** held until where the port lives is settled.

They plan to try it on a Roku and give feedback in the discussion, and invited
the repo owner to the project Discord. The owner keeps it to GitHub, so
drafts don't offer Discord.

[Followed up](https://github.com/chadMueller/Nostalgex/discussions/8#discussioncomment-18908210)
the same day: a separate repo is fine, the builder is ported and passes
`franchise-golden.json`, and should the Roku guide show franchise channels
now, following the Apple TV app, or wait for the web tuner?

[Asked](https://github.com/chadMueller/Nostalgex/discussions/8#discussioncomment-18937338)
on 2026-10-14, in the same thread: may the Roku app use upstream's TMDB/OMDb
relay and shared `media_enrichments` cache as `nostalgex-enrichment.js` does,
and under which `X-Nostalgex-Client` value?

[Answered](https://github.com/chadMueller/Nostalgex/discussions/8#discussioncomment-18953180)
on 2026-10-15:

- **Franchises:** the Roku follows the Apple TV app and shows franchise
  channels now. Done ([PORTING.md](PORTING.md)).
- **Enrichment:** yes, through the relay and the shared cache, as
  `X-Nostalgex-Client: roku`. On 2026-10-15 the relay still answered `roku`
  with 403, since `api/tmdb.js` accepts only `tvos`, `web` and `selfhost`. The
  Supabase URL and anon key are build settings upstream, not in its repo, as
  in its Docker image. The port's enrichment stays out of builds until the
  relay accepts `roku` ([PORTING.md](PORTING.md)).
- **An official app:** they would like to publish it as the official Nostalgex
  app for Roku, under the Nostalgex name with full credit to the repo owner,
  and offered to talk about how to work on it together.

[Replied](https://github.com/chadMueller/Nostalgex/discussions/8#discussioncomment-18954700)
on 2026-10-15: yes, and asked where the code lives (PRs or commit access to
`roku/`), whether the store listing goes on their Roku developer account, how
the credit should appear, and whether it may use the logo. Also reported that
franchise channels are in, and asked for `roku` on the relay and which
Supabase URL and anon key Roku builds should use.

[Answered](https://github.com/chadMueller/Nostalgex/discussions/8#discussioncomment-18961197)
on 2026-10-15, on enrichment only; the four official-app questions are still
open:

- **Relay:** accepts `X-Nostalgex-Client: roku` now (upstream bfb4453). Four
  read-only TMDB routes (`movie/{id}` and `tv/{id}` with
  `append_to_response=keywords`, `collection/{id}`, `search/collection`) plus
  `omdb/{imdbID}`, cached at the edge, nothing logged. `roUrlTransfer` sends
  no Origin, so no CORS handling is needed.
- **Cache first:** read the shared Supabase cache with the anon key and hit
  the relay only on a miss, as the Apple TV app and web tuner do.
- **OMDb:** the free tier is 1,000 requests a day across every client
  together, so cache aggressively.

They said the anon key is "already in the repo"; it isn't, upstream's source
has only placeholders. The URL and key are in the built web tuner, in the
`nostalgex-supabase-url` and `nostalgex-supabase-anon-key` meta tags of
`https://www.nostalgex.app/plex-tuner` (project `ljlhreomwcsyhiytqipm`, JWT
role `anon`).

[Replied](https://github.com/chadMueller/Nostalgex/discussions/8#discussioncomment-18963114)
on 2026-10-15 with the first TV run ([PORTING.md](PORTING.md)), asked whether
Roku builds should read that Supabase project or a separate one, and withdrew
the logo question: the owner keeps the port's own logo, icon and splash.

[Answered](https://github.com/chadMueller/Nostalgex/discussions/8#discussioncomment-18982798)
on 2026-10-16, after installing it on a Roku Stick Plus (OS 15.3.4). The
vectors pass on that device, the schedule matches the web tuner, and
enrichment through the relay works. The official-app questions are settled:

- **Where the code lives:** `roku/` in upstream's repo, with PRs from the
  repo owner's fork to start.
- **Who publishes:** the store listing goes on the maintainer's Roku developer
  account, and the repo owner prepares the builds.
- **Credit:** to the repo owner, in the app and in the listing.
- **Supabase:** the web tuner's project. The maintainer confirmed the anon key
  was never in the repo.

They reported six problems from their device, biggest first: transcoded
streams start from zero, a memory crash with 45 channels on
(`EXIT_CHANNEL_MEM_LIMIT_FG` while saving), every server on the account is
loaded instead of owned ones, the sign-in code never refreshes on screen,
deep links never match on a real Roku (the id arrives as `roInteger`), and
`*` in the guide signs out with no confirmation. They want the look as close
to the Apple TV app as it can get, guide first, from the App Store shots,
nostalgex.app/screens and `Nostalgex/Nostalgex/Views` (both 1920x1080).

[Followed up](https://github.com/chadMueller/Nostalgex/discussions/8#discussioncomment-18982978)
12 minutes later, as a reply under that comment, with a seventh problem and
the bar for the Channel Store. Seventh: turning a package on re-reads the
whole library from every server (3.5 minutes for them) instead of rebuilding
from the saved library as the Apple TV app does. The bar, on a normal
library:

- the guide ready in under 2 minutes on a first run, owned servers only;
- converted (transcoded) channels starting in under 10 seconds, mid-programme
  included;
- no crash with every package on, and no rescan when one is switched;
- the guide looking like the Apple TV one: layout, fonts and colours.

The Apple TV app's versions to look at: the library saved in chunks
(`LibrarySnapshotStore.swift`), transcodes started at the offset server side,
owned servers only. They put every pushed build on their stick and report
within a day, console log on request.

[Replied](https://github.com/chadMueller/Nostalgex/discussions/8#discussioncomment-18984559)
on 2026-10-16: all six fixed (`f237f6c`, memory also `62dc326`), saying which
were checked on a TV and which weren't (the server rows, the sign-in code,
the sign-out confirmation). It reported the saved pools file going from 30 MB
to 3.5 MB, asked for the `saved the pools` console line from their larger
library, agreed to `roku/` via PRs and the listing on their account, and said
the Apple TV look comes next, guide first, then the PRs. It missed the
follow-up above, posted two hours before it.

[Followed up](https://github.com/chadMueller/Nostalgex/discussions/8#discussioncomment-18984628)
the same day: took the four points as the bar for the Channel Store, said
where each stands (the rescan not fixed, the first run and transcode start
not timed, every package on not tried, the look after those), and asked for
their `saved the pools` line and a converted channel's start time.

[Reported the bar](https://github.com/chadMueller/Nostalgex/discussions/8#discussioncomment-18987342)
on 2026-10-16, at `008da95`, leading (after an edit) with the default
lineup's first run, 38 s after sign-in; then no rescan on a switch (0.9 s,
from the saved library), six converted
channels 1.8 to 13.2 s (the slow one waiting on Plex, unconfirmed), every
package on without a crash, and the guide ported from the Apple TV views with
RETRO MODE on by default. It named the two misses (that channel, and 131 s
for a 70-channel lineup) and the look's three deliberate differences, and
asked for their `guide on screen` and `picture after` console lines.

[Followed up](https://github.com/chadMueller/Nostalgex/discussions/8#discussioncomment-18998165)
on 2026-10-17, at `5a0cead`: a FRANCHISES first run in 103 s on the
55R617, 61 channels against the earlier 70 in 131 s, from a 3.7x faster
channel build and a 24x faster franchise step, both with identical results.
It said 58 s of it was a library read slowed by one retried request, and
asked for their `built … channels` and `guide on screen` lines.

[Answered](https://github.com/chadMueller/Nostalgex/discussions/8#discussioncomment-19003344)
on 2026-10-17, from `5a0cead` on their Stick Plus (11,684 owned items plus 3
shared servers): guide on screen 114.5 s after sign-in with 19 channels, the
build 12 s, most of the rest checking the shared servers' local addresses one
at a time. Converted channels gave a picture in 2.1 to 2.5 s, direct play 0.3
to 1.9 s. Bug 7 is fixed (a package switched on from the saved library in 2 s),
and the code refresh and sign-out changes work. The `link` test case fails only
on the text compare, because the Roku lowercases `contentid`. They asked for
Apple TV behaviour next: the onboarding order (library picker before the
progress rail, no server checks before it, no local-address retries during
playback), the Settings order with My Collections folded, a package switched
on in place with a spinner on its row, the full-screen controls of
`PlayerView.swift`, a fix for a stale tune setting the title overlay after
quick Up/Down flips, and the logo PNGs from upstream's `logo/`. Every package
on is to be tried on the next build.

[Replied](https://github.com/chadMueller/Nostalgex/discussions/8#discussioncomment-19007810)
on 2026-10-17, leading with all six in `791f31e` and the server checks no
longer holding up the first run: servers listed at sign-in, CHOOSE YOUR
LIBRARIES when there is more than one, only the picked ones checked, all at
once and by identity, then the step rail (51 ms and 24.2 s here, not a first
run). Then the Settings order, a package built in place (fingerprints equal
to a full rebuild), full screen as PlayerView with the sleep timer, the
latest-press fix and the wordmark. It named what one server can't show (the
picker, several servers, three of the logo's screens), noted their Apple TV
app still uses the old bolt logo, fixed `link` (`02cc134`), and asked them
to sign out and in on `02cc134` for the `checked`, `libraries picked` and
`guide on screen` lines, and every package on.

[Followed up](https://github.com/chadMueller/Nostalgex/discussions/8#discussioncomment-19008971)
on 2026-10-17: use `94f1a2e` instead, since on `02cc134` the progress screen
rebuilt itself on every update and the Collections step took 457 s on the
55R617 (1.1 s fetches, 66 s and 136 s of updates per 25), 10.3 s after the
fix. It noted the Library step's 12.2 s to 8.2 s as one run each, that a
stalled load can look like the app quitting (screensaver, then Back), and
that the sign-out steps and four log lines still apply.

[Answered](https://github.com/chadMueller/Nostalgex/discussions/8#discussioncomment-19018694)
on 2026-10-18, on `0eba225`: the picker, progress screen, Settings, full
screen and logo look solid and every test passes on the stick. Server checks
95 ms, a true first run 50.2 s to the guide (19.3 s with the saved library),
packages up to 81 channels at 41% memory. Next round, in order: a package
build never reaching the guide (`status` without `alwaysNotify`), leaving
Settings while it builds (52 s and 44 s; unchanged switches 28 s),
prebuilding other packages if memory allows, Jellyfin and Emby, whole-title
exclusive locks (`805c33e`, `scripts/filter-golden.json`), the MIT text in
the package, and a reinstall keeping the saved library for another account.
A [reply under it](https://github.com/chadMueller/Nostalgex/discussions/8#discussioncomment-19018852)
gave the Apple TV's stronger retro mode numbers (scanlines, vignette,
flicker, tracking line) to match.

[Replied](https://github.com/chadMueller/Nostalgex/discussions/8#discussioncomment-19019523)
on 2026-10-18, leading with item 1 fixed in `a028bf8`, checked before and
after on the 43" TCL: `0eba225` showed the symptom, and of about 25 switches
on `a028bf8` to `6cc4290`, 23 built in place (5 checked on screen). The other
2 fell back to a full rebuild; the logged one found no saved library for the
server in `cachefs:`, guessed but not proven to be the OS clearing it, and
`6cc4290` logs the cause. It said item 2's waits are most likely the build
itself, noted items 3 to 7 and the retro numbers, and asked them to try
`6cc4290`.

[Followed up](https://github.com/chadMueller/Nostalgex/discussions/8#discussioncomment-19020451)
on 2026-10-18: a switch with nothing new to build went from 5.2 s to 3.0 s
in `7112b9c` (channels too small for the guide are reused, fingerprints
equal to a full build), with where the 3.0 s goes and why the library load
stays. Item 2 already works with `a028bf8` (Back at once, channels arrive
11.8 s later), asking what "the guide shows it's building" means beyond
`BundleManagerView`'s spinner. Item 3: memory from `58213cc` (library about
11 MB of a ~195 MB limit, KIDZ ZONE 22% to 32%), holding off on prebuilding
unless the stick shows room. Asked them to try `58213cc`.

[Reported](https://github.com/chadMueller/Nostalgex/discussions/8#discussioncomment-19026577)
on 2026-10-18 that item 4 works on the 43" (`eeb42f3`).

- **Jellyfin:** Quick Connect, the guide on screen 21 s after sign-in, and 15
  channels on air against 16 through Plex.
- **Emby:** a password sign-in and the guide in 18 s; the test server's channel
  count isn't meaningful until its rescan is done.
- **The scan** is held to upstream's own function by `gen-mediabrowser.mjs`.
- **Differences from upstream:**
  - one kind of server at a time;
  - the token in a header;
  - HLS built on the TV, not taken from PlaybackInfo, with the subtitle burn-in
    seen there and a suggestion to check it on the Apple TV;
  - nothing reported to the server;
  - no collections yet.

It told them:

- their clients start Quick Connect with a GET, which Jellyfin 12.2 answers
  with 405;
- their privacy policy's Roku section says Plex only;
- Jellyfin 12.2, unlike Emby 4.10.1, cancels a device's previous token when it
  signs in again.

It reported items 5 to 7 done (`ffd2ef8`), asked them to try `eeb42f3`
against their Emby, and noted that items 1 to 3 wait on their run of
`58213cc`.

[Answered](https://github.com/chadMueller/Nostalgex/discussions/8#discussioncomment-19045881)
on 2026-10-19, on `49f5df7` on a Streaming Stick Plus (OS 15.3.4, 513.8 MB
limit) with all 14 packages on, about 120 channels, 11,687 Plex items:

- **Working:** 7 of 11 package switches built in place with fingerprints
  equal to a full build. Leaving Settings mid-build works. Emby signed in,
  played direct and HLS, and relaunched in 754 ms, with no `api_key` in any
  address. Every test passes off the TV.
- **On the stick:**
  - mediabrowser fails 2,245: 2,232 from the test's case-sensitive key
    compare against the TV's lowercased keys, and 13 real ones,
    `NxMbUnixSeconds` rounded to float32.
  - Emby fetched HLS segments twice over (177 GETs for 81 segments in 82 s)
    and answered 7 with 500.
- **Their order for next:**
  1. The OS clearing `cachefs:` (twice in about 25 minutes), which made a
     switch a silent 2.5-minute rescan.
  2. Scheduling: 13 to 18 s per switch, and 9 to 10 s of a core every 30 s.
  3. Memory held per build in one task (40% to 64% to 74%); hold off on
     prebuilding until these are sorted.
  4. `tune(0)` after a Settings rebuild, and the new-day launch (20.9 s to the
     guide; certification wants under 15 s).
- **Later:** Now Playing opening on a greyed-out CC row, the tuned row's
  shorter name, a 30 px sliver under the time header, a hint on the BUILDING
  row, and every launch rerunning the full build.
- **Dropped from their list:** FRANCHISES' single channel and SCREAM on top in
  October are upstream's own defaults.
- **From their side:**
  - Retro mode numbers in `e48cdc1`.
  - Quick Connect's POST in their main and Docker `tuner-v1.0.2`, credited.
  - Their subtitle burn-in confirmed and being fixed; `SubtitleStreamIndex: -1`
    sticks only with a matching `MediaSourceId`.
  - The privacy page gets a Jellyfin/Emby line when the Roku app ships with
    them.

[Replied](https://github.com/chadMueller/Nostalgex/discussions/8#discussioncomment-19047518)
on 2026-10-19, leading with items 1 to 4 in `a18a256`, 1 to 3 checked on the
43S45. Memory held at 36 to 39% over six switches of one package, and every
test passed on the TV.
- **Items 1 to 3:** a switch builds from the library in memory and keeps the
  day's schedules; the 30 s re-check acts only on a new hour or day.
  - Off the TV, scheduling for a switch went from 41.6 s to 11.5 s.
  - On the TV, switches on took 6.4 to 12.0 s, and a switch off 5.7 s.
- **Item 4:** franchise and collection switches build in place; a launch
  reuses the last filter results (6.2 s to 18 ms here); today's schedule goes
  up before tomorrow's.
- **Not tried on a TV:** the re-save after a purge, the cleared-library
  message, a server switch keeping the channel, and the new-day launch.
- **The smaller items:** done. Their Now Playing opens on CC too, and their
  bolt badge narrows the name too.
- **Emby:**
  - 4.10.1 starts ffmpeg again for every segment after a join part-way into
    a file whose audio it converts (26 starts in 11 s, also with curl).
  - That's the likely source of their 500s; a progressive stream is next.
  - It asked whether their Apple TV hits the same.
- **Also reported:** the hand-over loop on refused starts (`d991621`).
- **Asked them to:** run `a18a256` with every package on, checking switches,
  memory, the second launch and the first launch of a new day.
- **Still to do:** the retro numbers from `e48cdc1`.

[Followed up](https://github.com/chadMueller/Nostalgex/discussions/8#discussioncomment-19049078)
on 2026-10-19, leading with the schedule matching theirs across the clock
changes (`e1ef341`, the `dst` lineup cases, passing on the 43S45).
- **Two of theirs, kept in the port:** a day packs 24 hours, so a 25-hour
  Nov 1 can have nothing scheduled before its midnight; and on 2027-03-15
  "yesterday" is Mar 13 (web and Swift). It asked what their Apple TV shows
  at 11:30 PM on Nov 1, and suggested stepping the calendar day.
- **Bugs found by reading the code** (`469740f` to `b9bd4ff`):
  - a package switch unanswered after a refresh that reached no server;
  - Settings showing the last build's packages;
  - the retry landing on another channel;
  - a waiting tune's stale index;
  - and smaller ones.

  The first two were checked on the 43S45.
- **Also reported:** a nested `for each` over one array sharing its place on
  a TV.
- **Asked them to:** run `76d27d0` in place of `a18a256`.

[Answered](https://github.com/chadMueller/Nostalgex/discussions/8#discussioncomment-19074710)
on 2026-10-20, on `5e925ba` on the Streaming Stick Plus (OS 15.3.4, Plex,
11,686 items), installed over `49f5df7`, so the first launch was a new day.
On Plex it clears their bar on the stick.
- **Switches, all 14 on (123 channels):** off 17 to 20 s, the new lineup up
  about 13 s after the press (was 33 to 35 s); on 21 to 35 s (was 43 to 57 s);
  `scheduled in` 2.6 to 3.7 s (was 13 to 18 s). Fingerprints match a full
  build. Idle in the guide about 2% CPU; the hour change about 4 s at 12%.
- **Memory:** 32% to 66% turning on 11 packages in one task, then 66 to 68%
  over 8 switches at all-on, about 40% after the next tune, 43% on a fresh
  launch. No crash.
- **cachefs:** the stick cleared it mid-session and the re-save caught it in
  3.6 s with no rescan. The enrichment cache isn't saved again, so the next
  launch re-read 1,928 ids from Supabase (16.8 s, behind the guide).
- **Launch:** new day at 49 channels 7.1 s to AppLaunchComplete; same day
  1.1 s at 49 channels and 2.5 s at 123; a second launch reuses 122 channels'
  filter results and builds in 6.9 s (was 84 to 88 s). A cold deep link to
  CH 4 1.1 s, picture in 1.3 s; `/input` to CH 85 2.1 s.
- **Playback mid-programme:** HLS 1.3 to 3.8 s, direct MP4 3.7 to 6.3 s.
- **Checked on the stick:** a server-switch rebuild back on CH 85, Now
  Playing on RETRO MODE, the tuned row's name, the sliver gone, the BUILDING
  hint.
- **New ones:**
  1. Queued switches each do a full pass: 11 presses in a minute made 11
     builds, the last 6 no-ops of about 8.3 s each, busy 51 s. Drain pending
     `bundleRequest` events before `rebuildForBundles`.
  2. A launch that matches the saved guide still schedules both days (13 to
     14 s at 123 channels) and saves the pools again (5 s).
  3. A server switched on and back off in one visit still forces a full
     rebuild.
- **sca-cmd:** 0 errors, 4 warnings. Root `THIRD-PARTY-LICENSES.md` is an
  extraneous file (`licenses/THIRD-PARTY-LICENSES.txt` clears it); still
  missing `EnableMemoryWarningEvent`, `EnableLowGeneralMemoryEvent` and
  `GetChannelMemoryLimit`.
- **Two asks:** a QR code on the Plex sign-in screen
  (`https://www.plex.tv/link/?pin=<code>`, about 200 px, "SCAN TO CONNECT",
  after `QRCodeView` in `Views/SettingsView.swift`); and something in the
  guide while a package builds.
- **Upstream since `805c33e` (80 commits):**
  - `channels.json` v43 and memberships, 415 to 422 (SLASHER, HORROR COMEDY,
    FOUND FOOTAGE, WORLD HORROR, MYSTERY BOX TV, CRINGE TV, A24, TURKEY DAY);
    HALLMARK is now MISTLETOE, the holiday block at 145 to 152. Needs
    `2d1e237` first: episode rules on the item's own title, summary and air
    date, `matchTmdbGenres`, `type`/`source` on exclusive locks; loaders need
    `summary` and `originallyAvailableAt`. `filter-golden.json` has 87 cases.
  - `seasonStart` (`d0f897a`, `b67b28b`, `scripts/season-golden.json` in
    `f09fc86`): TIS THE SEASON from a week before US Thanksgiving (Nov 19).
  - Emby Dolby Vision profile 5 kept off channels (`5d6d65f`, `ccb6854`,
    golden cases in `95763c7`); Emby H.264 as TS segments (`72c844d`).
  - A forced subtitle track in the viewer's language burned in (`31b1193`,
    `a8ece18`); retro look values (`e48cdc1`).
- **Emby question:** every mid-programme join restarts Emby's encode for them
  too. Their problem was sync: with video copied and audio converted, fMP4
  stamps both tracks from zero, so sound ran early by up to a GOP (-1,720 ms
  vs TS +35 ms). The port sends `SegmentContainer=mp4` there; check sync on a
  Roku with TS. `JELLYFIN-EMBY.md` still says they send GET for Quick Connect.
- **Clock changes:** both are real and not changed on their side yet; keep
  matching theirs.
- **For a beta channel:** upstream caught up (holidays start Nov 19), the QR
  code and the guide notice, plus the Emby TS and DV5 changes if Jellyfin and
  Emby go in. Then name the commit; they'd import it into `roku/` with this
  history, sign it, and put it up as a beta.

[Replied](https://github.com/chadMueller/Nostalgex/discussions/8#discussioncomment-19078343)
on 2026-10-20, leading with every item on their beta list in `7bde5df`,
proposed as the commit to import once it passes on their stick.
- **Not yet checked, asked of them or left for us:** a phone scanning the
  sign-in QR, and sync after a mid-programme join on Emby with TS.
- **Upstream to `1b5859b`:** v43 with `2d1e237`'s filter rules, episode air
  dates and Emby's DV profile in the loaders, all 87 `filter-golden.json`
  cases, `season-golden.json` (SPOTLIGHTED NOV 19 TO DEC 31 seen on the
  43S45), and the pool-build season gate that `8160f04` had dropped. Emby
  H.264 as TS and DV5 off every channel, neither on a TV yet.
- **Not ported:** the burn-in changes (no PlaybackInfo here), the EAC3 cap
  and dvh1 signalling; asked whether they want any anyway.
- **Their asks and new items:** the QR code (matched to a reference encoder);
  the guide notice, seen; queued switches as two builds from three on the
  43S45; a same-day relaunch keeping its schedules (1.25 s); the server
  on-and-off compare, unpressed.
- **Also:** RetroLook, sca-cmd clean (`27d0c80` reproduces their four
  warnings), and caches keyed on a hash of the zip, with a one-time rescan
  (201 s on the 43S45).

[Answered](https://github.com/chadMueller/Nostalgex/discussions/8#discussioncomment-19085117)
on 2026-10-20: `7bde5df` passes on the Streaming Stick Plus (Plex, 11,687
items) and is the one they'll import.
- **Checked on the stick:**
  - The one-time rescan, with the guide up at 101 s (scan 18 s, build 53 s).
  - TIS THE SEASON: the BUILDING notice at once, channels 20 s after the
    press, SPOTLIGHTED NOV 19 TO DEC 31.
  - Queued switches: 3 in 5 s made 2 builds, and off-and-on during a build
    answered `the guide already has it`.
  - A same-day relaunch: guide 0.7 s, AppLaunchComplete 1.1 s, schedules
    kept.
  - 20 channel changes all played: HLS 1.4 to 4.0 s, direct MP4 3.5 to
    6.0 s, memory at most 51%, no crash.
  - sca-cmd clean, and every test passed on the stick.
- **Our two:**
  - The QR reads right, followed two code refreshes, and their phone
    signed the stick in.
  - Emby 4.10.1 with TS joined 48 s in: video copied, DTS to AAC, picture
    in 1.6 s. Sync not yet checked by eye.
- **Small, none blocking:**
  - Back on the live row goes to Home; a confirm is our call.
  - Jellyfin and Emby rescan every launch.
  - The screensaver still pauses the app.
  - The QR's quiet zone is about 2 modules.
- **Next on their side:** import `7bde5df` into `roku/` with its history,
  sign it, and put up the beta, staged the way `deploy.sh` does.

[Replied](https://github.com/chadMueller/Nostalgex/discussions/8#discussioncomment-19086119)
on 2026-10-20: `7bde5df` it is, with only tests and docs after it. The four
small ones stay as upstream has them unless they change theirs:
- Back on the live row follows `GuideExitAction`.
- Jellyfin and Emby have no library signature (`currentLibrarySignature`
  is Plex-only).
- The screensaver is kept off by playback, as their idle timer is.
- The QR's 2-module quiet zone was deliberate; we offered 4 if they want it.

[Reported](https://github.com/chadMueller/Nostalgex/discussions/8#discussioncomment-19087038)
on 2026-10-20: Emby TS in sync after a join (0 and -1 ms), fMP4 sound
2,048 ms early, measured off the stream and not yet watched on a TV
([JELLYFIN-EMBY.md](JELLYFIN-EMBY.md)).

[Answered](https://github.com/chadMueller/Nostalgex/discussions/8#discussioncomment-19099058)
on 2026-10-21: the beta is live, `7bde5df` as Nostalgex 1.0.1, signed on
their account (20 installs, until Feb 18), and #43 is merged.
- The four small ones stay as they are; the 2-module QR border scans fine.
- From here it's PRs into `roku/`, and they package and sign each release.
- Their fix for both clock changes (a day's length, "yesterday") is on a
  branch, not `main`; they'll say when it lands so the port can match.

[Replied](https://github.com/chadMueller/Nostalgex/discussions/8#discussioncomment-19099229)
on 2026-10-21: the beta goes on both TVs this evening, `nostalgex-roku` is
archived with a pointer to `roku/`, and the clock fix comes as a PR once it
is on their `main`.

[Answered](https://github.com/chadMueller/Nostalgex/discussions/8#discussioncomment-19103690)
on 2026-10-21: they ported the clock-change fix themselves (`85cb3a1`) and
shipped it as beta 1.0.2. `NxPackDay` takes `dayEndSec` after `dayStartSec`;
`nx_build` depends on the shell's sort locale. It ends "please pull it into
your fork before your next round:", which leads into the next post.

[Listed](https://github.com/chadMueller/Nostalgex/discussions/8#discussioncomment-19103692)
the same day: where Roku sits against the Apple TV, as phase 1 (ten items,
in the order testers hit them), phase 2, and theirs. Claim an item here
before starting it, then a PR into `roku/`.

[Claimed](https://github.com/chadMueller/Nostalgex/discussions/8#discussioncomment-19104645)
on 2026-10-21: phase 1's 2, 3 and 4 (decode-aware direct play, plain http to
home hostnames and Tailscale, the version line), one PR each. The decode
check asks the Roku rather than carrying over AVPlayer's limits such as DV
profile 7; Tailscale is covered by tests only, since our TVs aren't on it.
We'll start from `2f68a9e`, which has the fix and the 1.0.2 release. As
first posted it asked what followed the colon above; edited the same day,
once it was clear the next post was the answer.

[Reported](https://github.com/chadMueller/Nostalgex/discussions/8#discussioncomment-19110028)
on 2026-10-21: the beta on the living room TV (55R617, OS 15.3.4), about
50 s from Plex sign-in to the guide on a first launch (5,373 items) and
about 2 s to relaunch, counted by hand; and PRs #46 (decode check), #47
(home names), #48 (version line) and #49 (this file), each checked on the
43" first. `.local` got no answer on the TV, so the examples say `nas`.

## Channel ideas: Discussion #29

[Posted](https://github.com/chadMueller/Nostalgex/discussions/29) on
2026-10-14: a year-round horror package (FRIGHT NIGHT, NOSTALGEX HORROR,
SLASHER, FOUND FOOTAGE, HORROR COMEDY, WORLD HORROR), plus MYSTERY BOX TV in
CASE FILES, CRINGE TV in PRIME TIME and A24 in NETWORKS. It notes that SCREAM
is October-only and that an exclusive rule keeps "Halloween" and "Scream"
titles on SCREAM ADULTS. `channels.json` here stays unchanged until upstream
adopts something.

[Answered](https://github.com/chadMueller/Nostalgex/discussions/29#discussioncomment-18953112)
on 2026-10-15. They liked SLASHER and FOUND FOOTAGE most and will post back
once they have worked out which channels fit as a package. Horror will be
available outside October as a bundle that can be switched on or off, and so
will the Christmas bundle.

[Answered](https://github.com/chadMueller/Nostalgex/discussions/29#discussioncomment-19002764)
on 2026-10-17: built in, and in their next release.
