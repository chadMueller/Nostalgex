// Library selection for the web tuner: which of a server's libraries the viewer has switched OFF (or, for a library
// the user hides on Jellyfin, ON). The rules are scripts/nostalgex-library-picker.js, pinned by
// scripts/library-picker-golden.json; this file is where they meet the browser's storage.
//
// PARITY with tvOS
//   Nostalgex/Nostalgex/Services/LibrarySelectionStore.swift   LibrarySectionRef, LibrarySectionSelectionStore
//   Nostalgex/Nostalgex/App/AppState+Auth.swift                isLibrarySectionDeselected, excludedSectionKeys, includedHiddenSectionKeys
//   Nostalgex/Nostalgex/App/Plex90App.swift                    LibrarySelectionView (CHOOSE YOUR LIBRARIES)
//
// Opt OUT, not in: nothing stored (or a library never seen before) is ON, so a viewer who never meets the
// screen, a new library on the server, and an existing install all keep a full guide. The one exception is a
// Jellyfin library the user hides from the home screen: it is listed, marked, and OFF until the viewer switches it on
// (the Apple TV's rule; there used to be one switch for all of them here).
//
// The key is `<serverId>::<sectionKey>`, the tvOS key, stored as two lists:
//   nostalgex_deselected_library_sections        the libraries switched OFF (every library but a hidden one)
//   nostalgex_included_hidden_library_sections   the hidden Jellyfin libraries switched ON
// The server id is the Plex machineIdentifier (the server's name when plex.tv gave none), or the Jellyfin/Emby
// server's address; the section key is Plex's section key or the Jellyfin/Emby view Id. Both are the server's own
// ids, not names, so renaming a library on the server does not turn it back on, and a rescan leaves the choice
// alone. A saved id for a server that did not answer, or a library the server no longer lists, is never dropped.
//
// The scan reads this itself (the state is read from storage on every call), so the two scan loops need no state
// passed in, and a page or a test with no storage skips nothing.
//
// UPGRADE. The one switch INCLUDE LIBRARIES HIDDEN ON JELLYFIN (nostalgex_include_hidden_libraries) is gone. When it
// was on, the first time the hidden libraries are known each one the viewer had not turned off is put in the
// included list, so the same libraries stay on; then the old value is removed. See carryOverHiddenSwitch.
//
// Needs scripts/nostalgex-library-picker.js loaded first.
// USAGE: window.NostalgexLibrarySelection (browser), or import this file in node and read globalThis.

(function (global) {
  'use strict';

  const STORAGE_KEY = 'nostalgex_deselected_library_sections';
  const INCLUDED_HIDDEN_KEY = 'nostalgex_included_hidden_library_sections';
  // The one switch this replaces. Read once, for the upgrade, then removed.
  const LEGACY_HIDDEN_SWITCH_KEY = 'nostalgex_include_hidden_libraries';

  function picker() { return global.NostalgexLibraryPicker; }
  function sectionId(serverId, sectionKey) { return `${serverId}::${sectionKey}`; }

  function storage() {
    try { return global.localStorage || null; } catch (e) { return null; }
  }

  function loadList(key) {
    const s = storage();
    if (!s) return new Set();
    try {
      const raw = JSON.parse(s.getItem(key) || '[]');
      return new Set(Array.isArray(raw) ? raw.filter(x => typeof x === 'string') : []);
    } catch (e) { return new Set(); }
  }
  function saveList(key, set) {
    const s = storage();
    if (!s) return false;
    try { s.setItem(key, JSON.stringify([...set])); return true; } catch (e) { return false; }
  }

  /** The saved OFF set, as a Set of ids. Empty when nothing is saved or the saved value is not a list. */
  function load() { return loadList(STORAGE_KEY); }
  /** Saves the set. Returns whether it saved (a full or blocked storage says no). */
  function save(off) { return saveList(STORAGE_KEY, off); }
  /** The hidden Jellyfin libraries the viewer switched ON. */
  function loadIncludedHidden() { return loadList(INCLUDED_HIDDEN_KEY); }
  function saveIncludedHidden(set) { return saveList(INCLUDED_HIDDEN_KEY, set); }

  /** Both saved lists, as the rules read them. */
  function state() { return { off: load(), includedHidden: loadIncludedHidden() }; }

  function isOff(serverId, sectionKey) { return load().has(sectionId(serverId, sectionKey)); }

  /** Sets one library ON or OFF in storage (a library that is not hidden). Returns whether it saved. */
  function setOff(serverId, sectionKey, off) {
    const set = load();
    if (off) set.add(sectionId(serverId, sectionKey)); else set.delete(sectionId(serverId, sectionKey));
    return save(set);
  }

  /** Whether a listed library is on now, hidden or not. */
  function sectionOn(row) { return picker().isOn(row, state()); }

  /** Sets one listed library on or off, in the list it belongs to. Returns whether it saved. */
  function setSectionOn(row, on) {
    const next = picker().setOn(row, on, state());
    return row.hidden ? saveIncludedHidden(next.includedHidden) : save(next.off);
  }

  /** The Plex server's id: its machineIdentifier, or its name for a legacy saved server without one. */
  function plexServerId(server) { return String((server && (server.machineIdentifier || server.name)) || 'plex'); }

  /** A Jellyfin or Emby server's id: its address, lower case, no trailing slash. */
  function mediaBrowserServerId(url) { return String(url || '').trim().toLowerCase().replace(/\/+$/, ''); }

  /** Short label for a library's kind, the tvOS typeLabel. */
  function typeLabel(type, title) { return picker().typeLabel(type, title); }

  /** The line under a library's name: its kind, the server when more than one is in play, and the hidden mark. */
  function subtitle(section, multiServer) { return picker().subtitle(section, multiServer); }

  /** Carries the old single switch over (see UPGRADE above). `rows` are the Jellyfin libraries as listed, `hiddenKnown` is whether the includeHidden list was answered. */
  function carryOverHiddenSwitch(rows, hiddenKnown) {
    const s = storage();
    if (!s) return;
    let raw = null;
    try { raw = s.getItem(LEGACY_HIDDEN_SWITCH_KEY); } catch (e) { return; }
    if (raw === null || raw === undefined) return;
    const st = state();
    const r = picker().carryOverHiddenSwitch(raw === '1', hiddenKnown, rows, st);
    if (!r.done) return;
    // Saved first: if storage refuses, the old value stays and the next listing tries again.
    if (r.includedHidden.size !== st.includedHidden.size && !saveIncludedHidden(r.includedHidden)) return;
    try { s.removeItem(LEGACY_HIDDEN_SWITCH_KEY); } catch (e) { /* stays, and the carry over is a no-op the next time */ }
  }

  /**
   * One Jellyfin or Emby server's views, from the plain answer (`shown`, an Items array) and the includeHidden
   * answer (`all`, an Items array, or null when it was not asked or failed). Returns { views, rows }: the raw views
   * that hold videos with `hidden` set, and the same as listed rows. Notes the listing for Settings and carries the
   * old hidden switch over.
   */
  function mediaBrowserViews(backend, serverUrl, serverName, shown, all) {
    const P = picker();
    const sectionType = global.NostalgexJellyfinUrls.sectionType;
    const sid = mediaBrowserServerId(serverUrl);
    const views = P.mediaBrowserViews(shown, all, sectionType);
    const rows = views.map(v => P.viewRow(sid, serverName, v, sectionType));
    if (backend === 'jellyfin') carryOverHiddenSwitch(rows, Array.isArray(all));
    noteListing(sid, rows);
    return { views, rows };
  }

  // What the last scan of each server saw: every library it listed, ON or OFF. Settings draws its rows from
  // this, so opening it (or turning a library off) costs the server no extra request. The list is kept in
  // storage too, so a visit that opens from the saved library has rows before any scan. It is only a list of
  // names; which libraries are ON lives in the two sets above, and the next scan replaces the list.
  // Versioned: the first version (a bare list) had no `hidden` and could hold Music libraries, so it is not read.
  const LISTING_KEY = 'nostalgex_library_listing';
  const LISTING_VERSION = 2;
  const LISTED_TYPES = new Set(['movie', 'show', 'musicvideo']);
  const listings = new Map();
  function persistListing() {
    const s = storage();
    if (!s) return;
    try { s.setItem(LISTING_KEY, JSON.stringify({ v: LISTING_VERSION, rows: [...listings.values()].flat() })); } catch (e) { /* full or blocked: rows come from the next scan */ }
  }
  /** The scan hands over the libraries one server listed: [{serverId, serverName, key, title, type, hidden}]. */
  function noteListing(serverId, sections) { listings.set(serverId, sections.slice()); persistListing(); }
  /** Every library the scans of this visit saw; with none yet, the list the last visit saved. */
  function listed() {
    if (listings.size) return [...listings.values()].flat();
    const s = storage();
    if (!s) return [];
    try {
      const raw = JSON.parse(s.getItem(LISTING_KEY) || 'null');
      if (!raw || raw.v !== LISTING_VERSION || !Array.isArray(raw.rows)) return [];
      return raw.rows.filter(x => x && typeof x.key === 'string' && typeof x.serverId === 'string' && LISTED_TYPES.has(x.type))
        .map(x => ({ ...x, hidden: x.hidden === true }));
    } catch (e) { return []; }
  }
  function forgetListings() { listings.clear(); const s = storage(); try { if (s) s.removeItem(LISTING_KEY); } catch (e) {} }

  global.NostalgexLibrarySelection = {
    STORAGE_KEY, INCLUDED_HIDDEN_KEY, LEGACY_HIDDEN_SWITCH_KEY, sectionId, load, save, loadIncludedHidden, saveIncludedHidden, state,
    isOff, setOff, sectionOn, setSectionOn, plexServerId, mediaBrowserServerId, typeLabel, subtitle,
    carryOverHiddenSwitch, mediaBrowserViews, noteListing, listed, forgetListings,
  };
})(typeof globalThis !== 'undefined' ? globalThis : window);
