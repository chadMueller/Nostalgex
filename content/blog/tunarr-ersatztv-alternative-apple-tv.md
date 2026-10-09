---
title: "ErsatzTV and Tunarr Alternatives for Apple TV: Live Channels From Your Library, No Server Needed"
seo_title: "ErsatzTV & Tunarr Alternatives for Apple TV"
description: "ErsatzTV is in maintenance mode and Tunarr needs a server. Here's how the alternatives compare, and when a free Apple TV app is honestly all you need."
excerpt: "I love what Tunarr and ErsatzTV do. But if your channels only ever play on one Apple TV, you might not need a server tool at all. Here's how I'd decide."
author: "Chad Mueller"
slug: tunarr-ersatztv-alternative-apple-tv
date: 2026-10-13
updated: 2026-10-13
draft: true
---

# ErsatzTV and Tunarr Alternatives for Apple TV: Live Channels From Your Library, No Server Needed

> The main ErsatzTV alternative is Tunarr, which builds custom channels on your server and works with Plex, Jellyfin, Emby and any IPTV player. If you only watch on an Apple TV, you may not need a server at all. Nostalgex is a free, open source Apple TV app that turns your Plex or Jellyfin library into 131 live channels with a retro guide, automatically.

I should say up front that I built Nostalgex, so take my opinions here with the right amount of salt. I also spent a long time running the server tools before I wrote a line of it, and I still think they're great. This post is my honest attempt to help you figure out which kind of tool you actually need, because a lot of people asking for an "ErsatzTV alternative" this year really just want to flip channels on the couch.

## What are the best ErsatzTV alternatives?

Here's the short version, checked October 2026. The rest of the post explains each one.

| Tool | Where you watch | Runs on your server | You program the schedule | Shares channels as M3U or tuner | Cost |
|---|---|---|---|---|---|
| Tunarr | Plex, Jellyfin, Emby or any IPTV player | Yes (Docker or standalone binaries) | Yes | Yes | Free, open source |
| ErsatzTV Legacy | Plex, Jellyfin, Emby or any IPTV player | Yes | Yes | Yes | Free, open source |
| dizqueTV | Plex, Jellyfin, Emby or any IPTV player | Yes | Yes | Yes | Free, open source |
| JellyStream | Jellyfin or any IPTV player | Yes | You set genre rules, it fills the schedule | Yes | Free, open source |
| Live Channels plugin | Any Jellyfin app | Inside Jellyfin | Yes | Through Jellyfin Live TV | Free, open source |
| NostalgiaTV | Android TV, Android and Amazon devices | Optional Docker server | Prebuilt channels plus custom ones | Yes, with its server | Free, with a paid Pro upgrade |
| Nostalgex | Apple TV and a web browser | No | No, it builds every channel | No | Free, open source |

If you want to dig into any of them, start with the [Tunarr README](https://github.com/chrisbenincasa/tunarr/), [JellyStream](https://github.com/oarko/jellystream), the [Live Channels plugin](https://github.com/JPKribs/jellyfin-plugin-livechannels) and [NostalgiaTV on Google Play](https://play.google.com/store/apps/details?id=com.nostalgiatv). NostalgiaTV is a separate app from a different developer, and a good one if your house runs on Android TV or Fire TV.

## What happened to ErsatzTV, and is it still safe to use?

ErsatzTV had a rough 2026 if you were a fan. The project was archived in February, which set off threads like [this one on r/jellyfin](https://www.reddit.com/r/jellyfin/comments/1rdy2v0/ersatztv_is_now_archived/) where people asked what to switch to before their families noticed. In April the original app came back as ErsatzTV Legacy, which [gets security fixes but no new features](https://www.reddit.com/r/ErsatzTV/comments/1sp4jql/unarchiving_ersatztv_legacy/). The new project, [ErsatzTV Next](https://github.com/ErsatzTV/next), is a streaming engine built with the Tunarr developer, and it [deliberately doesn't do scheduling at all](https://www.reddit.com/r/ErsatzTV/comments/1sngryj/what_is_next_for_ersatztv/).

So is it safe? If your Legacy install works today, there's no fire. Keep it updated and keep using it. I just wouldn't start a brand new setup on it unless you need something it handles especially well, like [music video channels](https://github.com/ErsatzTV/legacy).

## Is Tunarr still the best pick for most people?

For people who want to program real channels, yes. [Tunarr](https://tunarr.com/) is the successor to dizqueTV, it's actively developed, and it connects to Plex, Jellyfin, Emby and local files. You build channels with time slots, filler, shuffles and marathons, then it hands them out as a fake HDHomeRun tuner or as M3U playlists that any IPTV player can open.

One correction to something I see a lot: Tunarr isn't Docker only. Its install page lists standalone binaries for Linux, Windows and macOS alongside the Docker image. You do have to bring your own FFmpeg with the binaries ([Tunarr install docs](https://tunarr.com/getting-started/installation/)).

The tradeoff is the same one it's always been. You're running another service, it does transcoding work, and you're the program director. Some people love that part. If you're one of them, Tunarr is the answer and you can stop reading.

## How do I watch Tunarr or ErsatzTV channels on an Apple TV?

There are two usual routes. You can add the tuner to Plex Live TV and watch in the Plex app, or you can paste the M3U address into an IPTV player on the Apple TV. UHF comes up a lot in [r/tunarr threads](https://www.reddit.com/r/tunarr/comments/1vneib8/macos_stable_successfull/) for this. Both work. Both also mean you've now got a server, a tuner layer and a player app that all need to agree with each other, and when a channel stutters it's not always obvious which piece to blame.

## Do I need a server tool at all if I only watch on Apple TV?

This is the question I wish someone had asked me earlier. A channel server makes sense when you want the same channels on lots of different screens: the Roku in the bedroom, Plex on a phone, Kodi in the basement. It's the shared source for everything.

If every bit of your channel surfing happens on one or two Apple TVs, a server is a lot of plumbing for that job. The guide and the schedule can live in the app on the TV, and the app can just ask your media server for the file when it's time to play it. That's how every channel surfing app on Apple TV works, including mine.

There's a comment in [an r/selfhosted thread](https://www.reddit.com/r/selfhosted/comments/1ryr6p0/analoq_my_take_on_a_free_plex_live_tv_app_for/) that stuck with me. Someone said they'd used ErsatzTV for years, got tired of streaming hiccups, and noted that Apple TV options had been "so limited." That's who this kind of app is for.

## How does Nostalgex compare to Tunarr and ErsatzTV?

Here's what you give up with [Nostalgex](/), plainly:

* **No handmade schedules.** You don't build channels or time slots. Nostalgex builds every channel and schedule from your library on its own. If you want Seinfeld at 7 and a movie at 9 every night, that's a Tunarr job.
* **No tuner or M3U output.** Nothing gets shared out to Plex Live TV, Kodi or other players.
* **No recording.**
* **Only two places to watch.** The Apple TV app (tvOS 18 or later) and the [web tuner](/web-tuner) in a browser. There's no Android, Roku or Fire TV version.

XDA Developers [tried Nostalgex with a Jellyfin server](https://www.xda-developers.com/this-jellyfin-plugin-made-my-media-library-feel-like-old-school-cable-tv/) in October and landed in the same place: much easier than Tunarr or ErsatzTV, with less control over individual channels. That's a fair summary.

And here's what you get:

* **Nothing installed on your server.** No container, no service, no FFmpeg build. The app talks to Plex or Jellyfin directly, and it plays the file as is when the Apple TV can handle it.
* **131 channels in 14 bundles, already airing.** Saturday morning cartoons, 90s sitcoms, decades, franchises, seasonal stuff. You connect your server and they fill themselves from what you own. This month there's a free SCREAM bundle you can turn on with one button. It adds four horror channels: 137 SCREAM KIDS, 138 FRIGHT NIGHT, 139 SCREAM ADULTS and 140 NOSTALGEX HORROR.
* **It's free in the same way Tunarr is free.** MIT licensed, [code on GitHub](https://github.com/chadMueller/Nostalgex), no ads, no account. It needs nothing paid either: no Plex Pass, no subscription.
* **Plex and Jellyfin.** The Apple TV app can connect to more than one server at once, and Emby support is coming soon.

If you're on Plex, here's [how Nostalgex works with Plex](/plex). On Jellyfin, start with [Nostalgex for Jellyfin](/jellyfin).

## Is there a good dizqueTV alternative?

dizqueTV started this whole category for a lot of Plex people, me included. It's still on GitHub (its last release, 1.7.0, came out in December 2025), but most of the new work in this space happens in Tunarr, which began as a dizqueTV fork. Tunarr's [install guide](https://tunarr.com/getting-started/installation/) even lets you point it at your existing dizqueTV folder to bring your channels over. If your dizqueTV setup works, there's no rush. If you're starting fresh, start with Tunarr.

## Which one should I pick?

My honest version:

* You want channels on lots of different devices, or you enjoy programming them: **Tunarr**.
* You already run ErsatzTV Legacy and it works: **keep it**, keep it updated.
* You want music video channels: **ErsatzTV Legacy** handles those well.
* Your house runs on Android TV or Fire TV and you want prebuilt channels: **NostalgiaTV**.
* You only watch on Apple TV and want to flip channels tonight without running anything new: **[Nostalgex](https://apps.apple.com/app/nostalgex/id6762563534)**, or try the [web tuner](/web-tuner) first if your server has an https address.

You can also run both. Nothing stops you from keeping Tunarr for the bedroom Roku and using Nostalgex in the living room.

## FAQ

### What's the best ErsatzTV alternative?

For most people it's Tunarr, which does the same job on your server and is actively developed. If you only watch on Apple TV and don't want to run a server, an app like Nostalgex builds the channels for you.

### Is ErsatzTV dead?

Not exactly. ErsatzTV Legacy still gets security fixes but no new features, and ErsatzTV Next is a streaming engine that leaves scheduling to other tools. Existing installs keep working. New setups are better off on Tunarr or an app.

### Does Tunarr work on Apple TV?

Yes, through another app. You either add Tunarr as a tuner in Plex Live TV and watch in Plex, or open its M3U playlist in an IPTV player like UHF.

### Do I need Docker or a server to use Nostalgex?

No. Nothing gets installed on your server. You install the Apple TV app, sign in to Plex or Jellyfin, and the channels build themselves.

### Can Nostalgex share its channels as an M3U playlist or HDHomeRun tuner?

No. The channels live inside the Apple TV app and the web tuner. If you need channels in other players, that's what Tunarr is for.

<!--
Build notes: build-blog.mjs ignores author, updated and excerpt today. Article JSON-LD author is the Organization and dateModified equals datePublished until the build reads these fields.
Intended schema: FAQPage from the FAQ H3s. Article "about": {"@id": "https://www.nostalgex.app/#app"} (needs the @id added to the homepage SoftwareApplication). No separate SoftwareApplication block.
Images to add (none exist yet): cover alt "Nostalgex channel guide on Apple TV showing live channels built from a Jellyfin library". Inline next to the table: "Side by side of a Tunarr channel editor and the Nostalgex guide" only if Chad has his own Tunarr screenshot, otherwise the guide alone.
ADD LINKS BACK (this post publishes Oct 13; these targets are not live yet):
1. Oct 15, once /blog/jellyfin-tv-guide-own-library is live: in "How does Nostalgex compare to Tunarr and ErsatzTV?", change "On Jellyfin, start with [Nostalgex for Jellyfin](/jellyfin)." to "On Jellyfin, start with [Nostalgex for Jellyfin](/jellyfin) or my post on [getting a TV guide for your own Jellyfin library](/blog/jellyfin-tv-guide-own-library)."
2. Oct 17, once /blog/make-plex-feel-like-cable-tv is live: in the same paragraph, after the Plex sentence, add: "For the full Plex walkthrough, here's [how to make Plex feel like cable TV](/blog/make-plex-feel-like-cable-tv)."
3. Oct 20, once /blog/apple-tv-channel-surfing-apps is live: at the end of "Which one should I pick?", add: "Comparing Apple TV apps instead? I lined them up in [the best channel surfing apps for Apple TV](/blog/apple-tv-channel-surfing-apps)."
4. Oct 22, once /blog/plex-virtual-channels-own-movies is live: optional, not in the review map. Skip unless Chad wants it.
Publish day check: NostalgiaTV Pro pricing (one time or subscription) before quoting any price.
-->
