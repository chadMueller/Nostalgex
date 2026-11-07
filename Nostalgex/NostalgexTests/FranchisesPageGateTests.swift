import XCTest
@testable import Nostalgex

/// The FRANCHISES switch gates every franchise channel, franchise collections included
/// (since 1.0.29). The Settings FRANCHISES page still let a franchise collection be
/// switched while FRANCHISES was off, so it could read ON and not air.
///
/// Runs on the same sample library the UI tests use (demo mode plus the franchise
/// fixture), through the real switches: `toggleCollection` and `toggleBundle`.
@MainActor
final class FranchisesPageGateTests: XCTestCase {

    private let keys = [
        "nostalgex_enabled_collections", "nostalgex_enabled_bundles",
        AppState.enabledFranchisesKey, AppState.disabledFranchisesKey
    ]
    private var saved: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        let d = UserDefaults.standard
        for key in keys {
            if let v = d.object(forKey: key) { saved[key] = v }
            d.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        let d = UserDefaults.standard
        for key in keys {
            if let v = saved[key] { d.set(v, forKey: key) } else { d.removeObject(forKey: key) }
        }
        super.tearDown()
    }

    private func fixtureState() async -> AppState {
        let state = AppState()
        let demo = DemoData.channels()
        state.allChannels = demo
        state.channels = demo
        state.allItems = demo.flatMap(\.itemPool)
        await state.installFranchiseFixture()
        return state
    }

    private let cornettoID = "fx-col-cornetto"
    private let cornettoName = "THREE FLAVOURS CORNETTO"

    private func cornetto(_ state: AppState) throws -> DiscoveredCollection {
        try XCTUnwrap(state.discoveredCollections.first { $0.id == cornettoID })
    }

    private func franchisesBundle(_ state: AppState) throws -> ChannelBundle {
        try XCTUnwrap(state.bundles.first { $0.id == AppState.franchisesBundleID })
    }

    private func airs(_ state: AppState) -> Bool {
        state.channels.contains { $0.name == cornettoName }
    }

    /// Off, a franchise collection does not air and keeps its own switch; on again, it
    /// airs exactly as it was set.
    func testFranchisesOffKeepsTheCollectionChoiceAndItDoesNotAir() async throws {
        let state = await fixtureState()
        XCTAssertTrue(state.isFranchisesBundleOn)
        XCTAssertEqual(try cornetto(state).category, .franchises)
        XCTAssertTrue(state.visibleDiscoveredCollections.contains { $0.id == cornettoID },
                      "CORNETTO is listed on the FRANCHISES page")

        state.toggleCollection(try cornetto(state))
        print("FRANCHISES-GATE master=on  cornetto.enabled=\(try cornetto(state).enabled) airs=\(airs(state))")
        XCTAssertTrue(try cornetto(state).enabled)
        XCTAssertTrue(airs(state), "switched on with FRANCHISES on, it airs")

        state.toggleBundle(try franchisesBundle(state))
        print("FRANCHISES-GATE master=off cornetto.enabled=\(try cornetto(state).enabled) airs=\(airs(state))")
        XCTAssertFalse(state.isFranchisesBundleOn)
        XCTAssertTrue(try cornetto(state).enabled, "its own choice is kept while FRANCHISES is off")
        XCTAssertFalse(airs(state), "FRANCHISES off: no franchise collection airs")
        XCTAssertTrue(UserDefaults.standard.stringArray(forKey: "nostalgex_enabled_collections")?
            .contains(cornettoID) == true, "the saved choice survives")

        state.toggleBundle(try franchisesBundle(state))
        print("FRANCHISES-GATE master=on  cornetto.enabled=\(try cornetto(state).enabled) airs=\(airs(state))")
        XCTAssertTrue(airs(state), "FRANCHISES on again: it airs as it was set")

        // A collection left off stays off through the round trip.
        let wick = try XCTUnwrap(state.discoveredCollections.first { $0.id == "fx-col-wick" })
        XCTAssertFalse(wick.enabled)
    }

    /// What the page shows follows what airs: with FRANCHISES off a collection set on
    /// reads OFF, can't be selected, and the Channels list reads OFF for FRANCHISES.
    func testThePageNeverReadsOnForACollectionThatDoesNotAir() async throws {
        let state = await fixtureState()
        state.toggleCollection(try cornetto(state))
        let collections = state.visibleDiscoveredCollections.filter { $0.category == .franchises }

        // On: reads ON, selectable, counted.
        XCTAssertTrue(FranchisesPageGate.collectionReadsOn(try cornetto(state), franchisesOn: state.isFranchisesBundleOn))
        XCTAssertTrue(FranchisesPageGate.collectionSelectable(franchisesOn: state.isFranchisesBundleOn))
        XCTAssertEqual(FranchisesPageGate.onCount(franchisesOn: true, franchiseRowsOn: 0, collections: collections), 1)

        state.toggleBundle(try franchisesBundle(state))
        let off = state.isFranchisesBundleOn
        XCTAssertFalse(off)
        // For every franchise collection the page lists, ON on the page means on the air.
        for collection in state.visibleDiscoveredCollections where collection.category == .franchises {
            let readsOn = FranchisesPageGate.collectionReadsOn(collection, franchisesOn: off)
            let airs = state.channels.contains { $0.name == collection.title }
            XCTAssertEqual(readsOn, airs, "\(collection.title): reads \(readsOn ? "ON" : "OFF"), airs \(airs)")
        }
        XCTAssertFalse(FranchisesPageGate.collectionSelectable(franchisesOn: off))
        XCTAssertEqual(FranchisesPageGate.onCount(franchisesOn: off, franchiseRowsOn: 0, collections: collections), 0)
        XCTAssertTrue(try cornetto(state).enabled, "the choice under the grey row is kept")

        // On again: ON on the page and on the air, as it was set.
        state.toggleBundle(try franchisesBundle(state))
        XCTAssertTrue(FranchisesPageGate.collectionReadsOn(try cornetto(state), franchisesOn: state.isFranchisesBundleOn))
        XCTAssertTrue(airs(state))
    }

    func testOffNoteIsPlainCopy() {
        let note = FranchisesPageGate.offNote
        XCTAssertTrue(note.contains("FRANCHISES"))
        XCTAssertFalse(note.contains("\u{2014}"), "no em dash")
        XCTAssertFalse(note.contains("\u{2013}"), "no en dash")
    }
}
