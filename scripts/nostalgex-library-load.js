// Phased library load UI + first-load vs incremental channel build helpers (mirrors tvOS).
(function (global) {
  'use strict';

  const INITIAL_LOAD_KEY = 'nostalgex_completed_initial_load';
  const MUSIC_BUNDLE_ID = 'high-rotation';

  // Mirrors AppState+Channels.swift `autoEnableBundlesWithContent`: when a first lineup comes
  // out with no channel, every package that is off and has at least one channel with content
  // is switched on, so a small or narrow library lands on a guide and not a blank screen.
  // Seasonal packages are left out (they are offered, never switched on for anyone) and so
  // are the server-collection packages (`collections-` ids). Returns the ids to switch on,
  // in the bundles' own order. `availableChannelIDs` are the channels whose pool is big
  // enough, which is only known for every package after a full (first-load) build.
  function bundlesToAutoEnable(ctx) {
    const { bundles: bundleList, enabledBundleIDs, availableChannelIDs } = ctx;
    const available = new Set(availableChannelIDs);
    const ids = [];
    for (const bundle of bundleList || []) {
      if (String(bundle.id).startsWith('collections-')) continue;
      if (Array.isArray(bundle.activeMonths)) continue;
      if (enabledBundleIDs.has(bundle.id)) continue;
      if ((bundle.channelIDs || []).some((id) => available.has(id))) ids.push(bundle.id);
    }
    return ids;
  }

  function isMusicBundleEnabled(enabledBundleIDs) {
    return enabledBundleIDs.has(MUSIC_BUNDLE_ID);
  }

  const PHASE_META = {
    preparing: {
      title: 'Lineup',
      hint: 'Loading channel rules and bundles',
      headline: (d) => (d ? d.toUpperCase() : 'PREPARING LINEUP'),
    },
    scanningLibrary: {
      title: 'Library',
      hint: 'Reading movies, shows, and music from your server',
      headline: (d) => (d ? `SCANNING · ${d.toUpperCase()}` : 'SCANNING YOUR LIBRARY'),
    },
    enrichingMusic: {
      title: 'Music',
      hint: 'MusicBrainz for music video channels',
      headline: (d) => (d ? `ENRICHING MUSIC · ${d.toUpperCase()}` : 'ENRICHING MUSIC VIDEOS'),
    },
    buildingChannels: {
      title: 'Channels',
      hint: 'Matching your library to each channel',
      headline: (d) => (d ? d.toUpperCase() : 'BUILDING CHANNELS'),
    },
    finishing: {
      title: 'Ready',
      hint: 'Almost there',
      headline: () => 'TUNING IN',
    },
  };

  const state = {
    phase: 'preparing',
    detail: '',
    visibleSteps: ['preparing', 'scanningLibrary', 'buildingChannels', 'finishing'],
    channelBuildIndex: 0,
    channelBuildTotal: 0,
    scanSectionIndex: 0,
    scanTotalSections: 0,
    scanItemsFound: 0,
    musicEnrichIndex: 0,
    musicEnrichTotal: 0,
  };

  function isFirstLibraryLoad() {
    return localStorage.getItem(INITIAL_LOAD_KEY) !== '1';
  }

  function markInitialLibraryLoadComplete() {
    // Runs inside the library build, so it must not throw: a full localStorage here used to
    // end the load and show "server unreachable" (#152). NostalgexStorage makes room for it
    // by giving up caches. Without that module, or if even that fails, the only cost is that
    // the next load counts as a first load again.
    const S = global.NostalgexStorage;
    if (S) { S.setLocal(INITIAL_LOAD_KEY, '1'); return; }
    try { localStorage.setItem(INITIAL_LOAD_KEY, '1'); } catch (_) { /* next load is a first load again */ }
  }

  function visibleSteps(includesMusic) {
    const steps = ['preparing', 'scanningLibrary'];
    if (includesMusic) steps.push('enrichingMusic');
    steps.push('buildingChannels', 'finishing');
    return steps;
  }

  function refreshStepRail(includesMusic) {
    state.visibleSteps = visibleSteps(includesMusic);
  }

  function headline(phase, detail) {
    const meta = PHASE_META[phase] || PHASE_META.preparing;
    return meta.headline(detail || '');
  }

  function phaseHint(phase) {
    return (PHASE_META[phase] || PHASE_META.preparing).hint;
  }

  // Mirrors AppState+Channels.swift `staticChannelIDsForPoolBuild`: every enabled
  // bundle builds its pools, in any month. A seasonal bundle's `activeMonths` only
  // decides when it is offered (the invite row) and when it leads the guide
  // (scripts/nostalgex-season.js). It used to gate this too, so SCREAM or
  // TIS THE SEASON switched on outside its month came back with zero channels after
  // a reload, while Apple TV (since 1.0.26) kept them.
  function staticChannelIDsForPoolBuild(ctx) {
    const {
      buildAll,
      bundles: bundleList,
      enabledBundleIDs,
      allChannelsUnfiltered,
    } = ctx;

    if (buildAll || !bundleList || bundleList.length === 0) {
      return new Set(allChannelsUnfiltered.map((ch) => ch.id));
    }

    const ids = new Set();
    for (const bundle of bundleList) {
      if (enabledBundleIDs.has(bundle.id)) {
        for (const id of bundle.channelIDs) ids.add(id);
      }
    }
    return ids;
  }

  // The Settings row note for a seasonal bundle outside its season ("SPOTLIGHTED OCT")
  // is NostalgexSeason.seasonalSpotlightLabel in scripts/nostalgex-season.js.

  function progressFraction() {
    switch (state.phase) {
      case 'scanningLibrary':
        if (state.scanTotalSections > 0) {
          return (state.scanSectionIndex + 1) / state.scanTotalSections;
        }
        break;
      case 'enrichingMusic':
        if (state.musicEnrichTotal > 0) {
          return state.musicEnrichIndex / state.musicEnrichTotal;
        }
        break;
      case 'buildingChannels':
        if (state.channelBuildTotal > 0) {
          return state.channelBuildIndex / state.channelBuildTotal;
        }
        break;
      default:
        break;
    }
    return null;
  }

  function progressCaption() {
    switch (state.phase) {
      case 'scanningLibrary':
        if (state.scanTotalSections > 0) {
          return `Section ${state.scanSectionIndex + 1} of ${state.scanTotalSections} · ${state.scanItemsFound} items`;
        }
        break;
      case 'enrichingMusic':
        if (state.musicEnrichTotal > 0) {
          return `Music ${state.musicEnrichIndex}/${state.musicEnrichTotal}`;
        }
        break;
      case 'buildingChannels':
        if (state.channelBuildTotal > 0) {
          return `Channel ${state.channelBuildIndex} of ${state.channelBuildTotal}`;
        }
        break;
      default:
        break;
    }
    return '';
  }

  function renderStepRail(container) {
    if (!container) return;
    container.innerHTML = '';
    const currentIdx = state.visibleSteps.indexOf(state.phase);

    state.visibleSteps.forEach((step, index) => {
      if (index > 0) {
        const conn = document.createElement('div');
        conn.className = 'load-rail-connector';
        if (currentIdx >= 0 && index <= currentIdx) conn.classList.add('done');
        container.appendChild(conn);
      }

      const cell = document.createElement('div');
      cell.className = 'load-rail-step';
      let status = 'upcoming';
      if (currentIdx >= 0) {
        if (index < currentIdx) status = 'complete';
        else if (index === currentIdx) status = 'active';
      }
      cell.classList.add(status);

      const dot = document.createElement('div');
      dot.className = 'load-rail-dot';
      if (status === 'complete') dot.textContent = '✓';
      else if (status === 'active') {
        const inner = document.createElement('span');
        inner.className = 'load-rail-dot-active';
        dot.appendChild(inner);
      }

      const label = document.createElement('div');
      label.className = 'load-rail-label';
      label.textContent = PHASE_META[step].title.toUpperCase();

      cell.appendChild(dot);
      cell.appendChild(label);
      container.appendChild(cell);
    });
  }

  function render() {
    const headlineEl = document.getElementById('loading-library-headline');
    const subEl = document.getElementById('loading-library-sub');
    const railEl = document.getElementById('loading-library-rail');
    const progressWrap = document.getElementById('loading-library-progress-wrap');
    const progressBar = document.getElementById('loading-library-progress');
    const progressCaptionEl = document.getElementById('loading-library-progress-caption');
    const firstHint = document.getElementById('loading-library-first-hint');

    if (firstHint) {
      firstHint.style.display = isFirstLibraryLoad() ? 'block' : 'none';
    }

    if (headlineEl) {
      headlineEl.textContent = headline(state.phase, state.detail);
    }

    if (subEl) {
      if (state.phase === 'buildingChannels' && state.channelBuildTotal > 0) {
        subEl.textContent = '';
        subEl.style.display = 'none';
      } else {
        subEl.style.display = '';
        const caption = progressCaption();
        // Several phases fold the detail into the headline (SCANNING · TV SHOWS
        // · 4362 EPS). Repeating it underneath read as a stutter on a phone, so
        // the second line falls back to what the phase is actually doing.
        const headlineText = headline(state.phase, state.detail);
        const detail = state.detail || '';
        subEl.textContent = (detail && !headlineText.toUpperCase().includes(detail.toUpperCase())
          ? detail
          : phaseHint(state.phase)).toUpperCase();
        // The caption belongs to the progress bar. Printing it here as well put
        // the same "SECTION 2 OF 4" line on screen twice, once above the rail
        // and once below it. Only fall back to it when there is no bar.
        if (caption && progressFraction() == null
            && (state.phase === 'scanningLibrary' || state.phase === 'enrichingMusic')) {
          subEl.textContent = caption.toUpperCase();
        }
      }
    }

    renderStepRail(railEl);

    const fraction = progressFraction();
    if (progressWrap && progressBar) {
      if (fraction != null) {
        progressWrap.style.display = 'flex';
        progressBar.style.width = `${Math.min(100, Math.max(0, fraction * 100))}%`;
        if (progressCaptionEl) progressCaptionEl.textContent = progressCaption().toUpperCase();
      } else {
        progressWrap.style.display = 'none';
      }
    }
  }

  function setPhase(phase, detail = '') {
    state.phase = phase;
    state.detail = detail;
    render();
  }

  async function briefUILBeat() {
    await new Promise((r) => setTimeout(r, 0));
    await new Promise((r) => setTimeout(r, 220));
  }

  async function pulsePhase(phase, detail = '') {
    setPhase(phase, detail);
    await briefUILBeat();
  }

  function show() {
    const el = document.getElementById('loading-library');
    if (el) el.style.display = 'flex';
    // The side guide layout pins .video-area to exactly 50% of the screen, and
    // both it and .video-container clip with overflow:hidden. The build panel
    // lives inside them, so it was confined to half the window and cut off at
    // the top. Nothing is playing and the guide is hidden while the library
    // builds, so give the panel the whole screen for the duration.
    const screen = document.getElementById('player-screen');
    if (screen) screen.classList.add('building');
    render();
  }

  function hide() {
    const el = document.getElementById('loading-library');
    if (el) el.style.display = 'none';
    const screen = document.getElementById('player-screen');
    if (screen) screen.classList.remove('building');
  }

  global.NostalgexLibraryLoad = {
    state,
    isFirstLibraryLoad,
    markInitialLibraryLoadComplete,
    staticChannelIDsForPoolBuild,
    bundlesToAutoEnable,
    refreshStepRail,
    setPhase,
    pulsePhase,
    briefUILBeat,
    show,
    hide,
    render,
    headline,
    isMusicBundleEnabled,
    MUSIC_BUNDLE_ID,
  };
})(typeof globalThis !== 'undefined' ? globalThis : window);
