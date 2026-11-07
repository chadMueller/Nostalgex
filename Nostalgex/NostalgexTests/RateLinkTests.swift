import XCTest
@testable import Nostalgex

/// The App Store link RATE opens, the DEBUG switch that picks one for a hardware test, the
/// open-result signals and the scroll hint (rating funnel, 2026-11-04).
final class RateLinkTests: XCTestCase {

    // MARK: - Links

    func testEveryVariantIsThisAppsAddress() {
        for v in AppStoreLink.RateLinkVariant.allCases {
            XCTAssertTrue(v.url.absoluteString.contains("6762563534"), "\(v.rawValue): \(v.url)")
        }
        XCTAssertEqual(AppStoreLink.RateLinkVariant.productPage.url.absoluteString,
                       "itms-apps://apps.apple.com/app/id6762563534")
        XCTAssertEqual(AppStoreLink.RateLinkVariant.httpsWriteReview.url.absoluteString,
                       "https://apps.apple.com/app/id6762563534?action=write-review")
    }

    func testTheShippedLinkIsTheProductPage() {
        // Measured on the living room Apple TV 2026-11-04: the write-review links (b, c, d)
        // land on the same page as (a), focus on the download button. The page is what ships.
        XCTAssertEqual(AppStoreLink.productPage.absoluteString, "itms-apps://apps.apple.com/app/id6762563534")
        XCTAssertEqual(AppStoreLink.RateLinkVariant.shipped, .productPage)
    }

    func testTheLaunchArgumentPicksAVariantByLetterOrPosition() {
        let arg = AppStoreLink.variantLaunchArgument
        XCTAssertEqual(AppStoreLink.variant(fromArguments: ["app", arg, "b"]), .itmsWriteReview)
        XCTAssertEqual(AppStoreLink.variant(fromArguments: ["app", arg, "C"]), .httpsWriteReview)
        XCTAssertEqual(AppStoreLink.variant(fromArguments: ["app", arg, "3"]), .legacyReviews)
        XCTAssertNil(AppStoreLink.variant(fromArguments: ["app", arg, "z"]))
        XCTAssertNil(AppStoreLink.variant(fromArguments: ["app", arg]))
        XCTAssertNil(AppStoreLink.variant(fromArguments: ["app"]))
    }

    // MARK: - Open-result signals

    func testBannerOpenCarriesAcceptedAndVariant() {
        let e = AnalyticsEvent.ratingNudgeOpened(accepted: true, variant: "a")
        XCTAssertEqual(e.name, "rating_nudge.opened")
        XCTAssertEqual(e.parameters, ["accepted": "true", "variant": "a"])
        XCTAssertNil(e.floatValue)
    }

    func testSettingsOpenCarriesAcceptedAndVariant() {
        let e = AnalyticsEvent.rateOpened(accepted: false, variant: "c")
        XCTAssertEqual(e.name, "rate.opened")
        XCTAssertEqual(e.parameters, ["accepted": "false", "variant": "c"])
    }

    func testBothOpenSignalsAreGatedLikeTheTaps() {
        let tap = AnalyticsGate.rule(for: "rate.tapped")
        XCTAssertNotNil(tap)
        for name in ["rate.opened", "rating_nudge.opened"] {
            let rule = AnalyticsGate.rule(for: name)
            XCTAssertEqual(rule?.identity, tap?.identity, name)
            XCTAssertEqual(rule?.limit, tap?.limit, name)
        }
    }

    // MARK: - Scroll hint

    func testTheScrollHintIsOnBecauseNoLinkLandsOnTheStars() {
        XCTAssertTrue(RatingNudgePolicy.showsScrollHint)
        XCTAssertEqual(RatingNudgePolicy.autoDismissSeconds, 12)
    }

    func testTheHintGivesTheBannerLongerOnScreen() {
        XCTAssertEqual(RatingNudgePolicy.autoDismissSeconds(hintShown: false), 8)
        XCTAssertEqual(RatingNudgePolicy.autoDismissSeconds(hintShown: true), 12)
        XCTAssertEqual(RatingNudgePolicy.autoDismissSeconds,
                       RatingNudgePolicy.autoDismissSeconds(hintShown: RatingNudgePolicy.showsScrollHint))
        XCTAssertEqual(RatingNudgePolicy.scrollHint, "Then scroll down to the stars")
    }

    func testTheThresholdsAreUnchanged() {
        XCTAssertEqual(RatingNudgePolicy.minimumSessionSeconds, 600)
        XCTAssertEqual(RatingNudgePolicy.requiredSessions, 3)
    }
}
