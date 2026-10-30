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
    val ref = ScheduleChannel(def.id, def.isPremiereChannel)
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
) {
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
    fun build(items: List<MediaItem>, enabledBundles: Set<String>, onProgress: (Int, Int) -> Unit = { _, _ -> }): Set<String> {
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
        channels = select(bundles)
        return bundles - enabledBundles
    }

    /**
     * The lineup for a new set of packages, as rebuildLineupAfterBundleChange: a package switched
     * on filters only the channels not built yet; one switched off just leaves the guide.
     */
    fun setBundles(enabledBundles: Set<String>) {
        val o = opts ?: return
        val missing = bundleChannelIds(enabledBundles).filter { !pools.containsKey(it) }.toSet()
        filter(items, config.channels.filter { it.id in missing }, o, pools) { _, _ -> }
        channels = select(enabledBundles)
    }

    /** Settings' line for a package: each channel's name and whether the library fills it (bundleChannelAvailability). */
    fun availability(bundle: ChannelConfig.Bundle): List<Pair<String, Boolean>> {
        val available = availableIds()
        val defs = config.channels.associateBy { it.id }
        return bundle.channelIDs.mapNotNull { id -> defs[id]?.let { it.name to (id in available) } }
    }

    /** The package sidebar's rows: each package on, and the first of its channels in the guide (bundleJumpTargets). */
    fun jumpTargets(enabledBundles: Set<String>): List<Pair<ChannelConfig.Bundle, GuideChannel>> {
        val byId = channels.associateBy { it.id }
        return config.bundles.filter { it.id in enabledBundles }.mapNotNull { b ->
            b.channelIDs.firstNotNullOfOrNull { byId[it] }?.let { b to it }
        }
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
        val picked = config.channels.filter { it.id in ids && it.id in available }
        return (picked.filter { it.id in rank }.sortedBy { rank.getValue(it.id) } + picked.filter { it.id !in rank }.sortedBy { it.number })
            .map { GuideChannel(it, pools.getValue(it.id).filter { item -> item.duration > 0 }) }
    }

    /** Watershed (Settings > SCHEDULE): read at every schedule, tune and next programme. */
    @Volatile var watershed = false

    private fun poolNow(ch: GuideChannel, now: ZonedDateTime) = config.timeFilteredPool(ch.def, ch.pool, now.hour, watershed)

    /** Off the air until 9 PM because Watershed emptied it, not because it has nothing. */
    fun isWatershedHold(ch: GuideChannel, now: ZonedDateTime = ZonedDateTime.now()) =
        config.isWatershedHold(ch.def, ch.pool, now.hour, watershed)

    private fun lineupNow(now: ZonedDateTime) = channels.map { it.ref to poolNow(it, now) }

    private fun ZonedDateTime.sec() = toInstant().toEpochMilli() / 1000.0

    /** TunerView.buildAllSchedules: every channel at one instant, then conflicts resolved. */
    fun rebuildSchedules(now: ZonedDateTime = ZonedDateTime.now()) {
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

    /** What tuning in plays, and from where. */
    fun tune(ch: GuideChannel, now: ZonedDateTime = ZonedDateTime.now()): Pick? {
        val pool = poolNow(ch, now)
        return engine.tuneIn(ch.ref, pool, schedules[ch.id], now.sec(), serverKey)
            ?: pool.randomOrNull()?.let { Pick(it, 0) }
    }

    /** What plays when a programme ends (naturally, or after a failure: from where it is now). */
    fun next(ch: GuideChannel, ended: MediaItem?, fromNaturalEnd: Boolean, now: ZonedDateTime = ZonedDateTime.now()): Pick? {
        val pool = poolNow(ch, now)
        return engine.advancePick(ch.ref, pool, ended?.ratingKey, now.sec(), lineupNow(now), serverKey, fromNaturalEnd)
            ?: pool.randomOrNull()?.let { Pick(it, 0) }
    }
}
