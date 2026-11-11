import XCTest
@testable import Nostalgex

/// The launch after a snapshot restore refilters every channel with the enrichment cache, and that used to hold the
/// main actor for 9 to 14 s. The filter pass and the franchise builder now run in a background task and are applied on
/// the main actor in one step. This holds that the result is the same as the synchronous one: same channels, same
/// pools in the same order, same guide order, same found franchises, for several bundle sets.
@MainActor
final class EnrichedRefilterOffMainTests: XCTestCase {

    private struct Outcome: Equatable {
        let allChannels: [String]
        let guide: [Int]
        let franchises: [String]
    }

    private static func fixture() -> (items: [PlexMediaItem], enrichments: [MediaEnrichment]) {
        let movies = MovieLibraryScaleHarness.makeMovieLibrary(count: 600, serverID: "refilter-fixture")
        let episodes = Array(BigLibraryHarness.makeLibrary(count: 1_500, serverID: "refilter-fixture").items
            .filter { $0.type == .episode }.prefix(900))
        return (movies.items + episodes, movies.enrichments)
    }

    private func makeState(items: [PlexMediaItem], enrichments: [MediaEnrichment], enabled: Set<String>) -> AppState {
        let state = AppState()
        let config = ChannelConfigLoader.loadBundled()
        state.allItems = items
        state.channelConfigChannels = config.channels
        state.exclusiveRules = config.exclusiveRules
        state.bundles = config.bundles.map { $0.toChannelBundle(enabled: enabled.contains($0.id)) }
        state.enabledBundleIDs = enabled
        state.enrichmentService.seedCache(enrichments)
        return state
    }

    private func outcome(_ state: AppState) -> Outcome {
        Outcome(
            allChannels: state.allChannels.map { "\($0.id):\($0.itemPool.map(\.id).joined(separator: ","))" },
            guide: state.channels.map(\.id),
            franchises: state.foundFranchises.map { "\($0.id):\($0.name):\($0.items.map(\.id).joined(separator: ","))" })
    }

    func testTheOffMainResultEqualsTheSynchronousOneForSeveralBundleSets() async throws {
        let scope = HarnessScope.begin("refilter-offmain")
        defer { scope.end() }
        let fx = Self.fixture()
        let allIDs = Set(ChannelConfigLoader.loadBundled().bundles.map(\.id))
        let someIDs = Set(ChannelConfigLoader.loadBundled().bundles.prefix(3).map(\.id))
        for (label, enabled) in [("every bundle", allIDs), ("the first three", someIDs), ("the app's default", Set(["nostalgex"]))] {
            let sync = makeState(items: fx.items, enrichments: fx.enrichments, enabled: enabled)
            sync.refilterChannelsWithEnrichment()
            sync.rebuildFoundFranchises()
            sync.materializeDynamicChannels()
            sync.applyBundleFilter()

            let off = makeState(items: fx.items, enrichments: fx.enrichments, enabled: enabled)
            let applied = await off.refilterChannelsWithEnrichmentOffMain()
            await off.rebuildFoundFranchisesOffMain()
            off.materializeDynamicChannels()
            off.applyBundleFilter()

            XCTAssertTrue(applied, "\(label): the result was applied")
            XCTAssertFalse(sync.allChannels.isEmpty, "\(label): the fixture builds channels")
            XCTAssertEqual(outcome(off), outcome(sync), "\(label): the off-main result is the synchronous one")
        }
    }

    /// A result computed while the lineup changes under it is thrown away and the pass runs again, so the lineup
    /// that lands is the one for the bundles that are on now.
    func testAResultMadeStaleByABundleSwitchIsRecomputed() async throws {
        let scope = HarnessScope.begin("refilter-offmain-stale")
        defer { scope.end() }
        let fx = Self.fixture()
        let one = Set(["nostalgex"])
        let state = makeState(items: fx.items, enrichments: fx.enrichments, enabled: one)
        let task = Task { await state.refilterChannelsWithEnrichmentOffMain() }
        // The switch lands while the first attempt's pools are being built (the build is off the main actor, so this
        // runs in the gap). Whatever the timing, the lineup that ends up applied is the one for both bundles.
        await Task.yield()
        let both = one.union(["kids"])
        state.enabledBundleIDs = both
        for i in state.bundles.indices { state.bundles[i].enabled = both.contains(state.bundles[i].id) }
        _ = await task.value

        let expected = makeState(items: fx.items, enrichments: fx.enrichments, enabled: both)
        expected.refilterChannelsWithEnrichment()
        XCTAssertEqual(outcome(state).allChannels, outcome(expected).allChannels)
    }
}
