// Which servers and libraries Nostalgex lists, starts on and reads. The rules, with no storage and no page in them.
//
// ONE RULE SET, PINNED BY scripts/library-picker-golden.json (read by scripts/nostalgex-library-picker-smoke.mjs,
// `npm run test:library-picker`). The Apple TV, the Roku and Android are to match that file. N-016 option A.
//
// PARITY with tvOS (the reference)
//   Nostalgex/Nostalgex/Services/LibrarySelectionStore.swift   LibrarySectionRef (id, subtitle, typeLabel, hiddenMark)
//   Nostalgex/Nostalgex/Services/JellyfinAPIService.swift      loadSections (plain list + includeHidden list), videoSections
//   Nostalgex/Nostalgex/App/AppState+Auth.swift                isLibrarySectionDeselected, librarySectionStartsOn, toggleLibrarySection
//   Nostalgex/Nostalgex/App/Plex90App.swift                    the server picker's default (owned servers, all when none is owned)
//
// THE RULES
//  1. Plex lists, and reads, the movie and show library types only. A Music (artist) or Photo library is never
//     listed and never asked for items: every row of one was dropped for having no runtime. A music video library
//     is not a type of its own in Plex ("Other Videos" is type movie), so it is a movie or show library and stays
//     listed and read; it is still found as music videos by its NAME (musicVideoName).
//  2. Jellyfin and Emby keep the non-video exclusion list (NostalgexJellyfinUrls.sectionType): Playlists, Music,
//     Collections, Books, Photos, Home Videos, Live TV, Trailers and Folders are never listed or read.
//  3. Every library starts ON. The one exception is rule 5.
//  4. The viewer's own Plex servers start on; with none of their own (every server is shared with them), all start on.
//  5. A Jellyfin library the user hides from the home screen is listed like any other, one row each, marked
//     HIDDEN ON JELLYFIN, and starts OFF. It is on only while the viewer has switched that library on. There is no
//     single switch for all of them. Found by asking /UserViews twice: the plain list, and the list with
//     includeHidden=true; a library only in the second is hidden. If the second ask fails, the plain list stands and
//     nothing is hidden. A library that is in the first and not the second is kept (the union, the second's order).
//     Emby has no includeHidden and no hidden libraries.
//  6. A library's key is `<serverId>::<sectionKey>` (the server's own ids, never names).
//  7. Within a sign-in, a saved choice is kept for a server that did not answer, and for a library the server no
//     longer lists. A choice only ever changes the one library the viewer touched.
//  8. The picker (CHOOSE YOUR LIBRARIES) is offered at a sign-in only when there is something to choose: more than one
//     library across the chosen servers, or a hidden Jellyfin library (which starts off, so without the screen nothing
//     would offer it). With a single library that is not hidden the scan just runs.
//  9. Every sign-in starts again: both saved lists are cleared (and the old single hidden switch, where there was
//     one), so every library is on and every hidden one off, whatever an earlier sign-in chose. A choice made in
//     Settings afterwards lasts until the next sign-in.
//
// WHAT IS SAVED (the Apple TV's two sets, under the same key names)
//   nostalgex_deselected_library_sections        ids the viewer switched OFF. Every library but a hidden one reads this.
//   nostalgex_included_hidden_library_sections   ids of hidden libraries the viewer switched ON. A hidden library reads only this.
//
// A `row` is { serverId, serverName, key, title, type, hidden }. `type` is 'movie', 'show' or 'musicvideo'.
// A `state` is { off: Set|Array of ids, includedHidden: Set|Array of ids }.
//
// USAGE: window.NostalgexLibraryPicker (browser), or import this file in node and read globalThis.

(function (global) {
  'use strict';

  const HIDDEN_MARK = 'HIDDEN ON JELLYFIN';
  const PLEX_LIBRARY_TYPES = ['movie', 'show'];

  function libraryKey(serverId, sectionKey) { return `${serverId}::${sectionKey}`; }
  function rowId(row) { return libraryKey(row.serverId, row.key); }

  /** Rule 1: a Plex library type the app lists and reads. */
  function isPlexVideoType(type) { return PLEX_LIBRARY_TYPES.includes(String(type || '').toLowerCase()); }

  /** A Plex library whose name says it holds music videos (the name rule every platform has today). */
  function musicVideoName(title) { return /music.?video|^music$|^mv[s]?$/i.test(String(title || '').trim()); }

  /** Short label for a library's kind, as the Apple TV's LibrarySectionRef.typeLabel. */
  function typeLabel(type, title) {
    switch (type) {
      case 'show': return 'TV Shows';
      case 'musicvideo': return 'Music Videos';
      case 'artist': return 'Music';
      case 'photo': return 'Photos';
      case 'movie': return musicVideoName(title) ? 'Music Videos' : 'Movies';
      default: return 'Library';
    }
  }

  /** The line under a library's name: its kind, the server when more than one is in play, and the hidden mark. */
  function subtitle(row, multiServer) {
    const base = multiServer ? `${row.serverName} · ${typeLabel(row.type, row.title)}` : typeLabel(row.type, row.title);
    return row.hidden ? `${base} · ${HIDDEN_MARK}` : base;
  }

  function multiServer(rows) { return new Set(rows.map(r => r.serverId)).size > 1; }

  /** Rule 1. One Plex server's /library/sections answer as listed rows. */
  function plexListed(serverId, serverName, sections) {
    return (sections || [])
      .filter(sec => sec && isPlexVideoType(sec.type))
      .map(sec => ({ serverId, serverName, key: String(sec.key), title: sec.title || 'Library', type: String(sec.type).toLowerCase(), hidden: false }));
  }

  /**
   * Rules 2 and 5. The Jellyfin or Emby views of one user, as raw view objects in the order they are listed, each
   * with `hidden`, and the ones that hold no videos left out. `shown` is the plain list, `all` the includeHidden
   * list (null or missing when it was not asked, or failed). `sectionType` is NostalgexJellyfinUrls.sectionType.
   */
  function mediaBrowserViews(shown, all, sectionType) {
    const first = Array.isArray(shown) ? shown : [];
    const second = Array.isArray(all) ? all : null;
    const shownIds = new Set(first.map(v => v.Id));
    const secondIds = new Set((second || []).map(v => v.Id));
    const union = second ? second.concat(first.filter(v => !secondIds.has(v.Id))) : first;
    return union
      .filter(v => sectionType(v.CollectionType) !== 'other')
      .map(v => ({ ...v, hidden: second ? !shownIds.has(v.Id) : false }));
  }

  /** One view from mediaBrowserViews as a listed row. */
  function viewRow(serverId, serverName, view, sectionType) {
    return { serverId, serverName, key: String(view.Id), title: view.Name || 'Library', type: sectionType(view.CollectionType), hidden: view.hidden === true };
  }

  function mediaBrowserListed(serverId, serverName, shown, all, sectionType) {
    return mediaBrowserViews(shown, all, sectionType).map(v => viewRow(serverId, serverName, v, sectionType));
  }

  // Always a copy: a state handed in is never changed.
  /**
   * The second ask of a Jellyfin user's libraries (the one with includeHidden=true). Null when it fails or answers
   * something that is not a list: the plain list then stands and nothing is hidden. Never throws. `fetchFn` is fetch.
   */
  async function fetchHiddenViews(fetchFn, url, init) {
    try {
      const res = await fetchFn(url, init);
      if (!res.ok) return null;
      const data = await res.json();
      return Array.isArray(data && data.Items) ? data.Items : null;
    } catch (e) { return null; }
  }

  function toSet(x) { return new Set(x instanceof Set ? [...x] : (Array.isArray(x) ? x : [])); }
  function stateOf(state) { return { off: toSet(state && state.off), includedHidden: toSet(state && state.includedHidden) }; }

  /** Rules 3 and 5: whether a library is on before the viewer has chosen anything. */
  function startsOn(row) { return !row.hidden; }

  /** Whether a library is on under a saved state. A hidden one follows the included list only; every other follows the off list. */
  function isOn(row, state) {
    const s = stateOf(state);
    return row.hidden ? s.includedHidden.has(rowId(row)) : !s.off.has(rowId(row));
  }

  /** The rows a scan reads. */
  function readable(rows, state) { return rows.filter(r => isOn(r, state)); }

  /** Rule 7. The state after the viewer switches one library: only its id moves; every other saved id stays, answered or not. */
  function toggled(row, state) {
    const s = stateOf(state);
    const id = rowId(row);
    if (isOn(row, s)) {
      if (row.hidden) s.includedHidden.delete(id); else s.off.add(id);
    } else {
      if (row.hidden) s.includedHidden.add(id); else s.off.delete(id);
    }
    return s;
  }

  /** The state after one library is set on or off (no change when it already is). */
  function setOn(row, on, state) {
    return isOn(row, state) === !!on ? stateOf(state) : toggled(row, state);
  }

  /** Rule 8. Whether the picker is offered at a sign-in, for the libraries listed across the chosen servers. */
  function offersPicker(rows) { return (rows || []).length > 1 || (rows || []).some(r => r.hidden); }

  /** Rule 9. The saved state after a sign-in, whatever it was before. */
  function afterSignIn() { return { off: new Set(), includedHidden: new Set() }; }

  /** Rule 4. The ids of the servers that start on. `servers` is [{ id, owned }]. */
  function defaultServerIds(servers) {
    const list = servers || [];
    const own = list.filter(s => s.owned);
    return (own.length ? own : list).map(s => s.id);
  }

  /**
   * UPGRADE from the one switch (INCLUDE LIBRARIES HIDDEN ON JELLYFIN) to a switch per library. The switch, when it
   * was on, made every hidden library readable except the ones the viewer had turned off one by one. So when it was
   * on, each hidden library that is not in `off` goes into the included list, once. The caller reads the switch,
   * and clears it when `done` is true. `hiddenKnown` is whether the includeHidden list was answered: when it was
   * not, nothing is known about the hidden libraries yet, and the switch is kept for the next time.
   * Returns { includedHidden: Set, done: boolean }.
   */
  function carryOverHiddenSwitch(switchOn, hiddenKnown, rows, state) {
    const s = stateOf(state);
    if (!switchOn) return { includedHidden: s.includedHidden, done: true };
    if (!hiddenKnown) return { includedHidden: s.includedHidden, done: false };
    for (const r of rows) if (r.hidden && !s.off.has(rowId(r))) s.includedHidden.add(rowId(r));
    return { includedHidden: s.includedHidden, done: true };
  }

  global.NostalgexLibraryPicker = {
    HIDDEN_MARK, PLEX_LIBRARY_TYPES, libraryKey, rowId, isPlexVideoType, musicVideoName, typeLabel, subtitle, multiServer,
    plexListed, mediaBrowserViews, fetchHiddenViews, viewRow, mediaBrowserListed, startsOn, isOn, readable, toggled, setOn, defaultServerIds,
    carryOverHiddenSwitch, offersPicker, afterSignIn,
  };
})(typeof globalThis !== 'undefined' ? globalThis : window);
