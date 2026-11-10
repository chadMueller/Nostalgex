import XCTest
@testable import Nostalgex

/// ABOUT > LINKS (1.0.32): every link a viewer can use today, as an address to read.
final class AboutLinksTests: XCTestCase {

    func testTheLinksAreThese() {
        XCTAssertEqual(AboutLinks.all.map(\.title),
                       ["DISCORD", "WEBSITE", "WEB TUNER", "ROKU", "GITHUB"])
        XCTAssertEqual(AboutLinks.all.map(\.address), [
            "discord.gg/FgnZcr5bDT",
            "nostalgex.app",
            "nostalgex.app/web-tuner",
            "my.roku.com/account/add/NOSTALGEX",
            "github.com/chadMueller/Nostalgex",
        ])
    }

    func testRokuShowsItsChannelCode() {
        XCTAssertTrue(AboutLinks.roku.subtitle.contains("NOSTALGEX"))
    }

    func testNothingUnreleasedIsListed() {
        let text = AboutLinks.all.map { "\($0.title) \($0.subtitle) \($0.address)" }.joined(separator: " ").lowercased()
        XCTAssertFalse(text.contains("android"))
        XCTAssertFalse(text.contains("coming"))
        XCTAssertFalse(text.contains("soon"))
    }

    func testRowIDsAreUniqueAndKeepTheOldGithubID() {
        let ids = AboutLinks.all.map(\.rowID)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(AboutLinks.github.rowID, "about_github")
        XCTAssertFalse(ids.contains("about_version"))
    }

    func testAddressesAreBareAndCopyHasNoEmDashes() {
        for link in AboutLinks.all {
            XCTAssertFalse(link.address.contains("://"), link.address)
            XCTAssertFalse((link.title + link.subtitle).contains("\u{2014}"), link.title)
        }
    }
}
