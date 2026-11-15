// The Plex direct play decision reads the file's codecs, not the container alone (GitHub #326).
// PARITY: the Jellyfin and Emby path in plex-tuner.html (a codec list); Android decides from what the TV decodes (#197); the Apple TV
// per decoder (PlaybackDecision in AppState+Playback.swift).
//
// A browser plays an MP4 only if it decodes what is inside it: an MP4 holding HEVC plays in Safari and not in Chrome, and one holding
// AC-3 or DTS audio often plays silent or not at all. Going by the container alone tried direct play first and recovered after the
// failure; with the codecs known this goes to the server's stream straight away when the browser cannot decode them.
//
// `codecsOK(item, probe)`: true when the codecs the item carries are ones a browser plays, false when one of them is not, and `null` when
// the item carries none (a library saved before codecs were kept): the caller keeps what it did before, the container alone.
// `probe(name)` asks the browser about a codec that only some browsers decode: 'hevc', 'ac3', 'eac3'; with none, those read as unplayable.
(function (global) {
  'use strict';

  // Decoded by every browser the tuner runs in (or close enough that the fallback handles the exception).
  const VIDEO_OK = new Set(['h264', 'avc', 'avc1', 'vp8', 'vp9', 'av1']);
  const AUDIO_OK = new Set(['aac', 'mp3', 'opus', 'vorbis', 'flac']);
  const VIDEO_ASK = { hevc: 'hevc', h265: 'hevc' };
  const AUDIO_ASK = { ac3: 'ac3', eac3: 'eac3', 'e-ac3': 'eac3' };

  function videoPlays(codec, probe) {
    const c = String(codec || '').toLowerCase();
    if (!c) return null;
    if (VIDEO_OK.has(c)) return true;
    if (VIDEO_ASK[c]) return !!(probe && probe(VIDEO_ASK[c]));
    return false;
  }
  function audioPlays(codec, probe) {
    const c = String(codec || '').toLowerCase();
    if (!c) return null;
    if (AUDIO_OK.has(c)) return true;
    if (AUDIO_ASK[c]) return !!(probe && probe(AUDIO_ASK[c]));
    return false;
  }

  function codecsOK(item, probe) {
    const v = videoPlays(item && item.videoCodec, probe);
    const a = audioPlays(item && item.audioCodec, probe);
    if (v === false || a === false) return false;
    if (v === null && a === null) return null;
    return true;
  }

  /** A browser's answer for a codec only some decode, from `video.canPlayType`. */
  function browserProbe(createVideo) {
    const cache = {};
    const types = {
      hevc: 'video/mp4; codecs="hvc1.1.6.L93.B0"',
      ac3: 'video/mp4; codecs="ac-3"',
      eac3: 'video/mp4; codecs="ec-3"',
    };
    return (name) => {
      if (name in cache) return cache[name];
      let ok = false;
      try { ok = createVideo().canPlayType(types[name]) !== ''; } catch (e) { ok = false; }
      cache[name] = ok;
      return ok;
    };
  }

  const api = { codecsOK, videoPlays, audioPlays, browserProbe };
  global.NostalgexDirectPlay = api;
  if (typeof module !== 'undefined' && typeof module.exports !== 'undefined') module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : window);
