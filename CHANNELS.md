# Nostalgex Channel Guide

<!-- GENERATED FILE — do not edit by hand. Run `npm run channels:doc` after any
     channels.json change. Source: scripts/render-channels-doc.mjs -->

Quick reference for every channel and bundle. Source of truth: `channels.json`.

## Read this before editing a channel

**`id` and `number` are NOT the same thing.** A channel's `number` is what
viewers tune to; its `id` is the stable key everything else references. They
drifted apart as channels were renumbered, and today they differ for many
channels — for example `id` 40 is **CH121 TRUE CRIME**, and `id` 211 is
**CH150 CRITERION**. Get it wrong and you edit a different channel than the one
you meant.

Which key does what:

| Uses `id` | Uses `number` |
|---|---|
| `channels-memberships.json` (the TMDB membership manifest) | The on-screen channel number and guide ordering |
| `exclusiveRules.channelID` / `channelIDs` | Nothing else |
| `bundles[].channelIDs` | |
| Daily EPG manifest cache keys | |

Every table below shows both.

**Pool filter logic must stay aligned across three implementations.**
`scripts/nostalgex-channel-filter.cjs` (web tuner + devtools) mirrors
`Nostalgex/Nostalgex/App/AppState+Channels.swift` → `filterItems` (tvOS).
They do not share code, so a rule change has to land in both or the platforms
drift. TMDB membership manifest: `channels-memberships.json`.

**Schedule ordering must stay aligned too.**
`scripts/nostalgex-daily-manifest.js` mirrors
`Nostalgex/Nostalgex/Models/SchedulePoolOrdering.swift` and
`Nostalgex/Nostalgex/Services/DailyManifestScheduler.swift`, bit-for-bit, so
web and Apple TV air the same program at the same time.

**Keyword matches are ADDITIVE.** They broaden what a channel can pull in; they
never gate it. Never gate keywords on a broad genre like Drama — it leaks
unrelated titles. `keywordGatedGenres` is the deliberate exception, and it must
only name the channel's own defining genre.

**`rewatched` means `viewCount >= 3`** in both implementations.

**Config version:** 49 · **142 channels** across **14 bundles** · 123 channels whose `id` differs from their `number`.

---

## Bundles

| Bundle | Bundle ID | Channels | Range | Description |
|---|---|---|---|---|
| NOSTALGEX | `nostalgex` | 22 | CH 1–22 | The 80s and 90s. All retro, all the time |
| KIDZ ZONE | `kids` | 15 | CH 30–44 | Disney, Nickelodeon, Pixar, and more |
| PRIME TIME | `essentials` | 16 | CH 50–65 | Everyday favorites and feel-good viewing |
| MARQUEE | `premium` | 11 | CH 70–80 | Premium channels |
| ADVENTURELAND | `adventureland` | 9 | CH 90–98 | Epic quests, disasters, and adrenaline |
| OVERTIME | `sports` | 3 | CH 110–112 | Movies, shows, and docs |
| CASE FILES | `truecrime` | 6 | CH 120–125 | True crime, thrillers & mystery |
| DECADES | `decades` | 7 | CH 130–136 | Movies and shows sorted by decade |
| ARTHOUSE | `arthouse` | 4 | CH 150–153 | Criterion, foreign films, midnight movies, and cult classics |
| NETWORKS | `streamers` | 12 | CH 160–171 | Channels by streaming service and studio |
| SCREAM | `seasonal` | 8 | CH 180–187 | Horror, all year's worth, front and centre every October. Spotlighted Oct. Off until switched on, then on in any month. |
| TIS THE SEASON | `tis-the-season` | 8 | CH 190–197 | Christmas, Thanksgiving and holiday channels. Spotlighted from 7 days before US Thanksgiving (the fourth Thursday of November) through Dec. Off until switched on, then on in any month. |
| FRANCHISES | `franchises` | 7 | CH 300–306 | Movie franchise marathons |
| HIGH ROTATION | `high-rotation` | 14 | CH 500–513 | Music videos by genre |

Bundled channels: 142 of 142.

---

## Channel exclusivity

Exclusive rules block a title from EVERY channel except the listed channel
`id`s. **Only lock a title to a channel when you are 95%+ sure it belongs
nowhere else — default to overlap.** Over-locking hides content: locking Die
Hard into the holiday channel made it vanish from action for eleven months of
the year.

A lock reads the item's own title (the song for a music video, never the
artist), with any " (YYYY)" suffix ignored. `editorialTitles` must match the
whole title exactly. `titleContains` matches whole words only, the same rule
as a channel's `titleContains`: "Noel" catches Noel, not Noelle, and "Santa
Claus" does not catch Santana. A lock can be scoped with `type` and `source`;
then it only applies to items of that type from that kind of library. Both filters
implement it (`ExclusiveRule.matches` in Swift, `exclusiveRuleMatches` in the
web filter) and `scripts/filter-golden.json` pins the cases.

| Locked to | Matches on | Notes |
|---|---|---|
| CH190 HOLIDAZE (id 130)<br>CH191 SANTA'S LIST (id 409)<br>CH192 NAUGHTY LIST (id 410)<br>CH193 NOSTALGEX CHRISTMAS (id 411)<br>CH194 MISTLETOE (id 412)<br>CH195 CHRISTMAS SPECIALS (id 413)<br>CH196 KIDS CHRISTMAS TV (id 414) | genres Holiday/Christmas, 14 title words, 47 exact titles, only movies from the movie library | Christmas films belong to the TIS THE SEASON channels, including the two TV channels, which air half-hour specials stored as films. Films in a movie library only (`type: movie`, `source: movie`), so a show with Santa in its name and a Christmas song on a music video stay free. Title words are the ones that measured 95% or more Christmas across TMDB films with 25+ votes (2026-10-18): "Holiday" (66%, Mr. Bean's Holiday, Roman Holiday), "Santa" (87%, Santa Sangre, Santa Fe Trail), "Merry", "Snowman", "Grinch", "Scrooge", "Nutcracker" and "Reindeer" were dropped, so the channels still match them but no longer lock them away. Die Hard, Lethal Weapon, Reindeer Games, Rocky IV, Gremlins, Batman Returns, Trading Places, The Family Man, While You Were Sleeping and The Shop Around the Corner are deliberately NOT locked: Christmas-set, but they belong on their year-round channels too. |
| id 32 (missing)<br>CH70 ANIME (id 60) | genres Anime, TMDB manifest claim (`manifestExclusive`) | Anime is claimed by genre `Anime` OR by a TMDB-manifest claim (`manifestExclusive`), so manifest-claimed anime is blocked from the other animation channels even when Plex only tags it "Animation". The manifest builder gates these channels with `requireGenres: ["Animation"]` + `requireOriginalLanguage: ["ja"]` + `autoSweepCollections: false` so TMDB similar/collection noise cannot be claimed — that blocks live-action (Spy Kids) AND Western animation (An American Tail, Avatar, Castlevania). Strict Japanese anime only. Re-run the keyword tuner to apply changes. |
| CH182 SCREAM ADULTS (id 132)<br>CH184 SLASHER (id 415) | 22 exact titles, only movies from the movie library | The Scream and Halloween films, by exact title, so SCREAM ADULTS and SLASHER own them rather than the other horror channels. It used to match any title containing "scream" or "halloween", which hid Kicking & Screaming and Hubie Halloween from every channel they belong on. |

---

## Channels by bundle

### NOSTALGEX · CH 1–22

_The 80s and 90s. All retro, all the time_

| CH | `id` | Name | Color | Type | Min items | Rules |
|---|---|---|---|---|---|---|
| 1 | `1` | REWATCHABLES MOVIES | `#FFE500` | Movies | 5 | rewatched (viewCount ≥ 3) |
| 2 | `2` | REWATCHABLES TV | `#FFD000` | Episodes | 5 | rewatched (viewCount ≥ 3) |
| 3 | `3` | NOSTALGEX LOL | `#F1C40F` | Movies | 3 | incl Comedy, no Animation/Animated, kw excl (3), 1980-1999 |
| 4 | `4` | SAT MORNING CARTOONS | `#00DD88` | Episodes | 15 | incl Animation/Kids/Children/Cartoon/Animated, 1960-1999, rated TV-Y/TV-Y7/TV-G/G/unrated |
| 5 | `5` | 90S SITCOMS | `#9B59B6` | Episodes | 10 | incl Comedy, no Anime/Animation, 1990-1999 |
| 6 | `6` | AFTER SCHOOL TV | `#F39C12` | Episodes | 5 | incl Comedy/Drama/Family, no Animation/Anime/Cartoon, 1980-1999, rated TV-G/TV-PG/TV-14/unrated |
| 7 | `7` | VHS VAULT | `#E67E22` | Movies | 5 | 1980-1999 · _time: blocks R/NC-17 before 21:00_ |
| 8 | `8` | CLASSIC FAM JAMS | `#E05A32` | Movies | 3 | needs ALL Family, no Animation/Anime, 1960-1999 |
| 9 | `9` | GIRLS NIGHT | `#FF85A1` | Movies | 3 | needs ALL Romance, no Family/Children/Kids/Action/Adventure/Horror/Thriller/Crime +4 more, kw excl (10), 1960-2004 |
| 10 | `10` | TEEN MOVIES | `#FF5E8A` | Movies | 5 | incl Comedy/Drama/Romance, no Animation/Horror/Family, title blocklist (1), kw +20, kw needs genre Comedy/Romance/Drama, kw-gated genre Comedy/Drama/Romance, 1980-1999 |
| 11 | `11` | RETRO TOONS | `#2DC7B0` | Movies | 5 | incl Animation, kw +7, kw needs genre Animation/Family/Adventure, …-1999, rated G/PG/TV-Y/TV-Y7/TV-G/TV-PG/unrated |
| 12 | `12` | ACTION ADVENTURE | `#E74C3C` | Movies | 3 | incl Action/Adventure, no Thriller/Crime/War/Horror/Animation, 1980-1999 |
| 13 | `13` | LAST ACTION HEROES | `#B7410E` | Movies | 5 | incl Action/Thriller, no Family/Kids/Children/Animation/Animated/Fantasy/Comedy, kw +13, kw needs genre Action/Thriller, 1980-2002, ≥ 85 min |
| 14 | `14` | BUDDIES | `#F39C12` | Movies | 5 | incl Action/Comedy, no Animation/Animated/Horror/Kids/Children/Family/Romance, kw +10, kw needs genre Action/Comedy, 1980-2004 |
| 15 | **`215`** ⚠︎ | CARTOON NETWORK | `#00BFFF` | Episodes | 5 | networks Cartoon Network, title allowlist (39) |
| 16 | **`405`** ⚠︎ | DVD SHELF | `#C0392B` | Movies | 5 | 2000-2009 |
| 17 | **`406`** ⚠︎ | Y2K COMEDY | `#E67E22` | Movies | 3 | incl Comedy, no Animation/Animated, kw excl (3), 2000-2009 |
| 18 | **`407`** ⚠︎ | Y2K SITCOMS | `#F1C40F` | Episodes | 10 | incl Comedy, no Anime/Animation, 2000-2009 |
| 19 | **`216`** ⚠︎ | Y2K TOONS | `#1ABC9C` | Episodes | 5 | incl Animation/Kids/Children/Cartoon/Animated, 2000-2009, rated TV-Y/TV-Y7/TV-G/G/TV-PG/unrated |
| 20 | **`423`** ⚠︎ | 80S SITCOMS | `#8E44AD` | Episodes | 10 | incl Comedy, no Anime/Animation, 1980-1989 |
| 21 | **`424`** ⚠︎ | 80S LOL | `#D4AC0D` | Movies | 3 | incl Comedy, no Animation/Animated, kw excl (3), 1980-1989 |
| 22 | **`425`** ⚠︎ | 80S AFTER SCHOOL TV | `#D35400` | Episodes | 5 | incl Comedy/Drama/Family, no Animation/Anime/Cartoon, 1980-1989, rated TV-G/TV-PG/TV-14/unrated |

### KIDZ ZONE · CH 30–44

_Disney, Nickelodeon, Pixar, and more_

| CH | `id` | Name | Color | Type | Min items | Rules |
|---|---|---|---|---|---|---|
| 30 | **`20`** ⚠︎ | FAMILY HOUR | `#00C4FF` | Movies | 10 | needs ALL Family, rated G/PG/PG-13/unrated |
| 31 | **`21`** ⚠︎ | DIZ FLICKS | `#7B2FBE` | Movies | 3 | studios Disney/Walt Disney/Walt Disney Pictures +1 more, rated G/PG/PG-13/TV-Y/TV-Y7/TV-G/TV-PG/TV-14/unrated |
| 32 | **`22`** ⚠︎ | DIZNEY TOONS | `#9C27B0` | Movies | 3 | needs ALL Animation, studios Disney/Walt Disney/Walt Disney Pictures +1 more, rated G/PG/PG-13/TV-Y/TV-Y7/TV-G/TV-PG/unrated |
| 33 | **`23`** ⚠︎ | DIZ JUNIOR | `#7B68EE` | Episodes | 3 | studios Disney Junior/Disney Television Animation/Ludo Studio +3 more, title allowlist (19), 2010-…, rated TV-Y/TV-Y7/TV-G/G/unrated |
| 34 | **`24`** ⚠︎ | DIZ TV | `#AB47BC` | Episodes | 3 | studios Disney/Disney Channel/Disney Television Animation +2 more, networks Disney Channel/Disney XD/Disney+, rated TV-Y/TV-Y7/TV-G/TV-PG/TV-14/G/PG/unrated |
| 35 | **`25`** ⚠︎ | ANIMATION | `#FF5722` | Movies | 5 | incl Animation, prodCo DreamWorks Animation/Sony Pictures Animation/Warner Bros. Animation +9 more, rated G/PG/PG-13/TV-G/TV-PG/unrated |
| 36 | **`26`** ⚠︎ | SLIME TV | `#FF6600` | Episodes | 3 | networks Nickelodeon/Nick at Nite, rated TV-Y/TV-Y7/TV-G/TV-PG/TV-14/G/PG/unrated |
| 37 | **`27`** ⚠︎ | PIXAR MOVIES | `#00B894` | Movies | 3 | studios Pixar/Pixar Animation Studios, prodCo Pixar Animation Studios/Pixar, rated G/PG/PG-13/TV-Y/TV-Y7/TV-G/TV-PG/unrated |
| 38 | **`28`** ⚠︎ | MINION HQ | `#FDCB6E` | Movies | 3 | studios Illumination/Illumination Entertainment, prodCo Illumination Entertainment/Illumination |
| 39 | **`29`** ⚠︎ | TWEEN TV | `#FF69B4` | Episodes | 5 | no Animation/Anime/Cartoon, studios Disney Channel/Nickelodeon/Nickelodeon Productions +7 more, title allowlist (26), 1989-…, rated TV-G/TV-PG/TV-Y7/unrated |
| 40 | **`30`** ⚠︎ | TEEN DRAMA | `#E74C8B` | Episodes | 5 | incl Drama/Romance/Comedy, no Animation/Anime, kw +7, kw excl (8), 2000-…, rated TV-14/TV-PG |
| 41 | **`33`** ⚠︎ | FAMILY TV | `#FF7043` | Episodes | 10 | incl Family/Comedy/Drama, no Kids/Children/Cartoon, 2000-…, rated TV-G/TV-PG/TV-14/unrated |
| 42 | **`34`** ⚠︎ | NETFLIX KIDS | `#E50914` | Any | 3 | incl Family/Kids/Children/Comedy/Adventure, no Horror/Thriller, studios Netflix/Netflix Animation/Netflix Family, title allowlist (28), rated TV-Y/TV-Y7/TV-G/G/PG/TV-PG/unrated |
| 43 | **`218`** ⚠︎ | DREAMWORKS | `#2ECC71` | Any | 5 | studios DreamWorks Animation/Pacific Data Images, rated G/PG/PG-13/TV-Y/TV-Y7/TV-G/TV-PG/unrated |
| 44 | **`400`** ⚠︎ | TOON TOWN | `#FF9F1C` | Movies | 5 | kw +1, kw needs genre Animation/Family/Comedy, rated G/PG/PG-13/unrated |

### PRIME TIME · CH 50–65

_Everyday favorites and feel-good viewing_

| CH | `id` | Name | Color | Type | Min items | Rules |
|---|---|---|---|---|---|---|
| 50 | `50` | SITCOMS | `#9B59B6` | Episodes | 10 | incl Comedy, no Animation/Anime/Kids/Children/Family, kw +7 |
| 51 | `51` | FLICKS | `#FF6600` | Movies | 10 | no Horror/Kids/Children/Family |
| 52 | `52` | ROM COMS | `#FF85A1` | Movies | 50 | needs ALL Romance + Comedy, no Horror/Thriller/Action/Animation/Family |
| 53 | `53` | FEEL GOOD TV | `#7ED957` | Episodes | 5 | title allowlist (51) |
| 54 | `54` | REALITY TV | `#FF4500` | Episodes | 5 | incl Reality/Reality-TV/Docuseries, no Game Show/Game-Show/Competition |
| 55 | **`56`** ⚠︎ | DOCS | `#2E86C1` | Any | 5 | incl Documentary, no Sport, kw +7, kw needs genre Documentary |
| 56 | **`57`** ⚠︎ | LOL | `#F1C40F` | Movies | 5 | incl Comedy, no Horror/War/History/Documentary, kw excl (3), Plex rating ≥ 7 |
| 57 | **`59`** ⚠︎ | MAN CAVE | `#4A6741` | Episodes | 3 | incl Crime/Action, no Family/Children/Kids, title allowlist (8) |
| 58 | **`62`** ⚠︎ | FRESH | `#00E5FF` | Movies | 3 | released ≤ 6 mo ago, ≥ 60 min |
| 59 | **`66`** ⚠︎ | BLOCKBUSTER | `#F39C12` | Movies | 5 | incl Action/Adventure/Science Fiction, Plex rating ≥ 6 |
| 60 | **`200`** ⚠︎ | DRAMA TV | `#5A3E8A` | Episodes | 10 | incl Drama, no Animation/Comedy/Documentary/Horror/Reality/Kids/Children/Family, kw +5, kw needs genre Drama |
| 61 | **`210`** ⚠︎ | RECORD STORE | `#FF6B35` | Movies | 3 | incl Music, kw excl (4) |
| 62 | **`404`** ⚠︎ | HISTORY & BIO | `#A0522D` | Movies | 5 | incl History/Biography, no Documentary/Docuseries/Animation/Animated |
| 63 | **`402`** ⚠︎ | R RATED COMEDY | `#E84393` | Movies | 5 | incl Comedy, no Animation/Family/Children/Kids, title blocklist (6), 1995-2029, rated R |
| 64 | **`403`** ⚠︎ | PREMIERES | `#F72585` | Any | 1 | incl Action/Adventure/Animation/Anime/Biography/Cartoon +23 more, added ≤ 14 d ago |
| 65 | **`420`** ⚠︎ | CRINGE TV | `#F7DC6F` | Episodes | 3 | incl Comedy/Documentary, title allowlist (20), kw +9, kw needs genre Comedy, kw-gated genre Comedy/Documentary |

### MARQUEE · CH 70–80

_Premium channels_

| CH | `id` | Name | Color | Type | Min items | Rules |
|---|---|---|---|---|---|---|
| 70 | **`60`** ⚠︎ | ANIME | `#FF3D6E` | Any | 3 | **TMDB manifest + gated genre/keyword fallback**, incl Animation/Anime, editorial always-in (138), kw +5, kw needs genre Animation/Anime, kw-gated genre Animation |
| 71 | **`61`** ⚠︎ | MUSICALS | `#C2185B` | Movies | 3 | incl Music/Musical, kw +5, kw needs genre Music/Comedy/Romance, kw-gated genre Music |
| 72 | **`55`** ⚠︎ | GAME SHOWS | `#FFB300` | Episodes | 3 | incl Game Show/Game-Show/Competition, title allowlist (30) |
| 73 | **`63`** ⚠︎ | ADULT CARTOONS | `#8E44AD` | Episodes | 3 | incl Animation/Animated/Cartoon, title allowlist (21) |
| 74 | **`64`** ⚠︎ | DATE NIGHT | `#E74C8B` | Movies | 3 | needs ALL Romance, no Horror/Animation/Family/Children/Kids, kw +7, kw excl (2) |
| 75 | **`58`** ⚠︎ | STAND-UP | `#F5B041` | Any | 3 | **TMDB manifest + gated genre/keyword fallback**, incl Comedy/Documentary/Stand-Up, kw +2, kw needs genre Comedy/Documentary/Stand-Up, kw-gated genre Comedy/Documentary |
| 76 | **`201`** ⚠︎ | BIOPICS | `#C9A84C` | Movies | 5 | kw +6 |
| 77 | **`67`** ⚠︎ | ALL TIME GREATS | `#FFD700` | Movies | 5 | Plex rating ≥ 8.2, ≥ 60 min |
| 78 | **`68`** ⚠︎ | CERTIFIED GOLD | `#F56040` | Movies | 3 | Plex rating ≥ 8, ≥ 60 min |
| 79 | **`69`** ⚠︎ | OSCAR WINNERS | `#FFD700` | Movies | 3 | title allowlist (44), title blocklist (7) |
| 80 | **`217`** ⚠︎ | SKETCH COMEDY | `#5DADE2` | Episodes | 3 | incl Comedy/Talk Show/News, title allowlist (24) |

### ADVENTURELAND · CH 90–98

_Epic quests, disasters, and adrenaline_

| CH | `id` | Name | Color | Type | Min items | Rules |
|---|---|---|---|---|---|---|
| 90 | **`70`** ⚠︎ | EPIC ADVENTURES | `#D4A017` | Movies | 3 | incl Adventure/Fantasy, no Animation/Animated/Family/Children/Kids, ≥ 110 min |
| 91 | **`71`** ⚠︎ | DISASTER MOVIES | `#E67E22` | Movies | 3 | no Animation/Animated/Family/Fantasy/Romance, title allowlist (23), title blocklist (8) |
| 92 | **`72`** ⚠︎ | RUSH | `#E74C3C` | Movies | 5 | incl Action/Thriller, no Family/Kids/Children/Animation/Animated/Fantasy, kw +10, 2000-…, Plex rating ≥ 5.5, ≥ 80 min |
| 93 | **`73`** ⚠︎ | SCI-FI | `#16A0C8` | Movies | 5 | incl Science Fiction/Horror, needs ALL Science Fiction, no Animation/Family/Kids, kw +8, kw needs genre Science Fiction |
| 94 | **`74`** ⚠︎ | FANTASY | `#8E44AD` | Movies | 5 | incl Fantasy/Adventure, no Animation/Horror/Science Fiction, kw +7, kw needs genre Fantasy/Adventure |
| 95 | **`75`** ⚠︎ | WESTERNS | `#B9770E` | Any | 3 | incl Western, kw +7, kw needs genre Western |
| 96 | **`76`** ⚠︎ | FRONT LINE | `#5D6D7E` | Any | 3 | incl War/War & Politics, no Documentary/Docuseries/Animation/Animated, kw +16, kw needs genre War/War & Politics/History/Biography |
| 97 | **`65`** ⚠︎ | SUPERHERO MOVIES | `#E74C3C` | Movies | 3 | title allowlist (31), title blocklist (5) |
| 98 | **`219`** ⚠︎ | SPY GAMES | `#34495E` | Movies | 5 | kw +8, kw needs genre Action/Thriller/Adventure/Comedy |

### OVERTIME · CH 110–112

_Movies, shows, and docs_

| CH | `id` | Name | Color | Type | Min items | Rules |
|---|---|---|---|---|---|---|
| 110 | **`80`** ⚠︎ | LOCKERROOM | `#1DB954` | Movies | 3 | incl Sport/Sports/Sports Film |
| 111 | **`81`** ⚠︎ | OVERTIME TV | `#2ECC71` | Episodes | 3 | incl Sport/Sports, title allowlist (1) |
| 112 | **`82`** ⚠︎ | SPORTS DOCS | `#27AE60` | Any | 3 | incl Documentary, needs ALL Sport |

### CASE FILES · CH 120–125

_True crime, thrillers & mystery_

| CH | `id` | Name | Color | Type | Min items | Rules |
|---|---|---|---|---|---|---|
| 120 | **`419`** ⚠︎ | MYSTERY BOX TV | `#2E4053` | Episodes | 3 | **TMDB manifest only**, incl Mystery/Horror |
| 121 | **`40`** ⚠︎ | TRUE CRIME | `#7B241C` | Any | 1 | incl Documentary/Docuseries, needs ALL Documentary, kw +17, kw-gated genre Documentary/Docuseries |
| 122 | **`41`** ⚠︎ | CRIME FLICKS | `#A93226` | Movies | 5 | incl Crime, no Documentary, kw +7, kw needs genre Crime |
| 123 | **`42`** ⚠︎ | THRILLERS | `#5B2C6F` | Movies | 5 | incl Thriller, no Horror/Documentary, kw +7, kw needs genre Thriller/Crime |
| 124 | **`43`** ⚠︎ | MYSTERY | `#1A5276` | Movies | 3 | incl Mystery, no Horror/Documentary, kw +6, kw needs genre Mystery/Crime/Thriller |
| 125 | **`44`** ⚠︎ | CRIME TV | `#784212` | Episodes | 3 | incl Crime, no Documentary/Animation, kw +6, kw needs genre Crime |

### DECADES · CH 130–136

_Movies and shows sorted by decade_

| CH | `id` | Name | Color | Type | Min items | Rules |
|---|---|---|---|---|---|---|
| 130 | **`90`** ⚠︎ | THE 60S | `#C0392B` | Any | 5 | 1960-1969, Plex rating ≥ 6 |
| 131 | **`91`** ⚠︎ | THE 70S | `#D2691E` | Any | 5 | 1970-1979, Plex rating ≥ 6 |
| 132 | **`92`** ⚠︎ | THE 80S | `#FF1493` | Any | 5 | 1980-1989, Plex rating ≥ 6 |
| 133 | **`93`** ⚠︎ | THE 90S | `#00CED1` | Any | 5 | 1990-1999, Plex rating ≥ 6 |
| 134 | **`94`** ⚠︎ | THE 00S | `#7B68EE` | Any | 5 | 2000-2009, Plex rating ≥ 6 |
| 135 | **`95`** ⚠︎ | THE 10S | `#20B2AA` | Any | 5 | 2010-2019, Plex rating ≥ 6 |
| 136 | **`96`** ⚠︎ | THE 20S | `#FF6347` | Any | 5 | 2020-2029, Plex rating ≥ 6 |

### ARTHOUSE · CH 150–153

_Criterion, foreign films, midnight movies, and cult classics_

| CH | `id` | Name | Color | Type | Min items | Rules |
|---|---|---|---|---|---|---|
| 150 | **`211`** ⚠︎ | CRITERION | `#F5E6C8` | Movies | 3 | **TMDB manifest only** |
| 151 | **`212`** ⚠︎ | FOREIGN FILMS | `#2C3E50` | Movies | 3 | kw +10, **IMDb ≥ 6.5**, **IMDb votes ≥ 5,000** |
| 152 | **`213`** ⚠︎ | MIDNIGHT | `#1A0A2E` | Movies | 3 | kw +9 |
| 153 | **`214`** ⚠︎ | CULT CLASSICS | `#6C1C8A` | Movies | 3 | kw +5, **IMDb votes ≥ 30,000** |

### NETWORKS · CH 160–171

_Channels by streaming service and studio_

| CH | `id` | Name | Color | Type | Min items | Rules |
|---|---|---|---|---|---|---|
| 160 | **`421`** ⚠︎ | A24 | `#E5E5E5` | Movies | 3 | studios A24, prodCo A24 |
| 161 | **`120`** ⚠︎ | HBO | `#8B5CF6` | Any | 5 | studios HBO/HBO Films/HBO Max, networks HBO/Max/HBO Max, title allowlist (52) |
| 162 | **`121`** ⚠︎ | APPLE TV+ | `#5AC8FA` | Any | 3 | studios Apple TV+/Apple/Apple Studios, networks Apple TV+, title allowlist (80) |
| 163 | **`122`** ⚠︎ | NETFLIX | `#E50914` | Any | 3 | studios Netflix/Netflix Animation/Netflix Studios +2 more, networks Netflix, title allowlist (40), editorial always-in (4) |
| 164 | **`123`** ⚠︎ | PARAMOUNT+ | `#0064FF` | Any | 3 | studios Paramount+/Paramount Television/Paramount Television Studios +3 more, networks Paramount+/Paramount Network/Showtime +4 more, title allowlist (22) |
| 165 | **`124`** ⚠︎ | AMAZON | `#00A8E1` | Any | 3 | studios Amazon/Amazon Studios/Amazon MGM Studios +3 more, networks Amazon Prime Video/Prime Video/Amazon, title allowlist (30) |
| 166 | **`125`** ⚠︎ | HULU | `#1CE783` | Any | 3 | studios Hulu/Hulu Originals/Onyx Collective +2 more, networks Hulu, title allowlist (28) |
| 167 | **`126`** ⚠︎ | SONY | `#374151` | Movies | 3 | studios Sony/Sony Pictures/Sony Pictures Television +3 more, prodCo Columbia Pictures/Sony Pictures/TriStar Pictures +2 more |
| 168 | **`127`** ⚠︎ | WARNER BROS | `#B8860B` | Movies | 3 | studios Warner Bros./Warner Bros. Pictures/Warner Bros. Television +3 more, prodCo Warner Bros. Pictures/New Line Cinema/Castle Rock Entertainment +2 more |
| 169 | **`128`** ⚠︎ | UNIVERSAL | `#00A651` | Movies | 3 | studios Universal/Universal Pictures/Universal Television +3 more, prodCo Universal Pictures/DreamWorks Pictures/DreamWorks Animation +2 more |
| 170 | **`129`** ⚠︎ | 20TH CENTURY | `#C8A951` | Movies | 3 | studios 20th Century Fox/20th Century Studios/20th Television +5 more, prodCo 20th Century Fox/20th Century Studios/Searchlight Pictures +2 more |
| 171 | **`401`** ⚠︎ | MIRAMAX | `#C0392B` | Movies | 3 | studios Miramax/Miramax Films/Dimension Films, prodCo Miramax/Dimension Films |

### SCREAM · CH 180–187

_Horror, all year's worth, front and centre every October_

Spotlighted Oct. Off until switched on, then on in any month.

| CH | `id` | Name | Color | Type | Min items | Rules |
|---|---|---|---|---|---|---|
| 180 | **`131`** ⚠︎ | SCREAM KIDS | `#FF8C00` | Movies | 3 | no Horror, title allowlist (37), editorial always-in (43), rated G/PG/TV-Y/TV-Y7/TV-G/TV-PG |
| 181 | **`141`** ⚠︎ | FRIGHT NIGHT | `#8B0000` | Any | 5 | incl Horror |
| 182 | **`132`** ⚠︎ | SCREAM ADULTS | `#8B0000` | Movies | 3 | incl Horror/Thriller, no Family/Children/Kids/Animation/Animated, title allowlist (53), title blocklist (14), rated R/NC-17/PG-13/TV-MA |
| 183 | **`408`** ⚠︎ | NOSTALGEX HORROR | `#8E44AD` | Movies | 3 | incl Horror, no Family/Children/Kids/Animation/Animated, 1975-1999 |
| 184 | **`415`** ⚠︎ | SLASHER | `#C0001A` | Movies | 5 | incl Horror, no Family/Children/Kids/Animation/Animated, title allowlist (23), title blocklist (3), kw +4, kw needs genre Horror, kw-gated genre Horror |
| 185 | **`416`** ⚠︎ | HORROR COMEDY | `#8BC34A` | Movies | 3 | incl Horror, needs ALL Horror + Comedy, no Family/Children/Kids/Animation/Animated, rated PG/PG-13/R/NC-17/TV-14/TV-MA/NR/unrated |
| 186 | **`417`** ⚠︎ | FOUND FOOTAGE | `#5D6D5F` | Movies | 3 | incl Horror, no Family/Children/Kids/Animation/Animated, title allowlist (10), kw +2, kw needs genre Horror/Science Fiction, kw-gated genre Horror |
| 187 | **`418`** ⚠︎ | WORLD HORROR | `#6A1B9A` | Movies | 3 | **TMDB manifest only**, incl Horror, no Family/Children/Kids/Animation/Animated |

### TIS THE SEASON · CH 190–197

_Christmas, Thanksgiving and holiday channels_

Spotlighted from 7 days before US Thanksgiving (the fourth Thursday of November) through Dec. Off until switched on, then on in any month.

| CH | `id` | Name | Color | Type | Min items | Rules |
|---|---|---|---|---|---|---|
| 190 | **`130`** ⚠︎ | HOLIDAZE | `#C41E3A` | Movies | 3 | incl Holiday/Christmas, title allowlist (19), title blocklist (3), editorial always-in (98), Plex rating ≥ 5 |
| 191 | **`409`** ⚠︎ | SANTA'S LIST | `#2ECC71` | Movies | 3 | incl Holiday/Christmas, title allowlist (114), title blocklist (9), rated G/PG/TV-Y/TV-Y7/TV-G/TV-PG/unrated |
| 192 | **`410`** ⚠︎ | NAUGHTY LIST | `#C0392B` | Movies | 3 | incl Holiday/Christmas, title allowlist (114), title blocklist (9), rated PG-13/R/TV-14/TV-MA |
| 193 | **`411`** ⚠︎ | NOSTALGEX CHRISTMAS | `#E74C3C` | Movies | 3 | incl Holiday/Christmas, title allowlist (114), title blocklist (9), …-1999 |
| 194 | **`412`** ⚠︎ | MISTLETOE | `#D98880` | Movies | 3 | genres include TMDB's, needs ALL Romance, no Animation/Animated, title allowlist (19), title blocklist (2), kw +12, 1980-…, rated G/PG/TV-Y/TV-Y7/TV-G/TV-PG/NR/Not Rated/unrated, 70-120 min |
| 195 | **`413`** ⚠︎ | CHRISTMAS SPECIALS | `#27AE60` | Any | 5 | episode title words (38), seasonal title words (16) if aired 11-25 to 01-07, summary words (17), episode title blocklist (18), rated TV-PG/PG/TV-14/TV-MA/PG-13/R/NR/Not Rated, ≤ 65 min |
| 196 | **`414`** ⚠︎ | KIDS CHRISTMAS TV | `#58D68D` | Any | 5 | episode title words (38), seasonal title words (16) if aired 11-25 to 01-07, summary words (17), episode title blocklist (18), rated TV-Y/TV-Y7/TV-G/G/unrated, ≤ 65 min |
| 197 | **`422`** ⚠︎ | TURKEY DAY | `#B9770E` | Any | 5 | episode title words (5), seasonal title words (7) if aired 11-01 to 11-30, summary words (2), ≤ 65 min |

### FRANCHISES · CH 300–306

_Movie franchise marathons_

| CH | `id` | Name | Color | Type | Min items | Rules |
|---|---|---|---|---|---|---|
| 300 | **`100`** ⚠︎ | STAR WARS | `#FFE81F` | Movies | 3 | title allowlist (1) |
| 301 | **`101`** ⚠︎ | MARVEL | `#E74C3C` | Movies | 3 | studios Marvel Studios |
| 302 | **`102`** ⚠︎ | HARRY POTTER | `#7B68EE` | Movies | 3 | title allowlist (2) |
| 303 | **`103`** ⚠︎ | JURASSIC PARK | `#2ECC71` | Any | 3 | title allowlist (4) |
| 304 | **`104`** ⚠︎ | LORD OF THE RINGS | `#D4A017` | Movies | 3 | title allowlist (2) |
| 305 | **`105`** ⚠︎ | MISSION IMPOSSIBLE | `#C0392B` | Movies | 3 | title allowlist (2) |
| 306 | **`106`** ⚠︎ | JASON BOURNE | `#566573` | Movies | 3 | title allowlist (1) |

### HIGH ROTATION · CH 500–513

_Music videos by genre_

| CH | `id` | Name | Color | Type | Min items | Rules |
|---|---|---|---|---|---|---|
| 500 | **`150`** ⚠︎ | HIGH ROTATION | `#FF2DB4` | Any | 3 | source: music videos |
| 501 | **`151`** ⚠︎ | POP | `#FF2DB4` | Any | 3 | source: music videos, incl Pop |
| 502 | **`152`** ⚠︎ | ROCK'N | `#FF2DB4` | Any | 3 | source: music videos, incl Rock/Hard Rock/Classic Rock |
| 503 | **`153`** ⚠︎ | COUNTRY SWAGGER | `#FF2DB4` | Any | 3 | source: music videos, incl Country/Country Rock |
| 504 | **`154`** ⚠︎ | BALLIN | `#FF2DB4` | Any | 3 | source: music videos, incl Hip-Hop/Hip Hop |
| 505 | **`155`** ⚠︎ | RAP GODS | `#FF2DB4` | Any | 3 | source: music videos, incl Rap |
| 506 | **`156`** ⚠︎ | ALT ROCK | `#FF2DB4` | Any | 3 | source: music videos, incl Alternative/Indie Rock/Alternative Rock |
| 507 | **`157`** ⚠︎ | SLOW JAMS | `#FF2DB4` | Any | 3 | source: music videos, incl R&B/Soul/Acoustic |
| 508 | **`159`** ⚠︎ | Y2K | `#FF2DB4` | Any | 3 | source: music videos, 2000-2019 |
| 509 | **`160`** ⚠︎ | CURRENT SPIN | `#FF2DB4` | Any | 3 | source: music videos, 2020-2100 |
| 510 | **`161`** ⚠︎ | DANCE FLOOR | `#FF2DB4` | Any | 3 | source: music videos, incl Electronic/Dance/House/Techno/EDM/Trance |
| 511 | **`162`** ⚠︎ | CALIENTE | `#FF2DB4` | Any | 3 | source: music videos, incl Latin/Reggaeton |
| 512 | **`163`** ⚠︎ | HEADBANGERS | `#FF2DB4` | Any | 3 | source: music videos, incl Metal |
| 513 | **`164`** ⚠︎ | GET DOWN | `#FF2DB4` | Any | 3 | source: music videos, incl Funk/Disco |

---

## `id` ≠ `number`

123 channels whose manifest/exclusivity key (`id`) is not their on-screen number. Marked ⚠︎ in the tables above.

| `id` | Airs as | Name |
|---|---|---|
| `215` | CH15 | CARTOON NETWORK |
| `405` | CH16 | DVD SHELF |
| `406` | CH17 | Y2K COMEDY |
| `407` | CH18 | Y2K SITCOMS |
| `216` | CH19 | Y2K TOONS |
| `423` | CH20 | 80S SITCOMS |
| `424` | CH21 | 80S LOL |
| `425` | CH22 | 80S AFTER SCHOOL TV |
| `20` | CH30 | FAMILY HOUR |
| `21` | CH31 | DIZ FLICKS |
| `22` | CH32 | DIZNEY TOONS |
| `23` | CH33 | DIZ JUNIOR |
| `24` | CH34 | DIZ TV |
| `25` | CH35 | ANIMATION |
| `26` | CH36 | SLIME TV |
| `27` | CH37 | PIXAR MOVIES |
| `28` | CH38 | MINION HQ |
| `29` | CH39 | TWEEN TV |
| `30` | CH40 | TEEN DRAMA |
| `33` | CH41 | FAMILY TV |
| `34` | CH42 | NETFLIX KIDS |
| `218` | CH43 | DREAMWORKS |
| `400` | CH44 | TOON TOWN |
| `56` | CH55 | DOCS |
| `57` | CH56 | LOL |
| `59` | CH57 | MAN CAVE |
| `62` | CH58 | FRESH |
| `66` | CH59 | BLOCKBUSTER |
| `200` | CH60 | DRAMA TV |
| `210` | CH61 | RECORD STORE |
| `404` | CH62 | HISTORY & BIO |
| `402` | CH63 | R RATED COMEDY |
| `403` | CH64 | PREMIERES |
| `420` | CH65 | CRINGE TV |
| `60` | CH70 | ANIME |
| `61` | CH71 | MUSICALS |
| `55` | CH72 | GAME SHOWS |
| `63` | CH73 | ADULT CARTOONS |
| `64` | CH74 | DATE NIGHT |
| `58` | CH75 | STAND-UP |
| `201` | CH76 | BIOPICS |
| `67` | CH77 | ALL TIME GREATS |
| `68` | CH78 | CERTIFIED GOLD |
| `69` | CH79 | OSCAR WINNERS |
| `217` | CH80 | SKETCH COMEDY |
| `70` | CH90 | EPIC ADVENTURES |
| `71` | CH91 | DISASTER MOVIES |
| `72` | CH92 | RUSH |
| `73` | CH93 | SCI-FI |
| `74` | CH94 | FANTASY |
| `75` | CH95 | WESTERNS |
| `76` | CH96 | FRONT LINE |
| `65` | CH97 | SUPERHERO MOVIES |
| `219` | CH98 | SPY GAMES |
| `80` | CH110 | LOCKERROOM |
| `81` | CH111 | OVERTIME TV |
| `82` | CH112 | SPORTS DOCS |
| `419` | CH120 | MYSTERY BOX TV |
| `40` | CH121 | TRUE CRIME |
| `41` | CH122 | CRIME FLICKS |
| `42` | CH123 | THRILLERS |
| `43` | CH124 | MYSTERY |
| `44` | CH125 | CRIME TV |
| `90` | CH130 | THE 60S |
| `91` | CH131 | THE 70S |
| `92` | CH132 | THE 80S |
| `93` | CH133 | THE 90S |
| `94` | CH134 | THE 00S |
| `95` | CH135 | THE 10S |
| `96` | CH136 | THE 20S |
| `211` | CH150 | CRITERION |
| `212` | CH151 | FOREIGN FILMS |
| `213` | CH152 | MIDNIGHT |
| `214` | CH153 | CULT CLASSICS |
| `421` | CH160 | A24 |
| `120` | CH161 | HBO |
| `121` | CH162 | APPLE TV+ |
| `122` | CH163 | NETFLIX |
| `123` | CH164 | PARAMOUNT+ |
| `124` | CH165 | AMAZON |
| `125` | CH166 | HULU |
| `126` | CH167 | SONY |
| `127` | CH168 | WARNER BROS |
| `128` | CH169 | UNIVERSAL |
| `129` | CH170 | 20TH CENTURY |
| `401` | CH171 | MIRAMAX |
| `131` | CH180 | SCREAM KIDS |
| `141` | CH181 | FRIGHT NIGHT |
| `132` | CH182 | SCREAM ADULTS |
| `408` | CH183 | NOSTALGEX HORROR |
| `415` | CH184 | SLASHER |
| `416` | CH185 | HORROR COMEDY |
| `417` | CH186 | FOUND FOOTAGE |
| `418` | CH187 | WORLD HORROR |
| `130` | CH190 | HOLIDAZE |
| `409` | CH191 | SANTA'S LIST |
| `410` | CH192 | NAUGHTY LIST |
| `411` | CH193 | NOSTALGEX CHRISTMAS |
| `412` | CH194 | MISTLETOE |
| `413` | CH195 | CHRISTMAS SPECIALS |
| `414` | CH196 | KIDS CHRISTMAS TV |
| `422` | CH197 | TURKEY DAY |
| `100` | CH300 | STAR WARS |
| `101` | CH301 | MARVEL |
| `102` | CH302 | HARRY POTTER |
| `103` | CH303 | JURASSIC PARK |
| `104` | CH304 | LORD OF THE RINGS |
| `105` | CH305 | MISSION IMPOSSIBLE |
| `106` | CH306 | JASON BOURNE |
| `150` | CH500 | HIGH ROTATION |
| `151` | CH501 | POP |
| `152` | CH502 | ROCK'N |
| `153` | CH503 | COUNTRY SWAGGER |
| `154` | CH504 | BALLIN |
| `155` | CH505 | RAP GODS |
| `156` | CH506 | ALT ROCK |
| `157` | CH507 | SLOW JAMS |
| `159` | CH508 | Y2K |
| `160` | CH509 | CURRENT SPIN |
| `161` | CH510 | DANCE FLOOR |
| `162` | CH511 | CALIENTE |
| `163` | CH512 | HEADBANGERS |
| `164` | CH513 | GET DOWN |

---

_Generated from `channels.json` v49 by `scripts/render-channels-doc.mjs`. Do not edit by hand._
