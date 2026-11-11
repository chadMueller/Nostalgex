// Which audio track a channel starts on, and the rule that a commentary is never it when the file has another.
//
// PARITY with tvOS and Roku
//   Nostalgex/Nostalgex/Services/AudioTrackCommentary.swift          isCommentary, skippingCommentary
//   Nostalgex/Nostalgex/Services/JellyfinPlaybackResolver.swift      preferredAudioIndex (Jellyfin and Emby)
//   Nostalgex/Nostalgex/Services/PlexAPIService.swift                playbackAudioStream(in:) (Plex)
//   Roku: the same rules in issues #236, #245 and #246.
// The vectors are in scripts/audio-pick-golden.json; a Roku or Android port should pass the same file.
//
// A director's or cast commentary is an audio track a channel should never start on when the file has another.
// Servers name it in the track title ("Commentary", "Director's Commentary", "Audio Commentary with ...") and often
// flag it as the default or give it the viewer's language, so a language match alone lands on it (#153).
//
// Streams are plain objects: { index, lang, channels, isDefault, title, displayTitle } (Jellyfin and Emby), or
// { id, selected, title, displayTitle } (Plex). Language comparisons go through NostalgexLanguage.
(function (global) {
  'use strict';

  /** True when any of the titles says "commentary", in any case. */
  function isCommentary() {
    for (let i = 0; i < arguments.length; i += 1) {
      const t = arguments[i];
      if (t != null && String(t).toLowerCase().includes('commentary')) return true;
    }
    return false;
  }

  /** `items` without the commentary ones, unless that would leave nothing: a file whose only audio is a commentary
   *  still plays it. Order is kept. `titlesOf(item)` is the list of titles to read. */
  function skippingCommentary(items, titlesOf) {
    const rest = items.filter((it) => !isCommentary.apply(null, titlesOf(it)));
    return rest.length === 0 ? items : rest;
  }

  const defaultTitles = (s) => [s.title, s.displayTitle, s.rawTitle];

  function languageKey(tag) {
    const L = global.NostalgexLanguage;
    return L ? L.languageKey(tag) : (tag ? String(tag).toLowerCase().slice(0, 2) : null);
  }

  /** The first stream with the most channels (Swift's max(by:) keeps the first of equals). */
  function mostChannels(list) {
    let best = null;
    for (const s of list) if (best === null || (best.channels || 0) < (s.channels || 0)) best = s;
    return best;
  }

  /**
   * The Jellyfin or Emby audio track to pin, or null to leave the server's own choice alone.
   * Nothing to choose between (0 or 1 audio track) is null. A commentary is passed over while another track
   * exists. Then: the viewer's AUDIO LANGUAGE (anything but '__system__'), most channels first; else a track in one of
   * the browser's languages or English, most channels first; else the file's default; else the first.
   * Mirrors JellyfinPlaybackResolver.preferredAudioIndex.
   */
  function preferredAudioStream(streams, opts) {
    const o = opts || {};
    const all = Array.isArray(streams) ? streams : [];
    if (all.length <= 1) return null;
    const audio = skippingCommentary(all, defaultTitles);
    const audioLanguage = o.audioLanguage;
    if (audioLanguage && audioLanguage !== '__system__') {
      const chosen = languageKey(audioLanguage);
      if (chosen) {
        const best = mostChannels(audio.filter((s) => languageKey(s.lang) === chosen));
        if (best) return best;
      }
    }
    const wanted = new Set((o.preferredLanguages || []).map(languageKey).filter(Boolean).concat(['en']));
    const inLanguage = audio.filter((s) => { const k = languageKey(s.lang); return k !== null && wanted.has(k); });
    const best = mostChannels(inLanguage);
    if (best) return best;
    return audio.find((s) => s.isDefault === true) || audio[0] || null;
  }

  /** The Plex audio track the app keeps facts for: the one Plex marks selected, else the first, never a commentary
   *  while another audio track exists. Mirrors PlexAPIService.playbackAudioStream(in:). */
  function plexAudioStream(streams) {
    const audio = Array.isArray(streams) ? streams : [];
    const pool = skippingCommentary(audio, defaultTitles);
    return pool.find((s) => s.selected === 1 || s.selected === true) || pool[0] || null;
  }

  const api = { isCommentary, skippingCommentary, preferredAudioStream, plexAudioStream };
  global.NostalgexAudioPick = api;
  if (typeof module !== 'undefined' && typeof module.exports !== 'undefined') module.exports = api;
})(typeof window !== 'undefined' ? window : globalThis);
