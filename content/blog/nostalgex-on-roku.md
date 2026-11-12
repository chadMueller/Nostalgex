---
title: "Nostalgex Is on Roku: Free Live Channels From Your Own Plex, Jellyfin or Emby Library"
seo_title: "Nostalgex on Roku: Live Channels From Your Library"
description: "Nostalgex is on the Roku Channel Store. Add it with code NOSTALGEX, sign in to Plex, Jellyfin or Emby, and your library becomes 130+ live channels."
slug: nostalgex-on-roku
date: 2026-11-12
draft: false
keyword: "nostalgex roku"
cover: "https://pub-98e43e3b886d48018eab8387d373ddb4.r2.dev/site/blog/nostalgex-on-roku/header.webp"
cover_alt: "The Nostalgex guide on a Roku TV, with 90S SITCOMS, SAT MORNING CARTOONS and AFTER SCHOOL TV channels built from a home library"
og_image: "https://pub-98e43e3b886d48018eab8387d373ddb4.r2.dev/site/blog/nostalgex-on-roku/cover.jpg"
og_image_alt: "The Nostalgex guide on a Roku TV, with 90S SITCOMS, SAT MORNING CARTOONS and AFTER SCHOOL TV channels built from a home library"
author: "Chad Mueller"
excerpt: "The most asked question in my inbox finally has a short answer. Nostalgex is on Roku, it's free, and it takes about a minute to set up."
---

# Nostalgex is on Roku

> Nostalgex is on the Roku Channel Store. Add it from your Roku account with the code NOSTALGEX, or search for Nostalgex on your Roku, then sign in to your Plex, Jellyfin or Emby server. It turns your own movies and shows into 130+ live channels with a retro TV guide, and something is already playing when you tune in. It's free and open source (MIT).

For months, the question I got most was some version of "cool, but I have a Roku." Fair. Half the TVs in my extended family are Roku TVs, including the one at my parents' place that still has a VHS player plugged into it out of pure stubbornness.

So here's the short answer: yes. Nostalgex is on Roku now, as a real app in the Roku Channel Store. Not a sideload, not a beta you need an invite for.

## How do I add Nostalgex to my Roku?

Two ways, both take about a minute.

1. **From your Roku:** open the Streaming Store from the home screen, search for Nostalgex, and choose Add app.
2. **From your phone or computer:** sign in to your Roku account and add it with the code **NOSTALGEX**. The [Nostalgex for Roku page](https://www.nostalgex.app/roku?utm_source=blog&utm_medium=internal&utm_campaign=roku_launch_post&utm_content=add_steps) has the button that takes you straight there.

Then open it on the TV and sign in:

* **Plex:** scan the code on screen with your phone, or type your Plex email and password on the TV.
* **Jellyfin or Emby:** connect to your server. On Jellyfin you can approve a Quick Connect code instead of typing a password with the remote, which I highly recommend for your thumbs' sake.

That's the whole setup. Nothing gets installed on your server. No Docker, no plugins, no channel building.

![The Nostalgex sign in screen on Roku, with Connect to Plex, Use email and password, Jellyfin and Emby](https://pub-98e43e3b886d48018eab8387d373ddb4.r2.dev/site/blog/nostalgex-on-roku/roku-sign-in.webp)

## What do you actually get?

The same idea as the Apple TV app. Nostalgex reads your library and sorts it into 130+ themed channels on its own, like the back of an old cable bill: SAT MORNING CARTOONS, 90S SITCOMS, AFTER SCHOOL TV, VHS VAULT, teen movies, rom coms and a lot more. You never program a channel. It looks at genres, decades, studios and series, and the channels fill from what you own.

* **A real guide** that shows what's on now and next.
* **Every channel keeps running** on a set daily schedule, so you land in the middle of something, like real TV.
* **Film series get their own channels.** FRANCHISES is one section in Settings, and your server's collections can become channels too.
* **Retro mode** for that old CRT look, or switch it off.
* **Captions and subtitles**, with audio and subtitle language in Settings.
* **After a power cut**, it opens on your first channel and plays it while your library loads. You're watching in seconds instead of staring at a loading screen.

![The Nostalgex channel strip on Roku over a cartoon playing full screen, with the next channels lined up along the bottom](https://pub-98e43e3b886d48018eab8387d373ddb4.r2.dev/site/blog/nostalgex-on-roku/roku-flip-strip.webp)

Which channels show up depends on your library. If you don't own enough found footage horror, FOUND FOOTAGE waits until you do. That's on purpose. I'd rather show you 40 channels that are good than 130 that are mostly reruns of the same three movies.

## Does it cost anything?

No. Nostalgex is free on Roku, free on Apple TV, and free in your browser. The Apple TV app has an optional tip jar that unlocks nothing. The whole thing is open source under MIT, and the Roku app's source sits in the [roku folder on GitHub](https://github.com/chadMueller/Nostalgex/tree/main/roku?utm_source=blog&utm_medium=internal&utm_campaign=roku_launch_post&utm_content=github).

The one thing you need is your own Plex, Jellyfin or Emby server with movies or shows on it. Nostalgex plays your library. It doesn't host or supply any video.

## Which Roku devices does it work on?

So far it's been tested on a Roku Streaming Stick Plus and TCL Roku TVs. If yours does something weird, tell me in [Discord](https://discord.gg/FgnZcr5bDT?utm_source=blog&utm_medium=internal&utm_campaign=roku_launch_post&utm_content=discord) and I'll add it to the list.

## Is it the same as the Apple TV app?

Close, and getting closer every week. Both build the same channels from the same rules, so your lineup looks familiar if you switch between them. The Apple TV app usually gets new features first, and the Roku app catches up.

If you've got an Apple TV in the living room and a Roku in the bedroom, you can run both on the same server. On Apple TV, Nostalgex is [free on the App Store](https://apps.apple.com/app/apple-store/id6762563534?pt=128802261&ct=blog_roku_launch&mt=8), and the [Plex on Apple TV setup](https://www.nostalgex.app/plex?utm_source=blog&utm_medium=internal&utm_campaign=roku_launch_post&utm_content=plex_page) is about one minute.

## Want to try it before you grab the remote?

The free [web tuner at nostalgex.app](https://www.nostalgex.app/web-tuner?utm_source=blog&utm_medium=internal&utm_campaign=roku_launch_post&utm_content=web_tuner) runs the same channels in any browser, no account needed. Sign in, and you'll see what your library looks like as cable in about the time it takes to find the remote.

More reading if you're new here:

* [How to make Plex feel like cable TV again](https://www.nostalgex.app/blog/make-plex-feel-like-cable-tv?utm_source=blog&utm_medium=internal&utm_campaign=roku_launch_post&utm_content=related)
* [Plex Live TV and your own movies: what it does and doesn't do](https://www.nostalgex.app/blog/plex-virtual-channels-own-movies?utm_source=blog&utm_medium=internal&utm_campaign=roku_launch_post&utm_content=related)
* [A Jellyfin TV guide for your own library](https://www.nostalgex.app/blog/jellyfin-tv-guide-own-library?utm_source=blog&utm_medium=internal&utm_campaign=roku_launch_post&utm_content=related)

## FAQ

### Is Nostalgex on the Roku Channel Store?

Yes. Search for Nostalgex on your Roku, or add it from your Roku account with the code NOSTALGEX.

### Is Nostalgex free on Roku?

Yes. It's free and open source under MIT.

### Does Nostalgex on Roku work with Jellyfin and Emby?

Yes. It works with Plex, Jellyfin and Emby. Jellyfin can sign in with a Quick Connect code.

### Do I need to install anything on my server?

No. Nostalgex runs on the Roku and asks your server for each file when it's time to play. You need your own Plex, Jellyfin or Emby server with media on it.

### Does Nostalgex supply movies or shows?

No. It only plays the library on your own Plex, Jellyfin or Emby server.

### Is there a Fire TV or Android TV version?

Not yet. Android TV is the most requested thing after Roku, and it's on the list. On other devices, the web tuner runs in a browser today.
