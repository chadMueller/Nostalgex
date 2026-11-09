import XCTest
@testable import Nostalgex

/// Jellyfin's `GET /UserViews` has an `includeHidden` parameter that defaults to false, and with it false
/// `UserViewManager.GetUserViews` drops every library in the user's `MyMediaExcludes` (the "Display on
/// home screen" box in Home settings), so a library the user hides there is never listed or scanned. Measured
/// on a lab Jellyfin 10.11.11, a user who hides two libraries and has no access to a third: the plain list
/// names 3 libraries and `includeHidden=true` names 5, the third in neither; an admin gets 6 both ways.
///
/// But a user hides a library on purpose (adult content, test or plugin folders), so a hidden library is
/// listed in LIBRARIES and left OFF until the viewer switches it on. The fake server answers the way Jellyfin
/// does: the hidden library is in the reply only when the request carries `includeHidden=true`. Emby's
/// list is a different request and is left alone.
final class JellyfinHiddenLibrariesTests: XCTestCase {

    private func movie(_ id: String) -> [String: Any] {
        ["Id": id, "Name": "Film \(id)", "Type": "Movie", "Genres": ["Drama"],
         "ProviderIds": ["Tmdb": "\(abs(id.hashValue % 900_000))"], "RunTimeTicks": Int64(5_400_000_000),
         "MediaSources": [["Id": "ms-\(id)", "Container": "mkv"]]]
    }

    /// `hiddenAnswers` false: a server where the user hides nothing. `failsHiddenList`: the
    /// includeHidden request answers 500, as a server that does not know the parameter might.
    private func reply(_ path: String, _ query: [String: String], hiddenLibrary: Bool = true,
                       failsHiddenList: Bool = false, secondAnswerDropsShown: Bool = false) -> LoopbackReply? {
        if path.hasSuffix("/UserViews") {
            var views: [[String: Any]] = [["Id": "shown", "Name": "Movies", "CollectionType": "movies"]]
            if query["includeHidden"] == "true" {
                if failsHiddenList { return nil }
                if hiddenLibrary { views.append(["Id": "hidden", "Name": "Plugin Films", "CollectionType": "movies"]) }
                if secondAnswerDropsShown { views.removeAll { ($0["Id"] as? String) == "shown" } }
            }
            return LoopbackReply(delayMs: 0, body: ["TotalRecordCount": views.count, "Items": views])
        }
        if path.hasSuffix("/Views") {   // Emby
            return LoopbackReply(delayMs: 0, body: ["TotalRecordCount": 1, "Items": [
                ["Id": "shown", "Name": "Movies", "CollectionType": "movies"]]])
        }
        guard path.hasSuffix("/Items") else { return nil }
        switch query["ParentId"] ?? "" {
        case "shown":
            let rows = (0..<4).map { movie("s\($0)") }
            return LoopbackReply(delayMs: 0, body: ["TotalRecordCount": rows.count, "Items": rows])
        case "hidden":
            let rows = (0..<3).map { movie("h\($0)") }
            return LoopbackReply(delayMs: 0, body: ["TotalRecordCount": rows.count, "Items": rows])
        default:
            return nil
        }
    }

    private func server(hiddenLibrary: Bool = true, failsHiddenList: Bool = false,
                        secondAnswerDropsShown: Bool = false) async throws -> LoopbackJSONServer {
        let server = try LoopbackJSONServer { [self] path, query in
            reply(path, query, hiddenLibrary: hiddenLibrary, failsHiddenList: failsHiddenList,
                  secondAnswerDropsShown: secondAnswerDropsShown)
        }
        try await server.start()
        return server
    }

    private func service(_ server: LoopbackJSONServer, included: Set<String> = [],
                         onByDefault: Bool = false) -> JellyfinAPIService {
        JellyfinAPIService(serverURL: server.url, accessToken: "t", userId: "user-1",
                           includedHiddenSectionKeys: included, hiddenSectionsOnByDefault: onByDefault)
    }

    // MARK: Listed, and marked

    func testAHiddenLibraryIsListedAndMarkedHidden() async throws {
        let server = try await server()
        defer { server.stop() }

        let sections = try await service(server).loadSections()
        XCTAssertEqual(sections.map(\.title), ["Movies", "Plugin Films"])
        XCTAssertEqual(sections.map(\.hidden), [false, true])

        let views = server.requests.filter { $0.path.hasSuffix("/UserViews") }
        XCTAssertEqual(views.count, 2, "the plain list, then the list with the hidden libraries")
        XCTAssertEqual(views.filter { $0.query["includeHidden"] == "true" }.count, 1)
        XCTAssertTrue(views.allSatisfy { $0.query["userId"] == "user-1" })
    }

    func testWithNothingHiddenNothingChanges() async throws {
        let server = try await server(hiddenLibrary: false)
        defer { server.stop() }
        let api = service(server)

        let sections = try await api.loadSections()
        XCTAssertEqual(sections.map(\.title), ["Movies"])
        XCTAssertEqual(sections.map(\.hidden), [false])
        let items = try await api.loadLibrary(excludedSectionKeys: [], progress: nil)
        XCTAssertEqual(items.count, 4)
    }

    /// The two answers are merged: a second one that comes back smaller cannot take a library off the list.
    func testASmallerSecondAnswerCannotTakeALibraryOffTheList() async throws {
        let server = try await server(secondAnswerDropsShown: true)
        defer { server.stop() }

        let sections = try await service(server).loadSections()
        XCTAssertEqual(Set(sections.map(\.title)), ["Movies", "Plugin Films"])
        XCTAssertEqual(sections.first { $0.title == "Movies" }?.hidden, false)
        XCTAssertEqual(sections.first { $0.title == "Plugin Films" }?.hidden, true)
    }

    func testIfTheHiddenListFailsTheAnswerIsTheListItAlwaysWas() async throws {
        let server = try await server(failsHiddenList: true)
        defer { server.stop() }

        let sections = try await service(server).loadSections()
        XCTAssertEqual(sections.map(\.title), ["Movies"])
        XCTAssertEqual(sections.map(\.hidden), [false])
    }

    // MARK: Off by default, on when the viewer says so

    /// Hiding a library was a choice made on the server; its titles do not start airing by surprise.
    func testAHiddenLibraryIsNotScannedUntilTheViewerSwitchesItOn() async throws {
        let server = try await server()
        defer { server.stop() }

        let items = try await service(server).loadLibrary(excludedSectionKeys: [], progress: nil)
        XCTAssertEqual(items.count, 4, "only the library on the home screen")
        XCTAssertFalse(server.requests.contains { $0.query["ParentId"] == "hidden" }, "never fetched")
    }

    func testASwitchedOnHiddenLibraryIsScanned() async throws {
        let server = try await server()
        defer { server.stop() }

        let items = try await service(server, included: ["hidden"]).loadLibrary(excludedSectionKeys: [], progress: nil)
        XCTAssertEqual(items.count, 7, "four from the library in My Media, three from the hidden one")
    }

    /// The one constant that decides the default: with it on, a hidden library is scanned like any other.
    func testWithTheDefaultOnAHiddenLibraryIsScannedAndCanStillBeSwitchedOff() async throws {
        let server = try await server()
        defer { server.stop() }

        let on = try await service(server, onByDefault: true).loadLibrary(excludedSectionKeys: [], progress: nil)
        XCTAssertEqual(on.count, 7)
        let off = try await service(server, onByDefault: true).loadLibrary(excludedSectionKeys: ["hidden"], progress: nil)
        XCTAssertEqual(off.count, 4)
    }

    /// The one assertion that pins the shipped default (the other tests set a position or read the
    /// constant). Flipping `hiddenSectionsOnByDefault` is one line plus this one.
    func testTheShippedDefaultIsOff() {
        XCTAssertFalse(LibrarySectionSelectionStore.hiddenSectionsOnByDefault)
        XCTAssertEqual(JellyfinAPIService(serverURL: "http://x", accessToken: "t", userId: "u").hiddenSectionsOnByDefault,
                       LibrarySectionSelectionStore.hiddenSectionsOnByDefault)
    }

    /// The viewer's own library selection still applies to a hidden library they switched on.
    func testASwitchedOnHiddenLibraryCanStillBeExcluded() async throws {
        let server = try await server()
        defer { server.stop() }

        let items = try await service(server, included: ["hidden"]).loadLibrary(excludedSectionKeys: ["hidden"], progress: nil)
        XCTAssertEqual(items.count, 4)
    }

    // MARK: Emby

    func testEmbysLibraryListIsNotChanged() async throws {
        let server = try await server()
        defer { server.stop() }
        let api = EmbyAPIService(serverURL: server.url, accessToken: "t", userId: "user-1")

        _ = try await api.loadSections()
        let hits = server.requests.filter { $0.path.hasSuffix("/Views") }
        XCTAssertEqual(hits.count, 1, "one request, as before")
        XCTAssertEqual(hits[0].path, "/Users/user-1/Views")
        XCTAssertTrue(hits[0].query.isEmpty, "Emby is asked exactly what it was asked before")
    }
}
