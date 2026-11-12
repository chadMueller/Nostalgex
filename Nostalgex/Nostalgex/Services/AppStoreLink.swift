import Foundation
import SwiftUI

/// Apple TV App Store URLs for Nostalgex (tvOS supports star ratings only, no written reviews).
///
/// Measured 2026-11-04 (TelemetryDeck, 30 days): the nudge showed to 152 people, 20 pressed
/// RATE on it and 30 more pressed RATE in Settings, and the App Store had zero ratings. On an
/// Apple TV the product page opens with focus on the download button and the stars below
/// the fold. `RateLinkVariant` holds the candidate links; a DEBUG launch argument picks one
/// so each can be pressed on a real Apple TV. The shipped link is `RateLinkVariant.shipped`.
///
/// Pressed on the living room Apple TV 4K (tvOS, Debug 1.0.29 (53)) the same day:
/// b, c and d were all accepted by tvOS (`accepted=true`) and all landed on the product page
/// with focus on the download button, no stars in view. Same page as (a), so the shipped
/// link is (a) and the banner and the Settings tile say "Then scroll down to the stars".
/// (e) was not tried: Apple documents nothing for tvOS beyond `action=write-review`.
enum AppStoreLink {
    static let appID = "6762563534"

    /// Which App Store URL RATE opens.
    enum RateLinkVariant: String, CaseIterable {
        /// (a) The product page, what every build so far opened.
        case productPage = "a"
        /// (b) The product page with Apple's write-review action, over the itms-apps scheme.
        case itmsWriteReview = "b"
        /// (c) Apple's documented form: https plus `action=write-review`, which landed on
        /// the product page like the others. StoreKit's
        /// RequestReviewAction, "Provide a persistent link to your product page": "Append the
        /// query parameter action=write-review to your product page URL to automatically open
        /// the App Store page where users can write a review." The sample "Requesting App
        /// Store reviews" uses `https://apps.apple.com/app/idYOURAPPSTOREID?action=write-review`.
        /// Neither page lists tvOS.
        case httpsWriteReview = "c"
        /// (d) The pre-2019 iTunes form, still widely passed around, undocumented today.
        case legacyReviews = "d"
        /// (e) The App Store web address of the reviews list. Not documented by Apple for any
        /// platform and never pressed on a TV, since b, c and d all landed on the same page.
        case seeAllReviews = "e"

        var url: URL {
            let id = AppStoreLink.appID
            let s: String
            switch self {
            case .productPage: s = "itms-apps://apps.apple.com/app/id\(id)"
            case .itmsWriteReview: s = "itms-apps://apps.apple.com/app/id\(id)?action=write-review"
            case .httpsWriteReview: s = "https://apps.apple.com/app/id\(id)?action=write-review"
            case .legacyReviews: s = "itms-apps://itunes.apple.com/app/viewContentsUserReviews?id=\(id)&action=write-review"
            case .seeAllReviews: s = "https://apps.apple.com/app/id\(id)?see-all=reviews"
            }
            return URL(string: s)!
        }

        /// What a release build opens.
        static let shipped: RateLinkVariant = .productPage
    }

    /// DEBUG only: `-NostalgexRateLinkVariant b` (a letter, or its position 0 to 4) picks the
    /// link RATE opens for a hardware test. Edit Scheme > Run > Arguments.
    static let variantLaunchArgument = "-NostalgexRateLinkVariant"

    /// The variant named by the launch arguments, or nil when there is none or it is unknown.
    static func variant(fromArguments args: [String]) -> RateLinkVariant? {
        guard let i = args.firstIndex(of: variantLaunchArgument), i + 1 < args.count else { return nil }
        let raw = args[i + 1].lowercased()
        if let v = RateLinkVariant(rawValue: raw) { return v }
        if let n = Int(raw), RateLinkVariant.allCases.indices.contains(n) { return RateLinkVariant.allCases[n] }
        return nil
    }

    /// The variant in force: the launch argument in a DEBUG build, else the shipped one.
    static var activeVariant: RateLinkVariant {
        #if DEBUG
        if let v = variant(fromArguments: ProcessInfo.processInfo.arguments) { return v }
        #endif
        return RateLinkVariant.shipped
    }

    /// The URL RATE opens (banner and Settings).
    static var productPage: URL { activeVariant.url }

    /// The one place RATE opens the App Store, for the rating banner and the Settings tile
    /// alike, so the two can never open different links. `completion` gets the variant and
    /// URL that were opened and whether tvOS accepted them; each caller logs and tracks it
    /// under its own name.
    static func openRate(
        using openURL: OpenURLAction,
        completion: @escaping (_ variant: RateLinkVariant, _ url: URL, _ accepted: Bool) -> Void
    ) {
        let variant = activeVariant
        let url = variant.url
        openURL(url) { accepted in completion(variant, url, accepted) }
    }
}
