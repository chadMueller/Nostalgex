// Jellyfin and Emby sign-in for the web tuner: the decisions behind the connect screens.
//
// PARITY with Apple TV (branch signin-redesign, 1.0.28). The spec is the Apple TV app's
// connect flow; this file ports its logic, and scripts/signin-golden.json holds the cases
// both should agree on.
//   Nostalgex/Nostalgex/Services/ServerURLNormalizer.swift   candidates, basePath
//   Nostalgex/Nostalgex/Services/LANServerDiscovery.swift    parse(reply:kind:), dedupe
//   Nostalgex/Nostalgex/Views/SignInFlow.swift               outcome, preferredMethod,
//     offersQuickConnect, check, parsePublicInfo, parseQuickConnectEnabled, parsePublicUsers
//
// WHAT A BROWSER CAN'T DO (measured 2026-10-21).
// 1. No UDP, so no LAN discovery the way Apple TV does it (port 7359 broadcast). The hosted
//    page (https) also cannot fetch any http:// server, localhost included: Chromium
//    blocked localhost:8096, 127.0.0.1:8096 and two LAN servers from nostalgex.app. So on
//    https the flow opens on TYPE AN ADDRESS.
// 2. A tuner page served over plain http (the Docker container) reached all four, and
//    Jellyfin 12.2.0 and Emby 4.10.1.0 answer CORS for every call below. There, FIND MY
//    SERVER asks likely addresses directly (findCandidates): the machine the page came
//    from, localhost and the last address used, on Jellyfin's and Emby's 8096.
// 3. Broadcast discovery from inside the container got no replies on Docker's default
//    bridge network or on host networking under Colima, so the container does not do it.
//
// USAGE (browser: <script src="scripts/nostalgex-signin.js">, then window.NostalgexSignIn;
// node: `import "./nostalgex-signin.js"`, then globalThis.NostalgexSignIn).

(function (global) {
  'use strict';

  /** Jellyfin and Emby both listen here out of the box. */
  const DEFAULT_HTTP_PORT = 8096;
  /** How long FIND MY SERVER listens, as on Apple TV. */
  const FIND_WINDOW_MS = 3000;
  /** The address check: per request and overall (SignInFlow.checkSession). */
  const CHECK_REQUEST_MS = 8000;
  const CHECK_TOTAL_MS = 12000;
  /** Quick Connect polls every 2 s, 150 times: 5 minutes. */
  const QUICK_CONNECT_POLL_MS = 2000;
  const QUICK_CONNECT_MAX_POLLS = 150;

  // ── Addresses ─────────────────────────────────────────────────────────────

  /** Splits a typed address without validating it. Whitespace anywhere is dropped. */
  function splitAddress(raw) {
    let s = String(raw == null ? '' : raw).replace(/\s+/g, '');
    let scheme = null;
    const sep = s.indexOf('://');
    if (sep >= 0) {
      const candidate = s.slice(0, sep);
      if (candidate && /^[A-Za-z0-9+.-]+$/.test(candidate)) {
        scheme = candidate.toLowerCase();
        s = s.slice(sep + 3);
      }
    }
    const authorityEnd = s.search(/[/?#]/);
    let authority = authorityEnd < 0 ? s : s.slice(0, authorityEnd);
    const rest = authorityEnd < 0 ? '' : s.slice(authorityEnd);
    let userInfo = null;
    const at = authority.lastIndexOf('@');
    if (at >= 0) {
      userInfo = authority.slice(0, at);
      authority = authority.slice(at + 1);
    }
    let host = authority;
    let port = null;
    const intOrNull = (t) => (/^\d+$/.test(t) ? Number(t) : null);
    if (authority.startsWith('[') && authority.indexOf(']') >= 0) {
      const close = authority.indexOf(']');
      host = authority.slice(0, close + 1);
      const after = authority.slice(close + 1);
      if (after.startsWith(':')) port = intOrNull(after.slice(1));
    } else if (authority.indexOf(':') >= 0 && authority.indexOf(':') === authority.lastIndexOf(':')) {
      const colon = authority.indexOf(':');
      host = authority.slice(0, colon);
      port = intOrNull(authority.slice(colon + 1));
    } else if (authority.indexOf(':') >= 0) {
      host = `[${authority}]`; // a bare IPv6 literal
    }
    return { scheme, userInfo, host: host.toLowerCase(), port, pathQueryFragment: rest };
  }

  /** Drops query, fragment, any /web UI path and trailing slashes; keeps a proxy path. */
  function basePath(pathQueryFragment) {
    let path = pathQueryFragment || '';
    const cut = path.search(/[?#]/);
    if (cut >= 0) path = path.slice(0, cut);
    const parts = path.split('/').filter(Boolean);
    const web = parts.findIndex((p) => p.toLowerCase() === 'web');
    if (web >= 0) parts.splice(web);
    return parts.length ? '/' + parts.join('/') : '';
  }

  /**
   * Base URLs to try, best guess first. A plain http address with no port and no path
   * tries :8096 first, then the address as typed. `defaultScheme` is what an address
   * with none gets: Apple TV uses http; the hosted page passes https, since it can't
   * reach http at all.
   */
  function addressCandidates(raw, defaultScheme) {
    const parts = splitAddress(raw);
    if (!parts.host) return [];
    const scheme = parts.scheme || defaultScheme || 'http';
    const path = basePath(parts.pathQueryFragment);
    const build = (port) =>
      `${scheme}://${parts.userInfo ? parts.userInfo + '@' : ''}${parts.host}${port != null ? ':' + port : ''}${path}`;
    if (parts.port == null && scheme === 'http' && !path) return [build(DEFAULT_HTTP_PORT), build(null)];
    return [build(parts.port)];
  }

  // ── Discovery ─────────────────────────────────────────────────────────────

  function parseJSON(text) {
    if (text == null) return undefined;
    if (typeof text !== 'string') return text;
    try { return JSON.parse(text); } catch (e) { return undefined; }
  }

  const trimmed = (v) => (typeof v === 'string' ? v.trim() : '');

  /**
   * One discovery reply (the UDP answer on Apple TV and Roku): `Address` and `Id` are
   * required; an empty `Name` becomes the address. The kind is whichever probe was sent.
   */
  function parseDiscoveryReply(reply, kind) {
    const o = parseJSON(reply);
    if (!o || typeof o !== 'object' || Array.isArray(o)) return null;
    if (typeof o.Address !== 'string' || typeof o.Id !== 'string') return null;
    const address = trimmed(o.Address);
    const id = trimmed(o.Id);
    if (!address || !id) return null;
    const name = trimmed(o.Name) || address;
    return { kind, name, address, id };
  }

  /** Keeps the first server seen for each Id, in arrival order. */
  function dedupeServers(servers) {
    const seen = new Set();
    const out = [];
    for (const s of servers || []) {
      if (seen.has(s.id)) continue;
      seen.add(s.id);
      out.push(s);
    }
    return out;
  }

  /** none | single | several, after dedupe: one server goes straight to it. */
  function discoveryOutcome(servers) {
    const unique = dedupeServers(servers);
    if (unique.length === 0) return { type: 'none', servers: [] };
    if (unique.length === 1) return { type: 'single', servers: unique };
    return { type: 'several', servers: unique };
  }

  /**
   * Where FIND MY SERVER looks from a browser, best first: the last address used, then
   * the machine the tuner page itself came from (a NAS running both), then localhost.
   * Only an http page can look at all; an https page gets nothing.
   */
  function findCandidates(opts) {
    const { pageProtocol, pageHostname, savedAddress } = opts || {};
    if (pageProtocol !== 'http:') return [];
    const out = [];
    const add = (url) => { if (url && !out.includes(url)) out.push(url); };
    if (savedAddress) add(addressCandidates(savedAddress, 'http')[0]);
    const host = String(pageHostname || '').toLowerCase();
    if (host && host !== 'localhost' && host !== '127.0.0.1' && host !== '[::1]') {
      add(`http://${host.includes(':') && !host.startsWith('[') ? `[${host}]` : host}:${DEFAULT_HTTP_PORT}`);
    }
    add(`http://localhost:${DEFAULT_HTTP_PORT}`);
    return out;
  }

  // ── What the server says about itself ─────────────────────────────────────

  /**
   * /System/Info/Public. Jellyfin names itself in ProductName; Emby 4.x leaves it out.
   * A page without an Id (a router, a web UI) is not a server.
   */
  function parsePublicInfo(body) {
    const o = parseJSON(body);
    if (!o || typeof o !== 'object' || Array.isArray(o)) return null;
    const id = trimmed(o.Id);
    if (!id) return null;
    const kind = String(o.ProductName || '').toLowerCase().includes('jellyfin') ? 'jellyfin' : 'emby';
    const name = trimmed(o.ServerName) || (kind === 'jellyfin' ? 'Jellyfin' : 'Emby');
    return { id, name, kind };
  }

  /** /QuickConnect/Enabled answers a bare true or false; anything else is "can't say" (null). */
  function parseQuickConnectEnabled(body, status) {
    if (!(status >= 200 && status <= 299)) return null;
    const text = String(body == null ? '' : body).trim().toLowerCase();
    if (text === 'true') return true;
    if (text === 'false') return false;
    return null;
  }

  /** /Users/Public: the users a server shows on its own login screen. */
  function parsePublicUsers(body) {
    const list = parseJSON(body);
    if (!Array.isArray(list)) return [];
    const out = [];
    for (const u of list) {
      if (!u || typeof u !== 'object') continue;
      const id = typeof u.Id === 'string' ? u.Id : '';
      const name = trimmed(u.Name);
      if (!id || !name) continue;
      out.push({ id, name, hasPassword: typeof u.HasPassword === 'boolean' ? u.HasPassword : true });
    }
    return out;
  }

  /** Quick Connect first on a Jellyfin that says it is on. Emby has none. */
  function preferredMethod(kind, quickConnectEnabled) {
    return kind === 'jellyfin' && quickConnectEnabled === true ? 'quickConnect' : 'password';
  }

  /** The password screen offers Quick Connect unless the server said it is off. */
  function offersQuickConnect(kind, quickConnectEnabled) {
    return kind === 'jellyfin' && quickConnectEnabled !== false;
  }

  // ── The address check ─────────────────────────────────────────────────────

  /** A failed check: code is notAServer | network | timeout. */
  function CheckError(code, url) {
    const e = new Error(code);
    e.code = code;
    e.url = url || '';
    return e;
  }

  async function timedFetch(fetchImpl, url, ms, init) {
    const controller = typeof AbortController === 'function' ? new AbortController() : null;
    const timer = controller ? setTimeout(() => controller.abort(), ms) : null;
    try {
      const res = await fetchImpl(url, { ...(init || {}), headers: { Accept: 'application/json', ...((init && init.headers) || {}) },
        signal: controller ? controller.signal : undefined });
      const body = await res.text();
      return { status: res.status, body };
    } catch (e) {
      if (e && (e.name === 'AbortError' || e.name === 'TimeoutError')) throw CheckError('timeout', url);
      throw CheckError('network', url);
    } finally {
      if (timer) clearTimeout(timer);
    }
  }

  /**
   * Asks an address who it is before anyone types: Info/Public on each candidate (moving
   * on when the first is clearly the wrong place), then Quick Connect on Jellyfin, then
   * the public users. Resolves to { kind, url, name, id, quickConnectEnabled, users };
   * rejects with a CheckError. `opts.fetch` stands in for window.fetch in tests.
   */
  async function checkServer(address, opts) {
    const o = opts || {};
    const fetchImpl = o.fetch || global.fetch.bind(global);
    const requestMs = o.requestMs || CHECK_REQUEST_MS;
    const started = Date.now();
    const candidates = addressCandidates(address, o.defaultScheme);
    if (!candidates.length) throw CheckError('notAServer', '');
    let info = null;
    let base = candidates[0];
    for (let i = 0; i < candidates.length; i++) {
      const last = i === candidates.length - 1;
      let answer;
      try {
        answer = await timedFetch(fetchImpl, candidates[i] + '/System/Info/Public', requestMs);
      } catch (e) {
        // A refused or unreachable address (a browser can't tell them apart) moves on; a
        // timeout fails once, not twice.
        if (e.code === 'network' && !last) continue;
        throw e;
      }
      const parsed = answer.status >= 200 && answer.status <= 299 ? parsePublicInfo(answer.body) : null;
      if (parsed) { info = parsed; base = candidates[i]; break; }
      if (last) throw CheckError('notAServer', candidates[i]);
    }
    if (!info) throw CheckError('notAServer', base);
    const remaining = () => Math.max(1000, Math.min(requestMs, (o.totalMs || CHECK_TOTAL_MS) - (Date.now() - started)));

    let quickConnectEnabled = null;
    if (info.kind === 'jellyfin') {
      try {
        const qc = await timedFetch(fetchImpl, base + '/QuickConnect/Enabled', remaining());
        quickConnectEnabled = parseQuickConnectEnabled(qc.body, qc.status);
      } catch (e) { quickConnectEnabled = null; }
    }
    let users = [];
    try {
      const u = await timedFetch(fetchImpl, base + '/Users/Public', remaining());
      if (u.status >= 200 && u.status <= 299) users = parsePublicUsers(u.body);
    } catch (e) { users = []; }
    return { kind: info.kind, url: base, name: info.name, id: info.id, quickConnectEnabled, users };
  }

  /**
   * FIND MY SERVER in a browser: Info/Public on every candidate at once, for the window,
   * keeping servers of the kind being looked for. Same outcome rules as discovery.
   */
  async function findServers(kind, candidates, opts) {
    const o = opts || {};
    const fetchImpl = o.fetch || global.fetch.bind(global);
    const windowMs = o.windowMs || FIND_WINDOW_MS;
    const answers = await Promise.all((candidates || []).map(async (url) => {
      try {
        const r = await timedFetch(fetchImpl, url + '/System/Info/Public', windowMs);
        const info = r.status >= 200 && r.status <= 299 ? parsePublicInfo(r.body) : null;
        return info && info.kind === kind ? { kind, name: info.name || url, address: url, id: info.id } : null;
      } catch (e) { return null; }
    }));
    return discoveryOutcome(answers.filter(Boolean));
  }

  // ── Quick Connect ─────────────────────────────────────────────────────────

  /**
   * What Initiate's answer means, after the POST-then-GET of quickConnectInitiate
   * (scripts/nostalgex-jellyfin-urls.js): start | off | notJellyfin | failed.
   */
  function quickConnectInitiateOutcome(status, body) {
    if (status === 401) return 'off';
    if (status === 404) return 'notJellyfin';
    if (status >= 200 && status <= 299) {
      const o = parseJSON(body);
      if (o && typeof o === 'object' && trimmed(o.Code) && trimmed(o.Secret)) return 'start';
      return o === undefined ? 'notJellyfin' : 'failed';
    }
    return 'failed';
  }

  /** One poll's answer: approved | waiting | expired (after the 150th poll). */
  function quickConnectPollOutcome(pollNumber, body) {
    const o = parseJSON(body);
    if (o && o.Authenticated === true) return 'approved';
    return pollNumber >= QUICK_CONNECT_MAX_POLLS ? 'expired' : 'waiting';
  }

  async function readBody(res) {
    if (res && typeof res.text === 'function') return res.text();
    if (res && typeof res.json === 'function') { try { return JSON.stringify(await res.json()); } catch (e) { return ''; } }
    return '';
  }

  /** The MediaBrowser Authorization header every Jellyfin and Emby request carries. */
  function authHeader(deviceId, token) {
    const fields = ['Client="Nostalgex"', 'Device="Browser"', `DeviceId="${deviceId}"`, 'Version="1.0"'];
    if (token) fields.push(`Token="${token}"`);
    return 'MediaBrowser ' + fields.join(', ');
  }

  /**
   * Quick Connect from start to sign-in. Initiate (opts.initiate: the POST-then-GET of
   * NostalgexJellyfinUrls.quickConnectInitiate), show the code (opts.onCode), poll every
   * 2 s up to 150 times with network errors not stopping it, then AuthenticateWithQuickConnect.
   * Returns { cancel, done }; done resolves to { status, result? } where status is
   * approved | expired | off | notJellyfin | failed | network | cancelled.
   */
  function quickConnect(opts) {
    const o = opts || {};
    const fetchImpl = o.fetch || global.fetch.bind(global);
    const sleep = o.sleep || ((ms) => new Promise((r) => setTimeout(r, ms)));
    const headers = { Accept: 'application/json', Authorization: o.authorization };
    let cancelled = false;
    const done = (async () => {
      let init;
      try {
        init = await o.initiate(o.url, headers, fetchImpl);
      } catch (e) { return { status: 'network' }; }
      if (cancelled) return { status: 'cancelled' };
      const initBody = await readBody(init);
      const outcome = quickConnectInitiateOutcome(init.status, initBody);
      if (outcome !== 'start') return { status: outcome };
      const { Code: code, Secret: secret } = JSON.parse(initBody);
      if (o.onCode) o.onCode(code);
      for (let poll = 1; ; poll++) {
        await sleep(o.pollMs || QUICK_CONNECT_POLL_MS);
        if (cancelled) return { status: 'cancelled' };
        let body = '';
        try {
          const res = await fetchImpl(`${o.url}/QuickConnect/Connect?Secret=${encodeURIComponent(secret)}`, { headers });
          body = await readBody(res);
        } catch (e) { body = ''; }
        if (cancelled) return { status: 'cancelled' };
        const state = quickConnectPollOutcome(poll, body);
        if (state === 'expired') return { status: 'expired' };
        if (state !== 'approved') continue;
        try {
          const res = await fetchImpl(`${o.url}/Users/AuthenticateWithQuickConnect`, {
            method: 'POST', headers: { ...headers, 'Content-Type': 'application/json' }, body: JSON.stringify({ Secret: secret }) });
          const result = parseJSON(await readBody(res));
          if (result && result.AccessToken) return { status: 'approved', result };
          return { status: 'failed' };
        } catch (e) { return { status: 'network' }; }
      }
    })();
    return { cancel() { cancelled = true; }, done };
  }

  /**
   * POST /Users/AuthenticateByName with { Username, Pw } (the password may be empty, for a
   * user without one). Resolves to the result with AccessToken; rejects with code
   * incorrect (401 or 403) | notReached (any other answer) | timeout | network.
   */
  async function signInWithPassword(url, username, password, opts) {
    const o = opts || {};
    const fetchImpl = o.fetch || global.fetch.bind(global);
    const controller = typeof AbortController === 'function' ? new AbortController() : null;
    const timer = controller ? setTimeout(() => controller.abort(), o.timeoutMs || 15000) : null;
    let res;
    try {
      res = await fetchImpl(`${url}/Users/AuthenticateByName`, {
        method: 'POST',
        headers: { Accept: 'application/json', 'Content-Type': 'application/json', Authorization: o.authorization },
        body: JSON.stringify({ Username: username, Pw: password || '' }),
        signal: controller ? controller.signal : undefined,
      });
    } catch (e) {
      throw CheckError(e && (e.name === 'AbortError' || e.name === 'TimeoutError') ? 'timeout' : 'network', url);
    } finally {
      if (timer) clearTimeout(timer);
    }
    if (res.status === 401 || res.status === 403) throw CheckError('incorrect', url);
    const result = res.status >= 200 && res.status <= 299 ? parseJSON(await readBody(res)) : null;
    if (!result || !result.AccessToken) throw CheckError('notReached', url);
    return result;
  }

  // ── Copy (verbatim from the Apple TV spec, web wording where it has to differ) ──

  const NAMES = { jellyfin: 'Jellyfin', emby: 'Emby' };
  const COPY = {
    connectTitle: (k) => `CONNECT TO ${NAMES[k].toUpperCase()}`,
    findIntro: (k) => `Nostalgex can look for your ${NAMES[k]} server on this network. Or type its address.`,
    typeIntro: (k) => `Type the address of your ${NAMES[k]} server.`,
    findButton: 'FIND MY SERVER',
    searching: 'SEARCHING...',
    searchAgain: 'SEARCH AGAIN',
    typeAddress: 'TYPE AN ADDRESS',
    pickServer: 'PICK YOUR SERVER',
    // The browser only looks on the machine the tuner runs on and this one, not the whole network.
    noneFound: 'No server answered here. If it runs on another machine, type its address.',
    addressTitle: 'SERVER ADDRESS',
    addressHintHttp: 'The address and port, like 192.168.1.10:8096',
    addressHintHttps: 'An https address, like https://jellyfin.example.com',
    addressPlaceholderHttp: '192.168.1.10:8096',
    addressPlaceholderHttps: 'https://jellyfin.example.com',
    connect: 'CONNECT',
    connecting: (what) => `CONNECTING TO ${String(what).toUpperCase()}`,
    signInTo: 'SIGN IN TO',
    whoIsWatching: "WHO'S WATCHING?",
    someoneElse: 'SOMEONE ELSE',
    username: 'USERNAME',
    password: 'PASSWORD',
    passwordFor: (name) => `PASSWORD FOR ${String(name).toUpperCase()}`,
    pressToType: 'Press to type',
    signIn: 'SIGN IN',
    signingIn: 'SIGNING IN',
    useQuickConnect: 'USE QUICK CONNECT',
    usePassword: 'SIGN IN WITH A PASSWORD',
    back: 'BACK',
    cancel: 'CANCEL',
    // "THIS TV" on Apple TV; a browser may be on a laptop.
    quickConnectTitle: 'APPROVE NOSTALGEX IN JELLYFIN',
    quickConnectSteps: 'On your phone or computer, open Jellyfin, then your profile, then Quick Connect, and enter this code.',
    waitingForApproval: 'WAITING FOR APPROVAL',
    switchedKind: (k) => `That address is a ${NAMES[k]} server, so this is a ${NAMES[k]} sign-in.`,
    notAServer: "That address answered, but it isn't a Jellyfin or Emby server. Check the port (both use 8096 unless you changed it).",
    nothingAnswered: 'Nothing answered at that address. Check the address and port (Jellyfin and Emby default to 8096).',
    timeout: (k) => `The ${NAMES[k]} server took too long to answer. Check the address, or that this device can reach it.`,
    offline: "No network. Check this device's connection.",
    mixedContent: 'Browsers block a plain http:// server from this secure page. Use an https address, the Apple TV app, or run the tuner on your own server (nostalgex.app/self-host).',
    localFromSecure: 'That is an address on your own network, which browsers block from this secure page. Use the Apple TV app, a public https address, or run the tuner on your own server (nostalgex.app/self-host).',
    incorrect: 'Incorrect username or password.',
    enterUsername: (k) => `Enter your ${NAMES[k]} username.`,
    // The spec says "press" for a remote; the web says "click" (SIGNIN-FLOW.md, Plex errors).
    codeExpired: 'The code expired. Click USE QUICK CONNECT for a new one, or sign in with your password.',
    couldNotReach: (k) => `Could not reach the ${NAMES[k]} server. Check the address.`,
    plexCodeExpired: 'The code expired. Click CONNECT TO PLEX for a new one.',
    plexRateLimited: 'plex.tv is rate-limiting sign-in requests from this device. Wait a minute, then click CONNECT TO PLEX again.',
    plexOffline: "No internet connection. Check this device's connection, then click CONNECT TO PLEX again.",
    plexTimeout: 'plex.tv took too long to respond. Check your connection, then click CONNECT TO PLEX again.',
    plexUnreachable: 'Could not reach plex.tv. Check your connection, then click CONNECT TO PLEX again.',
    plexHttp: (status) => `plex.tv returned an error (HTTP ${status}). Try again in a moment.`,
    plexNoServer: "Signed in, but no Plex Media Server was found on your account. Set up Plex on a computer or NAS (with media), make sure it's running, then try again.",
    plexOwnUnreachable: (n) => `Signed in, but couldn't reach your Plex server from this network (${n} found, none reachable). Make sure the server is running and Remote Access is enabled, then try again.`,
    plexFindFailed: "Signed in, but couldn't reach plex.tv to find your servers. Check your connection and try again.",
    goPlexLink: 'GO TO plex.tv/link AND ENTER:',
    scanToConnect: 'SCAN TO CONNECT',
    plexConnecting: 'CONNECTING TO PLEX.TV',
    plexWaiting: 'WAITING FOR AUTHORIZATION',
    plexFinding: 'FINDING YOUR SERVERS',
    quickConnectOff: 'Quick Connect is off on this server. Turn it on in Jellyfin (Dashboard, then General), or sign in with your password.',
    quickConnectNotJellyfin: "That address answered, but it isn't Jellyfin. Check the address and port (Jellyfin uses 8096).",
    quickConnectFailed: 'Could not start Quick Connect. Check the server address, or sign in with your password.',
  };

  /**
   * The amber line for a failed check, by error code and page. A network failure from an
   * https page to an http or private address is the browser's block, not the server.
   */
  function checkErrorMessage(err, kind, page) {
    const p = page || {};
    if (p.online === false) return COPY.offline;
    const code = err && err.code;
    if (code === 'notAServer') return COPY.notAServer;
    if (code === 'timeout') return COPY.timeout(kind);
    const url = (err && err.url) || '';
    if (p.protocol === 'https:') {
      if (/^http:\/\/(?:10\.|127\.|192\.168\.|169\.254\.|172\.(?:1[6-9]|2\d|3[01])\.|\[?::1\]?|localhost)/i.test(url)) return COPY.localFromSecure;
      if (/^http:\/\//i.test(url)) return COPY.mixedContent;
    }
    return COPY.nothingAnswered;
  }

  const api = {
    DEFAULT_HTTP_PORT, FIND_WINDOW_MS, CHECK_REQUEST_MS, CHECK_TOTAL_MS, QUICK_CONNECT_POLL_MS, QUICK_CONNECT_MAX_POLLS,
    splitAddress, basePath, addressCandidates,
    parseDiscoveryReply, dedupeServers, discoveryOutcome, findCandidates, findServers,
    parsePublicInfo, parseQuickConnectEnabled, parsePublicUsers, preferredMethod, offersQuickConnect,
    checkServer, checkErrorMessage,
    quickConnectInitiateOutcome, quickConnectPollOutcome, quickConnect, signInWithPassword, authHeader,
    COPY,
  };
  global.NostalgexSignIn = api;
})(typeof window !== 'undefined' ? window : globalThis);
