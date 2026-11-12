// A channel's pool, filtered in slices that give the page back between them (GitHub #294).
//
// The launch-time refilter ran the shared channel filter over every title for every rules channel in one
// synchronous pass: 5 s with all 14 bundles on at 10,700 titles, longer on a TV browser, and the page did not
// answer a key or a tap for that long. This runs the SAME filter over the SAME titles, a block at a time, and
// hands the page back whenever a slice (12 ms) is used up, so no single task is long.
//
// What it does not do: change which title lands on which channel. filterPool is per title (a title passes or
// not by the channel's rules and its own fields; nothing about the other titles is read), so filtering a block
// and joining the blocks in order returns exactly the rows filterPool returns for the whole array, in the same
// order. The one input that could differ between blocks is the clock (`nowSec`, read by time-sensitive rules),
// so it is fixed once by the caller and passed to every block. scripts/sliced-filter-smoke.mjs proves this on
// every channel in channels.json, with a yield after every block.
//
// Pure apart from the timer: the caller passes the filter module (`CF`), so this file needs no DOM, no
// storage and no copy of the rules. It does not touch the channel-filter module that the Apple TV mirrors.
//
// USAGE (browser: plain <script src="scripts/nostalgex-sliced-filter.js">, node: import it, then globalThis):
//   const SF = globalThis.NostalgexSlicedFilter;
//   const slicer = SF.makeSlicer({ isCancelled: () => stale });           // one per pass, shared by its channels
//   const rows = await SF.filterPool(CF, items, channel, opts, slicer);   // the rows, or null if cancelled
//   if (slicer.tired() && await slicer.rest()) return;                    // between channels
(function (global) {
  'use strict';

  /**
   * Gives the page back and comes back soon, by a message to itself, else a timeout. Not scheduler.yield(): its
   * continuation runs ahead of timers, so with it a 5 s pass answered the remote and drew frames but ran no timer
   * at all until it was done (measured: 0 timer beats in 22 s), and a player's retries and the guide's own clock
   * are timers. A message waits its turn among them.
   */
  function defaultYield() {
    if (typeof MessageChannel !== 'undefined') {
      return new Promise((resolve) => {
        const channel = new MessageChannel();
        channel.port1.onmessage = () => { channel.port1.close(); resolve(); };
        channel.port2.postMessage(0);
      });
    }
    return new Promise((resolve) => setTimeout(resolve, 0));
  }

  /**
   * One pass's time budget. `tired()` is true once a slice is used up; `rest()` gives the page back, starts the
   * next slice and returns true when the pass should stop (a newer library, a sign-out, a newer pass).
   * @param {object} [opts]
   * @param {number} [opts.sliceMs]     how long to work before giving the page back (default 12; 0 gives it back at every check)
   * @param {() => number} [opts.now]
   * @param {() => Promise<void>} [opts.yieldFn]
   * @param {() => boolean} [opts.isCancelled]   asked after each give-back
   */
  function makeSlicer(opts = {}) {
    const { sliceMs = 12, now = () => performance.now(), yieldFn = defaultYield, isCancelled = () => false } = opts;
    let sliceStart = now();
    const slicer = {
      yields: 0,
      tired: () => now() - sliceStart >= sliceMs,
      async rest() {
        slicer.yields += 1;
        await yieldFn();
        sliceStart = now();
        return !!isCancelled();
      },
    };
    return slicer;
  }

  /**
   * CF.filterPool(items, channel, opts).items, a block of titles at a time.
   * @param {{filterPool: Function}} CF   the shared channel filter (NostalgexChannelFilter)
   * @param {object[]} items
   * @param {object} channel               { id, rules, category }
   * @param {object} opts                  what filterPool is given; set `nowSec` so every block reads one clock
   * @param {ReturnType<typeof makeSlicer>} slicer
   * @param {number} [block]               titles per call (default 128, well under a millisecond each on a PC)
   * @returns {Promise<object[] | null>}   the rows, in the order of `items`; null when the pass was cancelled
   */
  async function filterPool(CF, items, channel, opts, slicer, block = 128) {
    const nowSec = opts && opts.nowSec != null ? opts.nowSec : Math.floor(Date.now() / 1000);
    const blockOpts = { ...opts, nowSec };
    const out = [];
    for (let i = 0; i < items.length; i += block) {
      const rows = CF.filterPool(items.slice(i, i + block), channel, blockOpts).items;
      for (let j = 0; j < rows.length; j++) out.push(rows[j]);
      if (slicer.tired() && await slicer.rest()) return null;
    }
    return out;
  }

  const api = { defaultYield, makeSlicer, filterPool };
  global.NostalgexSlicedFilter = api;
  if (typeof module !== 'undefined' && typeof module.exports !== 'undefined') module.exports = api;
})(typeof window !== 'undefined' ? window : globalThis);
