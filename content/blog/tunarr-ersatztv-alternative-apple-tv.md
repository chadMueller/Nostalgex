---
title: "Tunarr vs ErsatzTV in 2026: Which One to Run, and When You Don't Need Either"
seo_title: "Tunarr vs ErsatzTV: Which One to Run in 2026"
description: "Tunarr vs ErsatzTV, compared plainly: setup, scheduling, players and where each project stands now. Plus when a free app on your TV is all you need."
cover: "https://pub-98e43e3b886d48018eab8387d373ddb4.r2.dev/site/blog/tunarr-ersatztv-alternative-apple-tv/cover.jpg"
cover_alt: "Full screen movie playing on the Classic Fam Jams channel in the Nostalgex Apple TV app, no server needed"
excerpt: "Tunarr vs ErsatzTV, compared honestly: who each one is for, where the projects stand in 2026, and when a free app on your TV is all you need."
author: "Chad Mueller"
slug: tunarr-ersatztv-alternative-apple-tv
date: 2026-10-13
updated: 2026-11-13
---

# Tunarr vs ErsatzTV in 2026: Which One to Run, and When You Don't Need Either

> Tunarr and ErsatzTV both turn your Plex, Jellyfin or Emby library into custom live channels on a server, then share them as a fake HDHomeRun tuner or an M3U playlist. Tunarr is the easier place to start for most people, with a web editor for time slots and filler and frequent releases. ErsatzTV is the pick if you want its scheduling tools or already run it. If you only watch on Apple TV or Roku and don't want to program channels, a free app like Nostalgex builds them for you instead.

I should say up front that I built Nostalgex, so take my opinions here with the right amount of salt. I also spent a long time running the server tools before I wrote a line of it, and I still think they're great. If you're comparing Tunarr and ErsatzTV, the table below is the useful part. If you really just want to flip channels on the couch, keep reading, because you might not need either one.

## Tunarr vs ErsatzTV: what's the difference?

Both are free, open source channel servers. You install them next to Plex, Jellyfin or Emby, you build the lineup, and they pretend to be live TV. The difference is how they feel to run, and where each project is in 2026.

| | Tunarr | ErsatzTV |
|---|---|---|
| Install | Docker, Unraid, or standalone binaries for Linux, Windows and macOS. Binaries need your own FFmpeg. | Docker, Unraid, or binaries for Windows, macOS and Linux |
| How you build schedules | Web editor for lineups, time slots, random slots, filler, shuffles and marathons | Web UI for custom channels and scheduling |
| Outputs | HDHomeRun tuner, M3U, XMLTV, HLS | M3U, XMLTV, HLS, MPEG-TS (HDHomeRun-compatible) |
| Media servers | Plex, Jellyfin, Emby and local files | Plex, Jellyfin, Emby and more |
| Streaming engine | Tunarr's FFmpeg pipeline, plus ErsatzTV Next as an optional experimental backend | ErsatzTV Next is the default as of v26.12.0 |
| Release pace | Frequent. Latest is v2026.11.2 (November 9, 2026) | Regular releases every 1 to 2 weeks. Latest is v26.12.0 (November 6, 2026) |
| License | zlib, open source | zlib, open source |

**Pick Tunarr if** you're starting fresh and you want a web editor for time slots, filler and shuffles. Releases come often, it talks to Plex, Jellyfin and Emby, and it hands channels out as a fake HDHomeRun tuner or an M3U playlist. [v2026.11.2](https://tunarr.com/blog/2026.11.2/) (November 9) added stream selection profiles and a rebuilt Channels page. That's the one I'd install on a new box.

**Pick ErsatzTV if** you already run it, you want its scheduling tools, or you care about things it has always done well, like music video channels. The original app is still labeled Legacy, and it is actively released: [v26.12.0](https://github.com/ErsatzTV/legacy/releases) on November 6 moved every channel onto the ErsatzTV Next streaming engine. If your family already knows those channel numbers, staying is a reasonable choice.

## What are the best ErsatzTV alternatives?

Here's every option at a glance, checked November 2026. The rest of the post explains each one.

| Tool | Where you watch | Runs on your server | You program the schedule | Shares channels as M3U or tuner | Cost |
|---|---|---|---|---|---|
| Tunarr | Plex, Jellyfin, Emby or any IPTV player | Yes (Docker or standalone binaries) | Yes | Yes | Free, open source |
| ErsatzTV | Plex, Jellyfin, Emby or any IPTV player | Yes | Yes | Yes | Free, open source |
| dizqueTV | Plex, Jellyfin, Emby or any IPTV player | Yes | Yes | Yes | Free, open source |
| JellyStream | Jellyfin or any IPTV player | Yes | You set genre rules, it fills the schedule | Yes | Free, open source |
| Live Channels plugin | Any Jellyfin app | Inside Jellyfin | Yes | Through Jellyfin Live TV | Free, open source |
| NostalgiaTV | Android TV, Android and Amazon devices | Optional Docker server | Prebuilt channels plus custom ones | Yes, with its server | Free, with a paid Pro upgrade |
| Nostalgex | Apple TV, Roku Channel Store, a web browser or a Docker container | No | No, it builds every channel | No | Free, open source |

If you want to dig into any of them, start with the [Tunarr README](https://github.com/chrisbenincasa/tunarr/), [JellyStream](https://github.com/oarko/jellystream), the [Live Channels plugin](https://github.com/JPKribs/jellyfin-plugin-livechannels) and [NostalgiaTV on Google Play](https://play.google.com/store/apps/details?id=com.nostalgiatv). NostalgiaTV is a separate app from a different developer, and a good one if your house runs on Android TV or Fire TV.

## Is ErsatzTV still maintained?

Yes. It had a messy stretch in 2026, which is why people still ask. The project was archived in February, and that set off threads like [this one on r/jellyfin](https://www.reddit.com/r/jellyfin/comments/1rdy2v0/ersatztv_is_now_archived/) where folks wondered what to switch to before their families noticed. In April the original app came back as ErsatzTV Legacy.

The Legacy name stuck. The app itself is actively released, with new builds about every week or two. [v26.12.0](https://github.com/ErsatzTV/legacy/releases) landed November 6, 2026, and Legacy now defaults to the ErsatzTV Next streaming engine.

[ErsatzTV Next](https://github.com/ErsatzTV/next) is that engine, a rewrite that transcodes and streams. Library management, scheduling and playout are not its job. As of v0.2.5 (also November 6), it is the default streaming engine inside ErsatzTV, and it can run on its own. Docs live at [ersatztv.org/next-docs](https://ersatztv.org/next-docs/).

So is it safe? If your install works today, keep it updated and keep using it. I wouldn't start a brand new setup on it unless you need something it handles especially well, like [music video channels](https://github.com/ErsatzTV/legacy). For a fresh install where you want to program channels, Tunarr is the easier on-ramp.

## Is Tunarr still the best pick for most people?

For people who want to program real channels, yes. [Tunarr](https://tunarr.com/) is the successor to dizqueTV, it's actively developed, and it connects to Plex, Jellyfin, Emby and local files. You build channels with time slots, filler, shuffles and marathons, then it hands them out as a fake HDHomeRun tuner or as M3U playlists that any IPTV player can open.

The current release is [v2026.11.2](https://tunarr.com/blog/2026.11.2/) (November 9, 2026): stream selection profiles so a channel can pick the right audio and subtitles, and a rebuilt Channels page with bulk actions. Tunarr 2026.11.0 also added [ErsatzTV Next as an optional streaming backend](https://tunarr.com/configure/ffmpeg/ersatztv-next), marked experimental, one channel at a time if you want to try it. They're not enemies. Tunarr still runs the schedule. Next can transcode the stream.

One correction to something I see a lot: Tunarr isn't Docker only. Its install page lists standalone binaries for Linux, Windows and macOS alongside the Docker image. You do have to bring your own FFmpeg with the binaries ([Tunarr install docs](https://tunarr.com/getting-started/installation/)).

The tradeoff is the same one it's always been. You're running another service, it does transcoding work, and you're the program director. Some people love that part. If you're one of them, Tunarr is the answer and you can stop reading.

## How do I watch Tunarr or ErsatzTV channels on an Apple TV?

There are two usual routes. You can add the tuner to Plex Live TV and watch in the Plex app, or you can paste the M3U address into an IPTV player on the Apple TV. UHF comes up a lot in [r/tunarr threads](https://www.reddit.com/r/tunarr/comments/1vneib8/macos_stable_successfull/) for this. Both work. Both also mean you've now got a server, a tuner layer and a player app that all need to agree with each other, and when a channel stutters it's not always obvious which piece to blame.

## Do I need a server tool at all if I only watch on Apple TV?

This is the question I wish someone had asked me earlier. A channel server makes sense when you want the same channels on lots of different screens: the Roku in the bedroom, Plex on a phone, Kodi in the basement. It's the shared source for everything.

![Nostalgex guide on Apple TV airing Urban Legend on the Nostalgex Horror channel straight from a home library](https://pub-98e43e3b886d48018eab8387d373ddb4.r2.dev/site/blog/tunarr-ersatztv-alternative-apple-tv/nostalgex-horror-guide.webp)

If every bit of your channel surfing happens on one or two TVs, a server is a lot of plumbing for that job. The guide and the schedule can live in the app on the TV, and the app can just ask your media server for the file when it's time to play it. That's how every channel surfing app on Apple TV works, including mine.

There's a comment in [an r/selfhosted thread](https://www.reddit.com/r/selfhosted/comments/1ryr6p0/analoq_my_take_on_a_free_plex_live_tv_app_for/) that stuck with me. Someone said they'd used ErsatzTV for years, got tired of streaming hiccups, and noted that Apple TV options had been "so limited." That's who this kind of app is for.

## How does Nostalgex compare to Tunarr and ErsatzTV?

Here's what you give up with [Nostalgex](/?utm_source=blog&utm_medium=internal&utm_campaign=tunarr_vs_ersatztv_refresh), plainly:

![Nostalgex channel flip bar over a playing movie, showing what is on the next channels](https://pub-98e43e3b886d48018eab8387d373ddb4.r2.dev/site/blog/tunarr-ersatztv-alternative-apple-tv/channel-flip-bar.webp)

* **No handmade schedules.** You don't build channels or time slots. Nostalgex builds every channel and schedule from your library on its own. If you want Seinfeld at 7 and a movie at 9 every night, that's a Tunarr job.
* **No tuner or M3U output.** Nothing gets shared out to Plex Live TV, Kodi or other players.
* **No recording.**
* **Apple TV, Roku and the web.** The Apple TV app, the [Roku Channel Store app](/roku?utm_source=blog&utm_medium=internal&utm_campaign=tunarr_vs_ersatztv_refresh) (add it with code NOSTALGEX), the [web tuner](/web-tuner?utm_source=blog&utm_medium=internal&utm_campaign=tunarr_vs_ersatztv_refresh) in a browser, and a [Docker container](/self-host?utm_source=blog&utm_medium=internal&utm_campaign=tunarr_vs_ersatztv_refresh) for Jellyfin or Emby servers that don't have https. There is no Fire TV version. Android TV is on the list.

XDA Developers [tried Nostalgex with a Jellyfin server](https://www.xda-developers.com/this-jellyfin-plugin-made-my-media-library-feel-like-old-school-cable-tv/) in October and landed in the same place: much easier than Tunarr or ErsatzTV, with less control over individual channels. That's a fair summary.

And here's what you get:

* **Nothing installed on your server for the TV apps.** No channel server, no FFmpeg build. The app talks to Plex, Jellyfin or Emby directly, and it plays the file as is when the TV can handle it. The Docker container is only for running the web tuner on your own network.
* **130+ channels in 14 bundles, already airing.** Saturday morning cartoons, 90s sitcoms, decades, franchises, seasonal stuff. You connect your server and they fill themselves from what you own.
* **It's free in the same way Tunarr is free.** MIT licensed, [code on GitHub](https://github.com/chadMueller/Nostalgex?utm_source=blog&utm_medium=internal&utm_campaign=tunarr_vs_ersatztv_refresh), no account. It needs nothing paid either: no Plex Pass, no subscription.
* **Plex, Jellyfin and Emby.** Nostalgex works with all three, and the Apple TV app can connect to more than one server at once.

If you're on Plex, here's [how Nostalgex works with Plex](/plex?utm_source=blog&utm_medium=internal&utm_campaign=tunarr_vs_ersatztv_refresh), or the longer walkthrough on [making Plex feel like cable TV](/blog/make-plex-feel-like-cable-tv?utm_source=blog&utm_medium=internal&utm_campaign=tunarr_vs_ersatztv_refresh). On Jellyfin, start with [Nostalgex for Jellyfin](/jellyfin?utm_source=blog&utm_medium=internal&utm_campaign=tunarr_vs_ersatztv_refresh) or my post on [getting a TV guide for your own Jellyfin library](/blog/jellyfin-tv-guide-own-library?utm_source=blog&utm_medium=internal&utm_campaign=tunarr_vs_ersatztv_refresh). On Emby, here's [Nostalgex for Emby](/emby?utm_source=blog&utm_medium=internal&utm_campaign=tunarr_vs_ersatztv_refresh).

## Is there a good dizqueTV alternative?

dizqueTV started this whole category for a lot of Plex people, me included. It's still on GitHub (its last release, 1.7.0, came out in December 2025), but most of the new work in this space happens in Tunarr, which began as a dizqueTV fork. Tunarr's [install guide](https://tunarr.com/getting-started/installation/) even lets you point it at your existing dizqueTV folder to bring your channels over. If your dizqueTV setup works, there's no rush. If you're starting fresh, start with Tunarr.

## Which one should I pick?

My honest version:

* You want channels on lots of different devices, or you enjoy programming them: **Tunarr**.
* You already run ErsatzTV and it works: **keep it**, keep it updated.
* You want music video channels: **ErsatzTV** handles those well.
* Your house runs on Android TV or Fire TV and you want prebuilt channels: **NostalgiaTV**.
* You watch on Apple TV or Roku and want to flip channels tonight without programming anything: **[Nostalgex](https://apps.apple.com/app/apple-store/id6762563534?pt=128802261&ct=blog_tunarr_vs_ersatztv&mt=8)**. On Roku, search the Channel Store or add it with code NOSTALGEX ([more on the Roku app](/blog/nostalgex-on-roku?utm_source=blog&utm_medium=internal&utm_campaign=tunarr_vs_ersatztv_refresh)). If your Jellyfin or Emby server is on plain http, run the web tuner in a [Docker container](/self-host?utm_source=blog&utm_medium=internal&utm_campaign=tunarr_vs_ersatztv_refresh) instead of the hosted tuner.

You can also run both. Nothing stops you from keeping Tunarr for the bedroom Roku and using Nostalgex in the living room.

Comparing Apple TV apps instead? I lined them up in [the best channel surfing apps for Apple TV](/blog/apple-tv-channel-surfing-apps?utm_source=blog&utm_medium=internal&utm_campaign=tunarr_vs_ersatztv_refresh).

## FAQ

### Is Tunarr better than ErsatzTV?

For most people starting fresh, Tunarr is the easier pick: a web editor for building channels, frequent releases, and Plex, Jellyfin and Emby support. ErsatzTV is a strong choice if you want its scheduling tools or already run it. Both are free and open source.

### Can Tunarr and ErsatzTV work together?

Yes, in one way. Tunarr can use ErsatzTV Next as an experimental streaming backend for a channel, while Tunarr still handles the schedule.

### What's the best ErsatzTV alternative?

For most people it's Tunarr, which does the same job on your server and is actively developed. If you only watch on Apple TV or Roku and don't want to run a server, an app like Nostalgex builds the channels for you.

### Is ErsatzTV dead?

No. ErsatzTV (still labeled Legacy) is actively released. v26.12.0 on November 6, 2026 moved every channel onto the ErsatzTV Next streaming engine. Next is a streaming engine that leaves scheduling to ErsatzTV or other tools. Existing installs keep working.

### Does Tunarr work on Apple TV?

Yes, through another app. You either add Tunarr as a tuner in Plex Live TV and watch in Plex, or open its M3U playlist in an IPTV player like UHF.

### Do I need Docker or a server to use Nostalgex?

No. Nothing gets installed on your server for the Apple TV or Roku apps. You install the app, sign in to Plex, Jellyfin or Emby, and the channels build themselves. A Docker container is optional, and only if you want the web tuner on a Jellyfin or Emby server that doesn't have https.

### Can Nostalgex share its channels as an M3U playlist or HDHomeRun tuner?

No. The channels live inside the Apple TV app, the Roku app and the web tuner. If you need channels in other players, that's what Tunarr is for.

<!--
Build notes: build-blog.mjs reads seo_title, author and updated. excerpt is unused.
FAQPage comes from the FAQ H3s. Article "about" is the homepage SoftwareApplication.
No new images in this refresh.
-->
