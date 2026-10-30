' Copyright (c) 2026 nostalgex-roku contributors, MIT License.

sub init()
    m.top.functionName = "loadLibrary"
end sub

' The saved guide: the last build's output, shown at launch while it is for
' the same local day, packages, choices and servers on, from this build or
' another (NxSavedKeyShowable in source/util/SavedKey.brs). The full build
' runs behind it either way.
' It holds titles and schedules, nothing secret.
function NxGuideCachePath() as String
    return NxCacheRoot() + "/nostalgex-guide.json"
end function

function NxGuideCacheKey(nowSec as LongInteger, bundles as Object) as String
    return NxSavedKey(NxBuildKey(), NxLocalDay(nowSec).dayKey + "|" + FormatJson(bundles) + "|" + NxChoicesKey())
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
' with the items they hold. Filtering is most of a build (over a minute on a
' TV), and a pool rarely changes from one day to the next, so when the saved
' guide is a day old these are scheduled for today instead, in seconds, and the full build still runs
' behind them. Shown while the month and which packages are in season
' (NxSeasonKey: the guide's lead, and the year the filter reads), packages,
' franchise and collection choices and servers on are the same, from any
' build; their filter results are reused only by the same build.
function NxPoolCachePath() as String
    return NxCacheRoot() + "/nostalgex-pools.json"
end function

' The display's Dolby Vision answer counts too (#69): a stick moved to a TV
' that answers otherwise builds its channel lists again.
function NxPoolCacheKey(season as String, bundles as Object) as String
    return NxSavedKey(NxBuildKey(), season + "|" + FormatJson(bundles) + "|" + NxChoicesKey() + "|dv" + FormatJson(NxDisplayShowsDolbyVision()))
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
'
' The channel summaries and the filtered map are one FormatJson each here
' too (I-065), on top of a library large enough to need the per-server
' filter split above: with several large servers' worth of channels and
' their filter results, that was a second place a single call formatted
' everything at once. Each channel (and each filtered entry) is its own
' small FormatJson call instead, in the same pieces-of-500 as the items.
sub NxSavePools(ordered as Object, guide as Object, now as Object, built as Object)
    path = NxPoolCachePath()
    WriteAsciiFile(path, "{""key"":" + FormatJson(NxPoolCacheKey(NxSeasonKey(guide.bundles, now), guide.enabledBundles)) + ",""items"":[")
    st = { index: {}, count: 0, parts: [], path: path }
    chans = []
    for each ch in ordered
        saved = {}
        ' Keys come back lowercased from an AA's iteration, so they're compared
        ' that way: a `k <> "basePool"` never matched, and every channel's pool
        ' was written out in full a second time (20 MB of a 23 MB file).
        for each k in ch
            lk = LCase(k)
            if lk <> "pool" and lk <> "filtered" and lk <> "nxmemo" then saved[k] = ch[k]
        end for
        saved.poolIdx = NxPoolItemIndexes(ch.pool, st)
        chans.Push(saved)
    end for
    filtered = []
    for each ch in built
        if ch.filtered <> invalid then filtered.Push({ id: ch.id.ToStr(), idx: NxPoolItemIndexes(ch.filtered, st) })
    end for
    ' The items array above is only safe to close once both loops are done
    ' reading pools into it (a filtered set can hold an item no channel's
    ' own pool does), so the channels and filtered pieces come after.
    st.parts.Push("],""channels"":[")
    for i = 0 to chans.Count() - 1
        text = FormatJson(chans[i])
        if i > 0 then text = "," + text
        st.parts.Push(text)
        if st.parts.Count() >= 500 then NxAppendText(st.path, st.parts)
    end for
    st.parts.Push("],""filtered"":{")
    for i = 0 to filtered.Count() - 1
        f = filtered[i]
        text = FormatJson(f.id) + ":" + FormatJson(f.idx)
        if i > 0 then text = "," + text
        st.parts.Push(text)
        if st.parts.Count() >= 500 then NxAppendText(st.path, st.parts)
    end for
    st.parts.Push("}")
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
' The season key comes from the file's own packages, as they were in the
' channels.json of the build that saved them.
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
    if not NxSavedKeyShowable(saved.key, NxPoolCacheKey(NxSeasonKey(saved.bundles, NxFilterClock(nowSec)), bundles)) then return invalid
    ordered = []
    for each ch in saved.channels
        pool = []
        for each n in ch.poolIdx
            pool.Push(saved.items[n])
        end for
        ch.Delete("poolIdx")
        ch.pool = pool
        ordered.Push(ch)
    end for
    NxClearManifests()
    timer.Mark()
    channels = NxScheduleGuide(ordered, nowSec, true)
    print "library: saved pools scheduled for today in "; timer.TotalMilliseconds(); " ms"
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
    m.shownOtherBuild = false
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
                guideKey = NxGuideCacheKey(clock0.nowSec, NxEnabledBundles())
                if NxSavedKeyShowable(saved.key, guideKey) and type(saved.guide) = "roAssociativeArray" then
                    m.savedGuideKey = saved.key
                    ' Another build scheduled it, so its schedules don't
                    ' stand for this one's (buildGuide).
                    m.shownOtherBuild = saved.key <> guideKey
                    m.top.fromCache = true
                    m.top.guide = saved.guide
                    m.shownGuide = saved.guide
                    m.top.status = "ready"
                    shown = true
                    if m.shownOtherBuild then
                        print "library: showing the saved guide from another build after "; timer.TotalMilliseconds(); " ms; rebuilding in the background"
                    else
                        print "library: showing the saved guide after "; timer.TotalMilliseconds(); " ms; refreshing in the background"
                    end if
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
    ' Set when a server's scan was stopped part way: its items are in, but
    ' not saved, so the next load reads it again, as upstream marks the
    ' library stale.
    partial = false
    ' Who stopped a scan that had read nothing: the load fails with that
    ' only if no server gave any items, as upstream counts its successes.
    emptyStop = ""
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
                if not fresh and not m.top.rescan then
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
                got = scanUnderWatch(servers[i], i, info)
                stopped = info.stopped
                if stopped <> "" then
                    count = 0
                    if got <> invalid then count = got.Count()
                    print "library: stopped waiting on server "; i; " ("; stopped; ") with "; count; " items read"
                    ' A background refresh stopped part way is dropped, as
                    ' upstream's: its items are a subset of the guide on
                    ' screen.
                    if shown then
                        keepSavedGuide()
                        return
                    end if
                    if count = 0 then
                        emptyStop = stopped
                        got = []
                    end if
                    partial = true
                else if got = invalid then
                    if shown then
                        print "library: background refresh couldn't read the library; keeping the saved guide"
                        keepSavedGuide()
                        return
                    end if
                    fail("Couldn't read the library on " + NxToStr(servers[i].name) + ". Press OK to try again.")
                    return
                end if
                items.Append(got)
                if stopped = "" then
                    s = { index: i, key: keys[i], signature: info.signature, collections: invalid, savedAt: nowSec& }
                    scanned.Push(s)
                    saves.Push(s)
                end if
            end if
        end if
    end for
    print "library: "; items.Count(); " items in "; timer.TotalMilliseconds(); " ms ("; scanned.Count(); " servers scanned)"
    if items.Count() = 0 and emptyStop = "viewer" then
        fail("Stopped waiting. Nothing had come back from your server, so no channels were built. Press OK to try again when the connection looks better.")
        return
    else if items.Count() = 0 and emptyStop <> "" then
        fail("Your server stopped sending data partway through the scan and never resumed. Check that it is awake and reachable on this network, then press OK to try again.")
        return
    end if

    ' Server collections (source/collections/Collections.brs), read after the
    ' library as the web tuner's scan runs after its load, for the servers
    ' just scanned. A server whose collections can't be read just has none
    ' this time.
    timer.Mark()
    setPhase("collections")
    if scanned.Count() > 0 then m.top.progress = "Reading your collections…"
    for each s in scanned
        ' Plex collections, or Jellyfin and Emby BoxSets.
        if NxServerKind(servers[s.index]) = "plex" then
            got = NxCollectionsFetchPlex(s.key, NxPlexCollectionsFetcher(servers[s.index]), m.top)
        else
            got = NxCollectionsFetchBoxSets(s.key, NxToStr(servers[s.index].userId), NxMbFetcher(servers[s.index]), m.top)
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
        cache: NxEnrichFileCache(NxCacheRoot() + "/nostalgex-enrichment.json"),
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
    if scanned.Count() = 0 and not partial then
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
    ' A library the switched-on packages fill no channel from (a first run is
    ' NOSTALGEX only): every other package with content is switched on and
    ' kept as the viewer's choice, as upstream's autoEnableBundlesWithContent
    ' (#60), so the guide isn't empty.
    if NxList(built.guide.channels).Count() = 0 then
        enabled = NxEnabledBundles()
        extra = NxAutoEnableCandidates(config.bundles, enabled)
        if extra.Count() > 0 then
            trial = []
            trial.Append(enabled)
            trial.Append(extra)
            NxSaveEnabledBundles(trial)
            built = buildGuide(items, config, manifest, collections, shown)
            keep = NxBundlesWithContent(config.bundles, extra, built.channels)
            final = []
            final.Append(enabled)
            final.Append(keep)
            NxSaveEnabledBundles(final)
            print "library: no channel from the packages on; switched on "; FormatJson(keep)
            if keep.Count() < extra.Count() then built = buildGuide(items, config, manifest, collections, shown)
        end if
    end if
    timer.Mark()
    for each s in scanned
        NxSnapshotSaveServer(snapDir, snap, s.key, items, s.index, s.collections, s.signature, nowSec&)
    end for
    NxSnapshotForgetServers(snapDir, snap, keys)
    ' What Settings' RESCAN LIBRARY row says the app holds, and since when.
    NxSaveLibraryHeld(NxLibraryCounts(items), nowSec&)
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
    ' A display that can't show Dolby Vision leaves profile 5 off every
    ' channel, from any server (#69, source/guide/DolbyVision.brs).
    if not NxDisplayShowsDolbyVision() then
        before = items.Count()
        items = NxOnChannelsForDisplay(items, false)
        if items.Count() < before then print "library: this display doesn't show Dolby Vision: "; before - items.Count(); " profile 5 item(s) left off channels"
    end if
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
    ' Which pool channels still need a fresh filter pass: a reuse miss, or
    ' every pool channel when there is no saved build to reuse at all. Each
    ' gets its channel compiled once; NxFilterPoolsByServer then filters them
    ' one server's items at a time (I-065: several large servers combined
    ' into one array and filtered as one crashed a Streaming Stick 4K about
    ' 30 minutes in; one server of about 1,000 files worked), so no more of
    ' the filter's per-item cache is ever resident than the largest enabled
    ' server needs, instead of the sum of every enabled server's.
    fresh = []
    for each def in config.channels
        if poolIds.DoesExist(def.id.ToStr()) then
            matched = invalid
            if reuse <> invalid then matched = reuse[def.id.ToStr()]
            if matched = invalid then
                if reuse <> invalid then print "library: filtering channel "; def.id; " (no earlier result to reuse)"
                fresh.Push({ id: def.id.ToStr(), compiled: NxFilterChannel(def) })
            end if
        end if
    end for
    m.top.progress = "Building channels…"
    pools = NxFilterPoolsByServer(items, fresh, manifest, exclusive, clock, backend, NxFilterTopProgress(m.top))
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
            matched = invalid
            if reuse <> invalid then matched = reuse[def.id.ToStr()]
            if matched = invalid then
                matched = pools[def.id.ToStr()]
                if matched = invalid then matched = []
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
    m.top.bar = -1
    m.top.barCaption = ""
    print "library: built "; built; " channels ("; reused; " kept from the last build) in "; timer.TotalMilliseconds(); " ms"
    setPhase("finishing")
    m.top.progress = ""

    ' FRANCHISES, as the Apple TV app has it (the web tuner doesn't call the
    ' builder): covered franchises join their classic's pool, and each found
    ' franchise switched on gets a channel from CH 300 that rides on the
    ' package's switch.
    franchiseRows = []
    franchiseOverCap = 0
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
        franchiseOverCap = fr.overCap
        print "library: franchises: "; fr.found.Count(); " found, "; foundIDs.Count(); " channels, "; fr.overCap; " past CH 449, in "; timer.TotalMilliseconds(); " ms"
    end if

    ' MY COLLECTIONS, read as the web tuner reads them and split as the Apple
    ' TV app splits them: a collection switched on airs outside every package,
    ' a movie series under FRANCHISES (CH 450-499) and the rest under OTHER
    ' COLLECTIONS (CH 500-699), whatever the found franchises do. One that is a
    ' franchise the package already carries folds into it instead.
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
    print "library: collections: "; cl.rows.Count(); " listed, "; cl.folded.Count(); " folded into franchises, "; collectionIDs.Count(); " channels, "; cl.overCapFranchises; " past CH 499, "; cl.overCapCustom; " past CH 699, in "; timer.TotalMilliseconds(); " ms"
    for each f in cl.folded
        print "library: collection "; f.title; " ("; f.items; " items) folds into "; f.into; " by "; f.why
    end for
    timer.Mark()

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
    print "library: ordered in "; timer.TotalMilliseconds(); " ms"
    fingerprint = NxPoolsFingerprint(ordered)
    print "library: pools fingerprint "; fingerprint; " ("; ordered.Count(); " channels)"
    timer.Mark()
    ' Pools the same as the guide on screen's, on the same local day: its
    ' schedules are what scheduling would give, so they stand. A launch matching its saved guide scheduled both days again,
    ' 13 to 14 s at 123 channels on a Streaming Stick Plus (Discussion #8).
    ' The schedule keeps the time it was made, so a new hour since is
    ' re-checked by keepScheduling as ever.
    old = m.shownGuide
    sameSchedule = false
    builtAt& = nowSec&
    if shown and old <> invalid and not m.shownOtherBuild then
        if NxToStr(old.poolsFingerprint) = fingerprint and type(old.channels) = "roArray" and NxIsNumber(old.builtAt) then
            oldAt& = old.builtAt
            sameSchedule = NxLocalDay(oldAt&).dayKey = NxLocalDay(nowSec&).dayKey
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
        franchises: franchiseRows, franchiseOverCap: franchiseOverCap, franchiseCapacity: NxFranchiseCapacity(),
        collections: { rows: cl.rows, overCap: cl.overCap, overCapFranchises: cl.overCapFranchises, overCapCustom: cl.overCapCustom,
            capacityFranchises: NxCollectionFranchiseCapacity(), capacityCustom: NxCollectionsCapacity(), scanned: collections.raw.Count(), failed: collections.failed }
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
    m.top.refreshed = true
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
    m.top.refreshed = true
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
            print "library: server "; s.index; "'s saved library is gone (dir has "; ListDir(snapDir).Count(); " files, saved guide "; fs.Exists(NxGuideCachePath()); ", pools "; fs.Exists(NxPoolCachePath()); ", enrichment cache "; fs.Exists(NxCacheRoot() + "/nostalgex-enrichment.json"); "); saving it again"
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

' SHA-1 of each guide channel's id and its pool's items, in library order,
' first 12 hex digits: a package built on its own must match a full build of
' the same packages. Item keys only; no titles or addresses.
function NxPoolsFingerprint(ordered as Object) as String
    d = CreateObject("roEVPDigest")
    d.Setup("sha1")
    for each ch in ordered
        keys = [NxToStr(ch.id)]
        for each it in ch.pool
            keys.Push(NxToStr(it.ratingKey) + "@" + NxToStr(it.serverIndex))
        end for
        b = CreateObject("roByteArray")
        b.FromAsciiString(keys.Join(",") + Chr(10))
        d.Update(b)
    end for
    return Left(d.Final(), 12)
end function

' NxScanServerFor under the stall watch: MainScene watches scanning and
' scanAnswers, and the server requests (NxServerWait) end early once it
' sets stopWaiting. info.stopped gets who stopped it ("viewer" or "stall"),
' or "". MainScene sets stopWaiting only while scanning is true.
function scanUnderWatch(server as Object, index as Integer, info as Object) as Dynamic
    m.top.stopWaiting = ""
    m.top.scanAnswers = 0
    m.nxLoadWatch = m.top
    m.top.scanning = true
    got = NxScanServerFor(server, index, m.top, info)
    info.stopped = m.top.stopWaiting
    m.nxLoadWatch = invalid
    m.top.scanning = false
    m.top.stopWaiting = ""
    return got
end function

' Progress on the loading screen while NxFilterPoolsByServer works through
' the enabled servers: one tick per server done, since I-065's fix moved the
' heavy per-item work there instead of once per channel.
function NxFilterTopProgress(top as Object) as Object
    return {
        top: top,
        report: sub(done as Integer, total as Integer)
            m.top.progress = "Building channels: server " + done.ToStr() + " of " + total.ToStr()
            if total > 0 then
                m.top.bar = done / total
                m.top.barCaption = "Server " + done.ToStr() + " of " + total.ToStr()
            end if
        end sub
    }
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
