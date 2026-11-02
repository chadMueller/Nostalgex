package com.muellhaus.nostalgex.engine

/**
 * Demo mode's channels: the Apple TV's DemoData.baseChannels, five sample channels with no
 * server behind them. Every channel plays one public sample stream ([STREAM_URL]); the titles,
 * years, genres and running times are what the guide shows.
 */
object DemoData {
    /** Apple's canonical HLS sample (bipbop), on Apple's own CDN, as the Apple TV's demo plays. */
    const val STREAM_URL = "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8"

    /** The sample's length, measured 600.0 s on the Apple TV (AppState.demoClipSeconds). */
    const val CLIP_SECONDS = 600L

    /** Where the clip seeks for a programme `offsetSec` in: the clock's position, modulo the clip (playerSeekSeconds). */
    fun clipOffset(offsetSec: Long) = Math.floorMod(offsetSec, CLIP_SECONDS)

    /** The manifests' key, apart from every real server's. */
    const val SERVER_KEY = "demo"

    private fun movie(id: String, title: String, year: Int, genre: String, duration: Int) = MediaItem(
        ratingKey = id, title = title, type = "movie", duration = duration, summary = "Sample content for demo mode.",
        year = year, contentRating = "PG-13", genres = listOf(genre), rating = 7.5, studio = "Nostalgex Demo",
        addedAt = System.currentTimeMillis() / 1000,
    )

    private fun episode(id: String, show: String, se: String, year: Int, duration: Int) = MediaItem(
        ratingKey = id, title = show, type = "episode", duration = duration, episodeTitle = "Demo Episode", seTag = se,
        summary = "Sample episode for demo mode.", year = year, contentRating = "TV-PG", genres = listOf("Drama"),
        rating = 7.2, studio = "Nostalgex Demo", librarySource = "tv", addedAt = System.currentTimeMillis() / 1000,
    )

    private fun channel(id: Int, number: Int, name: String, colorHex: String, items: List<MediaItem>) =
        GuideChannel(ChannelConfig.StockChannel(id, number, name, colorHex, "demo", 0, null, null, false), items)

    fun channels(): List<GuideChannel> = listOf(
        channel(9001, 1, "DEMO ACTION", "#FF2244", listOf(
            movie("d-act-1", "Neon Strike", 1987, "Action", 102),
            movie("d-act-2", "Cobra Code", 1991, "Action", 96),
            movie("d-act-3", "Velocity 9", 1989, "Action", 110),
            movie("d-act-4", "Razor City", 1993, "Action", 105),
            movie("d-act-5", "Last Patrol", 1985, "Action", 98),
        )),
        channel(9002, 2, "DEMO COMEDY", "#FFD400", listOf(
            movie("d-com-1", "Tape Deck Heroes", 1988, "Comedy", 92),
            movie("d-com-2", "Mall Cops on Vacation", 1990, "Comedy", 89),
            movie("d-com-3", "Summer of Static", 1986, "Comedy", 95),
            movie("d-com-4", "Big Hair, Bigger Problems", 1992, "Comedy", 88),
            movie("d-com-5", "Boombox Brothers", 1989, "Comedy", 99),
        )),
        channel(9003, 3, "DEMO SCI-FI", "#00C4FF", listOf(
            movie("d-sci-1", "Quantum Drift", 1984, "Sci-Fi", 118),
            movie("d-sci-2", "Orbit Echo", 1992, "Sci-Fi", 124),
            movie("d-sci-3", "Signal from Vega", 1979, "Sci-Fi", 132),
            movie("d-sci-4", "The Replicant Trial", 1987, "Sci-Fi", 108),
            movie("d-sci-5", "Synthwave Frontier", 1990, "Sci-Fi", 101),
        )),
        channel(9004, 4, "DEMO 80s TV", "#FF66CC", listOf(
            episode("d-tv-1", "Late Shift Diner", "S01E01", 1986, 44),
            episode("d-tv-2", "Late Shift Diner", "S01E02", 1986, 44),
            episode("d-tv-3", "Beach Patrol PI", "S02E03", 1988, 47),
            episode("d-tv-4", "Beach Patrol PI", "S02E04", 1988, 46),
            episode("d-tv-5", "Garage Band USA", "S01E05", 1989, 42),
        )),
        channel(9005, 5, "DEMO LATE NIGHT", "#7C3AED", listOf(
            movie("d-ln-1", "Midnight Cassette", 1981, "Thriller", 96),
            movie("d-ln-2", "Static at 3 AM", 1984, "Horror", 84),
            movie("d-ln-3", "Channel Phantom", 1988, "Thriller", 101),
            movie("d-ln-4", "Drive-In Apparition", 1979, "Horror", 92),
            movie("d-ln-5", "VHS Witness", 1991, "Mystery", 97),
        )),
    )
}
