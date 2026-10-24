' Copyright (c) 2026 nostalgex-roku contributors, MIT License.

sub init()
    m.top.functionName = "loadLibrary"
end sub

' The saved guide: the last build's output, reused only while a fresh build
' would give the same thing (same local day, and UTC day, which the pool
' shuffle used to follow, same packages, same servers on,
' same build, NxBuildKey).
' It holds titles and schedules, nothing secret.
function NxGuideCachePath() as String
    return "cachefs:/nostalgex-guide.json"
end function

function NxGuideCacheKey(nowSec as LongInteger, bundles as Object) as String
    return NxBuildKey() + "|" + (nowSec \ 86400).ToStr() + "|" + NxLocalDay(nowSec).dayKey + "|" + FormatJson(bundles) + "|" + NxChoicesKey()
end function

' Which build this is, for the cache keys: the app version and the hash of
' the zip's files that scripts/deploy.sh writes into the manifest
' (`nx_build`). A sideload keeps
' the version, and its channel data and filter may still have changed.
function NxBuildKey() as String
    info = CreateObject("roAppInfo")
    return info.GetVersion() + "+" + info.GetValue("nx_build")
end function

'' The viewer's franchise, collection and server switches, as part of a cache key.
function NxChoicesKey() as String
    return FormatJson(NxFranchiseChoiceLists(NxSavedFranchiseChoices())) + "|" + FormatJson(NxCollectionKeyList(NxSavedCollectionKeys())) + "|" + NxSavedServersOnKey()
end function

' The servers on (source/plex/ServerChoice.brs), as the cache keys hold them.
function NxSavedServersOnKey() as String
    reg = NxPlexRegistry()
    servers = ParseJson(reg.Read("servers"))
    if type(servers) <> "roArray" then return ""
    return NxServersOnKey(servers, NxSavedServerChoices())
end function

' The saved pools: each guide channel's pool as the last build filtered it,
' before the shuffle, with the items they hold. Filtering is most of a build
' (over a minute on a TV), and a pool rarely changes from one day to the
' next, so when the saved guide is a day old these are
' scheduled for today instead, in seconds, and the full build still runs
' behind them. Kept while the build, the month and which packages are in
' season (NxSeasonKey: the guide's lead, and the year the filter reads),
' packages, franchise and collection choices and servers on are the same.
function NxPoolCachePath() as String
    return "cachefs:/nostalgex-pools.json"
end function

function NxPoolCacheKey(season as String, bundles as Object) as String
    return NxBuildKey() + "|" + season + "|" + FormatJson(bundles) + "|" + NxChoicesKey()
end function

' Written in pieces: one FormatJson of every pooled item, on top of the
' library itself, ran a Roku Stick Plus out of memory with 45 channels on
' (EXIT_CHANNEL_MEM_LIMIT_FG, Discussion #8). Each item is copied only for
' as long as it takes to format it, without what only the build reads: the
' filter cache, the enrichment record and the artwork paths. Every episode of
' a show shares one enrichment record in memory but would get its own copy
' in the file.
'
' Besides the guide's pools, every built channel's filter result (built:
' buildGuide's channels, those too small for the guide included), so a
' launch with an unchanged library reuses them (NxSavedFiltered).
sub NxSavePools(ordered as Object, guide as Object, now as Object, built as Object)
    path = NxPoolCachePath()
    WriteAsciiFile(path, "{""key"":" + FormatJson(NxPoolCacheKey(NxSeasonKey(guide.bundles, now), guide.enabledBundles)) + ",""items"":[")
    st = { index: {}, count: 0, parts: [], path: path }
    chans = []
    for each ch in ordered
        saved = {}
        ' Keys come back lowercased from an AA's iteration, so they're compared
        ' that way: `k <> "basePool"` never matched, and every channel's pool
        ' was written out in full a second time (20 MB of a 23 MB file).
        for each k in ch
            lk = LCase(k)
            if lk <> "pool" and lk <> "basepool" and lk <> "filtered" and lk <> "nxmemo" then saved[k] = ch[k]
        end for
        pool = ch.basePool
        if pool = invalid then pool = ch.pool
        saved.poolIdx = NxPoolItemIndexes(pool, st)
        chans.Push(saved)
    end for
    filtered = {}
    for each ch in built
        if ch.filtered <> invalid then filtered[ch.id.ToStr()] = NxPoolItemIndexes(ch.filtered, st)
    end for
    st.parts.Push("],""channels"":" + FormatJson(chans))
    st.parts.Push(",""filtered"":" + FormatJson(filtered))
    st.parts.Push(",""libraryItems"":" + FormatJson(guide.items))
    st.parts.Push(",""bundles"":" + FormatJson(guide.bundles))
    st.parts.Push(",""franchises"":" + FormatJson(guide.franchises))
    st.parts.Push(",""collections"":" + FormatJson(guide.collections))
    st.parts.Push(",""fingerprint"":" + FormatJson(NxToStr(guide.poolsFingerprint)) + "}")
    NxAppendText(path, st.parts)
end sub

' Each item's place in the file's item list, writing the items not yet in it.
function NxPoolItemIndexes(list as Object, st as Object) as Object
    idx = []
    for each it in list
        id = NxToStr(it.ratingKey) + "@" + NxToStr(it.serverIndex)
        n = st.index[id]
        if n = invalid then
            n = st.count
            st.count = st.count + 1
            st.index[id] = n
            copy = {}
            for each k in it
                lk = LCase(k)
                if lk <> "nxfilter" and lk <> "enrichment" and lk <> "thumb" and lk <> "art" then copy[k] = it[k]
            end for
            text = FormatJson(copy)
            if n > 0 then text = "," + text
            st.parts.Push(text)
            if st.parts.Count() >= 500 then NxAppendText(st.path, st.parts)
        end if
        idx.Push(n)
    end for
    return idx
end function

' The last build's filter results, for a launch whose library is the one it
' was built from (every server from its save, nothing new from enrichment):
' { <channel id>: [items] } over this run's items, as buildGuide's reuse.
' A channel whose rules read the clock to the day or finer (PREMIERES'
' addedWithinDays, releasedWithinMonths) is left out, so it's filtered
' again; the rest read only the year, which the key holds. Invalid
' when there is no match for these packages and choices, or an item isn't in
' the library.
function NxSavedFiltered(items as Object, config as Object, now as Object, bundles as Object) as Dynamic
    if not CreateObject("roFileSystem").Exists(NxPoolCachePath()) then return invalid
    saved = ParseJson(NxReadBigFile(NxPoolCachePath()))
    if type(saved) <> "roAssociativeArray" then return invalid
    if saved.key <> NxPoolCacheKey(NxSeasonKey(config.bundles, now), bundles) or type(saved.filtered) <> "roAssociativeArray" or type(saved.items) <> "roArray" then return invalid
    m.savedPoolsKey = saved.key
    m.savedPoolsFingerprint = NxToStr(saved.fingerprint)
    byKey = {}
    for each it in items
        byKey[NxToStr(it.ratingKey) + "@" + NxToStr(it.serverIndex)] = it
    end for
    mapped = []
    for each it in saved.items
        x = byKey[NxToStr(it.ratingKey) + "@" + NxToStr(it.serverIndex)]
        if x = invalid then return invalid
        mapped.Push(x)
    end for
    clocked = {}
    for each def in config.channels
        r = def.rules
        if type(r) = "roAssociativeArray" then
            if NxIsNumber(r.addedWithinDays) or NxIsNumber(r.releasedWithinMonths) then clocked[def.id.ToStr()] = true
        end if
    end for
    reuse = {}
    for each id in saved.filtered
        if not clocked.DoesExist(id) then
            list = []
            for each n in saved.filtered[id]
                list.Push(mapped[n])
            end for
            reuse[id] = list
        end if
    end for
    return reuse
end function

function NxFileKB(path as String) as Integer
    st = CreateObject("roFileSystem").Stat(path)
    if st = invalid or st.size = invalid then return -1
    return st.size \ 1024
end function

' Appends the pieces to the file, UTF-8, and empties the list.
sub NxAppendText(path as String, parts as Object)
    bytes = CreateObject("roByteArray")
    bytes.FromAsciiString(parts.Join(""))
    bytes.AppendFile(path)
    parts.Clear()
end sub

' A file's text, or "". ReadAsciiFile refuses a pools file this big ("file
' is too big", 70 channels on a TV), so the bytes are read and turned into
' text instead.
function NxReadBigFile(path as String) as String
    bytes = CreateObject("roByteArray")
    if not bytes.ReadFile(path) then return ""
    return bytes.ToAsciiString()
end function

' The guide from the saved pools, as { ordered, guide }, or invalid when
' there are none for this key.
' Only today is scheduled: the launch's guide goes up first, and the caller
' schedules tomorrow after.
' The season key comes from the file's own packages: a matching build key
' means the same channels.json.
function NxGuideFromSavedPools(nowSec as LongInteger, bundles as Object) as Dynamic
    if not CreateObject("roFileSystem").Exists(NxPoolCachePath()) then return invalid
    timer = CreateObject("roTimespan")
    text = NxReadBigFile(NxPoolCachePath())
    readMs = timer.TotalMilliseconds()
    timer.Mark()
    saved = ParseJson(text)
    text = ""
    print "library: saved pools read in "; readMs; " ms, parsed in "; timer.TotalMilliseconds(); " ms"
    if type(saved) <> "roAssociativeArray" then return invalid
    if type(saved.bundles) <> "roArray" or type(saved.channels) <> "roArray" or type(saved.items) <> "roArray" then return invalid
    if saved.key <> NxPoolCacheKey(NxSeasonKey(saved.bundles, NxFilterClock(nowSec)), bundles) then return invalid
    ordered = []
    for each ch in saved.channels
        pool = []
        for each n in ch.poolIdx
            pool.Push(saved.items[n])
        end for
        ch.Delete("poolIdx")
        ' Pools air in library order, as the Apple TV's and the web tuner's
        ' (1.0.7) do: the day's order comes from the scheduler alone.
        ch.pool = pool
        ordered.Push(ch)
    end for
    NxClearManifests()
    timer.Mark()
    channels = NxScheduleGuide(ordered, nowSec, true)
    print "library: saved pools read and today scheduled in "; timer.TotalMilliseconds(); " ms"
    guide = {
        channels: channels, builtAt: nowSec, items: saved.libraryItems,
        bundles: saved.bundles, enabledBundles: bundles, franchises: saved.franchises,
        collections: saved.collections, poolsFingerprint: NxToStr(saved.fingerprint)
    }
    m.savedPoolsKey = saved.key
    m.savedPoolsFingerprint = NxToStr(saved.fingerprint)
    return { ordered: ordered, guide: guide }
end function

sub loadLibrary()
    ' The keys the saved guide and pools were last written or read under, and
    ' the pools' fingerprint, so a build that would write the same skips it.
    m.savedGuideKey = ""
    m.savedPoolsKey = ""
    m.savedPoolsFingerprint = ""
    m.top.status = "loading"
    setPhase("preparing")
    timer = CreateObject("roTimespan")
    shown = false
    if m.top.useCache then
        clock0 = NxFilterClock()
        raw = ""
        if CreateObject("roFileSystem").Exists(NxGuideCachePath()) then raw = NxReadBigFile(NxGuideCachePath())
        if raw <> "" then
            saved = ParseJson(raw)
            if type(saved) = "roAssociativeArray" then
                if saved.key = NxGuideCacheKey(clock0.nowSec, NxEnabledBundles()) and type(saved.guide) = "roAssociativeArray" then
                    m.savedGuideKey = saved.key
                    m.top.fromCache = true
                    m.top.guide = saved.guide
                    m.shownGuide = saved.guide
                    m.top.status = "ready"
                    shown = true
                    print "library: showing the saved guide after "; timer.TotalMilliseconds(); " ms; refreshing in the background"
                end if
            end if
        end if
        if not shown then
            m.top.progress = "Scheduling your channels…"
            fromPools = NxGuideFromSavedPools(clock0.nowSec, NxEnabledBundles())
            if fromPools <> invalid then
                m.top.fromCache = true
                m.top.guide = fromPools.guide
                m.shownGuide = fromPools.guide
                m.top.status = "ready"
                shown = true
                print "library: showing the saved pools, scheduled for today, after "; timer.TotalMilliseconds(); " ms; refreshing in the background"
                ' Then tomorrow, so the guide can be read past midnight.
                t = CreateObject("roTimespan")
                fromPools.guide.channels = NxScheduleGuide(fromPools.ordered, clock0.nowSec)
                m.top.guide = fromPools.guide
                m.shownGuide = fromPools.guide
                m.top.status = "ready"
                print "library: tomorrow scheduled and handed over in "; t.TotalMilliseconds(); " ms"
            end if
        end if
    end if
    servers = ParseJson(NxPlexRegistry().Read("servers"))
    if type(servers) <> "roArray" or servers.Count() = 0 then
        fail("No " + NxKindName(NxSignedInKind()) + " server is set up on this TV. Press * to sign in again.")
        return
    end if

    ' The saved library (source/plex/LibrarySnapshot.brs): a rebuild after a
    ' switch in Settings takes each server from it, and so does any load while
    ' a server's library signature is unchanged and its save under a day old,
    ' as the Apple TV app's refreshLibraryIfChanged skips the scan. A server
    ' read this time is saved again once the guide is up.
    snapDir = NxSnapshotDir()
    snap = NxSnapshotReadMeta(snapDir)
    m.top.firstRun = type(snap.servers) <> "roAssociativeArray" or snap.servers.Count() = 0
    ' A first run after an earlier save: the OS cleared cachefs: (a restart
    ' does, as it lives in RAM). The registry outlasts that, not a sign-out.
    m.top.savedBefore = m.top.firstRun and NxPlexRegistry().Read("librarySaved") = "1"
    nowSec& = NxFilterClock().nowSec
    ' Every server keeps its index, on or off, since items carry it, and its
    ' machine identifier keys its collections and its save.
    keys = []
    collections = { raw: [], serverKeys: {}, failed: 0 }
    for i = 0 to servers.Count() - 1
        key = NxToStr(servers[i].machineIdentifier)
        if key = "" then key = "plex"
        keys.Push(key)
        collections.serverKeys[i.ToStr()] = key
    end for
    items = []
    scanned = []
    ' Every server on, as NxSnapshotSaveServer takes it, so a save the OS
    ' has cleared from cachefs: can be written again from memory.
    saves = []
    serversOn = NxServersOn(servers, NxSavedServerChoices())
    setPhase("library")
    m.top.progress = "Connecting to your servers…"
    missing = NxPlexResolveSaved(servers, serversOn)
    usable = 0
    for i = 0 to servers.Count() - 1
        if serversOn[i] and NxToStr(servers[i].uri) <> "" then usable = usable + 1
    end for
    if usable = 0 then
        if shown then
            print "library: background refresh reached no server; keeping the saved guide"
            keepSavedGuide()
            return
        end if
        if missing = invalid then
            fail("Can't reach plex.tv to find your servers. Check the TV's internet connection, then press OK to try again.")
        else
            fail("None of your Plex servers answered over a secure (HTTPS) connection. In Plex, set Settings > Network > Secure connections to Preferred. Press OK to try again.")
        end if
        return
    end if
    for i = 0 to servers.Count() - 1
        ' A server with no address is left out this time; it's tried again on
        ' the next load.
        if serversOn[i] and NxToStr(servers[i].uri) <> "" then
            saved = invalid
            if type(snap.servers[keys[i]]) = "roAssociativeArray" then
                fresh = m.top.rebuild
                if not fresh then
                    m.top.progress = "Checking your library on " + NxToStr(servers[i].name) + "…"
                    fresh = NxSnapshotFresh(snap.servers[keys[i]], NxServerSignatureFor(servers[i]), nowSec&)
                end if
                if fresh then saved = NxSnapshotLoadServer(snapDir, snap, keys[i], i)
            end if
            if saved <> invalid then
                items.Append(saved.items)
                if saved.collections <> invalid then
                    collections.raw.Append(saved.collections)
                else
                    collections.failed = collections.failed + 1
                end if
                saves.Push({ index: i, key: keys[i], signature: saved.entry.signature, collections: saved.collections, savedAt: saved.entry.savedAt })
                print "library: "; saved.items.Count(); " items from the saved library, server "; i
            else
                m.top.progress = "Reading your library from " + NxToStr(servers[i].name) + "…"
                info = { signature: invalid }
                got = NxScanServerFor(servers[i], i, m.top, info)
                if got = invalid then
                    if shown then
                        print "library: background refresh couldn't read the library; keeping the saved guide"
                        keepSavedGuide()
                        return
                    end if
                    fail("Couldn't read the library on " + NxToStr(servers[i].name) + ". Press OK to try again.")
                    return
                end if
                items.Append(got)
                s = { index: i, key: keys[i], signature: info.signature, collections: invalid, savedAt: nowSec& }
                scanned.Push(s)
                saves.Push(s)
            end if
        end if
    end for
    print "library: "; items.Count(); " items in "; timer.TotalMilliseconds(); " ms ("; scanned.Count(); " servers scanned)"

    ' Server collections (source/collections/Collections.brs), read after the
    ' library as the web tuner's scan runs after its load, for the servers
    ' just scanned. A server whose collections can't be read just has none
    ' this time.
    timer.Mark()
    setPhase("collections")
    if scanned.Count() > 0 then m.top.progress = "Reading your collections…"
    for each s in scanned
        ' Jellyfin and Emby collections aren't read yet (docs/JELLYFIN-EMBY.md,
        ' phase 4): none, rather than a failure.
        if NxServerKind(servers[s.index]) = "plex" then
            got = NxCollectionsFetchPlex(s.key, NxPlexCollectionsFetcher(servers[s.index]), m.top)
        else
            got = []
        end if
        if got = invalid then
            collections.failed = collections.failed + 1
        else
            collections.raw.Append(got)
            s.collections = got
        end if
    end for
    print "library: "; collections.raw.Count(); " server collections ("; collections.failed; " servers failed) in "; timer.TotalMilliseconds(); " ms"
    config = ParseJson(ReadAsciiFile("pkg:/data/channels.json"))
    manifest = ParseJson(ReadAsciiFile("pkg:/data/channels-memberships.json"))

    ' Enrichment, when this build has it (source/enrich/Enrichment.brs): the
    ' local and shared caches first. If the relay or OMDb has more to give, a
    ' guide built from the caches goes up first, unless the saved one is
    ' already showing, and the guide is rebuilt only if they added anything.
    opts = {
        config: NxEnrichmentConfig(), net: NxEnrichmentNet(),
        cache: NxEnrichFileCache("cachefs:/nostalgex-enrichment.json"),
        nowSec: NxFilterClock().nowSec, channels: config.channels,
        backoff: NxEnrichOMDbBackoff(NxEnrichRegistryStore()), progress: NxEnrichTopProgress(m.top)
    }
    timer.Mark()
    setPhase("metadata")
    m.top.progress = "Reading shared details…"
    state = NxEnrichFromCaches(items, opts)
    if not state.skipped then print "library: enrichment caches read in "; timer.TotalMilliseconds(); " ms"
    ' Every server from its save: the last build's filter results stand for
    ' all but the channels that read the clock (NxSavedFiltered).
    reuse = invalid
    if scanned.Count() = 0 then
        timer.Mark()
        reuse = NxSavedFiltered(items, config, NxFilterClock(), NxEnabledBundles())
        if reuse <> invalid then print "library: "; reuse.Count(); " channels' filter results from the last build, read in "; timer.TotalMilliseconds(); " ms"
    end if
    built = invalid
    if NxEnrichHasRemoteWork(state, opts) then
        if not shown then
            built = buildGuide(items, config, manifest, collections, false, reuse)
            shown = true
        end if
        timer.Mark()
        added = NxEnrichFromRemote(state, items, opts)
        print "library: enrichment remote step added "; added; " in "; timer.TotalMilliseconds(); " ms"
        if added > 0 then
            built = invalid
            reuse = invalid
        end if
    end if
    if built = invalid then built = buildGuide(items, config, manifest, collections, shown, reuse)
    timer.Mark()
    for each s in scanned
        NxSnapshotSaveServer(snapDir, snap, s.key, items, s.index, s.collections, s.signature, nowSec&)
    end for
    NxSnapshotForgetServers(snapDir, snap, keys)
    reg = NxPlexRegistry()
    if reg.Read("librarySaved") <> "1" and (scanned.Count() > 0 or not m.top.firstRun) then
        reg.Write("librarySaved", "1")
        reg.Flush()
    end if
    if scanned.Count() > 0 then print "library: saved the library in "; timer.TotalMilliseconds(); " ms; memory "; CreateObject("roAppMemoryMonitor").GetMemoryLimitPercent(); "% of the app's limit"
    ' Every item's filter cache goes; the library itself stays for package
    ' switches (rebuildForBundles). The pools hold most of it anyway, and
    ' reading it back from cachefs: for each switch kept two copies alive
    ' (reused pools held the old one) and failed when the OS had cleared it.
    for each it in items
        it.Delete("nxFilter")
    end for
    ' The enrichment cache too, which holds its rows once read, so a cleared
    ' cachefs: gets it back with the library (resaveClearedLibrary).
    lib = { items: items, collections: collections, saves: saves, serversOn: NxSavedServersOnKey(), enrichCache: opts.cache }
    items = invalid
    keepScheduling(built.ordered, built.guide, built.channels, lib)
end sub

' Builds the switched-on channels from the library, schedules them and hands
' the guide to the render thread, unless `shown` and it matches what is
' already on screen. Returns { ordered, guide, channels } for keepScheduling:
' channels is every channel built, those too small for the guide included.
function buildGuide(items as Object, config as Object, manifest as Object, collections as Object, shown as Boolean, reuse = invalid as Dynamic) as Object
    timer = CreateObject("roTimespan")
    ' A library load clears the day schedules, as the web tuner's does. A
    ' package switch (reuse) keeps them, as the Apple TV's
    ' rebuildLineupAfterBundleChange does: a channel whose pool is unchanged
    ' keeps today's schedule instead of being packed again.
    if reuse = invalid then NxClearManifests()
    ' The choices this build reads, for keepScheduling to compare.
    m.builtChoices = NxChoicesKey()
    exclusive = NxFilterExclusiveRules(config.exclusiveRules)
    clock = NxFilterClock()
    nowSec& = clock.nowSec
    ' Which server kind the items are from: an Emby Dolby Vision profile 5
    ' file goes on no channel.
    backend = NxSignedInKind()
    ' What the franchise and collection steps read, as upstream's onChannels:
    ' the filter leaves those files out itself, and these must too.
    onChannels = items
    if backend = "emby" then
        onChannels = []
        for each it in items
            if not NxIsLeftOffChannels(it, backend) then onChannels.Push(it)
        end for
        print "library: Emby: "; items.Count() - onChannels.Count(); " Dolby Vision profile 5 item(s) left off channels"
    end if
    bundles = NxEnabledBundles()
    poolIds = NxPoolChannelIds(config, bundles)

    timer.Mark()
    setPhase("channels")
    channels = []
    built = 0
    reused = 0
    for each def in config.channels
        ch = {
            id: def.id, number: def.number, name: NxToStr(def.name), colorHex: NxToStr(def.colorHex),
            minItems: def.minItems, isPremiereChannel: def.isPremiereChannel,
            timeRestrictions: def.timeRestrictions, enabled: true, built: false, pool: []
        }
        ' `enabled: def.enabled !== false`; comparing invalid to a Boolean is an error here.
        if type(def.enabled) = "Boolean" or type(def.enabled) = "roBoolean" then ch.enabled = def.enabled
        if poolIds.DoesExist(def.id.ToStr()) then
            built = built + 1
            m.top.progress = "Building channels: " + built.ToStr() + " of " + poolIds.Count().ToStr()
            m.top.bar = (built - 1) / poolIds.Count()
            m.top.barCaption = "Channel " + built.ToStr() + " of " + poolIds.Count().ToStr()
            matched = invalid
            if reuse <> invalid then matched = reuse[def.id.ToStr()]
            if matched = invalid then
                if reuse <> invalid then print "library: filtering channel "; def.id; " (no earlier result to reuse)"
                matched = []
                for each row in NxFilterPool(items, NxFilterChannel(def), manifest, exclusive, clock, backend)
                    matched.Push(row.item)
                end for
            else
                reused = reused + 1
            end if
            ' The filter's own result, kept apart from what the franchise step
            ' adds, so a package switched on later reuses it (rebuildForBundles).
            ch.filtered = []
            ch.filtered.Append(matched)
            ch.pool = []
            ch.pool.Append(matched)
            ch.built = true
            minItems = 50
            if NxTruthy(def.minItems) then minItems = def.minItems
            ch.enabled = ch.pool.Count() >= minItems
        end if
        channels.Push(ch)
    end for
    print "library: built "; built; " channels ("; reused; " kept from the last build) in "; timer.TotalMilliseconds(); " ms"
    setPhase("finishing")
    m.top.progress = ""

    ' FRANCHISES, as the Apple TV app has it (the web tuner doesn't call the
    ' builder): covered franchises join their classic's pool, and each found
    ' franchise switched on gets a channel from CH 300 that rides on the
    ' package's switch.
    franchiseRows = []
    foundIDs = []
    franchiseBundleIDs = []
    fr = invalid
    defs = []
    for each bdl in NxList(config.bundles)
        if bdl.id = NxFranchisesBundleID() then franchiseBundleIDs = NxList(bdl.channelIDs)
    end for
    if NxHasValue(bundles, NxFranchisesBundleID()) then
        timer.Mark()
        m.top.progress = "Finding franchises…"
        defs = NxFranchiseDefinitions(ParseJson(ReadAsciiFile("pkg:/data/franchises.json")))
        fr = NxFranchiseStep({
            channels: channels, items: onChannels, defs: defs,
            choices: NxSavedFranchiseChoices(), bundleChannelIDs: franchiseBundleIDs,
            manifest: manifest, exclusiveRules: exclusive
        })
        for each ch in fr.channels
            channels.Push(ch)
            foundIDs.Push(ch.id)
        end for
        franchiseRows = fr.rows
        print "library: franchises: "; fr.found.Count(); " found, "; foundIDs.Count(); " channels, in "; timer.TotalMilliseconds(); " ms"
    end if

    ' MY COLLECTIONS, as the web tuner has them: each collection switched on
    ' airs from CH 500, outside every package. One that is a franchise the
    ' package already carries folds into it instead, as on the Apple TV.
    timer.Mark()
    cl = NxCollectionsStep({
        channels: channels, raw: collections.raw, items: onChannels, serverKeys: collections.serverKeys,
        manifest: manifest, enabledKeys: NxSavedCollectionKeys(),
        franchise: fr, franchiseBundleIDs: franchiseBundleIDs, defs: defs
    })
    collectionIDs = []
    for each ch in cl.channels
        channels.Push(ch)
        collectionIDs.Push(ch.id)
    end for
    print "library: collections: "; cl.rows.Count(); " listed, "; cl.folded.Count(); " folded into franchises, "; collectionIDs.Count(); " channels, "; cl.overCap; " past CH 699, in "; timer.TotalMilliseconds(); " ms"
    for each f in cl.folded
        print "library: collection "; f.title; " ("; f.items; " items) folds into "; f.into; " by "; f.why
    end for
    timer.Mark()
    for each ch in channels
        ' Pools air in library order, as the Apple TV's and the web tuner's
        ' (1.0.7) do: no shuffle.
        if ch.built and not NxTruthy(ch.collection) then ch.basePool = ch.pool
    end for

    ' Found franchise channels show while the package is on; its own channel
    ' list stays the seven classics, as upstream's Settings row reads.
    guideConfig = { bundles: [] }
    for each bdl in NxList(config.bundles)
        if bdl.id = NxFranchisesBundleID() and foundIDs.Count() > 0 then
            ids = []
            ids.Append(NxList(bdl.channelIDs))
            ids.Append(foundIDs)
            guideConfig.bundles.Push({ id: bdl.id, channelIDs: ids, activeMonths: bdl.activeMonths, seasonStart: bdl.seasonStart })
        else
            guideConfig.bundles.Push(bdl)
        end if
    end for
    ' Collection channels belong to no package; the web tuner shows them
    ' whenever they are built. Here they ride on a package that is always on.
    guideBundles = []
    guideBundles.Append(bundles)
    if collectionIDs.Count() > 0 then
        guideConfig.bundles.Push({ id: "nx-collections", channelIDs: collectionIDs })
        guideBundles.Push("nx-collections")
    end if
    ordered = NxGuideOrder(guideConfig, channels, guideBundles, clock)
    print "library: shuffled and ordered in "; timer.TotalMilliseconds(); " ms"
    fingerprint = NxPoolsFingerprint(ordered)
    print "library: pools fingerprint "; fingerprint; " ("; ordered.Count(); " channels)"
    timer.Mark()
    ' Pools the same as the guide on screen's, on the same local and UTC day
    ' (the shuffle's seed): its schedules are what scheduling would give, so
    ' they stand. A launch matching its saved guide scheduled both days again,
    ' 13 to 14 s at 123 channels on a Streaming Stick Plus (Discussion #8).
    ' The schedule keeps the time it was made, so a new hour since is
    ' re-checked by keepScheduling as ever.
    old = m.shownGuide
    sameSchedule = false
    builtAt& = nowSec&
    if shown and old <> invalid then
        if NxToStr(old.poolsFingerprint) = fingerprint and type(old.channels) = "roArray" and NxIsNumber(old.builtAt) then
            oldAt& = old.builtAt
            sameSchedule = oldAt& \ 86400 = nowSec& \ 86400 and NxLocalDay(oldAt&).dayKey = NxLocalDay(nowSec&).dayKey
        end if
    end if
    if sameSchedule then
        out = old.channels
        builtAt& = oldAt&
        print "library: pools match the guide on screen; its schedules stand"
    else
        out = NxScheduleGuide(ordered, nowSec&)
        print "library: scheduled in "; timer.TotalMilliseconds(); " ms"
    end if
    bundleList = []
    for each bdl in NxList(config.bundles)
        entry = { id: bdl.id, name: NxToStr(bdl.name), channelIDs: NxList(bdl.channelIDs), activeMonths: bdl.activeMonths, seasonStart: bdl.seasonStart }
        ' The sidebar jumps to the first channel shown, found franchises included.
        if bdl.id = NxFranchisesBundleID() then
            jump = []
            jump.Append(entry.channelIDs)
            jump.Append(foundIDs)
            entry.jumpIDs = jump
        end if
        bundleList.Push(entry)
    end for
    guide = {
        channels: out, builtAt: builtAt&, poolsFingerprint: fingerprint, items: items.Count(), bundles: bundleList, enabledBundles: bundles,
        franchises: franchiseRows, collections: { rows: cl.rows, overCap: cl.overCap, scanned: collections.raw.Count(), failed: collections.failed }
    }
    ' Only hand over a refresh that differs, so an unchanged library leaves the
    ' screen alone. Before the saves, so a first run's guide doesn't wait on
    ' them.
    ' The package list counts too: a new package that is off changes no
    ' channel, but Settings has to show it.
    ' Compared with the task's own copy: each read of m.top.guide copies the
    ' whole guide out of the node.
    timer.Mark()
    matched = false
    if shown and old <> invalid and FormatJson(guide.channels) = FormatJson(old.channels) and FormatJson(guide.bundles) = FormatJson(old.bundles) and FormatJson(guide.franchises) = FormatJson(old.franchises) and FormatJson(guide.collections) = FormatJson(old.collections) then
        matched = true
        print "library: background refresh matches the saved guide"
    else
        m.top.fromCache = false
        m.top.guide = guide
        m.shownGuide = guide
        m.top.status = "ready"
    end if
    print "library: compared and handed over in "; timer.TotalMilliseconds(); " ms"
    ' The saves, unless the file already holds this: a guide that matched the
    ' one on screen (so its packages, franchise and collection lists too) and
    ' kept its schedules, under the same key; for the pools, also from a build
    ' that filtered nothing new (the clock-read channels it did filter are
    ' never reused from the file). cachefs: can lose a file, so it must be there.
    fs = CreateObject("roFileSystem")
    timer.Mark()
    guideKey = NxGuideCacheKey(nowSec&, bundles)
    if matched and sameSchedule and m.savedGuideKey = guideKey and fs.Exists(NxGuideCachePath()) then
        print "library: the saved guide is this one; not saved again"
    else
        WriteAsciiFile(NxGuideCachePath(), FormatJson({ key: guideKey, guide: guide }))
        m.savedGuideKey = guideKey
        print "library: saved the guide in "; timer.TotalMilliseconds(); " ms"
    end if
    timer.Mark()
    poolsKey = NxPoolCacheKey(NxSeasonKey(guide.bundles, clock), guide.enabledBundles)
    if matched and sameSchedule and reuse <> invalid and m.savedPoolsKey = poolsKey and m.savedPoolsFingerprint = fingerprint and fs.Exists(NxPoolCachePath()) then
        print "library: the saved pools are these; not saved again"
    else
        NxSavePools(ordered, guide, clock, channels)
        m.savedPoolsKey = poolsKey
        m.savedPoolsFingerprint = fingerprint
        print "library: saved the pools in "; timer.TotalMilliseconds(); " ms; memory "; CreateObject("roAppMemoryMonitor").GetMemoryLimitPercent(); "% of the app's limit; "; NxFileKB(NxPoolCachePath()); " KB"
    end if
    return { ordered: ordered, guide: guide, channels: channels }
end function

' Stay up with the pools, re-checking schedules whenever asked (MainScene asks
' every 30 s, as upstream's rebuildAllSchedules runs): a time restriction
' lifting at 9 PM, or a new day, re-packs exactly as it would upstream.
sub keepScheduling(ordered as Object, guide as Object, builtChannels as Object, lib as Object)
    port = CreateObject("roMessagePort")
    m.top.ObserveField("reschedule", port)
    m.top.ObserveField("bundleRequest", port)
    ' A switch saved while this load was still running (a package, or a
    ' franchise or collection on the way out of Settings) was missed by the
    ' observer above: build for it now. Either way Settings hears which
    ' packages the guide holds.
    built = FormatJson(guide.enabledBundles)
    if FormatJson(NxEnabledBundles()) <> built or NxChoicesKey() <> m.builtChoices then
        got = rebuildForBundles(builtChannels, lib)
        if got <> invalid then
            ordered = got.ordered
            guide = got.guide
            builtChannels = got.channels
            built = FormatJson(guide.enabledBundles)
        else
            built = "rebuild"
        end if
    end if
    m.top.bundleBuilt = built
    last = FormatJson(guide.channels)
    ' What a schedule depends on besides the pools: the local day and hour
    ' (time restrictions go by the hour). The re-check skips while neither
    ' has moved; scheduling about 120 channels took a core for 9 to 10 s.
    lastHour = NxScheduleHourKey(guide.builtAt)
    while true
        msg = Wait(0, port)
        if type(msg) = "roSGNodeEvent" and msg.GetField() = "bundleRequest" then
            ' Several switches while one builds: the saved packages are read
            ' afresh each time, so one build covers every request queued
            ' behind it, and a request the guide already answers builds
            ' nothing. Eleven presses in a minute were eleven builds, the last
            ' six of them no-ops of 8 s each (Discussion #8).
            dropped = NxDrainBundleRequests(port)
            if FormatJson(NxEnabledBundles()) = FormatJson(guide.enabledBundles) and NxChoicesKey() = m.builtChoices then
                print "library: package change requested; the guide already has it ("; dropped; " more queued)"
                m.top.bundleBuilt = FormatJson(guide.enabledBundles)
            else
                print "library: package change requested ("; dropped; " more queued)"
                got = rebuildForBundles(builtChannels, lib)
                if got <> invalid then
                    ordered = got.ordered
                    guide = got.guide
                    builtChannels = got.channels
                    last = FormatJson(guide.channels)
                    lastHour = NxScheduleHourKey(guide.builtAt)
                    m.top.bundleBuilt = FormatJson(guide.enabledBundles)
                else
                    m.top.bundleBuilt = "rebuild"
                end if
            end if
        else if type(msg) = "roSGNodeEvent" and NxScheduleHourKey(CreateObject("roDateTime").AsSeconds()) <> lastHour then
            nowSec& = CreateObject("roDateTime").AsSeconds()
            lastHour = NxScheduleHourKey(nowSec&)
            channels = NxScheduleGuide(ordered, nowSec&)
            now = FormatJson(channels)
            if now <> last then
                last = now
                guide.channels = channels
                m.top.guide = guide
                m.top.status = "ready"
                print "library: schedules changed (new day or time restriction)"
            end if
        end if
    end while
end sub

' Takes the bundleRequest events waiting on the port, and returns how many.
' Anything else waiting there is a 30 s re-check, which the next one repeats.
function NxDrainBundleRequests(port as Object) as Integer
    n = 0
    msg = port.GetMessage()
    while msg <> invalid
        if type(msg) = "roSGNodeEvent" and msg.GetField() = "bundleRequest" then n = n + 1
        msg = port.GetMessage()
    end while
    return n
end function

' keepScheduling for a saved guide the background refresh couldn't follow
' with a library (no server reached, or its scan failed). The task stays up,
' so Settings and the 30 s re-check still have someone listening: a package
' switch needs the library, so it is answered "rebuild", and a new hour or
' day schedules from the saved pools, read the first time one is needed.
sub keepSavedGuide()
    port = CreateObject("roMessagePort")
    m.top.ObserveField("reschedule", port)
    m.top.ObserveField("bundleRequest", port)
    guide = m.shownGuide
    if FormatJson(NxEnabledBundles()) <> FormatJson(guide.enabledBundles) then
        m.top.bundleBuilt = "rebuild"
    else
        m.top.bundleBuilt = FormatJson(guide.enabledBundles)
    end if
    ordered = invalid
    lastHour = NxScheduleHourKey(guide.builtAt)
    while true
        msg = Wait(0, port)
        if type(msg) = "roSGNodeEvent" and msg.GetField() = "bundleRequest" then
            print "library: package change needs a full rebuild: the background refresh has no library"
            m.top.bundleBuilt = "rebuild"
        else if type(msg) = "roSGNodeEvent" and NxScheduleHourKey(CreateObject("roDateTime").AsSeconds()) <> lastHour then
            nowSec& = CreateObject("roDateTime").AsSeconds()
            lastHour = NxScheduleHourKey(nowSec&)
            if ordered = invalid then
                clock = NxFilterClock(nowSec&)
                fromPools = NxGuideFromSavedPools(nowSec&, guide.enabledBundles)
                if fromPools <> invalid then
                    ordered = fromPools.ordered
                    guide = fromPools.guide
                end if
            end if
            if ordered = invalid then
                print "library: no saved pools to schedule the new hour from; the guide stays as it is"
            else
                guide.channels = NxScheduleGuide(ordered, nowSec&)
                m.top.guide = guide
                m.top.status = "ready"
                print "library: saved guide rescheduled from the saved pools (new day or time restriction)"
            end if
        end if
    end while
end sub

' A package switched on or off in Settings, as upstream's
' rebuildLineupAfterBundleChange: only channels that weren't built last time
' (prev: buildGuide's channels, the guide's and those too small for it) are
' filtered, from the library the load kept in memory (lib); every other
' channel keeps its filtered pool. The franchise, collection, order and
' schedule steps run as in a full build. Returns buildGuide's result, or
' invalid when the servers on have changed since the load (Settings then
' rebuilds the whole guide).
function rebuildForBundles(prev as Object, lib as Object) as Dynamic
    timer = CreateObject("roTimespan")
    if lib.serversOn <> NxSavedServersOnKey() then
        print "library: package change needs a full rebuild: the servers on changed"
        return invalid
    end if
    config = ParseJson(ReadAsciiFile("pkg:/data/channels.json"))
    manifest = ParseJson(ReadAsciiFile("pkg:/data/channels-memberships.json"))
    reuse = {}
    for each ch in prev
        if ch.filtered <> invalid then reuse[ch.id.ToStr()] = ch.filtered
    end for
    print "library: package change: "; lib.items.Count(); " items in memory; memory "; NxMemoryLine()
    built = buildGuide(lib.items, config, manifest, lib.collections, true, reuse)
    for each it in lib.items
        it.Delete("nxFilter")
    end for
    print "library: package change built in "; timer.TotalMilliseconds(); " ms; memory "; NxMemoryLine()
    resaveClearedLibrary(lib)
    return built
end function

' cachefs: lives in RAM, and the OS takes it back when it needs the space
' (twice in 25 minutes on a Streaming Stick Plus, Discussion #8): a server
' whose saved library has gone is saved again from memory, so the next
' launch doesn't have to read the whole server, and so is the enrichment
' cache, or the next launch asks Supabase for every TMDB id again (1,928 ids,
' 16.8 s on a Streaming Stick Plus). The guide and pools are written by every
' build anyway.
sub resaveClearedLibrary(lib as Object)
    c = lib.enrichCache
    if c <> invalid then
        if c.loaded and type(c.rows) = "roAssociativeArray" then
            if c.rows.Count() > 0 and not CreateObject("roFileSystem").Exists(c.path) then
                t = CreateObject("roTimespan")
                WriteAsciiFile(c.path, FormatJson(c.rows))
                print "library: the enrichment cache was gone; saved "; c.rows.Count(); " records again in "; t.TotalMilliseconds(); " ms"
            end if
        end if
    end if
    snapDir = NxSnapshotDir()
    snap = NxSnapshotReadMeta(snapDir)
    for each s in lib.saves
        if type(snap.servers[s.key]) <> "roAssociativeArray" then
            t = CreateObject("roTimespan")
            fs = CreateObject("roFileSystem")
            print "library: server "; s.index; "'s saved library is gone (dir has "; ListDir(snapDir).Count(); " files, saved guide "; fs.Exists(NxGuideCachePath()); ", pools "; fs.Exists(NxPoolCachePath()); ", enrichment cache "; fs.Exists("cachefs:/nostalgex-enrichment.json"); "); saving it again"
            ' Its first save time, so it still ages out a day after the scan.
            ' From JSON it may be an Integer or a Double.
            savedAt& = s.savedAt
            NxSnapshotSaveServer(snapDir, snap, s.key, lib.items, s.index, s.collections, s.signature, savedAt&)
            print "library: saved server "; s.index; "'s library again in "; t.TotalMilliseconds(); " ms"
        end if
    end for
end sub

' The app's memory use, for the package-change log: percent of its limit and
' KB still available to it.
function NxMemoryLine() as String
    mon = CreateObject("roAppMemoryMonitor")
    return mon.GetMemoryLimitPercent().ToStr() + "%, " + mon.GetChannelAvailableMemory().ToStr() + " KB free"
end function

' SHA-1 of each guide channel's id and its pool's items before the shuffle,
' first 12 hex digits: a package built on its own must match a full build of
' the same packages. Item keys only; no titles or addresses.
function NxPoolsFingerprint(ordered as Object) as String
    d = CreateObject("roEVPDigest")
    d.Setup("sha1")
    for each ch in ordered
        pool = ch.basePool
        if pool = invalid then pool = ch.pool
        keys = [NxToStr(ch.id)]
        for each it in pool
            keys.Push(NxToStr(it.ratingKey) + "@" + NxToStr(it.serverIndex))
        end for
        b = CreateObject("roByteArray")
        b.FromAsciiString(keys.Join(",") + Chr(10))
        d.Update(b)
    end for
    return Left(d.Final(), 12)
end function

' A new step on the loading screen's rail; the last step's bar goes with it.
sub setPhase(phase as String)
    m.top.bar = -1
    m.top.barCaption = ""
    m.top.phase = phase
end sub

sub fail(message as String)
    m.top.message = message
    m.top.status = "error"
    print "library: "; message
end sub
