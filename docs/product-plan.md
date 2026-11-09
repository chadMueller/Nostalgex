# Nostalgex product plan

Living plan for Claude Code (and the rest of the Nostalgex team). Read this at the start of each session. Keep it short. Update it when priorities change.

## How to use this file

- This file is direction, not a changelog or a release notes draft.
- Slack #nostalgex is the live lane with the Nostalgex CEO assistant:
  - `TASK:` something to do
  - `CONTEXT:` something to know, no action needed
  - `PLAN:` product direction or a pointer to a change here
- Report progress through the Claude Code activity webhook, and post short `Claude:` milestone lines in #nostalgex for merges, pushes, releases, decisions, and items waiting on Chad.
- Chad's go overrides everything. Do not merge, push public copy, post, or email without that go.
- Never add an AI author trailer on commits, PRs, or comments.
- Trello board "Nostalgex Roadmap" remains the idea backlog source of truth: https://trello.com/b/2TDIX8KN/nostalgex-roadmap

## Current releases per platform

- **Apple TV:** App Store **1.0.29** live. **1.0.30** (build 54) TestFlight candidate is on main with changelog `released:false`. **1.0.31 RC1** is local only on branch `appletv/1.0.31-rc1` (head `82ba4b09`): guide no-jump fix included; package preview and stripes deferred to a small second batch.
- **Roku:** Channel Store app live (add code `NOSTALGEX`). **1.0.12** going live Nov 9, 2026. tydude001 PRs #199, #200, #210 to #214 are on main for the build after 1.0.12.
- **Android TV / Google Play:** In progress (outside contributor PR #151 is a large draft, not merge-ready). Public announcements held.
- **Web tuner / Docker:** Free side product. Stays free with no premium features.

## Now (this week's priorities)

1. **Apple TV 1.0.31 RC1**: Chad installs the Debug build on the living room TV and checks `[GuideJump]` console lines. Ship the no-jump fix once Chad signs off. Leave package preview and stripes for a follow-up batch.
2. **Roku 1.0.12 store settle**: Confirm Channel Store text and screenshots match once the page settles. Hold every public Roku announcement, site flip, Discord post, and launch email until written Roku PR approval. Keep `/roku` on Beta wording until then.
3. **Android keep-moving**: Keep PR #151 progressing as a draft. Do not merge a 17k-line dump. Public Android / Google Play talk stays held.
4. **Support loop**: Discord #support is watched; replies are drafted to Chad first. Do not auto-post as nostalgex-bot unless Chad grants that.

## Next

- Apple TV second batch: package preview (scroll bug on TV) and stripes.
- Next Roku build after 1.0.12 from the already-merged tydude001 work.
- Free core ideas still on the roadmap: "Why is this channel empty?" (I-004), hide a single channel (I-011), German localization first (I-010), Australian ratings (I-066).
- Android TV / Google TV path once the contributor draft is reviewable in smaller pieces.

## Later / ideas

- iPhone and iPad on the same App Store record (I-012).
- Watershed setting (I-005), library pickers for Jellyfin/Emby (I-054).
- Plus customization tier (custom channels, reorder packages, favourites lineup, guide skins). Nothing that exists today moves behind a paywall. Web tuner and Docker stay free.
- Channels into Jellyfin or Plex Live TV (I-014). Samsung / LG (I-022).

## Holds and rules

- **Roku public hold:** announcements, site wording, email, Discord, and blog stay held until Roku PR writes back with an OK. Do not put any Roku PR email address in this file or in public copy. `/roku` stays Beta until cleared.
- **Android / Google Play public hold:** build quietly; no public launch talk yet.
- **HIGH ROTATION (PR #105):** on hold since Oct 27 until Chad says otherwise.
- **.m3u / outside channel lists in the Apple TV app:** held (App Store risk). Keep Nostalgex focused on the user's own library.
- **Public copy:** first person (I/me/my), casual, no emojis, no em dashes, no future promises. Site shows only the App Store-live version. Chad posts Reddit, GitHub replies, Discord announcements, and influencer outreach himself unless he asks otherwise.
- **Commits:** no AI author trailers, ever.

## Open questions for Chad

1. Has Roku PR written back with an OK for public Roku wording?
2. Does 1.0.31 RC1 pass on the living room TV (`[GuideJump]`)?
3. OK to keep Discord #support as drafts-only, or grant FAQ auto-replies for nostalgex-bot?
4. Per-platform Discord channels (Apple TV / Roku / Android), or stay with one #support plus a pinned checklist?
5. Priority between Android PR #151 cleanup and the Apple TV second batch (package preview + stripes)?

## Changelog of this plan

- **2026-11-09, ~1:20 PM America/Toronto**: First version. Captures live Apple TV / Roku / Android state, the Slack TASK/CONTEXT/PLAN lane, public holds, and this week's ship priorities.
