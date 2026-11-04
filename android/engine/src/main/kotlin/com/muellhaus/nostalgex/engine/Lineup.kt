package com.muellhaus.nostalgex.engine

import kotlinx.serialization.json.JsonObject
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import java.time.LocalDateTime
import java.time.ZonedDateTime

/** A channel in the guide: its definition from channels.json and the pool it airs from. */
class GuideChannel(val def: ChannelConfig.StockChannel, val pool: List<MediaItem>) {
    val id get() = def.id
    val number get() = def.number
    val name get() = def.name
    /** Gated: its pool changes with the hour (timeRestrictions), so it packs after the rest of the lineup. */
    val ref = ScheduleChannel(def.id, def.isPremiereChannel, def.timeRestrictions != null)
}

/**
 * The library turned into channels, and what each airs: plex-tuner.html's
 * repopulateChannelsFromLibrary, applyBundleFilter, autoEnableBundlesWithContent,
 * rebuildAllSchedules and nextAfterEnd, over the engine.
 */
class Lineup(
    private val config: ChannelConfig,
    private val memberships: JsonObject?,
    private val engine: DailyManifest,
    private val serverKey: String,
    /** "plex", "jellyfin" or "emby": Emby leaves Dolby Vision profile 5 off channels (isLeftOffChannels). */
    private val backend: String = "plex",
    /** franchises.json, for the found franchises and the fold. Empty: no franchise is found. */
    private val franchiseDefinitions: List<FranchiseDefinition> = emptyList(),
) {
    /** The viewer's franchise and collection switches (Prefs), by stable id and collection id. */
    data class FranchiseChoices(
        val enabledFranchises: Set<String> = emptySet(),
        val disabledFranchises: Set<String> = emptySet(),
        val enabledCollections: Set<String> = emptySet(),
    )

    @Volatile var franchiseChoices = FranchiseChoices()

    /** The server's collections, read with the library. */
    private var collections: List<ServerCollection> = emptyList()

    /** The FRANCHISES package and the server collections at the last build (FranchiseLineup.build). */
    var franchises: FranchiseLineup.Result? = null
        private set

    /** The classics' pools as their rules built them, before what the franchises add. */
    private val rulePools = HashMap<Int, List<MediaItem>>()

    /** Runtime channels: found franchises and server collections, CH 310-499. */
    private var runtime: List<GuideChannel> = emptyList()

    /** The pools built at the last library load: the chosen packages' channels, or every channel if those filled nothing. */
    private val pools = ConcurrentHashMap<Int, List<MediaItem>>()
    /** The library and filter options of the last build, so switching a package on filters only its channels. */
    private var items: List<MediaItem> = emptyList()
    private var opts: ChannelFilter.Options? = null

    var channels: List<GuideChannel> = emptyList()
        private set

    /** How long the last build spent on per-item facts, before any channel was filtered. */
    var prepareMs = 0L
        private set

    /** Each channel's guide at the last rebuild, after one title on two channels was resolved. */
    var schedules: Map<Int, Schedule> = emptyMap()
        private set

    /** The half hour the last rebuild's guide window starts at (ChannelScheduleBuilder.windowStart), unix seconds. */
    var windowStartSec: Long = 0
        private set

    /**
     * Filters the chosen packages' channels, and every other channel only when those fill
     * nothing, as the web tuner builds every channel only on a first load
     * (staticChannelIDsForPoolBuild). Channels are filtered in parallel. Returns the packages it
     * switched on, if none of the chosen ones had content.
     */
    fun build(
        items: List<MediaItem>,
        enabledBundles: Set<String>,
        collections: List<ServerCollection> = emptyList(),
        onProgress: (Int, Int) -> Unit = { _, _ -> },
    ): Set<String> {
        this.collections = collections
        val t0 = System.nanoTime()
        val opts = ChannelFilter.Options(memberships, config.exclusiveRules, backend).also { it.prepare(items) }
        prepareMs = (System.nanoTime() - t0) / 1_000_000
        this.items = items
        this.opts = opts
        pools.clear()
        val chosen = bundleChannelIds(enabledBundles)
        filter(items, config.channels.filter { it.id in chosen }, opts, pools, onProgress)

        var bundles = enabledBundles
        if (select(bundles).isEmpty()) {
            filter(items, config.channels.filter { !pools.containsKey(it.id) }, opts, pools, onProgress)
            // NostalgexLibraryLoad.bundlesToAutoEnable: every package with content that isn't seasonal.
            val available = availableIds()
            val extra = config.bundles.filter { b ->
                !b.id.startsWith("collections-") && b.activeMonths == null && b.id !in bundles && b.channelIDs.any { it in available }
            }.map { it.id }
            bundles = bundles + extra
        }
        applyFranchises(bundles)
        channels = select(bundles)
        return bundles - enabledBundles
    }

    /**
     * Demo mode: these channels and nothing else, with no library and no filtering
     * (enterDemoMode's `channels = DemoData.channels()`). Schedules, tuning and the next
     * programme work as for any lineup. Packages don't apply: [setBundles] leaves it as it is.
     */
    fun airFixed(fixed: List<GuideChannel>) {
        channels = fixed
    }

    private fun franchiseBundle() = config.bundles.firstOrNull { it.id == FRANCHISES_BUNDLE }

    /**
     * rebuildFoundFranchises, applyFranchiseFolds and materializeDynamicChannels together
     * (FranchiseLineup.build): the found franchises, what each classic gains, which server
     * collections fold away, and the runtime channels. Rerun when a franchise or collection
     * switch changes; the rule-built pools are kept, so nothing is filtered again.
     */
    private fun applyFranchises(bundles: Set<String>) {
        val o = opts ?: return
        val classicIds = franchiseBundle()?.channelIDs ?: emptyList()
        // The classics' rule pools, filtered once even with the package off (Settings counts them).
        val missing = config.channels.filter { it.id in classicIds && !pools.containsKey(it.id) }
        if (missing.isNotEmpty()) filter(items, missing, o, pools) { _, _ -> }
        for (id in classicIds) rulePools.getOrPut(id) { pools[id] ?: emptyList() }
        val defs = config.channels.associateBy { it.id }
        val stock = classicIds.mapNotNull { id ->
            val def = defs[id] ?: return@mapNotNull null
            val pool = rulePools[id] ?: emptyList()
            if (pool.size < def.minItems) null else FranchiseLineup.Stock(id, def.number, def.name, pool)
        }
        val staticChannels = config.channels.mapNotNull { def ->
            val pool = (if (def.id in rulePools) rulePools[def.id] else pools[def.id]) ?: return@mapNotNull null
            if (pool.size < def.minItems) null else Collections.StockChannel(def.id, def.number, def.name, pool)
        }
        val eligible = items.filterNot { ChannelFilter.isLeftOffChannels(it, backend) }
        val c = franchiseChoices
        val result = FranchiseLineup.build(
            franchiseDefinitions, FRANCHISES_BUNDLE in bundles, c.enabledFranchises, c.disabledFranchises,
            eligible, stock, classicIds, memberships, config.exclusiveRules,
            FranchiseLineup.CollectionInput(collections, Collections.indexLibrary(eligible) { it.serverUrl ?: "" }, staticChannels, c.enabledCollections),
        )
        franchises = result
        for (id in classicIds) pools[id] = (rulePools[id] ?: emptyList()) + (result.stockAdditions[id] ?: emptyList())
        runtime = result.channels.map { ch ->
            GuideChannel(
                ChannelConfig.StockChannel(ch.id, ch.number, ch.name, ch.colorHex, ch.category.wire, ch.minItems, null, null, false),
                ch.itemPool.filter { it.duration > 0 },
            )
        }
    }

    /** A franchise or collection switch: the franchise step again, then the guide. */
    fun setFranchiseChoices(choices: FranchiseChoices, enabledBundles: Set<String>) {
        franchiseChoices = choices
        applyFranchises(enabledBundles)
        channels = select(enabledBundles)
    }

    /**
     * The lineup for a new set of packages, as rebuildLineupAfterBundleChange: a package switched
     * on filters only the channels not built yet; one switched off just leaves the guide.
     */
    fun setBundles(enabledBundles: Set<String>) {
        val o = opts ?: return
        val missing = bundleChannelIds(enabledBundles).filter { !pools.containsKey(it) }.toSet()
        filter(items, config.channels.filter { it.id in missing }, o, pools) { _, _ -> }
        applyFranchises(enabledBundles)
        channels = select(enabledBundles)
    }

    /** Settings' line for a package: each channel's name and whether the library fills it (bundleChannelAvailability). */
    fun availability(bundle: ChannelConfig.Bundle): List<Pair<String, Boolean>> {
        val available = availableIds()
        val defs = config.channels.associateBy { it.id }
        return bundle.channelIDs.mapNotNull { id -> defs[id]?.let { it.name to (id in available) } }
    }

    /** A channel the library doesn't fill: its definition, and how many titles match its rules now. */
    data class OffAir(val def: ChannelConfig.StockChannel, val matched: Int)

    /**
     * WHY AREN'T THESE ON AIR? (I-004): a package's channels that didn't fill, rule-based ones
     * only (a channel with no rules has nothing to explain). The count is the pool the last
     * build filtered, the same pass that decided the channel, so it can't drift from it.
     */
    fun offAir(bundle: ChannelConfig.Bundle): List<OffAir> {
        val available = availableIds()
        val defs = config.channels.associateBy { it.id }
        return bundle.channelIDs.filter { it !in available }.mapNotNull { id ->
            defs[id]?.takeIf { it.rules != null }?.let { OffAir(it, pools[id]?.size ?: 0) }
        }
    }

    /**
     * The package sidebar's rows (bundleJumpTargets): each package on, at the earliest of its
     * channels in the guide, in guide order, so a seasonal package leading the guide leads here.
     */
    fun jumpTargets(enabledBundles: Set<String>): List<Pair<ChannelConfig.Bundle, GuideChannel>> {
        val position = HashMap<Int, Int>()
        channels.forEachIndexed { i, ch -> position.putIfAbsent(ch.id, i) }
        // FRANCHISES is one entry for the classics, found franchises and franchise collections;
        // the other collections get OTHER COLLECTIONS (bundleJumpTargets).
        val franchiseIds = runtime.filter { it.def.category == CollectionCategory.FRANCHISES.wire }.map { it.id }
        val otherIds = runtime.filter { it.def.category != CollectionCategory.FRANCHISES.wire }.map { it.id }
        val bundles = config.bundles.map { b -> if (b.id == FRANCHISES_BUNDLE) b.copy(channelIDs = b.channelIDs + franchiseIds) else b } +
            listOfNotNull(if (otherIds.isEmpty()) null else ChannelConfig.Bundle(OTHER_COLLECTIONS_BUNDLE, "OTHER COLLECTIONS", otherIds, null))
        return bundles.filter { it.id in enabledBundles || it.id == OTHER_COLLECTIONS_BUNDLE }
            .mapNotNull { b -> b.channelIDs.mapNotNull { position[it] }.minOrNull()?.let { at -> Triple(b, channels[at], at) } }
            .sortedBy { it.third }
            .map { it.first to it.second }
    }

    private fun filter(
        items: List<MediaItem>,
        defs: List<ChannelConfig.StockChannel>,
        opts: ChannelFilter.Options,
        into: MutableMap<Int, List<MediaItem>>,
        onProgress: (Int, Int) -> Unit,
    ) {
        val done = AtomicInteger()
        defs.parallelStream().forEach { def ->
            into[def.id] = ChannelFilter.filterPool(items, ChannelFilter.Channel(def.id, def.rules, def.category), opts)
            onProgress(done.incrementAndGet(), defs.size)
        }
    }

    private fun bundleChannelIds(bundles: Set<String>) = config.bundles.filter { it.id in bundles }.flatMap { it.channelIDs }.toSet()

    private fun availableIds() = config.channels.filter { (pools[it.id]?.size ?: 0) >= it.minItems }.map { it.id }.toSet()

    private fun select(bundles: Set<String>, now: LocalDateTime = LocalDateTime.now()): List<GuideChannel> {
        val ids = bundleChannelIds(bundles)
        val available = availableIds()
        // GuideChannelOrder: the channels of every seasonal package on and in season lead, in
        // package order; the rest by number (seasonalLeadIDs, sortChannelsForGuide).
        val lead = config.bundles.filter { Season.isSeasonal(it) && it.id in bundles && Season.isInSeason(it, now) }
            .flatMap { it.channelIDs }.distinct()
        val rank = lead.withIndex().associate { (i, id) -> id to i }
        // A classic switched off in the franchise list leaves the guide on its own (applyBundleFilter).
        val packageOn = FRANCHISES_BUNDLE in bundles
        val classicIds = franchiseBundle()?.channelIDs ?: emptyList()
        val switchedOff = franchises?.switchedOffStock ?: emptySet()
        val picked = config.channels.filter { it.id in ids && it.id in available }
            .filter { FranchiseLineup.stockVisible(it.id, packageOn, classicIds, switchedOff) }
            .map { GuideChannel(it, pools.getValue(it.id).filter { item -> item.duration > 0 }) }
        // Found franchises and franchise collections go with the package; other collections air when switched on.
        val dynamic = runtime.filter { it.def.category != CollectionCategory.FRANCHISES.wire || packageOn }
        val rest = (picked.filter { it.id !in rank } + dynamic).sortedBy { it.number }
        return picked.filter { it.id in rank }.sortedBy { rank.getValue(it.id) } + rest
    }

    /** Watershed (Settings > SCHEDULE): read at every schedule, tune and next programme. */
    @Volatile var watershed = false

    private fun poolNow(ch: GuideChannel, now: ZonedDateTime) = config.timeFilteredPool(ch.def, ch.pool, now.hour, watershed)

    /** Off the air until 9 PM because Watershed emptied it, not because it has nothing. */
    fun isWatershedHold(ch: GuideChannel, now: ZonedDateTime = ZonedDateTime.now()) =
        config.isWatershedHold(ch.def, ch.pool, now.hour, watershed)

    private fun lineupNow(now: ZonedDateTime) = channels.map { it.ref to poolNow(it, now) }

    /** The instant the engine is being asked about, so the lineup's pools are read at the guide's hour. */
    @Volatile private var askedAt: ZonedDateTime = ZonedDateTime.now()

    init {
        // Each day is packed across the guide's channels with the pools they air from, so one
        // title is never on two of them at once (the web tuner's guideLineup, AppState.channels).
        engine.setLineup { lineupNow(askedAt) }
    }

    private fun ZonedDateTime.sec() = toInstant().toEpochMilli() / 1000.0

    /** TunerView.buildAllSchedules: every channel at one instant, then conflicts resolved. */
    fun rebuildSchedules(now: ZonedDateTime = ZonedDateTime.now()) {
        askedAt = now
        val nowSec = now.sec()
        val raw = LinkedHashMap<Int, Schedule>()
        for (ch in channels) {
            val pool = poolNow(ch, now)
            if (pool.isEmpty()) continue
            engine.buildSchedule(ch.ref, pool, nowSec, serverKey)?.let { raw[ch.id] = it }
        }
        schedules = engine.resolveConflicts(raw)
        windowStartSec = Math.floorDiv(now.toEpochSecond(), 1800L) * 1800
        engine.pruneManifests(serverKey, now.toInstant().toEpochMilli())
    }

    /**
     * Minutes of the guide's window where a title is on more than one channel, out of the
     * minutes scheduled, for the log (scripts/qa/cross-channel-duplicates.mjs measures the same).
     */
    fun doubledMinutes(): Pair<Long, Long> {
        class Span(val ch: Int, val s: Long, val e: Long)
        val byKey = HashMap<String, MutableList<Span>>()
        var total = 0L
        for ((ch, schedule) in schedules) for (e in schedule.entries) {
            total += e.endSec - e.startSec
            byKey.getOrPut(e.item.ratingKey) { ArrayList() }.add(Span(ch, e.startSec, e.endSec))
        }
        var doubled = 0L
        for (spans in byKey.values) for (i in spans.indices) for (j in 0 until i) {
            val a = spans[i]; val b = spans[j]
            if (a.ch != b.ch) doubled += maxOf(0L, minOf(a.e, b.e) - maxOf(a.s, b.s))
        }
        return doubled / 60 to total / 60
    }

    /** What tuning in plays, and from where. */
    fun tune(ch: GuideChannel, now: ZonedDateTime = ZonedDateTime.now()): Pick? {
        askedAt = now
        val pool = poolNow(ch, now)
        return engine.tuneIn(ch.ref, pool, schedules[ch.id], now.sec(), serverKey)
            ?: pool.randomOrNull()?.let { Pick(it, 0) }
    }

    /** What plays when a programme ends (naturally, or after a failure: from where it is now). */
    fun next(ch: GuideChannel, ended: MediaItem?, fromNaturalEnd: Boolean, now: ZonedDateTime = ZonedDateTime.now()): Pick? {
        askedAt = now
        val pool = poolNow(ch, now)
        return engine.advancePick(ch.ref, pool, ended?.ratingKey, now.sec(), lineupNow(now), serverKey, fromNaturalEnd)
            ?: pool.randomOrNull()?.let { Pick(it, 0) }
    }

    companion object {
        /** The stock FRANCHISES package (ids 100-106, CH 300-306); found franchises ride on its switch. */
        const val FRANCHISES_BUNDLE = "franchises"
        /** The sidebar's entry for the other collections (CollectionCategory.custom's bundle). */
        const val OTHER_COLLECTIONS_BUNDLE = "collections-custom"
    }
}
