# Dev log

Why things changed, and what state they were left in. Newest first.
Commits carry the detail of *what*; this carries the *why*.

## 2026-10-29 (Apple TV: channel overlay stuck on after a stall, branch only)

**Shipped.** Nothing. Branch `fix/channel-overlay-stuck`, cut from `origin/main`
at `ee2f5d9`, not merged, not pushed.

**Why.** The channel info overlay could reappear during playback after a brief
stall and then stay on screen for good (Trello gENSCnj1). `PlayerView` read
`appState.player?.timeControlStatus == .playing` live inside the view body to
decide whether to show the overlay. `timeControlStatus` lives on the plain
`AVPlayer`, not on an `@Observable` property, so SwiftUI had no reliable
reason to re-render when it changed on its own. A brief stall flips it away
from `.playing`; if any unrelated render happened to land at that moment, the
overlay showed; once the stall cleared, nothing forced another render, so it
sat there until some other interaction (channel change, Play/Pause, Back)
happened to redraw the view. A tester harness reproduced the mechanism with a
real stall and a control case before this fix was written.

**Changed.**

- `Nostalgex/Nostalgex/App/AppState.swift`: new tracked property
  `isVideoPlaying: Bool`, mirroring `player.timeControlStatus == .playing`.
- `Nostalgex/Nostalgex/App/AppState+Playback.swift`: `installFreshPlayer` now
  subscribes to the fresh `AVPlayer`'s `timeControlStatus` via KVO (same
  pattern as the existing Now Playing heartbeat observer in
  `installStarvationMonitor`) and mirrors it into `isVideoPlaying`, guarded on
  `self.player === fresh` so a stale observer from a retired player can never
  win. Every load path (`loadCurrentItem`, `retryLoad`, `fallbackToTranscode`)
  already calls `cancellables.removeAll()` immediately before
  `installFreshPlayer` runs, so the previous player's subscription is gone
  before the new one is added, no leaked observer, and a channel change
  re-attaches fresh rather than relying on a stale subscription from the old
  `AVPlayer` instance. `expireSleepTimer` and `stopChannelAfterRepeatedFailures`
  now also set `isVideoPlaying = false` explicitly, since both pause the
  player without installing a new one (and the latter already cleared
  `cancellables` first, so nothing else would flip it back).
- `Nostalgex/Nostalgex/App/AppState+Auth.swift`: `disconnect()` resets
  `isVideoPlaying = false` alongside `player = nil`.
- `Nostalgex/Nostalgex/Views/PlayerView.swift`: the channel OSD visibility
  check now reads `appState.isVideoPlaying` instead of
  `appState.player?.timeControlStatus`.
- `installFreshPlayer` changed from `private` to internal visibility so tests
  can drive it directly with a real `AVPlayer`.

**Tests.** New `Nostalgex/NostalgexTests/ChannelOverlayPlaybackStateTests.swift`:
drives a real `AVPlayer` through `installFreshPlayer` and confirms (1) a
`timeControlStatus` change (`play()`/`pause()`) actually updates
`isVideoPlaying`, polling rather than asserting immediately since the KVO
sink is routed through `.receive(on: DispatchQueue.main)`; and (2) across a
simulated channel change (`cancellables.removeAll()` + a second
`installFreshPlayer` call, matching the real load paths), the retired
player's state changes no longer reach `isVideoPlaying` while the new
player's do. Full app target and `NostalgexTests` target both build clean for
the tvOS simulator SDK (`xcodebuild build` / `build-for-testing`). The test
suite itself was not run, that needs booting the tvOS Simulator, which is
on hold pending a go-ahead after an unrelated audio incident the same day.

**Half-done.** The actual `xcodebuild test` run (and a hardware check that
the overlay no longer gets stuck after a real stall) is unverified. Needs the
go-ahead to use the simulator, then `NostalgexTests` must show green before
this merges.

**Next.** Get the go to run `NostalgexTests` on the tvOS Simulator. If green,
this is ready for the normal review/merge path; no device hardware check is
strictly required since the fix is pure state-propagation (no new playback
behavior), but one on the Apple TV would be a reasonable final check given
"schedule and playback are the product."

## 2026-10-29 (Roku: on-device Plex sign-in, branch only)

**Shipped.** Nothing. Branch `roku/plex-password-signin`, cut from `main` at
`072b399`, head `0bc748d`, not merged, not pushed.

**Why.** Roku certification rule 2.2 requires on-device authentication and
prohibits an off-device-only sign-in flow. The Roku app only offered
plex.tv/link (entered on a second device), the same flow Plex's own Roku app
had to drop at version 7.6.0/7.6.1 over this same rule. Jellyfin and Emby
already sign in on-device here; only Plex was missing it. Chad's 2026-10-29
decision corrects the 2026-10-28 one (link code only): keep the link code as
the easy option, add an on-device email and password option alongside it.

**Changed.** Nothing on `main`.

**Done, on the branch.**

- `roku/source/plex/PlexApi.brs`: `NxHttp` takes an optional POST body (the
  two existing POST callers, the pin create and check, keep sending none).
  New `NxPlexSignInWithPassword(login, password)` posts to
  `https://plex.tv/users/sign_in.json` with the same X-Plex-* headers the
  link flow already sends, form-encoded `user[login]` / `user[password]`.
  `NxPlexPasswordAuthResult(code, json)` is the pure parser: "ok" with a
  token and name (read from whichever field the legacy JSON endpoint used,
  nested under `user` or flat, `authToken` or the older `authenticationToken`),
  "invalid" on 401 (a wrong password, or an account that signs in through
  Google or Apple and has no Plex password at all; the Roku can't tell
  those apart), "error" otherwise. A two-factor code goes on the end of the
  password with no separator, Plex's own documented workaround for an app
  with no separate code field; nothing in the code needs to know that.
- `roku/components/PlexSignInTask.{brs,xml}`: a `mode` field, `""` (the link
  code, unchanged) or `"password"` (new, with `email`/`password` fields).
  The tail both modes share (save the token, learn the account, clear
  another account's caches, list or confirm the servers) is now one shared
  sub, `finishSignIn`, extracted from the existing flow rather than
  duplicated. `password` is cleared on the task the instant the request is
  sent; only the token reaches `NxPlexSaveToken`.
- `roku/components/ConnectView.brs`: a USE EMAIL AND PASSWORD button next to
  CONNECT TO PLEX on the picker, leading to a new `plexCreds` screen built
  on the same field/keyboard pattern as the Jellyfin/Emby password screen
  (`addField`, `openKeyboard`, `keyboardDone`). It runs its own
  `PlexSignInTask` (mode "password") rather than going through MainScene's
  plexState/plexCode bridge, since there is no second device and no code to
  show. A standing line on the screen says a Google or Apple sign-in has no
  Plex password and to use CONNECT TO PLEX instead (it has to be standing,
  not triggered only on failure, since a 401 can't tell that case apart
  from a wrong password); the 401 error itself reads "Incorrect email or
  password."
- `roku/components/MainScene.brs`: `onConnectDone` gets a `"plexSignedIn"`
  branch (ConnectView's own task already saved the token and the servers)
  that picks up exactly where the link code's "ready" status does: the
  server picker if the account has more than one, else straight to the
  library.
- `roku/source/mediabrowser/SignInFlow.brs`: five new lines in `NxSignInCopy`
  (swept automatically by the existing em-dash/emoji/"tap" copy test) and a
  default-focus case for the new screen.
- Tests: `roku/tests/SignInFlowTests.brs` adds cases for
  `NxPlexPasswordAuthResult` (success nested under `user`, a flat response,
  the older field name, 401, a network error, a 2xx with no token, and that
  nothing but status/token/name ever leaves the parser, proven by handing it
  a crafted response with a `password` field and checking it never comes
  back) and the new screen's default focus. The request function itself,
  like its siblings `NxPlexAccount` and `NxPlexCreatePin`, is network-only
  and isn't tested off-device.
- `privacy.html` and `Nostalgex/PRIVACY_POLICY.md`: the Roku sign-in
  paragraph now says the app can send a password straight to plex.tv, the
  same way the existing Plex sign-in already does for the link code.

**Measured.** `roku/tests/run.sh`: ALL TESTS PASSED (sign-in flow: 111
passed, 0 failed). `roku/tests/pr-check.sh` against `origin/main`: see the
same session's report for the result.

**Not measured; needs Chad.** No stick check yet. That needs the dev
password (`ROKU_DEV_PASSWORD`, not in this worktree's `.env`) to install the
build, and a real Plex account's email and password typed on the remote,
either Chad's own or the demo account's; neither is something this session
should fetch or guess. Once installed: sign in with real credentials,
confirm it reaches the guide, sign out, confirm the link code still works
unchanged.

**Next.** The stick check above, then Chad's go to push.

## 2026-10-29 (publish moving from Plex to Jellyfin or Emby)

**Shipped.** Nothing until this lands on main. Vercel then deploys `https://www.nostalgex.app/blog/plex-to-jellyfin-emby-cable-guide`.

**Why.** Today's post: Nostalgex already works with Plex, Jellyfin and Emby, so pointing the app at a new server rebuilds the same channel guide from that library. The copy was already approved (`draft: false`, date 2026-10-29); this session only put the file in `content/blog` and recorded the image sizes.

**Changed.**
- `content/blog/plex-to-jellyfin-emby-cable-guide.md`: added exactly as approved. Copy was not rewritten.
- `scripts/media-sizes.json`: cover at `site/blog/plex-to-jellyfin-emby-cable-guide/cover.jpg` is 1200x630. The inline phone sign-in shot `web-tuner-signin-mobile.png` is 1290x2796. The reused TEEN MOVIES guide still from the 1.0.26 post was already listed at 1280x720. All three R2 URLs returned 200. Cover 88,670 bytes; the phone PNG 517,048 bytes; the reused still 57,528 bytes. Images stay on R2; none committed.
- `npm run blog:render` wrote twelve live posts into `public/sitemap.xml`, including `/blog/plex-to-jellyfin-emby-cable-guide` with lastmod 2026-10-29. `/blog` lastmod is 2026-10-29. `npm run build` emitted the post to `dist/blog/plex-to-jellyfin-emby-cable-guide.html` with width/height on all three images and no missing-size errors. `npm run bundles:render` ran after the blog step, so the committed sitemap has the blog block above the channels block, matching a full site build.

**Half-done.** None.

**Next.** None for this post.

## 2026-10-28 (web tuner: an empty guide says so, issue #129)

**Shipped.** Nothing until this lands on main. Branch `fix/129-empty-guide-state`, off main `52b5139`.

**Why.** After #124, a library where no package has any content still ended every loader with "tune the first enabled channel, if there is one." With none, nothing showed: a black screen and nothing to press, on the web tuner and in Docker. The Apple TV (`Plex90App.swift`) and Roku (#60) both say NO CHANNELS FOUND with an OPEN SETTINGS button.

**Changed.**
- `plex-tuner.html`: one helper, `tuneFirstOrShowEmpty()`, replaces that ending in the Jellyfin and Emby loader, `fetchLibraryFromServer`, and the cache-restore branch of `fetchPlexLibrary`. With a channel it tunes as before. With none it shows NO CHANNELS FOUND, the Apple TV line verbatim, and an OPEN SETTINGS button, inside the existing connect screen and its styles (the `.plex-btn`, VT323 text). The button is a real `<button>` that opens Settings by click or tap, so a TV browser works with no keys; Enter opens Settings too instead of starting a Plex sign-in. If Settings turns a package on and is closed, the first channel tunes and the message goes. The demo path is untouched. Exits browser full screen if the message has to show.
- `scripts/empty-guide-browser-smoke.mjs` (`npm run test:empty-guide`, needs Playwright, not in `npm test`): a library nothing matches, on the fresh-fetch path at desktop, tablet, phone and 960x540, and on the cache-restore path (checked to read the saved cache, not the server). Checks heading, line, a focusable button, and that a click opens Settings. Negative control: the old ending shows no message. Run against origin/main's page, 18 of the checks fail with no message shown.

**Measured.** 34 smoke checks pass. `npm test`, `npm run build`, `npm run build:selfhost`, the tuner isolation and tuner version checks pass. `test:empty-lineup` and `test:cache-restore-crash` still pass.

**Cross-product.** Apple TV and Roku already do this; no port. No engine change.

## 2026-10-28 (web tuner: a crash on a returning visit no longer freezes the loading screen)

**Shipped.** Nothing until this lands on main. Branch `web/cache-restore-catch`, off main `9ea9e15`.

**Why.** A support report (web tuner, Chrome on macOS 26): worked on first connect, then every return visit "finds the server, loads the library, and then build the channels and gets stuck at 139 of 139." Reproduces on reconnect, refresh, reboot. Reading `fetchPlexLibrary()` found the cause of the freeze itself, though not yet what actually throws: the function has two branches, a fresh server fetch wrapped in `try/catch` that shows an error screen, and a cache-restore branch (used on a returning visit, within the 24 hour cache TTL) with no try/catch of its own. An exception anywhere in that branch (filtering, schedule building, autogenerated channels, render) left `LL.hide()` never called, the loading screen frozen forever, and nothing in the console. Because the saved cache persists, the same crash reproduces identically every time. "139 of 139" is the last channel's name written to the step-rail text before the per-channel loop ends; the freeze does not have to come from that channel's own rules, since nothing after the loop (bundle filtering, the schedule-build pass, autogenerated channels, render) updates that text either.

**Not changed.** The actual trigger. A harness (real `plex-tuner.html`, headless, a Jellyfin-shaped library built to populate all 139 channels including the one from the report, every bundle switched on as the reporter described) completed cleanly in both a first-connect and a cache-restore pass, at normal and 8x library size. Whatever throws depends on a shape only the reporter's real server data produces, not reproduced here.

**Changed.**
- `plex-tuner.html` (`fetchPlexLibrary`): the cache-restore branch now runs inside the same `try` as the fresh-fetch branch, so the same `catch` and the same error screen cover both. The wording was written for a fetch failure; it is generic enough to reuse for a build crash too, and a safety net beats a silent freeze while the real cause is unconfirmed.
- The console log now names which branch failed (`Library fetch error (cache-restore): ...` vs `(fetch): ...`), so the next occurrence says more than "it froze."
- `scripts/cache-restore-crash-browser-smoke.mjs` (`npm run test:cache-restore-crash`, needs Playwright, not in `npm test`): the real page against a Jellyfin-shaped server, connects once to save a cache, then reloads with a flag that makes a post-load step throw only on that second load, the one that takes the cache-restore branch. Checks the error screen shows, with text, the connect screen returns, and the loading screen is hidden rather than left up. Negative control: the same crash served against the branch's pre-fix shape (the cache-restore work outside any try/catch) times out with the loading screen still up and no error shown, proving the test exercises the actual fix.

**Measured.** The regression smoke: 11 checks passed, including the negative control against the reverted (pre-fix) code, which times out as expected instead of passing. `npm test`, both builds, tuner isolation and tuner version all pass unchanged.

**Half-done.** The real trigger is still unknown. Trello card (P1, Bug, Ready): https://trello.com/c/nAsb4O8f.

**Next.** Watch for the console line naming the branch and the error the next time this is reported; that is the fastest path to the actual cause.

## 2026-10-27 (Roku: the loading note after the TV clears the saved library no longer gives a time)

**Shipped.** Nothing until this lands on main. Branch `roku/restart-loading-note`, off main `9ea9e15`. Chad's go (option 1 of the power-loss rescan).

**Why.** Two beta users on Discord report a full rescan every time the stick loses power. Cause: the saved library, guide, pools and enrichment cache live in `cachefs:`, which Roku keeps in RAM and empties on a reboot (Roku's file-system docs; no SD card on a Streaming Stick Plus). The registry survives a reboot but holds 32 KB, so a library can't go there. The sign-in, server kind and server list are in the registry, so a Jellyfin or Emby user comes back to the same server, not Plex. The loading screen already says what happened, but ended "This can take a few minutes", which is wrong for most libraries (Chad's 1,545 films read in 6 to 13 s).

**Changed.**
- `source/util/LoadingNote.brs`: `NxLoadingNote(firstRun, savedBefore)` returns the line under the logo. First-ever setup keeps "First setup can take a few minutes to scan and build channels." A library saved before and now gone (`savedBefore`, from the registry's `librarySaved`) says "The TV cleared the saved library, so it's being read again." with no time. A library still saved shows nothing.
- `components/LoadingView.brs` and `.xml`: use it (the headline still names Plex, Jellyfin or Emby, `NxScanHeadline`).
- `tests/MediaBrowserTests.brs`: the four states, no "minute" in the cleared note, a length that fits the line, and that `LoadingView` calls the function and holds no copy of the old text.

**Not changed.** The scan, the schedule and playback. No speed work.

**Half-done.** A cold-boot measurement on the stick (time to guide, the screen shown) waits for a restart of the stick.

## 2026-10-27 (tuner 1.0.9)

**Shipped.** `tuner-v1.0.9`, the Docker image and the hosted tuner. Merged since `tuner-v1.0.8`: an empty first lineup falls back to every package with content (#124), a Plex title with a bad byte keeps its accent (#125), STREAM QUALITY (#123).

**Changed.** `tunerVersion` 1.0.8 to 1.0.9 and the README's latest-release lines. The first load after the update reads each library once more, because the library cache is now version 3.

**Next.** The GitHub release note for `tuner-v1.0.9`.

## 2026-10-27 (web tuner: STREAM QUALITY)

**Shipped.** Nothing until the PR for #123 lands on main. Branch `web/stream-quality-123`, off main `ab60b31`.

**Why.** The Apple TV has Settings > PLAYBACK > STREAM QUALITY: Auto, Maximum, High (1080p, 12 Mbps), Medium (720p, 4 Mbps), Low (480p, 1.5 Mbps), on every channel. The web tuner and Docker had nothing, so a slow link or a remote server could not ask for less (issue #123).

**Compared first.** What the web sent before this change: Jellyfin and Emby `MaxStreamingBitrate` 120,000,000 in PlaybackInfo (profile and body) and `MaxWidth=3840` with no `VideoBitrate` on the fallback URL; Plex none of the four quality parameters. The Apple TV's Auto sends 40 Mbps and 4K on all three, and Maximum the same, so Auto and Maximum differ from the web's today. Playback is the product, so on the web Auto and Maximum leave every request exactly as it was; only High, Medium and Low change anything. Whether the web's Auto should move to the Apple TV's numbers is a separate decision.

**Changed.**
- `scripts/nostalgex-stream-quality.js`: the five levels, the saved choice (`nostalgex_stream_quality`, the Apple TV's key) and what a capped level asks of each backend. Plex: `maxVideoBitrate`, `videoQuality`, `videoResolution`, `autoAdjustQuality=0` on the transcode URL. Jellyfin and Emby: `MaxStreamingBitrate` in the PlaybackInfo profile and body, `VideoBitrate` and `MaxWidth` on the fallback URL (`fallbackHlsUrl` takes them as options and is byte for byte the same without). Read at the start of each program, so a change applies from the next one.
- Direct play: a file whose bitrate is above a capped level's ceiling is transcoded instead, on any connection (the Apple TV does it for remote Plex servers only; a browser cannot tell). Items now carry `bitrate` in kbps, from Plex `Media.bitrate` and Jellyfin/Emby `MediaSource.Bitrate`. The library cache version goes from 2 to 3, so a cache written by the previous page (no bitrate) is refused once and the library is read again, as the earlier tmdbID bump did; without that, a 20 Mbps MP4 would direct play at LOW for up to a day.
- `plex-tuner.html`: a QUALITY button on the rail (sharing a row with SETTINGS, so the rail keeps its height), STREAM QUALITY in the phone drawer, a picker, and a row of five chips in Settings > General > PLAYBACK, all from one renderer. Playback Information shows the level at High, Medium and Low.
- `scripts/stream-quality-golden.json`, held by `scripts/nostalgex-stream-quality-smoke.mjs` (`npm run test:stream-quality`, in `npm test`) and by the new `StreamQualityGoldenTests.swift`. Roku #65 reads the same file.
- `scripts/stream-quality-browser-smoke.mjs` (`npm run test:stream-quality:browser`, needs Playwright): the real page against a Jellyfin-shaped and a Plex-shaped server that record what a program start asks for, at every level, for a transcoded file and for direct-playable ones, plus the controls and a negative control.

**Measured.** Against a Jellyfin 10.10.7 test server, PlaybackInfo for a 28 Mbps MKV: Auto asks for 120 Mbps and gets a transcode at `VideoBitrate=119360000`; Low sends `MaxStreamingBitrate=1500000` and gets `VideoBitrate=1116000` with `AudioBitrate=384000` and `TranscodeReasons=ContainerBitrateExceedsLimit`. Headless Chromium at 390x844, 820x1180, 1440x900 and 960x540: the picker, the drawer row and the Settings chips fit with no horizontal scroll, and the rail's last button sits where it did before. The Swift table test passes on the tvOS 26.1 simulator.

**Half-done.** Not run against a real Plex or Emby server: the Plex parameters are the four the Apple TV sends, checked as URLs only. The resolution cap on Jellyfin and Emby is the fallback URL's `MaxWidth` and the server's own scaling for the bitrate; the test files were 360p, so a downscale was not seen. No iCloud-style sync of the choice, as the web has none for any setting.

**Next.** Roku #65 follows with the same golden file. Decide whether the web's Auto should match the Apple TV's. Nothing changes what is sent anywhere beyond request parameters to the viewer's own server.
## 2026-10-27 (Roku: `tests/pr-check.sh`, the mechanical review checks in one command)

**Shipped.** Nothing until this lands on main. Branch `roku/pr-check`, off main `8f994d8`. Test tooling only under `roku/tests/` and one CI step; none of it is in the channel package (`stage.sh` packs only manifest, source, components, images, data and fonts, and the script proves that on every run).

**Why.** A reviewer and a tester were redoing the same mechanical checks by hand on every branch and release candidate: the suite, the include check, the saved-data guard, the test lists after a merge, the commit scan. Each costs tokens and attention, and a hand merge went wrong in exactly the places those checks cover (a test file dropped from a list, a line kept twice, an uninitialized variable that stopped the app on a TV). Now one command prints one line per check, and the reviewer reads the lines.

**What each check proves, and what it can't.**
- `testlists`: every `tests/*Tests.brs` is listed once in `deploy.sh` and once in `run.sh`, every suite function is reachable from `main.brs`, none is called or listed twice. Proves a merge didn't drop or repeat a suite. Doesn't prove the suite passes.
- `includes`, `uninit`, `guards`: the existing include check, `check-uninit.py`, and the grep guards (secret in a print, saved data outside `NxRegSection`, a variable named `m` or `run`), now in `tests/tools/check-guards.sh` so `run.sh` and `pr-check.sh` share one copy. The tools run from the checkout you are in against the tree of REF, so an old head is held to a check that came later (4f0a467 and `check-uninit.py`).
- `dupkeys` (new): an associative-array literal that names a key twice. A hand merge that keeps both sides of a changed line makes this, and nothing else sees it.
- `package`: the staged channel contains nothing from `tests/`. Proves release tooling can't ship.
- `trailers`, `secrets`, `addresses`, `dashes`: what the change adds, from the commits in BASE..REF that aren't already on origin/main and the lines REF would add to BASE (the diff to a `git merge-tree` merge, so lines main already has aren't counted again). A `range` row warns when there is nothing to scan. AI trailers (commits by tydude001 are counted and left as they are), tokens and keys and `.env` files, real server addresses (a deny list; other IPv4 addresses are a warning to read), em and en dashes. A warning isn't a failure; it is a line for a person to read.
- `heads` and `held`: with `--prs` or `--heads`, every PR head is an ancestor of REF; with `--held`, a head that was to stay out isn't in it. Proves a candidate holds the reviewed heads, not newer or older ones.
- `sca`: Roku's static analysis when Java 21 is here (or podman, as `scripts/sca.sh` needs); otherwise it says NOT RUN.
- `suite`: `tests/run.sh`, the slow one (started first, runs while the others are checked).
- `--since SHA`: lists what changed since the last head that passed and says whether any app file moved, so a device pass is only asked for what changed.

**Stays manual.** Anything on a TV (the on-device suite, Settings scrolled to CHANNEL PACKAGES, a smoke test, playback), whether a change is right, the privacy wording, and whether a conflict hand-resolution kept the intended side (the checks only catch the mistakes that have a signature).

**Changed.**
- `roku/tests/pr-check.sh`: the command. `roku/tests/tools/check-testlists.py`, `check-dupkeys.py`, `scan-added.py`, `check-guards.sh`: its parts. `check-includes.py` and `check-uninit.py` take an optional roku/ directory.
- `roku/tests/run.sh`: its inline grep guards moved to `check-guards.sh`, unchanged; it now also runs `check-testlists.py` and `check-dupkeys.py`.
- `.github/workflows/ci.yml`: on a pull request the `roku` job runs `pr-check.sh` (which includes the suite) and writes the report to the job summary; on a push it still runs `run.sh`.
- `roku/tests/README.md`: how to run it and read it.

**Tested.** On `f4d9f9e` (the 1.0.6 candidate, against its main `9ff822b`, with all ten PR heads and #105 held): every check passes. On `4f0a467`, the head before the Settings fix: `uninit` fails on `drawRow()` reading `isOn`. On a branch with a dropped list entry, a repeated key, an AI trailer, a token-shaped string, a real address, a dash and a test file in the package: each check fails on its own line.

**Half-done.** None.

**Next.** Reviewer v2 reads the branch before it is pushed.

## 2026-10-27 (Roku: a Jellyfin or Emby item's bitrate is in kbps, as the web tuner and the Apple TV hold it)

**Shipped.** Nothing until this lands on main. Branch `roku/bitrate-kbps`, off main `ab60b31`.

**Why.** The web tuner's STREAM QUALITY branch (PR #123) gives Jellyfin and Emby items a `bitrate` in kbps, `Math.round(Bitrate / 1000)`, as the Apple TV holds it. The Roku held the server's raw bits per second in the same field (19,269,041 where the web says 19269). `roku/tests/run.sh` compares each Roku item with the JS engine's, so with #123 merged the `mediabrowser` suite fails all 222 `bitrate` cases and nothing else (checked on a merged tree of main and #123). This lands the Roku side with no change in behaviour.

**Changed.**
- `source/mediabrowser/MediaBrowserLibrary.brs`: `NxMbBitrateKbps` (Integer sums, half up, 0 when there is none, as the JS); `NxMbMediaInfo` uses it. The best-source pick still reads the server's raw `Bitrate`, as the web's does.
- `source/mediabrowser/MediaBrowserPlayback.brs`: `NxMbVideoQuery` compares with 20,000 kbps instead of 20,000,000 bps. That is the only user of an item's bitrate besides the pass-through in `GuideSchedule.brs`. Plex items already held kbps and nothing reads them for this. One rounding edge: a file within half a kbps of 20 Mb/s can now land on the other side of the re-encode line.
- `source/plex/LibrarySnapshot.brs`: saved library format 7 to 8, since a saved item would no longer read the same (an old save in bits per second would re-encode every file). A library saved by 1.0.6 is read again once, as after the earlier bumps.
- Tests: the expected bitrates and `NxMbVideoQuery` arguments in kbps; ten cases for `NxMbBitrateKbps` (rounding at 499 and 500, a Float, over 2 Gb/s, none, negative).

**Tested.** `tests/run.sh`: ALL TESTS PASSED on this branch off main, and on a merged tree of main and web/stream-quality-123 (`326fd6a`), where it failed before this change. So it lands in either order.

**Half-done.** None. STREAM QUALITY on the Roku (#65) is separate and stays with tydude001; it will read `scripts/stream-quality-golden.json` once #123 is in.

## 2026-10-27 (web tuner: a Plex title with a bad byte keeps its accent)

**Shipped.** Nothing until the PR for #125 lands on main. Branch `web/bad-byte-125`, off main `ab60b31`.

**Why.** Plex copies a file or folder name into its JSON byte for byte, so an unmatched item named in Latin-1 puts a lone 0xE9 into its title. The Apple TV repairs that since 1.0.27 (`PlexUTF8Repair`). The web tuner's scan reads pages with `Response.json()`, which decodes UTF-8 with replacement characters instead of failing, so the library loaded but the title read "Caf\uFFFD Society" (issue #125).

**Reproduced first.** The unchanged page, headless in Chromium, against a Plex-shaped server whose library page held raw bad bytes: the titles the tuner kept read "Caf\uFFFD Society", "Say \uFFFDHello\uFFFD", "Br\uFFFDl\uFFFDe" and "Cut Off \uFFFD", the summary kept one too, and the guide text had a replacement character in it. A title that was valid UTF-8 ("Am\u00e9lie") came through fine.

**Changed.**
- `scripts/nostalgex-utf8-repair.js`: the Apple TV's rule. A valid response is decoded untouched; otherwise every byte outside a well-formed UTF-8 sequence is read as Windows-1252 and every well-formed sequence is kept. A stray byte is always 0x80 or above, so the repair cannot add a quote, backslash or control character to the JSON. One console line says how many bytes were repaired. A byte order mark is valid UTF-8 and is never repaired: one at the very start of the text is dropped (as `Response.json()` does), one anywhere else is kept, including right after a repaired byte, as the Apple TV keeps it.
- `plex-tuner.html`: the four reads of a Plex server (section pages, `allLeaves`, and the two library helpers that also carry server collections) go through `NostalgexUTF8Repair.json`.
- `scripts/utf8-repair-golden.json`: 27 shared vectors, 8 of them about byte order marks (a reviewer's fuzzing found the first version dropped a mark that followed a repaired byte, in 6,776 of 60,019 inputs), made with an independent Python model, held by `scripts/nostalgex-utf8-repair-smoke.mjs` (`npm run test:utf8-repair`, in `npm test`) and by the new `Nostalgex/NostalgexTests/PlexUTF8RepairGoldenTests.swift`. Roku reads the same file for #121.
- `scripts/plex-bad-byte-browser-smoke.mjs` (`npm run test:plex-bad-byte`, needs Playwright): the real page against the same Plex-shaped server, plus a negative control with the repair taken out.

**Measured after.** The same page now keeps "Caf\u00e9 Society", curly quotes for 0x93 and 0x94, "Cr\u00e8me Br\u00e9l\u00e9e" and "Cut Off \u00e2", with no replacement character in a title or on the page. The Swift golden test passes on the tvOS 26.1 simulator along with the 11 existing `PlexUTF8RepairTests`.

**Half-done.** Jellyfin and Emby are not touched: both send valid UTF-8. plex.tv's server list and the Continue Watching read still use `res.json()`: plex.tv sends valid UTF-8, and a replacement character there cannot stop a cleanup, which only reads ids. Not run against a real Plex server; the server in the test is a stand-in that returns the bytes Plex was measured to return (see the 2026-10-16 entry). The repair guesses Windows-1252 for any stray byte, so a name in another single-byte encoding loads with the wrong accented letter, the same as on the Apple TV.

**Next.** Roku #121 follows with the same golden file. Nothing changes what is sent anywhere.
## 2026-10-27 (web tuner: a small library no longer opens on a blank screen)

**Shipped.** Nothing until the PR for #124 lands on main. Branch `web/empty-lineup-124`, off main `ab60b31`.

**Why.** A first run starts with the NOSTALGEX package only. A library too small or too narrow to fill any NOSTALGEX channel left the web tuner on a black screen with nothing to press (issue #124). The Apple TV switches on every package that has content when the first lineup comes out empty (`autoEnableBundlesWithContent`), and Roku 1.0.6 does the same (#109). The web had no such step.

**Measured first.** The unchanged page, headless, against a lab Jellyfin as three users: a 20-film documentary library and a 2-film one both landed on 0 channels with only NOSTALGEX on, and a black screen; a 34-item library that fills one NOSTALGEX channel opened on its guide. So the answer to "empty guide or fallback" was an empty guide.

**Changed.**
- `scripts/nostalgex-library-load.js`: `bundlesToAutoEnable`, the Apple TV's rule as a pure function. Every package that is off, not seasonal, not a server-collection package and has at least one channel with enough content, in the bundles' order.
- `plex-tuner.html`: `autoEnableBundlesWithContent`, run at the end of a first (full) lineup build when no channel came out. It switches those packages on, saves the choice and builds their schedules. A later load never runs it, because only a full build knows which packages have content.
- `scripts/empty-lineup-browser-smoke.mjs` (`npm run test:empty-lineup`, needs Playwright): the real page against a Jellyfin-shaped server with a 20-film, a 2-film, a 6-film (fills VHS VAULT on its own, nothing else switched on) and a no-match library, plus a negative control with the call removed.
- `scripts/nostalgex-library-load-smoke.mjs`: four cases for the rule itself.

**Measured after.** The 20-film library switches on ESSENTIALS and opens on 2 channels; the 2-film library opens on 1 (PREMIERES); the 34-item library is unchanged. Same numbers the Roku tester saw on the stick for the same lab users.

**Half-done.** A library where no package has content still ends on the blank screen. The Apple TV and Roku show NO CHANNELS FOUND with an OPEN SETTINGS button there; the web does not yet. Nothing changes what is sent anywhere.

**Next.** Decide whether the web gets that NO CHANNELS FOUND screen.

## 2026-10-27 (publish how to make Plex feel like cable TV)

**Shipped.** Nothing until this lands on main. Vercel then deploys `https://www.nostalgex.app/blog/make-plex-feel-like-cable-tv`.

**Why.** Scheduled publish for the Plex cable-TV walkthrough. Yesterday's virtual-channels post had its link to this page cut so a 404 would not ship; that sentence comes back today, plus the planned link-backs on the live Jellyfin and sit-back posts.

**Changed.**
- `content/blog/make-plex-feel-like-cable-tv.md`: `draft: false`, `date` 2026-10-27. Copy check: no em or en dashes, no "no ads" / "no upsell" / "no paid tier" / "no in app purchases". Channel count already said 130+. One fix: the web tuner Emby line now says choose Connect with Emby, because that button exists and the old "use the Jellyfin connect option" line was stale. No Apple TV version or release-date promises. Internal `/blog/` links stay on two already-live posts (`best-90s-buddy-cop-movies-channel`, `90s-slasher-movies-halloween-marathon`). None of the still-draft slugs were in the file.
- `content/blog/plex-virtual-channels-own-movies.md`: restored the paragraph cut on Oct 26, original wording from PR #102: "I'm not going to repeat the full Plex setup here, because I already wrote it up in [how to make Plex feel like cable TV](/blog/make-plex-feel-like-cable-tv)." Date on that post stays 2026-10-26.
- `content/blog/jellyfin-tv-guide-own-library.md`: after the existing Apple TV channel-surfing link in "Do I have to set up M3U, XMLTV or a tuner for this?", added the planned line pointing at the Plex walkthrough. Date stays 2026-10-19.
- `content/blog/plex-apple-tv-app-sit-back-alternative.md`: one sentence in "Do I have to give up Plex to use it?" pointing at `/blog/make-plex-feel-like-cable-tv`. Date stays 2026-10-22.
- Images stay on R2; none committed. Cover and the Scream banner were already in `scripts/media-sizes.json`. Cover returned 200 (1200x630, 98,909 bytes). The Scream banner returned 200 (1280x720, 63,882 bytes).
- `npm run blog:render` wrote eleven live posts into `public/sitemap.xml`, including `/blog/make-plex-feel-like-cable-tv` with lastmod 2026-10-27. `/blog` lastmod is 2026-10-27. There are no remaining drafts in `content/blog`. `npm run bundles:render` then ran after the blog step, so the committed sitemap has the blog block above the channels block, matching main.

**Half-done.** None. This was the last scheduled draft in `content/blog`.

**Next.** The Tunarr post still has a build-notes reminder to add this walkthrough in "How does Nostalgex compare to Tunarr and ErsatzTV?". That was not in today's publish list.

## 2026-10-26 (Roku: a small library no longer lands on an empty guide)

**Shipped.** Nothing until the PR for #60 lands on main. Branch `roku/small-library`, off main `ae3cd6d`.

**Why.** A first run starts with NOSTALGEX only. A library too small or too narrow to fill any NOSTALGEX channel landed on a guide that read NO CHANNELS AVAILABLE, with nothing to press (issue #60). The Apple TV switches on every package that has content when the channels come out empty (`autoEnableBundlesWithContent`), and if that still finds nothing it says NO CHANNELS FOUND with an OPEN SETTINGS button.

**Changed.**
- `components/LibraryTask.brs`: after a build with no channel, the packages that aren't on, aren't seasonal and aren't collection ones are tried together. The ones that built a channel with content stay on and are saved, as upstream saves its preferences. One more build if any of them came out empty.
- `source/guide/BundleChoices.brs`: `NxAutoEnableCandidates`, `NxBundlesWithContent`, `NxSaveEnabledBundles`.
- `components/GuideView.brs`: the empty guide reads upstream's NO CHANNELS FOUND text, and OK opens Settings.
- `tests/SmallLibraryTests.brs`: 8 cases, among them a 20-film true-crime documentary library that fills no NOSTALGEX channel and gets ESSENTIALS switched on. Registered in `tests/main.brs`, `tests/run.sh`, `scripts/deploy.sh`.

**Measured.** Before the change the new suite fails (the functions don't exist). After it, the whole suite passes off-device, one process at a time, and on a Streaming Stick Plus (`small library cases: 8 passed, 0 failed`). The stick's own library (Emby) launches and plays as before; its guide was never empty, so the fallback doesn't run there.

**Half-done.** The fallback hasn't run on a TV with a small library: the stick stays signed in to Chad's Emby. tydude or a tester with a small library can check it.

## 2026-10-26 (Roku: accented names compare and upper-case as on the Apple TV)

**Shipped.** Nothing until the PR for #70 and #71 lands on main. Branch `roku/my-collections`.

**Why.** The reviewer's nit on the fixed blocks: Swift compares Strings by canonical equivalence and orders them by NFC, and `uppercased()` maps é to É. BrightScript compares raw code points, and a TV's `UCase`, like its `LCase`, isn't Unicode's beyond ASCII. Off the TV, a precomposed CAFÉ and CAFE with a combining accent sorted apart (`c,b,d,a` where Swift gives `c,d,a,b`), so a full franchise block could keep or number them differently from the Apple TV.

**Changed.**
- `source/franchise/FranchiseUnicode.brs` (new, generated by `tests/tools/gen-unicode.py` from Unicode 16): 635 upper-case mappings and 572 canonical compositions, for the scripts `NxFranchiseLower` covers. The generator stops unless its Python has Unicode 16.0.0, so another version can't quietly write different tables.
- `source/franchise/FranchiseBuilder.brs`: `NxFranchiseUpper` (ASCII through `UCase`, the rest through the table; ß to SS) and `NxFranchiseCompose` (a base letter and a following mark become the precomposed letter). Auto-found franchise names use `NxFranchiseUpper`.
- `source/collections/Collections.brs`: collection titles upper-cased with `NxFranchiseUpper`.
- `source/guide/Franchises.brs`: `NxBlockKept` compares names composed (`NxBlockNameKey`), ids as before.
- `tests/CollectionTests.brs`: the two forms of CAFÉ, upper-casing (amélie, straße, дом, ά), and a lowercase accented collection title through the step. Expected values from running the same comparisons in Swift.

**Measured.** Off-device: the ordering case fails before (`c,b,d,a`) and passes after; the suite passes, one process.

**Not measured.** Not on a TV. The off-device interpreter's `UCase` is JS's, so only the TV shows whether the old code mis-cased there; the on-device suite now checks `NxFranchiseUpper` and the composed ordering. The tables are parsed once per thread when a name has non-ASCII text; that cost is unmeasured on a TV. Marks out of canonical order aren't reordered, as full NFC would.

## 2026-10-26 (Roku: fixed channel blocks for franchises and collections, after the Apple TV)

**Shipped.** Nothing until the PR for #70 and #71 lands on main. Branch `roku/my-collections`. The Apple TV side is `fix/franchise-numbering` (`8ab0bc6`).

**Why.** Franchise collections numbered straight after the found franchises, on one id base, so switching the FRANCHISES package or a found franchise moved them. On the Apple TV they followed the found franchises even with the package off; matching that on the Roku meant finding franchises on every package-off load, measured at an estimated 1.8 s (5.4k items) to 20 s (60k) on a TV, so it was parked. Chad chose fixed blocks on every platform instead. On his Emby (1,544 films) the port finds 64 franchises with a switch (70 with no classic built), and one other library reached 86, so found franchises get 150 numbers and franchise collections 50.

**Changed.**
- `source/guide/Franchises.brs`: found franchises CH 300-449 (150), ids from 1,000,000 as before. `NxBlockKept` ports `DynamicChannelBlock.keptInDisplayOrder`: a full block keeps the most films, ties by name then id, and numbers the kept ones by name then id, with Swift's case-sensitive `<`. `NxFranchiseStep` returns how many didn't fit.
- `source/collections/Collections.brs`: franchise collections CH 450-499, ids from 1,010,000, by the same rule; other collections CH 500-699 as before. Nothing depends on the found franchises any more.
- `components/SettingsView.brs`: upstream's lines when a block is full, under the franchise list and under each MY COLLECTIONS accordion. The block sizes come with the build. The old "N SWITCHED ON PAST CH 499" note is gone.
- `tests/CollectionTests.brs`, `tests/FranchiseGuideTests.brs`: the new `FranchiseNumberingTests.swift` cases (the 449 and 499 limits, the overflow order, ids per block), and a step case where the package and the found franchises switch while two collections keep CH 450 and 500 and their ids.
- `docs/PORTING.md`, `README.md`: the blocks; the old package-off difference is gone.

**Measured.** Off-device, one process. Before the change the new cases fail (old code: the collections suite errors on `NxFranchiseBlock`, and 2 franchise guide checks fail; old ranges with the new code: 15 collection and 2 franchise guide checks fail). After it, all pass.

**Not measured.** Not on a TV yet. The tester re-runs the BoxSet checks: OAK at CH 450, MY SHOWS at CH 500. The on-device suite also checks that BrightScript's string `<` orders as Swift's does (a case in `tests/CollectionTests.brs`).

## 2026-10-26 (Roku: MY COLLECTIONS on Jellyfin and Emby, split into FRANCHISES and OTHER COLLECTIONS)

**Shipped.** Nothing until the PR for #70 and #71 lands on main. Branch `roku/my-collections`, on top of `roku/advance-ended-slot` (the hand-over fix) and `roku/test-isolated-data` (a test build keeps its own saved data, for the BoxSet checks).

**Why.** On Jellyfin and Emby, MY COLLECTIONS was always empty: the Roku read Plex collections only (issue #70). And every collection sat under OTHER COLLECTIONS from CH 500, where the Apple TV sorts movie series into FRANCHISES from CH 300 (issue #71). One branch, since both change `Collections.brs` and its tests.

**Changed.**
- `source/collections/Collections.brs`: `NxCollectionsFetchBoxSets`, a port of the web's `fetchBoxSetCollections` (BoxSets deduped by Id, each one's films and series paged). `NxCollectionsMaterialize` numbers per category as `materializeDynamicChannels`: FRANCHISES in CH 450-499, the rest in CH 500-699 (fixed blocks, the entry above). The collections step classifies each collection and its rows carry the category and whether they warn.
- `source/collections/CollectionClassifier.brs` (new): a port of the Apple TV's `CollectionClassifier`.
- `source/collections/CollectionChoices.brs`: the two category names and descriptions.
- `components/LibraryTask.brs`: Jellyfin and Emby servers read their BoxSets. `MediaBrowserLibrary.brs` is untouched, so tydude's #63 rebases cleanly.
- `components/SettingsView.brs`: MY COLLECTIONS has a FRANCHISES and an OTHER COLLECTIONS accordion, as upstream. A row that is off and already mostly on another channel is dimmed to 0.7, as upstream. The note under MY COLLECTIONS counts rows past CH 499 and past CH 699 separately.
- `tests/gen-collections.mjs`: 7 BoxSet fixtures run through upstream's `fetchBoxSetCollections`. `tests/CollectionTests.brs`: those vectors, the cases of `CollectionClassifierTests.swift`, the classifier cases of `CollectionShowsTests.swift`, the numbering cases of `FranchiseNumberingTests.swift`, and a step case. With the package off, the step case "package off: three channels" numbers 450, 451, 500.
- `docs/PORTING.md`, `docs/JELLYFIN-EMBY.md`.

**Measured.**
- Before the change, the new tests crash on main's code (`NxCollectionsFetchBoxSets` doesn't exist). After it, the whole suite passes off-device, one process at a time, and on a Streaming Stick Plus (`collection cases: 2647 passed, 0 failed`).
- Lab servers, Jellyfin 10.10.7 and Emby 4.10.1, each with a BoxSet of two shows and a film, and on Jellyfin a five-film BoxSet. Upstream's fetch was recorded against them, and the port read the recorded answers with the same requests and the same result. Jellyfin lists the two series ids; Emby lists the six episodes.
- On the stick, signed in to Chad's Emby, the load reads its BoxSet list in 93 ms. It has no BoxSets, so it lists none, and the guide builds as before.

**Differences from upstream.**
- The web tuner has no classifier. Its vectors still cover the OTHER COLLECTIONS numbering only.

**Half-done.** No collection channel has been seen on a TV from a Jellyfin or Emby server with BoxSets: Chad's Emby has none, and the stick stays signed in to it.

## 2026-10-26 (Roku: a hand-over that skips a title could re-tune the same file every few seconds)

**Shipped.** Nothing until it lands on main. Branch `roku/advance-ended-slot`, on top of `roku/test-isolated-data` (`cd8f783`). The loop is in Roku 1.0.5.

**Why.** At a hand-over (`NxAdvancePick`, the Apple TV's `advanceToNextItem`), a title another channel has on now is skipped: the pick is the entry after that title's first airing in the guide's window. When that first airing is earlier than now, the entry after it can be over already. Upstream just plays the item from its start. The Roku's player also ends an airing by its slot (`NxAiringEnded`, with its five-minute overrun cap), and that slot was over, so the next tick handed over again, to the same pick, for as long as the conflict lasted. On the stick, a lab Jellyfin channel re-tuned one film 34 times in about 5 minutes with no picture ("next is <id>, from its start", tune, stop, every ~9 s). A collection channel on a 12-item lab library showed it first, but any channel can meet it: it takes a title airing twice in the window, the first already over, while another channel has it on now. That is likely with music videos, short episodes and small pools, and rare with films.

**Changed.** `roku/source/guide/Advance.brs`: a pick whose slot is already over airs as from now, for its slot's length, as a copy, so the schedule keeps its own. The pick and its seek are unchanged. `roku/tests/AdvanceTests.brs`: the log's case cut down. Before the fix, 3 checks fail and a minute of ticks hands over 61 times; after, once. `roku/docs/PORTING.md`: the hand-over note.

**Not measured.** Not seen on a TV after the fix; the tester re-runs it.

## 2026-10-26 (Roku: a stream that fails no longer counts as the film's end)

**Shipped.** Nothing until it lands on main. Branch `roku/failed-start-not-finished`, off #108 (`cd8f783`).

**Why.** On 1.0.5, CH 12 joined 54 minutes into *Soldier* (Emby) failed within a second and jumped straight to the next film from its beginning. There was no retry, no card and nothing in Settings (tester's console: `error -3 … source buffer:reader`, `error on the server stream; retrying it`, `finished`, `finished, -2628 s past the slot`, `next is 2856, from its start`). The ladder clears the running attempt while its retry waits, and Roku's player then reports `finished`. `onVideoState` only checked a never-played end while an attempt was running, so this one fell through to the hand-over as if the file had ended.

**Changed.**
- `source/guide/Fallback.brs`: `NxFinishedAction` decides what `finished` means. If the start already failed (retry pending or card up), the answer is "ignore". Otherwise it is the same as before: hand over, ask the server, or a second unplayed end is an error.
- `components/GuideView.brs`: `onVideoState` acts on it.
- `source/plex/LibrarySnapshot.brs`: `NxClearPlaybackVerdicts`. A sign-out clears the stored playback failures, and so does a sign-in by another account or server: Settings kept Jellyfin's "Last playback failure" after signing in to Emby. The Apple TV keeps them too; that side is on Chad's board.
- Tests:
  - `tests/FallbackTests.brs`: 8 cases. Without the new rule, the three "after the start failed" cases fail.
  - `tests/SnapshotTests.brs`: the failures cleared on sign-out and on another account's sign-in. These run on a TV, since the off-TV interpreter has no registry. The owner tests now run in a data space of their own, so a TV's run can't clear the app's.

**Measured.** Off-device only; the tester owns the stick.

**Then: the step down (second commit).** The tester found Soldier fails from 0 s too (an `item:` link: the same `error -3 … buffer:reader`), so a retry of the same stream can't help. Its server stream copies H.264 High level 5.1 with keyframes 4 to 10 s apart; at the 54-minute join the piece the playlist calls 2 s is 18 MB and 10 s long.
- `source/guide/Fallback.brs`: on Jellyfin and Emby, an error on the server stream steps down to the 1080p rung instead of retrying the same request. Plex keeps upstream's retry.
- `source/mediabrowser/MediaBrowserPlayback.brs`: that rung asks for `AllowVideoStreamCopy=false`, so it always re-encodes. Upstream's `cappedTranscodeURL` doesn't, and a file at or under 8 Mb/s would come back copied.
- Measured off the TV, one probe on the home Emby, stopped after (204):
  - Soldier's 1080p stream, from 0 s and at the join, comes in even 2 s pieces of 1.1 to 2.9 MB, H.264 Main level 4.0.
  - The copied stream's piece at the join is 18 MB.
- `tests/FallbackTests.brs`: 12 more cases. The Jellyfin/Emby ones fail on the first commit.

## 2026-10-27 (Roku: Settings' package rows stopped the app, and a check for it)

**Shipped.** Nothing until the PR for #72 (#114) takes it. Branch `roku/playback-report`.

**Why.** The tester found the 1.0.6 release candidate crashing as soon as Settings scrolled to CHANNEL PACKAGES: `Use of uninitialized variable (runtime error &he9)` in `SettingsView.drawRow`. My own bug in #114: renaming `on` to `isOn` for the two reporting rows also changed the package rows' `if on then`, and that branch never sets `isOn`. The tester had run Settings on this branch without scrolling that far. Neither the suite nor static analysis can see a variable read before it is assigned.

**Changed.**
- `components/SettingsView.brs`: the package rows read `on` again.
- `tests/tools/check-uninit.py` (new), run by `tests/run.sh`: flags a plain name an `if`, `else if` or `while` condition reads when this path has not assigned it, following if / else-if branches (a branch sees what came before the chain, not what a sibling set). On the broken commit and on the candidate it reports exactly this line; on the fixed tree and the rest of the repo it reports nothing. It checks conditions only, so it is not a general lint: a variable read outside a condition, or set on only some paths into a later read, is not caught.

## 2026-10-27 (Roku: SHOW NOW PLAYING and MARK WATCHED, off by default)

**Shipped.** Nothing until it lands on main. Branch `roku/playback-report`, off #108 (`cd8f783`).

**Why.** Issue #72: the Roku never told Plex, Jellyfin or Emby what was playing, and never counted a watch. The Apple TV has two opt-in switches for that (w6trp's work, in 1.0.28's source). Chad asked for the Roku to match.

**Changed.**
- `source/guide/PlaybackReport.brs` (new): the two choices, saved through `NxRegSection("player")` and off until turned on; the epochs that revoke queued work when a choice goes off; the 15% entry / 75% watched gate; the tracker. The tracker is pure: it takes the clock and returns events.
- `source/guide/ReportExecutor.brs` (new): what goes to the server, one event at a time, as upstream's queued operations.
  - **Plex:** position-free `PUT /:/timeline` with the session in `X-Plex-Session-Identifier`. A counted watch is `GET /:/scrobble` with the bare key. For a counted episode whose show wasn't already in Continue Watching, the next-up entry is removed (three lookups, a second apart).
  - **Jellyfin and Emby:** the item's UserData is read first. With no reading there is no report and no mark. Then `/Sessions/Playing`, `/Progress` and `/Stopped`, the stop capped at 89% of the runtime. A counted watch is an explicit `POST PlayedItems`. When the session ends, the prior UserData goes back, or the counted state.
  - **Pulse backoff:** a server that stops answering gets fewer pulses (skip 1, 2, 4 ... 30). The setting never changes.
- `components/ReportTask.*` (new): runs the events on its own thread, so a slow or silent server never holds up the picture or the guide. It is created only once there is something to send; with both choices off since launch, nothing is created and nothing is sent.
- `components/GuideView.*`:
  - a tracker per airing (a retry or a step down keeps it), started at the first picture, pulsed every 10 s and stopped on a channel change, the card, the sleep timer, a rebuild or sign-out, and Back;
  - leaving with Back waits up to 4 s for the stop and the cleanup.
- `components/SettingsView.*`: SHOW NOW PLAYING ON <SERVER> and MARK WATCHED ON <SERVER> under CONNECTION, with upstream's wording.
- `source/guide/GuideSchedule.brs`: a block carries its item's runtime.
- Tests: `tests/ReportTests.brs`, 80 cases.
  - The cleanup plans against `scripts/watch-cleanup-golden.json` and upstream's module.
  - The backoff against `nostalgex-watch-state.js` (`tests/gen-watch.mjs`).
  - The gate, all four combinations of the two choices on Plex, Jellyfin and Emby, an unreadable baseline, the next-up removal with its retry, revocation and epochs, and the request shapes.
- `README.md` Security and the read-only notes in the playback files.

**Measured.** Off-device only: the tester owns the stick. The new suite crashes on the base (the functions don't exist) and passes here. Mutating the 89% cap or the 15% gate fails it.

**Half-done.**
- Not on a TV yet.
- The Roku section of the privacy page and the store listing still say read-only. Updating them needs the maintainer's OK (issue #72) and the site agent.

## 2026-10-26 (Roku: a test build can keep its own saved data)

**Shipped.** Nothing until it lands on main. Branch `roku/test-isolated-data`, off main `ae3cd6d`. Tooling for testing; a release is unchanged.

**Why.** The sideloaded build and the store beta on one TV share the registry, since both are signed with one developer key. So a tester can't sign the sideload in to a lab Jellyfin or Emby server without signing the store copy out of the real one. That blocked device checks for #60 (a small library) and #70 (BoxSets).

**Changed.**
- `source/util/Values.brs`: `NxDataSpace` reads `nx_data_ns` from the manifest. `NxRegSection(name)` opens `<space>-<name>`, and `NxCacheRoot()` is `cachefs:/<space>`. A manifest without the key gives `""`, so every name stays what it was.
- Every `roRegistrySection` in `source/` and `components/` (21) goes through `NxRegSection`. The saved library, guide, pools, enrichment cache and owner file go through `NxCacheRoot`.
- `scripts/stamp-manifest.sh` (new): writes `nx_build`, and with `--test-data` `nx_data_ns=nxtest`. `deploy.sh` passes `--test-data` when `NX_TEST_DATA=1`. `release.sh` stamps through it without the flag, and refuses a staged manifest that has `nx_data_ns`.
- `source/util/AppVersion.brs`: a test-data build's VERSION line ends in TEST DATA.
- Tests: `tests/stamp-test.sh` (run by `tests/run.sh`) checks:
  - the repo manifest has no `nx_data_ns`;
  - release.sh's stamp never writes it, even with `NX_TEST_DATA=1` set;
  - the test-data stamp writes it with the same build hash;
  - release.sh keeps its single plain call and its guard.

  `tests/VersionTests.brs` checks that a build without the key keeps `guide`, `cachefs:`, `cachefs:/nostalgex-library` and the plain VERSION line, and how a manifest value becomes a name.
- `README.md`: how to make a test-data build.

**Measured.** Off-device only: the stamp test fails on main (no `stamp-manifest.sh`) and passes here, and the whole suite passes one process at a time. Not on a TV yet: the tester owns the stick.

**Fixed after the tester's run.** SIGN OUT crashed every test-data build on a Streaming Stick Plus (`'Dot' Operator attempted with invalid BrightScript Component`, `NxCacheRoot` from `NxClearAccountCaches`). Sign-out runs on the render thread, where `CreateObject("roFileSystem")` gives invalid. `NxCacheRoot` now makes its folder with the global `CreateDirectory`. A release never reached that line. `tests/VersionTests.brs` signs a test-data build out off the TV, where roFileSystem is missing too. It reproduces the crash on the old code and passes now. `tests/run.sh` fails if `Values.brs` uses roFileSystem.

**Half-done.** Whether `cachefs:` is shared between the sideload and the store copy isn't measured; the change keeps them apart either way. The registry's per-key size limit is shared, and a test-data build adds its own few KB.

## 2026-10-26 (Roku: Dolby Vision profile 5 stays off channels on a TV without Dolby Vision)

**Shipped.** Nothing until the PR for #69 lands on main. Branch `roku/dv5-off-channels`, off main `2a0d3d4`. For Roku 1.0.6.

**Why.** On a Roku whose display can't show Dolby Vision, a profile 5 file plays green and purple (issue #69). Measured on a local Plex Media Server 1.43.5 with the Roku's own request: Plex copies profile 5 HEVC as it is when HEVC is offered, and refuses to convert it when it isn't ("Neither direct play nor conversion is available"), so there is no picture to ask for. Chad chose to keep such files off channels on such a TV, as the Emby rule already does on every TV.

**Changed.**
- `roku/source/guide/DolbyVision.brs`: on a display whose `GetDisplayProperties` says `DolbyVision` false, profile 5 goes on no channel, from any server. Profile 8 (an HDR10 or SDR base layer) and files without a profile stay. Called at the top of `buildGuide`; the shared `isLeftOffChannels` rule and `scripts/filter-golden.json` are unchanged.
- `roku/source/plex/PlexLibrary.brs`: Plex's section listing has no stream details, so on a display without Dolby Vision each section gets one more request for its `dovi=1` items with `includeElements=Stream` (type 4 for show sections), and their `DOVIProfile` is set on the items. A display with Dolby Vision makes no extra request.
- `roku/components/LibraryTask.brs`: the display's answer is part of the saved channel lists' key, so a stick moved to another TV builds them again.
- `roku/source/mediabrowser/MediaBrowserLibrary.brs`: Jellyfin's `DvProfile` is read when Emby's `ExtendedVideoSubType` isn't there.
- `roku/tests/DolbyVisionTests.brs` with trimmed real answers in `roku/tests/fixtures/dolby-vision.json` (Plex 1.43.5, Jellyfin 10.10.7): 14 cases.

**Measured.** Plex 1.43.5: `dovi=1` lists the profile 5 and 8.1 files of a movie section and, with `type=4`, the profile 5 episode of a show section. Jellyfin 10.10.7: `DvProfile` 5 for both profile 5 files, 8 for 8.1. Tests pass off the TV and on a Streaming Stick Plus. On that stick (DolbyVision false) against a home Emby server, the build leaves a profile 5 film off channels: "this display doesn't show Dolby Vision: 1 profile 5 item(s) left off channels".

**Half-done.** No eye test on a Roku with Dolby Vision (none here). Plex and Jellyfin profile 5 haven't been seen on a TV; the stick stays on Emby.

## 2026-10-26 (Roku: a TV left on keeps a current library)

**Shipped.** Nothing until the PR for #67 lands on main. Branch `roku/daily-library-refresh`, off main `2a0d3d4`. For Roku 1.0.6.

**Why.** A Roku left on for a day kept yesterday's library; it was read only at launch, on a server switch and from RESCAN LIBRARY (issue #67). The Apple TV checks every 15 minutes and refreshes once the library is 6 hours old.

**Changed.**
- `roku/source/util/DailyRefresh.brs`: upstream's `startDailyRefresh` rule. Every 15 minutes, once the last load (the one RESCAN LIBRARY's row reports) and the last check are both 6 hours old, the library is read again.
- `roku/components/MainScene.brs`: the 15-minute timer, started with the first guide, runs that read behind the guide through #98's path (`startLibrary`), never while a load already runs. A Plex server whose library signature is unchanged and whose save is under a day old isn't scanned (`NxSnapshotFresh`), as upstream's `refreshLibraryIfChanged` skips up to its 24-hour cap. Jellyfin and Emby have no signature and are read, as upstream.
- `roku/tests/DailyRefreshTests.brs`: 8 cases from upstream's constants.

**Measured.** The cases fail without `DailyRefresh.brs` and pass with it. Full suite passes off the TV and on a Streaming Stick Plus; the build launches clean there against Emby.

**Half-done.** The 6-hour refresh itself hasn't been watched on a TV.

## 2026-10-26 (Apple TV: franchise channel numbers that don't move with packages)

**Shipped.** Nothing. Branch `fix/franchise-numbering`, held for the next Apple TV bug-fix bundle.

**Why.** Chad, 2026-10-26. Found franchises and the server's franchise collections shared CH 300-499 and one id base, with the collections numbered straight after the found ones. Switching the FRANCHISES package, or any found franchise, renumbered and re-id'd every franchise collection. Channel numbers should stay put, and be the same on every platform for the same library.

**Changed.**
- `Models/Channel.swift`: `DynamicChannelBlock`, one fixed block per kind. Found franchises CH 300-449 (150), ids from 1,000,000 as before. Franchise collections CH 450-499 (50), ids from 1,010,000. Other collections CH 500-699 (200), ids from 1,020,000, unchanged. `CollectionCategory` reads its range from its block.
- Overflow (`DynamicChannelBlock.keptInDisplayOrder`), for the two franchise blocks: when more are switched on than fit, the ones with the most films stay, ties by name and then stable id, so every platform drops the same ones; the kept ones are numbered A to Z (name, then stable id) as before. OTHER COLLECTIONS keeps its old rule (first 200 A to Z), which is what the web tuner mirrors, so the web doesn't change.
- `AppState.materializeDynamicChannels` builds each block on its own; nothing in the collection blocks depends on the found franchises. `dynamicChannelsOverCap` is keyed by block. Settings: the found-franchise line says "Up to 150"; a collection category that is full gets the same line under its header.
- 1,010,000 was the retired NOTABLE STARS base. Checked before reusing it: no channel id is kept across launches in UserDefaults or iCloud (saved choices are franchise and collection ids, never channel ids). Today's schedules are keyed by channel id but rebuilt from a pool fingerprint and purged daily; the snapshot's runtime rows are rebuilt on restore; Top Shelf is rewritten every load. Nothing can bring back an old NOTABLE STARS id pointing at a new channel.

**Release notes (one-time move).** Franchise collections from your server move to CH 450 and up, and from then on they keep their numbers when you switch the FRANCHISES package or a found franchise. Their day's lineup reshuffles once, because the schedule is seeded by the channel. Found franchises keep their numbers (300 up) and their lineups.

**Measured.** NostalgexTests: 903 passed, 0 failures, on a tvOS 26.1 simulator; 6 new and 2 rewritten in `FranchiseNumberingTests` (toggling the package and a found franchise leaves franchise-collection and collection ids and numbers alone, block limits, overflow order). `npm test`: pass; no golden file or web engine file changes.

**Next.** Roku ports it on `roku/my-collections`.

## 2026-10-26 (publish Plex virtual channels from your own movies)

**Shipped.** Nothing until this lands on main. Vercel then deploys `https://www.nostalgex.app/blog/plex-virtual-channels-own-movies`.

**Why.** Scheduled publish for the Plex virtual channels post. The cable-TV walkthrough it used to link (`/blog/make-plex-feel-like-cable-tv`) is still a draft and goes live tomorrow, so that sentence was cut so a 404 does not ship today.

**Changed.**
- `content/blog/plex-virtual-channels-own-movies.md`: `draft: false`, `date` and `updated` both 2026-10-26. Cut the paragraph that started "I'm not going to repeat the full Plex setup here" and linked the still-draft cable-TV post. Other live links left as they were (`/blog/tunarr-ersatztv-alternative-apple-tv`, `/blog/apple-tv-channel-surfing-apps`, `/blog/best-90s-buddy-cop-movies-channel`, `/blog/90s-slasher-movies-halloween-marathon`, `/plex`, `/web-tuner`).
- `content/blog/apple-tv-channel-surfing-apps.md`: one sentence in "Is there a free app that turns my Plex library into live TV channels?" pointing at `/blog/plex-virtual-channels-own-movies`. Date on that post stays 2026-10-20.
- `scripts/media-sizes.json`: already had both R2 images. Cover is 1200x630, `teen-movies-channel-guide.webp` is 1280x720. Both URLs returned 200. Images stay on R2; none committed.
- `npm run blog:render` wrote ten live posts into `public/sitemap.xml`, including `/blog/plex-virtual-channels-own-movies` with lastmod 2026-10-26. `/blog` lastmod is 2026-10-26. The remaining draft (`make-plex-feel-like-cable-tv`) is not in the sitemap. `npm run bundles:render` then ran after the blog step, so the committed sitemap has the blog block above the channels block, matching main.

**Half-done.** `make-plex-feel-like-cable-tv` is still a draft.

**Next.** Tomorrow's publish of the cable-TV post, then the planned link-backs on the Jellyfin and Tunarr posts.

## 2026-10-25 (Roku: 5.1 Dolby audio through Plex)

**Shipped.** Nothing until the PR for #68 lands on main. Branch `roku/plex-surround`, off main `954473b`.

**Why.** A 5.1 film that Plex converts played in stereo on Roku (issue #68). The Apple TV's Plex profile keeps AC3 and E-AC-3, E-AC-3 capped at 6 channels.

**Changed.**
- `source/plex/PlexPlayback.brs`: the server stream offers AC3 and E-AC-3 (`add-transcode-target-audio-codec`) when `CanDecodeAudio` says the TV or its receiver takes them, as the Jellyfin/Emby request does, with upstream's `eac3ChannelCap`. The playback session is per audio offer.
- `components/GuideView.brs`: Playback information has an AUDIO row with what arrives.
- `tests/PlexAudioTests.brs`: 8 cases.

**Measured.** On a local Plex Media Server 1.43.5 with 60-second 5.1 test films, the Roku's own request: today every film comes as stereo MP3. With AC3 and E-AC-3 offered, AC3 and E-AC-3 5.1 are copied and DTS and 5.1 AAC become AC3 5.1 (decision endpoint and ffprobe of the actual HLS). With AC3 alone, E-AC-3 becomes AC3 5.1. The same hint for AAC is ignored, so the Apple TV's "AAC otherwise" is MP3 here. Tests pass off-device and on a Streaming Stick Plus; that stick, set to stereo, offers neither, so its requests don't change.

**Half-done.** Not played on a TV through Plex: the stick stays on Emby. The cap is unmeasured (ffmpeg can't make a 7.1 E-AC-3 file).

## 2026-10-25 (Roku: the Plex poster in Now Playing)

**Shipped.** Nothing until the PR for #76 lands on main. Branch `roku/now-playing-poster`, off main `954473b`.

**Why.** The Now Playing panel had no poster (issue #76). The Apple TV shows the Plex poster on the panel's left, Plex only.

**Changed.**
- `source/plex/PlexPoster.brs`, `components/PosterTask.*`: `posterURL(for:)` and `PlexAPIService.thumbnailURL` at 300 wide, 150 by 225 on screen. The request goes through `NxPlexTransfer`, so it follows every other Plex request's address rule (HTTPS, or plain HTTP to a home-network address) with the token in a header, never the URL. The file goes to `tmp:`.
- `components/NowPlayingView.*`, one line in `GuideView.brs`: the poster left of the info zone, a 14% white placeholder until it comes. Nothing more in the saved library: an item read back from it asks for its own `/thumb`.
- `tests/PosterTests.brs`: 15 cases, the home-network HTTP address among them.

**Measured.** Tests pass off-device and on a Streaming Stick Plus. On Emby the panel shows no poster, as upstream.

**Half-done.** A Plex poster hasn't been seen on a TV: the stick stays signed in to Emby. tydude was asked to check it on his.

## 2026-10-25 (Roku: SUBTITLES reads FOREIGN AUDIO until chosen)

**Shipped.** Nothing until the PR for #64 lands on main. Branch `roku/foreign-audio-default`, off main `954473b`.

**Why.** A foreign-language film had no subtitles on Roku until the viewer found the setting (issue #64). The Apple TV's `autoSubtitlesForForeignAudioEnabled` defaults to true.

**Changed.**
- `source/subtitles/SubtitleSettings.brs`: FOREIGN AUDIO is on until chosen; a saved choice is kept. Only a setting that changed is written, as upstream writes one key per setting, so the CC toggle no longer saves FOREIGN AUDIO as off.
- `tests/SubtitleTests.brs`: 5 cases for the defaults.

**Measured.** 24 subtitle cases pass off-device and on a Streaming Stick Plus. Settings on the stick, with nothing saved, reads FOREIGN AUDIO.

**Known.** A TV that ever pressed CC on 1.0.4 or earlier saved FOREIGN AUDIO as off and keeps it off; there's no migration. Beta notes: "Subtitles now turn on by themselves when a film's audio isn't in your language. If you ever pressed CC on an earlier beta, turn it on in Settings > SUBTITLES (FOREIGN AUDIO)."

## 2026-10-25 (Roku: RESCAN LIBRARY in Settings)

**Shipped.** Nothing until the PR for #66 lands on main. Branch `roku/rescan-library`, off main `954473b`.

**Why.** A film added on the server didn't show on Roku until the app was relaunched, and nothing in the app said what it held (issue #66). The Apple TV has RESCAN LIBRARY under CONNECTION for both.

**Changed.**
- `components/SettingsView.*`: a RESCAN LIBRARY row after the servers. Its lines, as upstream's subtitle: what the app holds (`LibraryDiagnostics.summary`), "Last updated ... Pull a fresh copy of your Emby library after adding content", and the last playback failure (`PlaybackDiagnostics.latestForSettings`). UPDATING while any load runs, when OK does nothing, as upstream.
- `components/MainScene.brs`, `GuideView.*`, `LibraryTask.*`: OK reads every server again behind the guide, as the launch refresh does, even one whose saved library is still fresh. The guide swaps only if the pools changed.
- `source/util/RescanInfo.brs`, `source/util/PlaybackVerdict.brs`: the counts are kept with the sign-in after each load; a programme given up on leaves a verdict line in upstream's wording.
- `tests/RescanTests.brs`: 37 cases from `LibraryDiagnosticsTests.swift` and `PlaybackFailure.diagnosticSummary`.

**Measured.** Tests pass off-device and on a Streaming Stick Plus (OS 15.3.4). Pressed on the stick against Emby: 1,544 items read again in about 3 s, the guide on screen unchanged ("background refresh matches the saved guide"), the row UPDATING meanwhile.

**Differences.** Upstream also clears its day schedules on a rescan; this keeps them, as the issue asks. Upstream's verdicts also log fallbacks; here only a programme given up on.

**Next.** Rebase after tydude's nine merge (MainScene.brs and the test lists overlap).

## 2026-10-23 (web and Docker: START OVER while the library loads)

**Shipped.** The web tuner on nostalgex.app when this lands on main, and Docker as `tuner-v1.0.8` from the same commit.

**Why.** The Apple TV got an always-visible START OVER on its loading screen because people got stuck in a load with no way back to sign-in. Measured on the web tuner (1.0.7) with a Jellyfin-shaped server that answers the sign-in check and the library list but never the items: after 90 s the page was still on SCANNING, the only things to click were the coffee button, CH -, CH +, SOUND and EXIT FULL SCREEN (Settings and its sign-out aren't reachable during the load), the one item request was never retried, and a reload signed in with the saved login and stuck at the same place. On a TV browser like TV Bro, where no keys reach the page, that was a dead end.

**Changed.**
- `plex-tuner.html`: a START OVER button on the loading screen, under the coffee, for the whole load. It runs the existing sign-out (session, saved login and library cache go) and then replaces the page with `web-tuner.html`. Leaving the page also drops the stuck requests, so a late answer can't rebuild channels for a login that is gone. It leaves even if the sign-out throws.
- `tunerVersion` 1.0.8, and README's Docker lines point at `tuner-v1.0.8`.
- `npm run test:start-over` (in `npm test`): the button is a real button inside the loading screen, and the page's own start over and sign-out clear the login and leave, last. Negative controls: no button, and a start over that skips the sign-out.
- `npm run test:start-over:browser` (needs Playwright, not in CI): the real page against a server whose scan never answers, at 960x540 and 390x844. START OVER is on screen, the click lands on the sign-in page with the saved login gone, and opening the tuner again starts no library load. Negative control: without the button nothing on screen leads back to sign-in.

**Measured.** The browser test: 16 passed, no page errors. `npm test`, both builds, the isolation and version build checks: pass.

**Next.** Push main and tag `tuner-v1.0.8`. Roku has no START OVER on its loading screen yet; that's a port.

## 2026-10-23 (web and Docker air the Apple TV's schedule)

**Shipped.** The web tuner on nostalgex.app when this lands on main, and Docker as `tuner-v1.0.7` from the same commit. Every channel's lineup reshuffles once, on the first load after the update. The Apple TV doesn't change. Roku isn't ported yet and keeps its own schedule until it is.

**Why.** Chad, 2026-10-22: every surface follows the Apple TV's schedule. The web engine already packed a day the way the Apple TV does, but the page fed it different pools and did different things with the result. Roku parity queue items 24 and 25.

**Changed.**
- `plex-tuner.html`: pools stay in library order (the page shuffled every pool by UTC day before the engine saw it). Minutes are truncated as the Apple TV's loaders do (`Math.round` before). The guide reads a 24-hour window across midnight, not today's blocks only. One title on two channels at once stays on the lowest channel id; the others lose their now-playing mark in the guide, as on the Apple TV, and still play that title when tuned, also as on the Apple TV. When a programme ends on its own, the next one plays from its start (the page used to jump to what the clock said, from where the clock said), skipping a title another channel has on at that moment. After a stall or a failure, what is on now from where it is. The info panel shows what the player is playing, as `InfoPanelView` does, since the player can now run a little behind the clock. Demo items get keys.
- `scripts/nostalgex-daily-manifest.js`: mirrors of `ChannelScheduleBuilder.buildSchedule`, `blocksInRange`, `resolveConflicts`, `findConflict`, `ChannelSchedule.isCurrent` and `livePlayback`, `AppState.selectChannel` and `advanceToNextItem`, and the loaders' minute and date conversions. Stored manifests move to schema 2, so a day an older tuner stored is packed again on the first load after the update instead of airing the old way until midnight.
- `tunerVersion` 1.0.7, and README's Docker lines point at `tuner-v1.0.7`.
- `scripts/schedule-parity-golden.json`: generated from `NostalgexTests/ScheduleParityTests.swift` running the app's own code on fixtures in Plex, Jellyfin and Emby shapes: New York's 25-hour day, London's 23-hour day, Santiago's day that starts at 1 AM, 16 channel-instants giving a title way, items the loaders drop, one-minute and longer-than-a-day items. `scripts/schedule-parity-golden.mjs` builds it. `npm run test:schedule-parity` checks the engine byte for byte and runs the page's own schedule functions on it, with 8 negative controls. The Swift test asserts the same file.

**Measured.**
- Before the change, on Chad's Plex library (11,788 items) with a 95-channel lineup, today: the web aired something other than the Apple TV in 92.6% of channel-minutes (93 of 95 channels). The pool shuffle alone: 91.9%. Rounding alone: 41.8% (57.6% of items have a different length rounded). Plex's episode order is the same either way (the Apple TV's one sweep and the page's per-show requests gave the identical sequence on both TV sections).
- After: the web engine and the Apple TV's code give the same bytes on the golden file and on that whole library and lineup (2 days, 2 instants, 95 channels). The page itself, headless against the same server with the page's 17-channel default lineup at one frozen instant, matched the Apple TV on all 119 channel fields (now, next, window, tune, guide, conflict, next pick).
- One title on two channels on the Apple TV's schedule today: 2,669 channel-minutes (1.95%); at 72 of 4,610 programme changes the next title was already on another channel.
- Headless at 390x844, 820x1180, 1440x900 and 960x540: tune, then the player's own `ended` handler plays the engine's pick from the start; guide rows render, no page errors, no sideways scroll.
- `npm test`, `npm run build`, `npm run build:selfhost`, the isolation and version build checks: pass. NostalgexTests: 880 tests, 0 failures, on a tvOS 26.1 simulator.

**Half-done.**
- Same engine is not same minute. A day is packed with what the device stored for the day before. On this library, a device first opened two days later than another still differs on 39% to 44% of channel-minutes after five days, and one with no history at all on 75% to 79%. That holds between two Apple TVs too. Closing it needs a change on the Apple TV.
- On Jellyfin and Emby the Apple TV adds each batch of 10 shows' episodes in the order the requests finish. Eight loads of the same 30-show test server with the app's own loader gave eight different orders. Run on this library's shape, a rescan changed 7% to 9% of channel-minutes (33% to 41% on channels with episodes). The web adds them in show order, so Jellyfin and Emby can't match until the Apple TV does too.
- Not on the web: disc-stacked Jellyfin and Emby movies (the Apple TV schedules the whole runtime and plays disc 2), and runtime franchise and collection channels.

**Next.** Push main and tag `tuner-v1.0.7`. Roku ports the same answers against `scripts/schedule-parity-golden.json`. Chad decides on the history and the Jellyfin order (board item q36).
## 2026-10-23 (the site for Apple TV 1.0.28)

**Shipped.** Nothing until this lands on main. Branch `site/1.0.28`. Apple TV 1.0.28 has been on the App Store (Ready for Sale) since this morning.

**Why.** The site only shows the App Store version, so the 1.0.28 notes, the privacy policy and the sign-in descriptions wait for the release, and the release is out.

**Changed.**
- `content/changelog.json`: 1.0.28 is `released: true`, rendered into the home page's What's New. 1.0.27 was folded into it and never had an entry of its own.
- `privacy.html` (effective October 23): the Apple TV app now starts looking for a Jellyfin or Emby server as soon as you pick one, and asks the system's Local Network question the first time. Before you sign in it asks the server for its public details, whether Quick Connect is on, and the users it lists on its login screen, shown as tiles and never saved. Checked against `Views/SignInFlow.swift` on main and the sign-in spec. The Roku paragraph says the same of Roku 1.0.4, checked against `roku/components/ConnectView.brs` and `roku/source/mediabrowser/SignInFlow.brs` at `roku-v1.0.4`. Sitemap lastmod for /privacy moves to 2026-10-23.
- Sign-in copy for the 1.0.28 flow, plug and play first: `/apple-tv` step 2 and its seasonal line, the hero, steps, quick start, FAQ and tips on `/jellyfin` and `/emby` (FAQ structured data matches the visible answers), the Jellyfin and Emby notes in the server cards on the home and server pages, and two lines on `/support` (the Apple TV card, and the web tuner's own Emby button).
- `README.md`: What's new is 1.0.28, and the releases line says 1.0.28 is live. Its link to the `v1.0.28` GitHub release works once that release is published.
- `content/blog/franchise-channels-your-collections.md`: SCAN MY COLLECTIONS lists TV show collections too, as of 1.0.28.

## 2026-10-23 (publish franchise channels from your collections)

**Shipped.** Nothing until this lands on main. Vercel then deploys `https://www.nostalgex.app/blog/franchise-channels-your-collections`.

**Why.** New live post. Chad's copy was already `draft: false` and dated 2026-10-23. The article is how franchise channels fill from a Plex, Jellyfin or Emby library, including TV spinoffs, and how existing server collections fold into one channel.

**Changed.**
- Added `content/blog/franchise-channels-your-collections.md` as given. No copy edits. Other posts untouched, including the two remaining drafts (`make-plex-feel-like-cable-tv`, `plex-virtual-channels-own-movies`).
- `scripts/media-sizes.json`: cover at `site/blog/franchise-channels-your-collections/cover.jpg` is 1200x630. The two inline guide frames (`library-franchises-guide.webp`, `jurassic-park-guide.webp`) are 1280x720. All three R2 URLs returned 200. Images stay on R2; none committed.
- `npm run blog:render` wrote nine live posts into `public/sitemap.xml`, including `/blog/franchise-channels-your-collections` with lastmod 2026-10-23. `/blog` lastmod is 2026-10-23. `npm run bundles:render` then ran after the blog step, so the committed sitemap has the blog block above the channels block, matching main.

**Half-done.** The other drafts are still drafts: `make-plex-feel-like-cable-tv`, `plex-virtual-channels-own-movies`.

**Next.** Nothing on this post.

## 2026-10-22 (Roku 1.0.4: sound from Jellyfin and Emby, Dolby as stereo AAC, the VERSION line)

**Shipped.** Nothing yet. Branch `roku/1.0.4` = main `c21813e` (tydude001's #55, #53, #54, #56, #48 and #51, merged in that order) plus `build_version=4`. Not signed.

**Why.** A Dolby film played silent on a Streaming Stick Plus set to stereo (Discussion #8). Measured there: Emby copied AC3 and E-AC-3 into the stream because the request offered them, and the Roku played no audio from fMP4 segments at all, on Emby and on Jellyfin, so any Jellyfin or Emby server stream sent as fMP4 was silent. #55 asks both servers for TS with only the audio the TV decodes, 2 channels unless it decodes 5.1 AAC. With it: #53 asks baseline H.264 as main (a Roku only names main and high, so these files had gone to the server since #46), #54 the hint for a .local name, #56 the password keyboard's voice domain (certification 4.12), #48 the VERSION line, #51 the off-TV tests in parallel.

**Changed.**
- `roku/manifest`: `build_version=4`.

**Measured.** On the Streaming Stick Plus (Roku OS 15.3, audio stereo; it decodes no AC3, E-AC-3 or 6-channel AAC), Emby 4.10.1:
- `tests/run.sh` on the six PRs merged locally in the same order (the same `roku/` tree as main `c21813e`): ALL TESTS PASSED in 126 s on macOS. `deploy.sh --test` from this branch: ALL TESTS PASSED, all 27 suites (filter 373 on the TV, 371 off it: the interpreter skips its 2 key-case vectors, as before). The app build hashes `dbd1441bc6e1`, the same as the local merge the stick tests ran on.
- In the app: an AC3 5.1 airing and an E-AC-3 5.1 airing went to the server as `VideoCodec=h264,hevc&AudioCodec=aac&TranscodingMaxAudioChannels=2&SegmentContainer=ts`. Emby converted the audio to stereo AAC, the player reported `aac_adts`, and the picture came up in 1.5 s. Dennis the Menace (E-AC-3 2.0) with the same request in a throwaway player: `aac_adts`.
- #53: a Constrained Baseline 3.1 MP4 (36 of the first 200 films on this Emby) plays direct with picture and AAC; a channel that had sent one to the server since #46 played it direct again.
- #56: the password keyboard opens with no console warning. Voice entry needs a voice remote, so it wasn't tried.
- #48: the VERSION line sits under the intro text on the connect screen.
- The 1.0.4 app build on a signed-in launch: sign-in check ok, 19 channels in 2.9 s, launch complete in 7.9 s. Chad's Emby sign-in unchanged (registry compared before and after).

**Half-done.**
- Not heard yet. Chad listens on the stick. tydude measured the sync within 5 ms for HEVC 10-bit over TS joined about 30 minutes in, on his lab Emby and Jellyfin.
- A 4K remux through the server fails on this stick: a 4K HEVC Dolby Vision 8.1 film at 29 Mb/s stops with error -3 ("Requested reservation ... is larger than the entire buffer"), over TS and over fMP4 alike, and the app moves on to the next airing. 1.0.3 played it direct, with picture and no sound. It goes to the server since #46 because its AC3 isn't decodable here; #55 doesn't change that. It needs its own fix.
- Without `AudioStreamIndex` the server plays the file's default audio track (Portuguese and German on two test films). Queue item 12.

**Next.** Sign on Chad's go, then the upload to beta 888351 and Publish on his go.

## 2026-10-22 (1.0.27 folds into 1.0.28)

**Shipped.** Nothing. The project reads 1.0.28 (52), as on branch `build-52`, and the 1.0.28 changelog entry stays `released: false`.

**Changed.** 1.0.27 never ships on its own: build 52 carries everything in it, plus the new Jellyfin and Emby sign-in and the ratings fix. Its changelog entry folds into 1.0.28 (27 bullets, nothing dropped), so the site shows one entry when 1.0.28 ships. The version and build number come from `build-52`'s commit, because the changelog check wants an entry for the version the project reads.

## 2026-10-22 (publish Plex Apple TV sit-back alternative)

**Shipped.** Nothing until this lands on main. Vercel then deploys `https://www.nostalgex.app/blog/plex-apple-tv-app-sit-back-alternative`.

**Why.** New live post. Chad's copy was already `draft: false` and dated 2026-10-22. The article is a sit-back alternative for people who miss things in the redesigned Plex Apple TV app (Watch Together, the trailer button, some library filters) and would rather not browse at all.

**Changed.**
- Added `content/blog/plex-apple-tv-app-sit-back-alternative.md` as given. No copy edits. Other posts untouched, including the two remaining drafts (`make-plex-feel-like-cable-tv`, `plex-virtual-channels-own-movies`).
- `scripts/media-sizes.json`: cover at `site/blog/plex-apple-tv-app-sit-back-alternative/cover.jpg` is 1200x630. The inline Girls Night guide still from the Jellyfin post already had its 1280x720 entry. Both R2 URLs returned 200. Images stay on R2; none committed.
- `npm run blog:render` wrote eight live posts into `public/sitemap.xml`, including `/blog/plex-apple-tv-app-sit-back-alternative` with lastmod 2026-10-22. `/blog` lastmod is 2026-10-22. `npm run bundles:render` then ran after the blog step, so the committed sitemap has the blog block above the channels block, matching main.

**Half-done.** The other drafts are still drafts: `make-plex-feel-like-cable-tv`, `plex-virtual-channels-own-movies`.

**Next.** Nothing on this post.

## 2026-10-21 (Roku 1.0.3: the sign-in redesign and ratings from other countries)

**Shipped.** Roku beta 1.0.3 (channel 888351), signed and published 2026-10-22 09:29 UTC; package md5 `fe816755723e0cbed9697bc98cb66394` (in `roku/releases.tsv`). Branch `roku/1.0.3` = main `65c886f` (the sign-in redesign and the ratings fix) plus the build number and a fixed build hash. The dashboard's static analysis gave the same three known items as 1.0.2: the getUserData (RFI) error and two Authentication warnings.

**Why.** Chad's go for a Roku beta with the sign-in redesign (entry below) and the rating normaliser (`ad139fc`, GitHub #41). The beta runs 1.0.2, and the dashboard takes only a version past it.

**Changed.**
- `roku/manifest`: `build_version=3`.
- `deploy.sh` and `release.sh` hash the staged files with `LC_ALL=C sort`: the hash followed the shell's locale, so the 1.0.2 tree hashed `cca0d38` under C and `d27182e` under en_US. The 1.0.3 tree hashes the same in both now.
- After signing: `release.sh` takes the signing key's password from the login Keychain (item "Nostalgex Roku signing key", account `nostalgex-roku`) when the shell doesn't give it, and falls back to the prompt. Chad makes the item with `-T ""`, so macOS asks to allow every read. `RELEASING.md` has the one command to make it.

**Measured.** On the Streaming Stick Plus, `deploy.sh --test`: ALL TESTS PASSED, ratings 296, sign-in 97 (the dry-run registry check among them), lineup 154, DST golden 320. The 1.0.3 app build on a signed-in launch: the guide built, no errors. `release.sh --dry-run` passes to the signing step. Chad's sign-in on the stick unchanged.

**Next.** Testers' devices pick up 1.0.3 on Roku's own schedule (the stick still reported 1.0.2 just after publishing). The RFI item stays with the 2.2 sign-in question before a public submission.

## 2026-10-21 (Roku: the Apple TV sign-in redesign, ported)

**Shipped.** Nothing. Branch `roku/signin` off main `93419d9` (after the ratings fix, the web sign-in and the Apple TV sign-in), pushed as a branch and not merged, for a Roku beta after Chad's go. Not in any package.

**Why.** Chad wants the same login on every platform, after the Apple TV's sign-in redesign (`signin-redesign`, `562c9f3`; spec in the internal `SIGNIN-FLOW.md`). The Roku took 4 presses to a Jellyfin Quick Connect code (counted from the code), asked the viewer to pick a found server and then Quick Connect, checked nothing but the address's kind before the password, closed its keyboards only from the dialog's own OK button (Back abandoned what was typed), and focus was a faint outline.

**Changed.**
- `components/ConnectView.*`: the Apple TV's screens, order, focus defaults, words and colours. Picking Jellyfin or Emby starts the network search; one server answering opens it with no pick; none puts focus on TYPE AN ADDRESS. The address is asked who it is before anyone types, so Jellyfin with Quick Connect on opens straight on the code, and an Emby server's users show as tiles (one with no password signs in on the press). Closing the keyboard moves on: OK is Done, Back keeps the text and moves to the next control.
- Plex's plex.tv/link code and QR code now show on the connect screen with CANCEL, and a Plex sign-in error shows there in red (`components/MainScene.brs`). The library picker starts on CONTINUE and has the same look (`components/ServerPickerView.brs`).
- `source/mediabrowser/SignInFlow.brs`: the decisions, after `SignInFlow.swift`: discovery outcome, the address check (`/System/Info/Public`, `/QuickConnect/Enabled` on Jellyfin, `/Users/Public`), which way in, where focus starts, Quick Connect polling (a failed poll waits on, as upstream), every line of copy. Discovery replies are read and merged by server Id as upstream's, listening 3 s.
- The look: `images/look/ob_*.9.png` from `scripts/look-images.py`, the focused slab, edges, field frame and pills with their glows.
- Copy from the spec: "Incorrect username or password.", and "That address answered, but it isn't Jellyfin..." when Quick Connect can't start on a non-Jellyfin address. Then the spec's revision (buttons named by their on-screen label, "press", never "tap"): each expired code names the button that makes a new one, the plex.tv lines end "press CONNECT TO PLEX again" and are chosen by the request's code (429, no DNS, timeout, other), and "Check the address" replaces "Check the URL".
- Where errors land, as the spec: the address check on the screen it came from (amber), Quick Connect and password on the sign-in screen (red), every Plex error on the first screen (red) with CONNECT TO PLEX focused. The plex.tv/link code now stops after 5 minutes with "The code expired. Press CONNECT TO PLEX for a new one." where the port fetched a fresh one every 5 minutes. The launch check of a saved Plex sign-in keeps its own line: it shows with the guide up, where OK is the retry.
- `scripts/deploy.sh --tour`: the connect screens on their own (`tests/signin`), to walk with a remote and count presses; `?discovery=none|several` and `?picker=1` stand in where one network can't show a screen. The tour is a dry run (`ConnectView.dryRun`): finishing a Jellyfin or Emby sign-in in it asks no server, saves nothing and writes no install id. A saved sign-in deletes the Plex one, a sideloaded build shares its saved data with the store build signed with the same key, and Jellyfin ends a device's earlier session when the same device signs in again.
- The address check stops at 12 s overall, each request at 8 s, as the spec.
- `scripts/deploy.sh --test`: the console listener is `exec cat`, so stopping it closes the TV's one console connection. A `cat` left over from an earlier run held it for over three hours.

**Measured.** On a Roku Streaming Stick Plus (OS 15.3.4), lab Jellyfin 12.2.0 (Quick Connect on) and an Emby 4.10.1.0 with one password user, counted as upstream counts (typing is 2 presses). The last press of each sign-in was not made on the stick, which holds a real sign-in, and is added to the count.

| Path | Apple TV | Roku before (from the code) | Roku now |
|---|---|---|---|
| Plex | 1 | 1 | 1 |
| Jellyfin, Quick Connect | 2 | 4 | 2 |
| Jellyfin, password | 8 | 7 | 8 |
| Emby, server found | 7 (4 with no password) | 7 | 7 (4) |
| Emby, typed address | 11 (8) | 8 | 10 (7) |

"Roku before" is counted from the old code, not on a TV, closing each keyboard as 1 press. The old flow opened the password keyboard by itself and signed in on its OK, so by that count it was a press shorter on the password paths; but its keyboards closed only from the dialog's OK button, several presses away on a Roku keyboard, where the new one closes with Back. "Roku now" counts the Apple TV's way (Back, then SIGN IN); OK on the password keyboard signs in a press sooner. The no-password counts follow from the code (no such user on the test server). `tests/SignInFlowTests.brs`: 74 cases, `SignInFlowTests.swift`'s plus the port's, passing off the TV and on the stick (`deploy.sh --test` ALL TESTS PASSED); a broken merge and a broken Quick Connect default fail 4 of them. `run.sh` ALL TESTS PASSED. Static analysis: nothing reported. Back on the first screen leaves the app. After the copy revision: 85 cases (every plex.tv line, and none says "tap"), `run.sh` again; the Plex expiry landing seen on the stick through the tour (`?plexerror=1`); MainScene's own Plex error path needs a signed-out TV and was not run. After the review: 95 cases on the stick, one of them a TV-only check that a dry run leaves every registry section, key and value as it was (compared by hash).

**Not like the Apple TV.** No demo mode (the store's test credentials stand in); the port's own wordmark; one limited broadcast for the search, where upstream also sends a directed one per subnet (it found the Emby on a /22 anyway); no letter spacing and no animation on focus; long field text cut at the end. The VERSION line under the intro is tydude001's item on #8, not here.

**Next.** Chad's go for a beta. tydude001's VERSION line and home-hostname changes touch the same screen and `NxIsPrivateHost`; whichever lands second rebases.

## 2026-10-21 (Apple TV sign-in: the search starts on its own, Quick Connect by default, focus you can see)

**Shipped.** Not yet. On main for 1.0.28 (from branch `signin-redesign`, rebased onto `5a4a873`); not in any build. The 1.0.28 changelog entry, shared with the ratings fix, stays `released: false`.

**Why.** Chad: the Jellyfin and Emby sign-in took too many presses, and on every connect screen it was hard to tell which control the remote was on. Measured in the simulator first: a focused button differed from the rest only by an outline going from 55% to 100% and a fill from 8% to 16%, so an unfocused CONNECT TO PLEX looked brighter than a focused JELLYFIN; a fresh launch started with nothing focused, so the first press only found the screen; Jellyfin took 10 presses by Quick Connect and 15 by password, Emby 15.

**Changed.**
- One focus style for every connect screen (`Views/OnboardingStyle.swift`): the focused control is a solid cyan slab with dark text, 7% bigger, with a glow; the others are outlines. On the two code screens (Plex and Jellyfin Quick Connect) the buttons light up as a cyan outline and glow instead, so the code stays the brightest thing on screen. The Plex library picker, the loading screen's STOP WAITING and the empty-library buttons use the same style.
- Text fields are drawn by us. A SwiftUI TextField on tvOS always paints the system platter inside it (a white pill when focused, which white text and password dots all but vanished on, and a grey one when not), and neither `.plain` nor `focusEffectDisabled()` turns it off. The real field now sits shrunk under an opaque drawing made from the same text and focus state: focused is a dark well with a cyan frame and glow, white text and a light caret; unfocused is a dim well with a grey edge. Contrast is checked in `OnboardingContrastTests`: typed text and dots 17.9:1 focused and 11.7:1 unfocused, placeholder 7.0:1 and 5.0:1.
- Each screen puts focus on its first choice when it appears. A fresh launch starts on CONNECT TO PLEX. The Plex library picker starts on CONTINUE, since the usual choice is already ticked.
- Jellyfin and Emby: picking one starts the network search straight away; FIND MY SERVER is first and focused as the retry. One server answering opens it with no pick; several are listed; none, or a declined Local Network prompt, leaves focus on TYPE AN ADDRESS. That first search is what brings up tvOS's Local Network prompt, so when the app comes back from the prompt it searches once more. Coming BACK to the screen does not search again, or one server answering would bounce the viewer straight back.
- Before anything is typed, the app asks the address who it is (`Views/SignInFlow.swift`, `check`): `/System/Info/Public`, then `/QuickConnect/Enabled` on Jellyfin, then `/Users/Public`. A Jellyfin server with Quick Connect on opens straight on the code, with SIGN IN WITH A PASSWORD as the other way in. A server that lists its users (Emby does by default) shows them as tiles, so the name is a press instead of typing, and a user with no password signs in on that press. The server's own answer decides Jellyfin or Emby, and a wrong address fails on the address screen with the reason instead of after the password.
- Closing the keyboard, with Done or Back, moves on: the address gets checked, the username goes to the password, the password goes to SIGN IN (Done on the password signs in). The move waits for tvOS to hand focus back to the field, then goes on at once.
- The keychain and storage diagnostics line is off the connect screen in every build (Chad: "just take out that log information on the far left"). The same values go to the log when the screen opens (subsystem `com.muellhaus.nostalgex`, category `auth`), where a sign-in that didn't survive a restart can still be read off a device. VERSION stays.
- Messages name what the screen has. "Code expired. Tap Connect to try again." pointed at a Connect button neither code screen has (found by the Roku port). A Plex code that runs out now says "The code expired. Press CONNECT TO PLEX for a new one." on the picker, and a Quick Connect code "The code expired. Press USE QUICK CONNECT for a new one, or sign in with your password." on the password screen. The plex.tv request errors say "press CONNECT TO PLEX again" instead of "tap Connect again", "Check the URL" became "Check the address" to match SERVER ADDRESS, and the library timeout says "press RETRY". `SignInCopyTests` checks there is no "tap" or "URL" in any sign-in line.
- Sign-in itself is unchanged: the same `authenticateJellyfin`, `startJellyfinQuickConnect` and `authenticateEmby`, given the address the check found.
- The connect screen's accessibility identifier no longer replaces every control's own (`.accessibilityElement(children: .contain)`), so UI tests can find its controls by id.
- The shared scheme carries three launch arguments, off by default: `-uiTestForceSettings 1`, `-uiTestDiscovery several` and `-uiTestDiscovery none`.

**Measured.** Remote presses from a fresh launch to a signed-in library, in the simulator, against a lab Jellyfin 12.2.0 (Quick Connect on) and a lab Emby 4.10.1.0 on the test Mac, plus a real Emby on the same network for discovery. Typing into a field counts as 2 presses (open the keyboard, close it); the characters are not counted. The UI tour that measured it is `NostalgexUITests/SignInTourUITests` (opt-in, needs those servers); all 9 runs pass.

| Path | Before | After |
|---|---|---|
| Plex (code entered at plex.tv/link) | 2 | 1 |
| Jellyfin, Quick Connect | 10 | 2 |
| Jellyfin, password | 15 | 8 |
| Emby, server found on the network | 15 | 7 (4 for a user with no password) |
| Emby, typed address | 15 | 11 (8 for a user with no password) |

Emby has no Quick Connect (`/QuickConnect/Enabled` is a 404 on 4.10.1.0), so its shortest path is the user tiles. The Emby "found" count is 4 measured to the password field on the real Emby (no password to finish with) plus 3 measured on the lab Emby. NostalgexTests: 880 passed, 0 failed, 13 skipped (opt-in harnesses), with 21 in `SignInFlowTests` and 5 in `OnboardingContrastTests`. The connect screen shows VERSION and no diagnostics line (checked in the tour's first run).

**Half-done.**
- Not looked at on a real Apple TV: the focus style from the couch, the Local Network prompt appearing as the Jellyfin or Emby screen opens and the search after it is answered (the simulator never shows that prompt), and the keyboard-close focus move.
- Several servers answering and none answering were seen only through the `-uiTestDiscovery` stand-in.
- The Plex library picker starting on CONTINUE was not reached: the test account has one server.
- The lab Jellyfin library is too small to fill a channel, so its runs end at NO CHANNELS FOUND rather than a guide.

**Next.** Chad tries it in Xcode, then a pass on a real Apple TV. The web tuner and Roku connect screens should follow the same flow. The Apple TV privacy page does not describe the network search yet; it says nothing about it today either.

## 2026-10-21 (/apple-tv linked from the home page and the footers)

**Shipped.** Nothing until this lands on main. Branch `site/link-apple-tv`.

**Why.** Chad approved `/apple-tv` and asked for it to be linked: the yellow Apple TV tile on the home page and the footer link, renamed from "Apple TV app" to "Apple TV".

**Changed.**
- `index.html`: the Apple TV tile goes to `/apple-tv` instead of the App Store. Same look.
- The footer on every site page now says "Apple TV" and goes to `/apple-tv`: the eight static pages with a footer, and `scripts/site-chrome.mjs` for the blog and the channel guide. The buttons to the App Store, the nav's "Get the tvOS app" included, still go straight there with their `ct`.
- The tuner pages are left as they are, so `web-tuner.html` keeps its own footer, which still says "Apple TV app" and goes to the App Store. Their build output is unchanged.


## 2026-10-21 (the web tuner, apart from the marketing site)

**Shipped.** With the sign-in in the entry below: the web tuner on nostalgex.app when this lands on main, and Docker as `tuner-v1.0.6` from the same commit. Nothing should look different.

**Why.** Chad: "anything that touches the marketing site should never affect the web tuner or the docker container - those should feel very separate." Today it did. `web-tuner.html` linked the site's `styles.css` and `app.js`, and the hosted build compiled it with the site, so `dist/web-tuner.html` loaded the very same `assets/styles-*.css` and `assets/app-*.js` as the home page. The Docker build bundled the same two files. A site CSS change reached the tuner's connect page and the next Docker image.

**What was coupled, and what was not.**
- Coupled: the stylesheet and script above; the hosted build (one Vite run for site and tuner, with the site's plugins and `public/`); the logo and icon files in `logo/` and `public/`; the Docker context, which let in `styles.css`, `app.js` and `logo/`; the analytics loader on the connect page, edited as site code today.
- Not coupled: `plex-tuner.html` has its own inline styles and loads no site script. `scripts/site-chrome.mjs` is only used by the blog and channel-page generators. No site page loads the tuner's engine scripts.
- Shared on purpose and kept: `vercel.json` (routes and one set of headers for the whole domain) and the Google Fonts links.

**Changed.**
- `tuner/` is the tuner's own: `connect.css` holds the 108 of `styles.css`'s 630 rules the connect page uses, picked by testing every selector against the page in each state (both themes, menu open, scrolled, every sign-in screen) on the hosted and Docker builds, then frozen. `signin.css` is the sign-in (it was `tuner.css`). `connect.js` is the theme toggle, nav scroll state, mobile menu and email signup, copied word for word from `app.js`. `logo/` has copies of the logo and icons both pages use.
- `vite build --mode tuner` builds the two tuner pages on their own, with no `public/` and assets in `tuner-assets/`, after the site build, which no longer sees them. `npm run build` runs both. URLs are unchanged.
- The Docker context takes `tuner/` and no site file.
- The connect page's analytics loader is the tuner's own copy, hosted only as before.
- `npm run test:tuner-isolation` (in `npm test`) fails when a tuner page loads a site file, `tuner/` imports anything, a site generator reads a tuner page, either build takes the other's pages, the Docker context lets a site file in, or `vercel.json`'s CSP drops a source the tuner loads. `npm run test:tuner-isolation:builds` (CI web job) builds a temporary copy, makes site-only edits (`styles.css`, `app.js`, `index.html`, `site-chrome.mjs`, a `public/` file), builds again, and fails unless every file the tuner ships hashes the same.
- `tunerVersion` 1.0.6, and README's Docker lines point at `tuner-v1.0.6`.
- `web/signin` also got a fix found here: on the hosted build Vite loaded the site stylesheet after the tuner's, so its `:focus-visible` rule squared off focused fields and buttons (2px corners) where Docker had the spec's 14px. The panel's corners now win in either order.

**Measured.**
- Screenshots, hosted and Docker builds, 960x540 and 1440x900, dark and light: the page, the full page, the menu, and every sign-in screen, 46 hosted and 44 Docker. Before against after: 0 pixels differ. Two runs of the unchanged build differ by nothing except, sometimes, the hero headline's anti-aliasing at 960x540 in the light theme (up to 4,985 pixels, at most 51 levels per channel); that flicker showed once in an after run and not on the rerun.
- The build check: 91 tuner files hash the same after the site-only edits. On today's layout it fails as it should: 11 of 93 files change on origin/main `a2bc1bb`, 11 of 96 on `web/signin`.
- Docker image 94.6 MB (94.7 MB before). It now holds the two pages, their bundle, the tuner's engine scripts, vendored libraries and fonts, and the data files.
- Signing in and tuning, headless: on the Docker build and on the hosted build, the lab Emby by typed address and a no-password user, then the guide loaded 11 items into 4 channels and started channel 406, no page errors. The Docker sign-in tour (Jellyfin Quick Connect in 2 presses, password, wrong password, Escape) passed as on `web/signin`.
- `npm test`, `npm run build`, `build:selfhost` green.

**Next.** Not tried in TV Bro on a Google TV yet. The connect page can now change its own look without touching the site; that would be a separate design step.

## 2026-10-21 (web tuner: the Apple TV sign-in, screen by screen)

**Shipped.** The web tuner on nostalgex.app when this lands on main, and Docker as `tuner-v1.0.6` from the same commit, together with the separation in the entry above.

**Why.** The Apple TV app's connect screens were rebuilt for 1.0.28 (find the server first, Quick Connect by default, user tiles, focus you can see from the couch). The web tuner and Docker get the same flow so every product signs in the same way.

**What each casing can do (measured).**
- A browser can't send UDP, so no LAN discovery the Apple TV way.
- From the hosted page (https), headless Chromium could fetch no http server at all: not `localhost:8096`, not `127.0.0.1:8096`, not two servers on the LAN. Mixed content plus local network rules.
- From a page served over http (the Docker container), all four answered, and Jellyfin 12.2.0 and Emby 4.10.1.0 send CORS headers on every call the flow makes.
- Broadcast discovery from inside the container got no replies, on Docker's default bridge network and on host networking under Colima, whose VM sits behind its own NAT. The same probe from the Mac got both servers. A Linux host with host networking is unverified.

**Changed.**
- `web-tuner.html`: the connect card is now the Apple TV screens: picker, find, type an address, checking, sign in, Quick Connect. Focus lands on each screen's first choice, Enter in a field moves on as closing the keyboard does on a TV, Escape is BACK, arrow keys move like a D-pad, and every step has a button for TV Bro, which sends no keys. Plex keeps its flow, gains a CANCEL, and its errors use the spec's lines ("Click CONNECT TO PLEX for a new one").
- The hosted page opens Jellyfin and Emby on TYPE AN ADDRESS and defaults a typed address to https. On Docker, FIND MY SERVER runs as the screen opens and asks, in parallel, the last address used, the machine the tuner page came from, and localhost, all on 8096. One answer goes straight to it, several give a list, none gives the amber line with focus on TYPE AN ADDRESS.
- After the address, both casings match Apple TV: the check (`/System/Info/Public`, then `/QuickConnect/Enabled` on Jellyfin, then `/Users/Public`), a Jellyfin with Quick Connect on opening on the code, Emby user tiles where a user with no password signs in on one click, and the server's own answer beating the button that was pressed.
- New `scripts/nostalgex-signin.js` holds the logic (address candidates, discovery replies, the three parsers, the check, find, the Quick Connect controller, password sign-in, copy). `scripts/signin-golden.json` has the cases, written from the Apple TV tests, for a Swift test and the Roku port to read too; `npm run test:signin` runs them. The Quick Connect smoke test now drives the controller the page uses.
- New `tuner.css` holds every sign-in style, so nothing here depends on the site's `styles.css` (Chad's rule from today). The panel is black with the spec's cyan focus slab, outline-glow on the code screens, and dark-well fields with a cyan frame.
- `.dockerignore` allows `tuner.css`. Without it the image linked a stylesheet it didn't have: Vite only warns. `scripts/selfhost-build.mjs` now fails the build when a tuner page links a local file the output doesn't contain.
- CI: the sign-in files start the channel engine job (which runs `npm test`), and `tuner.css` the web and Docker jobs.

**Measured.** Headless Chromium, keyboard only, against a lab Jellyfin 12.2.0 and Emby 4.10.1.0, on the Docker build and on the hosted build served over http:
- Jellyfin, Quick Connect: 2 presses (Tab, Enter), the same as Apple TV. The code was approved through the Jellyfin API and the page landed in the tuner.
- Jellyfin, password: 5 (typing a field and pressing Enter counted as one). Wrong password: the red line, still on the screen.
- Emby on another port, typed, user with no password: 7, one of them an arrow key to reach the tile. Then the tuner loaded the library and started a channel, no page errors.
- Escape walked back screen by screen, and coming back to the find screen did not search again.
- Hosted preview (https): Jellyfin opened on the address field, a LAN address got the "address on your own network" line, a site that isn't a server got the "isn't a Jellyfin or Emby server" line, and the Plex code came up with CANCEL focused.
- No horizontal scroll and no page errors at 1440x900, 960x540, 820x1180 and 390x844, dark and light.
- `npm test`, `npm run build`, `build:selfhost` green. The live Quick Connect smoke test passed against the lab Jellyfin, through `AuthenticateWithQuickConnect` and a library list with the new token.

**Not done or not verified.**
- An Emby user with a password signing in for real: the lab account's password couldn't be recovered, so only the 401 path was seen. The same call signed in a Jellyfin user and an Emby user without a password.
- Docker find covers the tuner's own machine and localhost, not another machine on the LAN. Real discovery would need host networking on Linux plus a small helper in the image.
- Not tried in TV Bro on a Google TV, or in Safari or Firefox.
- No Swift test reads `signin-golden.json` yet: `SignInFlow` lives on `signin-redesign`. Roku has its own port, on `roku/signin`.

**Next.** See the entry above.


## 2026-10-21 (ratings from other countries count like their US equivalents, GitHub #41)

**Shipped.** The web tuner on nostalgex.app and Docker `tuner-v1.0.5`, from the same commit. The Apple TV app gets it in 1.0.28 and Roku in beta 1.0.3.

**Why.** Every rating rule matched exact US labels. Jellyfin and Emby store a certificate from outside the US with its country in front (`TmdbUtils.BuildParentalRating`: `GB-15`, `GB-12A`, and Germany as `FSK-16`), and a UK library in #41 also showed `TV-12A`. On a UK server:
- the 27 channels with a `contentRatings` allow-list turned down `GB-U` and `GB-PG`, so the kids and family channels came out thin;
- the kids and family adult gate didn't see `GB-18` as adult, and MINION HQ leans on that gate alone;
- VHS VAULT's 9 PM rule (`blockRatings` R and NC-17) aired `GB-18` films by day.

**Changed.**
- One normaliser per engine: `usContentRating` in `scripts/nostalgex-channel-filter.cjs`, `ContentRating.usLabel` in the new `Nostalgex/Nostalgex/Models/ContentRating.swift`, and `NxUsContentRating` in `roku/source/filter/ChannelFilter.brs`. A label it recognises becomes the US label of its age band, by item type: a film reads G, PG, PG-13, R or NC-17, an episode TV-G, TV-PG, TV-14 or TV-MA. TWEEN TV lists only TV labels and FAMILY HOUR only film labels, so `GB-U` has to be TV-G on one and G on the other. US labels, empty ratings and anything it doesn't recognise come back unchanged.
- Bands: 0 is all ages, up to 10 is PG, 11 to 14 is PG-13 or TV-14, 15 and up is R or TV-MA, and adult-only certificates (BBFC R18, Australia's X18+) are NC-17. Word labels for the UK (U, PG, 12A, R18), Ireland, Australia, New Zealand, Canada, France and the Netherlands; a number from any country, Germany's FSK included, reads as an age. It takes `GB-15`, `gb/15` (Plex style, not seen on a real server), `FSK-16`, `FSK 16`, a bare `12A` and `TV-12A`. The labels come from Jellyfin's `Localization/Ratings` tables, and a label between two bands takes the stricter one.
- Used in every rating check: the adult gate, the allow-list and VHS VAULT's `blockRatings` (`getTimeFilteredPool` in `plex-tuner.html`, `Channel.filteredPool`, Roku `NxTimeFilteredPool`). Swift works the label out once per item in `FilterCache`. The guide and Now Playing still show the label the server sent. If the browser ever pairs a fresh page with a cached older filter script, VHS VAULT's check reads the raw label instead of throwing, which would have left the channel without a schedule.
- Shared tests: new `scripts/rating-golden.json`, 296 cases read by `npm run test:ratings`, `RatingGoldenTests.swift` and `roku/tests/RatingGoldenTests.brs`. The node test also fails when a label in the table has no case. 15 GB, FSK and `TV-12A` cases in `scripts/filter-golden.json`, 12 of which fail on the old engine. Roku's generated filter and lineup vectors now carry GB, FSK, IE, AU and NZ labels.
- CI path filters: the two golden files and their tests now start the tvOS, channel engine and Roku jobs, and `plex-tuner.html` the channel engine job, since the ratings test reads VHS VAULT's rule from it.
- `tunerVersion` 1.0.5, and README's Docker lines point at `tuner-v1.0.5`. A 1.0.28 changelog entry, `released: false`.

**Measured.** A test library of 11,641 items (2,961 films, 8,680 episodes, all US labels) through all 139 channels, on the old engine (`2f68a9e`) and the new one:
- With its US labels, every pool is the same byte for byte: 29,892 placements, the same hash. The all-channel filter took 5.0 s both ways.
- Relabelled the way a UK Jellyfin server stores it (G, TV-Y, TV-Y7 and TV-G to GB-U, PG and TV-PG to GB-PG, PG-13 to GB-12A, TV-14 to GB-12, and R, NC-17 and TV-MA split between GB-15 and GB-18), the 16 kids and family channels hold 1,291 items before and 12,095 after (10,871 with US labels). FAMILY HOUR 0 to 234, DIZ TV 0 to 813, TWEEN TV 374 to 966, SAT MORNING CARTOONS 40 to 698. No GB-15 or GB-18 item is on a kids or family channel, before or after. The 111 channels with no rating rule don't change.
- AFTER SCHOOL TV (1,240) and FAMILY TV (4,896) end up wider than with US labels (1,053 and 3,859). The UK has no label for shows made for young children, so a TV-Y7 show is U there and reads as TV-G, which those two take.
- VHS VAULT holds 113 of its 269 films until 9 PM with US labels. With GB labels it held 0 before and holds 113 now.
- In Chromium, the Docker build against a real Plex server (11,763 items, playback and enrichment requests blocked), old and new filters run over the same loaded items in the page: with the server's US labels, all 139 channels match (34,292 placements each). With the library rewritten to GB labels in flight, only the 25 channels with a rating rule change, all upward (FAMILY HOUR 0 to 239, FAMILY TV 395 to 4,452), and VHS VAULT at 4 PM airs 163 of its 278 films, the same as with US labels. Loaded and tuned with no page errors at 960x540, 1440x900, 820x1180 and 390x844. A page paired with the old filter script still tunes.
- `npm test`, `npm run build` and `build:selfhost` green, both builds at 1.0.5. NostalgexTests 858 passed, 0 failed, 13 skipped. `roku/tests/run.sh` ALL TESTS PASSED: rating golden 296, filter golden 235, filter vectors 371, lineup 154.
- Not checked against a real UK library, or a Plex server with non-US ratings. The Roku change ran in the off-device interpreter only, not on a TV.

**Calls worth a second look.**
- `GB-18` on a film is R, not NC-17. Both are adult to every check, and R keeps 18-rated films on R RATED COMEDY, NAUGHTY LIST and CHRISTMAS SPECIALS, which don't list NC-17. Jellyfin's older table puts GB-18 level with R too.
- `GB-15` on an episode is TV-MA, the stricter side; Jellyfin's older table put it level with TV-14. Australia's M (advised for 15 and up) and New Zealand's M (16 and up) are R or TV-MA for the same reason.
- A foreign label it doesn't recognise is left alone, so it passes the adult gate and fails every allow-list, as before.

**Next.** Push main and tag `tuner-v1.0.5`. Apple TV in 1.0.28. Roku 1.0.3 needs a manifest bump and a signed package.


## 2026-10-21 (a real /apple-tv page, the 404 in the house style, one CTA button everywhere)

**Shipped.** Nothing until this lands on main. Branch `site/apple-tv-404`, a Vercel preview for Chad's review.

**Why.** `/apple-tv` was a permanent redirect to the home page, so the Apple TV app had no page of its own for search or for an App Store campaign. The 404 page had a look of its own. Chad then asked for the main buttons to match on every page, with the store badges as supporting marks rather than buttons.

**Changed.**
- `apple-tv.html`: the page, from Chad's copy. The App Store links carry `ct=site_appletv_page`. Facts are checked against the `v1.0.26` tag, the App Store version: 131 channels in 14 bundles; KIDZ ZONE, DECADES, FRANCHISES, SCREAM and TIS THE SEASON are the real bundle names; Plex signs in with a code, Jellyfin and Emby can find the server on the network (Jellyfin then takes Quick Connect or a login, Emby a login); in full screen left and right change channels, up brings up the channel strip and down what's playing. In 1.0.26 a seasonal bundle is offered in its month (SCREAM in October, TIS THE SEASON in December) and stays on all year once switched on. The week-before-Thanksgiving start for TIS THE SEASON arrives with 1.0.27, so the page says December. The FAQ names Pseudo TV, Tunarr and ErsatzTV on purpose.
- `vercel.json`: a `/apple-tv` rewrite replaces the permanent redirect to `/`. A browser that cached the old redirect can keep going home until its cache clears.
- `404.html`: on the site's stylesheet and fonts, but with no nav or footer, at Chad's ask: a small TV of static, "Channel not found.", one line and one Back to home button, centred in the window. Still a real 404 with `noindex`.
- One CTA button on every page: the house `.btn` (`.btn-ink` first, `.btn-paper` second, `.btn-lg` or `.btn-sm`). The sunset closer no longer swaps the button shadows. Every button to the App Store, the nav's "Get the tvOS app" included, leads with a small retro TV glyph instead of the Apple logo, which Apple's guidelines keep to their badge. The home page Apple TV tile uses the same glyph.
- Apple's "Download on Apple TV" badge (`public/badges/download-on-apple-tv-black.svg`, unaltered, 44 px) is a supporting mark, once per page, next to that page's main Apple TV button: under the hero buttons on the home, Plex, Jellyfin, Emby and Apple TV pages, under the buttons at the end of each blog post, and in the Apple TV tile on `/roku`. Those footers carry Apple's credit line. Source and terms in `docs/BRAND-ASSETS.md`.
- Roku has no badge for apps and its logo may only come from Roku's own artwork. The home page Roku tile now says Roku in plain text with a Beta sticker (it said Coming), `/roku` has the registered mark on its first Roku and Roku's trademark notice, and `public/og-roku-1200.png` says "on Roku" in type.
- Analytics: the statsngraphs tag was `async`, which still holds the window load event until the script arrives. It now loads from a small inline script after `load` on every page that had it, `scripts/site-chrome.mjs` included. On `/web-tuner` the loader sits between selfhost strip markers, and `scripts/selfhost-build.mjs` now fails if "statsngraphs" survives in the Docker build in any form.
- The blog and the channel guide lost their stylesheet on this branch, caught in review. Those pages are written after Vite and found the hashed CSS by name (`app-*.css`). Once the 404 stopped loading `app.js`, Vite named the shared stylesheet `styles-*.css`, the lookup missed, and `scripts/site-chrome.mjs` fell back to a `/styles.css` that isn't in dist: 23 pages unstyled, nothing failed. The lookup now takes the stylesheet and script from what the built home page links, and throws if either is missing. `scripts/dist-asset-check.mjs` runs at the end of `npm run build` and fails when any built page points at a local stylesheet, script, image or video that isn't in dist. It fails on the broken build (23 missing) and passes on this one.
- The App Store links in the nav and footer of `/apple-tv` and `/roku` carry those pages' `ct` too.
- `privacy.html`: the Apple TV app's Find servers on my network (UDP broadcast to port 7359, only when pressed, stays on the network), and which pages load analytics.
- `public/sitemap.xml` and `public/llms.txt` list `/apple-tv`. `/roku` stays unlinked.

**Half-done.** Chad's review of the preview.

## 2026-10-21 (nostalgex.app/roku: the Roku beta page, live and unlinked)

**Shipped.** `https://www.nostalgex.app/roku`, live with this push to main and unlinked on purpose: no footer link, not in the sitemap or `llms.txt`, and no home page change. Chad reviews the live page first; the links come after.

**Why.** The Roku app is a beta with 20 tester spots, added by access code, and the site had no page to send people to.

**Changed.**
- `roku.html`: the page. Hero with the Roku guide, three steps, what you get, how to join the beta, credit to tydude001 with links to the official source in `roku/` and to this repo, four FAQs, and two colour tiles for Apple TV and the web tuner. The Apple TV tile carries the App Store campaign token `ct=site_roku_page`. Copy is Chad's, with facts checked against `channels.json` and `roku/README.md`: KIDZ ZONE, SCREAM and TIS THE SEASON are real bundle names, and the tip jar is named as Apple TV only, because the Roku app has none. Step 3 points at the Nostalgex Discord in general; there is no Roku channel there, by Chad's choice.
- `content/roku.json` + `scripts/render-roku.mjs`: the hero button and the beta card are generated, the same arrangement as `/self-host`. `betaFull` is the one switch for when the 20 spots are taken: true takes the add link and the access code off the page and leads with the Discord button. `announcementPost` links a blog post from the credits once one exists, and the render fails if that post is missing or still a draft. `npm run build` renders it; `npm test` fails if `roku.html` is stale.
- `public/og-roku-1200.png` and `public/screens/roku-*.webp`: the share card and two screenshots, from the Roku listing screenshots of 2026-10-18.
- Wiring: the `vite.config.js` input and the `/roku` rewrite in `vercel.json`. Nothing else on the site links to it yet.

**Measured.** `npm test` and `npm run build` pass. Checked at 1440 and 390 px in both themes: no horizontal scroll, no console errors. The full state rendered and screenshotted, then flipped back. `my.roku.com/account/add/JRLVTGL` answers 302 to `/account/add?channel=JRLVTGL`, then sends a signed-out browser to Roku sign-in with that page as the return address. The signed-in page is not checked.

**Half-done.** The links. Once Chad OKs the live page: `/roku` in every footer (the static pages and `scripts/site-chrome.mjs`), in `public/sitemap.xml` and `public/llms.txt`, the home page Roku tile (it still reads "Coming" and links Discussion #8), and the Roku row on `/self-host` (`content/self-host.json`).

**Next.** Flip `betaFull` when the beta reaches 20 testers.

## 2026-10-21 (Roku 1.0.2: the clock-change fix, and a one-command signed release)

**Shipped.** Nothing yet. Branch `roku/1.0.2` = main `9efefa4` (which has the clock-change fix) + the release script + the version bump, not pushed. No package signed or uploaded.

**Why.** The Roku beta runs 1.0.1, which packs every day as 86,400 s, and the US clocks go back on Sun Nov 1. The Roku dashboard only takes a version past the last one it saw.

**Changed.**
- `roku/manifest`: `build_version=2`, so the app is Nostalgex 1.0.2. It carries the Roku port of the clock-change fix (`85cb3a1`, see the entry below).
- `roku/scripts/release.sh`, `roku/releases.tsv` and the Roku section of `RELEASING.md`, from `roku/release-script` (`a0d0f3d`, rebased): build as `scripts/deploy.sh` does with enrichment on, check the stick holds the signing key's Dev ID, install, sign, download the `.pkg` and log it. The script refuses a version that isn't past `releases.tsv` and every `roku-v*` tag.

**Measured.**
- `roku/tests/run.sh` on this branch: ALL TESTS PASSED. Lineup vectors 154, DST golden 320, schedule 174.
- `release.sh --dry-run`: version 1.0.2 past 1.0.1, enrichment on, build `cca0d38c709d` (95 files, 671 KB).
- Roku static analysis (`sca-cmd`, Java 21) on 1.0.2: nothing reported at any severity.
- The stick reports the signing key's Dev ID.
- On a Roku Streaming Stick Plus (OS 15.3.4), `scripts/deploy.sh --test`: ALL TESTS PASSED. Lineup 154, DST golden 320, schedule 174, filter 373, collections 2,586, mediabrowser 5,395, all with 0 failed. That closes the clock-change entry's hardware gap for Roku. On macOS, `deploy.sh` needs stand-ins for GNU `timeout` and `stat -c`.
- The saved sign-in survived the test build and then the app build. The beta from the store and the sideloaded build share one saved-data store, because they are signed with the same key.

**Next.** Sign 1.0.2, upload it to the beta and tag `roku-v1.0.2`.

## 2026-10-21 (clock changes: a day runs to the next midnight, on every surface)

**Shipped.** The web tuner on nostalgex.app when this lands on main, and Docker as `tuner-v1.0.4` from the same commit. The Apple TV app in 1.0.27 build 51 (TestFlight 2026-10-21, App Review next). The Roku app in its next package, 1.0.2.

**Why.** Where the clocks change, a local day is 23 or 25 hours long (23.5 or 24.5 on Lord Howe), and all three engines packed every day as 86,400 s from midnight and found yesterday 86,400 s before it.
- The day the clocks go back: its schedule ended at 11 PM. From 11 PM to midnight the Apple TV tuned to the logo and SELECT A CHANNEL, and the web tuner handed the player the day's last programme at a start point past its end. The Roku port does what the web tuner does.
- The day after they go forward: the 23-hour day's schedule ran an hour into the next one, and the next day's no-repeat check read two days back, so it aired titles from the day before.

**Changed.**
- Swift and JS (`901a99a`, on `dst-fix` since 2026-10-20): a day packs from its midnight to the next local midnight, the start of the day 36 hours on, and yesterday is the day 12 hours before midnight. `DailyManifestStore.startOfNextLocalDay` and `previousLocalDayKey`, and `startOfNextLocalDayMs` and `previousLocalDayKey` in `scripts/nostalgex-daily-manifest.js`. Days that aren't change days come out byte for byte as before.
- Shared vectors (`901a99a`): `scripts/schedule-dst-golden.json`, 60 days in 10 zones (US, EU, Sydney, Lord Howe, Santiago where midnight is skipped, and Phoenix, Kolkata and UTC as controls). The harness behind it is `scripts/dst-harness/` (`f8eefe3`).
- Roku port: the same two changes. `roku/source/guide/Lineup.brs` gets `NxStartOfNextLocalDaySec` and `NxPreviousLocalDayKey`, and `NxPackDay` takes the day's end, as the Swift `packDay` does. @tydude001 found the bug and pointed out that the port's start of day was already right, so only these two needed porting. New `roku/tests/ScheduleDSTGoldenTests.brs` reads the shared golden file, byte-copied into `tests/vectors/` like the other golden files. `roku/tests/gen-dst.mjs` writes each zone's UTC offsets from the tz database so the test can pin the zone. The packDay vectors now carry the day's end. `roku/docs/PORTING.md` says the port no longer keeps the 24-hour day.
- `npm run test:schedule-dst` checked the golden file's midnights with Temporal, which node 22, the CI runner, doesn't have, so `npm test` would have stopped there in CI. It reads the tz database through Intl now. On node 26 the two agree on all 60 midnights.
- CI path filters: the golden file now triggers the roku, tvos and channel engine jobs, and its smoke test the channel engine job.
- `tunerVersion` 1.0.4, and README's Docker lines point at `tuner-v1.0.4`. One line in the unreleased 1.0.27 changelog entry.

**Measured.**
- DST harness, web, before (`f8eefe3`): 45 to 60 minutes past the last block on each 25-hour day (20 to 30 on Lord Howe's 24.5), and 16 to 21 repeats the day after each 23-hour day on the big channel, 63 in London, a full rerun. After: 0 minutes past the last block, 0 with nothing on, 0 repeats. The small and medium channels start and end exactly at midnight every day.
- DST harness, Apple TV, after (`DSTHarnessTests` over the same plan): 0 minutes with nothing on, 0 repeats, and the same blocks as the web tuner on every day and every sampled minute in all 18 scenarios.
- Roku: lineup vectors 154 passed (8 `dst` cases failed before the port), DST golden 320 passed. With the old arithmetic put back, the golden fails exactly 21 cases, the 14 days that aren't 24 hours and the 7 days after a short one, none in Phoenix, Kolkata or UTC: the same 21 as the node test's negative control.
- `npm test` green on node 26 and node 22. `npm run build` and `build:selfhost` green, both at 1.0.4. NostalgexTests 854 passed, 0 failed, 13 skipped (opt-in harnesses). `roku/tests/run.sh` ALL TESTS PASSED.
- Not run on hardware. The Roku change ran in the off-device interpreter only, not with `scripts/deploy.sh --test` on a TV. The Apple TV side ran in the simulator, which checks the schedule, not playback.

**Not fixed.**
- The web guide's last hour before midnight shows a programme that won't air, because the guide has no tomorrow yet: 60 minutes every night in every zone. Not a clock-change bug.
- London, Dublin and Lisbon: the day after the spring change gets the same day number as the day before (its midnight is 23:00 UTC), so it shuffles with the same seed. The no-repeat check still keeps the day before's titles off. It first matters on 29 March 2027.

**Half-done.** No hardware run yet: the Roku change needs `scripts/deploy.sh --test` on a TV before the 1.0.2 package, and build 51 hasn't been opened on an Apple TV.

**Next.** Submit 1.0.27 (build 51) for App Review so it is live before Nov 1. Run the Roku tests on a TV, then sign and upload Roku 1.0.2.

## 2026-10-21 (terms of use page, Roku privacy for Jellyfin and Emby)

**Shipped.** `https://www.nostalgex.app/terms` (new) and an updated `https://www.nostalgex.app/privacy`, live when this lands on main.

**Why.** The Roku Streaming Store listing asks for a terms of use URL, and the site had no terms page. The privacy page's Roku section still said Plex only, but the Roku app imported into `roku/` on 2026-10-20 (tydude's `7bde5df`) also signs in to Jellyfin and Emby.

**Changed.**
- New `terms.html`, laid out like `privacy.html` (same inline styles, back link, no site chrome). Covers the Apple TV app, the Roku app, the web tuner and the self-hosted container: publisher Muell Haus Inc. and support@nostalgex.app; Nostalgex supplies no video and the user is responsible for their server and the rights to their media; Plex, Jellyfin, Emby, TMDB, OMDb, MusicBrainz, Apple and Roku are third parties with their own terms, with TMDB's attribution line; MIT for the code (root `LICENSE` and `roku/LICENSE`) with the name, logo and nostalgex.app outside the grant, as the README says; Apple TV tips are optional in-app purchases that unlock nothing, refunds through Apple; as is, no warranty; liability limited as far as the law allows; privacy at /privacy; changes posted with a new effective date. No governing law, jurisdiction or address, since none is on record. Effective October 21, 2026.
- `/terms` wired in wherever `/privacy` is: `vercel.json` rewrite, `vite.config.js` input, `public/sitemap.xml` (privacy lastmod moved to 2026-10-21 too), the Help list in `public/llms.txt`, the footer of every hand-written page and of `scripts/site-chrome.mjs` (blog and channel guide), the support page's closing line, and the `web` path filter in `ci.yml`. All outside generated regions.
- `privacy.html` and `Nostalgex/PRIVACY_POLICY.md`, Roku section, read from the code in `roku/`: Plex, Jellyfin and Emby; the plex.tv/link QR code is drawn on the TV (`source/util/QrCode.brs`), so the code goes to no QR service; Jellyfin and Emby are found by a UDP broadcast to port 7359 on the home network (`NxMbDiscover`) or a typed address, sign in by Quick Connect (Jellyfin) or username and password, and only the access token is saved (`NxMbSaveSignIn`), never the username or password; server requests are HTTPS or plain HTTP to a private address only, with the token in the `Authorization` header and never in a URL (`NxServerTransfer`, `NxMbStreamContent`); no playback reporting to any of the three, but leaving a converted stream asks the server to stop it (`NxStopStream`); what the TV stores for a Jellyfin or Emby sign-in; memory warnings (`source/main.brs`) are printed to the TV's debug log and sent nowhere. Effective date October 21, 2026 in both files.

**Checked.** No analytics library, no `GetRIDA` or advertising id, and the only hosts in the Roku code are plex.tv, the user's server, the relay on www.nostalgex.app and the Supabase project a build is given. Enrichment is on only when a build sets `NOSTALGEX_ENRICHMENT=on`; the relay bullet stays, written for a build with it on, as before.

**Next.** Enter `https://www.nostalgex.app/terms` in the Roku developer dashboard's terms field.

## 2026-10-21 (publish Plex remote streaming post)

**Shipped.** Nothing until this lands on main. Vercel then deploys `https://www.nostalgex.app/blog/plex-remote-streaming-changes-explained`.

**Why.** New live post. Chad's copy was already `draft: false` and dated 2026-10-21. The article explains Plex's late-September 2026 remote playback rule for third party apps (Infuse, Plezy, and Nostalgex), who needs a pass when a family shares a server, and why a TV at home can still look remote.

**Changed.**
- Added `content/blog/plex-remote-streaming-changes-explained.md` as given. No copy edits. Other posts untouched, including the two remaining drafts (`make-plex-feel-like-cable-tv`, `plex-virtual-channels-own-movies`).
- `scripts/media-sizes.json`: cover at `site/blog/plex-remote-streaming-changes-explained/cover.jpg` is 1200x630. The inline Buddies / EuroTrip still from the Jellyfin post already had its 1280x720 entry. Images stay on R2; none committed.
- `npm run blog:render` wrote seven live posts into `public/sitemap.xml`, including `/blog/plex-remote-streaming-changes-explained` with lastmod 2026-10-21. `/blog` lastmod is 2026-10-21. `npm run build` then ran `bundles:render` after the blog step, so the committed sitemap has the blog block above the channels block, matching main.

**Half-done.** The other drafts are still drafts: `make-plex-feel-like-cable-tv`, `plex-virtual-channels-own-movies`.

**Next.** Nothing on this post. The article points at a separate post about switching the channel guide to Jellyfin or Emby; that is not this file.

## 2026-10-20 (the web tuner says its version in Settings)

**Shipped.** Nothing yet. Branch `web/tuner-version` on build-50 (473c5ca), this entry included, not pushed. nostalgex.app gets it when main is pushed, Docker with `tuner-v1.0.3`, cut right after.

**Why.** Chad: "on the web tuner do we put anywhere the version number? I think we should do that". Nothing on the page said which tuner was running, so a support report from the web or a container could not name a build. The Apple TV app has `VERSION 1.0.26 (50)` at the bottom of Settings.

**Changed.**
- One number: `"tunerVersion"` in `package.json`, 1.0.3. The hosted build can't read it from git, because Vercel's clone is shallow and has no tags, so it is committed. Not package.json `"version"`: package-lock.json repeats that one, and `npm version` would tag `v1.0.x`, which in this repo means an Apple TV release.
- New `scripts/tuner-version.mjs`. The build takes `NOSTALGEX_TUNER_VERSION` when it is set (the Docker release passes the tag's version), else package.json, and writes `<meta name="nostalgex-tuner-version" content="1.0.3">` into `plex-tuner.html` and `web-tuner.html` in both builds. A missing or malformed value fails the build. The self-host `config.json` default gets the same number instead of `dev`.
- Settings, a last line under the footer: `WEB TUNER 1.0.3` on nostalgex.app, `WEB TUNER 1.0.3 · DOCKER` in the container. VT323 18px, 35% white, centred, selectable, after the Apple TV's VERSION line. The container's number comes from its `config.json`, else the page's meta tag. Anything that isn't a release number (dev, empty, a missing file) shows no line at all. The hosted page makes no extra request; the container makes one `config.json` fetch.
- Docker. The build arg defaults to empty (was `dev`), so a plain `docker build .` carries package.json's number. `docker/40-config.sh` takes `NOSTALGEX_TUNER_VERSION`, else the version the build wrote into the image's own `config.json`, else an empty string. It no longer writes `dev`. A local build's `org.opencontainers.image.version` label is empty; the release sets it.
- Release. `.github/workflows/docker.yml` stops before pushing when the tag and `tunerVersion` differ. RELEASING.md has the step: bump `tunerVersion` in the commit you tag. `ci.yml` checks both builds after `build:selfhost`, and the PR docker smoke checks the meta tag, the container's value and an environment override.

**Measured.**
- `npm run test:tuner-version`, now in `npm test`: 59 checks. The module; the page's own section in a VM with a fake DOM and fetch (20 cases: hosted, the container's value, the fallbacks, and dev, empty, a placeholder, "undefined" or a missing file hiding the line; the hosted page makes no request); three negative controls; where the line sits in the markup; and `40-config.sh` under sh with its two paths pointed at a temp dir. Breaking the DOCKER suffix fails 9 checks, breaking the script's fallback to the built file fails 4.
- `npm test` green. `npm run build` and `npm run build:selfhost`, then `npm run test:tuner-version:builds`: 69 checks, 10 on the built files. No regenerated file changed.
- A local image run three ways: no build arg gives 1.0.3, `--build-arg NOSTALGEX_TUNER_VERSION=1.0.3` gives 1.0.3, `-e NOSTALGEX_TUNER_VERSION=1.0.9` gives a `config.json` of 1.0.9 and `WEB TUNER 1.0.9 · DOCKER` in Settings. Built with the legacy builder (no buildx here), from a scratch copy of the Dockerfile without the platform pin and `--chmod`; the version path is the same. The `ci.yml` smoke lines pass against these containers, and the `docker.yml` check passes for `tuner-v1.0.3` and fails for `tuner-v1.0.2`.
- Headless Chromium, signed out: the line is in view and inside the Settings panel at 1440x900, at 960x540 (the TV zoom, about 12px tall) and on a 390x844 phone (demo channels, MENU, SETTINGS in the drawer), for both builds, with no page errors. With the meta tag removed, or an empty value in the container, there is no line.

**Unverified.** A real TV browser and a real phone. The release workflow itself, which only runs on a tag.

**Next.**
- Cut `tuner-v1.0.3` from the merge; `tunerVersion` already says 1.0.3. README's "Latest: `tuner-v1.0.2`" moves with it.
- Seen on the way, not changed: on a phone the Settings footer's key hints (ESC, TABS, ENTER, DEL, coffee) don't fit and overlap. They mean nothing on touch.
- Draft changelog line, not in `content/changelog.json`: "The web tuner shows its version at the bottom of Settings."

## 2026-10-19 (Emby A/V sync fix moved onto build 50)

**Shipped.** Nothing. Branch `fix/emby-avsync-ts` is rebased onto `build-50`, not merged, not in any build. The 2026-10-16 entry below has the cause and the first measurements.

**How it sits with build 50.** Build 50 changed the same PlaybackInfo request: no subtitle stream (`SubtitleStreamIndex` -1, every subtitle profile External), a second request that burns a forced track in the viewer's language (Encode), and the Dolby Vision range list on the HEVC codec profile. The segment format is one more parameter next to those and touches none of them. For an H.264 file the Emby body differs from build 50's in two values, the transcoding profile's `Container` (mp4 to ts) and `VideoCodec` (h264,hevc to h264); for HEVC it is the same body. The forced-subtitle request asks for the same format as the first. Jellyfin is unchanged.

**Measured.** Lab Emby 4.10.1.0, each build's own request body (encoded by the app code), fetched in AVPlayer's order with 400 ms per segment, two encodes per join (the first, then the restart at the join segment). The H.264 + DTS eye-test file joined at 160 s, where the soak test joins:

| Join segment | build 50 | branch |
|---|---|---|
| Format | fMP4 | MPEG-TS |
| First PTS, video / audio | 0.083 / 0.000 s, both from zero | 164.154 / 165.979 s: source time + 10 s, the keyframe before 156 s and 156 s |
| Beep minus flash | -1916 ms | -8 ms |

The same file joined at 247.3 s: -1832 / -15 ms. The flash-per-second H.264 + DTS file: -1930 / -22 ms at 160 s, -1816 / +1 ms at 247.3 s; in AVPlayer on a Mac, -1833 / +14 ms and -1719 / +36 ms. HEVC + DTS: fMP4 on both, -1916 ms on both, the known limit. Forced subtitles over TS: Emby burned an SRT forced track (subtitles filter) and a PGS forced track (overlay) into libx264 MPEG-TS segments, AC3 copied, every segment 200.

**Tests.** NostalgexTests: 831 run, 819 passed, 0 failed, 12 skipped (build 50 alone: 819 run, 807 passed, 12 skipped). `EmbySegmentContainerTests` gained two: TS changes nothing in the body but the transcoding profile, with and without a burned track; and the forced-subtitle request asks for the same format as the first. `npm test` green.

**Next.** The eye test on the living room Apple TV, Debug 1.0.27 (50) with and without the fix.

**Checked on a real Apple TV 4K (2026-10-20)** against a real Emby 4.10.1 library: a DTS film (H.264 MKV, the audio converted by Emby) joined part way through had its voices clearly ahead of the lips before the fix, and in sync after. An AC-3 film plays in sync either way, because Emby copies AC-3 rather than converting it.

## 2026-10-19 (TIS THE SEASON: the invite from a week before Thanksgiving)

**Shipped.** Nothing yet. Branch `holiday/invite-thanksgiving`, five commits on build-50 (0b1899c), this entry included, not pushed. Apple TV needs an App Store build; the web tuner gets it when main is pushed, and Docker with the next `tuner-v*` tag.

**Why.** TIS THE SEASON's invite and guide lead ran in December only (`activeMonths: [12]`), so TURKEY DAY, its Thanksgiving channel, was never offered while Thanksgiving was coming. This answers the open question in the 2026-10-18 entry. Chad's call: the holiday invite shows from 7 days before US Thanksgiving.

**Changed.**
- `channels.json` v42. A bundle can carry `seasonStart: { "relativeTo": "usThanksgiving", "days": -7 }`. The bundle is then also in season from local midnight on that day to the end of that day's month, and then through its `activeMonths` as before. US Thanksgiving is the fourth Thursday of November, worked out each year in the device's time zone. TIS THE SEASON keeps `activeMonths: [12]` and gets the start, so it runs Nov 19 to Dec 31 in 2026 (Thanksgiving Nov 26), Nov 18 in 2027, Nov 16 in 2028. The start is never earlier than Nov 15 or later than Nov 21, so it never meets SCREAM's October. The end is unchanged: the last minute of Dec 31, out of season at midnight on Jan 1. An anchor a build does not know is ignored, and every other bundle, SCREAM included, has no `seasonStart` and is unchanged. Keeping `activeMonths: [12]` means a build that ignores the new key still offers the bundle in December.
- Apple TV: `SeasonStart` and `ChannelBundle.isInSeason` in `ChannelBundle.swift`. The season check is now Gregorian in the device's zone whatever calendar the device is set to, since `activeMonths` and Thanksgiving are Gregorian dates. `SeasonalPrompt.bundleToOffer`, `GuideChannelOrder.seasonalLeadIDs`, the new `SeasonalPrompt.headline` and `ChannelBundle.spotlightLabel` (the Settings note, moved out of the view) take an injectable calendar for tests. The library snapshot keeps `seasonStart`; a snapshot saved before this has no start, so that Apple TV offers the bundle from December until its next scan (within a day, or a RESCAN).
- Web tuner and Docker: new `scripts/nostalgex-season.js` holds the season check, the offer, the lead, the headline and the Settings note. `plex-tuner.html` calls it and keeps `seasonStart` when it parses `channels.json`; the note moved out of `nostalgex-library-load.js`. The web also takes two Apple TV rules it lacked, the September 15 gate (no bundle uses September) and the "<NAME> IS IN SEASON." fallback headline.
- Copy. The invite headline reads "IT'S DECEMBER. DECK THE CHANNELS." in December only; from the start to Nov 30 it reads "THE HOLIDAYS ARE HERE. DECK THE CHANNELS." Outside the season the Settings row reads "Spotlighted NOV 19 to DEC 31" (this year's start, which outside the season is the next one) instead of "Spotlighted DEC". CHANNELS.md: "Spotlighted from 7 days before US Thanksgiving (the fourth Thursday of November) through Dec."
- NOT THIS YEAR is still keyed on the calendar year, in both engines. The season sits inside one year, so a no on Nov 19 holds to Dec 31, and next season asks again from its own start (Nov 18 2027, not before). A no last December does not silence this November. DON'T ASK AGAIN is unchanged. A test fails if a shipped season ever wraps the year.
- New shared vectors `scripts/season-golden.json`, read by `SeasonGoldenTests.swift` and `npm run test:season`: US Thanksgiving and the holiday start for 2024 to 2035; 38 in-season cases (the minute before the start and the start for 2025 to 2030, the earliest and latest possible years, Thanksgiving, Nov 30, Dec 1, Dec 25, Dec 31 23:59, Jan 1, SCREAM's edges, and inline bundles for an unknown anchor, days 0 and +1 and the September gate); offers; guide leads; six answer sequences (22 steps); headlines; Settings notes. Times are local; both runners check every case in seven zones from UTC-11 to UTC+14, Apple TV also in the machine's own.

**Measured.**
- `npm run test:season`: 70 checks, 87 vectors and 22 answer steps in each of 7 zones, through the module and through `plex-tuner.html`'s own season section in a VM with a pinned clock and an in-memory localStorage. Negative controls in the runner: with the early start removed from the module, exactly the 12 November in-season vectors fail and nothing else; reading UTC instead of local time fails 76 across the zones.
- Swift: new `SeasonGoldenTests` (6 tests), 3 new `SeasonalBundleTests` and 5 new `SeasonalPromptTests`. Its committed control: the shipped bundles with the holiday start stripped fail exactly the 10 late November in-season, offer and lead vectors in every zone. Two more run by hand and reverted: with the early start removed from `isInSeason`, 9 of 30 seasonal tests fail (55 assertions); with the season read in UTC, 4 of the 6 golden tests fail (39 assertions). Full NostalgexTests, run serially: 819 tests, 0 failures, 12 skipped (the opt-in live harnesses), plus 32 Swift Testing tests.
- `npm test`, `npm run build` and `npm run build:selfhost` pass; both builds ship `nostalgex-season.js` and `channels.json` v42.
- The built web tuner in headless Chromium with a pinned clock, in Los Angeles and in Kiritimati: Oct 20 offers SCREAM; Nov 18 at 23:59 offers nothing; Nov 19 at 00:00 offers TIS THE SEASON with the November headline; Dec 25 shows the December headline; Jan 1 offers nothing and Settings reads "SPOTLIGHTED NOV 18 TO DEC 31"; with every package on, the guide leads with the holiday block from Nov 19 at 00:00 and not at 23:59 the night before; no page errors. No library was loaded; the check stops at the season logic.

**Unverified.** No Apple TV and no Roku were used; the Apple TV side is tests only. Not seen on a real guide with a library.

**Next.**
- The November headline is a placeholder for Chad's copy.
- Roku port. Its `NxSeasonalOffer` and `NxBundleInSeason` take a month (and year), so to match it needs the local day too: in season when the month is active, or when it is the start's month and the day is on or after the start's day. US Thanksgiving from `roDateTime` (Nov 1's `GetDayOfWeek`, then the fourth Thursday), plus `days`. The same check for the guide lead in `NxGuideOrder`, and `NxSeasonalHeadline` says December only in December. The per-year registry key (`seasonalDismissed_<id>_<year>`) works as is. Vendor `scripts/season-golden.json` next to the other vectors and add it to `run.sh`'s comparison; its zones don't matter to a runner that works in local date parts. Until then the port reads v42 and offers the holiday bundle in December, as before. Separately, `NxPoolChannelIds` still builds a seasonal bundle's pools only in season, which upstream stopped doing on 2026-10-16.
- Draft changelog line, not in `content/changelog.json`: "TIS THE SEASON shows up a week before US Thanksgiving now, in time for TURKEY DAY."

## 2026-10-20 (publish Apple TV channel surfing post)

**Shipped.** Nothing until this lands on main. Vercel then deploys `https://www.nostalgex.app/blog/apple-tv-channel-surfing-apps`.

**Why.** Chad's daily schedule, one post per morning. This one sat as a draft. The Oct 20 morning recheck found TubeTime+ had left TestFlight and landed on the App Store, so the reviewed copy was swapped in rather than flipping `draft: false` on the old Oct 9 competitor numbers.

**Changed.**
- `content/blog/apple-tv-channel-surfing-apps.md`: `draft: false`, `date` and `updated` both 2026-10-20. Competitor details rechecked on the vendors' own pages today: Coax and Bunny Ears prices and tvOS mins unchanged, TubeTime+ now on the App Store with Premium after 1 hour free, NostalgiaTV still not on Apple TV. Emby links and a tracked App Store link (`ct=blog_channel_surfing`) are in the copy. The HTML comment block of build notes stays in the Markdown because `scripts/build-blog.mjs` strips comments before rendering.
- `content/blog/jellyfin-tv-guide-own-library.md`: date and updated stay 2026-10-19. The last sentence of "Do I have to set up M3U, XMLTV or a tuner for this?" now links to the new post. The App Store link carries `ct=blog_jellyfin_guide`. The HTML build-notes comment marks that Oct 20 link as done.
- `npm run blog:render` wrote six live posts into `public/sitemap.xml`, including `/blog/apple-tv-channel-surfing-apps` with lastmod 2026-10-20. The blog block moved below the channels block, because the script always re-inserts it just before `</urlset>`. Images stay on R2. `scripts/media-sizes.json` already had the three R2 images for this post, so none were added.

**Half-done.** The other drafts are still drafts: `make-plex-feel-like-cable-tv`, `plex-virtual-channels-own-movies`.

**Next.** Nothing on this post. Indexing `/jellyfin` in Search Console is still Chad's, from the Jellyfin post's build notes. Oct 26, once `/blog/plex-virtual-channels-own-movies` is live: add the Plex Live TV link named in this post's build notes.

## 2026-10-19 (Emby: Dolby Vision profile 5 stays off channels)

**Shipped.** Nothing yet. Branch `jellyfin/playback-subs-dv`, not merged or pushed. Apple TV needs an App Store build; the web tuner gets it when main is pushed, and Docker with the next `tuner-v*` tag.

**Why.** On a real Apple TV 4K signed in to Chad's Emby 4.10.1.0, a Dolby Vision profile 5 MKV plays green and purple. The same file from Plex is right. The entry below found no request that makes Emby send profile 5 in a form the Apple TV or a browser draws right. Chad's call: when the server is Emby, profile 5 files go on no channel, in every app. Profile 8 stays (HDR10 base layer, not green on Apple TV). Plex and Jellyfin are unchanged.

**Changed.**
- How the profile is known. Emby names it in the video stream's `ExtendedVideoSubType`: `DoviProfile50` is profile 5, `DoviProfile81` 8.1, `DoviProfile76` 7.6 (the last digit is the base layer's compatibility id). Emby has no `DvProfile`; that is Jellyfin's field, and Jellyfin has no `ExtendedVideoSubType`. `VideoRange` and `ExtendedVideoType` only say Dolby Vision. The list call the scan already makes (`Fields=...MediaSources...`) carries it for films and episodes, so the scan asks for nothing new. Anything else (`Hdr10`, `None`, missing) is an unknown profile, and an unknown profile is kept.
- Apple TV: `EmbyAPIService.doviProfile(extendedVideoSubType:)` fills `doviProfile` on Emby films and episodes (the shared `JellyfinItem` decodes the one new field; Jellyfin's parse is untouched and never sets it). Only the Plex path reads `doviProfile` for playback, so nothing else changes. `ChannelEligibility.isLeftOffChannels` (Emby and profile 5) is applied wherever a pool is built from the library: stock channels (a flag in `makeFilterCache`, checked first in `filterItems`, with or without rules), found franchises (`rebuildFoundFranchises`) and server collections (`scanCollections`). The items stay in `allItems`, so library counts, enrichment and the snapshot are as before. One line per load: `[Plex90] CHANNELS: N Emby Dolby Vision profile 5 item(s) left off channels`.
- Web tuner and Docker: the same rule. `embyDoviProfile` in `scripts/nostalgex-jellyfin-urls.js` (point 11), `isLeftOffChannels` and `onChannels` in `scripts/nostalgex-channel-filter.cjs`, checked first in `itemPasses`. The page passes `mediaBackend` to the pool build, to a channel with no rules and to the collection index. One line per scan: `[Emby] CHANNELS: N Dolby Vision profile 5 item(s) left off channels`.
- `scripts/filter-golden.json` items can carry `backend` and `doviProfile`. Seven new cases: an Emby profile 5 film and episode on no channel, and on their channels an Emby profile 8 film and episode, an Emby film with no profile, and Jellyfin and Plex profile 5 films. Both runners read the new fields.
- Support page: a FAQ entry, "Why is a Dolby Vision movie missing from my channels on Emby?", and its JSON-LD.
- New opt-in `EmbyDolbyVisionLiveHarness`, skipped unless pointed at a server.

**Measured.**
- Field names, lab Emby 4.10.1.0: DV5 MKV and `dvh1` MP4 `ExtendedVideoSubType: DoviProfile50` ("Profile 5.0"), DV8.1 MKV and MP4 `DoviProfile81`, DV7 `DoviProfile76`, HDR10 and HDR10+ `Hdr10`, SDR `None`, on the item and on the scan's own list call, films and episodes alike. Lab Jellyfin 12.2.0 sends `DvProfile: 5` and `VideoRangeType: DOVI` for the same file, and no `ExtendedVideoSubType`.
- Lab: the NX Playback Lab clips run under a minute, and both scans drop anything under a minute, so two new libraries hold 75 s stream-copy loops of them with Comedy and Action genres: "NX DV Channels" (DV5 MKV, DV5 MP4, DV8.1 MKV, DV8.1 MP4, HDR10, SDR) and "NX DV Shows" (one show, episodes DV5 MKV, DV5 MP4, DV8.1, HDR10, SDR). ffprobe sees the profile 5 and 8 configuration in every DV loop. Through each client's real scan and pool build (Apple TV: `EmbyAPIService.loadLibrary` and `rebuildStaticChannelPools` in the harness; web: the page itself in headless Chrome, served from the worktree): before, both DV5 films were on channels 14, 16, 17, 41 and 54 in both clients. After, all four DV5 files (two films, two episodes) are on no channel in both. DV8.1 films stay on 14, 16, 17, 41 and 54, the DV8.1 episode on 54 (the web also builds 18, 31 and 40, under their minimum), HDR10 and SDR as before, and the library count is unchanged (24 items, then 29 with the show). Control in the same runs: the same scanned items built as if from Jellyfin put the DV5 files back on 5 channels (films) and 1 to 4 (episodes). The web logged `[Emby] CHANNELS: 4 Dolby Vision profile 5 item(s) left off channels`.
- Scan time: the request is unchanged (the smoke asserts the Fields list). Lab medians of 5 scans: Apple TV 0.019 s before, 0.025 s after (runs 0.017 to 0.050 s before and 0.018 to 0.044 s after, so noise); web scan and build 905 ms before, 908 ms after. At 10,000 items (the lab's list answer repeated): Swift decode 157 ms before, 162 ms after with the profile read and the rule (Mac, `-O`); on the web the profile read is 5 ms in all and the full stock pool build over 138 channels is no slower (6.3 s old filter, 5.8 s new, the profile 5 items now dropping out at the first check).
- Tests. Swift: new `EmbyDolbyVisionChannelTests`, 8 tests: Emby's field, the scan's parse on JSON shaped like Emby's (and Jellyfin's, unchanged), the rule, stock pools for films and episodes (Emby DV5 on no channel; Emby 8, 7, unknown, Jellyfin 5 on the same channels as the same file from Plex, which must reach some), a channel with no rules, a found franchise and a server collection. `FilterGoldenTests` runs the 7 new cases. Web: new `npm run test:emby-dolby-vision`, 20 checks, runs the page's own scan, `filterItems` and `refreshCollectionChannels` against a fake server with Emby's and Jellyfin's fields; filter golden 53 cases. Negative controls: with the rule switched off behind the same API, 5 of the 9 Swift tests fail (15 assertions) and the parse tests pass; with Emby's field not read, the 2 parse tests fail and the rule tests pass. The web checks against the page, filter and module from before this change: 9 fail (every left-off check, the profile read, the log line), 11 pass (every keep check and control). Full NostalgexTests run serially: 803 tests, 0 failures, 12 skipped (the opt-in live harnesses, the new one included). `npm test`, `npm run build` and `npm run build:selfhost` pass, and both builds carry the change.

**Unverified.** No Apple TV and no Roku were used. On a real Apple TV with Chad's Emby: the profile 5 file off every channel, profile 8 files still fine. An Emby library restored from the last scan (the Apple TV snapshot, the web's saved library) keeps that scan's channels until the next scan, up to a day or a RESCAN, because the old scan never read the profile. An item with several versions is judged by the version the app plays (highest bitrate). Emby other than 4.10.1.0 is not checked for the field.

**Trade-off.** A profile 5 MP4 is left out too. It direct plays on Apple TV, but a browser gets Emby's re-encode with no tone mapping, and the rule is the same in every app.

**Next.**
- The Roku port scans Emby too. To match: read `ExtendedVideoSubType` off the video stream in `NxMbMediaInfo` (no new Fields) and put `doviProfile` on films and episodes; leave Emby profile 5 out in `NxItemPasses` (and a channel with no rules), and out of the franchise and collection sources; log the count once per load; teach its golden runner `backend` and `doviProfile`, since it reads this `filter-golden.json` unchanged and the 7 new cases fail until then.
- Draft changelog line, not yet in `content/changelog.json`: "On Emby, Dolby Vision profile 5 files stay off your channels. Emby can't send them in a form the Apple TV or a browser shows right."

## 2026-10-19 (Jellyfin and Emby: only forced subtitles burned in, Dolby Vision 5 signalled on Jellyfin)

**Shipped.** Nothing yet. Branch `jellyfin/playback-subs-dv`, not merged or pushed. Apple TV needs an App Store build; the web tuner gets it when main is pushed, and Docker with the next `tuner-v*` tag.

**Why.** Two reports. The Roku port's author saw Jellyfin answer PlaybackInfo for two MKVs with `SubtitleMethod=Encode`, a full video re-encode to burn subtitles in, and pointed out that our Apple TV body sends no `SubtitleProfiles` either. A Discord user who runs Jellyfin and Emby says Dolby Vision files show "a green tint on the channels". We don't know yet whether he watches on Apple TV, in a browser or through Docker.

**Changed.**
- Apple TV, Jellyfin and Emby (`JellyfinPlaybackResolver`): PlaybackInfo sends `SubtitleStreamIndex: -1` and lists every subtitle format as `External`, so no subtitle goes into the picture. One exception, Chad's choice (option B): a track flagged forced, in the viewer's subtitle language, is burned in. That is the app's own rule for subtitles the viewer has not turned on (`AppState.pickForcedLegibleOption`), and burning is the only way such a track reaches the screen from these servers. The tracks are known only from the first PlaybackInfo answer, so when it lists one, a second PlaybackInfo names that track with every format as `Encode`; if that fails, the first answer plays. A track flagged only default is never burned. Languages are compared through `SubtitleSelectionLogic.sameLanguage`, which reads "eng", "en", "ger" and "deu" alike. The HEVC codec profile names the dynamic ranges Apple TV shows (`VideoRangeType` SDR, HDR10, HLG, DOVI, DOVIWithHDR10, DOVIWithHLG, DOVIWithSDR; not DOVIWithEL).
- Web tuner and Docker: the same rule, from `scripts/nostalgex-jellyfin-urls.js` (points 8 to 10), in one request because the tuner already has the item's tracks from the library. The tuner's own WebVTT skips a track already burned in, and the picker takes only text tracks.
- Nothing for Dolby Vision in the web tuner, and nothing that changes Emby's Dolby Vision answer: no request we tried does.

**Measured.** Lab Jellyfin 12.2.0 (account subtitle mode Default, tone mapping off, no hardware acceleration) and Emby 4.10.1.0 (mode Smart, tone mapping off) on this Mac. A new "NX Playback Lab" library on each holds 21 short clips, cut by stream copy from files in Chad's Plex (the SRT written here, the HDR10 clip is the DV8.1 one with its RPU stripped, the untagged HEVC encoded here): SRT, ASS, PGS and VobSub tracks flagged default, forced or neither, a Blu-ray layout (PGS default, SRT, ASS, forced PGS), an MP4 with `mov_text`, an MP4 with a sidecar `.srt`, DV profile 5 (MKV and `dvh1` MP4), 8.1 (MKV and `hvc1` MP4), 7, HDR10, HDR10+ and an untagged 8-bit HEVC. Each client's exact request was replayed: the Apple TV body and stream URL came out of the Swift source itself, the web tuner's from running its page function. Then the playlists, init and first segment as a player fetches them, the server's own ffmpeg command, and the first video packets compared with the source.
- Subtitles, first pass (option A, nothing ever burned), before: Jellyfin burned every default or forced track, all four formats, into a libx264 re-encode, for both clients. Asked about the two MP4s, which should direct play, it answered with burn-in transcodes too. Apple TV asks PlaybackInfo about HEVC MP4s and on the retry after a failed direct play (H.264 MP4s direct play without asking); the web tuner asks about any MP4 whose audio a browser cannot play. Emby burned every forced track. No master playlist ever had a subtitle track, so the Apple TV subtitle toggle had nothing to pick on either server. After: all 13 subtitle files copy the video on both servers and both clients, and the MP4s direct play. Of 84 before and after pairs (21 files, two clients, two servers), 30 changed, every one a burn-in gone, a direct play back or Dolby Vision signalled; the other 54 are identical.
- Option B, the shipped rule, run as shipped: the app's own `negotiate` against the live servers, the web body from the page's own function with the item's tracks. Viewer language English, plus a new clip with a forced SRT tagged `ger` (Jellyfin 12.2.0 reports it as `deu`, Emby keeps `ger`). Forced English SRT, PGS and VobSub, and the Blu-ray layout's forced PGS: burned in on both servers and both clients (libx264 with an overlay or subtitles filter; on the Blu-ray layout the overlay reads stream 5, the forced PGS, not the default at 2). The German clip: copied for an English viewer, burned for a German one. Every default-only, unflagged, no-subtitle and MP4 case copies or direct plays exactly as in option A, and every non-subtitle file (Dolby Vision, HDR10, HDR10+, DV7, the untagged HEVC) is identical to option A. The app sends one PlaybackInfo for those and two for the forced files.
- Why `Encode`: asked for a forced track by index with the `External` profiles, both servers answered External and copied the video. With every format `Encode`, or with no profiles at all, both burned it in.
- `-1` needs a matching `MediaSourceId`: without one Jellyfin burned in as before, which may be the Roku case. With `-1` Jellyfin still writes `SubtitleMethod=Encode` on the URL; nothing is encoded. Hand-built HLS URLs (the 1080p rung, the fallback) never burned on either server.
- Tried and dropped: Jellyfin's HLS subtitle delivery. Selecting one text track lists all text tracks as HLS renditions, with DEFAULT and FORCED right, and AVPlayer offers them. But AVPlayer showed every cue 10 s late: the WebVTT says `X-TIMESTAMP-MAP=MPEGTS:900000`, which is where Jellyfin's MPEG-TS output starts (10.1 s), while its fMP4 output starts at 0.07 s. Emby has no HLS subtitles; asked for a text track it answered `External` or burned it.
- PGS and VobSub as WebVTT: Jellyfin 400, Emby an empty `WEBVTT`. On the Blu-ray layout the web tuner used to pick the English PGS over the English SRT and show nothing.
- Dolby Vision on Apple TV: both servers sent the DV5 MKV as plain `hvc1` with no `dvcC`, no colour information and the RPU still in every frame. AVFoundation reads that track as SDR. Drawn without the RPU, the frame is green and purple (yellow sign pink, red car purple). With the range list Jellyfin sends `dvh1` with a profile 5 `dvcC`, `CODECS="dvh1.05.06"`, `VIDEO-RANGE=PQ`, video still copied. That is what our Plex path gets from `dolbyVisionRemuxURL` (checked the same day on Chad's Plex: video copy, `dvh1`, profile 5 `dvcC`). AVFoundation reads the new track as HDR, and AVPlayer on the Mac plays it. DV8.1 gains its `dvvC` box. DV7, HDR10, HDR10+ and the untagged HEVC are unchanged. With the bitrate cap lifted, DV7 goes from copied with the RPU to copied with the RPU removed, plain HDR10. Emby ignores `VideoRangeType`, and every Emby answer is the same before and after. Emby never wrote `dvh1` or `dvcC` for any request tried (`VideoRange`, `ExtendedVideoType` and `ExtendedVideoSubType` conditions, `hevc-videorange`, `hevc-codectag=dvh1`). DV MP4s direct play on both.
- Dolby Vision in browsers: the tuner always gets H.264 for HEVC. Jellyfin 12.2.0 tone-maps in software (`tonemapx`, which applies the RPU) even with tone mapping off in its settings, and the colours are right. Emby 4.10.1.0 re-encodes with no tone mapping: DV5 green and purple, DV8.1 and HDR10 washed out. Headless Chrome and WebKit, playing the tuner's own request with its hls.js 1.5.17, showed the same. A throwaway second Emby with software tone mapping switched on gave byte-identical green frames. Apple TV HD (no HEVC, so H.264) matches the browser: right on Jellyfin, green on Emby.
- Swift: new tests in `JellyfinPlaybackInfoTests` for the body, the range list and the forced rule (forced, default only, none, another language, both ISO codes, the Blu-ray layout), and three that run both services' real negotiation against a fake server: forced (two requests, the burned stream plays), default only (one request), and a failed second request (the film plays without the burn). `SubtitleSelectionLogicTests` covers the language codes. The key-list test in `StallRetryServerStreamTests` now expects `SubtitleStreamIndex`. Full NostalgexTests run serially, rebased on main with the EAC3 cap: 794 tests, 0 failures, 11 skipped (the opt-in live harnesses). Negative controls behind the same API: with option A's behaviour (never burn) the 7 forced tests fail and the default-only, none and other-language ones pass; with main's behaviour 12 fail.
- Web: new `npm run test:jellyfin-subtitles`, 46 checks, runs the page's own `getJellyfinTranscodeUrl`, `langMatches` and `pickSubtitle` against a fake server, both backends, the same forced, default-only, none and language cases. Against main's page and module it fails 40 of 46; against option A's it fails 25, every forced case on `SubtitleStreamIndex -1`. `web-tune-ownership-smoke` expects the new key. `npm test`, `npm run build` and `npm run build:selfhost` pass, and both builds carry the change.

**Unverified.** No Apple TV and no Roku were used. A file a client plays without asking the server is not burned: on Apple TV an H.264 MP4, MOV or M4V (AVPlayer shows an embedded forced `mov_text` track by itself; a forced sidecar `.srt` beside such a file is not shown), in the tuner an MP4 or WebM the browser plays as it is. DV5 colour on a real Apple TV, before (expected green) and after (expected right), is not measured: the Mac's AVFoundation hands back the raw base layer even for a correct `dvh1` file, so it cannot judge. Not tested: Jellyfin other than 12.2.0 (DV tone mapping in 10.x depends on the version and the tone mapping setting), Emby with Premiere, hardware acceleration, Emby in subtitle mode Default, and the full web tuner page in a browser against these files.

**Trade-off.** A forced track in the viewer's language costs a full video re-encode for that file, as before, and shows in the guide preview too, as forced lines do in the app's own rule. Default-flagged subtitles that the servers used to burn in no longer appear on Apple TV; the app had no other way to show them on these servers, and they could not be turned off. The web tuner still shows text subtitles itself, in full screen.

**Next.**
- Ask the Discord user which client, which server and version, and which DV profile and container.
- On a real Apple TV: DV5 MKV from Jellyfin on this branch, and from Emby.
- Subtitles on Apple TV for Jellyfin and Emby need the app to draw a fetched WebVTT itself, as the web tuner does, or Jellyfin to fix the fMP4 time map.
- Emby DV5: no client fix. Emby tone mapping (possibly Premiere, untested) for browsers, or DV5 in MP4, which direct plays on Apple TV.
- The Roku port: `SubtitleStreamIndex: -1` with a matching `MediaSourceId`, and `External` subtitle profiles; for a forced track in the viewer's language, its index with `Encode` profiles.
- Draft changelog line, not yet in `content/changelog.json`: "Jellyfin and Emby no longer burn subtitles into the picture unless they are forced subtitles in your language, and Dolby Vision profile 5 plays as Dolby Vision from Jellyfin on Apple TV."

## 2026-10-19 (Apple TV: RATE opens the Nostalgex page)

**Shipped.** On main, for the next Apple TV build.

**Why.** RATE (Settings and the rating nudge) opened the App Store but not the Nostalgex page, so rating took a search. All four App Store link forms land on the page when handed to the App Store directly, so the address was fine; an `https` link opened from inside the app is what lost it.

**Changed.** `AppStoreLink.productPage` is `itms-apps://apps.apple.com/app/id6762563534`, which goes straight to the App Store with the address.

**Measured.** On a real Apple TV 4K: RATE in Settings now lands on the Nostalgex page.

## 2026-10-19 (Jellyfin Quick Connect starts with a POST)

**Shipped.** Nothing yet. Branch `jellyfin/quick-connect-post`, not merged or pushed. Apple TV needs an App Store build; the web tuner gets it when main is pushed, and Docker with the next `tuner-v*` tag.

**Why.** Quick Connect could not start on Jellyfin 12 from either client. Both sent `GET /QuickConnect/Initiate`. Jellyfin 12.2.0 answers that with 405 and an empty body, and answers `POST` with 200 and the code and secret. So the web tuner and the Docker image said QUICK CONNECT IS NOT ENABLED ON THIS SERVER with Quick Connect on, and Apple TV said "Could not start Quick Connect". Reported by the Roku port's author, who also confirmed the poll (`GET /QuickConnect/Connect`) and `POST /Users/AuthenticateWithQuickConnect` work as we have them. Jellyfin's own history, from `Jellyfin.Api/Controllers/QuickConnectController.cs` at each release tag: 10.7.7, 10.8.8 and 10.8.13 route Initiate as GET only. 10.9.0 made it POST and kept GET as an obsolete route (commit 722ad3f, "Change InitiateQuickConnect to use POST request"), and 10.9.0 through 10.11.11 answer both. 12.0 removed the GET ("Remove some deprecated API members", 874fd9a); 12.0-rc1, 12.0 and 12.2 are POST only.

**Changed.**
- Apple TV: `JellyfinAPIService.quickConnectInitiate` sends POST. Only when that gets 405 or 404 does it send the same request again as GET, so 10.7 and 10.8 keep working. A 401 (Quick Connect off), any other error and a network failure are not retried. Two 404s still read as "that address isn't Jellyfin", so sign-in moves on to the next address as before. How the request is sent is now a parameter, so tests can record it; the app passes the same session as before.
- Web tuner and Docker: the same rule, as `quickConnectInitiate` in `scripts/nostalgex-jellyfin-urls.js` (point 7), which `web-tuner.html` already loads. It hands back the server's response, so the page's checks and messages are unchanged.
- Every other Quick Connect call is unchanged.
- Looked for the same problem elsewhere. Every other Jellyfin method and path either client uses is in Jellyfin's 12.2 source with the method we send, and the lab server routes each one (a PUT to the same path is 405, ours is not). The legacy `/Users/{id}/...` watch-state routes (`Items/{id}`, `PlayedItems/{id}`, `Items/{id}/UserData`) are still there in 12.2, left out of its OpenAPI document. The other endpoints the 12.0 cleanup removed are ones neither client calls.

**Measured.** Lab Jellyfin 12.2.0 on this Mac, Quick Connect on: GET Initiate 405, POST 200 with a 6 digit code and a 64 character secret. Without the MediaBrowser header the POST is 400; both clients send it.
- Swift: new `JellyfinQuickConnectTests`, 7 tests, pass, and `QuickConnectFailureMessageTests` (4) still pass. With the old GET-only request put back behind the same seam, all 7 fail. `JellyfinQuickConnectLiveHarness` (skipped unless pointed at a server) runs the app's own initiate, poll and authenticate: code issued, poll false, code approved, poll true, signed in as the right user, and the new token lists the libraries. With the old request it fails on HTTP 405. Full NostalgexTests run serially: 805 tests, 794 passed, 0 failed, 11 skipped (the opt-in live harnesses, this one included). In a parallel run one wall-clock harness, `TelemetryVolumeHarness` timing the five second skip loop, read 6.5 s against 5 plus or minus 1 on a busy machine; it passes 3 of 3 on its own.
- Web: new `npm run test:jellyfin-quick-connect`, 24 checks. The module, then `web-tuner.html`'s own Jellyfin section in a VM against fake servers with the 12.x, 10.9 to 10.11, and 10.7 and 10.8 route tables, plus Quick Connect off, an unreachable server and a server that isn't Jellyfin. The old GET-only call is run through the same checks as negative controls. Against main's page and module the file fails 20 of 24. With a server set in the environment it also signs in for real through the page's code: POST Initiate 200, poll, `AuthenticateWithQuickConnect` 200, saved as Jellyfin, `/UserViews` 200 with the new token. The built Docker files in headless Chrome: Quick Connect lands on the tuner signed in; the same files with the old call put back show QUICK CONNECT IS NOT ENABLED ON THIS SERVER after a GET 405.
- `npm test`, `npm run build` and `npm run build:selfhost` pass.

**Unverified.** No Apple TV, no Roku and no Jellyfin 10.x server were used. The GET fallback for 10.7 and 10.8 is covered only by tests: whether 10.8 answers a POST with 405 or 404 was not measured, and both get the GET. Codes were approved with the lab's admin API key, standing in for the person in the Jellyfin dashboard.

**Next.**
- Which build carries this is Chad's call. Draft changelog line, not yet in `content/changelog.json`: "Jellyfin Quick Connect works on Jellyfin 12."
- The Roku port should start Quick Connect with POST too.

## 2026-10-19 (publish Jellyfin TV guide post)

**Shipped.** Nothing until this lands on main. Vercel then deploys `https://www.nostalgex.app/blog/jellyfin-tv-guide-own-library`.

**Why.** Chad's daily schedule, one post per morning. This one sat as a draft dated 2026-10-14.

**Changed.** Front matter only: `draft: false`, `date` and `updated` both 2026-10-19. Article copy is unchanged. The HTML comment block of build notes at the end stays in the Markdown because `scripts/build-blog.mjs` runs `stripHtmlComments` before rendering, so those notes never reach the public HTML. No links added to `/blog/apple-tv-channel-surfing-apps` or `/blog/make-plex-feel-like-cable-tv`; those pages are still drafts. The live links already in the post (`/`, `/jellyfin`, `/web-tuner`, `/blog/tunarr-ersatztv-alternative-apple-tv`) stay as they were. `npm run blog:render` writes the new URL into `public/sitemap.xml`; there is no RSS/Atom feed. Images stay on R2.

**Half-done.** The other drafts are still drafts: `apple-tv-channel-surfing-apps`, `make-plex-feel-like-cable-tv`, `plex-virtual-channels-own-movies`.

**Next.** Nothing on this post. Indexing `/jellyfin` in Search Console is Chad's, from the build notes.

## 2026-10-18 (TOON TOWN: no more Middle-earth)

**Shipped.** Nothing yet. Branch `channels/toon-town-gate`: the web gets it when main is pushed, Apple TV with the next build, Docker with the next `tuner-v*` tag.

**Why.** TOON TOWN was airing The Hobbit. The channel is for live action and cartoon hybrids, and its only test was the TMDB keyword "live action and animation", which TMDB also puts on all three Hobbit films and all three Lord of the Rings films (CGI and motion capture).

**Changed.** `channels.json` v39: TOON TOWN counts the keyword only on a title that is also Animation, Family or Comedy (`keywordsRequireAnyGenre`, already in both engines). Comedy is in the list because the 2002 Scooby-Doo and Detective Pikachu are real hybrids with neither Animation nor Family in Plex. Three new cases in `scripts/filter-golden.json`.

**Measured.** Against the 113 movies in the shared metadata cache with that keyword: 100 still qualify, the 6 Middle-earth films, Okja and a few others drop out, and the two R-rated titles Comedy lets back in are already stopped by the channel's G to PG-13 rule. On one real library, 45 films carry the keyword: the 6 Middle-earth films drop, the rest stay. Both engines pass all 46 golden cases; with the gate removed the Hobbit case fails.

## 2026-10-18 (Apple TV: retro mode is stronger, and on in full screen)

**Shipped.** Nothing yet. Branch `retro/medium`, for the next build.

**Why.** Retro mode read as too subtle. Full screen had no scanlines at all (the old comment called them too distracting), so in full screen retro mode was the crop, the vignette and a tracking line now and then.

**Changed.** Three looks were tried side by side on a TV and the middle one won. Scanlines at 0.18 (were 0.12), in the guide and now in full screen too. A darker vignette: corners 0.78, top and bottom 0.58, sides 0.48 (were 0.7, 0.5, 0.4). Flicker on 8% of the 80 ms ticks, dipping to 0.76 to 0.88 (was 5%, 0.80 to 0.90). The tracking line on 45% of its checks at 0.22 brightness (was 30%, 0.15). The numbers live in `RetroLook` in `CRTOverlayView.swift`, so the Roku port can match them. The web tuner's retro mode is its own effect and is unchanged.

**Measured.** Unit tests pass. Checked by eye on an Apple TV 4K, in the guide and in full screen.

## 2026-10-18 (Plex: Blu-ray DD+ 7.1 plays on Apple TV)

**Shipped.** On main, for the next Apple TV build.

**Why.** Some films never played on Apple TV: The Wild Robot, Bob Marley: One Love, and about ten more in one library. Plex's decision looked fine (video copied, "EAC3 7.1" copied, MPEG-TS), the TV read about a megabyte and hung up, and the server never refused anything. These are Blu-ray "DD+ 7.1" tracks: every audio frame is an AC-3 5.1 core followed by an E-AC-3 extension frame, labelled E-AC-3 but never a plain E-AC-3 frame. AVPlayer on tvOS rejects that (CoreMedia -12979) within about two seconds. The Mac's player plays it on the core, so a Mac-only check misses it. True E-AC-3 7.1 and Plex's own 7.1 encodes play, so eight channels is not the problem.

**Changed.** Both Plex client profiles (the everyday one and the Dolby Vision remux) cap EAC3 at 6 channels: `add-limitation(scope=videoAudioCodec&scopeName=eac3&type=upperBound&name=audio.channels&value=6)`. Plex then re-encodes only that audio to AC-3 5.1 and still copies the video. The scope has to be `videoAudioCodec`; `audioCodec` is silently ignored. EAC3 5.1 is still copied as before. The cost: a title that reached the TV as 7.1 now arrives as 5.1.

**Measured.** The app's exact request reproduced against the real server: the affected titles fail with -12979 in a tvOS 26.1 simulator, EAC3 5.1 controls play in under a second, and with the cap all affected titles play (ready in 0.5 to 2.4 s). Unit test pins the cap and its scope in both profiles. On a real Apple TV 4K (living room, 2026-10-19), the app's own playback soak over 15 EAC3 titles (12 with the AC-3 core, 3 controls): before the cap 5 of 15 played (10 of the 12 failed, the 3 controls and 2 of the 12 played); with the cap 15 of 15 played, first picture in 1.5 to 3.2 s, each held 15 s with no stalls.

Also found: a file whose audio track runs far past its video (one film: 97 min of picture, 219 min of audio, the rest digital silence) gets a slot the length of the audio, so most of its airing is a frozen frame. That one is the file, fixed by remuxing it; the app has no check yet for a clock that moves with no new frames.

## 2026-10-18 (TIS THE SEASON: Christmas episodes, MISTLETOE, TURKEY DAY)

**Shipped.** Nothing yet. Branch `channels/holiday-season`, six commits on 680b99a, not pushed. Apple TV needs an App Store build; the web gets it when main is pushed, Docker with the next `tuner-v*` tag.

**Why.** An audit of the bundle against a test library (1,787 films, 8,770 episodes, 1,127 music videos, with the shared TMDB enrichment attached) found it thin and in places wrong:
- The two TV channels never aired an animated show. Episode titles did not open the Animation lock the way a title list does, so the Christmas episodes of Bluey, The Simpsons, Family Guy, Animaniacs and Darkwing Duck aired nowhere.
- Episode titles alone missed most Christmas episodes and let a few wrong ones in. Friends has five in the test library and two say so in the title. "Roman Holiday" (Emily in Paris, a trip to Rome), Full House "Jingle Hell" (an advertising jingle) and "Stuck in a Merry Scary" (Halloween) were on the holiday channels.
- HALLMARK matched the shared 114 title list plus a runtime shape. It found 7 films and missed anything not on the list, The Princess Switch trilogy among them. The name was also a real network's.
- The holiday lock read show names and song titles as well as film titles, so a show with Santa in its name and any Christmas song on a music video were locked to movie channels that can never air them, and aired nowhere. Its words were not 95% Christmas either (below).
- Rocky IV was on SANTA'S LIST. HOLIDAZE missed Home Alone 2, which Plex titles "Home Alone 2: Lost in New York", and the one Hanukkah film, Eight Crazy Nights, was on no holiday channel.

**Changed.**
- Episode rules, both engines (`AppState+Channels.swift`, `nostalgex-channel-filter.cjs`). They read an item's own title: the episode title for an episode, the title for a film, so a half hour special stored as a film matches like an episode. Beside `episodeTitleContains` there is now `episodeSummaryContains`, `episodeSeasonalTitleContains` with `episodeAirWindow` (a word that only counts for an episode first aired inside the window, which wraps the new year), and `episodeTitleExcludes`. An episode-curated channel opens the Animation lock, nothing else widens it, and a manifest claim cannot get past it. The web now skips the content block for these channels as Swift did.
- The web tuner gives episodes `originallyAvailableAt` (episode, else show) on Plex, Jellyfin and Emby, which Apple TV already had.
- `matchTmdbGenres`: a channel's genre tests also read the item's TMDB genres. A Plex listing carries two genres per film; The Princess Switch reads "Comedy, Family" on Plex and "Romance, Comedy" on TMDB. Lock genre tests stay on the server's genres.
- Exclusive rules take an optional `type` and `source`. The holiday lock is films in a movie library only, and now names the two TV channels so specials stored as films can air there.
- TIS THE SEASON is eight channels and moves as one block to CH145 to 152, after SCREAM, because 137 is SCREAM's and a bundle has to be one unbroken run (ChannelNumberingTests). Ids did not change, so per-channel settings carry over. The bundle has never been in season.
  - CH149 MISTLETOE (id 412, was HALLMARK): cozy Christmas romances. A holiday word in the title or a Christmas TMDB keyword (christmas, christmas romance, christmastime, christmas eve and a few more; never bare "holiday", which TMDB uses for vacations), then Romance on Plex or TMDB, rated G to TV-PG or NR, 1980 on, 70 to 120 minutes, no animation.
  - CH150 CHRISTMAS SPECIALS and CH151 KIDS CHRISTMAS TV: strong title words (Christmas, Xmas, Hanukkah, Chrismukkah, Festivus, Santa Claus, Secret Santa, Krampus, Nativity, Deck the Halls and others), seasonal words (Holiday, Santa, Merry, Jingle, Noel, Grinch, Scrooge, Snowman, Elf) only for an episode aired Nov 25 to Jan 7, Christmas words in the summary, place name excludes (Santa Monica, Santa Fe, Christmas Island and more), and 65 minutes or less. Ratings split as before; Not Rated goes to CHRISTMAS SPECIALS, so A Charlie Brown Christmas has a TV home. Minimum 5 items.
  - CH152 TURKEY DAY (id 422): Thanksgiving episodes. Thanksgiving, Friendsgiving or Slapsgiving in the title or Thanksgiving in the summary; Turkey, Pilgrim and Gobble count in November only. Minimum 5.
- The holiday lock's title words are the ones that measured 95% or more Christmas across TMDB films with 25 or more votes: Christmas 98.8%, Xmas, Mistletoe, Noel, Rudolph, Frosty, Jingle, Hanukkah, Yuletide, Winter Wonderland. Off it: Holiday 66% (Mr. Bean's Holiday, Roman Holiday), Santa 87% (Santa Sangre, Santa Fe Trail), Grinch 60% (Halloween Is Grinch Night), Merry 80%, Snowman 80%, Scrooge, Nutcracker and Reindeer (Reindeer Games, freed like Die Hard). Santa Claus, Santa Clause and Holiday Special are lock phrases, and five films that lost their word are exact titles. Rocky IV, Gremlins, Batman Returns, Trading Places, The Family Man, While You Were Sleeping and The Shop Around the Corner are no longer locked; HOLIDAZE keeps them as editorial picks. The channels still match the dropped words; only the lock stopped hiding them.
- Smaller: Home Alone 2's full title and Eight Crazy Nights on HOLIDAZE, Eight Crazy Nights on the shared title list, Roman Holiday, Mr. Bean's Holiday and Summer Holiday excluded from the holiday movie channels, Rocky IV off the shared title list.
- 30 new golden cases in `scripts/filter-golden.json` (73 in all), positive and negative. CHANNELS.md renders the new rules and bundles split across blocks. The bundle page names the two new channels.

**Measured.** On the test library through the web filter, before and after: HOLIDAZE 42 to 44, SANTA'S LIST 39 to 38, NAUGHTY LIST 17 to 18, NOSTALGEX CHRISTMAS 16 to 15, HALLMARK 7 to MISTLETOE 11, CHRISTMAS SPECIALS 29 to 75 (Friends 5, Family Guy 10, Home Improvement 8, The O.C.'s three Chrismukkahs, Simpsons Roasting on an Open Fire, A Charlie Brown Christmas), KIDS CHRISTMAS TV 23 to 55 (Bluey, Animaniacs, Darkwing Duck, the 1966 Grinch, Mickey's Christmas Carol), TURKEY DAY 69 (all nine Friends Thanksgivings). Every other channel is unchanged except what the lock freed: Reindeer Games, Rocky IV and While You Were Sleeping are back on 13 year-round channels. Read by hand, the summary path lets in a few borderline episodes (a Big Bang Theory birthday episode with a Christmas letter subplot, a New Year's Eve How I Met Your Mother); SNL and Whose Line, which mention Christmas in sketch lists, stay out because the News and Reality locks keep them off. The same 11,684 items run through `AppState.filterItems` in a throwaway XCTest: 138 of 139 channels identical item for item to the web filter, all eight holiday channels identical; the one difference is ANIMATION, where the web counts Plex's studio as a production company and Swift does not (existing, not touched here). MISTLETOE against 2,085 TMDB Christmas films since 1990: 900 pass, 761 of them TV movies, 23 more from TV movie companies, most of the rest streaming rom-coms; 784 of 799 Christmas TV movie romances pass (98%). NostalgexTests: 768 tests, 758 passed, 0 failed, 10 skipped (opt-in live harnesses), plus 32 Swift Testing tests. `npm test`, `npm run build` and `npm run build:selfhost` pass. Golden negative control: 21 of the first 29 new cases fail on the v38 engine and config.

**Unverified.** Nothing ran on an Apple TV or in a browser against a real server; the web loader change was checked by syntax and the filter by tests. No Jellyfin or Emby library was used, so the air dates from PremiereDate are unmeasured. The test library has no Christmas music videos and no classic Hollywood Christmas films. An episode with no air date of its own takes the show's, as Apple TV already did, so an undated episode of a show that premiered in December counts as in season.

**Next.**
- Whether to spotlight TIS THE SEASON from November (`activeMonths: [11, 12]`), so TURKEY DAY is offered while it is in season. Left at December; `SeasonalBundleTests` pins it.
- Draft changelog bullets, not in `content/changelog.json`: "TIS THE SEASON is eight channels. MISTLETOE is the cozy made for TV Christmas romance, and TURKEY DAY plays every Thanksgiving episode you own." / "CHRISTMAS SPECIALS and KIDS CHRISTMAS TV find the Christmas episodes of your shows by title, summary and air date, cartoons included, plus half hour specials like A Charlie Brown Christmas." / "Films that are only set at Christmas, like Reindeer Games and Rocky IV, are back on their other channels, and a show with Santa in its name is no longer hidden." / "The holiday channels are now 145 to 152, right after SCREAM."
- Roku port: own-title episode rules, the three new episode keys and the air window (episodes need `originallyAvailableAt`), the Animation lock for episode-curated channels, the episode gate on manifest claims, `matchTmdbGenres`, and lock `type`/`source`.
- The SCREAM lock could take the same `type`/`source` scope, so a song titled exactly "Scream" stays on HIGH ROTATION.
- OSCAR WINNERS matches "Rocky" as a word, so every Rocky sequel qualifies; Rocky IV now shows it.

## 2026-10-16 (blog screenshot sizes)

**Shipped.** Nothing until this lands on main. The live pages pick it up on the next Vercel deploy.

**Why.** Ten in-post screenshots on the media bucket are full 1280x720 frames now. `scripts/media-sizes.json` still had the old crop heights (412 for the grid crops, 565 for the guide crops, 560 for one TEEN MOVIES frame). The blog build stamps those numbers onto `<img width>` and `<img height>`, so a stale cache would reserve a short box and then jump when the file loaded.

**Changed.** Those ten records now say height 720. Widths left at 1280. No keys were missing. Covers stay 1200x630. No image files added; the files on the bucket already measure 1280x720 (checked four of the ten by Range request). `node scripts/build-blog.mjs` re-ran: four live posts and four drafts all render `width="1280" height="720"` on those figures. The sitemap blog block moved below the channels block, because the script always re-inserts it just before `</urlset>`. URLs and lastmod dates are unchanged.

**Half-done.** Six of the ten images live in draft posts (`apple-tv-channel-surfing-apps`, `jellyfin-tv-guide-own-library`, `make-plex-feel-like-cable-tv`, `plex-virtual-channels-own-movies`). They take the new sizes when those posts publish.

**Next.** Nothing. The other six remote files were not re-fetched this session.

## 2026-10-16 (web tuner: sleep timer, playback information, and Emby as its own choice)

**Shipped.** On nostalgex.app and in the Docker image `tuner-v1.0.1`, merged from branch `web/sleep-info-emby`. The tvOS app is untouched.

**Why.** Three Apple TV features the web tuner and the Docker image did not have. And Emby in the browser never worked: the connect page said Emby "connects through the Jellyfin option", but that path asked Emby for `/UserViews`, which is Jellyfin's spelling. Measured on Emby 4.8.11.0, 4.9.5.0 and 4.10.1.0: 404 on all three, so the library load failed the moment it started.

**Changed.**
- Sleep timer, matching tvOS: OFF, 15 MIN, 30 MIN, 1 HR. SLEEP in the rail and SLEEP TIMER in the phone drawer open a small picker; Settings > PLAYBACK has the same choices inline. The time left shows on the rail and drawer. At zero, "STILL WATCHING?" with a 20 second countdown; any click, tap or key keeps watching (the key is taken before the shortcuts, so it never changes channel). Left alone, it does what tvOS does: reports the stop, stops the video, ends the server's stream, leaves full screen, shows the guide. The web adds one line on the picture ("Pick a channel to start watching again.") because a stopped video in a browser has nothing else to explain it, and picking the same channel in the guide starts it again. A library refresh never restarts it. The timer survives channel changes and a reload turns it off. Logic in `scripts/nostalgex-sleep-timer.js`.
- Playback information, matching the tvOS panel from PR #26. INFO in the rail, sharing a row with SLEEP, the I key, PLAYBACK INFO in the phone drawer, and a row at the bottom of Settings > PLAYBACK (VIEW). Nothing in full screen, which is the browser's own. A ninth full-width rail button pushed Instagram out of sight at most desktop and TV sizes, so SLEEP and INFO are half-width side by side; the countdown is capped at 59:59 so it fits, and the short-window steps start at 892px and 779px instead of 760px and 700px, because 1280x800 already ran 43px over and 1440x760 7px with eight controls. Measured at 13 desktop sizes from 1920x1080 to 1366x700, 960x540, iPad both ways and iPhone: nothing clipped, no rail scroll. Same rows and sentences: BACKEND, PLAYBACK (Direct Play / Server stream / Loading), QUALITY AT TUNE (what the browser asked for: Server default on Plex, Up to 120 Mbps on Jellyfin and Emby; the web tuner has no quality setting), PLAYER SIZE from the video element, SOURCE METADATA from allowlisted codec names, FALLBACK in plain words (server stream chosen, direct play failed, or an hls.js retry). RECOVERY REQUEST never shows on the web: there is no 1080p rung. It holds no URL, token, address, session or item id. Each programme has a generation and each try an attempt; only the current one can mark it ready. Building the tuner-level test found that the panel said "No fallback used." while a server stream was still being negotiated after a failed direct play; the attempt now starts at the decision, as on tvOS. Plex items keep `videoCodec` and `audioCodec` from the scan so the panel can name them; Plex's direct play choice still goes by container.
- Connect with Emby on the connect page, with its own form (no Quick Connect, Emby has none), Emby wording in errors and EMBY SERVER in Settings > SERVER. What differs from Jellyfin mirrors `EmbyAPIService.swift`: libraries from `/Users/{id}/Views`; after a failed direct play PlaybackInfo is asked with `EnableDirectPlay` and `EnableDirectStream` both false (Emby 4.10.1.0 offers the same MP4 again with only the first off, measured); the server name comes from `/System/Info/Public` because Emby's sign-in result has no `User.ServerName`. Header, sign-in body, `/Items`, static stream, subtitle VTT, watch state and the encode stop are shared, and were measured to work on Emby. Subtitles and audio language now run for Emby too (an external `.srt` came back as WebVTT).
- Emby users saved as `jellyfin` from before are migrated, not asked to sign in again: start-up reads `/System/Info/Public` (Jellyfin says `ProductName: "Jellyfin Server"`; Emby has no ProductName and lists `LocalAddresses`) and switches the saved sign-in to `emby`. If that can't be read, a 404 on `/UserViews` then a 200 on `/Users/{id}/Views` does the same. Sign-in runs the same check, so either button lands on the right backend. Still one backend at a time.
- Jellyfin is unchanged: same `/UserViews`, same PlaybackInfo body, Quick Connect, same error text except one em dash replaced with a full stop. Docs: WEB-TUNER-FEATURES.md, and the "Jellyfin option" line removed from the connect page, README, emby.html, self-host.html and llms.txt.

**Measured.** `npm test` green: new `test:sleep-timer` (42, including the tuner's own sleep section run against a fake DOM and two negative controls), `test:playback-info` (14, the Swift test vectors), `test:jellyfin-urls` 22 to 41 (Emby URL shapes and Jellyfin unchanged), `test:web-tune-ownership` 25 to 35 scenarios plus a negative control for the late-callback guard, `test:reporting-controls` 24 to 28 (Emby reports through `/Sessions/Playing`). `npm run build` and `npm run build:selfhost` pass. Headless Chrome against a lab Emby 4.10.1.0 with synthetic test files: on the Docker image over plain http and on the hosted build behind a local https front with the site's CSP, sign-in, `/Users/{id}/Views` 200, 18 items, a direct play channel (H.264 + AAC MP4) and a server stream channel both played, HLS segments all 200 (120 and 54), the encode stopped with a 204 on channel change and at sleep expiry, no Emby ffmpeg left running. An http LAN address on the https page gets the local network message. Jellyfin 12.2.0 lab on the Docker image: `/UserViews` 200, stays Jellyfin, direct play and server stream play, wrong password still says INCORRECT USERNAME OR PASSWORD. UI pass at 1440x900, 1280x720 (zoom 0.875), 960x540 at pixel ratio 2 with a fine pointer (zoom 0.6667), iPhone 15 Pro and iPad Pro 11 both ways: the rail fits with eight controls and nothing clipped (at 1440x900 it ran 7px over until the short-window gaps came down by a pixel), picker, chips, panel and prompt all on screen, keep watching by click or tap, expiry, re-tune.

**Unverified.** Nothing on a real TV browser, iPhone or iPad: the phone and tablet runs were Chrome's emulation, so iOS Safari's own full-screen player (closed before the prompt shows) is untested. No Plex server was used, so the Plex codec fields and the panel on Plex are unmeasured. Emby subtitles were checked at the HTTP level, not watched. Full-screen expiry is covered by the fake-DOM test, not a real browser.

**Next.**
- Batch test on nostalgex.app and in Docker: Connect with Emby, the sleep timer to expiry once, the info panel on a server stream.
- Found while testing, not fixed: joining a server stream mid-programme stalls on a file with long gaps between keyframes when the server copies the video. A lab file with a keyframe every 10.4 s stalled on 6 of 7 joins (the first segment starts at the next keyframe, past the join point, and hls.js won't jump a start gap over 2 s); a 2 s keyframe file played 12 of 12. Same device profile on Jellyfin, not measured there.

## 2026-10-16 (horror all year, four new channels, locks that match whole titles)

**Shipped.** The web tuner on nostalgex.app since the branch was merged and pushed, and the Docker image `tuner-v1.0.1`. Apple TV still needs an App Store build. The channel ideas are @tydude001's, from discussion #29.

**Why.** tydude asked for horror outside October. On Apple TV a seasonal bundle has stayed on in any month since 1.0.26 (`activeMonths` only decides the October invite and the guide lead), but the web tuner and the Docker image still built a seasonal bundle's channels only in its month, so SCREAM looked October only. tydude also spotted that the SCREAM lock, which keeps the Scream and Halloween films on SCREAM ADULTS, would have to be shared with a SLASHER channel. Looking at the lock showed it matched substrings, which hid unrelated films.

**Changed.**
- Web and Docker: a bundle you switched on builds its channels in every month, as on Apple TV. Before, a returning visitor with SCREAM on got 0 of its channels outside October, and TIS THE SEASON 0 of 7 outside December. The Settings row says "SPOTLIGHTED OCT" instead of "(OFF SEASON)". `npm run test:library-load` runs the production loader and plex-tuner.html's own season check under a pinned clock for seven months; the old code fails 10 of its 13 checks.
- Exclusive locks, both engines: `editorialTitles` match the whole title, `titleContains` matches whole words (the same rule as a channel's `titleContains`), and a lock reads the item's own title, never a music video's artist. The web used to match artist plus title by substring and Swift title only by substring, so they disagreed. The SCREAM lock is now an exact list of the Scream and Halloween films (22 titles) and is shared by SCREAM ADULTS and SLASHER (`channelIDs: [132, 415]`). The holiday lock keeps its word list; "Santa" no longer catches Santana and "Holiday" no longer catches the horror anthology Holidays. Kicking & Screaming and Hubie Halloween are free again.
- Shared golden vectors for the channel filter, `scripts/filter-golden.json` (43 cases), run by the new `FilterGoldenTests` (Swift, against the bundled config and manifest) and by `npm run test:filter-golden`. A deliberately wrong case fails the Swift test, so it is not passing vacuously.
- SCREAM grows from 4 to 8 channels, still off by default, offered in October and switchable in any month: CH141 SLASHER (the franchise titles, or Horror with a TMDB slasher keyword), CH142 HORROR COMEDY (Horror and Comedy, no kids ratings), CH143 FOUND FOOTAGE (the found footage keyword on Horror or Sci-Fi, or the franchise titles; hidden under 3 films), CH144 WORLD HORROR. One horror bundle, not a second year-round one: a bundle without `activeMonths` is switched on at first load for anyone who owns a horror film. TIS THE SEASON gets the same web fix and lock fix, no new channels, December spotlight unchanged.
- New channels where tydude suggested: CH84 MYSTERY BOX TV in CASE FILES (the TV side of MYSTERY), CH55 CRINGE TV in PRIME TIME, CH118 A24 in NETWORKS. Numbers keep every bundle one unbroken block (CASE FILES 84 to 89, PRIME TIME 40 to 55, NETWORKS 118 to 129, SCREAM 137 to 144).
  - MYSTERY BOX TV is 30 shows by TMDB id (Lost, Twin Peaks, The X-Files, Dark, FROM, Severance and more), a `handCurated` block in the tuner's exemplars, every id checked against TMDB. Titles collide (Lost in Space, Dark Matter), TMDB keywords on these shows are thin (Lost has three), and Plex lists two genres per show, so a keyword or genre gate would miss most of them. It includes Horror only to open the genre lock for its own shows.
  - CRINGE TV: The Office, Curb, Peep Show, Nathan for You, The Rehearsal, How To with John Wilson and others by title, or a Comedy with a TMDB cringe keyword (cringe, awkward, socially awkward, embarrassment and a few more). Genre alone never qualifies. Not the mockumentary keyword, which covers Modern Family and Parks and Recreation.
  - A24 by studio and production company. Like the other studio channels it skips the genre locks, so A24 horror airs there with SCREAM off.
- WORLD HORROR data. It needs each film's original language and the app has none. Checked what is in reach: the shared `media_enrichments` table has 15 columns and none is language or country; Plex section listings carry `Country` on every film (1,787 of 1,787 in a test library), but country is not language, and Jellyfin and Emby need an extra field requested, which is six parsers on two platforms; OMDb has Language but 1,000 lookups a day shared by everyone; TMDB has `original_language` on the document the app already fetches, but cached rows would never be refetched, so it needs a Supabase column plus a backfill. Chosen instead: the language test runs offline. `scripts/channel-keyword-tuner/discover-world-horror.mjs` lists every TMDB horror film not in English with 25 or more votes (2,004 films, 57 languages, two sort orders unioned so paging cannot drop any) and writes them as manifest claims; the channel is `manifestOnly`. No app code, no Supabase change, no SQL. Cost: `channels-memberships.json` grows from 926 KB to 1.28 MB (107 KB to 138 KB gzipped). New releases need a rerun, and a full tuner regeneration needs it rerun afterwards, like `discover-standup.mjs` (tuner README).
- The Apple TV October dialog no longer says "for the rest of the month"; it says the package stays on until you switch it off.
- "130+ channels" replaces the hand written "131 channels" across the site pages, five blog posts, README, REPOSITORY-LAYOUT, llms.txt and the App Store metadata. Generated text keeps exact counts, and `render-lineup.mjs` now also writes the lineup header's no-JS counts. `bundles:render:strict` fails if a page claims more channels than `channels.json` has or names an exact count that is wrong. README and REPOSITORY-LAYOUT no longer say the Apple TV app fetches an updated `channels.json` at runtime: it asks the media server, which never has one.
- `channels.json` is v38, 138 channels.

**Measured.** On a test library of 1,787 films, 8,769 episodes and 1,131 music videos, through the web filter: SLASHER 10 films, HORROR COMEDY 6, FOUND FOOTAGE 2 (hidden), WORLD HORROR 0 (hidden), MYSTERY BOX TV 16 episodes of 1 show, CRINGE TV 0 (hidden), A24 5 films. SCREAM KIDS 13, FRIGHT NIGHT 49, SCREAM ADULTS 18 and NOSTALGEX HORROR 17 are unchanged, and the 8 SCREAM channels carry the same 69 distinct titles the 4 did. Every holiday channel is unchanged. Elsewhere only the lock fix moved anything: one film back on four channels, four music videos back on HIGH ROTATION. NostalgexTests: 797 tests, 787 passed, 0 failed, 10 skipped (opt-in live harnesses), run serially; with parallel clones two simulator clones refused to launch ("installing or uninstalling") on a busy machine while every test still passed on the other three. `npm test`, `npm run build` and `npm run build:selfhost` pass. The built web tuner in headless Chromium with a pinned clock and a synthetic library: on November 5 a returning visitor with SCREAM on gets its channels built, the row reads SPOTLIGHTED OCT and the guide starts at CH1; on October 20 SCREAM leads the guide from CH137; on July 4 TIS THE SEASON builds; no page errors.

**Unverified.** Nothing has run on an Apple TV, and the web tuner was not driven against a real server. WORLD HORROR and CRINGE TV have nothing to air in the test library, so only the golden vectors cover them. Whether Plex tags shows like FROM as Horror is unknown; MYSTERY BOX TV allows it either way. After the app update, Apple TV shows the new channels only after the next library refresh or Settings > Rescan library, because launch restores channel rules from the library snapshot.

**Next.**
- Which build carries this is Chad's call. It needs an App Store build for Apple TV; the web gets it when main is pushed and Docker with the next `tuner-v*` tag. Draft changelog bullets, not yet in `content/changelog.json`: "SCREAM is eight channels now: SLASHER, HORROR COMEDY, FOUND FOOTAGE and WORLD HORROR join, and you can switch it on in any month. Thanks to @tydude001." / "New channels: MYSTERY BOX TV in CASE FILES, CRINGE TV in PRIME TIME and A24 in NETWORKS. Thanks to @tydude001." / "Films that only sound like Halloween or Christmas ones, like Kicking & Screaming, are back on the channels they belong on."
- Roku port: the SCREAM lock uses `channelIDs: [132, 415]`, WORLD HORROR and MYSTERY BOX TV are `manifestOnly`, and lock `titleContains` is whole words now.
- Locks still hide two kinds of item, as before: a music video whose song is titled exactly "Scream", or any Christmas song, is locked to movie channels that never air music videos; a show with Santa as a word in its name is locked to the holiday movie channels. One fix would be that a lock never applies to an item none of its channels can air.
- Blog posts that say SCREAM "adds four horror channels" want a refresh once the app update is out.

## 2026-10-16 (Emby: sound and picture drift apart after tuning in mid-programme)

**Shipped.** Nothing yet. Branch `fix/emby-avsync-ts`, not merged, not in any build.

**Report.** On Discord: Emby, Apple TV 4K (1st generation), 1.0.26. On some channels the sound and the picture drift apart and never catch up.

**Cause, measured.** Every mid-programme join on Emby restarts the server's encode at the join segment: the app loads the stream and seeks, and Emby starts ffmpeg again there ("Starting transcoding because segmentGap is 39 ... requestedIndex=41"). When the video is copied and the audio is not (DTS, TrueHD, FLAC: anything AVPlayer cannot decode), the copied video starts at the keyframe before the join point and the audio exactly at it. In fMP4 segments both tracks are stamped from zero and the gap is kept only as an edit list in the init segment, which AVPlayer does not apply. The sound then runs early by the distance back to the previous keyframe, up to a whole GOP, until the programme ends. A programme watched from its start is fine, which is why only some channels showed it.

**How it was measured.** A Mac harness plays the same URLs the app requests in AVPlayer, timestamps flash frames through `AVPlayerItemVideoOutput` and beeps through a capture of its own audio mapped to the item's timebase, and reports sound minus picture. Synthetic files with one flash and one beep per second, a test Emby 4.10.1.0, a join at 247.3 s, segment responses held 400 ms to stand in for a real network. The harness reads +25 to +36 ms on a file played from its start, so that band is "in sync".

| Source | fMP4 + seek (today) | TS + seek (branch) |
|---|---|---|
| H.264 + DTS 5.1, 2 s GOP | -1720 ms | +35 ms |
| H.264 + FLAC, 5 s GOP | -731 ms | +24 ms |
| H.264 + TrueHD 5.1, 10.4 s GOP | about -6.2 s | +24 ms |
| H.264 + AC3, audio 0.5 s late in the file | -487 ms | +9 ms |
| MPEG-2 + AC3 (video re-encoded, audio copied) | +511 ms | +24 ms |
| H.264 + AC3, both copied | -59 to -69 ms | +9 to +19 ms |
| H.264 + AAC, both copied | -49 ms | +14 ms |
| MPEG-4 ASP + MP3, AVI (video re-encoded, MP3 copied) | does not open (-11829) | -5 ms |

Emby 4.8.11.0 and 4.9.5.0 in Docker measure the same (H.264 + DTS -1720 / +35 ms, H.264 + FLAC -731 / +24 ms). The hand-built fallback and the 1080p rung on TS: +35 ms. TS played from the start: +36 ms.

**Changed.** Emby HLS is MPEG-TS whenever the video can only come out as H.264, and fMP4 only when it may come out as HEVC, which AVPlayer will not render from TS. TS carries the source timestamps, so the player lines the tracks up itself, restart or not. One decision, `JellyfinPlaybackResolver.embySegmentContainer`, used by all three Emby HLS requests: the PlaybackInfo device profile, the hand-built fallback after a failed direct play, and the 1080p rung. A TS request offers H.264 only, so the server can never put HEVC in it. The join is still a client seek.

**Tests.** `EmbySegmentContainerTests` (10): the decision table, the PlaybackInfo profile, the fallback and capped URLs, the client seek, direct play, and Jellyfin unchanged. NostalgexTests: 792 passed, 0 failed, 10 skipped (opt-in live harnesses). `npm test` green.

**Rejected.**
- A start time instead of the seek. Emby would accept one: `StartTimeTicks` on PlaybackInfo comes back as `#EXT-X-START`, its segment URLs carry only `PlaySessionId`, and every request answered 200 on 4.8.11.0, 4.9.5.0 and 4.10.1.0. It does not help: AVPlayer fetches init.mp4 first, which starts the encode at zero, and the join segment restarts it anyway (-1723 ms). Even an encode started at the join point before AVPlayer asked for anything played -1784 ms out on fMP4, because the gap is still only in the edit list.
- Re-encoding the video on a join (`AllowVideoStreamCopy=false`). In sync when the audio is transcoded (+62 to +73 ms), but the gap flips when the audio is copied (H.264 + AC3 +1829 ms, H.264 + AAC about +6.2 s), it costs a full video encode, and Emby 4.10.1.0 cannot transcode 10-bit sources at all.

**Side effects, measured.** With no pacing (the player outrunning the encoder on localhost) the fMP4 join never played: Emby restarted ffmpeg for every segment, 42 restarts in 20 s and 2 frames decoded. TS played the same join in sync with 2 restarts. On a long-GOP file a TS seek can land up to a GOP after the requested time (10.4 s GOP: playback began at 252.2 s for a 247.3 s join).

**Not changed.** Jellyfin: the same fMP4 join is in sync on Jellyfin 12.2.0 (H.264 + DTS +35 ms, H.264 + FLAC +24 ms), so it keeps fMP4. Plex and every direct play are untouched. The web tuner already asks Jellyfin and Emby for TS (H.264, AAC stereo): +35 and +24 ms through AVPlayer on the same Emby, and -2 to -12 ms between PTS in the TS it receives.

**Unverified.** Not run on an Apple TV yet; macOS AVFoundation is close to tvOS for HLS but not the same, and an Apple TV passing AC3 to a receiver adds its own latency. HEVC with a transcoded audio track still streams as fMP4 and still drifts: H.265 + DTS -1720 ms, 10-bit H.265 + TrueHD -1731 ms, on all three Emby versions. EAC3 with Atmos in TS has not been tried. A file whose library entry has no video codec keeps fMP4 on an HEVC-capable device.

**Next.** On an Apple TV 4K (1st generation), the reporter's model: tune into an H.264 MKV with DTS or TrueHD mid-programme on Emby and check by eye. For HEVC, the cheap next step is preferring an AC3/EAC3/AAC track in the viewer's language when the file has one, so the audio is copied and starts with the video.

## 2026-10-16 (PR #25 merged: Show Now Playing and Mark Watched are separate)

**Shipped.** Merged to main, not released. PR #25 by @w6trp splits the one Report Playback switch into SHOW NOW PLAYING and MARK WATCHED, on the Apple TV (Settings > CONNECTION) and in the web tuner (Settings > PLAYBACK).

**Why.** Report Playback did two jobs: putting the channel in the server's Now Playing, and counting a programme as watched. People want one without the other, and counting a surf-past as a watch was the complaint the first version was built to avoid.

**Changed.** Both switches are off for new installs, the same opt-in default as before. An existing Report Playback choice carries over to both, and an explicit new off is kept. Mark Watched counts a programme only when you join in its first 15% and watch at least 75% of it. On Plex, Now Playing alone sends no position or watched updates. On Jellyfin and Emby, if the app cannot read the existing watch state first, it skips reporting for that session rather than writing a zero resume position, which could wipe real progress. Both switches sync through iCloud like the old one. The detail is in `Nostalgex/docs/plex-session-reporting.md`.

**Measured.** NostalgexTests on main with this merged: 749 passed, 0 failed (9 opt-in live harnesses skipped). Web: 24 new reporting-control checks and the watch-state golden cases pass. The README conflict with the reworked README was resolved in the README's favour; the switches are named in its privacy list.

**Unverified.** On a physical Apple TV: the two rows in Settings, the carry-over from an existing Report Playback choice, and a Jellyfin or Emby session where the watch state can't be read.

## 2026-10-16 (Plex: a Latin-1 file name no longer fails the whole library)

**Shipped.** Nothing yet. Branch `plex-utf8-repair`, for the next TestFlight build.

**Why.** A Plex user on 1.0.26 (48), tvOS 26.6 and Plex Media Server 1.43.4 could not load their library: LINEUP finished, LIBRARY stopped about halfway through section 1 of 2 with "Your server returned unexpected data" and `NSCocoaErrorDomain 4864`. Rebuilding the Plex database, refreshing metadata, updating Plex and reinstalling the app changed nothing.

**Cause, reproduced.** Measured in Docker on Plex Media Server 1.43.4.10903 and 1.42.2.10156: an unmatched item whose file or folder name holds a byte that is not UTF-8 (an é written in Latin-1, the single byte 0xE9) gets that raw byte copied into the JSON `title`, or into `summary`. The page is then not UTF-8, and JSONDecoder refuses it: "The given data was not valid JSON", `NSCocoaErrorDomain 4864`, underlying 3840, empty coding path, so nothing says which item. A section page (`/library/sections/{key}/all?includeGuids=1`, 500 items, 150 on a slow link) was one strict decode, so that ended the section and the scan. The same byte only in fields the app never reads (the file path, image alt text) does not fail the page, because the decoder converts a string only when it is read.

**Changed.**
- Every Plex response is checked for valid UTF-8 before decoding. A valid response is decoded untouched. Otherwise each byte that is not part of a well-formed UTF-8 sequence is read as Windows-1252 (0xE9 becomes é, 0x93 and 0x94 become curly quotes), every valid sequence is copied as it is, and the result is decoded. A stray byte is always 0x80 or above, so the repair cannot add a quote, backslash or control character to the JSON. One log line through `InstallDiagnostics` names the request path and page and the number of bytes repaired: `PLEX UTF-8 /library/sections/1/all?...&X-Plex-Container-Start=500: repaired 5 byte(s) that were not UTF-8, read as Windows-1252`.
- Applied on every Plex read: section pages, the sections list, the episode sweep (`type=4`), `allLeaves`, collections, collection children, `/identity`, plex.tv `resources` (server names) and the Plex Continue Watching read, which used `try?` and would have skipped its cleanup in silence. The PIN requests carry no names and are unchanged.
- Safety net, per item only: a Metadata item the model cannot decode is skipped and logged with its ratingKey and the path of the field that failed (`PLEX DECODE ...: skipped item ratingKey=202 at MediaContainer.Metadata[1]: expected Array<Any> at MediaContainer.Metadata[1].Media`), and the rest of the page loads. Field decoding is unchanged: no type coercion, because no other shape has been seen on a real server (a test library of 11,787 items and 15 lab edits all decoded with the 1.0.26 models). A broken container or a body that is not JSON still fails as before.

**Measured.**
- Three synthetic lab pages (`NostalgexTests/Fixtures/`, a file named `Café Society (2016).mp4` written in Latin-1, nothing from a real library) throw 4864 on the strict decode on the tvOS 26.1 simulator, and now decode with every item kept and the title "Café Society", not a replacement character. No model change was needed for that.
- A 500-item page (542 KB) on a Mac: 6.9 to 7.4 ms to decode in 1.0.26, 7.1 to 7.2 ms on the branch, 7.5 ms with one stray byte repaired. The UTF-8 check alone is 0.03 ms; the repair copy 0.4 ms.
- NostalgexTests: 745 tests, 736 passed, 0 failed, 9 skipped (opt-in live harnesses), including 15 new (`PlexUTF8RepairTests` 11, `PlexSkippedItemTests` 4). `npm test` green.

**Not changed.** The web tuner. Its scan reads pages with `Response.json()`, which decodes UTF-8 with replacement characters instead of failing: measured on the minimal fixture with Node 26's fetch, which follows the same Fetch spec as browsers, the page parses and the title reads "Caf\uFFFD Society". So its scan does not stop, though the accent is lost.

**Unverified.** Not run against the reporter's own server or on an Apple TV. The repair guesses Windows-1252 for any stray byte; a name written in another single-byte encoding would load, with the wrong accented letter.

**Next.** Ship in the next build and ask the reporter to confirm the library loads.

## 2026-10-16 (playback: a channel where nothing plays stops)

**Changed.** On branch `telemetry/signal-budget`, not merged, not in any build.
- Each failed programme sends `playback.error` once. The retry and transcode-failed paths sent it twice, as `player_failed` when AVPlayer failed and again from the error card (measured: two per failure on both paths). The card is now the one report, so the code on the wire matches the words on screen. A failure the viewer tunes away from before its card shows still reports once, for the channel it failed on. A starved direct-play stream with no server stream to fall back to used to skip with no report; it now reports `stalled`.
- A channel where nothing plays used to show the card, skip after 5 seconds, fail, and go round again for as long as the TV was on: a request to the server and a `playback.error` every 5.0 seconds (measured). Now, after 5 failures in a row on one channel with no picture in between, the channel stops. The card says "Nothing on this channel will play right now", gives the last reason, and "Try another channel, or select this one again to retry." The player item and any server transcode are torn down and nothing more is requested until `selectChannel` runs again: the viewer tunes, selects the channel again (selecting the current channel in the guide now retries instead of going full screen), the app returns to the foreground, or a library reload re-selects it.
- Why 5: one bad file, or a few in a row, still skip and carry on as before. If half a channel played, five failures in a row would come up about one time in 32; with four in five playing, about one in 3,000. Reaching five takes about 20 seconds when there is nothing to request and a few minutes on the slowest failure (a 4K server stream gets 40 seconds before the watchdog gives up).
- Only a picture confirmed by the startup watchdog resets the count. Reaching ready does not, because a file the device opens but cannot decode reaches ready with a black screen.
- The count lives in `Services/ChannelFailureRun.swift` and is advanced in one function, `recordFailedItem`, which every failure path calls. The recovery ladder and the attempt ownership checks are unchanged.

**Measured.** `PlaybackFailureRunTests`: a channel of items with no stream stops at the fifth failure, after five requests, and makes none over the next 600 ms. One bad programme among good ones (generated H.264) shows its card and the next programme plays. Four failures and then a playing programme: the watchdog's picture check resets the count at its 15-second deadline. Tuning away, selecting the stopped channel again, or re-selecting it as foreground return does each start a fresh count. Through the analytics gate, five failures with one code send one `playback.error`, and the session summary counts five.

**Web tuner.** Already stops after three failures in a row (`MAX_CONSECUTIVE_FAILURES` in `plex-tuner.html`), so it does not loop. Its count resets only when a frame plays, not on a channel change, so after one channel parks, the next channel's first failure parks it too. Left alone.

**Privacy policy.** Effective date October 16, 2026 in `Nostalgex/PRIVACY_POLICY.md` and `privacy.html`. Move both if the build ships later; `privacy.html` goes live when main is pushed.

**Unverified.** Not run on a physical Apple TV. The stopped card has not been looked at on a TV.

## 2026-10-16 (app analytics: a signal budget)

**Changed.** On branch `telemetry/signal-budget`, not merged, not in any build. Every analytics event now passes through one gate, `Nostalgex/Analytics/AnalyticsGate.swift`, before it reaches TelemetryDeck. No playback or guide code changed. TelemetryDeck counts every signal, and the app sent them in step with remote presses and hours watched rather than once per device, so the count climbed steeply with the users the 1.0.26 launch brought in.

**Measured.** `TelemetryVolumeHarness` drives the real AppState and AVPlayer load path in the simulator and records every event, then replays the same stream through the gate.
- 20 channel changes with real (generated H.264) playback: 61 events, 3 per change (`channel.tuned`, `playback.ready`, `playback.stopped`). After the gate: 3 in total.
- One channel with 4-second programmes for 30 seconds: 2 events per programme boundary (`playback.ready` and `playback.stopped`). A channel left on all night does this at every boundary, every 3 to 4 minutes on the music video channels.
- A channel where nothing plays, with nobody at the remote: `playback.error` every 5.0 seconds, about 720 an hour, until someone tunes away. The retry and transcode failure paths send `playback.error` twice per failure (once as `player_failed`, again from the error card). After the gate: one per backend and code.
- 200 changes on a lineup that cannot play: 400 events, 3 after the gate.

**Rules, per visit** (one foreground session, closed by `app.session.ended`; a visit that never backgrounds gets a fresh allowance every 4 hours):
- `channel.tuned`: first per backend and method. `playback.ready`: first per backend and delivery. `playback.error`: first per backend and code. `playback.transcode_fallback`: first per backend.
- `playback.stopped`: programmes on the same channel are added into one stay; stays under 60 seconds (surfing) are not sent; at most 12 stays per window. Watch time per channel survives.
- Every other name has a cap (settings 20, connect and library 5, rate and QR 1) and the window has a ceiling of 60. `app.launch` and `app.session.ended` always go out.
- `app.session.ended` now carries `tunes`, `playbackStarts`, `playbackErrors`, `suppressed` as ranges (0, 1, 2-5, 6-20, 21-50, 51-200, 201+) and the `backend` in use.

**Estimate per device per day.** Same before for 1.0.26 and main: the call sites did not change between them. "Visit overhead" is `TelemetryDeck.Session.started` + `app.session.ended` per visit, `app.launch` once, and a library refresh (started + completed).
- Light viewer, one visit, one hour, 10 changes, 2 programme boundaries. Before: overhead 5 + `channel.tuned` 10 + `playback.ready` 13 (launch tune, 10 changes, 2 boundaries) + `playback.stopped` 13 (10 changes, 2 boundaries, 1 on background) = 41. After: 5 + tuned 2 (guide, next) + ready 1 + about 5 stays of a minute or more = 13.
- Heavy surfer, two visits, 4 hours, 200 changes, 10 boundaries, 4 stalls (2 ending in a skip). Before: overhead 7 + 2 launch tunes + 200 x 3 + 10 x 2 + stalls about 12 (4 fallbacks, 2 x 2 errors, 4 reloads) + 2 background stops = about 643. After: 7 + tuned up to 8 + ready 4 + about 20 stays + fallback 2 + error 2 = about 43.
- A channel left playing overnight: before, 2 per programme (about 720 a day on a music video channel, about 130 on a sitcom channel); after, 2 per 4-hour window. A failing channel left alone: before about 720 an hour; after, one per window.

**Not changed.** TelemetryDeck SDK 2.14.0 defaults. Its only automatic signals are `TelemetryDeck.Session.started` (cold launch, and a return after 5 minutes or more away) and `TelemetryDeck.Acquisition.newInstallDetected` (once per install); session length is kept on the device and sent as parameters, not as extra signals. Debug builds still send, tagged as test signals.

**Dashboard effect.** Charts that count `channel.tuned`, `playback.ready`, `playback.error` or `playback.stopped` per event now count visits in which that kind happened at least once. Totals live on `app.session.ended`. Privacy policy (`Nostalgex/PRIVACY_POLICY.md`, `privacy.html`) updated to say so; `privacy.html` deploys when main is pushed.

**Unverified.** Not run on a physical Apple TV. Not checked against the live TelemetryDeck dashboard: which signal dominates the real count is inferred from the harness and the code, and the dashboard's breakdown by signal type is what confirms it. TelemetryDeck's docs do not say whether test-mode signals count toward the plan limit.

**Open.** `channel.tuned` per channel is down to the first tune of each method per visit; watch time per channel (`playback.stopped`, summed) is the channel popularity number now. `library.load.completed` sends the exact `itemCount`, which is more precise about a library's size than it needs to be; a range would do. The TelemetryDeck app ID is in the public `Info.plist` and shared scheme, so anyone who builds the repo reports into the same app (Debug as test signals, their own Release builds as live ones).

**Next.** Confirm the top signal names on the dashboard, then merge and ship with the next build.

## 2026-10-16 (PR #26 merged: playback information on Apple TV)

**Shipped.** Merged to main, not released. PR #26 by @w6trp adds PLAYBACK INFORMATION to the Now Playing panel, at the bottom under the sleep timer. It goes out with the next TestFlight build.

**Why.** When someone writes in because a channel won't play, the first questions are which server, whether it is direct play or a server stream, and why it fell back. This puts those answers on the screen while the problem is happening: backend, playback type, quality at tune, any recovery request, player size, source codecs and the fallback reason in plain words. The display model only accepts enums, fixed codec labels and bounded numbers, so no URL, token, server address or raw error text can reach it. Late callbacks are checked against the generation, attempt and current player item, so a channel change cannot paint the old programme's details over the new one.

**Changed from the first version.** Rebased onto #27's recovery flow by its author. The row moved from the PICTURE section to the bottom of the panel, since most people open it for retro and quality. Delivered Codecs and Stream Bitrate were dropped, because nothing fills them yet and rows that always say Unknown read as broken.

**Measured.** NostalgexTests on the merged tree: 730 tests, 721 passed, 0 failed, 9 skipped (opt-in live harnesses), up 25 from #27. Device build for tvOS succeeds. The PR's first CI run never reached the tests: the runner's simulator could not launch the test host.

**Unverified.** The panel on a physical Apple TV: row placement, remote focus, Back returning to the row, VoiceOver.

**Next.** #25 (separating Now Playing reports from watched counts) is the last open PR from @w6trp; it needs a rebase now that #26 and #27 are in.

## 2026-10-16 (homepage: four ways to watch, README refresh, tuner release notes)

**Shipped.** On nostalgex.app: a "Three ways to tune in. A fourth is on the way." section above How it works, with one tile each for Apple TV, the web tuner, the Docker container and a Roku preview. The hero puts its video straight under the headline on tablets and phones. GitHub release `tuner-v1.0.0` for the container, published as not latest so the repo's Latest badge stays on the Apple TV app (`v1.0.26`).

**Changed.**
- The section started as cards with device drawings. They read as busy and the four cards were hard to tell apart, so it is now solid colour tiles (yellow, cyan, pink) with a large ink logo, a name and one line, and a dashed tile with a Coming sticker for Roku. Docker and Roku joined the footer's not-affiliated line since their marks are on the page.
- On stacked layouts the hero video sat after the paragraph, both buttons and the note, a full screen down. `.hero-copy` becomes `display: contents` at 1024px and below so the video can be ordered second.
- The self-host page and README wrote the address as `http://<that-machine>:8080`. Browsers render that, but text extractors and AI readers strip the angle brackets and print `http://:8080`, so it is `YOUR-SERVER-IP` now.
- README: 1.0.26 and what it rolled up, Emby officially supported, the tip jar (replacing "no in-app purchases"), a shorter Docker quick start pointing at /self-host, iCloud and REPORT PLAYBACK in what leaves your network, an Other platforms section, and the `--` stand-ins replaced.

**Next.** PR #26 waits on @w6trp's rebase onto #27; #25 after it. The Roku port goes onto a real Roku for a sideload test.

## 2026-10-16 (web tuner from a TV browser, and the container goes public)

**Shipped.** The web tuner changes below, on nostalgex.app and in the first public container image, `ghcr.io/chadmueller/nostalgex` from tag `tuner-v1.0.0`. The `/self-host` page is published.

**Why.** The container was run on a Google TV in TV Bro. A test page on the TV measured what the browser gives a page: a 960x540 viewport at pixel ratio 2, `pointer: fine`, and a remote that moves an on-screen cursor and sends OK as a touch click. No arrow key, Escape or Back reached the page; Back only shows and hides the browser's own buttons. So the tuner drew its desktop layout at twice the size it was designed for, and everything that needed a key was out of reach.

**Changed.** All in the shared page, so the hosted tuner and the container stay identical.

- Small landscape screens with a mouse pointer scale the page (`zoom` 0.875 up to 1280x720, 0.6667 up to 1099x620) so it lays out like a desktop window about 1440px wide. `zoom` scales viewport units too, so the body and the settings panel are sized back up. At 960x540: the rail fits through Instagram, the channel tag clears the corner logo, the guide shows 7 rows instead of 4. Phones and tablets (`pointer: coarse`) and desktop windows above 1280x720 are unchanged, measured.
- Settings has a CLOSE button. It had no clickable exit at all, including on phones and tablets.
- In full screen, a click or OK on the picture shows the info bar with CH -, CH +, SOUND and EXIT FULL SCREEN.
- At TV sizes the guide footer's key hints become UP and DOWN page buttons. Cursor edge-scrolling scrolls whatever is under the cursor, and the top of the screen is the video, so the guide could scroll down but never back up.
- Sound remembers the viewer's choice. The page still starts muted, and a saved "on" comes back on the first click or key, the earliest a browser allows. A first press on a sound control is left to that control.
- The connect screen's scanline overlay is gone and retro mode's flicker and scanlines run only once a channel plays. The connect screen had five looping animations, two of them full screen at 80ms and 150ms, and the loading screen flickered whole every 150ms. On the TV the cursor lagged and colours washed out. The picture's retro look is unchanged.
- The video has a 1x1 transparent poster. Android's web view otherwise paints a grey box with a large play icon over the video between channels.
- The connect page scales the same way, so both Connect buttons are above the fold at 960x540.

**Measured.** Click-only runs in Chrome at 960x540 against a real Plex server: Settings opens and closes, the guide pages down and back to the top, full screen fills the screen, CH + and CH - change channel, EXIT leaves, no page errors. Sound memory checked in four cases with the video never pausing. `npm test` green; both CSPs allow the `data:` poster. On the TV itself: layout, rail clicks, full screen controls and the guide buttons confirmed by eye.

**Unverified.** Surround audio on the TV. Fire TV Silk, Samsung and LG browsers. An arm64 server running the image.

**Next.** A real Android TV app is the fix for the remaining TV-browser limits; the web tuner will not get Back or the D-pad from TV Bro. The container now follows the web tuner: tag `tuner-vX.Y.Z` when a batch of tuner changes is worth shipping to self-hosters.

## 2026-10-16 (PR #27 merged after a hardware pass)

**Shipped.** PR #27 by @w6trp is merged to main: native playback recovery belongs to one attempt at a time, and a server reply that arrives after its attempt was superseded only stops its own session. Not in a release yet. It goes out with the next TestFlight build.

**Measured.** Debug build of the merged tree on an Apple TV 4K (3rd generation), against a Plex server on the LAN, with Plex's `/transcode/sessions` polled every 3s.

- Recovery still recovers. Stopping the server transcode from outside the app gave a 20s stall, then the starvation ladder resumed the same item at the same position on a fresh session capped at 1080p. One transcode on the server afterwards.
- A second forced stop, on the stream that was already capped, advanced to the next scheduled item after an error banner. Same path, same behaviour as main before the merge.
- 78 channel changes in about three minutes, 39 of them server transcodes, many superseded mid-handshake. Every stop played the selected channel and no late reply replaced the player.
- Nine transcode sessions were visible at 3s resolution. Five were stopped by the app within 3 to 12 seconds. Three idle stubs (progress 0, speed 0, no duration) were never stopped and Plex reaped each one at its own 180s idle timeout. The ninth was the channel left playing.
- NostalgexTests on the merged tree: 705 passed, 0 failed, 9 skipped.

**Unverified.** Whether main before the merge leaves the same idle stubs; the same run against the old build would settle it. Jellyfin and Emby recovery under #27 were not exercised on hardware.

**Next.** Trace the idle stubs (most likely a decision or start request that reaches Plex after its stop) once the comparison says whether they are new. PR #26 next, then #25.

## 2026-10-16 (PR #28: current-main rebase and test sensitivity)

**Shipped.** Updated `fix/web-tune-ownership` for PR #28 on current main `bfb4453`. No app release, installation or deployment.

**Changed.** Rebased the rapid-tune patch and retained the upstream Roku relay, tablet rail, phone drawer and inline-player work. Both sides of the development-log conflict are preserved, including the earlier reconciliation entry. The production tuner is byte-for-byte unchanged from the previous PR head; this follow-up changes tests and this log only.

The race harness now enters through populated `switchChannel` paths, including A to B to A, and exercises the production advancement function. It executes the registered document/native fullscreen callbacks and pointer, touch and key retry callbacks. Rejected play promises leave the fixture paused. Fixture element ids must exist in the production HTML; schedule time, rendering, media and network remain controlled fixtures.

**Measured.** All 25 production-function scenarios pass. Four in-memory negative controls each fail the expected behavioral assertion when request ownership, queued-gesture protection, old-manifest protection or native-fullscreen resume is removed. Missing mutation targets are errors, not successful negative controls. The complete npm suite, including the upstream Roku relay smoke checks, and both hosted and self-host builds pass. The offline native suite passes 698 tests with zero failures; six live/opt-in harness classes were excluded. Both inline tuner scripts parse, the harness passes syntax checks and the diff has no whitespace errors.

**Half-done.** These are mocked DOM/media callback tests, not a real-browser or WebKit acceptance pass. Phone/tablet layout, actual codec playback, CORS and live server cleanup remain unverified. Fresh GitHub Actions will validate the pushed head; the known fork-only Vercel preview gate is unchanged.

**Next.** Review #28 first. The native recovery, playback-information and reporting-controls PRs remain on hold in that order; native recovery needs hardware acceptance and reporting controls need a Settings/defaults decision.

## 2026-10-15 (the relay accepts a Roku client)

**Changed.** `X-Nostalgex-Client: roku` is now accepted by `api/tmdb.js`, alongside
`tvos`, `web` and `selfhost`. A community Roku port is being built against the same
`channels.json` and filter rules (discussion #8), and without this it cannot fill the
channels that need TMDB keywords or IMDb ratings. One line plus a smoke test.

Roku needs nothing else: `roUrlTransfer` is not a browser, so it sends no Origin, gets
no CORS treatment, and reads the body regardless. The path allowlist, the edge cache
and the no-logging promise are unchanged, so a Roku client is the same shape of traffic
as an Apple TV.

**Watch.** OMDb's free tier is 1,000 requests a day across every client together, and a
backfill has come close to it before. The shared Supabase cache and a 7 day edge cache
absorb most of it, but a third client population is worth keeping an eye on.

## 2026-10-15 (/self-host page, branch)

**Changed.** All on branch `self-host-page`, unmerged and not deployed. Nothing
about the container itself changed; this is the page that explains it.

- New `/self-host` page (`self-host.html`, rewritten to `/self-host` in
  `vercel.json`, registered in `vite.config.js` next to the other static pages).
  It is the human version of the README's "Run it on your server": what the
  container is for, who does not need it, what you need, the commands, what
  leaves your network, where it works, and where it does not. The README is for
  people who already run Docker; this is for someone deciding whether to bother.
- Every command on the page is byte-for-byte the README's, checked by diffing
  the page's `<pre><code>` blocks against `README.md`. Three of the four match
  verbatim; the fourth is the two-line `NOSTALGEX_ENRICHMENT: "off"` snippet,
  which matches `docker/compose.yaml` and the values `docker/40-config.sh`
  accepts. The claims about what the container contacts were checked against
  `scripts/nostalgex-enrichment.js` (only TMDB and IMDb ids go to the relay and
  Supabase), `docker/nginx.conf`, `Dockerfile` (port 8080, uid 101) and
  `.github/workflows/docker.yml` (amd64 and arm64, no armv7).
- The device table is generated. `content/self-host.json` holds the rows and
  `scripts/render-self-host.mjs` renders them between markers, the same
  arrangement as `render-changelog.mjs`. It runs in `npm run build` and a
  `--check` mode runs in `npm test`, so the committed HTML cannot drift from the
  data. Statuses are deliberately graded: desktop browsers say Works because
  they were tested; iPhone and iPad say Should work, because the layout is built
  and checked in a headless browser but has never run on real hardware; TV
  browsers say Untested, because there are no results at all.
- On a phone both tables stack into labelled cards instead of scrolling
  sideways. The third column is the honest column ("not confirmed on hardware
  yet"), and hiding it behind a horizontal drag defeated the point of the page.
  Page styles are scoped under `.page-selfhost` in the global stylesheet.

**Half-done.** The page is deliberately not published. `published: false` in
`content/self-host.json` keeps it `noindex`, keeps it out of `public/sitemap.xml`
and `public/llms.txt`, and puts a note at the top saying the image is not on GHCR
yet. It is reachable by URL only: nothing in the nav or the footer links to it.
Flipping that flag to `true` and running `npm run build` publishes it, which is
the whole switch. That is meant to happen the day the image goes public, not
before.

**Next.** Publish the image, flip the flag, and decide separately whether
`/self-host` earns a nav or footer link. The iPhone and iPad row should become
Works or something worse once someone opens it on a real phone, and the TV
browser row needs a Fire TV before it can say anything at all.

## 2026-10-15 (PR #28: upstream reconciliation)

**Shipped.** Updated `fix/web-tune-ownership` for PR #28. No app release or deployment.

**Changed.** Merged upstream `1ae5dc4` so the tablet control rail is retained alongside rapid-tune ownership. Only the development log conflicted; both the upstream and feature entries are preserved. No ownership behavior was changed during reconciliation.

**Measured.** The complete npm suite, hosted build and self-host build passed on the reconciled tree, including all 17 rapid-tune race scenarios. Native source and bundled channel inputs are unchanged from upstream, so this web-only update did not need a new native run. The staged diff has no whitespace errors.

**Half-done.** Real-browser playback and live server cleanup are still unverified. Fresh GitHub Actions will validate the updated PR head after push.

**Next.** Await upstream review. Combining this with the independent reporting controls remains a separate integration step.

## 2026-10-15 (PR #27: upstream reconciliation)

**Shipped.** Updated `fix/playback-recovery-ownership` for PR #27. No app release, installation or deployment.

**Changed.** Merged upstream `1ae5dc4` so the tablet control rail is retained. Only the development log conflicted; both the upstream and feature entries are preserved. Native recovery behavior was unchanged during reconciliation, and the PR remains independent of the other playback changes.

**Measured.** The full offline native suite passed 705 tests with zero failures on tvOS Simulator. Six live/opt-in harness classes were excluded. The complete npm suite, hosted build and self-host build passed on the reconciled tree. The staged diff has no whitespace errors.

**Half-done.** Apple TV callback timing, real backend resource usage and live server session teardown remain unverified. Fresh GitHub Actions will validate the updated PR head after push.

**Next.** Await upstream review. Combining the separate playback PRs remains an integration step before release.

## 2026-10-15 (Web tuner: the control rail comes back on tablets, branch)

**Changed.** All on branch `tablet-rail`, unmerged and undeployed.

- The web tuner shows the desktop control rail on tablets again instead of the
  MENU button and the drawer. The drawer was the right call on a phone, where
  six controls cost a row of the guide, but on an iPad it hid SOUND, FULL
  SCREEN, RETRO, SETTINGS, APPLE TV, BUY ME A COFFEE and INSTAGRAM behind a tap
  for no reason. Where the rail shows, the top bar, the MENU button and the
  drawer are all `display: none` and the fixed corner wordmark comes back, so
  there is never a second way to the same controls, and nothing in the drawer is
  focusable by keyboard either.
- Gated on the width the rail needs, not on device names, following the
  `pointer: coarse` pattern already in the file so no laptop and no narrow
  desktop window can match. Portrait needs 700px: a phone in portrait is at most
  about 440px and a folding phone opens to 674px, while the narrowest tablet in
  portrait is 744px. Landscape needs 1000px, with the same `min-height: 501px`
  and `max-width: 1366px` as the tablet-landscape block it overrides; the
  narrowest tablet in landscape is 1133px and an unfolded folding phone is
  841px.
- Tablet portrait stacks, so the rail had no column to stand in and all three
  arrangements were built and measured at 834x1194 before choosing. Rail beside
  the info panel under a full-width video: the video keeps 834x469 but the row
  under it grows from 148px to 467px and the guide falls from 12 rows to 5. The
  full desktop side layout: the video drops to 444px wide, narrower than the
  guide under it. Rail beside the video with the info panel full width
  underneath, which is what shipped: the video goes from 834x469 to 694x390, the
  row is the rail's height instead of the rail's height added to the video's,
  and the guide rises from 12 rows to 15. That trades 17% of the video's width
  for three guide rows and seven controls on screen.
- Rail controls are 44px minimum on touch, where the desktop rail packs a button
  into 36px, paid for out of the padding and the gaps. Without the compaction
  the rail was 24px taller than its row at 1133x744 and scrolled. The rail also
  swaps to the short labels the drawer used, because [M] and [F] mean nothing on
  a tablet with no keyboard, and `:hover` is neutralised under `hover: none` so a
  tapped button does not stay lit.
- Rotating a tablet out of a drawer layout now closes an open drawer, since the
  rotation takes the MENU button away and would otherwise leave the sheet and
  its scrim on screen with nothing to dismiss them.

**Measured.** `npm test` and `npm run build` green. Headless Chrome against the
built `dist/`, at iPhone portrait and landscape, a 360x800 Android, iPad mini,
iPad and iPad Pro in both orientations, 1440x900, 1280x800, 1440x700, 1100x760
and 1920x1080. Guide rows fully visible, before to after: iPad portrait 12 to
15, iPad mini portrait 12 to 14, iPad Pro portrait 14 to 16, and all three
landscape sizes unchanged at 10, 8 and 12 because the rail takes its width from
the video rather than from the guide. All seven controls reachable on every
tablet size with the smallest tap target 44px, the rail fitting its row with no
internal scroll anywhere, no horizontal page scroll, no page errors, and SOUND,
RETRO and SETTINGS all driven by a real tap.

Desktop, TV and phones are unchanged, proved by dumping the rect and 36
computed properties of every element in the player at eight sizes from a build
of `main` and a build of the branch. The only differences are animation phase
(the retro scanlines, the VHS tracking bar, the coffee steam) and the live
progress bars, plus one new `<span class="v-btn-short">APPLE TV</span>` that is
`display: none` and 0x0 everywhere outside the tablet rail. The first-run build
screen measures identically to main at both iPad sizes.

**Half-done.** Branch only, not merged. Not tried on a real iPad and not in
Safari: everything above is headless Chromium with touch emulation, so the
`pointer: coarse` matching, the safe-area insets and iOS's own tap handling are
unverified on hardware. A touch screen wider than 1366px in landscape still
falls through to the desktop rail with its 36px targets and keyboard hints; that
is the same gap the tablet block already had, left alone so a 1920px TV browser
reporting a coarse pointer keeps the desktop layout.

**Next.** Chad to look at it on the iPad, in both orientations, and say whether
portrait's narrower video is the right trade for the controls and the extra
guide rows. If it is, merge and ship with the next web tuner deploy.

## 2026-10-14 (Web rapid-tune ownership, local review branch)

**Shipped.** Nothing published. This patch is prepared locally on
`fix/web-tune-ownership` for separate review.

**Changed.** An offline harness reproduced the production race: selecting A then
B, with PlaybackInfo resolving B then A, left A attached to the player. Subtitle
responses could likewise append A after B. Each tune now owns a generation,
request identity, cancellation signal, and captured connection context. Results
must still own the current selection after asynchronous work before changing the
player, tracker, or active server session. Returning to the same channel and
item does not revive an old request.

- Retiring a tune aborts its resolver, destroys its HLS loader, removes native
  metadata listeners, and cancels failure/stall timers. Queued media, HLS, gesture
  retry and subtitle callbacks also check ownership before acting.
- Late resolver results release only their captured server session, including
  Jellyfin/Emby active encodings. Cleanup does not use mutable connection
  credentials or a device-wide stop. A reused active session id is protected.
  Selecting a channel with no program now retires the outgoing playback.
- Subtitle loads have separate cancellation and generations, including body-read
  awaits and preference reloads for the same item.
- Added `npm run test:web-tune-ownership` to the standard test chain. Its 17
  offline scenarios execute production functions with controlled promises,
  mocked network/media/DOM, and fetches deliberately ignoring abort signals.
  All 17 passed. Existing web player smoke passed all 12 assertions; Jellyfin
  URL smoke passed 26. The new script passed `node --check`, both inline tuner
  scripts parsed without execution, and `git diff --check` passed. The complete
  npm suite and both hosted and self-hosted builds also passed. The native
  source tree and bundled channel inputs are identical to pinned upstream
  `9dd308b`, whose offline native suite passed 698 tests; no native source
  change required a new native run for this web-only patch.

**Half-done.** Local branch only. No live Plex, Jellyfin or Emby requests, browser
media playback, CORS checks, or device testing were performed. Session deletion
is best effort; when cancellation prevents receiving a server-assigned session
id, the client cannot explicitly delete that unknown id. Activity-reporting
features and pause controls are outside this patch.

**Next.** Review the local diff and complete real-browser validation before
choosing whether to publish. Verify rapid tuning with native HLS and
HLS.js, subtitles, connection changes, and server-side session cleanup.

## 2026-10-14 (playback recovery ownership, local review branch)

**Shipped.** Nothing published or installed. Changes are on
`fix/playback-recovery-ownership` for review.

**Changed.** Retries and fallback players now have an attempt token in addition
to the channel load generation. Status events, seek completions, startup
watchdogs and error probes check the exact player item before acting. Delayed
loads, negotiations and watchdogs are owned tasks and are cancelled on
replacement or disconnect. The starvation monitor and startup watchdog share
one pending server-stream negotiation. A cancelled request that still returns a
session stops that exact session instead of installing it. Initial-load offset
state is updated only after the request is still current. The existing
`resolveServerStream` behavior and retry delays are preserved.

Measured. Seven focused offline tests pass against AppState's production
recovery callbacks with AVPlayerItem and a controlled backend, including
repeated starvation verdicts, overlapping watchdog recovery, late replies,
rapid channel changes, cancelled debounce and preparation. The full offline
native suite passes 705 tests with zero failures (676 XCTest and 29 Swift
Testing). Swift syntax and whitespace checks pass. No user credentials or real
media-server state were used.

**Half-done.** The branch is local and unpublished. Actual Apple TV playback,
backend resource usage and server session teardown are unverified.

**Next.** Review the patch, then verify rapid surfing and slow-server recovery
on hardware before publication.

## 2026-10-14 (Docker web tuner: caught up with main, branch)

**Changed.** All on branch `docker-selfhost`, still unmerged and unpublished.

- `origin/main` merged in. The branch was cut from 1.0.26 (47) and predated the
  whole mobile web tuner pass, so the image would have handed self-hosters the
  old desktop-only tuner. That was the reason Docker was put on hold, so this had
  to come first. The two tuner pages merged with no conflict: main rewrote layout
  and playback, the branch touched sign-in plumbing and added marker comments,
  and the hunks did not overlap. Four files conflicted (`vite.config.js`,
  `package.json`, `.github/workflows/ci.yml`, `docs/DEVLOG.md`) and kept both
  sides. The self-host build asserts that no remote script, stylesheet, font or
  image survives, so the new drawer and touch markup could not quietly bring the
  CDN back.
- The channel hub's hero screenshot is measured on first render instead of at
  module import. `vite.config.js` now imports `scripts/build-bundles.mjs` for the
  hosted site, the self-host build loads the same config, and its Docker context
  carries only the two tuner pages, so measuring at import failed the image build
  before any tuner work started.

Measured. `npm ci`, `npm test` and both builds green. `dist/` still differs from
main only in the `location.protocol` guards, the `randomUUID` fallback, the
relative tuner links and the two self-host branches in the shared scripts. No
marker line reaches `dist/`. In `dist-selfhost/` every `https://` in a `src` or
`href` is a user-facing link (App Store, GitHub, Instagram, Buy Me a Coffee,
plex.tv/link); no subresource is remote. Image 26.5 MB compressed on amd64 and
26.8 MB on arm64, built multi-arch, both run on a Mac (amd64 emulated).

In headless Chrome against the running container on a LAN http origin, driving a
scratch Jellyfin 12.2:

- Phone layout is in the image. At 393x852 the video container is 393x221, the
  video element carries `playsinline` and `webkit-playsinline`, the bottom
  toolbar is `display: none`, the MENU button is 86x44, the drawer opens to 300px
  and closes on Escape and on a tap outside, and the page has 0px of horizontal
  scroll. Same at 360x800, 834x1194 and both landscape sizes; the desktop rail
  comes back at 1440x900. Guide scrolls and tunes at every size, no page errors.
- A channel played from the http origin, at phone size as well as desktop, 2 to
  24 seconds to picture and still running at 2:36.
- Hosts contacted while connecting and playing: with `NOSTALGEX_ENRICHMENT=off`,
  only the container and the media server, nothing else at all. With it on, the
  same plus the Supabase metadata cache.
- Enrichment gating measured directly, since the scratch library has no TMDB ids
  and never reaches the metadata layer on its own. Driving the page's own
  enrichment entry with three TMDB ids: with enrichment on, three records came
  from the Supabase cache and no other host was contacted; with it off, the run
  skipped, logged why, and made no request beyond `config.json`. Music lookups
  report off in both.
- Plex PIN request, QR render and polling work from the http origin: nine
  plex.tv requests, no CORS failure, no other host.

**Half-done.** The relay change is still not deployed, so a cache miss cannot be
filled from a self-host origin today. Every TMDB id in the measurement above was
a cache hit, so the relay path itself is still unproven from a container. Plex
sign-in was still not completed from an http origin, only the PIN handshake.
TV browsers are still untested (no Fire OS device). No arm64 hardware run; arm64
was only built and inspected, not executed on an arm64 server. The plan's second
egress test, the container and a media server on an `--internal` Docker network,
has not been run; the proof so far is the browser request log. No GHCR image, no
tag, no `/self-host` page.

**Next.** Deploy the relay and prove a cache miss fills from a container. Then
the Phase 0 TV pass, which needs a Fire TV device. Publishing (tag, image,
making the package public, the page and the posts) waits on Chad.

## 2026-10-14 (1.0.26 released)

**Shipped.** 1.0.26 (48) is live on the App Store, released manually after Apple
approved it. The three tips (Popcorn, TV Dinner, Pizza Night) were approved with
it, so the tip jar works for the first time. The jump from 1.0.23 means the
release notes cover 1.0.24 through 1.0.26.

Apple's two review queues disagreed: the full App Store review passed while the
TestFlight beta review for the same binary was still waiting, a day after
submission. Build 48 was never distributed to the external groups. 49 takes that
slot instead.

**Changed.** `content/changelog.json` marks 1.0.26 `released: true`, so the site
shows it. 1.0.24 and 1.0.25 stay `false`: those versions only ever existed in
TestFlight, and their changes are inside the 1.0.26 notes. The privacy page's
playback reporting paragraph now covers the Apple TV app, not just the web tuner,
because 1.0.26 is where position-free Plex reporting shipped. Effective date moved
to October 14, 2026.

**Next.** Build 49: the Emby fallback stream fix, the Jellyfin and Emby stall
retry fix, and collections that hold TV shows. All three are on main and none are
in 48. The two playback ones are pre-existing faults, present in 1.0.23 as well,
so 1.0.26 does not regress anyone; they want a hardware pass before 49 ships.

## 2026-10-13 (Docker web tuner, branch)

**Changed.** All on branch `docker-selfhost`, not main, nothing published.

- `npm run build:selfhost` builds web-tuner.html (also as index.html) and plex-tuner.html
  into `dist-selfhost/` with hls.js, qrcodejs and the fonts vendored from pinned npm
  packages (the files match the jsDelivr SRI hashes), analytics removed, and marketing
  chrome, newsletter and the email promo cut out between `selfhost:` markers. The hosted
  build deletes the marker lines only: `dist/` was byte-identical after that commit.
- The tuner now works from a plain http page: a getRandomValues fallback for
  `crypto.randomUUID` (missing on http, which broke the Plex client id), bare Jellyfin
  hosts default to http:// when the page is http, and the mixed-content flag and copy
  only apply on https. Tuner links are relative. On the hosted site these are guarded
  by `location.protocol`; `dist/` differs only in those lines.
- Enrichment stays on in the container (nine or more channels need it) and is the only
  outside traffic besides plex.tv. `NOSTALGEX_ENRICHMENT=off` turns it off; the tuner
  reads `config.json`, written at container start, and treats a missing file as off.
  MusicBrainz and Deezer lookups are off in the self-host build.
- The TMDB relay accepts `X-Nostalgex-Client: selfhost` from any http(s) origin, since a
  LAN address can't be listed. Listed origins, the path allowlist and edge caching are
  unchanged. The self-host build calls www, because the apex 308s and a CORS preflight
  can't follow a redirect.
- Dockerfile (nginx-unprivileged 1.30 alpine, uid 101, port 8080), nginx config (.cjs
  as JavaScript, http-friendly CSP, no HSTS), compose example, a `tuner-v*` GHCR release
  workflow and a PR docker smoke in ci.yml.

Measured on a Mac (colima, arm64; amd64 built and run under Rosetta): image 26.8 MB
compressed. In headless Chrome on a LAN http origin against a scratch Jellyfin 12.2,
the connect form signed in over http and a channel played (H.264/AAC, 1080p). Hosts
contacted: with enrichment off, only the container and the media server; with it on,
also the Supabase cache and www.nostalgex.app. Plex PIN request and polling from the
http origin worked (plex.tv CORS allows it); sign-in was not completed.

**Half-done.** The relay change is not deployed, so today the live relay refuses
self-host origins (verified: the preflight gets no allow-origin) and enrichment from
the container only gets what is already in the shared cache. TV browsers untested
(no Fire OS device yet). No GHCR image, no tag, no `/self-host` page.

**Next.** Deploy the relay, set the `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY`
repo variables, tag `tuner-v1.0.0-rc1` for a private image, then the Phase 0 TV pass.

## 2026-10-13 (web tuner: controls behind one menu on touch)

**Shipped.** Nothing. The work is on the branch `web-tuner-drawer`, not merged.

**Changed.** Testing the new touch layout on a phone, the owner's verdict was
that the guide and the video are the two things that matter and the controls are
not: in landscape the vertical rail ate a column of the screen and left about
two guide rows visible, and in portrait the controls cost a row from the bottom.
So on touch there is no control surface on screen at all. One MENU button sits
in the top right, and every control lives behind it.

- The drawer is a sheet from the right, `min(300px, 84vw)` wide, full height,
  over a scrim. Right rather than bottom because the same sheet then works in
  both orientations: at 393px wide it covers three quarters of the screen, and
  at 393px tall all seven boxes still fit without scrolling. It holds SOUND,
  FULL SCREEN, RETRO, SETTINGS, INSTAGRAM and BUY ME A COFFEE. SETTINGS opens
  the config screen that already existed. The coffee box is the only warm one;
  everything else is the toolbar's cyan.
- It dismisses by the close box, by a tap anywhere outside it, and by Escape,
  traps Tab inside while open, and returns focus to the MENU button on close.
  Opening it only moves a panel: `pause()` and `load()` call counts and the
  video's `currentSrc` are unchanged across an open, so playback carries on
  behind it.
- Every other key falls through, so M, F, B and H still work with the drawer
  open as well as on desktop.
- Landscape phones get no top bar either. A bar would cost 48px of the 393
  available, so the MENU button floats in the top right corner over the
  letterboxed black beside the video and takes no layout height. The video row
  gives up 62% to 55% of the height, which is the only place extra guide rows
  can come from in landscape: the 84px the rail held was horizontal, and the
  video there is height-limited, so it could not use the width anyway.
- Tablet landscape: the guide cap went from 44% to 50%, so the 56px the bottom
  bar gave up goes to the guide rather than to the video row, which is already
  as tall as the panel beside it allows.
- Portrait phones under 560px: guide rows go 34px to 32px. The screen is all
  guide now and one more channel fits.
- The closed drawer is parked off the right edge, which widens the document and
  leaves the page scrollable sideways. `body` already clips; `html` does not, so
  it gets `overflow-x: hidden` in the touch blocks.

**Measured.** Channel rows fully visible in the guide, before and after, driving
the built `dist/` in headless Chromium against a fixture library:

| Viewport | Before | After |
|---|---|---|
| iPhone portrait 393x852 | 10 | 11 |
| iPhone landscape 852x393 | 2 | 3 |
| Android portrait 360x800 | 9 | 10 |
| iPad portrait 834x1194 | 11 | 12 |
| iPad landscape 1194x834 | 8 | 10 |
| Desktop 1440x900 | 8 | 8 |
| Desktop 1280x720 | 6 | 6 |

The guide's scrolling body grew 52px in portrait, 52px on iPad portrait, 28px on
a landscape phone and 25px on iPad landscape. No horizontal scrolling at any
size (300px of it before the `overflow-x` fix). Every control in the drawer is
at least 44px in both dimensions.

**Desktop is untouched**, and that was checked rather than assumed: a dump of
every rendered element's box, display, colour and font size at 1440x900,
1280x720 and 1100x900 is identical before and after, apart from the playback
progress bar's width and the VHS tracking line's position, which both move with
the clock. The new nodes are all `display: none` 0x0 boxes there. The rail, its
keyboard hints and the short-window height tiers are unchanged; the new
landscape rules are gated on `pointer: coarse`, so a short desktop window keeps
the rail it had.

**Half-done.** Branch `web-tuner-drawer`, one commit on top of
`8f74c78`. Not merged, and `main` has moved since it was cut.

**Unverified.** Headless Chromium only. Not tried on a real phone, in Safari, or
with a real `env(safe-area-inset-*)`, so the home indicator clearance in
portrait and the notch clearance for the floating button in landscape are
reasoned from the CSS, not seen. VoiceOver was not run against the drawer.

**Next.** Merge with the two other web tuner branches in flight, then look at it
on a phone.

## 2026-10-13 (web tuner: iPhone had no inline playback)

**Shipped.** Nothing. The work is on the branch `web-tuner-ios-playback`, not
merged.

**Changed.** On iPhone the web tuner never played. Tapping a channel threw
playback into the native fullscreen player, and leaving that player left a
frozen frame with the schedule running on without it. One root cause: the
player element was `<video id="plex-video" autoplay muted>` with no
`playsinline`. iOS does not allow a video without that attribute to run inline
at all, so every `play()` the schedule made was refused and the native player
was the only place the picture could appear. A landscape screenshot from a
phone showed the end state exactly: the video inline but paused, iOS's own
transport overlay on top of it (iOS draws that on a video it will not play
inline, even with no `controls` attribute), the native scrubber reading a real
position and duration, and the tuner's info panel counting on past it.

Measured before the fix, in WebKit under a shim of Apple's two documented
iPhone rules (no inline playback without `playsinline`, and no element
fullscreen API): on one channel tune, `playsInline` false, `paused` true,
`readyState` 4 with the stream loaded and seeked to the schedule offset, one
rejected `play()` and zero successful ones. After the fix, same harness: zero
rejections, `paused` false, `currentTime` advancing, and no fullscreen call
anywhere in the tune path.

Three more things were found that would each have kept the picture dead, and
are fixed in the same change:

- A refused `play()` logged "Autoplay blocked" and gave up, so once the browser
  said no there was no route back short of a reload. Playback now retries on the
  viewer's next tap or key, one armed listener at a time, and disarms when the
  channel moves on.
- Nothing listened for `webkitendfullscreen`. iOS pauses the element when its
  native player closes, so even a viewer who got playback going through that
  player came back to a still. Measured: paused after leaving, `currentTime`
  frozen. It now resumes inline from inside the dismissal gesture, and
  measured after the fix the clock keeps running.
- `toggleFullscreen` called `container.requestFullscreen()` unguarded. That API
  does not exist on iPhone in any spelling, so the FULL SCREEN control threw a
  TypeError on every tap. It now feature-detects and falls back to the video
  element's own `webkitEnterFullscreen`, which is the only fullscreen iOS
  offers. The Jellyfin subtitle gate and the G-key overlay were keyed off
  `document.fullscreenElement`, which is also undefined on iPhone; both go
  through one `isVideoFullscreen()` helper now, so captions work in the native
  player too.

`scripts/web-tuner-player-smoke.mjs` asserts all of it against the source and
runs in `npm test`. It fails on the pre-fix file with 9 failures, so the
attributes and the recovery paths cannot quietly disappear again.

**Half-done.** Branch `web-tuner-ios-playback`. Not verified on a real iPhone:
real iOS was not available to the agent that made the change, and the
forced-fullscreen rule is iOS-only, so desktop WebKit cannot reproduce it. What
was run is desktop WebKit and Chromium at phone viewport with a real H.264/AAC
MP4 served to the direct-play path, plus the shim described above. Someone with
an iPhone should open the tuner, tap a channel, and confirm the picture starts
in the guide with no fullscreen transition, that FULL SCREEN opens and closes
without killing playback, and that playback is still running after closing the
native player.

The Apple TV app is untouched by this. It plays through AVPlayer natively and
shares no code with the web player.

**Next.** The iPhone confirmation above. The branch touches only the player and
fullscreen code, so it should merge cleanly alongside the touch chrome work on
`web-tuner-screens` and `web-tuner-drawer`.

## 2026-10-13 (web tuner: server picker and first-run build screen)

**Shipped.** Nothing. The work is on the branch `web-tuner-screens`, not merged.

**Changed.** The two screens a new phone user meets before the guide ever
appears. Both were reported from a phone on the live site, and both reproduced
in a headless browser at 393x852 against stubbed plex.tv resources and a fixture
library, so the numbers below are measured rather than guessed.

Server picker:

- The column was a hard `width: 500px` inside an unpadded `.plex-connect`, so at
  393px it was 447px wide starting at x -53. The row checkbox sat off the left
  edge of the screen, which is why you could not tell what was selected, and the
  page scrolled sideways. The column is `min(500px, 100%)` now and the connect
  screen has gutters plus safe-area padding, scrolls when a long list does not
  fit, and caps the wordmark, which used to render 560px wide on a 393px screen.
- A row's address is around 80 characters of plex.direct hostname. It was
  ellipsised mid-hash and took most of the row's height for no information. On
  touch a row is now the name, a tick and short badges (SHARED, LOCAL, REMOTE,
  RELAY, OFFLINE), with the addresses behind a SHOW ADDRESSES toggle that wraps
  them in full for anyone diagnosing a connection. OFFLINE comes from the
  `presence` flag plex.tv already returns, which is now carried through
  discovery; before this the picker gave no hint that a server could not be
  reached until after CONNECT.
- Selection reads at a glance: a cyan border, a cyan inset edge down the left
  and a 26px tick. Rows are at least 60px, CONNECT is full width and 52px.
- Pointer screens are untouched. The badges and the toggle are display:none
  outside the touch media queries, and the inline "(shared)" suffix and the
  always-visible address stay exactly as they were on desktop and TV.

First-run build screen:

- The panel is `inset: 0` inside `.video-container`, which the portrait rules
  size to a 16:9 box. Measured at 393x852: a 221px tall box holding 510px of
  content. The coffee block fell off the bottom, the step rail and the progress
  bar were stranded, and the remaining two thirds of the screen was empty black,
  which read as broken rather than as working. While `.building` is set there is
  no video and no guide, so the container now takes the whole screen on touch.
  `position: fixed` was tried first and does not work here: the retro flicker
  animation puts a transform on `.video-container`, which makes it the
  containing block for fixed descendants, so fixed resolved to the same 221px.
- The status content is one bordered card (hint, steps, headline, status line,
  progress) between the wordmark and the coffee ask, rather than five things
  floating in a column. The card wrapper is `display: contents` on pointer
  screens, so the desktop and TV stack is unchanged.
- Step labels no longer truncate. They were equal-width columns at 10px, which
  cut CHANNELS to CHANNE... at 393px and LIBRARY as well at 360px. Each step now
  takes the width its label needs and the connectors take the rest, at 8px.
  Checked with the five-step rail (the music bundle adds a phase) at 360px.
- The progress rail is the width of the card and 10px tall with the count under
  it, so it has a job. The second line was printing the same "Section 2 of 4"
  caption as the bar, and for the scanning phases the same detail as the
  headline; it now shows what the phase is doing instead. That one is in
  `scripts/nostalgex-library-load.js` and so applies on desktop too.
- Retro mode pins the empty video element to 4:3 off its height. With the
  container full screen that was wider than the screen (1137px of page at 393px
  of viewport), so the video is constrained while `.building` is set. No
  playback rule was touched.

**Measured.** Headless Chromium at 393x852, 852x393, 360x800, 834x1194,
1194x834 and 1440x900, on six states each (sign-in, PIN, picker, picker with
addresses, scanning, music enrichment): no horizontal scroll, nothing outside
the viewport on either edge, no truncated text, and every row, toggle and button
at 44px or more. Desktop is byte-for-byte the same layout it was, bar the
status line wording. `npm test` and `npm run build` pass.

**Half-done.** Branch `web-tuner-screens`, not merged. Not tried on a real
phone and not in Safari: Chromium only. The `safe` keyword in
`justify-content: safe center` and `display: contents` both want a look on
iOS Safari. Unrelated and untouched: the picker's Enter handler calls
`selectServer()`, which does not exist in the file, so keyboard selection in the
picker throws. Another branch, `web-tuner-ios-playback`, is editing the video
element and fullscreen in the same file.

**Next.** Look at both screens on a real iPhone before merging, in portrait and
landscape, and in particular check that the build screen fills the screen under
Safari's shrinking toolbar.

## 2026-10-13 (page media, blog images, legal holds lifted)

**Shipped.** The channel guide went live: `/channels` plus 14 bundle pages, the
new hand written titles, and every bundle name in the home page lineup linking
to its page. Sitemap resubmitted to Search Console. The Tunarr and ErsatzTV post
is live, a day later than scheduled.

**Changed.**

- `scripts/site-media.mjs`, shared by the blog and the guide. Every image
  carries width and height so nothing shifts while it loads: a file in this repo
  is measured at build time (png, jpeg and webp headers, no new dependency), and
  a remote file is measured once by `npm run media:measure` into
  `scripts/media-sizes.json`. The build reads that file and never touches the
  network, so a deploy does not depend on the bucket answering, and a new remote
  image fails the build until it has been measured.
- Every image needs real alt text or the build fails. Alt text and a clip's
  aria-label now feed the guide's copy checks, so a dash or a held name in alt
  fails the same way it does in body copy.
- Blog posts take `cover`, `og_image` and inline markdown images, which render
  as lazy loaded figures with the markdown title as the caption. Bundle pages
  take the same fields plus an optional `clip`. Clips are muted, looping and
  poster backed, started by app.js when they scroll into view, left paused under
  reduced motion or Save Data. `og:image:width` and `og:image:height` are now
  emitted for any card, not only the shared default.
- Seventeen images across all seven posts, three live and four drafts, served
  from the media bucket rather than committed: this repo is public and the
  captures are frames from films. Measured sizes matched what the retrofit
  documented (covers 1200x630, grid crops 1280x412, guide crops 1280x565).
- Fixed the markup a standalone image produced. marked wraps it in a paragraph,
  and a figure inside a paragraph makes the browser close the `<p>` early and
  leave an empty one behind.
- **The legal holds are lifted.** Chad cleared the brand and franchise channel
  names for publication, for now. All 14 bundles are indexed, all 131 channel
  names are printed, the sitemap went from 11 URLs to 15, and llms.txt lists
  every bundle. The brand word list moved out of `build-bundles.mjs` into
  `scripts/legal-hold.json`, so that one file decides what is held: bundles,
  channels and words. The former lists are kept in the same file under
  `releasedBundles`, `releasedChannels` and `releasedBrands`, so putting a hold
  back is a copy from one list to another and a rebuild.
- The affiliation disclaimer now renders on every bundle page rather than only
  the held ones. A page that prints a studio or franchise channel name is the
  page that needs it.

**Half-done.** The four bundles that were held (Kidz Zone, Franchises, Networks,
Arthouse) still carry the deliberately generic intros written while they were
noindex: they never name their own channels. They are accurate and they are safe
if the holds go back on, but they read vaguely for pages that are now indexed
and could name what is on them. Rewriting them is the obvious next copy job.
Bundle pages have no images yet beyond the hub, which reuses the home page
lineup screenshot; six bundles have no usable capture at all (sports, true
crime, arthouse, Christmas, music videos) and Christmas wants a November capture
with holiday titles in the guide.

**Next.** Decide whether the four generic intros get rewritten now that the
names are published. Request indexing for `/channels` once Google has refetched
the sitemap: the Indexing API submission failed with "Insufficient Permission",
so that is a service account and API enablement job in Google Cloud before it
can be scripted.

## 2026-10-13 (web tuner: phones and tablets)

**Shipped.** Nothing. The work is on the branch `web-tuner-mobile`, not merged.

**Changed.** The web tuner had no real phone layout. Measured on a 393x852
viewport, the video element rendered 393x0: the side layout put the info panel
and the 140px toolbar in a column, they used the whole 650px video row, and the
picture got nothing. The toolbar also overflowed its row on a 852x393 landscape
phone and on an iPad, so the Instagram link was cut in half.

The touch layouts now follow the shape already shipped on another product of
Chad's: a slim top bar, the video first and edge to edge, the now-playing line
compacted under it, the guide taking the rest, and the controls as a bar across
the foot of the screen.

- Portrait up to 1024px: the video is `order: -1`, full width, `aspect-ratio:
  16 / 9`. The info panel sits under it with the description hidden, the title
  clamped to two lines and the episode line to one. The guide fills what is
  left. Measured on 393x852: video 393x221, info 115, guide 416, bar 56.
- The toolbar becomes a fixed bar, `calc(56px + env(safe-area-inset-bottom))`
  tall, six equal columns divided by hairlines, with
  `padding-bottom: env(safe-area-inset-bottom)` so it clears the home
  indicator. `.player-screen` gains matching padding so the guide is never
  underneath it.
- Six controls, not seven. The App Store link is dropped on touch rather than
  moved: it points at a tvOS app, and nobody installs one of those from a
  phone (owner's call). The top bar carries the wordmark and nothing else. The
  coffee box keeps its warmth as a yellow wash and yellow type rather than a
  solid slab, and loses the desktop glow, which is far too much at this size.
- Desktop, short windows: the rail is centred, so once Instagram joined it the
  content outgrew the video row and clipped SOUND at the top and Instagram at
  the bottom. Measured 20px over at 1280x800 and 30px at 1440x760. Three
  height tiers tighten the padding and gaps, and the rail scrolls from the top
  (`justify-content: safe center`) rather than clipping if it ever does not
  fit. Re-measured at 1280x650 through 1920x1080: nothing clipped anywhere.
- Keyboard hints are gone from touch labels. `[M]` and `[F]` mean nothing on a
  phone, so each button carries a second short label that the touch layouts
  swap in. Desktop keeps the hints.
- Landscape phones (`max-height: 500px`) keep a vertical rail, because height
  is the scarce dimension there and a bottom bar would cost 56px of 393. The
  rail is now pinned to the left edge over the full height instead of being
  confined to the video row: inside the row its six controls were 35px tall,
  under the 44px a thumb needs, and the last one was clipped. Pinned, they
  measure 71x60.
- Tablet landscape keeps the side layout, since it is a good use of the width,
  but loses the 140px toolbar column to the bottom bar and has its type
  compacted. On 1194x834 the video went from 636 to 788 wide.
- Two text bugs that were visible at tablet width: the fixed corner wordmark
  printed on top of the channel tag (the top bar carries the mark now, and the
  corner one is hidden on touch), and `.info-channel-tag` had no line-height,
  so a tag wrapping to two lines printed them over each other in the pixel
  font. Grid header times get `white-space: nowrap`; they were wrapping out of
  the fixed 32px header into the rows below.

Nothing outside a media query changed, so desktop and TV are untouched. Checked
by measurement at 1440x900: video, info panel, toolbar and guide boxes are
identical before and after, and the toolbar still shows seven controls with
their keyboard hints.

**Half-done.** Branch `web-tuner-mobile`. Verified only in headless Chromium at
393x852, 852x393, 360x800, 834x1194, 1194x834 and 1440x900, driven against a
synthetic fixture library. Not tried on a real phone or tablet, and not in
Safari, which is where `env(safe-area-inset-*)`, `aspect-ratio` and sticky
`:hover` after a tap actually matter. The hover-after-tap guard is written but
unproven on a real iOS device. The video element was black in every shot
because the fixture has no media, so the 16:9 box is confirmed by measurement
rather than by picture.

**Next.** Chad to open the branch on a phone and an iPad before it merges.

## 2026-10-13 (web tuner: Instagram in the toolbar)

**Shipped.** Nothing yet. On main, goes out with the next deploy.

**Changed.** The player toolbar has an Instagram link under Buy Me a Coffee
(`instagram.com/nostalgex_`). It wears the toolbar's own shape rather than the
coffee box's, so the yellow one stays the only button that asks for something.
Checked in a headless browser: the link opens in a new tab with
`rel="noopener noreferrer"`, and nothing else in the toolbar moved.

**Next.** The loading screen's coffee call to action has no Instagram link. Leave
it or match it, owner's call.

## 2026-10-13 (collections that hold shows, on a branch)

**Shipped.** Nothing yet. Branch `collections-with-shows`, merged into main for the next build.

**Changed (on the branch).**

- A server collection of TV shows now becomes a channel, on the Apple TV and the web
  tuner. A Plex collection, or a Jellyfin or Emby BoxSet, can hold shows, and the scan
  threw them away in three places: it read collections from movie libraries only (a Plex
  collection of shows lives in the TV library, so it was never listed), Jellyfin and
  Emby asked the BoxSet for `Movie` only, and the children were matched against an index
  of films only. A collection with fewer than 3 films was then skipped, so a collection
  of shows always read as empty.
- The fix leans on what the library load already holds: every episode of every show.
  Episodes now carry their show's id (`showKey`: Plex `grandparentRatingKey`, Jellyfin and
  Emby `SeriesId`), and a show in a collection expands to its episodes. No extra request.
  A films-only collection is matched, classified, numbered and labelled exactly as before.
- The three servers answer differently, measured: Plex lists the shows (a Plex
  collection is all films or all shows; Plex refuses a film in a TV collection with a
  400). Jellyfin 12.2 lists the series for `IncludeItemTypes=Movie,Series`. Emby 4.10
  answers the same query with the series' episodes. The matcher takes a film id, an
  episode id or a show id, so all three work, and Emby works even on items restored from
  an older snapshot.
- The channel is built and scheduled by the existing code. Episodes are shuffled within
  each show and shows are interleaved two at a time, the same `interleaveByShow` the TV
  channels use. A mixed collection airs its films and its shows' episodes together.
- A collection of shows always lands in OTHER COLLECTIONS. Every episode carries its
  show's title, so the repeated-word rule would have called one show with 30 episodes a
  franchise. A mixed collection is classified on its films alone, which is what the
  films-only scan did. A collection holding shows folds into a franchise only when that
  franchise already airs an episode of each of its shows, so folding never hides episodes.
- No snapshot format bump. `showKey` is an optional field; collection members were
  already stored as indexes into the item list, episodes included. Items restored from a
  snapshot written before this have no `showKey`, so a Plex or Jellyfin collection of shows
  appears after the next library scan rather than at once.

Measured on a real Plex server with a temporary three-show collection (since deleted):
every episode came back with its show key, the old matcher found 0 films and skipped the
collection, and the new scan built it at CH 500 with every episode of the three shows and
a full 24 hour schedule, on the Apple TV code (`LiveCollectionShowsHarness`) and on the
web tuner driven headless, in the same order on both. On the same server every films-only
collection came out identical to the old scan: same members, same fold, same channel
numbers, checked against the old matcher on the Apple TV side and against main's
`nostalgex-collections.js` on the web side. Jellyfin 12.2 and Emby 4.10 lab servers with
synthetic media: a shows-only BoxSet and a mixed one, both skipped before, both built
after (web tuner on the Jellyfin lab only; it has no Emby path).

NostalgexTests: 684 passed, 0 failed, 9 skipped (668 before, plus 16 in
`CollectionShowsTests`; the new live harness skips without a server). `npm test` and
`npm run build` green; collections smoke went from 38 to 55 checks.

**Half-done.** Not on hardware. Not measured against a Jellyfin older than 12.2, which
may answer the BoxSet query like Emby (episodes); the matcher accepts both. The web tuner
has no Emby path, so Emby collections are Apple TV only, as before. A Plex or Jellyfin
collection holding seasons or single episodes rather than whole shows is not handled:
a season key matches nothing.

**Next.** Chad to decide whether to merge. Before release, check one real collection of
shows on an Apple TV, and decide whether a collection dominated by one long show should
interleave differently: once the shorter shows run out, `interleaveByShow` plays the long
one back to back, which is what a TV channel with the same pool does today.

## 2026-10-13 (Jellyfin and Emby: the stall retry replayed the file that stalled)

**Shipped.** Nothing yet. Branch `jellyfin-stall-transcode`, merged into main for the next build.

**Changed.**

- The question left open in the entry below is answered: it was real. When direct play
  gave no picture (watchdog) or starved (starvation ladder), Apple TV asked Jellyfin or
  Emby's PlaybackInfo the same question as the first attempt. For a file the server can
  direct play, the answer is the file. Measured on an 8-bit H.264 MP4 against a local
  Jellyfin 12.2.0 and an Emby 4.10.1.0 server: `SupportsDirectPlay=true`, no
  TranscodingUrl, so `JellyfinPlaybackResolver.resolve` returned `stream.mp4?Static=true`
  and the ladder played the same file again (206, `video/mp4`) under the transcode label.
- What that cost: not a dead end, a wasted rung. By the watchdog's own deadlines, the
  replay got the transcode deadline (20s, 40s for 4K) or a second stall window before
  the 1080p capped rung, so a black picture lasted 15s plus 20 to 40s more, and a
  starving film had to starve twice.
  An MKV was never affected: it does not direct play, so PlaybackInfo always handed back
  HLS. Plex was never affected: its transcode request is always HLS.
- Fix: the retry goes through a new `resolveServerStream`. It sends PlaybackInfo with
  `EnableDirectPlay=false` and `EnableDirectStream=false`, and the resolver never returns
  the static file on a retry (it returns nil, and the service falls back to its
  hand-built HLS stream). Both flags are needed. With only `EnableDirectPlay=false`,
  Jellyfin returns a TranscodingUrl but Emby reports `SupportsDirectStream=true` and
  still none.
- After, with the branch's own body builder and resolver: the retry gets a `master.m3u8`
  TranscodingUrl on both servers (reason `DirectPlayError`), and master, variant, init
  and segments 0 to 2 all answer 200, for the MP4 and the MKV. For the MP4 it is a remux:
  video and audio copied into HLS (Jellyfin's ffmpeg log `codec:v:0 copy`, Emby's session
  `IsVideoDirect` and `IsAudioDirect` true). The first attempt sends exactly the three keys it sent before and still
  direct plays the MP4.
- Web tuner: not affected and unchanged. Its only retry is after a direct play errors,
  and for an MP4 it gets no TranscodingUrl and uses the hand-built HLS fallback, which
  walked 200 on both servers. It has no stall ladder: a stall skips after 8s.
- Tests: `StallRetryServerStreamTests` (10): request body on first attempt and retry,
  both services' requests, the resolver on each measured answer, the offline fallback,
  and Plex unchanged.

NostalgexTests: 682 passed (672 on the branch point plus the 10 new), 0 failed, 8 live
harnesses skipped. `npm test` and `npm run build` green.

**Half-done.** Proven at the HTTP level, not watched on an Apple TV: no forced
no-picture or starvation has been run through the ladder on a device. The forced server
stream is a remux at the same bitrate: it changes the container, not the video or the
bitrate. A file whose video the device cannot decode, or a link too slow for the file,
still depends on the 1080p rung after it, which was not re-measured here.

**Next.** On an Apple TV against Jellyfin or Emby, force a direct-play stall on an MP4
and check the diagnostics line reads "server stream" then plays HLS, not the file.

## 2026-10-13 (Emby fallback stream: every segment refused for want of a PlaySessionId)

**Shipped.** Nothing yet. Branch `emby-playsessionid`, merged into main for the next build.

**Changed.**

- On Emby, the HLS stream Nostalgex builds by hand after a failed direct play never
  played, on Apple TV or in the web tuner. Measured against a test Emby 4.10.1 server on
  8-bit H.264 MKV and MP4 files: master and variant playlists 200, then the init segment
  and segments 0 to 2 all HTTP 400 "Value cannot be null. (Parameter 'key')". Emby writes
  each segment URL as `hls1/main/0.mp4?PlaySessionId=<id>` and nothing else, taking the
  id from the master request. The hand-built master had none, so every segment asked for
  `PlaySessionId=` with no value. Jellyfin copies the whole query string onto segments,
  which is why the same URL plays there.
- Where it bites: a direct play that fails. The web tuner's retry asks PlaybackInfo,
  which returns no TranscodingUrl for a file Emby thinks the browser can play (measured),
  so it falls back to the hand-built URL. Apple TV's `.failed` fallback uses the
  hand-built URL directly, as does any PlaybackInfo request that errors. PlaybackInfo's
  own TranscodingUrl and the 1080p capped rung already carried an id and played.
- Fix: the hand-built URL carries a client-made `PlaySessionId`. Apple TV:
  `EmbyAPIService.buildTranscodeURL(for:sessionID:)`, and the id is tracked so a channel
  change stops that encode, as it does a PlaybackInfo session. Web:
  `NostalgexJellyfinUrls.fallbackHlsUrl`, a UUID where the browser has
  `crypto.randomUUID`, else 32 hex characters (a self-hosted tuner over plain http has
  no secure context). Leaving the parameter off is not an option: it already was off,
  and Emby writes the empty one itself.
- After: master, variant, init and segments 0 to 2 all 200 on the same Emby server, for
  the URLs the Apple TV code builds (both fallback paths, both files) and the URLs the
  built web tuner builds (both id shapes).
- Jellyfin: the Apple TV Jellyfin code is unchanged. The web tuner signs in to Emby as
  Jellyfin and shares one fallback, so that change reaches Jellyfin too. On a local
  Jellyfin 12.2.0 the hand-built URL was all 200 before and is all 200 with the id.
- Tests: `EmbyPlaySessionTests` (4) and 8 new checks in `test:jellyfin-urls`.

NostalgexTests: 672 passed (668 on main plus the 4 new), 0 failed, 8 live harnesses
skipped. `npm test` and `npm run build` green.

**Half-done.** Proven at the HTTP level (playlist and segment statuses), not watched on
an Apple TV or in a browser. The web tuner still never stops a Jellyfin or Emby encode
on channel change (`stopActiveTranscode` returns early for them), so the web id is not
yet used for cleanup.

**Next.** Watch one forced direct-play failure on an Apple TV against Emby. Worth a
measured look: when direct play gives no picture or starves, Apple TV asks PlaybackInfo
for the server stream, and for a file the server calls direct-playable
`JellyfinPlaybackResolver.resolve` returns the same static file rather than an HLS
stream. Seen in the PlaybackInfo responses above, not yet on a device.

## 2026-10-13 (membership generator keeps the cleanup)

**Shipped.** Nothing. Branch `membership-generator-rules`, merged into main.
`channels-memberships.json` on main is untouched.

**Changed.**

- The 2026-10-12 memberships cleanup (5,154 to 4,898 entries) was applied to
  the shipped file by hand, and the keyword tuner only knew the first of its
  three rules. The next regeneration would have put 22 horror-only titles back
  on SCI-FI and dropped 20 real musicals. The tuner now carries all three:
  - Genre gate (cherry-picked from `membership-genre-gate`): recommendation,
    similar and collection claims must match the channel's `genres.include`.
  - `genres.requireAll` from channels.json gates the same claims. SCI-FI's
    Science Fiction is the one that bites. ROM COMS and GIRLS NIGHT opt out
    with `gateRequireAll: false` in exemplars.json, as decided on 2026-10-12;
    applying it there would take 83 and 19 titles off. DATE NIGHT and TRUE
    CRIME also carry requireAll and lose nothing extra to it today.
  - MUSICALS `genreRescueKeywords`: musical, song and dance, broadway. Not
    "based on play or musical", which would add 10 plays (Roxanne, Cyrano de
    Bergerac, On Golden Pond), and not "singing".
- The rule data lives in exemplars.json, the generator's input. channels.json,
  the Swift app and the web filter are unchanged: a manifest claim bypasses
  include and requireAll at runtime, so gating is the generator's job alone.
- `--cache <file>` keeps every TMDB response on disk and `--out <dir>` writes
  somewhere other than the shipped files. A rerun from the cache with no
  network gave the same file apart from the timestamp.
- `npm run test:tuner-gate` (24 checks, in `npm test`) runs the rule function
  against the real rule data. Removing the rescue list, adding the plays
  keyword, dropping the ROM COMS opt-out or ignoring requireAll each fail it.

How it was checked:

- Replaying the cleanup over the pre-cleanup file with the generator's rule
  function gives the shipped content exactly: 4,898 items, 5,593 title and
  channel pairs, every field equal. Not byte-identical, because 5 items list
  their channels in another order and the rescued musicals sit at the end of
  the file, both left by the two-step hand edit. TMDB genres had not changed
  on any of 2,830 titles between 10-12 and today.
- A full live regeneration today gives 3,737 items: 2,146 pairs only in it,
  3,057 only in the shipped file. A control run with the gate off, on the same
  cached TMDB data, accounts for all but one pair:
  - 1,320 STAND-UP claims come from `discover-standup.mjs`, not from the
    tuner, so a full regeneration has to rerun it afterwards.
  - The rest is the candidate set moving: TMDB recommendations, similar lists
    and search matches, and exemplar lists edited since a channel was last
    generated (MIDNIGHT, CULT CLASSICS and BIOPICS each gain 110 to 150). The
    gate-off control differs from the pre-cleanup file by 2,542 and 3,598
    pairs on its own.
  - The one rule difference is Heat on MYSTERY. The hand cleanup gated by each
    entry's single source label, and Heat's says exemplar (it is one on
    another channel), so its MYSTERY claim was never checked. The tuner gates
    per claim, and Heat (Crime, Drama, Action) misses MYSTERY's Mystery rule.
  - No pair the cleanup removed comes back.

**Half-done.** The regenerated file is not committed: it would change about
5,200 title and channel pairs for reasons that have nothing to do with these
rules. Swift tests were not run, since nothing the app reads changed.

**Next.** Chad reviews and merges `membership-generator-rules`; it supersedes
`membership-genre-gate`. Whether to regenerate the shipped memberships at all
is a separate call, and if so, `discover-standup.mjs` runs after the tuner.

## 2026-10-13 (channel guide pages)

**Shipped.** Nothing. Branch `seo/bundle-pages`, draft PR, waiting on Chad's
review of the copy and a legal answer on the brand names.

**Changed.**

- New `/channels` hub and 14 `/channels/<bundle-id>` pages, generated by
  `scripts/build-bundles.mjs` from `channels.json` at build time, so counts and
  channel names cannot drift from the app. Intros (300 to 600 words) and 5 FAQs
  per bundle are hand written in `content/bundles/<id>.md`.
- `scripts/legal-hold.json` holds the four bundles whose channels are all brand
  names (franchises, streamers, kids, arthouse) plus 31 individual channels.
  A held bundle still builds, at `noindex, follow` with an affiliation
  disclaimer, and stays out of the sitemap and llms.txt. A held channel name is
  omitted from every indexed page, including JSON-LD, and the list ends "plus
  {n} more channels in the app". Counts stay true: 131 channels, 14 bundles.
  Deleting an entry from that file releases it on the next build.
- Build checks that fail the build: a dash of any kind in visible copy, a held
  brand name on an indexed page, an intro outside 300 to 600 words, a duplicate
  or over length title or meta description, "Emby" anywhere in the generated
  pages, a banned marketing phrase, and the hard coded 131 in plex.html
  drifting from channels.json. Each one was proved to fire against a scratch
  copy of the tree.
- Page chrome (nav, footer, head, theme boot) moved out of `build-blog.mjs`
  into `scripts/site-chrome.mjs`, imported by both generators. The blog header
  drifted from the global header once before; one copy now. Blog output is
  unchanged apart from the new footer link.
- Channel names on these pages render upper case, as on the homepage lineup and
  in the app. The only presentation change is dropping hyphens (SCI FI, STAND
  UP), because the dash check forbids them in visible copy. `channels.json` is
  untouched.
- `BUNDLE_STYLE` moved to `scripts/bundle-style.mjs`, shared with
  render-lineup.mjs, and gained the missing `tis-the-season` entry.
- Footers across the site link to the channel guide; /plex and /jellyfin each
  got one sentence pointing at it.

**Half-done.** Not measured in Rich Results Test or Lighthouse yet, and not
seen on a Vercel preview. The guide pages drop the Emby footer link to satisfy
the no Emby rule, which leaves /emby live but unlinked from them: that
inconsistency is Chad's call, along with whether /emby stays in llms.txt and
the sitemap at all. Channel pages (`/channels/<number>-<slug>`) are not built;
the channel list markup already carries `data-channel-number` for when they
are. The homepage lineup still does not link to the bundle pages.

**Next.** Chad reads the 14 intros and the legal flags. After merge, request
indexing for /channels in Search Console.
## 2026-10-13 (1.0.26 (48) cut)

**Shipped.** main pushed, which deploys the site and web tuner. Build 1.0.26 (48) archived
and uploaded to App Store Connect, not yet given to any tester group. Build 47 was uploaded
earlier today and will not be distributed; 48 carries everything 47 had plus the franchise
line, iCloud sync, Report Playback v2 and PRs #18 and #21. The 1.0.26 changelog entry stays
`"released": false` until the App Store has it.

**Changed.**

- iCloud sync, tested on two Apple TVs (a 4K 3rd gen and a 4K 1st gen) on one Apple ID.
  Two bugs found that way. Turning sync on used to push that TV's lineup up, so the second
  TV to join overwrote the first; now the first TV seeds iCloud and later ones take what is
  there. And each TV's launch wrote its own bundle list to iCloud (snapshot restore,
  collection categories), so whichever loaded last won; now only a toggle the viewer makes
  is sent. After both fixes: changes crossed in both directions in about a minute with no
  echo back, and both TVs relaunched with identical values.
- Every Settings choice syncs: Stream Quality and Report Playback joined the list. Server
  addresses, sign-ins and the sync switch itself stay on each TV.
- Settings: a package switched on shows BUILDING and "Finding N channels in your library"
  until its channels are in. Before, it read "Not enough content" and dimmed for the
  length of the build, which looked frozen.
- Two quick package toggles ran two builds at once and the second overwrote the first
  package's channels with its stale copy (`BundleBuildTests`: all 6 of the first package's
  channels lost). Builds now queue.
- Web tuner: guide footer drops the "[V] HIDE GUIDE" hint (no key ever handled it).

NostalgexTests: 668 passed, 0 failed. `npm test` green.

**Half-done.** Docker self-host stays on branch `docker-selfhost`, unpublished. It waits
for the web tuner to work well on a phone, since the container serves the same page.

**Next.** Decide TestFlight or straight to App Store review for 48. Attach the three tip
in-app purchases to the 1.0.26 App Store submission. Update the App Store listing copy and
screenshots for this version. Widen the privacy page's Continue Watching wording to cover
the Apple TV app once 1.0.26 is live.

## 2026-10-13 (Web tuner: guide wraps, Blacklist tab gone)

**Changed.** Branch `web-tuner-guide-wrap`, merged into main and live with the 1.0.26 (48)
push below.

- The web guide wraps at both ends. Down on the last channel goes to channel one, Up on
  channel one goes to the last. A wrap centers the landed row, which scrolls the guide to
  that end, so the seasonal invite above channel one shows again. Apple TV is not the
  same: Down on the last channel wraps, but Up on channel one goes to the seasonal row
  and then SETTINGS, on purpose (see `ChannelGuideView.swift`). Left/Right on the web
  and channel up/down on Apple TV already wrapped.
- Settings → Blacklist is removed, and the saved list with it. `plex90_blacklist` is no
  longer read, because titles hidden through a tab nobody can open would stay missing
  for good. The key is left in place in browsers that have one. The tab also trapped the
  keyboard: arriving on it focused its search box, and the tuner ignores keys while an
  input has focus, so Left, Right and Escape stopped working there.

**Verified.** Built site in headless Chromium, with a synthetic 5,000 item library seeded
into the tuner's own library cache (plex.tv and the server stubbed), so the real load path
built a 16 channel guide taller than its pane. Before: Down on the last row and Up on the
first did nothing. After: both wrap in both guide layouts, 35 presses with no pause land
on the right row, Enter after a wrap tunes it. With 300 saved blacklist entries, 0 of
those titles were in any pool before and 278 after, the same 278 a browser with no list
pools. `npm test` green. Not tried with a real server or on a TV browser.

Settings → Help said Up/Down change channel; Left/Right is what does, so Help now says so.

**Next.** Found while measuring, left alone. In fullscreen (F), Up/Down move the hidden
guide cursor and the channel does not change. The guide footer's [V] HIDE GUIDE hint is
gone; no key ever handled V, and the guide has no reason to hide.

## 2026-10-13 (Report Playback rebuilt on PR #18)

**Changed.** w6trp's #18 merged with their commit kept, then folded into the one REPORT
PLAYBACK switch. The owner's rule: report watching, never fill Continue Watching.

- Plex sends position-free timeline reports (#18's idea, PUT, no `time`/`duration`): Now
  Playing shows the title and its playing/paused/buffering state, Plex stores nothing.
  A qualifying watch scrobbles with the bare key; a counted episode's next-up entry is
  removed unless its show was already in Continue Watching. The Plex unscrobble and
  `/:/progress` restore and the film prior-state read are gone.
- Jellyfin/Emby keep the restore. Measured on Emby 4.10.1: position-free start bumps
  PlayCount, and a stop without `PositionTicks` marks the item played.
- From #18 also kept: AVPlayer state feed, background grace for the final stop, the
  `backgrounded` guard, the request-shape and pulse tests. Dropped: the second toggle
  and the reporter that switched the setting off after one failed request. Failures now
  skip pulses (1, 2, 4 ... 30) and never touch the setting.
- Same on the web tuner. Settings copy unchanged on both surfaces.

**Verified.** Live Plex, real tracker code: a 2 minute real-time surf on an unwatched film
showed in Now Playing at offset 0 throughout, cleared on stop, metadata and Continue
Watching (17) unchanged. A counted episode: viewCount 1, no resume point, no next-up
(checked again 5 s on; a control scrobble shows Plex adds one), then unscrobbled back.
Emby surf + counted watch: UserData and Resume back exact. NostalgexTests 662: 654
passed, 8 skipped (live harnesses), 0 failed. `npm test`, `npm run build` green. Not
tested on hardware.

## 2026-10-13 (PR #21 merged for the next build)

**Changed.** `land-pr-21` merged into `ship-franchises` with w6trp's commit kept: the
selected Plex media version and multipart offsets survive into playback. On landing it
kept the single-file snapshot at schema 2; main has since moved to the chunked format,
so the same rule now reads "no bump of `formatVersion` 3" for the new item fields.
`LibrarySnapshotCompatibilityTests` strips the #21 keys from a 1.0.26 chunk file and
from a legacy v2 file and proves both still load; it fails with the format set to 4.
`PlaybackTracker` keeps both `onPlaybackPreparing` (#21) and the background restore
(Report Playback); the rating nudge counter still attaches once per tracker.

NostalgexTests 657: 649 passed, 8 skipped (live harnesses), 0 failed. `npm test`,
`npm run build` green. Multi-version and multi-file playback still needs hardware.

## 2026-10-13 (Report Playback restore and OMDb relay merged for the next build)

**Changed.** `omdb-relay` (with `report-no-cw` and `web-enrichment` under it) merged
into `ship-franchises`. App side only in effect: `WatchStateGuard` restores each
program's prior state on leave, Plex scrobble uses the bare rating key, Emby and
Jellyfin UserData restore, `OMDBService` goes through the relay with the IMDb budget
and 429 day stop. Web conflicts (`plex-tuner.html`, `package.json`, `privacy.html`)
took main's live copies; main already carried the web side.

`privacy.html` still says only the web tuner keeps Continue Watching clean. Update it
to cover the Apple TV app when this build is live, not before.

NostalgexTests 650: 642 passed, 8 skipped (the 3 new `LiveContinueWatchingTests` need a
real server), 0 failed. `npm test`, `npm run build` green. Not tested on hardware.

## 2026-10-13 (franchise line merged for the next build)

**Changed.** `shared-franchises` merged into `ship-franchises` off main 1.0.26 (47).
Conflicts and how they went:

- `LibrarySnapshotStore`: main's chunked v3 format kept. Found franchises ride in
  `meta.json` as rows plus item indexes (`foundFranchiseRows`, `foundFranchiseMovieItems`,
  `foundFranchiseTVItems`), all optional so a 1.0.26 snapshot restores as nothing found
  yet with no rescan. `foldedIntoFranchise` travels on the collection row. Two new
  `LibrarySnapshotChunkedTests` cover both.
- `AppState+Library`: main's background save and index lookup kept, franchises passed
  through. `BundleManagerView` merged clean (RATE "thanks" copy kept).
- Web: main's `api/tmdb.js` (TMDB + OMDb relay, CORS) and smoke test kept; main already
  had the franchise builder, golden file and `franchises.json`.
- Siri stays removed.

NostalgexTests 616: 611 passed, 5 skipped, 0 failed. `npm test`, `npm run build` green.
Simulator smoke with `-uiTestFranchiseFixture`: FRANCHISES and FOUND IN YOUR LIBRARY
render, no NOTABLE STARS. Not tested on hardware.

**Watch.** The iCloud KVS entitlement comes in with this merge (sync is off by default).
The 10-10 entry showed a Release archive signs with it; still no two-TV hardware pass.

## 2026-10-12 (community PRs)

**Changed.** Two fixes from @w6trp landed on main with their commits kept, thanks:

- #19: watchdog verdicts strip URLs and credentials before they reach the system log or
  Settings, so a support screenshot can no longer carry a server token. Kept main's
  verdict line format (no em dashes) with the redaction applied to it.
- #20: music enrichment and channel pools key on the server-qualified item id, so two
  servers that reuse a rating key no longer swap each other's music metadata.

NostalgexTests 495 passed, 2 skipped, 0 failed; web tests green. Not tested on hardware.

**Half-done.** #21 (keep the chosen Plex media version and multipart offsets) is on
`land-pr-21`, not main. It touches playback, so it waits for a hardware pass on a
multi-version title and a three-part film. On landing we dropped its snapshot schema bump
(2 to 3); `LibrarySnapshotCompatibilityTests` proves a pre-#21 snapshot still loads.

## 2026-10-13 (app, build 47)

**Shipped.** 1.0.26 (47) uploaded to TestFlight for beta review. 1.0.25 (46) is still in
Apple's beta review since Oct 9; 47 is reviewed on its own.

**Changed.**

- Tip jar: three StoreKit 2 consumables (Popcorn, TV Dinner, Pizza Night), quantity 1 to
  5, unlocking nothing. Settings shows them as four pixel-art tiles with RATE.
- Rating banner after the third 10+ minute watch, once per version. On hardware the first
  version never received focus; it now uses default focus plus retries after the slide-in
  and lands on RATE. A RATE press stops it for good. tvOS offers no in-app review API.
- Large libraries: the library snapshot was JSON-encoded in one piece on the main thread,
  peaking at 2.6 GB for 400k items, so tvOS killed the app right after the guide appeared
  and the atomic write left no snapshot. It is now saved in 10k-item chunks off the main
  thread with a manifest swapped in last. Measured on an Apple TV 4K (3rd gen): killed at
  400k before, survives after (+26 MB over steady while saving).
- Plex film titles: `parseMovieItem` ran the music-video "Artist - Song" parser on every
  film, so titles with " - " lost their first half and "Spider-Man" became "Man". It now
  runs only for music videos, as the Jellyfin and Emby paths already did.
- Jellyfin direct play requests `stream.mp4`: Jellyfin labels `/stream` by the file name,
  so an MP4 saved as `.mkv` came back as Matroska and the player refused it. The fallback
  HLS URLs also carry `ApiKey`, which Jellyfin 12.2 requires when legacy authorization is
  off. Reproduced and verified on a local Jellyfin 12.2.
- Collection classifier: a collection whose name appears in 2+ of its film titles is a
  franchise.
- Community PRs #19 and #20 by @w6trp merged with their commits.
- Siri channel tuning was built and tested on hardware: tvOS 26 Siri does not hand App
  Shortcut phrases to the app. Removed from this build; parked on `siri-intents`.

**Half-done.** PR #21 waits on a hardware test. The 1.0.27 line (franchise bundle,
iCloud opt-in, enrichment in the app, Report Playback rebuilt on PR #18) is on branches.
Emby's fallback HLS still fails on an empty `PlaySessionId`.

**Next.** Watch 47 through beta review; hardware-test PR #21; start 1.0.27.

## 2026-10-11 (web tuner)

**Shipped.** nostalgex.app: the web tuner now reads the shared metadata cache, fills
misses through the TMDB relay, and builds server collections as channels. Report
Playback on the web no longer fills Continue Watching. No app release.

**Changed.**

- The web tuner never attached enrichment to items, so every enrichment-gated channel
  was empty or thin on the web. It now batch-reads the shared Supabase cache by TMDB id,
  looks up misses through `api/tmdb.js`, and writes them back. On a test library of about
  11,600 items: SPY GAMES 0 to 59, TOON TOWN 0 to 44, MUSICALS 43 to 57, TEEN MOVIES 14
  to 21, BIOPICS 13 to 18, MIDNIGHT 1 to 6, TRUE CRIME 0 to 1.
- Plex items on the web had no TMDB id at all (the scan never asked Plex for guids, and
  episodes did not inherit the show's id). Now about 90% carry one. Old library caches
  are refused once so browsers rescan.
- The relay accepts `X-Nostalgex-Client: web`, answers CORS preflight, and echoes the
  origin only for nostalgex.app, www and localhost:5173. Other origins are blocked.
- Server collections air on CH 500-699; ones that duplicate a stock franchise channel
  fold out.
- Report Playback: Plex never counted a Nostalgex watch, because `/:/scrobble` with
  `key=/library/metadata/{id}` returns 404; it now sends the bare rating key. On leaving a
  program the tuner puts it back the way the server had it (Plex: unscrobble, progress
  restore, or remove from Continue Watching; Jellyfin/Emby: PlayedItems and UserData
  restore). Verified live on Plex and Emby, Jellyfin against a local server.
- Privacy page: the web tuner's metadata lookups and the Continue Watching promise.

**Half-done.** The same enrichment, collections, franchise bundle and Continue Watching
fix are on the app's 1.0.27 line, not released. FOREIGN FILMS and CULT CLASSICS stay
thin on both surfaces: they gate on IMDb ratings and OMDb is not relayed yet. The
franchise Found list is not wired into the web tuner's settings yet.

**Next.** OMDb through the relay; a generated membership file places the Pirates of the
Caribbean films on MARVEL, fix in the generator.

## 2026-10-11 (playback diagnostic credential redaction)

**Changed.** Watchdog verdicts now remove complete URLs and credential assignments before unified logging or UserDefaults persistence. Error-log URL tails are no longer copied because truncation can remove a token's identifying key while leaving its secret value. Legacy verdict rows are discarded instead of migrated. Diagnostic status codes and playback measurements remain readable.

**Validation.** Regression fixtures cover URL userinfo/query credentials, relative URLs, quoted headers and JSON keys, bearer authorization, percent-encoded forms, direct persistence inspection, and legacy row cleanup. Xcode 27 / tvOS 27 native suite passed 437 tests, with 2 optional live tests skipped and no failures.

**Half-done.** This is scoped to playback verdicts; it does not claim that every unrelated log producer has been audited. No server, account or credential settings changed.

**Next.** Upstream review. The change is isolated on `fix/redact-playback-diagnostics`; no merge or deployment is included.

## 2026-10-11 (server-qualified music cache identity)

**Changed.** Music enrichment and channel-pool refresh now use the existing server-qualified item identity instead of a server-local rating key. A new disk-cache filename avoids assigning ambiguous legacy rows to a server. Music display copies preserve server routing and playback compatibility fields, and non-music items do not receive cached music metadata.

**Validation.** Regression fixtures exercise two servers with the same rating key in both orders, disk reload, legacy cache isolation, non-music collision, and routing/codec fields through both music-copy paths. Xcode 27 / tvOS 27 native suite passed 441 tests, with 2 optional live tests skipped and no failures.

**Half-done.** This branch covers native music enrichment and pool identity. It does not include unrelated guide, metadata-provider or playback recovery changes.

**Next.** Upstream review on `fix/server-qualified-music-cache`. No merge or deployment is included.

## 2026-10-11 (OMDb through the relay, branch only)

**Shipped.** Nothing. Branch `omdb-relay`, cut from `report-no-cw` with
`web-enrichment` merged in, not merged, not deployed.

**Changed.** Nothing on `main`.

**Half-done.** On `omdb-relay`, both surfaces:

- FOREIGN FILMS (imdbRatingMin 6.5, imdbVotesMin 5000) and CULT CLASSICS
  (imdbVotesMin 30000) need IMDb values, and the shared Supabase cache had
  `imdb_rating` / `imdb_votes` empty on every row: the App Store build carries
  no OMDb key, so it never asked. `api/tmdb.js` now also answers
  `path=omdb/{imdbID}` (`tt` plus 7 to 9 digits only) with `OMDB_API_KEY`, same
  client header rule, CORS allowlist and Vary. Edge cache 7 days, stale for 30.
  OMDb's daily-limit answer (HTTP 401 "Request limit reached!") becomes a clean
  429; "Response: False" answers pass through uncached. No ids are logged.
- `OMDBService` works like `TMDBService`: direct with a key, else the relay.
  `EnrichmentService` now fetches TMDB first and decides OMDb afterwards.
- Quota. OMDb free is 1,000 a day for every device together, so a title is only
  looked up when it could land on an IMDb-gated channel: same media type plus a
  keyword or genre from that channel's rules (gates derived from channels.json,
  `OMDBGate`). At most 50 lookups per library load, random order, so repeat
  loads walk through different titles. After a 429 the device stops asking until
  the next UTC midnight (`OMDBBackoff`, UserDefaults; localStorage on the web).
- Web (`scripts/nostalgex-enrichment.js`): same gates, cap and backoff, 4 in
  flight, upsert back with the OMDb columns only. The IMDb id comes from the
  shared row or the TMDB movie document (`imdb_id`), never the server, so IMDb
  ids now leave the browser alongside TMDB ids.
- Tests: `OMDBRelayTests` (17), relay smoke and enrichment smoke extended.
  A local relay call for tt0133093 with the real key returned 200, rating 8.7.

**Next.** Set `OMDB_API_KEY` on Vercel before deploying the relay. A one-off
backfill of the gated candidates would fill the cache faster than 50 per load.

## 2026-10-11 (Report Playback never fills Continue Watching, branch only)

**Shipped.** Nothing. Branch `report-no-cw`, cut from `shared-franchises` at
`db9b26b`, not merged, not deployed.

**Changed.** Nothing on `main`.

**Half-done.** On `report-no-cw`, both surfaces, all three servers:

- Turning on Report Playback is meant to mean "my server sees what's playing and
  a real watch counts", not "every channel I surf past lands in Continue
  Watching". The tracker now reads the item's state before its first report and
  puts it back when the session ends: unscrobble for a never-watched item,
  `/:/progress` back to the user's own resume point, `removeFromContinueWatching`
  for a watched one; on Jellyfin/Emby a mark-unplayed or a `UserData` write of
  the prior values. Details and the measured server behaviour are in
  `Nostalgex/docs/plex-session-reporting.md`.
- Every report and cleanup goes through one serial queue, because Plex writes a
  resume point on every timeline report (measured: the first `playing` report
  puts the item in Continue Watching), so ordering decides whether the cleanup
  sticks.
- Plex scrobbles never counted: `/:/scrobble?key=/library/metadata/{rk}` is a
  404; only the bare rating key works. Fixed on both surfaces. After a scrobble
  the tracker reports position 0, since any real position re-creates a resume
  point on the item Plex just marked watched.
- Jellyfin and Emby count a play on the *start* report, so a 30 second surf
  used to add a play (and feed the rewatch channels). The restore puts the prior
  PlayCount back; a counted watch ends as prior + 1.
- Settings copy on both surfaces: "Off by default. When on, your server sees
  what's playing and a film you watch most of counts as watched. Channel
  surfing never fills your Continue Watching." The warning line is gone.
  Privacy page wording updated, effective date moved to October 11.
- The decision table is shared through `scripts/watch-cleanup-golden.json`
  (16 cases), read by `WatchStateGuardTests` and `npm run test:watch-state`.
- Verified against a real Plex server, an Emby 4.10.1 server and a local
  Jellyfin 12.2 test server by running the real tracker on a fake clock
  (`LiveContinueWatchingTests`, skipped unless `TEST_RUNNER_NOSTALGEX_LIVE_*`
  is set): Continue Watching / Resume identical before and after, item state
  restored exactly. The web module was run against the same three servers from
  node. The web tuner itself was not driven in a browser.
- Not verified: Jellyfin/Emby Next Up after a counted episode (no TV library on
  either test server). Left alone on purpose: it is a separate row there, and a
  counted episode is a real watch. Closing the web tab mid-program cleans up with
  `keepalive` requests that are not ordered; best effort.

**Next.** Review and merge `report-no-cw`. Then an on-device check with
reporting on: surf ten channels, open Plex, Continue Watching unchanged.

## 2026-10-11 (shared franchise dictionary, web port, branch only)

**Shipped.** Nothing. Branch `shared-franchises`, cut from `franchise-polish`
at `188d60d`, not merged.

**Changed.** Nothing on `main`.

**Half-done.** On `shared-franchises`:

- The 18 franchise definitions moved out of `FranchiseDictionary.swift` into
  `franchises.json` at the repo root, next to `channels.json`, so the web tuner
  can use the same editorial list instead of a copy that drifts. It is bundled
  the way `channels.json` is: a symlink in `Nostalgex/Nostalgex/` excluded from
  the synced group, copied by the "Sync channel config" build phase, and
  `public/franchises.json` for the Vite build. A Swift harness compared the
  decoded file with the old hard-coded table field by field: identical. The
  ids carry a `verified: 2026-10-11` header and a per-entry `note`.
  `FranchiseDictionary` keeps its API (`all`, `byCollectionID`,
  `defaultOnIDs`, `isOn`, `cleanFranchiseName`); a missing or broken file logs
  a CONFIG line and leaves the dictionary empty rather than crashing.
- `scripts/nostalgex-franchise-builder.js` is a port of
  `FranchiseChannelBuilder` (same module style as the daily manifest, works as a
  plain browser script and in node). It is standalone: `plex-tuner.html` does
  not load it yet, because that file was being changed on another branch.
- `scripts/franchise-golden.json` holds 13 library cases plus title-key,
  film-match and server-collection vectors (36 checks). The Swift
  `FranchiseGoldenTests` and the node `npm run test:franchises` both read it,
  so a rule changed in one engine fails the other's test.
- Three spots in the Swift builder depended on dictionary iteration order, which
  Swift does not keep stable, so the web port could not match them: which found
  franchise a TV show joins when two names match (now the lower collection id),
  the order of two dynamic channels with the same name (now by stable id), and
  which stock channel a server collection maps to when two qualify (now the
  lower channel). None changes a library where only one answer was possible.

7 new Swift tests; full `NostalgexTests` 598 passed, 0 failed, 2 skipped (the
two live harnesses). `npm test` and `npm run build` pass, and
`dist/franchises.json` and the built `Nostalgex.app/franchises.json` are both
present. Not run on a device or against a real library.

**Next.** Wire the builder into `plex-tuner.html` once the enrichment work there
lands: fetch `/franchises.json`, call `NostalgexFranchiseBuilder.build` with
items carrying `enrichment.franchiseID` and `franchiseName`. Then merge
`franchise-polish` and this branch together.

## 2026-10-11 (web tuner: TMDB enrichment and server collections, branch only)

**Shipped.** Nothing. Branch `web-enrichment`, cut from `franchise-polish` at
`188d60d`, not merged, not deployed.

**Changed.** Nothing on `main`.

**Half-done.** On `web-enrichment`:

- The web tuner had no enrichment, so every keyword, network and production
  company rule only matched through the membership manifest. It now does what
  EnrichmentService.swift does: dedupe to TMDB ids, read the shared Supabase
  cache in chunks of 200, fetch the misses through `api/tmdb.js` six at a time,
  parse exactly as `TMDBService.parseResponse`, upsert back with
  `resolution=merge-duplicates`. Only TMDB ids leave the browser; the upsert
  names its TMDB columns so it never touches OMDb columns an Apple TV wrote. A
  per-browser IndexedDB copy (7 days, TMDB 404s for 1 day) means a reload asks
  nothing. The guide is built first and rebuilt when enrichment lands.
- Plex items on the web carried no TMDB id for libraries on Plex's current
  agents: the section scan never asked for `includeGuids=1`, and episodes read
  their own guid instead of the show's. Both now match tvOS. The library cache
  is versioned so an old id-less cache is refused once.
- The relay accepts `X-Nostalgex-Client: web`, answers preflights, and echoes
  `Access-Control-Allow-Origin` only for nostalgex.app, www.nostalgex.app and
  localhost:5173.
- Server collections become channels: Plex section collections, Jellyfin and
  Emby BoxSets, 3+ movies, alphabetical, CH 500-699 capped at 200, switched on
  under Settings, BUNDLES, MY COLLECTIONS. Stock-duplicate warnings match the
  app. Collections that duplicate a stock franchise channel fold out using the
  app's name, manifest and pool-overlap signals; the franchise-dictionary
  signals and the FRANCHISES / OTHER COLLECTIONS split are not ported.
- Measured on a test Plex library of 11,656 items (10,488 with a TMDB id,
  1,926 unique): 1,926 Supabase hits on a warm cache, 132 relay fetches on a
  colder one, 36 channel pools changed, about 10s after the guide was up. A
  reload made no Supabase or relay requests. Pool sizes without and with
  enrichment: TEEN MOVIES 14 to 21, MUSICALS 43 to 57, BIOPICS 13 to 18,
  MIDNIGHT 1 to 6, TOON TOWN 0 to 44, SPY GAMES 0 to 59, TRUE CRIME 0 to 1,
  FOREIGN FILMS 2 and CULT CLASSICS 4 unchanged. The last two need OMDb values
  and the shared cache holds none (0 of about 2,100 rows), so they stay as thin
  on Apple TV.
- Not checked against Emby or Jellyfin servers with real credentials; the
  BoxSet calls are unit-tested only. The 9-channel parity with the app is a
  rule-by-rule read of `AppState+Channels.swift`, not a side-by-side run.

**Next.** Set `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` on Vercel before
merging, and deploy the relay with the tuner. `channels-memberships.json`
claims all five Pirates of the Caribbean films for CH101 MARVEL and X-Men for
CH65 BIOPICS; both surfaces read it, so the web folds a Pirates collection into
MARVEL just as the app would. The privacy page does not yet say the web tuner
talks to Supabase and the TMDB relay.

## 2026-10-11 (franchise numbers, Marvel TV, default-on franchises, branch only)

**Shipped.** Nothing. Branch `franchise-polish`, cut from `stock-fold` at
`be67d61`, not merged.

**Changed.** Nothing on `main`.

**Half-done.** Three changes on `franchise-polish`:

- Runtime channel numbers collided. Found franchises numbered from 220 and
  OTHER COLLECTIONS from 260, so a library with 86 three-film franchises under
  ADD ALL ran franchise numbers to 305 and two rows shared a number,
  interleaved in the guide (it sorts by number). Ids were never the problem
  (they live at 1,000,000+). Franchises now take CH 300-499 and collections
  CH 500-699, each a hard cap of 200: enabled items past the end are not built,
  the log says how many, and Settings shows one quiet line under FOUND IN YOUR
  LIBRARY only when the franchise range is full. Saved choices are ids, never
  numbers, so nothing a viewer switched on is lost; a stale row from an old
  snapshot is rebuilt on the new number. channels.json is untouched (1-140,
  music videos 200-213). The web tuner builds no collection or franchise
  channels at all, so it needed nothing.
- MARVEL (CH101) now carries TV. Its films stay with the `studios` rule; shows
  join by exact title only (case and punctuation ignored, so "What If...?",
  "What If…?" and "S.H.I.E.L.D" without the last dot all match, and "Echo"
  cannot take "Echo Park"). The list covers the Disney+ MCU shows, the Netflix
  era and the ABC era, plus the "Marvel's ..." spellings older agents use. It
  is editorial and can be trimmed in `FranchiseDictionary.swift`.
- STAR TREK and FAST & FURIOUS start switched on (`defaultOn`). An explicit
  off is kept in `nostalgex_disabled_franchises`, which iCloud sync carries
  next to the enabled list, so a viewer who removed one does not get it back
  on the next rescan, relaunch or other Apple TV. No films, no channel, same
  three-film gate as before.

16 new tests; full `NostalgexTests` 591 passed, 0 failed, 2 skipped (the two
live harnesses). Not run on a device or against a real library.

## 2026-10-11 (stock franchise channels mix movies and shows, branch only)

**Shipped.** Nothing. Branch `stock-fold`, cut from `enrichment-proxy` at
`3c1a2ed`, not merged.

**Changed.** Nothing on `main`.

**Half-done.** CH100-106 built their pools from the channels.json rule alone,
and six of the seven rules say `type: movie`. The franchise builder already
placed The Mandalorian and Andor under STAR WARS and Rings of Power under LORD
OF THE RINGS, but Settings only showed that as a greyed "ON CH 100" label; the
episodes never aired. On `stock-fold` a stock channel's pool is its rule's pool
plus the covered franchise's movies and shows, deduped by item id, while the
FRANCHISES package is on. Manifest locks and exclusive rules still win, so an
item another channel owns is not taken. The covered row now reads "3 movies,
2 shows on CH 100". Swift only: the web tuner has no franchise dictionary and
keeps the rule-only pool. 4 new tests, full `NostalgexTests` 575 passed,
0 failed. Not run on a device or against a real library.

Known limit: a classic whose rule matches fewer than `minItems` (3) films is
never built, so two Star Wars films plus The Mandalorian still give no CH100.

## 2026-10-11 (TMDB proxy and Supabase key plumbing, branch only)

**Shipped.** Nothing. Branch `enrichment-proxy`, cut from `icloud-opt-in` at
`42320a5`, not merged.

**Changed.** Nothing on `main`.

**Half-done.** No build has ever carried the TMDB, Supabase or OMDb values, so
every install logs `[Enrichment] Skipping: API keys not configured` and the
channels that lean on enrichment stay empty. `enrichment-proxy` turns the layer
on without shipping the TMDB key:

- `api/tmdb.js`, a Vercel function next to `subscribe.js`. GET with `?path=`
  restricted to `movie/{id}`, `tv/{id}`, `collection/{id}` and
  `search/collection` (numeric ids only, anything else is a 400). It adds the
  key from the `TMDB_API_KEY` env var, adds `append_to_response=keywords` for
  movie and tv, and returns TMDB's JSON and status. A 200 carries
  `Cache-Control: public, s-maxage=86400, stale-while-revalidate=604800` so
  Vercel's edge cache absorbs repeats; anything else is `no-store`. It requires
  `X-Nostalgex-Client: tvos` (403 without it), a cheap filter, not security, and
  logs nothing. `npm run test:tmdb` covers the allowlist and the handler with a
  stubbed fetch (48 checks) and is part of `npm test`.
- `TMDBService` gains a proxy mode. With an empty key it calls
  `https://www.nostalgex.app/api/tmdb?path=movie/{id}` with the client header
  and no key in the URL; with a key it keeps calling TMDB directly, for dev
  builds. `TMDBConfig.tmdbProxyURL` holds the base. The document is the same
  either way, so `parseResponse`, franchise fields included, is untouched.
- `EnrichmentService` proceeds when a key or the proxy is available but still
  requires the Supabase URL and anon key, since the shared cache is the point.
  The skip log names what is missing:
  `[Enrichment] Skipping: missing supabase url, anon key`.
- Supabase values arrive through an xcconfig. `Nostalgex/Config.xcconfig`
  (committed) is the app target's base configuration for Debug and Release; it
  defaults both values to empty and does `#include? "Secrets.xcconfig"`.
  `Nostalgex/Secrets.example.xcconfig` is the template, `Secrets.xcconfig` is
  gitignored, and `Info.plist` maps `SUPABASE_URL` and `SUPABASE_ANON_KEY` to
  `SupabaseURL` and `SupabaseAnonKey`. A missing base configuration file is a
  hard xcodebuild error (measured: exit 65, "Unable to open base configuration
  reference file"), which is why the committed file sits in between.

Verified: `NostalgexTests` passes with no `Secrets.xcconfig` on disk (573 tests,
571 passed, 2 skipped live harnesses, 13 new in `TMDBProxyTests`) and the built
Info.plist carries empty Supabase strings. With a dummy `Secrets.xcconfig` using
`https:/$()/host`, the built plist reads `https://host` with both slashes. The
function called locally against real TMDB returns `movie/603` with
`belongs_to_collection` and 18 keywords, `tv/1399` with keywords and networks,
and rejects `person/1` with 400 and a missing header with 403. `npm run build`
passes. Not run on a device or simulator against the live function: nothing is
deployed yet.

**Next.** Set `TMDB_API_KEY` on the Vercel project and deploy so `/api/tmdb`
exists. Put the real Supabase URL and anon key in a local `Secrets.xcconfig`
before the next archive. Then rescan on a device and watch for
`[Enrichment] TMDB via site proxy` followed by the cache and save counts. The
README's "What leaves your network" now names the proxy hop; the privacy page
covers TMDB lookups in general terms but does not name nostalgex.app as a hop,
worth a line before that build ships.

## 2026-10-10 (iCloud sync, now opt-in, branch only)

**Shipped.** Nothing. Branch `icloud-opt-in`, stacked on `franchise-ui`, not merged.

**Changed.** Nothing on `main`.

**Half-done.** `icloud-sync` mirrored lineup and display preferences through
iCloud key-value storage from the first launch, and whichever Apple TV launched
first seeded the household. That is the wrong default for a household where one
TV has a curated lineup and another is a fresh install, so `icloud-opt-in`
carries the same two commits on top of the franchise work and adds a switch:

- SYNC WITH MY OTHER APPLE TVS, under DISPLAY in Settings. Off by default. The
  flag (`nostalgex_icloud_sync_enabled`) is per TV and is never itself synced.
- While off, nothing reads or writes the ubiquitous store: launch neither pulls
  nor seeds, Settings changes stay local, and incoming change notifications are
  ignored. A fake store in the tests counts reads, writes and synchronize calls
  and asserts all three stay at zero.
- Turning it on pushes this TV's current preferences first (this TV wins),
  adopts cloud values only for keys this TV has never set, then starts
  listening. Turning it off stops listening and leaves iCloud and the local
  values as they are. A TV that turns it on later follows the same rule.
- The found-franchise switches (`nostalgex_enabled_franchises`) join the synced
  set. The never-sync list in the tests now also names the switch itself, the
  rating nudge counters and the tip ledger, next to credentials, server
  address, stream quality and playback reporting.

Cherry-picking onto `franchise-ui` conflicted only in `AppState+Channels.swift`
(the franchise branch had renamed `materializeCollectionChannels` to
`materializeDynamicChannels`); the sync code now calls the new name.

Verified: the full `NostalgexTests` run passes (557 tests, 37 of them for the
sync service and its merge rules). A Release archive signed through the App
Store Connect key carries `com.apple.developer.ubiquity-kvstore-identifier`,
and a local App Store export with automatic signing produces an IPA whose
distribution profile includes it; nothing was uploaded. Not yet tried on
hardware: two real Apple TVs on one Apple ID flipping the switch.

**Next.** Hardware round trip with two TVs: switch on with different lineups,
confirm the first TV to switch on wins, then flip one off and confirm nothing
moves. Then merge order: `franchise-data`, `franchise-channels`, `franchise-ui`,
`icloud-opt-in`.

## 2026-10-10 (franchise bundle, branch only)

**Shipped.** Nothing. Everything below is on branches off `main`, not merged.

**Changed.** Nothing on `main`.

**Half-done.** The FRANCHISES package is being rebuilt in three phases, each on
its own branch stacked on the last:

- `franchise-data` (Phase 0): enrichment rows gain `franchise_id` and
  `franchise_name`, parsed from TMDB `belongs_to_collection` with no extra
  request. The two columns are added by `Nostalgex/docs/franchise-migration.sql`,
  which has NOT been applied to the shared table yet, so live enrichment still
  carries no franchise fields. Rows without the columns decode fine.
- `franchise-channels` (Phase 1): `FranchiseChannelBuilder` turns a library plus
  its enrichment into a franchise list. Three or more owned films sharing a
  TMDB collection make a channel; `FranchiseDictionary` merges split
  collections (Star Trek is three on TMDB), folds known franchises into the
  stock classics CH100-106, and adds TV by title (The Mandalorian under STAR
  WARS). Films TMDB leaves outside any collection (Rogue One, Solo, Bumblebee,
  Rise of the Beasts, all checked against the live API) join dictionary
  franchises by title. Marvel stays studio-ruled, never grouped by collection.
  Every dictionary id was verified live on 2026-10-10.
- `franchise-ui` (Phase 2, this entry): the Settings half. Under the FRANCHISES
  package row, when it is on, FOUND IN YOUR LIBRARY lists each found franchise
  with a switch, ADD ALL and REMOVE ALL, and the ones a classic already covers
  greyed as "ON CH 100". Found franchises default off so a big library does not
  flood the guide. Switches persist as a plain string array under
  `nostalgex_enabled_franchises`, keyed by dictionary name or TMDB collection
  id, so a later iCloud sync can carry it unchanged. A switched-on franchise is
  a dynamic channel (`rules == nil`) in the collection range (numbers from
  220), shown while the package is on; the schedule engine and playback are
  untouched. A server collection that is really one of these franchises is
  folded: credited under the franchise, hidden from MY COLLECTIONS, never
  materialised twice (`FranchiseCollectionFold`, reusing the scan's name and
  manifest signals plus a 60% item overlap). NOTABLE STARS is gone; actor and
  director sets classify as OTHER COLLECTIONS, a persisted `collections-actors`
  id migrates, and older snapshot rows resolve. Full `NostalgexTests`: 521
  passed, 2 skipped (pre-existing), 0 failed.

  Verified on the tvOS 26.1 simulator through a test-only launch argument,
  `-uiTestFranchiseFixture`, which layers an enriched sample library over demo
  mode (six franchises, two sample collections) because the shared table has
  no franchise columns yet. Not verified: the real enrichment path end to end,
  which needs the migration applied; a relaunch from a snapshot that carries
  found franchises; the fold against a real server's collections.

**Next.** Apply the migration, then load a real library and compare the found
list against what the library actually holds before merging. Decide whether
STAR TREK and FAST & FURIOUS become stock classics or stay found-only. Merge
order: `franchise-data`, `franchise-channels`, `franchise-ui`.

## 2026-10-11 (selected Plex version and multipart position)

**Changed.** Plex items retain the selected media index, complete part descriptors and exact duration. Decision/start/recovery requests use that media and part instead of always requesting index zero. Later parts keep the remaining stack and their own codec facts. A whole-film tune offset maps to the correct part and local offset when every part duration is available. Part changes keep one tracker and pause its clock during loading. Library snapshots keep schema 2 (changed on landing): an older snapshot decodes the new fields as version 0, part 0 and no part lengths, which is the previous behaviour, until the next full library scan fills them in. That avoids forcing every user to rescan.

**Validation.** Regression coverage checks whole-film offsets, third-part continuity, per-part SDR/codec facts, persistence and transcode query identities. Xcode 27 / tvOS 27 native suite passed 440 tests, with 2 optional live tests skipped and no failures.

**Half-done.** Unknown part lengths retain the existing offset fallback; this does not infer missing server metadata. Real multi-version and multi-file direct/HLS playback still needs hardware acceptance. Codec policy, heartbeat reporting and unrelated recovery fixes are excluded.

**Next.** Upstream review on `fix/preserve-plex-media-parts`; verify recognizable multi-version and three-part files on hardware before treating playback acceptance as complete.
## 2026-10-11 (Plex heartbeat-only activity)

**Shipped.** Prepared on `feature/plex-heartbeat-only` against upstream `c2f32e6`. No release, store upload or upstream merge.

**Changed.** Added a separate opt-in Plex Heartbeat Only setting, mutually exclusive with History & Resume. Existing history preferences and reporting endpoints remain intact. Heartbeat POSTs carry the item key, playback state and exact session header, with no time, duration or watched/scrobble operation. AVPlayer state feeds heartbeat updates. Reporting continues until disabled or a request fails; there is no elapsed-time cutoff or title-count limit.

Each server's heartbeat queue preserves playing/stopped order and tracks only the sessions it opened. Channel changes, disable and disconnect close those exact sessions. Reactivation waits for earlier cleanup and uses a fresh identity. Normal backgrounding requests bounded OS time for stop delivery; it cannot promise delivery after force-quit, network loss or OS expiration. A failed request stops further activity updates and makes one bounded cleanup attempt without stopping the stream. No account permissions, tokens, telemetry, app identifiers, artwork or branding are changed.

**Validation.** Xcode 27 / tvOS 27 simulator suite: 447 passed, 2 optional live harnesses skipped. Eleven new tests cover exact request fields, ordering, disable during an in-flight request, background/foreground, tracker release, rapid reactivation, failure cleanup, exclusive settings, and 100 consecutive pulses without an artificial count cutoff. Pulsed tests are not a real-time sustained playback measurement.

Earlier short hardware experiments using the same position-free timeline approach observed unchanged watch count, resume offset, last-viewed time and history digest, plus stopped-session cleanup. Those experiments used separate instrumentation and do not certify this exact upstream branch or general server behavior.

**Half-done.** Sustained playback beyond ten minutes, completion, delayed persistence, network failure and force-quit remain unverified on this branch. A draft PR should remain explicit about that gap. No claim of guaranteed history suppression is made.

**Next.** With an owner-approved hardware window, capture baseline stored fields/history for selected titles, watch one title at least eleven minutes, switch twice, disable heartbeat while leaving playback running, then re-enable and exit to Home. Verify activity remains present past minute ten, outgoing sessions clear, and stored fields/history match the baseline after stopping and a later read. Keep History & Resume off and never reset history.

## 2026-10-09 (app)

**Shipped.** Nothing to Apple. 1.0.24 (45) is still in TestFlight beta review.
`main` now carries 1.0.25 (46), not archived or uploaded.

**Changed.**

- Jellyfin and Emby connect forms have a FIND SERVERS ON MY NETWORK button
  (`LANServerDiscovery.swift`). UDP 7359, `who is JellyfinServer?` and
  `who is EmbyServer?`, three second listen, deduped by server id, kind taken
  from which probe the server answered. Measured before writing it: the Emby
  under test answered the subnet directed broadcast and ignored
  255.255.255.255, so the app sends to both, computing the directed broadcast
  from every live IPv4 interface. Network.framework could not receive the reply
  (a connected UDP socket drops datagrams from the server's unicast address),
  so it is a BSD socket with SO_BROADCAST. No system prompt seen in the tvOS 26
  simulator; `NSLocalNetworkUsageDescription` now names all three servers in
  case hardware asks. Jellyfin side verified only as far as the parser, no
  Jellyfin server was on the test network. Plex skipped on purpose: that form
  has no address field.
- The Plex to Emby switch bug from the 2026-10-08 entry is fixed, and the cause
  was not either suspect named there. It was a race: a stale snapshot starts a
  background Plex refresh at launch, which on a large library runs for minutes;
  the user disconnects and signs into Emby meanwhile; Emby's scan finishes
  first; then the Plex scan returns and, with nothing checking that its sign-in
  still exists, rebuilt every pool from Plex items and saved the snapshot under
  the Emby identity. That poisoned snapshot is why it survived relaunch. The
  harness (`BackendSwitchScheduleTests.swift`) showed the clean switch passing
  on the old code and the race failing with "CH 7 VHS VAULT schedule would send
  18 Plex key(s) to Emby". Fix: a session generation bumped on Disconnect or a
  server change, checked before every commit in `loadLibrary` and used to abort
  the remaining requests; items from servers not signed in are dropped at load;
  a snapshot holding such items is refused on launch and rescanned; playback
  skips a foreign item with the failure card instead of sending the server a
  request it will answer 500. Disconnect now also clears today's manifests and
  the collection scan. Behaviour change: disconnect and re-sign-in to the same
  server reshuffles today's guide.
- Settings: Connection moved above Display and took in the report-playback
  switch (it had its own section). The two subtitle switches became one
  SUBTITLES row cycling Off, Foreign audio, Always: the fullscreen switch only
  ever overrode the foreign-audio one, so they were one three-way setting.
  Subtitle language only shows when subtitles are not Off. The Buy Me a Coffee
  and update-email QR codes are gone from Settings, with their analytics event.
  The in-player panel still has separate CC and auto buttons.
- `NostalgexTests`: 436 passed, 0 failed, 2 skipped on the merged tree
  (417 before, 9 discovery, 9 backend switch, 1 moved).

**Verified on hardware** (Apple TV 4K, first generation): RESCAN LIBRARY on a
Plex library of about 11,600 items, Disconnect mid scan, then Emby found via FIND
SERVERS. The log read "sign-in changed while the scan was running, discarding its
results", the Emby library loaded, and five programmes played with no HTTP 500s.
The automatic background refresh that started the original report was not
reproduced (the snapshot was only hours old) but runs through the same check. No
local network prompt appeared; a clean install is still the true first press.
A 4K HEVC title with EAC3 audio that stalled in the simulator played cleanly.

**Next.** 46 to TestFlight. App Store
listing for the next submission: "131 themed channels across 14 bundles" and
new screenshots. Discussion #2 (Fire TV fork): ordering and DayPacker ports match
the JS reference byte for byte; the channel filter does not (22 channels
diverge), asked the contributor for filter golden vectors in `scripts/` before
deciding where it lives. Discussions #8 (Roku) and #14 (languages) are
unanswered.

## 2026-10-09

**Shipped.** nostalgex.app: the four SEO blog drafts and table styling (#15),
then site wide SEO and speed work (#16). The buddy cop post went live a day
early; the other drafts each moved up a day (Oct 12, 14, 16, 19, 21) and still
need their `draft: true` removed on the day. No app change.

**Changed.**

- Hero text no longer waits for JavaScript. `.hero-copy` (and `.hero-shot`) on
  `/`, `/plex`, `/jellyfin` and `/emby` lost the `reveal` class, which kept them
  at opacity 0 until `app.js` ran. That was most of the mobile LCP.
- Hero media is lighter and off the critical path. New poster
  `guide-hero-1280.webp` (54 KB, was 511 KB) is preloaded; the video is
  `preload="none"` and `app.js` starts it after `load`, never under reduced
  motion or Save Data. New encodes: 480p mp4 412 KB (phones), 1600 webm 1.46 MB
  and 1280 mp4 1.37 MB (desktop). Old files stay for one release so cached
  pages don't 404. Screenshots below the hero get 1280 and 1920 `srcset` sizes.
- Lighthouse mobile, local static build, same machine before and after: `/`
  went 71 to 96 (LCP 6.3 s to 2.4 s, 1,068 to 745 KiB), `/jellyfin` 74 to 94
  (LCP 8.1 s to 2.3 s). Not yet measured on the Vercel preview.
- `/plex`, `/jellyfin` and `/emby` were near copies, and two of them sat outside
  Google's index. Each now has its own H1, direct answer, setup steps, tips and
  gotchas, and six server specific FAQs.
- Every page has new titles and descriptions, a 1200x630 card image
  (`og-image-1200.png`, letterboxed because a center crop clipped the logo), a
  48px favicon, an apple-touch-icon, and one JSON-LD `@graph` linking the app,
  Chad and Muell Haus by `@id`. Visible FAQs and FAQPage text are generated from
  the same strings.
- Blog: titles end in " | Nostalgex", Article author is the Person `#chad`,
  posts get a BreadcrumbList, and new optional front matter `cover_alt`. FAQPage
  and table wrapping from #15 are kept, folded into the single graph.
- Sitemap entries carry `lastmod` only (Google ignores changefreq and priority).
  Added `public/llms.txt`.
- Support page CORS configs said `https://nostalgex.app`, but the tuner runs on
  `https://www.nostalgex.app`, so the documented config could not work. Fixed.
- Removed the Data Haus analytics script from every page, the blog template and
  the CSP. statsngraphs stays. The privacy page, README and the support FAQ
  now describe one analytics script; the support FAQ no longer says there are
  no analytics on the tuner pages, because the connect page loads one.
- "Over a hundred" is now 131 everywhere it appeared.
- `Nostalgex/PRIVACY_POLICY.md` matches the privacy page: statsngraphs only,
  effective October 9. `docs/FAQ.md` named 1.0.22 for the Tailscale/VPN http fix,
  which shipped in 1.0.23 (support page was already right).

**Half-done.** Rich Results Test and a Lighthouse run against production still
need doing.

**Next.** Merge #15 first, then this. After deploy, resubmit the sitemap and
request indexing for /plex, /jellyfin, /support and the blog post.

## 2026-10-08

**Shipped.** 1.0.23 reached the App Store (build 44). It carries the Jellyfin
channel-change fix, the Plex playback fixes, the SCREAM and TIS THE SEASON
packages, eleven new channels and the Y2K renames. The web tuner on
nostalgex.app shipped separately the same day.

**Changed.**

- Merged #5 and #7 from @Gorbataras, who found the tune-in bug independently and
  traced it further than we had, through Jellyfin's `DynamicHlsController` across
  10.10.7, 10.11.0, 10.11.11 and 12.1. #5 routes **Emby** through the same
  client-side seek Jellyfin already used, and deletes `addingStartTime`, which no
  longer had a caller. #7 stops Jellyfin and Emby direct-playing the two things
  AVPlayer will not render: HEVC in MP4 tagged `hev1` (it renders only
  `hvc1`/`dvh1`) and 10-bit H.264. Both guards already existed on the Plex path
  and had never been ported.
- Closed #3. The symptom was the tune-in bug, fixed in 1.0.23 and verified by
  @Gorbataras on an Apple TV 4K against Jellyfin 12.1.
- **Plex adaptive mode is no longer requested.** With `autoAdjustQuality=1`, any
  film where the server re-encodes both video and audio came back as 3-second
  segments: the first eight arrived at full speed, then one every 6.1 seconds for
  the rest of the film. tvOS 26 abandons a segment that slow (CoreMedia -15628)
  and the picture died at 24 seconds, at 4K and at the 1080p retry alike. With it
  off, the same request returns 1-second segments and keeps pace. Audio-copied
  streams were never affected, which is why some channels played and others did
  not.
- **Dolby Vision profile 5 plays on Plex.** Plex refuses to re-encode DV5
  (decision 2003), but it will remux it for a client it resolves as Generic,
  which is what Plex's own Apple TV app gets: `container=mp4, video=copy hevc
  DOVI 5`. On a DoVi refusal the app now re-asks once that way. Measured on
  device: picture in 1.8s, 61.6s of playhead across a 60s hold, zero stalls, zero
  dropped frames.
- **A starving stream steps down instead of freezing.** When a server cannot keep
  up, the same film is re-requested from the current position capped at 1080p,
  and only a starving capped stream advances. Previously it froze or jumped to
  the next programme.
- **An offset HLS transcode reports the remainder as its duration**, not the full
  runtime. The end-of-item fallback was adding the offset back, so `remaining`
  went negative on every tuned-in transcode and the first rate-0 moment skipped
  to the next film.
- **Web tuner: a failed stream retried forever.** The hls.js error handler
  guarded its one recovery with a flag written onto the error payload, and hls.js
  builds a fresh payload per event, so the guard never held. Measured against a
  playlist of 404s: **14,612 requests in 8 seconds**, roughly 1,800/s aimed at
  the user's own server; the same handler with the flag held outside the event
  made 14. A real session was caught making 2,239 requests for one dead segment
  while an unrelated channel played normally.
- **Web tuner: each playback now mints its own Plex transcode session** and
  releases it on the way out. Without one, Plex keyed the transcode off the
  client id alone, so every channel change quietly repurposed the previous
  session, which is what left the old loader requesting segments that 404.
- **Web tuner: a manifest that will not load now skips.** `start.m3u8` answering
  400 produces exactly one fatal `manifestLoadError` and nothing after it, so
  `startLoad()` had nothing to retry and the channel sat on black indefinitely.
  It now says so and moves to the next programme, stopping after three failures
  in a row because that points at the server rather than the file.
- **Music video genres come from Deezer** when the server reports none. On a test
  library of 1,131 music videos only 148 carried a genre, and MusicBrainz tags
  filled almost none of the rest, which is why CALIENTE and HEADBANGERS sat
  empty. Deezer resolved 47 of a random 60, and a filename cleaner (underscores,
  scene tags, `ft.`/`feat.`) recovered 10 of the 13 misses.
- **Music video years** are read from the filename first, then MusicBrainz, then
  the server only when plausible. Servers commonly report 1970 or the date the
  file was added, and Deezer's year is the album's, wrong on 15 of 15 sampled, so
  the decade channels were sorting by the wrong year.

**Changed, evening session (real hardware).** Build 1.0.24 (45) ran on an Apple TV HD
(tvOS 26.6) and an Apple TV 4K simulator against an Emby 4.10.1.0 server. Everything below
was measured there, not inferred.

- **Issue #6 confirmed fixed on hardware, with a controlled before/after.** The shipped
  1.0.23 (44) from TestFlight on the same device: `HTTP 404. The file '/UserViews' could
  not be found.` Build 45 ten minutes later: `[Emby] LIBRARY: 1541 items`, 69 channels,
  playback at a 57-minute mid-schedule join. Gorbataras's #5 Emby seek is confirmed by the
  same run.
- **The guide wrap works on tvOS 26.6**, the reporter's exact version, which the 26.1
  simulator could never reproduce. Down wraps, Up reaches SETTINGS.
- **The failure card now says why, accurately.** Three classifier corrections from
  watching it misfire: the probe walks master to variant to first segment, because the
  master answers 200 while every segment beneath it is refused; CoreMedia -12889 (no
  response in 3s) and -15628 (segment abandoned) classify as the server being too slow,
  not the device failing to decode; and a decoded frame vetoes "Apple TV couldn't play
  this file" outright. Verified verdicts on hardware: `Emby HTTP 500, refused before
  video` and `Emby below real time on the capped stream`.
- **Audio track selection.** Jellyfin and Emby hand back the file's default track, and
  Joe Dirt's default is Spanish 2ch with English 5.1 unflagged, so it played in Spanish
  on a channel with no picker. The resolver now reads MediaStreams from PlaybackInfo,
  prefers a track in the viewer's language with the most channels, then the default,
  then the first, and pins `AudioStreamIndex` on the transcode URL. Verified against the
  server: Emby's own URL pinned index 1 (spa); ours pins 2 (eng); Emby accepts it. 7 tests.
- **The starvation ladder's Emby rung fired for real** (The Wedding Singer, 13 Going on
  30): starve, cap to 1080p, `TRANSCODE READY`. It recovers what it can.

**Found, not fixed.**

- **Switching backend keeps the old day schedule.** A device signed into Plex, then
  Disconnected and connected to Emby for the first time, kept playing the Plex running
  order: Plex rating keys sent to Emby resolve to Person records and 500, every channel,
  looping between two titles indefinitely. A fresh install is flawless, so it is the
  transition that leaks. `DailyManifestStore.clearAll` on Disconnect uses the fingerprint
  current at that moment, and `apiForServer` never checks an item's `serverID` belongs to
  the connected backend. Workaround: delete and reinstall. Worth fixing before a wide push.
- **Two test rigs invent failures.** The tvOS simulator has no EAC3/AC3 decoder, so ~25%
  of a typical library stalls 3s in and looks like starvation; the Apple TV HD has no HEVC
  decoder, so every HEVC title forces a server re-encode that held 1.07x here against
  CoreMedia's 3s first-segment patience. The same file for an HEVC-capable client is a
  17.3x remux. Playback claims need the 4K unit.
- **On this Emby, 10-bit sources cannot transcode at all.** `VideoFilters.format..ctor()`
  throws "An item with the same key has already been added. Key: threads" before ffmpeg
  starts; 190 of 1541 movies affected. Ruled out by measurement with the server restored
  afterwards: codec, resolution, bitrate, subtitles, audio stream, thread count, hardware
  acceleration. A server bug, reported by the card as a refusal, nothing for the app to do.

**Half-done.**

- `fix/emby-userviews-404` — **Emby library scans fail immediately.**
  `loadSections` asked for `/UserViews?userId=`, which is Jellyfin's spelling.
  Measured against Emby Server 4.10.1.0: `/UserViews` answers 404,
  `/Users/{id}/Views` answers 200. It is the first request after sign-in, so it
  fails whatever the libraries are named and however large they are. Fixed with
  three tests on the branch, not yet merged. This is issue #6, and it is present
  in the released 1.0.23. **Now verified end to end against an Emby server**
  (see below).
- `feat/playback-failure-card` — **a programme that will not play now says why,
  instead of being swapped for the next one in silence.** Only three of about eight
  failure paths showed any UI at all; the startup watchdog, the starvation verdict and an
  AVPlayer item reaching `.failed` all advanced with nothing on screen, which reads as a
  broken app and hides whether the person should look at their server or at the file.
  `PlaybackState.error` now carries a `PlaybackFailure` rather than a sentence, and every
  failure path funnels through one place that records the verdict, emits the matching
  analytics code and shows a card for five seconds before advancing. Amber when the server
  is the thing to go and look at, red when the file or the device is.
  Getting the reason right needed a new source of truth: tvOS has no `httpStatusCode` on
  `AVPlayerItemErrorLogEvent`, so the status of a refused segment cannot be read out of the
  player, and that status is the difference between "your server refused this" and "this
  file will not decode". `StreamFailureProbe` asks the server instead, with one ranged GET
  on the URL that just failed. 14 tests, classification being a pure function over what was
  observed. Not merged.
- The startup watchdog's capped retry had the same missing client-side seek the starvation
  ladder got, so a watchdog retry on Jellyfin or Emby would have restarted the film from
  frame one. Fixed on the same branch as the ladder.
- `fix/starvation-ladder-all-backends` — **the starvation ladder had no rung on
  Jellyfin or Emby, so one stall skipped the programme.** `handleStarvation` steps
  a starving stream down to 1080p and only advances once there is nothing smaller
  to ask for, but `cappedTranscodeURL` was implemented on Plex alone and the
  `MediaBackend` default returns nil. Measured on Emby Server 4.10.1.0: each
  6-second segment took 3.4s to produce before its first byte, at 128 Mbps once
  flowing, so the server and not the network was the limit; a film jumped out
  mid-scene to the next scheduled title at its first frame. Both backends now
  build the rung at 1920 wide and 8 Mbps under their own `PlaySessionId`, with no
  start time on the URL, because the segment handler refuses one. A new
  `cappedStreamStartsAtOffset` says which backends seek client-side. 4 tests.
  Not merged.
- `fix/backend-error-copy` — error messages name the server the user actually
  connected to. `PlexAPIService.APIError` is the shared error type for all three
  backends, but every message hung off it was written for Plex, so an Emby user
  whose scan 404s was told "Plex (or your network path) returned HTTP 404" and
  sent to check Plex's Remote Access setting. Plex keeps its own copy, including
  the `/library` and `/identity` paths only Plex serves. One test asserts no
  Jellyfin or Emby message contains the word "Plex", across every error case.
  Not merged.
- `fix/guide-wrap-scrolling` — the guide's vertical wrap now runs off a focusable
  sentinel row just outside the last channel rather than a 150ms staleness timer,
  so "ran off the end" is proven by the focus engine instead of inferred from a
  clock. Up out of channel one deliberately still leaves for SETTINGS and does
  not wrap. 9 UI tests. Not merged. The report that prompted it came from tvOS
  26.6 and never reproduced on the 26.1 simulator at any list length or cadence,
  so treat this as hardening fragile timing rather than a confirmed fix.
- The web tuner still appends `StartTimeTicks` to its Jellyfin fallback URL in
  `getJellyfinTranscodeUrl` (`plex-tuner.html`). Same defect #5 fixed on tvOS.
  hls.js already seeks via `startPosition`, so the parameter only breaks segment
  requests. Spotted by @Gorbataras. In progress.
- **Emby, measured.** The Emby halves of #5 and #7 were reasoned from Jellyfin's
  HLS controller being forked from Emby's, and from Emby's own web client seeking
  client-side. Both now ran against Emby Server 4.10.1.0: sign-in, library scan,
  guide build, and a mid-programme join that started Heat at 47 minutes into a
  2:50:00 film and advanced 25s of playhead across 25s of wall clock with no
  stall. The scan only ever touches `/Users/{id}/Views` and `/Items`, and series
  and episodes go through that same `/Items` call with a different
  `IncludeItemTypes`, so a movies-only test library still exercises every HTTP
  path the scan makes. What remains untested on Emby is episode *parsing*, not
  whether an endpoint answers.

**Next.**

- Merge the three branches above.
- Port the web tuner's `StartTimeTicks` removal.
- Exercise an Emby library that contains TV series, to cover episode parsing and
  the per-show grouping the movies-only run could not reach.
