/**
 * MusicBrainz enrichment for Nostalgex web tuner (browser).
 * Free API — no account/key; 1 request/sec; meaningful User-Agent required.
 * https://musicbrainz.org/doc/MusicBrainz_API
 */
(function (global) {
  const BASE = 'https://musicbrainz.org/ws/2';
  const USER_AGENT = 'Nostalgex/1.0.2 (https://www.nostalgex.app; web-tuner)';
  const CACHE_KEY = 'nostalgex_music_video_enrichments_v1';
  const MIN_INTERVAL_MS = 1050;

  let lastRequestAt = 0;
  let cache = {};

  // The self-hosted build (Docker, `<meta name="nostalgex-build" content="selfhost">`)
  // makes no MusicBrainz or Deezer requests. Titles still parse locally and cached
  // results still apply; only the online genre and year lookups are off.
  function lookupsEnabled() {
    try {
      const el = global.document && global.document.querySelector('meta[name="nostalgex-build"]');
      return !(el && el.getAttribute('content') === 'selfhost');
    } catch (e) {
      return true;
    }
  }

  function stripYearSuffix(title) {
    return String(title || '').replace(/\s+\(\d{4}\)$/, '').trim();
  }

  // Mirrors MusicTitleParser.clean in the tvOS app: ripped filenames down to
  // searchable text (underscores, [MMV]/{smg} tags, "(Shindig 1964)" notes, scene
  // suffixes, a stray "video!"). Measured 2026-10-07: recovered 10 of 13 misses.
  //
  // N-034 (2026-11-09): "Song (Official Music Video)" came out as "Song ( Music )" and
  // "Song (Official Video)" as "Song ( )", because the bare-word pass below took the
  // words out of the parentheses and left the parentheses. That text went to MusicBrainz
  // and Deezer as the search and into the guide as the title. A group made only of those
  // words now goes whole (step 5), and any parentheses a word came out of are tidied
  // (step 7). MusicTitleParser.clean (Swift) and NxCleanMusicTitle (Roku) have the old
  // passes and need the same two steps; scripts/music-title-golden.json is the contract
  // all three are to be tested against.
  const NOISE_WORD = 'official|music|video|audio|visualizer|lyrics?|remaster(?:ed)?|hd|hq|mv|4k|uhd|xvid|dvdrip|vgb|prv';
  const NOISE_GROUP = new RegExp('\\(\\s*(?:' + NOISE_WORD + ')(?:[\\s,&/+-]+(?:' + NOISE_WORD + '))*\\s*\\)', 'gi');
  function cleanTitle(raw) {
    let t = String(raw || '').replace(/_/g, ' ');                              // 1
    t = t.replace(/\[[^\]]*\]|\{[^}]*\}/g, '');                                // 2
    t = t.replace(/\s*\((?:19|20)\d\d\)\s*$/, '');                             // 3
    t = t.replace(/\([^)]*(?:19|20)\d\d[^)]*\)/g, '');                         // 4
    t = t.replace(NOISE_GROUP, '');                                            // 5
    t = t.replace(/\b(official|video|hd|hq|lyrics?|remaster(?:ed)?|mv|xvid|dvdrip|vgb|prv)\b!?/gi, '');   // 6
    t = t.replace(/\(\s*\)/g, '').replace(/\(\s+/g, '(').replace(/\s+\)/g, ')');   // 7
    t = t.replace(/\s+/g, ' ');                                                // 8
    return t.replace(/^[\s\-!.]+|[\s\-!.]+$/g, '');                            // 9
  }

  // The "(1988)" a filename carries: the one year source besides MusicBrainz that the
  // decade channels can trust (Plex: 1970 or date added; Deezer: album/remaster year).
  function yearInTitle(raw) {
    const m = String(raw || '').match(/\(((?:19|20)\d\d)\)/);
    return m ? parseInt(m[1], 10) : null;
  }

  function resolveMusicYear(titleYear, musicBrainzYear, plexYear) {
    if (titleYear) return titleYear;
    if (musicBrainzYear) return musicBrainzYear;
    const y = parseInt(String(plexYear || ''), 10);
    if (!y) return null;
    const thisYear = new Date().getFullYear();
    return y > 1970 && y < thisYear ? y : null;
  }

  function stripFeaturing(s, artistSide) {
    const re = artistSide
      ? /\s+(?:ft\.?|feat\.?|featuring|with|and the)\s+.*$/i
      : /\s+(?:ft\.?|feat\.?|featuring)\s+.*$/i;
    return String(s || '').replace(re, '').replace(/^[\s,]+|[\s,]+$/g, '');
  }

  function parseTitle(raw) {
    const cleaned = cleanTitle(raw);
    const dash = cleaned.indexOf(' - ');
    if (dash > 0) {
      const artist = stripFeaturing(cleaned.slice(0, dash), true);
      let song = cleaned.slice(dash + 3).trim();
      const next = song.indexOf(' - ');
      if (next > 0) song = song.slice(0, next);
      song = stripFeaturing(song, false);
      if (artist && song) return { artist, song };
    }
    const byIdx = cleaned.toLowerCase().lastIndexOf(' by ');
    if (byIdx > 0) {
      const song = stripFeaturing(cleaned.slice(0, byIdx), false);
      const artist = stripFeaturing(cleaned.slice(byIdx + 4), true);
      if (artist && song) return { artist, song };
    }
    const lone = cleaned.match(/^(.{2,}?)-(.+)$/);
    if (lone && !lone[1].includes(' - ')) {
      const artist = stripFeaturing(lone[1], true);
      const song = stripFeaturing(lone[2], false);
      if (artist.length >= 2 && song.length >= 2) return { artist, song };
    }
    return { artist: null, song: stripFeaturing(cleaned, false) };
  }

  // ── Deezer (genres MusicBrainz leaves blank) ─────────────────────────
  // api.deezer.com has no CORS headers, so the browser goes through JSONP.
  // Album genres are what Deezer tags; tracks and artists carry none.
  const DEEZER_BASE = 'https://api.deezer.com';
  const DEEZER_MIN_INTERVAL_MS = 250;
  let deezerLastRequestAt = 0;
  let deezerCallbackSeq = 0;

  function deezerJSONP(path, params) {
    if (!lookupsEnabled()) return Promise.reject(new Error('Music lookups are off in the self-hosted build'));
    return new Promise((resolve, reject) => {
      const elapsed = Date.now() - deezerLastRequestAt;
      const wait = elapsed < DEEZER_MIN_INTERVAL_MS ? DEEZER_MIN_INTERVAL_MS - elapsed : 0;
      setTimeout(() => {
        deezerLastRequestAt = Date.now();
        const cb = `__nostalgexDeezer${++deezerCallbackSeq}`;
        const q = new URLSearchParams({ ...(params || {}), output: 'jsonp', callback: cb });
        const script = document.createElement('script');
        const timer = setTimeout(() => { cleanup(); reject(new Error('Deezer timeout')); }, 15000);
        function cleanup() { clearTimeout(timer); delete global[cb]; script.remove(); }
        global[cb] = (data) => { cleanup(); resolve(data); };
        script.onerror = () => { cleanup(); reject(new Error('Deezer script error')); };
        script.src = `${DEEZER_BASE}${path}?${q.toString()}`;
        document.head.appendChild(script);
      }, wait);
    });
  }

  // Mirrors DeezerService.mapGenres in the tvOS app.
  function mapDeezerGenres(raw) {
    const out = [];
    const add = (...names) => { for (const g of names) if (!out.some((x) => x.toLowerCase() === g.toLowerCase())) out.push(g); };
    for (const name of raw || []) {
      const g = String(name).toLowerCase();
      switch (g) {
        case 'pop': case 'international pop': case 'indie pop': case 'k-pop': case 'j-pop': case 'latin pop':
          add('Pop'); if (g === 'indie pop') add('Alternative'); if (g === 'latin pop') add('Latin'); break;
        case 'rock': add('Rock'); break;
        case 'hard rock': add('Hard Rock', 'Rock'); break;
        case 'classic rock': add('Classic Rock', 'Rock'); break;
        case 'indie rock': case 'indie rock/rock pop': add('Indie Rock', 'Alternative', 'Rock'); break;
        case 'alternative': add('Alternative'); break;
        case 'punk': add('Punk', 'Rock', 'Alternative'); break;
        case 'metal': add('Metal', 'Hard Rock', 'Rock'); break;
        case 'rap/hip hop': add('Hip-Hop', 'Hip Hop', 'Rap'); break;
        case 'r&b': add('R&B'); break;
        case 'soul & funk': add('Soul', 'Funk'); break;
        case 'disco': add('Disco', 'Funk'); break;
        case 'dance': case 'dancefloor': add('Dance', 'Electronic'); break;
        case 'electro': case 'dubstep': case 'chill out/trip-hop/lounge': case 'electro pop/electro rock':
          add('Electronic', 'Dance'); if (g === 'electro pop/electro rock') add('Pop'); break;
        case 'techno/house': add('House', 'Techno', 'Electronic', 'Dance'); break;
        case 'country': add('Country'); break;
        case 'latin music': case 'brazilian music': add('Latin'); break;
        case 'reggaeton': add('Reggaeton', 'Latin'); break;
        case 'reggae': add('Reggae'); break;
        case 'folk': add('Acoustic', 'Folk'); break;
        case 'jazz': add('Jazz'); break;
        case 'blues': add('Blues'); break;
        default: break;
      }
    }
    return out;
  }

  function deezerBestHit(hits, artistHint) {
    if (!hits || !hits.length) return null;
    const hint = (artistHint || '').toLowerCase();
    if (!hint) return hits[0];
    const words = new Set(hint.split(/[^a-z0-9]+/).filter((w) => w.length > 2));
    if (!words.size) return hits[0];
    return hits.find((h) => String(h.artist && h.artist.name || '').toLowerCase().split(/[^a-z0-9]+/).some((w) => words.has(w))) || hits[0];
  }

  // Artist+song first, bare song second; one album fetch for genres and year.
  async function deezerResolve(song, artist) {
    const s = String(song || '').trim();
    if (!s) return null;
    const queries = artist ? [`${artist} ${s}`, s] : [s];
    for (const q of queries) {
      const res = await deezerJSONP('/search', { q, limit: '5' });
      const pick = deezerBestHit((res && res.data) || [], artist);
      if (!pick || !pick.album) continue;
      const album = await deezerJSONP(`/album/${pick.album.id}`, {});
      const rawGenres = ((album && album.genres && album.genres.data) || []).map((g) => g.name).filter(Boolean);
      const releaseYear = album && album.release_date ? parseInt(String(album.release_date).slice(0, 4), 10) || null : null;
      return {
        trackID: pick.id,
        title: pick.title,
        artist: pick.artist ? pick.artist.name : null,
        rawGenres,
        genres: mapDeezerGenres(rawGenres),
        releaseYear,
      };
    }
    return null;
  }

  async function withDeezerGenres(enr, item) {
    const parsed = parseTitle(item.title);
    const song = enr.recordingTitle || parsed.song;
    const artist = enr.artist || parsed.artist || null;
    const out = { ...enr, deezerCheckedAt: Date.now() };
    try {
      const match = await deezerResolve(song, artist);
      if (match) {
        out.genres = mergeGenres(enr.genres, match.genres);
        out.deezerID = match.trackID;
        if (!out.artist) out.artist = match.artist;
      }
    } catch (e) {
      console.warn('[Deezer] resolve failed', item.title, e);
    }
    out.hasUsefulGenres = usefulGenres(out.genres);
    return out;
  }

  function usefulGenres(genres) {
    return (genres || []).some((g) => {
      const l = String(g).toLowerCase();
      return !l.includes('music video') && l !== 'music' && l !== 'musical';
    });
  }

  function isSettled(enr) {
    if (!enr) return false;
    if (Date.now() - (enr.fetchedAt || 0) > 90 * 86400 * 1000) return false;
    return !!enr.hasUsefulGenres || !!enr.deezerCheckedAt;
  }

  function needsOnlyGenres(enr) {
    return !!enr && !enr.hasUsefulGenres && !enr.deezerCheckedAt && !!(enr.artist || enr.musicBrainzID);
  }

  function mapTagsToChannelGenres(tags) {
    const out = [];
    const add = (g) => {
      if (!out.some((x) => x.toLowerCase() === g.toLowerCase())) out.push(g);
    };
    for (const tag of tags) {
      const t = String(tag).toLowerCase();
      if (t.includes('pop') && !t.includes('k-pop')) add('Pop');
      if (t.includes('rock')) {
        if (t.includes('alternative') || t.includes('indie')) {
          add('Alternative Rock');
          add('Indie Rock');
        } else if (t.includes('hard rock') || t.includes('hard-rock')) add('Hard Rock');
        else if (t.includes('classic rock')) add('Classic Rock');
        else add('Rock');
      }
      if (t.includes('country')) {
        add('Country');
        if (t.includes('rock')) add('Country Rock');
      }
      if (t.includes('hip hop') || t.includes('hip-hop')) {
        add('Hip-Hop');
        add('Hip Hop');
      }
      if (t === 'rap' || t.includes('gangsta')) add('Rap');
      if (t.includes('r&b') || t.includes('rhythm and blues') || t === 'soul') {
        add('R&B');
        add('Soul');
      }
      if (t.includes('acoustic')) add('Acoustic');
      if (t.includes('electronic') || t.includes('dance') || t.includes('edm') ||
          t.includes('house') || t.includes('techno') || t.includes('trance')) add('Dance');
      if (t.includes('metal')) {
        add('Metal');
        add('Hard Rock');
        add('Rock');
      }
      if (t.includes('punk')) {
        add('Rock');
        add('Alternative');
      }
      if (t.includes('folk')) add('Acoustic');
      if (t.includes('latin') || t.includes('reggaeton') || t.includes('reggaetón')) add('Latin');
      if (t.includes('funk')) add('Funk');
      if (t.includes('disco')) add('Disco');
    }
    return out;
  }

  function primaryArtistName(rec) {
    const credits = rec['artist-credit'];
    if (!Array.isArray(credits)) return null;
    for (const credit of credits) {
      if (credit.name) return credit.name;
      if (credit.artist && credit.artist.name) return credit.artist.name;
    }
    return null;
  }

  function firstReleaseYear(rec) {
    const releases = rec.releases;
    if (!Array.isArray(releases)) return null;
    for (const release of releases) {
      const date = release.date;
      if (date && date.length >= 4) {
        const y = parseInt(date.slice(0, 4), 10);
        if (!Number.isNaN(y)) return y;
      }
    }
    return null;
  }

  function extractTagNames(rec) {
    if (!Array.isArray(rec.tags)) return [];
    return rec.tags.map((t) => t.name).filter(Boolean);
  }

  async function rateLimitedFetch(url) {
    if (!lookupsEnabled()) throw new Error('Music lookups are off in the self-hosted build');
    const elapsed = Date.now() - lastRequestAt;
    if (elapsed < MIN_INTERVAL_MS) {
      await new Promise((r) => setTimeout(r, MIN_INTERVAL_MS - elapsed));
    }
    lastRequestAt = Date.now();
    const res = await fetch(url, {
      headers: {
        Accept: 'application/json',
        'User-Agent': USER_AGENT,
      },
    });
    if (!res.ok) throw new Error(`MusicBrainz HTTP ${res.status}`);
    return res.json();
  }

  function escapeQuery(s) {
    return String(s).replace(/"/g, '');
  }

  async function searchBestRecording(songTitle, artist, year) {
    const parts = [`recording:"${escapeQuery(songTitle)}"`, 'video:true'];
    if (artist) parts.push(`artist:"${escapeQuery(artist)}"`);
    const query = encodeURIComponent(parts.join(' AND '));
    const json = await rateLimitedFetch(`${BASE}/recording?query=${query}&fmt=json&limit=10`);
    const recordings = json.recordings || [];
    if (!recordings.length) return null;

    const songLower = songTitle.toLowerCase();
    let best = null;
    let bestRank = -1;

    for (const rec of recordings) {
      if (!rec.id || !rec.title) continue;
      const score = rec.score || 0;
      const artistName = primaryArtistName(rec);
      const recYear = firstReleaseYear(rec);
      let rank = score;
      const titleLower = rec.title.toLowerCase();
      if (titleLower === songLower) rank += 40;
      else if (titleLower.includes(songLower) || songLower.includes(titleLower)) rank += 20;
      if (artist && artistName && artistName.toLowerCase().includes(artist.toLowerCase())) rank += 25;
      if (year && recYear === year) rank += 15;
      else if (year && recYear != null && Math.abs(year - recYear) <= 1) rank += 8;
      if (rank > bestRank) {
        bestRank = rank;
        best = { mbid: rec.id, title: rec.title, artist: artistName, year: recYear };
      }
    }
    return best;
  }

  async function lookupRecording(mbid) {
    const json = await rateLimitedFetch(
      `${BASE}/recording/${mbid}?inc=artist-credits+tags+releases&fmt=json`
    );
    if (!json.title) return null;
    const tags = extractTagNames(json);
    return {
      mbid,
      recordingTitle: json.title,
      artist: primaryArtistName(json),
      genres: mapTagsToChannelGenres(tags),
      releaseYear: firstReleaseYear(json),
    };
  }

  async function resolveRecording(title, artist, year) {
    const song = stripYearSuffix(title);
    if (!song) return null;
    const hit = await searchBestRecording(song, artist, year);
    if (!hit) return null;
    try {
      const detailed = await lookupRecording(hit.mbid);
      if (detailed) return detailed;
    } catch (e) {
      console.warn('[MusicBrainz] lookup failed', hit.mbid, e);
    }
    return {
      mbid: hit.mbid,
      recordingTitle: hit.title,
      artist: hit.artist,
      genres: [],
      releaseYear: hit.year,
    };
  }

  function loadDiskCache() {
    try {
      const raw = localStorage.getItem(CACHE_KEY);
      if (!raw) {
        cache = {};
        return;
      }
      cache = JSON.parse(raw) || {};
    } catch {
      cache = {};
    }
  }

  function saveDiskCache() {
    try {
      localStorage.setItem(CACHE_KEY, JSON.stringify(cache));
    } catch (e) {
      console.warn('[MusicBrainz] cache save failed', e);
    }
  }

  function plexGenresAreThin(genres) {
    const useful = (genres || []).filter((g) => {
      const l = String(g).toLowerCase();
      return !l.includes('music video') && l !== 'music' && l !== 'musical';
    });
    return useful.length === 0;
  }

  function mergeGenres(plex, resolved) {
    const out = [...(plex || [])];
    for (const g of resolved || []) {
      if (!out.some((x) => x.toLowerCase() === g.toLowerCase())) out.push(g);
    }
    return out;
  }

  function isMusicVideoItem(item) {
    return item && item.librarySource === 'musicVideo' && item.type !== 'episode';
  }

  function buildMusicMeta(item) {
    const parts = [];
    if (item.artist) parts.push(item.artist);
    if (item.year) parts.push(String(item.year));
    const genres = musicGenreDisplay(item);
    if (genres) parts.push(genres);
    if (item.duration) parts.push(formatDuration(item.duration));
    return parts.join(' · ');
  }

  function formatDuration(minutes) {
    const h = Math.floor(minutes / 60);
    const m = minutes % 60;
    return h > 0 ? `${h}h ${m}m` : `${m}m`;
  }

  function musicGenreDisplay(item) {
    if (!isMusicVideoItem(item)) return null;
    const useful = (item.genres || []).filter((g) => {
      const l = String(g).toLowerCase();
      return !l.includes('music video') && l !== 'music' && l !== 'musical';
    });
    if (!useful.length) return null;
    return useful.slice(0, 4).join(' · ');
  }

  function itemDisplayLine(item) {
    if (!isMusicVideoItem(item)) {
      if (item.episodeTitle) return `${item.title}: ${item.episodeTitle}`;
      return item.title || '';
    }
    if (item.artist) return `${item.artist} — ${item.title}`;
    return item.title || '';
  }

  function applyEnrichmentToItem(item, enr) {
    if (!enr || !isMusicVideoItem(item)) return item;
    const title = (enr.recordingTitle || item.title || '').trim() || item.title;
    const artist = enr.artist || item.artist || null;
    const genres = mergeGenres(item.genres, enr.genres);
    const year = resolveMusicYear(yearInTitle(item.title), enr.releaseYear, item.year) || '';
    const updated = {
      ...item,
      title,
      artist,
      genres,
      year,
      meta: buildMusicMeta({ ...item, title, artist, genres, year }),
    };
    return updated;
  }

  function itemsWithDisplayMetadata(items) {
    return items.map((item) => {
      const enr = cache[item.ratingKey];
      if (enr) return applyEnrichmentToItem(item, enr);
      if (!isMusicVideoItem(item)) return item;
      const year = resolveMusicYear(yearInTitle(item.title), null, item.year) || '';
      return year === (item.year || '') ? item : { ...item, year };
    });
  }

  function parseMusicVideoFromPlex(item, rawTitle) {
    const parent = item.parentTitle || '';
    const grandparent = item.grandparentTitle || '';
    const artistHint = parent || grandparent || null;
    const parsed = parseTitle(rawTitle);
    return {
      title: parsed.song || rawTitle,
      artist: artistHint || parsed.artist || null,
    };
  }

  async function enrichMusicVideos(items, onProgress) {
    loadDiskCache();
    const mv = items.filter(isMusicVideoItem);
    if (!mv.length) return { enriched: 0, total: 0 };
    if (!lookupsEnabled()) return { enriched: 0, total: mv.length, skipped: true };

    let updated = 0;
    let done = 0;
    for (const item of mv) {
      done += 1;
      if (onProgress) onProgress(done, mv.length, item.title);

      const existing = cache[item.ratingKey];
      if (isSettled(existing)) continue;
      if (needsOnlyGenres(existing)) {
        // Named by MusicBrainz, never got a genre: Deezer only, no second 1/sec crawl.
        cache[item.ratingKey] = await withDeezerGenres(existing, item);
        updated += 1;
        continue;
      }
      if (existing && !plexGenresAreThin(item.genres) && existing.artist) {
        continue;
      }

      const parsed = parseTitle(item.title);
      const artistHint = item.artist || parsed.artist;
      const songTitle = parsed.song;
      const yearNum = item.year ? parseInt(String(item.year), 10) : null;
      const year = Number.isNaN(yearNum) ? null : yearNum;

      try {
        const match = await resolveRecording(songTitle, artistHint, year);
        const enr = {
          ratingKey: item.ratingKey,
          recordingTitle: match ? match.recordingTitle : songTitle,
          artist: (match && match.artist) || artistHint || null,
          musicBrainzID: match ? match.mbid : null,
          genres: mergeGenres(item.genres, match ? match.genres : []),
          releaseYear: match ? match.releaseYear : null,
          fetchedAt: Date.now(),
        };
        enr.hasUsefulGenres = usefulGenres(enr.genres);
        cache[item.ratingKey] = enr.hasUsefulGenres ? enr : await withDeezerGenres(enr, item);
        updated += 1;
      } catch (e) {
        console.warn('[MusicBrainz] resolve failed', item.title, e);
        const fallback = {
          ratingKey: item.ratingKey,
          recordingTitle: songTitle,
          artist: artistHint || null,
          musicBrainzID: null,
          genres: item.genres || [],
          releaseYear: null,
          fetchedAt: Date.now(),
          hasUsefulGenres: usefulGenres(item.genres),
        };
        cache[item.ratingKey] = fallback.hasUsefulGenres ? fallback : await withDeezerGenres(fallback, item);
        updated += 1;
      }
    }
    if (updated) saveDiskCache();
    return { enriched: updated, total: mv.length };
  }

  function titleHaystack(item) {
    const parts = [stripYearSuffix(item.title || '')];
    if (item.artist) parts.push(item.artist);
    return parts.join(' ').toLowerCase();
  }

  global.NostalgexMusicBrainz = {
    lookupsEnabled,
    parseTitle,
    cleanTitle,
    yearInTitle,
    resolveMusicYear,
    stripYearSuffix,
    deezerResolve,
    mapDeezerGenres,
    parseMusicVideoFromPlex,
    isMusicVideoItem,
    itemDisplayLine,
    musicGenreDisplay,
    buildMusicMeta,
    titleHaystack,
    loadDiskCache,
    saveDiskCache,
    enrichMusicVideos,
    itemsWithDisplayMetadata,
    applyEnrichmentToItem,
    mapTagsToChannelGenres,
  };
})(typeof globalThis !== 'undefined' ? globalThis : window);
