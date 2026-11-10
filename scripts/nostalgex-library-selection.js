// Library selection for the web tuner: which of a server's libraries the viewer has switched OFF.
//
// PARITY with tvOS
//   Nostalgex/Nostalgex/Services/LibrarySelectionStore.swift   LibrarySectionRef, LibrarySectionSelectionStore
//   Nostalgex/Nostalgex/App/AppState+Auth.swift                isLibrarySectionDeselected, excludedSectionKeys
//   Nostalgex/Nostalgex/App/Plex90App.swift                    LibrarySelectionView (CHOOSE YOUR LIBRARIES)
//
// Opt OUT, not in: nothing stored (or a library never seen before) is ON, so a viewer who never meets the
// screen, a new library on the server, and an existing install all keep a full guide.
//
// The key is `<serverId>::<sectionKey>`, the tvOS key, stored as a list under
// `nostalgex_deselected_library_sections`. The server id is the Plex machineIdentifier (the server's name
// when plex.tv gave none), or the Jellyfin/Emby server's address; the section key is Plex's section key or
// the Jellyfin/Emby view Id. Both are the server's own ids, not names, so renaming a library on the server
// does not turn it back on, and a rescan leaves the choice alone.
//
// The scan reads this itself (isOff reads storage on every call), so the two scan loops need no state passed
// in, and a page or a test with no storage skips nothing.
//
// USAGE: window.NostalgexLibrarySelection (browser), or import this file in node and read globalThis.

(function (global) {
  'use strict';

  const STORAGE_KEY = 'nostalgex_deselected_library_sections';

  function sectionId(serverId, sectionKey) { return `${serverId}::${sectionKey}`; }

  function storage() {
    try { return global.localStorage || null; } catch (e) { return null; }
  }

  /** The saved OFF set, as a Set of ids. Empty when nothing is saved or the saved value is not a list. */
  function load() {
    const s = storage();
    if (!s) return new Set();
    try {
      const raw = JSON.parse(s.getItem(STORAGE_KEY) || '[]');
      return new Set(Array.isArray(raw) ? raw.filter(x => typeof x === 'string') : []);
    } catch (e) { return new Set(); }
  }

  /** Saves the set. Returns whether it saved (a full or blocked storage says no). */
  function save(off) {
    const s = storage();
    if (!s) return false;
    try { s.setItem(STORAGE_KEY, JSON.stringify([...off])); return true; } catch (e) { return false; }
  }

  function isOff(serverId, sectionKey) { return load().has(sectionId(serverId, sectionKey)); }

  /** Sets one library ON or OFF in storage. Returns whether it saved. */
  function setOff(serverId, sectionKey, off) {
    const set = load();
    if (off) set.add(sectionId(serverId, sectionKey)); else set.delete(sectionId(serverId, sectionKey));
    return save(set);
  }

  /** The Plex server's id: its machineIdentifier, or its name for a legacy saved server without one. */
  function plexServerId(server) { return String((server && (server.machineIdentifier || server.name)) || 'plex'); }

  /** A Jellyfin or Emby server's id: its address, lower case, no trailing slash. */
  function mediaBrowserServerId(url) { return String(url || '').trim().toLowerCase().replace(/\/+$/, ''); }

  /** Short label for a library's kind, the tvOS typeLabel. */
  function typeLabel(type, title) {
    switch (type) {
      case 'show': return 'TV Shows';
      case 'musicvideo': return 'Music Videos';
      case 'artist': return 'Music';
      case 'movie':
        return /music.?video|^music$|^mv[s]?$/i.test(String(title || '').trim()) ? 'Music Videos' : 'Movies';
      default: return 'Library';
    }
  }

  /** The line under a library's name: its kind, and the server when more than one is in play. */
  function subtitle(section, multiServer) {
    const base = typeLabel(section.type, section.title);
    return multiServer ? `${section.serverName} · ${base}` : base;
  }

  // What the last scan of each server saw: every library it listed, ON or OFF. Settings draws its rows from
  // this, so opening it (or turning a library off) costs the server no extra request. The list is kept in
  // storage too, so a visit that opens from the saved library has rows before any scan. It is only a list of
  // names; which libraries are ON lives in the OFF set above, and the next scan replaces the list.
  const LISTING_KEY = 'nostalgex_library_listing';
  const listings = new Map();
  function persistListing() {
    const s = storage();
    if (!s) return;
    try { s.setItem(LISTING_KEY, JSON.stringify([...listings.values()].flat())); } catch (e) { /* full or blocked: rows come from the next scan */ }
  }
  /** The scan hands over the libraries one server listed: [{serverId, serverName, key, title, type}]. */
  function noteListing(serverId, sections) { listings.set(serverId, sections.slice()); persistListing(); }
  /** Every library the scans of this visit saw; with none yet, the list the last visit saved. */
  function listed() {
    if (listings.size) return [...listings.values()].flat();
    const s = storage();
    if (!s) return [];
    try {
      const raw = JSON.parse(s.getItem(LISTING_KEY) || '[]');
      return Array.isArray(raw) ? raw.filter(x => x && typeof x.key === 'string' && typeof x.serverId === 'string') : [];
    } catch (e) { return []; }
  }
  function forgetListings() { listings.clear(); const s = storage(); try { if (s) s.removeItem(LISTING_KEY); } catch (e) {} }

  global.NostalgexLibrarySelection = {
    STORAGE_KEY, sectionId, load, save, isOff, setOff, plexServerId, mediaBrowserServerId, typeLabel, subtitle,
    noteListing, listed, forgetListings,
  };
})(typeof globalThis !== 'undefined' ? globalThis : window);
