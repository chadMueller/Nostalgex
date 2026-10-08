# Working in this repo

Nostalgex: a retro TV guide for Plex, Jellyfin and Emby on Apple TV, plus the
marketing site and the browser web tuner. This repo is **public**. Anything
written here, including the dev log, is readable by anyone.

## Dev log: required at the end of every session

Before finishing a session in which anything changed, append an entry to
`docs/DEVLOG.md`. Commits say what changed; the log says **why**, and what state
things were left in. It is read by Chad and by his agent, so it has to stand on
its own without the conversation around it.

Newest entry goes at the top, under the heading, in this shape:

```markdown
## 2026-10-08

**Shipped.** What actually went out, and where. Name versions and build numbers.

**Changed.** The work that landed on main, one line each, with the reason rather
than the diff. "Emby libraries come from /Users/{id}/Views now, because
/UserViews is Jellyfin's spelling and 404s on Emby" beats "fixed endpoint".

**Half-done.** Anything on a branch, behind a flag, or merged but unverified.
Name the branch. Say what would finish it.

**Next.** What the next session should pick up, and anything blocked on a person
rather than on code.
```

`docs/DEVLOG.md` is **public and carries the real detail**: what changed and why,
measured numbers, branch names, what is half-done, what is unverified, and credit
to contributors. Chad's agent reads it from GitHub, so it has to be complete
there, not a pointer to somewhere private.

Four things never go in it. They go in
`projects/nostalgex-internal/docs/DEVLOG-INTERNAL.md` instead:

- **Anyone who did not opt in to being public.** TestFlight testers, people who
  emailed support, anyone who is not already a participant in the GitHub thread.
  Describe the report, not the person: "a tester on tvOS 26.6", never their name.
- **Keys, tokens, server addresses**, local paths that reveal a home network.
- **Unreleased plans** meant to stay quiet: release timing, marketing sends,
  pricing, anything commercial.
- **Personal data**, including the contents and size of Chad's own libraries.
  Behavioural measurements are fine once detached from whose server they came
  from: "a test library of 1,131 music videos" rather than "Chad's library".

Rules for the entry:

- Write what a stranger needs, not what the session remembers. No "as discussed".
- Measured numbers beat adjectives. "0.72x real time, 14,612 requests in 8s" is
  the useful part.
- Say plainly when something is unverified. "Not measured against an Emby
  server" is worth more than silence.
- Keep it to the length the day earned. A one-line day gets one line.
- No em dashes, no emoji. Match the tone of the rest of the docs.

## Before changing playback or the guide

These are the product. A regression here is worse than a missing feature, and
both have been broken by well-meant fixes before.

- Never diagnose by reasoning alone. Build a harness, measure, then name a cause.
- `NostalgexTests` must pass:
  `xcodebuild test -project Nostalgex/Nostalgex.xcodeproj -scheme Nostalgex \
   -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' \
   -only-testing:NostalgexTests CODE_SIGN_IDENTITY="-" \
   CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`
- `channels.json` is shared by the Swift app and the web tuner
  (`scripts/nostalgex-channel-filter.cjs`). Change both or they drift.
- Generated regions of `index.html` come from `content/changelog.json` and
  `channels.json` via the scripts in `scripts/`. Never hand-edit between the
  markers; edit the source and re-render.
