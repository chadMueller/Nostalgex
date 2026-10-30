# Nostalgex Channel Guide

<!-- GENERATED FILE — do not edit by hand. Run `npm run channels:doc` after any
     channels.json change. Source: scripts/render-channels-doc.mjs -->

Quick reference for every channel and bundle. Source of truth: `channels.json`.

## Read this before editing a channel

**`id` and `number` are NOT the same thing.** A channel's `number` is what
viewers tune to; its `id` is the stable key everything else references. They
drifted apart as channels were renumbered, and today they differ for many
channels — for example `id` 40 is **CH85 TRUE CRIME**, and `id` 211 is
**CH107 CRITERION**. Get it wrong and you edit a different channel than the one
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

**Config version:** 46 · **139 channels** across **14 bundles** · 90 channels whose `id` differs from their `number`.

---

## Bundles

| Bundle | Bundle ID | Channels | Range | Description |
|---|---|---|---|---|
| NOSTALGEX | `nostalgex` | 19 | CH 1–19 | The 80s and 90s. All retro, all the time |
| KIDZ ZONE | `kids` | 15 | CH 20–34 | Disney, Nickelodeon, Pixar, and more |
| PRIME TIME | `essentials` | 16 | CH 40–55 | Everyday favorites and feel-good viewing |
| MARQUEE | `premium` | 11 | CH 59–69 | Premium channels |
| ADVENTURELAND | `adventureland` | 9 | CH 70–78 | Epic quests, disasters, and adrenaline |
| OVERTIME | `sports` | 3 | CH 80–82 | Movies, shows, and docs |
| CASE FILES | `truecrime` | 6 | CH 84–89 | True crime, thrillers & mystery |
| DECADES | `decades` | 7 | CH 90–96 | Movies and shows sorted by decade |
| FRANCHISES | `franchises` | 7 | CH 100–106 | Movie franchise marathons |
| ARTHOUSE | `arthouse` | 4 | CH 107–110 | Criterion, foreign films, midnight movies, and cult classics |
| NETWORKS | `streamers` | 12 | CH 118–129 | Channels by streaming service and studio |
| SCREAM | `seasonal` | 8 | CH 137–144 | Horror, all year's worth, front and centre every October. Spotlighted Oct. Off until switched on, then on in any month. |
| TIS THE SEASON | `tis-the-season` | 8 | CH 145–152 | Christmas, Thanksgiving and holiday channels. Spotlighted from 7 days before US Thanksgiving (the fourth Thursday of November) through Dec. Off until switched on, then on in any month. |
| HIGH ROTATION | `high-rotation` | 14 | CH 200–213 | Music videos by genre |

Bundled channels: 139 of 139.

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
| CH145 HOLIDAZE (id 130)<br>CH146 SANTA'S LIST (id 409)<br>CH147 NAUGHTY LIST (id 410)<br>CH148 NOSTALGEX CHRISTMAS (id 411)<br>CH149 MISTLETOE (id 412)<br>CH150 CHRISTMAS SPECIALS (id 413)<br>CH151 KIDS CHRISTMAS TV (id 414) | genres Holiday/Christmas, 14 title words, 47 exact titles, only movies from the movie library | Christmas films belong to the TIS THE SEASON channels, including the two TV channels, which air half-hour specials stored as films. Films in a movie library only (`type: movie`, `source: movie`), so a show with Santa in its name and a Christmas song on a music video stay free. Title words are the ones that measured 95% or more Christmas across TMDB films with 25+ votes (2026-10-18): "Holiday" (66%, Mr. Bean's Holiday, Roman Holiday), "Santa" (87%, Santa Sangre, Santa Fe Trail), "Merry", "Snowman", "Grinch", "Scrooge", "Nutcracker" and "Reindeer" were dropped, so the channels still match them but no longer lock them away. Die Hard, Lethal Weapon, Reindeer Games, Rocky IV, Gremlins, Batman Returns, Trading Places, The Family Man, While You Were Sleeping and The Shop Around the Corner are deliberately NOT locked: Christmas-set, but they belong on their year-round channels too. |
| id 32 (missing)<br>CH59 ANIME (id 60) | genres Anime, TMDB manifest claim (`manifestExclusive`) | Anime is claimed by genre `Anime` OR by a TMDB-manifest claim (`manifestExclusive`), so manifest-claimed anime is blocked from the other animation channels even when Plex only tags it "Animation". The manifest builder gates these channels with `requireGenres: ["Animation"]` + `requireOriginalLanguage: ["ja"]` + `autoSweepCollections: false` so TMDB similar/collection noise cannot be claimed — that blocks live-action (Spy Kids) AND Western animation (An American Tail, Avatar, Castlevania). Strict Japanese anime only. Re-run the keyword tuner to apply changes. |
| CH139 SCREAM ADULTS (id 132)<br>CH141 SLASHER (id 415) | 22 exact titles, only movies from the movie library | The Scream and Halloween films, by exact title, so SCREAM ADULTS and SLASHER own them rather than the other horror channels. It used to match any title containing "scream" or "halloween", which hid Kicking & Screaming and Hubie Halloween from every channel they belong on. |

---

## Channels by bundle

### NOSTALGEX · CH 1–19

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

### KIDZ ZONE · CH 20–34

_Disney, Nickelodeon, Pixar, and more_

| CH | `id` | Name | Color | Type | Min items | Rules |
|---|---|---|---|---|---|---|
| 20 | `20` | FAMILY HOUR | `#00C4FF` | Movies | 10 | needs ALL Family, rated G/PG/PG-13/unrated |
| 21 | `21` | DIZ FLICKS | `#7B2FBE` | Movies | 3 | studios Disney/Walt Disney/Walt Disney Pictures +1 more, rated G/PG/PG-13/TV-Y/TV-Y7/TV-G/TV-PG/TV-14/unrated |
| 22 | `22` | DIZNEY TOONS | `#9C27B0` | Movies | 3 | needs ALL Animation, studios Disney/Walt Disney/Walt Disney Pictures +1 more, rated G/PG/PG-13/TV-Y/TV-Y7/TV-G/TV-PG/unrated |
| 23 | `23` | DIZ JUNIOR | `#7B68EE` | Episodes | 3 | studios Disney Junior/Disney Television Animation/Ludo Studio +3 more, title allowlist (19), 2010-…, rated TV-Y/TV-Y7/TV-G/G/unrated |
| 24 | `24` | DIZ TV | `#AB47BC` | Episodes | 3 | studios Disney/Disney Channel/Disney Television Animation +2 more, networks Disney Channel/Disney XD/Disney+, rated TV-Y/TV-Y7/TV-G/TV-PG/TV-14/G/PG/unrated |
| 25 | `25` | ANIMATION | `#FF5722` | Movies | 5 | incl Animation, prodCo DreamWorks Animation/Sony Pictures Animation/Warner Bros. Animation +9 more, rated G/PG/PG-13/TV-G/TV-PG/unrated |
| 26 | `26` | SLIME TV | `#FF6600` | Episodes | 3 | networks Nickelodeon/Nick at Nite, rated TV-Y/TV-Y7/TV-G/TV-PG/TV-14/G/PG/unrated |
| 27 | `27` | PIXAR MOVIES | `#00B894` | Movies | 3 | studios Pixar/Pixar Animation Studios, prodCo Pixar Animation Studios/Pixar, rated G/PG/PG-13/TV-Y/TV-Y7/TV-G/TV-PG/unrated |
| 28 | `28` | MINION HQ | `#FDCB6E` | Movies | 3 | studios Illumination/Illumination Entertainment, prodCo Illumination Entertainment/Illumination |
| 29 | `29` | TWEEN TV | `#FF69B4` | Episodes | 5 | no Animation/Anime/Cartoon, studios Disney Channel/Nickelodeon/Nickelodeon Productions +7 more, title allowlist (26), 1989-…, rated TV-G/TV-PG/TV-Y7/unrated |
| 30 | `30` | TEEN DRAMA | `#E74C8B` | Episodes | 5 | incl Drama/Romance/Comedy, no Animation/Anime, kw +7, kw excl (8), 2000-…, rated TV-14/TV-PG |
| 31 | **`33`** ⚠︎ | FAMILY TV | `#FF7043` | Episodes | 10 | incl Family/Comedy/Drama, no Kids/Children/Cartoon, 2000-…, rated TV-G/TV-PG/TV-14/unrated |
| 32 | **`34`** ⚠︎ | NETFLIX KIDS | `#E50914` | Any | 3 | incl Family/Kids/Children/Comedy/Adventure, no Horror/Thriller, studios Netflix/Netflix Animation/Netflix Family, title allowlist (28), rated TV-Y/TV-Y7/TV-G/G/PG/TV-PG/unrated |
| 33 | **`218`** ⚠︎ | DREAMWORKS | `#2ECC71` | Any | 5 | studios DreamWorks Animation/Pacific Data Images, rated G/PG/PG-13/TV-Y/TV-Y7/TV-G/TV-PG/unrated |
| 34 | **`400`** ⚠︎ | TOON TOWN | `#FF9F1C` | Movies | 5 | kw +1, kw needs genre Animation/Family/Comedy, rated G/PG/PG-13/unrated |

### PRIME TIME · CH 40–55

_Everyday favorites and feel-good viewing_

| CH | `id` | Name | Color | Type | Min items | Rules |
|---|---|---|---|---|---|---|
| 40 | **`50`** ⚠︎ | SITCOMS | `#9B59B6` | Episodes | 10 | incl Comedy, no Animation/Anime/Kids/Children/Family, kw +7 |
| 41 | **`51`** ⚠︎ | FLICKS | `#FF6600` | Movies | 10 | no Horror/Kids/Children/Family |
| 42 | **`52`** ⚠︎ | ROM COMS | `#FF85A1` | Movies | 50 | needs ALL Romance + Comedy, no Horror/Thriller/Action/Animation/Family |
| 43 | **`53`** ⚠︎ | FEEL GOOD TV | `#7ED957` | Episodes | 5 | title allowlist (51) |
| 44 | **`54`** ⚠︎ | REALITY TV | `#FF4500` | Episodes | 5 | incl Reality/Reality-TV/Docuseries, no Game Show/Game-Show/Competition |
| 45 | **`56`** ⚠︎ | DOCS | `#2E86C1` | Any | 5 | incl Documentary, no Sport, kw +7, kw needs genre Documentary |
| 46 | **`57`** ⚠︎ | LOL | `#F1C40F` | Movies | 5 | incl Comedy, no Horror/War/History/Documentary, kw excl (3), Plex rating ≥ 7 |
| 47 | **`59`** ⚠︎ | MAN CAVE | `#4A6741` | Episodes | 3 | incl Crime/Action, no Family/Children/Kids, title allowlist (8) |
| 48 | **`62`** ⚠︎ | FRESH | `#00E5FF` | Movies | 3 | released ≤ 6 mo ago, ≥ 60 min |
| 49 | **`66`** ⚠︎ | BLOCKBUSTER | `#F39C12` | Movies | 5 | incl Action/Adventure/Science Fiction, Plex rating ≥ 6 |
| 50 | **`200`** ⚠︎ | DRAMA TV | `#5A3E8A` | Episodes | 10 | incl Drama, no Animation/Comedy/Documentary/Horror/Reality/Kids/Children/Family, kw +5, kw needs genre Drama |
| 51 | **`210`** ⚠︎ | RECORD STORE | `#FF6B35` | Movies | 3 | incl Music, kw excl (4) |
| 52 | **`404`** ⚠︎ | HISTORY & BIO | `#A0522D` | Movies | 5 | incl History/Biography, no Documentary/Docuseries/Animation/Animated |
| 53 | **`402`** ⚠︎ | R RATED COMEDY | `#E84393` | Movies | 5 | incl Comedy, no Animation/Family/Children/Kids, title blocklist (6), 1995-2029, rated R |
| 54 | **`403`** ⚠︎ | PREMIERES | `#F72585` | Any | 1 | incl Action/Adventure/Animation/Anime/Biography/Cartoon +23 more, added ≤ 14 d ago |
| 55 | **`420`** ⚠︎ | CRINGE TV | `#F7DC6F` | Episodes | 3 | incl Comedy/Documentary, title allowlist (20), kw +9, kw needs genre Comedy, kw-gated genre Comedy/Documentary |

### MARQUEE · CH 59–69

_Premium channels_

| CH | `id` | Name | Color | Type | Min items | Rules |
|---|---|---|---|---|---|---|
| 59 | **`60`** ⚠︎ | ANIME | `#FF3D6E` | Any | 3 | **TMDB manifest + gated genre/keyword fallback**, incl Animation/Anime, editorial always-in (138), kw +5, kw needs genre Animation/Anime, kw-gated genre Animation |
| 60 | **`61`** ⚠︎ | MUSICALS | `#C2185B` | Movies | 3 | incl Music/Musical, kw +5, kw needs genre Music/Comedy/Romance, kw-gated genre Music |
| 61 | **`55`** ⚠︎ | GAME SHOWS | `#FFB300` | Episodes | 3 | incl Game Show/Game-Show/Competition, title allowlist (30) |
| 62 | **`63`** ⚠︎ | ADULT CARTOONS | `#8E44AD` | Episodes | 3 | incl Animation/Animated/Cartoon, title allowlist (21) |
| 63 | **`64`** ⚠︎ | DATE NIGHT | `#E74C8B` | Movies | 3 | needs ALL Romance, no Horror/Animation/Family/Children/Kids, kw +7, kw excl (2) |
| 64 | **`58`** ⚠︎ | STAND-UP | `#F5B041` | Any | 3 | **TMDB manifest + gated genre/keyword fallback**, incl Comedy/Documentary/Stand-Up, kw +2, kw needs genre Comedy/Documentary/Stand-Up, kw-gated genre Comedy/Documentary |
| 65 | **`201`** ⚠︎ | BIOPICS | `#C9A84C` | Movies | 5 | kw +6 |
| 66 | **`67`** ⚠︎ | ALL TIME GREATS | `#FFD700` | Movies | 5 | Plex rating ≥ 8.2, ≥ 60 min |
| 67 | **`68`** ⚠︎ | CERTIFIED GOLD | `#F56040` | Movies | 3 | Plex rating ≥ 8, ≥ 60 min |
| 68 | **`69`** ⚠︎ | OSCAR WINNERS | `#FFD700` | Movies | 3 | title allowlist (44), title blocklist (7) |
| 69 | **`217`** ⚠︎ | SKETCH COMEDY | `#5DADE2` | Episodes | 3 | incl Comedy/Talk Show/News, title allowlist (24) |

### ADVENTURELAND · CH 70–78

_Epic quests, disasters, and adrenaline_

| CH | `id` | Name | Color | Type | Min items | Rules |
|---|---|---|---|---|---|---|
| 70 | `70` | EPIC ADVENTURES | `#D4A017` | Movies | 3 | incl Adventure/Fantasy, no Animation/Animated/Family/Children/Kids, ≥ 110 min |
| 71 | `71` | DISASTER MOVIES | `#E67E22` | Movies | 3 | no Animation/Animated/Family/Fantasy/Romance, title allowlist (23), title blocklist (8) |
| 72 | `72` | RUSH | `#E74C3C` | Movies | 5 | incl Action/Thriller, no Family/Kids/Children/Animation/Animated/Fantasy, kw +10, 2000-…, Plex rating ≥ 5.5, ≥ 80 min |
| 73 | `73` | SCI-FI | `#16A0C8` | Movies | 5 | incl Science Fiction/Horror, needs ALL Science Fiction, no Animation/Family/Kids, kw +8, kw needs genre Science Fiction |
| 74 | `74` | FANTASY | `#8E44AD` | Movies | 5 | incl Fantasy/Adventure, no Animation/Horror/Science Fiction, kw +7, kw needs genre Fantasy/Adventure |
| 75 | `75` | WESTERNS | `#B9770E` | Any | 3 | incl Western, kw +7, kw needs genre Western |
| 76 | `76` | FRONT LINE | `#5D6D7E` | Any | 3 | incl War/War & Politics, no Documentary/Docuseries/Animation/Animated, kw +16, kw needs genre War/War & Politics/History/Biography |
| 77 | **`65`** ⚠︎ | SUPERHERO MOVIES | `#E74C3C` | Movies | 3 | title allowlist (31), title blocklist (5) |
| 78 | **`219`** ⚠︎ | SPY GAMES | `#34495E` | Movies | 5 | kw +8, kw needs genre Action/Thriller/Adventure/Comedy |

### OVERTIME · CH 80–82

_Movies, shows, and docs_

| CH | `id` | Name | Color | Type | Min items | Rules |
|---|---|---|---|---|---|---|
| 80 | `80` | LOCKERROOM | `#1DB954` | Movies | 3 | incl Sport/Sports/Sports Film |
| 81 | `81` | OVERTIME TV | `#2ECC71` | Episodes | 3 | incl Sport/Sports, title allowlist (1) |
| 82 | `82` | SPORTS DOCS | `#27AE60` | Any | 3 | incl Documentary, needs ALL Sport |

### CASE FILES · CH 84–89

_True crime, thrillers & mystery_

| CH | `id` | Name | Color | Type | Min items | Rules |
|---|---|---|---|---|---|---|
| 84 | **`419`** ⚠︎ | MYSTERY BOX TV | `#2E4053` | Episodes | 3 | **TMDB manifest only**, incl Mystery/Horror |
| 85 | **`40`** ⚠︎ | TRUE CRIME | `#7B241C` | Any | 1 | incl Documentary/Docuseries, needs ALL Documentary, kw +17, kw-gated genre Documentary/Docuseries |
| 86 | **`41`** ⚠︎ | CRIME FLICKS | `#A93226` | Movies | 5 | incl Crime, no Documentary, kw +7, kw needs genre Crime |
| 87 | **`42`** ⚠︎ | THRILLERS | `#5B2C6F` | Movies | 5 | incl Thriller, no Horror/Documentary, kw +7, kw needs genre Thriller/Crime |
| 88 | **`43`** ⚠︎ | MYSTERY | `#1A5276` | Movies | 3 | incl Mystery, no Horror/Documentary, kw +6, kw needs genre Mystery/Crime/Thriller |
| 89 | **`44`** ⚠︎ | CRIME TV | `#784212` | Episodes | 3 | incl Crime, no Documentary/Animation, kw +6, kw needs genre Crime |

### DECADES · CH 90–96

_Movies and shows sorted by decade_

| CH | `id` | Name | Color | Type | Min items | Rules |
|---|---|---|---|---|---|---|
| 90 | `90` | THE 60S | `#C0392B` | Any | 5 | 1960-1969, Plex rating ≥ 6 |
| 91 | `91` | THE 70S | `#D2691E` | Any | 5 | 1970-1979, Plex rating ≥ 6 |
| 92 | `92` | THE 80S | `#FF1493` | Any | 5 | 1980-1989, Plex rating ≥ 6 |
| 93 | `93` | THE 90S | `#00CED1` | Any | 5 | 1990-1999, Plex rating ≥ 6 |
| 94 | `94` | THE 00S | `#7B68EE` | Any | 5 | 2000-2009, Plex rating ≥ 6 |
| 95 | `95` | THE 10S | `#20B2AA` | Any | 5 | 2010-2019, Plex rating ≥ 6 |
| 96 | `96` | THE 20S | `#FF6347` | Any | 5 | 2020-2029, Plex rating ≥ 6 |

### FRANCHISES · CH 100–106

_Movie franchise marathons_

| CH | `id` | Name | Color | Type | Min items | Rules |
|---|---|---|---|---|---|---|
| 100 | `100` | STAR WARS | `#FFE81F` | Movies | 3 | title allowlist (1) |
| 101 | `101` | MARVEL | `#E74C3C` | Movies | 3 | studios Marvel Studios |
| 102 | `102` | HARRY POTTER | `#7B68EE` | Movies | 3 | title allowlist (2) |
| 103 | `103` | JURASSIC PARK | `#2ECC71` | Any | 3 | title allowlist (4) |
| 104 | `104` | LORD OF THE RINGS | `#D4A017` | Movies | 3 | title allowlist (2) |
| 105 | `105` | MISSION IMPOSSIBLE | `#C0392B` | Movies | 3 | title allowlist (2) |
| 106 | `106` | JASON BOURNE | `#566573` | Movies | 3 | title allowlist (1) |

### ARTHOUSE · CH 107–110

_Criterion, foreign films, midnight movies, and cult classics_

| CH | `id` | Name | Color | Type | Min items | Rules |
|---|---|---|---|---|---|---|
| 107 | **`211`** ⚠︎ | CRITERION | `#F5E6C8` | Movies | 3 | **TMDB manifest only** |
| 108 | **`212`** ⚠︎ | FOREIGN FILMS | `#2C3E50` | Movies | 3 | kw +10, **IMDb ≥ 6.5**, **IMDb votes ≥ 5,000** |
| 109 | **`213`** ⚠︎ | MIDNIGHT | `#1A0A2E` | Movies | 3 | kw +9 |
| 110 | **`214`** ⚠︎ | CULT CLASSICS | `#6C1C8A` | Movies | 3 | kw +5, **IMDb votes ≥ 30,000** |

### NETWORKS · CH 118–129

_Channels by streaming service and studio_

| CH | `id` | Name | Color | Type | Min items | Rules |
|---|---|---|---|---|---|---|
| 118 | **`421`** ⚠︎ | A24 | `#E5E5E5` | Movies | 3 | studios A24, prodCo A24 |
| 119 | **`120`** ⚠︎ | HBO | `#8B5CF6` | Any | 5 | studios HBO/HBO Films/HBO Max, networks HBO/Max/HBO Max, title allowlist (52) |
| 120 | **`121`** ⚠︎ | APPLE TV+ | `#5AC8FA` | Any | 3 | studios Apple TV+/Apple/Apple Studios, networks Apple TV+, title allowlist (80) |
| 121 | **`122`** ⚠︎ | NETFLIX | `#E50914` | Any | 3 | studios Netflix/Netflix Animation/Netflix Studios +2 more, networks Netflix, title allowlist (40), editorial always-in (4) |
| 122 | **`123`** ⚠︎ | PARAMOUNT+ | `#0064FF` | Any | 3 | studios Paramount+/Paramount Television/Paramount Television Studios +3 more, networks Paramount+/Paramount Network/Showtime +4 more, title allowlist (22) |
| 123 | **`124`** ⚠︎ | AMAZON | `#00A8E1` | Any | 3 | studios Amazon/Amazon Studios/Amazon MGM Studios +3 more, networks Amazon Prime Video/Prime Video/Amazon, title allowlist (30) |
| 124 | **`125`** ⚠︎ | HULU | `#1CE783` | Any | 3 | studios Hulu/Hulu Originals/Onyx Collective +2 more, networks Hulu, title allowlist (28) |
| 125 | **`126`** ⚠︎ | SONY | `#374151` | Movies | 3 | studios Sony/Sony Pictures/Sony Pictures Television +3 more, prodCo Columbia Pictures/Sony Pictures/TriStar Pictures +2 more |
| 126 | **`127`** ⚠︎ | WARNER BROS | `#B8860B` | Movies | 3 | studios Warner Bros./Warner Bros. Pictures/Warner Bros. Television +3 more, prodCo Warner Bros. Pictures/New Line Cinema/Castle Rock Entertainment +2 more |
| 127 | **`128`** ⚠︎ | UNIVERSAL | `#00A651` | Movies | 3 | studios Universal/Universal Pictures/Universal Television +3 more, prodCo Universal Pictures/DreamWorks Pictures/DreamWorks Animation +2 more |
| 128 | **`129`** ⚠︎ | 20TH CENTURY | `#C8A951` | Movies | 3 | studios 20th Century Fox/20th Century Studios/20th Television +5 more, prodCo 20th Century Fox/20th Century Studios/Searchlight Pictures +2 more |
| 129 | **`401`** ⚠︎ | MIRAMAX | `#C0392B` | Movies | 3 | studios Miramax/Miramax Films/Dimension Films, prodCo Miramax/Dimension Films |

### SCREAM · CH 137–144

_Horror, all year's worth, front and centre every October_

Spotlighted Oct. Off until switched on, then on in any month.

| CH | `id` | Name | Color | Type | Min items | Rules |
|---|---|---|---|---|---|---|
| 137 | **`131`** ⚠︎ | SCREAM KIDS | `#FF8C00` | Movies | 3 | no Horror, title allowlist (37), editorial always-in (43), rated G/PG/TV-Y/TV-Y7/TV-G/TV-PG |
| 138 | **`141`** ⚠︎ | FRIGHT NIGHT | `#8B0000` | Any | 5 | incl Horror |
| 139 | **`132`** ⚠︎ | SCREAM ADULTS | `#8B0000` | Movies | 3 | incl Horror/Thriller, no Family/Children/Kids/Animation/Animated, title allowlist (53), title blocklist (14), rated R/NC-17/PG-13/TV-MA |
| 140 | **`408`** ⚠︎ | NOSTALGEX HORROR | `#8E44AD` | Movies | 3 | incl Horror, no Family/Children/Kids/Animation/Animated, 1975-1999 |
| 141 | **`415`** ⚠︎ | SLASHER | `#C0001A` | Movies | 5 | incl Horror, no Family/Children/Kids/Animation/Animated, title allowlist (23), title blocklist (3), kw +4, kw needs genre Horror, kw-gated genre Horror |
| 142 | **`416`** ⚠︎ | HORROR COMEDY | `#8BC34A` | Movies | 3 | incl Horror, needs ALL Horror + Comedy, no Family/Children/Kids/Animation/Animated, rated PG/PG-13/R/NC-17/TV-14/TV-MA/NR/unrated |
| 143 | **`417`** ⚠︎ | FOUND FOOTAGE | `#5D6D5F` | Movies | 3 | incl Horror, no Family/Children/Kids/Animation/Animated, title allowlist (10), kw +2, kw needs genre Horror/Science Fiction, kw-gated genre Horror |
| 144 | **`418`** ⚠︎ | WORLD HORROR | `#6A1B9A` | Movies | 3 | **TMDB manifest only**, incl Horror, no Family/Children/Kids/Animation/Animated |

### TIS THE SEASON · CH 145–152

_Christmas, Thanksgiving and holiday channels_

Spotlighted from 7 days before US Thanksgiving (the fourth Thursday of November) through Dec. Off until switched on, then on in any month.

| CH | `id` | Name | Color | Type | Min items | Rules |
|---|---|---|---|---|---|---|
| 145 | **`130`** ⚠︎ | HOLIDAZE | `#C41E3A` | Movies | 3 | incl Holiday/Christmas, title allowlist (19), title blocklist (3), editorial always-in (98), Plex rating ≥ 5 |
| 146 | **`409`** ⚠︎ | SANTA'S LIST | `#2ECC71` | Movies | 3 | incl Holiday/Christmas, title allowlist (114), title blocklist (9), rated G/PG/TV-Y/TV-Y7/TV-G/TV-PG/unrated |
| 147 | **`410`** ⚠︎ | NAUGHTY LIST | `#C0392B` | Movies | 3 | incl Holiday/Christmas, title allowlist (114), title blocklist (9), rated PG-13/R/TV-14/TV-MA |
| 148 | **`411`** ⚠︎ | NOSTALGEX CHRISTMAS | `#E74C3C` | Movies | 3 | incl Holiday/Christmas, title allowlist (114), title blocklist (9), …-1999 |
| 149 | **`412`** ⚠︎ | MISTLETOE | `#D98880` | Movies | 3 | genres include TMDB's, needs ALL Romance, no Animation/Animated, title allowlist (19), title blocklist (2), kw +12, 1980-…, rated G/PG/TV-Y/TV-Y7/TV-G/TV-PG/NR/Not Rated/unrated, 70-120 min |
| 150 | **`413`** ⚠︎ | CHRISTMAS SPECIALS | `#27AE60` | Any | 5 | episode title words (38), seasonal title words (16) if aired 11-25 to 01-07, summary words (17), episode title blocklist (18), rated TV-PG/PG/TV-14/TV-MA/PG-13/R/NR/Not Rated, ≤ 65 min |
| 151 | **`414`** ⚠︎ | KIDS CHRISTMAS TV | `#58D68D` | Any | 5 | episode title words (38), seasonal title words (16) if aired 11-25 to 01-07, summary words (17), episode title blocklist (18), rated TV-Y/TV-Y7/TV-G/G/unrated, ≤ 65 min |
| 152 | **`422`** ⚠︎ | TURKEY DAY | `#B9770E` | Any | 5 | episode title words (5), seasonal title words (7) if aired 11-01 to 11-30, summary words (2), ≤ 65 min |

### HIGH ROTATION · CH 200–213

_Music videos by genre_

| CH | `id` | Name | Color | Type | Min items | Rules |
|---|---|---|---|---|---|---|
| 200 | **`150`** ⚠︎ | HIGH ROTATION | `#FF2DB4` | Any | 3 | source: music videos |
| 201 | **`151`** ⚠︎ | POP | `#FF2DB4` | Any | 3 | source: music videos, incl Pop |
| 202 | **`152`** ⚠︎ | ROCK'N | `#FF2DB4` | Any | 3 | source: music videos, incl Rock/Hard Rock/Classic Rock |
| 203 | **`153`** ⚠︎ | COUNTRY SWAGGER | `#FF2DB4` | Any | 3 | source: music videos, incl Country/Country Rock |
| 204 | **`154`** ⚠︎ | BALLIN | `#FF2DB4` | Any | 3 | source: music videos, incl Hip-Hop/Hip Hop |
| 205 | **`155`** ⚠︎ | RAP GODS | `#FF2DB4` | Any | 3 | source: music videos, incl Rap |
| 206 | **`156`** ⚠︎ | ALT ROCK | `#FF2DB4` | Any | 3 | source: music videos, incl Alternative/Indie Rock/Alternative Rock |
| 207 | **`157`** ⚠︎ | SLOW JAMS | `#FF2DB4` | Any | 3 | source: music videos, incl R&B/Soul/Acoustic |
| 208 | **`159`** ⚠︎ | Y2K | `#FF2DB4` | Any | 3 | source: music videos, 2000-2019 |
| 209 | **`160`** ⚠︎ | CURRENT SPIN | `#FF2DB4` | Any | 3 | source: music videos, 2020-2100 |
| 210 | **`161`** ⚠︎ | DANCE FLOOR | `#FF2DB4` | Any | 3 | source: music videos, incl Electronic/Dance/House/Techno/EDM/Trance |
| 211 | **`162`** ⚠︎ | CALIENTE | `#FF2DB4` | Any | 3 | source: music videos, incl Latin/Reggaeton |
| 212 | **`163`** ⚠︎ | HEADBANGERS | `#FF2DB4` | Any | 3 | source: music videos, incl Metal |
| 213 | **`164`** ⚠︎ | GET DOWN | `#FF2DB4` | Any | 3 | source: music videos, incl Funk/Disco |

---

## `id` ≠ `number`

90 channels whose manifest/exclusivity key (`id`) is not their on-screen number. Marked ⚠︎ in the tables above.

| `id` | Airs as | Name |
|---|---|---|
| `215` | CH15 | CARTOON NETWORK |
| `405` | CH16 | DVD SHELF |
| `406` | CH17 | Y2K COMEDY |
| `407` | CH18 | Y2K SITCOMS |
| `216` | CH19 | Y2K TOONS |
| `33` | CH31 | FAMILY TV |
| `34` | CH32 | NETFLIX KIDS |
| `218` | CH33 | DREAMWORKS |
| `400` | CH34 | TOON TOWN |
| `50` | CH40 | SITCOMS |
| `51` | CH41 | FLICKS |
| `52` | CH42 | ROM COMS |
| `53` | CH43 | FEEL GOOD TV |
| `54` | CH44 | REALITY TV |
| `56` | CH45 | DOCS |
| `57` | CH46 | LOL |
| `59` | CH47 | MAN CAVE |
| `62` | CH48 | FRESH |
| `66` | CH49 | BLOCKBUSTER |
| `200` | CH50 | DRAMA TV |
| `210` | CH51 | RECORD STORE |
| `404` | CH52 | HISTORY & BIO |
| `402` | CH53 | R RATED COMEDY |
| `403` | CH54 | PREMIERES |
| `420` | CH55 | CRINGE TV |
| `60` | CH59 | ANIME |
| `61` | CH60 | MUSICALS |
| `55` | CH61 | GAME SHOWS |
| `63` | CH62 | ADULT CARTOONS |
| `64` | CH63 | DATE NIGHT |
| `58` | CH64 | STAND-UP |
| `201` | CH65 | BIOPICS |
| `67` | CH66 | ALL TIME GREATS |
| `68` | CH67 | CERTIFIED GOLD |
| `69` | CH68 | OSCAR WINNERS |
| `217` | CH69 | SKETCH COMEDY |
| `65` | CH77 | SUPERHERO MOVIES |
| `219` | CH78 | SPY GAMES |
| `419` | CH84 | MYSTERY BOX TV |
| `40` | CH85 | TRUE CRIME |
| `41` | CH86 | CRIME FLICKS |
| `42` | CH87 | THRILLERS |
| `43` | CH88 | MYSTERY |
| `44` | CH89 | CRIME TV |
| `211` | CH107 | CRITERION |
| `212` | CH108 | FOREIGN FILMS |
| `213` | CH109 | MIDNIGHT |
| `214` | CH110 | CULT CLASSICS |
| `421` | CH118 | A24 |
| `120` | CH119 | HBO |
| `121` | CH120 | APPLE TV+ |
| `122` | CH121 | NETFLIX |
| `123` | CH122 | PARAMOUNT+ |
| `124` | CH123 | AMAZON |
| `125` | CH124 | HULU |
| `126` | CH125 | SONY |
| `127` | CH126 | WARNER BROS |
| `128` | CH127 | UNIVERSAL |
| `129` | CH128 | 20TH CENTURY |
| `401` | CH129 | MIRAMAX |
| `131` | CH137 | SCREAM KIDS |
| `141` | CH138 | FRIGHT NIGHT |
| `132` | CH139 | SCREAM ADULTS |
| `408` | CH140 | NOSTALGEX HORROR |
| `415` | CH141 | SLASHER |
| `416` | CH142 | HORROR COMEDY |
| `417` | CH143 | FOUND FOOTAGE |
| `418` | CH144 | WORLD HORROR |
| `130` | CH145 | HOLIDAZE |
| `409` | CH146 | SANTA'S LIST |
| `410` | CH147 | NAUGHTY LIST |
| `411` | CH148 | NOSTALGEX CHRISTMAS |
| `412` | CH149 | MISTLETOE |
| `413` | CH150 | CHRISTMAS SPECIALS |
| `414` | CH151 | KIDS CHRISTMAS TV |
| `422` | CH152 | TURKEY DAY |
| `150` | CH200 | HIGH ROTATION |
| `151` | CH201 | POP |
| `152` | CH202 | ROCK'N |
| `153` | CH203 | COUNTRY SWAGGER |
| `154` | CH204 | BALLIN |
| `155` | CH205 | RAP GODS |
| `156` | CH206 | ALT ROCK |
| `157` | CH207 | SLOW JAMS |
| `159` | CH208 | Y2K |
| `160` | CH209 | CURRENT SPIN |
| `161` | CH210 | DANCE FLOOR |
| `162` | CH211 | CALIENTE |
| `163` | CH212 | HEADBANGERS |
| `164` | CH213 | GET DOWN |

---

_Generated from `channels.json` v46 by `scripts/render-channels-doc.mjs`. Do not edit by hand._
