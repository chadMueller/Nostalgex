// Jellyfin / Emby stream URLs for the web tuner.
//
// PARITY with tvOS
//   Nostalgex/Nostalgex/Services/JellyfinPlaybackResolver.swift  staticStreamURL
//   Nostalgex/Nostalgex/Services/JellyfinAPIService.swift        addingApiKey
//   Nostalgex/Nostalgex/Services/EmbyAPIService.swift            buildTranscodeURL(for:sessionID:)
//
// 1. Direct play asks for /Videos/{id}/stream.mp4, not /Videos/{id}/stream. Jellyfin 12.2
//    sets the Content-Type of a static stream from the FILE NAME, so an MP4 saved as .mkv
//    comes back video/x-matroska (and a .m4v as video/x-m4v, a .mov as video/quicktime).
//    The extension makes the server label the same bytes video/mp4. Only used for the
//    mp4/m4v/mov family; anything else keeps the extensionless URL.
// 2. Every hand-built HLS URL carries ApiKey beside api_key. Jellyfin 12.2 with legacy
//    authorization off (the default on a new install) answers 401 to api_key alone.
//    api_key stays for servers older than ApiKey. Emby 4.10 accepts both.
//
// Measured 2026-10-12 against local Jellyfin 12.2.0 and Emby 4.10.1.0.
//
// 3. The hand-built HLS fallback carries a PlaySessionId. Emby writes each segment URL as
//    hls1/main/0.ts?PlaySessionId=<id> and nothing else, so a master without one gets
//    segments asking for `PlaySessionId=` with no value, and Emby 4.10.1.0 answers every
//    one HTTP 400 "Value cannot be null. (Parameter 'key')" while master and variant
//    still answer 200. This is the URL a failed direct play retries with: PlaybackInfo
//    hands back no TranscodingUrl for a file it thinks the browser can play. With a
//    client-made id all segments are 200. Jellyfin copies the whole query string onto
//    segments and plays with or without one (12.2.0). Measured 2026-10-13.
//
// EMBY, where it differs from Jellyfin. Mirrors Nostalgex/Nostalgex/Services/EmbyAPIService.swift.
// Measured 2026-10-16 against Emby Server 4.8.11.0, 4.9.5.0 and 4.10.1.0, and Jellyfin 12.2.0.
//
// 4. Libraries are /Users/{id}/Views. /UserViews?userId= is Jellyfin's spelling and answers
//    404 on all three Emby versions, so the web tuner could never load an Emby library
//    through its Jellyfin sign-in. Jellyfin keeps /UserViews exactly as before.
// 5. After a failed direct play, PlaybackInfo needs EnableDirectPlay AND EnableDirectStream
//    false before Emby hands back a TranscodingUrl. With direct play off alone Emby 4.10.1.0
//    still says SupportsDirectStream and gives no URL (an 8-bit H.264 + AAC MP4). Same rule as
//    JellyfinPlaybackResolver.playbackInfoBody on Apple TV. Jellyfin's body is left as it is.
// 6. Telling them apart: /System/Info/Public on Jellyfin carries ProductName "Jellyfin Server";
//    Emby has no ProductName and lists LocalAddresses (plural). Emby's sign-in result also has
//    no User.ServerName, so the server's name comes from the same public info.
//
// JELLYFIN QUICK CONNECT. Mirrors JellyfinAPIService.quickConnectInitiate on Apple TV.
//
// 7. Quick Connect starts with POST /QuickConnect/Initiate. Jellyfin 12.2.0 answers a GET
//    405 with an empty body (measured 2026-10-19), and the tuner sent a GET, so it showed
//    QUICK CONNECT IS NOT ENABLED ON THIS SERVER with Quick Connect on. Jellyfin's history
//    (QuickConnectController.cs): 10.7 and 10.8 route only GET, 10.9 to 10.11 answer both,
//    12.0 removed the GET. So POST first, and GET again only on 405 or 404. The poll
//    (GET /QuickConnect/Connect) and POST /Users/AuthenticateWithQuickConnect are unchanged.
//
// SUBTITLES. Mirrors JellyfinPlaybackResolver.noSubtitleStream and .subtitleProfiles on Apple TV.
//
// 8. PlaybackInfo asks for no subtitle stream (SubtitleStreamIndex -1) and lists every subtitle
//    format as External. The tuner fetches the subtitle it shows itself, as WebVTT, in full
//    screen only. Without this the server picked a track by the account's subtitle mode and
//    burned it into the picture: a full video re-encode, subtitles in the small player, and a
//    second copy on top when the tuner showed its own. Measured 2026-10-19, Jellyfin 12.2.0
//    (mode Default) burned every default or forced track (SRT, ASS, PGS, VobSub, mov_text, a
//    sidecar .srt), Emby 4.10.1.0 (mode Smart) every forced one. With both fields every case
//    copies the video on both servers. -1 counts only with a matching MediaSourceId.
// 9. Only text tracks can be shown. The WebVTT endpoint turns SRT, ASS and mov_text into cues,
//    but a PGS or VobSub track came back HTTP 400 from Jellyfin 12.2.0 and as an empty WEBVTT
//    from Emby 4.10.1.0. A Blu-ray rip often lists an English PGS before an English SRT, so
//    the tuner picked the PGS and showed nothing. isTextSubtitle tells them apart.
// 10. One exception to 8: a track flagged forced, in the viewer's subtitle language, is burned
//    in. Those are the lines a film means to be read (Na'vi in Avatar), and the Apple TV app
//    shows them even with subtitles off (JellyfinPlaybackResolver.forcedSubtitleToBurn). The
//    tuner's own WebVTT is full screen only, so the server paints them: PlaybackInfo names
//    the track and lists every format as Encode. External would stop it again: asked for a
//    track by index with External profiles, both servers answered External and copied the
//    video; with Encode both burned it in (Jellyfin 12.2.0 and Emby 4.10.1.0, SRT, PGS and
//    VobSub forced tracks, measured 2026-10-19). A track only flagged default is never burned.
//    The cost is a video re-encode for these files only.
//
// DOLBY VISION ON EMBY. Mirrors EmbyAPIService.doviProfile(extendedVideoSubType:) on Apple TV.
//
// 11. Emby names a file's Dolby Vision profile in the video stream's ExtendedVideoSubType:
//    "DoviProfile50" is profile 5, "DoviProfile81" 8.1, "DoviProfile76" 7.6 (the last digit is
//    the base layer's compatibility id). Emby has no DvProfile field; that is Jellyfin's, and
//    Jellyfin has no ExtendedVideoSubType. The library scan already asks for MediaSources,
//    which carries it on Emby 4.10.1.0 for films and episodes (measured 2026-10-19). Anything
//    else ("Hdr10", "None", missing) is null, an unknown profile. embyDoviProfile reads it;
//    the channel filter's isLeftOffChannels keeps profile 5 off every channel on Emby.
//
// WHAT A LIBRARY SCAN READS. Mirrors JellyfinAPIService.sectionType and .itemTypes on Apple TV.
//
// 12. Only videos reach the guide. The scan once treated every view that was not TV or Music
//    Videos as a film library and asked it for IncludeItemTypes=Movie. The Playlists view is one
//    of those, and Jellyfin's PlaylistsFolder.GetItemsInternal overwrites the request with
//    `Recursive = true; IncludeItemTypes = [Playlist]`, so the answer to "Movie" under it was
//    the playlists. A playlist of eight songs (33 minutes, no year, no genre) went on the guide
//    as a film and passed every rule that says only "a movie" and "1980 to 1999 or no year":
//    CH 7 VHS VAULT, CH 16 DVD SHELF, CH 51 FLICKS. Playing it answered HTTP 500, because the
//    server has no video to send for a playlist. Now: sectionType gives 'other' for a view that
//    holds no videos (Music, Playlists, Collections, Books, Photos, Home Videos, Live TV,
//    Trailers, Folders), and the scan never asks it for items. For the rest, itemTypes is what
//    to ask for ('Movie', or 'Movie,MusicVideo' for Music Videos, I-067), and hasAskedType drops
//    any row whose Type was not asked for, for a server that answers with more than it was asked.
//    A row with no Type is kept. A view with no CollectionType (mixed content) is a film view.
//    scripts/jellyfin-library-golden.json pins both functions, for the other apps to port.
//
// Same on both, so shared: the MediaBrowser Authorization header (Emby 4.10 accepts it on every
// call the tuner makes), AuthenticateByName with { Username, Pw }, /Items, PlaybackInfo, the
// static stream, subtitle VTT, /Users/{id}/... watch state, and DELETE /Videos/ActiveEncodings,
// which ends an Emby encode within a second on its own (measured).
//
// USAGE (browser: plain <script src="scripts/nostalgex-jellyfin-urls.js">,
// node: `import "./nostalgex-jellyfin-urls.js"`, then globalThis):
//
//   const JU = window.NostalgexJellyfinUrls;
//   JU.staticStreamUrl({ serverUrl, itemId, mediaSourceId, container, token, audioStreamIndex });
//   JU.withApiKey(url, token);
//   JU.fallbackHlsUrl({ serverUrl, itemId, mediaSourceId, token, deviceId, playSessionId });
//   JU.userViewsPath(backend, userId);
//   JU.serverStreamOnlyFields(backend, serverStreamOnly);
//   JU.serverKindFromPublicInfo(json);
//   await JU.quickConnectInitiate(serverUrl, headers[, fetchImpl]);   // the Response
//   JU.subtitleProfiles(method);  JU.NO_SUBTITLE_STREAM;  JU.isTextSubtitle(codec);
//   JU.forcedSubtitleToBurn(subtitles, matchesViewerLanguage);   // a subtitle, or null
//   JU.embyDoviProfile(extendedVideoSubType);   // 5, 8, 7, or null
//   JU.sectionType(collectionType);   // 'show', 'musicvideo', 'movie' or 'other' (see 12)
//   JU.itemTypes(sectionType);   // 'Series', 'Movie', 'Movie,MusicVideo', or null for 'other'
//   JU.hasAskedType(item, includeItemTypes);   // false for a row of a type that was not asked for

(function (global) {
  'use strict';

  const MP4_FAMILY = new Set(['mp4', 'm4v', 'mov']);

  function isMp4Family(container) {
    // Jellyfin can report a comma list straight from ffprobe ("mov,mp4,m4a,3gp,3g2,mj2").
    return String(container || '')
      .toLowerCase()
      .split(',')
      .some(c => MP4_FAMILY.has(c.trim()));
  }

  function staticStreamUrl(opts) {
    const { serverUrl, itemId, mediaSourceId, container, token, audioStreamIndex } = opts;
    const path = isMp4Family(container) ? 'stream.mp4' : 'stream';
    let url = `${serverUrl}/Videos/${itemId}/${path}`
      + `?Static=true&MediaSourceId=${encodeURIComponent(mediaSourceId)}&api_key=${token}`;
    if (audioStreamIndex !== undefined && audioStreamIndex !== null) {
      url += `&AudioStreamIndex=${audioStreamIndex}`;
    }
    return url;
  }

  function hasParam(url, name) {
    return new RegExp(`[?&]${name}=`).test(url);
  }

  function withApiKey(url, token) {
    let out = url;
    for (const name of ['api_key', 'ApiKey']) {
      if (!hasParam(out, name)) out += (out.includes('?') ? '&' : '?') + `${name}=${token}`;
    }
    return out;
  }

  // crypto.randomUUID exists only in a secure context, and a self-hosted tuner on a LAN
  // address over plain http is not one. 32 hex characters is the shape Emby mints itself.
  function newPlaySessionId() {
    const c = global.crypto;
    if (c && typeof c.randomUUID === 'function') return c.randomUUID();
    let id = '';
    for (let i = 0; i < 32; i++) id += Math.floor(Math.random() * 16).toString(16);
    return id;
  }

  // Used when PlaybackInfo has no TranscodingUrl to give (see 3 above).
  function fallbackHlsUrl(opts) {
    const { serverUrl, itemId, mediaSourceId, token, deviceId } = opts;
    const playSessionId = opts.playSessionId || newPlaySessionId();
    // STREAM QUALITY (scripts/nostalgex-stream-quality.js): a capped level passes its width and
    // a VideoBitrate in bits per second. Left out, the URL is what it always was.
    const maxWidth = opts.maxWidth || 3840;
    const videoBitrate = opts.videoBitrate ? `&VideoBitrate=${opts.videoBitrate}` : '';
    return withApiKey(`${serverUrl}/Videos/${itemId}/master.m3u8`
      + `?MediaSourceId=${encodeURIComponent(mediaSourceId)}&api_key=${token}`
      + `&VideoCodec=h264&AudioCodec=aac&MaxWidth=${maxWidth}${videoBitrate}&SegmentContainer=ts&DeviceId=${deviceId}`
      + `&PlaySessionId=${encodeURIComponent(playSessionId)}`, token);
  }

  // The two backends that speak this API. Everything in this file applies to both unless a
  // function says otherwise.
  function isMediaBrowser(backend) {
    return backend === 'jellyfin' || backend === 'emby';
  }

  // Where a user's libraries are listed (see 4 above).
  function userViewsPath(backend, userId) {
    const id = encodeURIComponent(userId || '');
    return backend === 'emby' ? `/Users/${id}/Views` : `/UserViews?userId=${id}`;
  }

  // Extra PlaybackInfo body fields for the retry after a failed direct play (see 5 above).
  // Empty for Jellyfin and for a first attempt, so those requests are unchanged.
  function serverStreamOnlyFields(backend, serverStreamOnly) {
    if (backend !== 'emby' || !serverStreamOnly) return {};
    return { EnableDirectPlay: false, EnableDirectStream: false };
  }

  // 'jellyfin', 'emby', or null when the answer does not say (see 6 above).
  function serverKindFromPublicInfo(info) {
    if (!info || typeof info !== 'object') return null;
    if (typeof info.ProductName === 'string') {
      return /jellyfin/i.test(info.ProductName) ? 'jellyfin' : null;
    }
    if (Array.isArray(info.LocalAddresses) && typeof info.Version === 'string' && typeof info.Id === 'string') {
      return 'emby';
    }
    return null;
  }

  // Starts Quick Connect (see 7 above). Resolves to the server's Response; the caller reads
  // it as before. A network failure rejects as fetch does.
  function quickConnectInitiateRetriesWithGet(status) {
    return status === 405 || status === 404;
  }

  async function quickConnectInitiate(serverUrl, headers, fetchImpl) {
    const send = fetchImpl || ((url, init) => global.fetch(url, init));
    const url = `${serverUrl}/QuickConnect/Initiate`;
    const res = await send(url, { method: 'POST', headers });
    if (!quickConnectInitiateRetriesWithGet(res.status)) return res;
    return send(url, { method: 'GET', headers });
  }

  // Subtitles (see 8 and 9 above). Names are the servers' own codec names, any case.
  const TEXT_SUBTITLES = ['srt', 'subrip', 'ass', 'ssa', 'vtt', 'webvtt', 'mov_text', 'ttml', 'sub', 'smi', 'sami'];
  const IMAGE_SUBTITLES = ['pgs', 'pgssub', 'dvdsub', 'vobsub', 'dvbsub', 'sup', 'xsub'];
  const NO_SUBTITLE_STREAM = -1;

  // 'External' (the default) or 'Encode' when burning the forced track (see 10 above).
  function subtitleProfiles(method) {
    const Method = method === 'Encode' ? 'Encode' : 'External';
    return TEXT_SUBTITLES.concat(IMAGE_SUBTITLES).map(Format => ({ Format, Method }));
  }

  // The first forced track whose language the viewer reads, or null (see 10 above).
  // `subtitles` are the page's item.subtitles: { index, lang, forced, codec }.
  function forcedSubtitleToBurn(subtitles, matchesViewerLanguage) {
    if (!Array.isArray(subtitles)) return null;
    return subtitles.find(s => s && s.forced === true && matchesViewerLanguage(s.lang)) || null;
  }

  function isTextSubtitle(codec) {
    return TEXT_SUBTITLES.includes(String(codec || '').toLowerCase());
  }

  // Emby's Dolby Vision profile (see 11 above): "DoviProfile50" -> 5, anything else -> null.
  function embyDoviProfile(extendedVideoSubType) {
    const m = /^doviprofile(\d{2,})$/i.exec(String(extendedVideoSubType || ''));
    return m ? Number(m[1].slice(0, -1)) : null;
  }

  // Views that hold no videos (see 12 above). Anything else, including no CollectionType at all
  // (mixed content), is read as films.
  const NON_VIDEO_VIEWS = new Set([
    'music', 'playlists', 'boxsets', 'books', 'audiobooks', 'photos', 'homevideos', 'livetv', 'trailers', 'folders', 'channels',
  ]);

  // A view's CollectionType as the kind of section the scan branches on.
  function sectionType(collectionType) {
    const ct = String(collectionType || '').toLowerCase();
    if (ct === 'tvshows') return 'show';
    if (ct === 'musicvideos') return 'musicvideo';
    if (NON_VIDEO_VIEWS.has(ct)) return 'other';
    return 'movie';
  }

  // IncludeItemTypes for a section. A music video library holds MusicVideo items, so it is asked
  // for those and for Movie (a few libraries file their clips as Movie). null: do not ask.
  function itemTypes(section) {
    if (section === 'show') return 'Series';
    if (section === 'musicvideo') return 'Movie,MusicVideo';
    if (section === 'movie') return 'Movie';
    return null;
  }

  // False for a row whose Type is not among the types that were asked for. A row with no Type
  // is kept: every Jellyfin and Emby answer carries one, and a test double may not.
  function hasAskedType(item, includeItemTypes) {
    const type = item && item.Type;
    if (type == null || type === '') return true;
    return String(includeItemTypes || '').toLowerCase().split(',').includes(String(type).toLowerCase());
  }

  const api = {
    isMp4Family, staticStreamUrl, withApiKey, newPlaySessionId, fallbackHlsUrl,
    isMediaBrowser, userViewsPath, serverStreamOnlyFields, serverKindFromPublicInfo,
    quickConnectInitiateRetriesWithGet, quickConnectInitiate,
    subtitleProfiles, isTextSubtitle, forcedSubtitleToBurn, NO_SUBTITLE_STREAM,
    embyDoviProfile,
    sectionType, itemTypes, hasAskedType,
  };

  global.NostalgexJellyfinUrls = api;
  if (typeof module !== 'undefined' && typeof module.exports !== 'undefined') {
    module.exports = api;
  }
})(typeof window !== 'undefined' ? window : globalThis);
