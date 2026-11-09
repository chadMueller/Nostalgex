// OPEN ON THE LAST CHANNEL (Trello I-017). A setting, on unless the viewer turns it off (it was off by
// default in 1.0.15; Chad's decision of 2026-11-09 made it on, see OPEN_DEFAULT below): the guide opens on
// the channel that was playing when it was last used, instead of the first one.
//
// WHAT IS KEPT. The channel's id and its name, in this browser's storage (the Docker container's
// tuner is the same page, so each browser that opens it keeps its own). Nothing leaves the browser.
// Both are kept because ids and numbers move between releases: a channel is opened only when an
// enabled channel has the same id AND the same name. A channel that was renumbered, renamed,
// dropped from the lineup, or whose package is off is not opened by mistake: the guide opens on
// the first enabled channel, exactly as it does with the setting off.
//
// Shared with nothing yet: the Apple TV builds the same setting first, and this follows its wording
// and rules (docs: nostalgex-internal, Trello I-017). The pure choice lives here so a smoke test
// can hold it down without a page.
//
// USAGE (browser: plain <script src="scripts/nostalgex-last-channel.js">,
// node: `import "./nostalgex-last-channel.js"`, then globalThis):
//
//   const LC = window.NostalgexLastChannel;
//   LC.OPEN_KEY; LC.CHANNEL_KEY;                 // the two storage keys
//   LC.OPEN_DEFAULT;                              // what a browser that never chose gets
//   LC.isOn(storedValue);                         // no value: OPEN_DEFAULT. A stored '1' is on, anything else stored is off
//   LC.serialize(channel);                        // the string to store for a channel, or null
//   LC.parse(storedValue);                        // { id, name } or null
//   LC.channelToOpen(saved, enabledChannels);     // the channel to open on, or null (open the first)

(function (global) {
  'use strict';

  const OPEN_KEY = 'nostalgex_open_last_channel';
  const CHANNEL_KEY = 'nostalgex_last_channel';

  // What a browser that has never stored a choice gets. ON since 1.0.16. The page writes '1' or '0' when the
  // viewer presses the switch and never removes the key, so a stored '0' is a choice and stays off: only a
  // browser with nothing stored takes this default. Anything else that is stored (a value this code did not
  // write) counts as a choice too and reads as off, as it always did.
  const OPEN_DEFAULT = true;

  const isOn = (stored) => (stored == null ? OPEN_DEFAULT : stored === '1');

  // What is stored for a channel. null when it has no id or no name: nothing to match later.
  function serialize(channel) {
    if (!channel || channel.id == null || channel.id === '') return null;
    const name = typeof channel.name === 'string' ? channel.name : '';
    if (!name) return null;
    return JSON.stringify({ id: channel.id, name });
  }

  // The stored value back, or null for anything that is not what serialize() wrote.
  function parse(stored) {
    if (typeof stored !== 'string' || !stored) return null;
    let v;
    try { v = JSON.parse(stored); } catch (e) { return null; }
    if (!v || typeof v !== 'object') return null;
    if (v.id == null || v.id === '' || typeof v.name !== 'string' || !v.name) return null;
    return { id: v.id, name: v.name };
  }

  // The enabled channel the viewer was last on, or null. `saved` is parse()'s answer.
  function channelToOpen(saved, enabledChannels) {
    if (!saved || !Array.isArray(enabledChannels)) return null;
    return enabledChannels.find((c) => c && String(c.id) === String(saved.id) && c.name === saved.name) || null;
  }

  const api = { OPEN_KEY, CHANNEL_KEY, OPEN_DEFAULT, isOn, serialize, parse, channelToOpen };
  global.NostalgexLastChannel = api;
  if (typeof module !== 'undefined' && typeof module.exports !== 'undefined') {
    module.exports = api;
  }
})(typeof window !== 'undefined' ? window : globalThis);
