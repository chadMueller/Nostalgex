---
title: "Does Plex Live TV Play Your Own Movies? How to Get Pluto Style Virtual Channels From Your Library"
seo_title: "Plex Virtual Channels From Your Own Movies"
description: "Plex Live TV won't play your own movies. Here's what it does, what needs Plex Pass, and how to get free Pluto style channels from your own Plex library."
excerpt: "Plex has a Live TV tab and a server full of your movies, but the two never meet. Here's why, and the ways to get Pluto style channels out of your own library."
author: "Chad Mueller"
slug: plex-virtual-channels-own-movies
date: 2026-10-22
updated: 2026-10-22
draft: true
---

# Does Plex Live TV Play Your Own Movies? How to Get Pluto Style Virtual Channels From Your Library

> No. Plex Live TV plays Plex's free streaming channels and antenna TV, not the movies on your server. To get Pluto style virtual channels from your own Plex library, you need a separate tool, either a server like Tunarr that poses as a tuner or an app. [Nostalgex](/) does it free on Apple TV and in a browser, building 131 channels automatically with no Plex Pass.

I get some version of this question every week, usually from someone who just found the Live TV tab in Plex and got excited for about thirty seconds. You've got a server with hundreds of movies on it. Plex has a Live TV section with a guide. Surely you can put your movies in the guide?

You can't, at least not with Plex alone. I'll explain what Live TV actually is, then the ways to get the thing you were hoping for. I built Nostalgex, one of those ways, so factor that in.

## Is Plex like Pluto TV?

Pretty close, actually. The Live TV section in Plex is mostly a free, ad supported streaming service. Plex licenses channels and runs them with commercials, which is the same model as Pluto TV or the Roku Channel. They keep adding more, too. [Pocket Lint wrote up four more](https://www.pocket-lint.com/plex-adds-4-new-free-live-tv-channels-to-its-streaming-lineup/) recently.

So if you searched "is Plex like Pluto TV," the answer is yes, for that part of Plex. It's a different thing from your personal media, and that's the part that trips people up.

## Can you make virtual channels in Plex from your own movies?

Not with Plex Live TV on its own. Here are the three routes, side by side:

| Route | What you get | What it takes |
|---|---|---|
| Plex Live TV | Plex's free streaming channels and antenna TV | Nothing, but your own movies never show up |
| Tunarr or ErsatzTV added to Plex as a tuner | Your own channels inside Plex's guide | A separate server, schedules you build, and Plex's tuner setup |
| An app like Nostalgex | 131 channels built from your library | Install the Apple TV app and sign in with a code |

 The guide in Plex fills from two places: Plex's free streaming channels, and a tuner you connect to your server. A tuner usually means an HDHomeRun and an antenna for broadcast TV.

Per [Plex's own support page](https://support.plex.tv/articles/226463767-frequently-asked-questions-dvr-live-tv/), watching antenna TV live through a tuner is free, and recording it needs Plex Pass. Neither one puts The Goonies on channel 7 at 8 o'clock.

The workaround people have used for years is to fake a tuner. Tools like Tunarr or ErsatzTV build channels out of your library and pretend to be an HDHomeRun, and Plex happily adds them to the guide. It works, and threads like [this one on r/PlexMedia](https://www.reddit.com/r/PlexMedia/comments/1p4gx2d/plex_virtual_channels_make_your_own_tv_stations/) are full of people who love it. You're also running another server, building your own schedules, and sorting out transcoding. I went deep on that route in [a separate post about Tunarr and ErsatzTV](/blog/tunarr-ersatztv-alternative-apple-tv).

## How do I make a 24/7 channel from my Plex library?

Use an app that builds the channels itself instead of going through Plex Live TV at all. The app reads your library, makes a schedule, and asks your Plex server for each file when it's time to play. Nothing to install on the server, no fake tuner.

That's the gap I built Nostalgex for. If what you're after is the feeling of flipping past a sitcom rerun and landing on a movie you haven't seen in years, this is the easy way to get it. You install it on your Apple TV, sign in with a code at plex.tv/link, and it builds 131 channels in 14 bundles from what you own. You don't choose what goes on each channel. It sorts things by genre, decade, studio and franchise on its own, so you get stuff like SAT MORNING CARTOONS, 90S SITCOMS, VHS VAULT and BUDDIES (home of our [Friday buddy cop lineup](/blog/best-90s-buddy-cop-movies-channel)). Every channel keeps running even when nobody's watching, so you land in the middle of something like real TV.

It's basically Pluto, except the channels are made of your movies and there are no commercials. It's free, open source under MIT, and has no ads or account. It needs tvOS 18 or later. The [Nostalgex for Plex](/plex) page has the one minute setup.

Want to compare Coax and Bunny Ears TV too? See [the best channel surfing apps for Apple TV](/blog/apple-tv-channel-surfing-apps).

I'm not going to repeat the full Plex setup here, because I already wrote it up in [how to make Plex feel like cable TV](/blog/make-plex-feel-like-cable-tv). That post covers why a guide beats a poster wall and walks through every step.

## Do I need Plex Pass for channels made from my own library?

Not with Nostalgex. It doesn't use Plex Live TV or Plex DVR, so none of the Plex Pass features come into it. It needs nothing paid at all: no Plex Pass, no subscription, nothing.

One honest footnote, since it's Plex's rule and not mine. Streaming your own media from outside your home network needs a Remote Watch Pass or Plex Pass, according to Plex's [free vs paid page](https://support.plex.tv/articles/202526943-plex-free-vs-paid/). On your own network, which is where an Apple TV usually lives, there's nothing to pay.

If you go the fake tuner route with Tunarr or ErsatzTV, watching those channels in Plex works through Plex's Live TV and DVR setup, so check Plex's current requirements for that path before you commit.

## Can I watch my Plex channels in a web browser?

Yes. The free [web tuner](/web-tuner) runs the same idea in a browser, and it's the quickest way to see if you like it. Browsers need the server on https, and Plex handles that for you by giving servers secure addresses, so most Plex setups just work. Connect, and your channels are already on.

The web tuner and the Apple TV app don't show identical lineups, by the way. The Apple TV app has a few extra scheduling tricks, like putting new additions in prime time.

## What kinds of channels do you get?

The 131 channels come in 14 bundles, and the ones you see depend on what's in your library. There are decades, genres, studios and franchises, plus the comfort stuff like SAT MORNING CARTOONS, 90S SITCOMS and VHS VAULT. You can switch whole bundles on and off in settings, but you never have to program a channel.

This month there's a free SCREAM bundle you can turn on with one button. It adds four horror channels: 137 SCREAM KIDS, 138 FRIGHT NIGHT, 139 SCREAM ADULTS and 140 NOSTALGEX HORROR. SCREAM KIDS is for the little ones, and NOSTALGEX HORROR sticks to 1975 through 1999. If you want a preview of what a night on those feels like, I wrote up [a 90s slasher marathon](/blog/90s-slasher-movies-halloween-marathon).

Get Nostalgex free on the [App Store](https://apps.apple.com/app/nostalgex/id6762563534) or try the [web tuner](/web-tuner) tonight.

## FAQ

### Is Plex like Pluto TV?

Plex's Live TV section is, since it's a free, ad supported set of streaming channels. Your own movies and shows are a separate part of Plex and don't appear in that guide.

### Can I add my own movies to Plex Live TV?

Not directly. You'd need a tool like Tunarr or ErsatzTV that pretends to be a tuner. Or you can skip Plex Live TV and use an app like Nostalgex, which builds channels from your library on its own.

### Do I need Plex Pass to use Nostalgex?

No. Nostalgex needs no paid service. It doesn't use Plex Live TV or DVR. A free Plex account works.

### Is NostalgiaTV for Plex on Apple TV?

No. NostalgiaTV is a separate app for Plex, Jellyfin and Emby that runs on Android, Android TV and Amazon devices. If you're on Apple TV, Nostalgex does the same kind of thing for free.

### Does Nostalgex work on Roku or Fire TV?

No. Nostalgex runs on Apple TV with tvOS 18 or later, and in a browser through the web tuner.

<!--
Build notes: build-blog.mjs ignores author, updated and excerpt today. Article JSON-LD author is the Organization and dateModified equals datePublished until the build reads these fields.
Intended schema: FAQPage from the FAQ H3s. Article "about": {"@id": "https://www.nostalgex.app/#app"}. No separate SoftwareApplication block.
Image to add (none exist yet): alt "Nostalgex guide on Apple TV showing the BUDDIES and VHS VAULT channels built from a Plex library".
Links to /blog/tunarr-ersatztv-alternative-apple-tv (Oct 13), /blog/apple-tv-channel-surfing-apps (Oct 20), /blog/best-90s-buddy-cop-movies-channel (Oct 10) and /blog/make-plex-feel-like-cable-tv (Oct 17). Confirm the cable post is live before publishing Oct 22; if it slipped, cut the "I'm not going to repeat the full Plex setup here" link.
REMINDER Nov 1: trim the SCREAM paragraph in "What kinds of channels do you get?".
Chad: request indexing for /plex in Search Console.
-->
