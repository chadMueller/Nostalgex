---
title: "Franchise Marathons From Your Own Plex, Jellyfin or Emby Library, TV Spinoffs Included"
seo_title: "Franchise Marathons From Your Own Library"
description: "Nostalgex turns the film series in your Plex, Jellyfin or Emby library into live franchise channels on Apple TV, with TV spinoffs mixed in with the films."
slug: franchise-channels-your-collections
date: 2026-10-23
draft: false
keyword: "plex franchise marathon"
cover: "https://pub-98e43e3b886d48018eab8387d373ddb4.r2.dev/site/blog/franchise-channels-your-collections/cover.jpg"
cover_alt: "Nostalgex TV guide on Apple TV with the JASON BOURNE franchise channel airing The Bourne Ultimatum from a Plex library, next to LORD OF THE RINGS, MISSION IMPOSSIBLE, AMERICAN PIE and BAD BOYS"
author: "Chad Mueller"
excerpt: "A franchise marathon without the planning. Nostalgex turns the film series you own into live channels, and the TV spinoffs come along for the ride."
---

# Franchise marathons from your own library, TV spinoffs included

Every franchise marathon I've ever planned went the same way. Big plans for all of them in order. Then twenty minutes picking which one to start with, a debate about whether the prequels count, and somebody falls asleep before the sequel.

So I let the TV do it. Since Nostalgex 1.0.26 on Apple TV, the film series in your own Plex, Jellyfin or Emby library get their own live channels. You flip to one and the marathon is already going. And like the rest of the app, it's plug and play: no server plugin, no Docker needed, no playlists to build.

Here's how franchise channels work, where the TV shows come in, and a few marathons worth flipping to this weekend.

![Nostalgex TV guide on Apple TV with the FAST & FURIOUS channel airing The Fast and the Furious: Tokyo Drift, above AMERICAN PIE, BAD BOYS and CAPTAIN AMERICA channels built from a Plex library](https://pub-98e43e3b886d48018eab8387d373ddb4.r2.dev/site/blog/franchise-channels-your-collections/library-franchises-guide.webp)

## What is a franchise channel?

A franchise channel is a live channel that airs one film series from your own library, all day, like everything else in Nostalgex. It's plug and play. You don't schedule anything, you don't build a playlist, and you don't decide what goes first. Nostalgex builds the channel and runs the schedule from what you own. When you tune in, you land wherever the schedule is, the same as real TV.

That's the fun part. Turn on JASON BOURNE and you're an hour and a half into The Bourne Ultimatum, with The Bourne Legacy up next. You weren't going to start there. You're staying anyway.

## Which franchise channels are there?

Two kinds, and they sit in two places on the dial.

**The classics, in the 100s.** These are channels for the big series a lot of libraries have. In my guide right now that's 101 MARVEL, 102 HARRY POTTER, 103 JURASSIC PARK, 104 LORD OF THE RINGS, 105 MISSION IMPOSSIBLE and 106 JASON BOURNE. They fill from the films you actually own.

**Your own, in the 300s.** This is where it gets personal. Nostalgex looks through your movies, works out which ones belong to the same series using TMDB and IMDb data, and any series where you own 3 or more films gets a channel. My library came up with 300 AMERICAN PIE, 301 BAD BOYS, 302 CAPTAIN AMERICA and 303 FAST & FURIOUS. Yours will be different, because your shelf is different. That's the point.

Two films is a double feature, not a channel. Three or more and there's enough to keep a schedule going.

## Do TV spinoffs show up on franchise channels?

Yes, and it's my favourite surprise in the whole feature. If you own a show from the same franchise, it can mix in with the films. Flip to 103 JURASSIC PARK in my guide and Jurassic World: Camp Cretaceous is on, with Jurassic World: Chaos Theory coming up after it.

![Nostalgex TV guide on Apple TV with the JURASSIC PARK channel airing Jurassic World: Camp Cretaceous and Chaos Theory, next to LORD OF THE RINGS and MISSION IMPOSSIBLE channels](https://pub-98e43e3b886d48018eab8387d373ddb4.r2.dev/site/blog/franchise-channels-your-collections/jurassic-park-guide.webp)

That's how a franchise used to feel on cable. You'd catch the movie on one night and the cartoon on Saturday morning, and it all counted.

## What about the collections I already made on my server?

They still count, and they won't show up twice. If you already made a collection for a series on your Plex, Jellyfin or Emby server and Nostalgex found the same series on its own, it's folded into one channel instead of two.

The rest of your collections come along too. In Settings, under MY COLLECTIONS, press SCAN MY COLLECTIONS and Nostalgex lists the movie collections on your server so you can turn the ones you want into channels. Film series land in FRANCHISES. Everything else, like actor and director sets or a holiday shelf, lands in OTHER COLLECTIONS.

## Where do I turn franchise channels on?

Open Settings on your Apple TV and go to CHANNEL PACKAGES. Turn on FRANCHISES. Give it a moment while it builds.

Once it's on, a list called YOUR FRANCHISES opens right under it, with a switch for every series Nostalgex found, plus ADD ALL and REMOVE ALL. So if you want BAD BOYS and JASON BOURNE but would rather keep AMERICAN PIE off the TV when your parents visit, you can. Nothing else in your lineup changes.

## Five franchise marathons worth flipping to

These are straight off my guide this week. Yours will look a little different, since every channel fills from what you own.

1. **JASON BOURNE.** The Bourne Ultimatum into The Bourne Legacy. Peak "one more and then bed" energy.
2. **LORD OF THE RINGS.** The Fellowship of the Ring, then The Hobbit: The Battle of the Five Armies. Middle-earth doesn't care about release order, and honestly neither do I.
3. **AMERICAN PIE.** American Wedding, then American Pie Presents: Beta House. Maybe not with your parents in the room.
4. **BAD BOYS.** Bad Boys: Ride or Die, then Bad Boys II. Miami, explosions, Saturday afternoon sorted.
5. **CAPTAIN AMERICA.** Captain America: The First Avenger, then Captain America: Brave New World, while MARVEL runs its own thing on 101.

If you'd rather have a whole genre than one series, my posts on the [best 90s buddy cop movies channel](https://www.nostalgex.app/blog/best-90s-buddy-cop-movies-channel?utm_source=blog&utm_medium=internal&utm_campaign=launch_oct26_blog_franchises&utm_content=buddy_cop_post) and a [90s slasher movie marathon](https://www.nostalgex.app/blog/90s-slasher-movies-halloween-marathon?utm_source=blog&utm_medium=internal&utm_campaign=launch_oct26_blog_franchises&utm_content=slasher_post) show how those channels fill up from a normal library.

## Why doesn't one of my series show up?

Usually one of three things:

1. **You own fewer than three films from it.** Two isn't enough for a channel yet.
2. **A film isn't matched.** If a movie has an odd title or year on your server, it may not match its series. Fix the match on the server and let Nostalgex rescan.
3. **The package is off.** The YOUR FRANCHISES list only shows up when FRANCHISES is on.

## Does it work with Jellyfin and Emby?

Yes. Franchise channels work the same way on Plex, Jellyfin and Emby, and Emby is officially supported since 1.0.26. The [Plex](https://www.nostalgex.app/plex?utm_source=blog&utm_medium=internal&utm_campaign=launch_oct26_blog_franchises&utm_content=plex_page), [Jellyfin](https://www.nostalgex.app/jellyfin?utm_source=blog&utm_medium=internal&utm_campaign=launch_oct26_blog_franchises&utm_content=jellyfin_page) and [Emby](https://www.nostalgex.app/emby?utm_source=blog&utm_medium=internal&utm_campaign=launch_oct26_blog_franchises&utm_content=emby_page) pages cover connecting each one, and the [1.0.26 release notes](https://www.nostalgex.app/blog/nostalgex-1-0-26-franchise-channels?utm_source=blog&utm_medium=internal&utm_campaign=launch_oct26_blog_franchises&utm_content=release_post) have everything else that came with it.

## How do I start a franchise marathon tonight?

Get Nostalgex on your Apple TV (tvOS 18 or later) and connect your server. On Plex that's scanning the code on screen with your phone. On Jellyfin you pick your server from the list it finds on your network and approve a Quick Connect code, and on Emby you sign in with your username and password. Then turn on FRANCHISES under CHANNEL PACKAGES in Settings. You'll get 130+ channels built from your own library, with your franchises right there on the dial. Then flip around and see which sequel is on right now.

Free on Apple TV, [get it on the App Store](https://apps.apple.com/app/apple-store/id6762563534?pt=128802261&ct=blog_franchises&mt=8). Open source (MIT), no account. No Apple TV handy? The [web tuner](https://www.nostalgex.app/web-tuner?utm_source=blog&utm_medium=internal&utm_campaign=launch_oct26_blog_franchises&utm_content=web_tuner) shows you what Nostalgex does with your library in a browser, and the [support page](https://www.nostalgex.app/support?utm_source=blog&utm_medium=internal&utm_campaign=launch_oct26_blog_franchises&utm_content=support) has fixes if connecting gets stuck.

See you on the dial.

Chad

