---
title: "How to Run the Nostalgex Web Tuner in a Docker Container (Tuner 1.0.1: Sleep Timer, Playback Info and Connect with Emby)"
seo_title: "Run the Nostalgex Web Tuner in Docker"
description: "Run the free Nostalgex web tuner as a Docker container at home in one command. Plus what's new in tuner 1.0.1: sleep timer, playback info, Emby and more."
slug: docker-web-tuner-1-0-1-how-to
date: 2026-10-30
draft: false
keyword: "jellyfin tv guide docker"
cover: "https://pub-98e43e3b886d48018eab8387d373ddb4.r2.dev/site/blog/docker-web-tuner-1-0-1-how-to/header.webp"
cover_alt: "The Nostalgex web tuner running from a Docker container in a desktop browser, with the SCREAM horror channels in the guide"
og_image: "https://pub-98e43e3b886d48018eab8387d373ddb4.r2.dev/site/blog/docker-web-tuner-1-0-1-how-to/cover.jpg"
og_image_alt: "The Nostalgex web tuner running from a Docker container in a desktop browser, with the SCREAM horror channels in the guide"
author: "Chad Mueller"
excerpt: "One docker run and the Nostalgex web tuner is on your home network, plain http Jellyfin and Emby included. Here's how, plus everything new in tuner 1.0.1."
---

# How to run the Nostalgex web tuner in a Docker container

> The Nostalgex web tuner ships as a Docker container: `docker run -d --name nostalgex -p 8080:8080 --restart unless-stopped ghcr.io/chadmueller/nostalgex:latest`, then open `http://YOUR-SERVER-IP:8080`. It's the same free tuner as nostalgex.app, with 130+ channels, served over plain http on your network, so it can reach Jellyfin or Emby servers that don't have https. Tuner 1.0.1 adds a sleep timer, playback info, a Connect with Emby button, eight SCREAM channels, and MYSTERY BOX TV, CRINGE TV and A24.

The number one thing Jellyfin and Emby folks asked me for was "can I just run it myself?" Yes. Now you can, and it takes about as long as microwaving popcorn.

## Who is the Docker container for?

The web tuner at [nostalgex.app](https://www.nostalgex.app/web-tuner?utm_source=blog&utm_medium=internal&utm_campaign=launch_oct26_blog_docker_tuner&utm_content=web_tuner) is served over https. Browsers block an https page from talking to a plain `http://` address, and there's no setting that turns that off. Plex gets past it because it hands out real certificates for local addresses. Jellyfin and Emby usually don't, so a server at `http://192.168.1.50:8096` is out of reach from the hosted tuner.

Run the tuner as a Docker container on your own network and it's plain http too. Same network, same protocol, no block.

You probably **don't** need it if:

* You use Plex and watch on Apple TV. Get the [free App Store app](https://apps.apple.com/app/apple-store/id6762563534?pt=128802261&ct=blog_docker_tuner&mt=8) and you're done.
* You use Plex in a browser. The hosted tuner already works.
* Your Jellyfin or Emby server already has https with a valid certificate.

Moving from Plex? Here's [what happens to your channel guide](https://www.nostalgex.app/blog/plex-to-jellyfin-emby-cable-guide?utm_source=blog&utm_medium=internal&utm_campaign=launch_oct26_blog_docker_tuner&utm_content=switch_post).

What's left is the case it's built for: Jellyfin or Emby on plain http at home, and you want channels in a browser. Or you just like running things yourself. I get it.

## What do I need?

* A machine that stays on and runs Docker: a NAS, a mini PC, a Raspberry Pi 4 or 5 on a 64 bit OS, a spare Mac. If it already runs your media server, run it there.
* The same network as your media server.
* amd64 or arm64. There's no armv7 build.
* One free port. 8080 by default.

## How do I install it?

One command:

```sh
docker run -d --name nostalgex -p 8080:8080 --restart unless-stopped ghcr.io/chadmueller/nostalgex:latest
```

Then open `http://YOUR-SERVER-IP:8080` in a browser on your network, using whatever address that machine answers on. Connect Plex, Jellyfin or Emby the same way you would on nostalgex.app.

Port 8080 already taken? Use `-p 8099:8080` and open port 8099 instead.

Prefer Compose? Drop this next to your other compose files and run `docker compose up -d`:

```yaml
services:
  nostalgex:
    image: ghcr.io/chadmueller/nostalgex:latest
    container_name: nostalgex
    ports:
      - "8080:8080"
    environment:
      NOSTALGEX_ENRICHMENT: "on"
    read_only: true
    tmpfs:
      - /tmp
    restart: unless-stopped
```

There's a fuller version at [`docker/compose.yaml`](https://github.com/chadMueller/Nostalgex/blob/main/docker/compose.yaml?utm_source=nostalgex_blog&utm_medium=referral&utm_campaign=launch_oct26_blog_docker_tuner&utm_content=compose_file) in the repo, which also sets `no-new-privileges`.

The image is nginx serving static files on port 8080. No database, nothing to sign up for, and nothing gets installed on your media server. It runs as a non root user and is happy with a read only root filesystem as long as `/tmp` is writable.

## How do I update to tuner 1.0.1?

```sh
docker compose pull && docker compose up -d
```

Or `docker pull ghcr.io/chadmueller/nostalgex:latest` and recreate the container. The image tags are `1.0.1`, `1.0` and `latest`, so you can pin a version if you'd rather not move with `latest`.

## What's new in tuner 1.0.1?

All of this is on nostalgex.app too, since it's the same tuner. Here's the [full release](https://github.com/chadMueller/Nostalgex/releases/tag/tuner-v1.0.1?utm_source=nostalgex_blog&utm_medium=referral&utm_campaign=launch_oct26_blog_docker_tuner&utm_content=release).

### A sleep timer

**SLEEP** in the side menu next to the guide: 15 MIN, 30 MIN or 1 HR, with the time left right on the button. When it hits zero it asks "Still watching?" for 20 seconds, then stops the picture and goes back to the guide. Pick a channel to start again. On a small screen it's under MENU.

I added this because I fell asleep to the same slasher three nights running.

![The SLEEP button in the Nostalgex web tuner side menu counting down the time left, with the 15 MIN sleep timer running](https://pub-98e43e3b886d48018eab8387d373ddb4.r2.dev/site/blog/docker-web-tuner-1-0-1-how-to/sleep-timer.webp)

### Playback information

**INFO** in the side menu, or press **I**. It shows what's playing and how: Direct Play or a server stream, the picture size, the codecs, and why it fell back if it did. It's also under Settings > PLAYBACK. If you ever send me a "this won't play" report, a look at this panel saves us both a lot of guessing.

![The playback information panel in the Nostalgex web tuner showing Direct Play and the video and audio codecs](https://pub-98e43e3b886d48018eab8387d373ddb4.r2.dev/site/blog/docker-web-tuner-1-0-1-how-to/playback-info.webp)

### Connect with Emby

Emby has its own button now. **Connect with Emby** on the sign in page, with your Emby username and password. Before this, Emby went through the Jellyfin option and the library never loaded. If you signed in that way, you're switched over on the next load without signing in again.

In the Docker container, a plain `http://` Emby address works. On nostalgex.app it has to be https.

### SCREAM goes from 4 channels to 8

SLASHER, HORROR COMEDY, FOUND FOOTAGE and WORLD HORROR join SCREAM KIDS, FRIGHT NIGHT, SCREAM ADULTS and NOSTALGEX HORROR, on channels 137 to 144. Thanks to @tydude001 for the channel ideas. Switch SCREAM on in Settings and its channels build from the horror movies you own. It also stays on in any month now, so if you're a Halloween in July person, I see you.

### Three more channels

**MYSTERY BOX TV** (84), **CRINGE TV** (55) and **A24** (118), any month.

One heads up for all the new ones: a channel with too few titles in your library stays hidden until you have enough for it. If you're light on found footage, that one waits for you.

### Two separate switches

**Show Now Playing** and **Mark Watched** are separate switches in Settings now, instead of one Report Playback switch. They start off, and if you had Report Playback on, both stay on. Thanks to @w6trp.

## What leaves my network?

The point of running it yourself is knowing where things go, so here's the whole list:

* **Your media server.** Sign in and playback go straight from your browser to your server.
* **plex.tv.** Plex only, for the code sign in and finding your server, like every Plex app.
* **The shared metadata cache and the nostalgex.app relay.** On by default, because some channels (TEEN MOVIES, TRUE CRIME, CULT CLASSICS and others) need keywords, studios or ratings to fill. Only TMDB and IMDb ids leave the browser. No titles, no server address, no credentials. Set `NOSTALGEX_ENRICHMENT: "off"` to turn it off.

There are no analytics in the image. With enrichment off and Jellyfin or Emby, your browser talks to the container and your server and nothing else.

## Why can't the tuner reach my server behind a reverse proxy?

This is the one that catches people. If you put the tuner behind https, say `https://nostalgex.mydomain.com`, but your Jellyfin is still plain http, the browser blocks Jellyfin again. Serve both the same way. Both on plain http inside your network is the simple setup, and it's the one this is built for.

More troubleshooting is in the [Docker container guide](https://www.nostalgex.app/self-host?utm_source=blog&utm_medium=internal&utm_campaign=launch_oct26_blog_docker_tuner&utm_content=docker_guide) and on the [support page](https://www.nostalgex.app/support?utm_source=blog&utm_medium=internal&utm_campaign=launch_oct26_blog_docker_tuner&utm_content=support).

## FAQ

### What is the Nostalgex Docker image called?

`ghcr.io/chadmueller/nostalgex`. Tags are `latest`, `1.0` and `1.0.1`.

### What port does the Nostalgex container use?

8080 inside the container. Map any free port on the left side of `-p`, like `-p 8099:8080`.

### Does the Docker container work with plain http Jellyfin and Emby?

Yes. That's the main reason it exists. The container serves the tuner over plain http on your network, so it can reach plain http servers that nostalgex.app can't.

### Do Plex users need the container?

Usually not. The hosted web tuner and the Apple TV app both reach Plex as is.

### Is the Docker container free?

Yes. It's free and open source (MIT), no account, and the whole thing is in the [GitHub repo](https://github.com/chadMueller/Nostalgex?utm_source=nostalgex_blog&utm_medium=referral&utm_campaign=launch_oct26_blog_docker_tuner&utm_content=repo) if you'd rather build it yourself.

<!--
NOTES (not rendered)
Verified Oct 19, 2026 against github.com/chadMueller/Nostalgex:
- Release tuner-v1.0.1 (published Oct 16, 2026, 6:45 PM Toronto): https://github.com/chadMueller/Nostalgex/releases/tag/tuner-v1.0.1 . Source for sleep timer (15 MIN, 30 MIN, 1 HR, "Still watching?" 20 s, MENU on phones), INFO / I key / Settings > PLAYBACK, Connect with Emby (username and password, auto switch of old Jellyfin route sign ins, http in container vs https on nostalgex.app), SCREAM 4 to 8, @tydude001, MYSTERY BOX TV / CRINGE TV / A24, thin channels hidden, Show Now Playing and Mark Watched split (@w6trp), update commands, image tags 1.0.1 / 1.0 / latest.
- Image name ghcr.io/chadmueller/nostalgex, docker run command, compose block, port remap, amd64/arm64 no armv7, uid 101 non root, read only + /tmp: README "Docker container" sections, docker/compose.yaml, .github/workflows/docker.yml, and the live https://www.nostalgex.app/self-host page.
- Channel numbers from public/channels.json: SLASHER 141, HORROR COMEDY 142, FOUND FOOTAGE 143, WORLD HORROR 144, SCREAM KIDS 137, MYSTERY BOX TV 84, CRINGE TV 55, A24 118.
- "SCREAM stays on in any month": release notes. The same release says the holiday bundle does too; held per brief, not mentioned.
- Playback information is also in Apple TV 1.0.27, which is unreleased, so the post does not mention the Apple TV app panel.
- Avoided: the own-server phrasing (the self-host page heading uses it), browser compatibility claims for specific TVs and phones, any date for future channels.
- The hosted desktop sign in page header shows GitHub, Discord and Instagram icons (seen in the Oct 17 capture); captures must avoid them (third party logos). Use a guide or side menu view.
Internal links: live pages only (/web-tuner, /self-host, /support). GitHub links untagged (external). App Store link has pt=128802261 and its own ct.
Images (3, uploaded Oct 30): cover from web-oct29 10.27.53, sleep timer web-oct30 b.png, playback info web-oct30 a.png. Was: cover B1, sleep timer B2, playback info B3. See calendar/WEEKLY-PLAN-oct19.md.
ADD LINKS BACK when live:
1. Once /blog/plex-to-jellyfin-emby-cable-guide is live (Oct 23): add to "Who is the Docker container for?": "Moving from Plex? Here's [what happens to your channel guide](https://www.nostalgex.app/blog/plex-to-jellyfin-emby-cable-guide?utm_source=blog&utm_medium=internal&utm_campaign=launch_oct26_blog_docker_tuner&utm_content=switch_post)."
-->
