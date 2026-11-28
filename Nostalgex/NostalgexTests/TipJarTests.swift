import XCTest
@testable import Nostalgex

final class TipJarTests: XCTestCase {

    // MARK: - Purchase result mapping

    func testVerifiedThanksAndFinishes() {
        let r = TipJarLogic.resolve(.verified(transactionID: 42), alreadyThanked: [])
        XCTAssertEqual(r, TipResolution(outcome: .thanks, transactionToFinish: 42))
    }

    func testVerifiedAlreadyThankedStillFinishesButShowsNothing() {
        let r = TipJarLogic.resolve(.verified(transactionID: 42), alreadyThanked: [42])
        XCTAssertEqual(r, TipResolution(outcome: .none, transactionToFinish: 42))
    }

    func testUnverifiedIsQuietFailureAndStillFinishes() {
        let r = TipJarLogic.resolve(.unverified(transactionID: 7), alreadyThanked: [])
        XCTAssertEqual(r, TipResolution(outcome: .failed, transactionToFinish: 7))
        XCTAssertEqual(TipJarLogic.statusLine(for: r.outcome), TipJarLogic.failedLine)
    }

    func testUserCancelledDoesNothing() {
        let r = TipJarLogic.resolve(.userCancelled, alreadyThanked: [])
        XCTAssertEqual(r, TipResolution(outcome: .none, transactionToFinish: nil))
        XCTAssertNil(TipJarLogic.statusLine(for: r.outcome))
    }

    func testPendingShowsWaitingForApproval() {
        let r = TipJarLogic.resolve(.pending, alreadyThanked: [])
        XCTAssertEqual(r, TipResolution(outcome: .pending, transactionToFinish: nil))
        XCTAssertEqual(TipJarLogic.statusLine(for: r.outcome), "Waiting for approval")
    }

    func testThrownErrorIsQuietFailure() {
        let r = TipJarLogic.resolve(.failed, alreadyThanked: [])
        XCTAssertEqual(r, TipResolution(outcome: .failed, transactionToFinish: nil))
        XCTAssertEqual(TipJarLogic.statusLine(for: r.outcome), TipJarLogic.failedLine)
    }

    func testThanksHasNoStatusLine() {
        XCTAssertNil(TipJarLogic.statusLine(for: .thanks))
    }

    func testUserFacingLinesHaveNoEmDashOrEmoji() {
        let thanks = [TipJarLogic.thanksTitle, TipJarLogic.thanksLine]
            + TipProduct.allCases.map { TipJarLogic.thanksLine(for: $0, quantity: 5) }
        let rows = TipProduct.allCases.map(\.rowTitle) + TipProduct.allCases.map(\.pluralName)
        for line in [TipJarLogic.pendingLine, TipJarLogic.failedLine] + rows + thanks {
            XCTAssertFalse(line.contains("\u{2014}"), line)
            XCTAssertTrue(line.unicodeScalars.allSatisfy { $0.isASCII || $0 == "\u{2019}" }, line)
        }
    }

    // MARK: - Products

    func testProductIDsAndFocusIDs() {
        XCTAssertEqual(TipProduct.allIDs, [
            "com.muellhaus.nostalgex.tip.small",
            "com.muellhaus.nostalgex.tip.big",
            "com.muellhaus.nostalgex.tip.pizza"
        ])
        XCTAssertEqual(TipProduct.allCases.map(\.focusID), ["tip_popcorn", "tip_tv_dinner", "tip_pizza_night"])
        XCTAssertEqual(TipProduct.allCases.map(\.rowTitle), ["POPCORN", "TV DINNER", "PIZZA NIGHT"])
        XCTAssertEqual(TipProduct(rawValue: "com.muellhaus.nostalgex.tip.small"), .popcorn)
        XCTAssertEqual(TipProduct(rawValue: "com.muellhaus.nostalgex.tip.big"), .tvDinner)
        XCTAssertEqual(TipProduct(rawValue: "com.muellhaus.nostalgex.tip.pizza"), .pizzaNight)
    }

    private struct FakeProduct: Equatable {
        let id: String
        let price: Decimal
    }

    func testSortsByPriceAscending() {
        let input = [
            FakeProduct(id: TipProduct.pizzaNight.rawValue, price: Decimal(string: "12.99")!),
            FakeProduct(id: TipProduct.popcorn.rawValue, price: Decimal(string: "3.99")!),
            FakeProduct(id: TipProduct.tvDinner.rawValue, price: Decimal(string: "7.99")!)
        ]
        let sorted = TipJarLogic.sortedByPrice(input, id: \.id, price: \.price)
        XCTAssertEqual(sorted.map(\.id), TipProduct.allIDs)
    }

    func testPriceTiesKeepFixedOrder() {
        let input = [
            FakeProduct(id: TipProduct.pizzaNight.rawValue, price: 5),
            FakeProduct(id: TipProduct.tvDinner.rawValue, price: 5),
            FakeProduct(id: TipProduct.popcorn.rawValue, price: 5)
        ]
        let sorted = TipJarLogic.sortedByPrice(input, id: \.id, price: \.price)
        XCTAssertEqual(sorted.map(\.id), TipProduct.allIDs)
    }

    // MARK: - Quantity

    private let cad = Decimal.FormatStyle.Currency(code: "CAD").locale(Locale(identifier: "en_CA"))

    func testTotalForQuantityOne() {
        let price = Decimal(string: "3.99")!
        XCTAssertEqual(TipJarLogic.total(price: price, quantity: 1), price)
        XCTAssertEqual(TipJarLogic.totalText(price: price, quantity: 1, format: cad), price.formatted(cad))
    }

    func testTotalForQuantityThree() {
        let price = Decimal(string: "3.99")!
        XCTAssertEqual(TipJarLogic.total(price: price, quantity: 3), Decimal(string: "11.97")!)
        XCTAssertEqual(TipJarLogic.total(price: Decimal(string: "12.99")!, quantity: 3), Decimal(string: "38.97")!)
        XCTAssertEqual(
            TipJarLogic.totalText(price: price, quantity: 3, format: cad),
            Decimal(string: "11.97")!.formatted(cad)
        )
        XCTAssertTrue(TipJarLogic.totalText(price: price, quantity: 3, format: cad).contains("11.97"))
    }

    func testQuantityClampsToOneThroughFive() {
        XCTAssertEqual(TipJarLogic.quantityRange, 1...5)
        XCTAssertEqual(TipJarLogic.clampQuantity(-3), 1)
        XCTAssertEqual(TipJarLogic.clampQuantity(0), 1)
        XCTAssertEqual(TipJarLogic.clampQuantity(1), 1)
        XCTAssertEqual(TipJarLogic.clampQuantity(3), 3)
        XCTAssertEqual(TipJarLogic.clampQuantity(5), 5)
        XCTAssertEqual(TipJarLogic.clampQuantity(6), 5)
        XCTAssertEqual(TipJarLogic.clampQuantity(99), 5)
        // The total never multiplies past the clamp.
        XCTAssertEqual(TipJarLogic.total(price: 2, quantity: 9), 10)
        XCTAssertEqual(TipJarLogic.total(price: 2, quantity: 0), 2)
    }

    // MARK: - Thank-you line

    func testThanksLineForOneIsUnchanged() {
        for tip in TipProduct.allCases {
            XCTAssertEqual(TipJarLogic.thanksLine(for: tip, quantity: 1), "This keeps the channels on.")
        }
        XCTAssertEqual(TipJarLogic.thanksLine(for: nil, quantity: 3), "This keeps the channels on.")
    }

    func testThanksLinePlurals() {
        XCTAssertEqual(TipJarLogic.thanksLine(for: .popcorn, quantity: 3), "3 popcorns. This keeps the channels on.")
        XCTAssertEqual(TipJarLogic.thanksLine(for: .tvDinner, quantity: 2), "2 TV dinners. This keeps the channels on.")
        XCTAssertEqual(TipJarLogic.thanksLine(for: .pizzaNight, quantity: 5), "5 pizza nights. This keeps the channels on.")
    }

    // MARK: - Thank once per transaction id

    func testLedgerThanksOncePerTransactionID() {
        var ledger = TipThankLedger()
        XCTAssertTrue(ledger.recordThanks(for: 100))
        XCTAssertFalse(ledger.recordThanks(for: 100))
        XCTAssertTrue(ledger.recordThanks(for: 101))

        // The same transaction arriving again (purchase result, then Transaction.updates)
        // maps to no thank-you.
        let again = TipJarLogic.resolve(.verified(transactionID: 100), alreadyThanked: ledger.asSet)
        XCTAssertEqual(again.outcome, .none)
        XCTAssertEqual(again.transactionToFinish, 100)
    }

    func testLedgerSurvivesRelaunch() {
        let suite = "TipJarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        var ledger = TipThankLedger.load(from: defaults)
        ledger.recordThanks(for: 9_000_000_000_000_000_001)
        ledger.save(to: defaults)

        let reloaded = TipThankLedger.load(from: defaults)
        XCTAssertTrue(reloaded.contains(9_000_000_000_000_000_001))
        XCTAssertFalse(TipThankLedger.load(from: defaults).asSet.isEmpty)
    }

    func testLedgerIsCapped() {
        var ledger = TipThankLedger()
        for id in 0..<UInt64(TipThankLedger.cap + 25) { ledger.recordThanks(for: id) }
        XCTAssertEqual(ledger.ids.count, TipThankLedger.cap)
        XCTAssertFalse(ledger.contains(0))
        XCTAssertTrue(ledger.contains(UInt64(TipThankLedger.cap + 24)))
    }

    // MARK: - Analytics

    /// Pins the three tip signals: their names and the one parameter. A new key means a
    /// new look at the privacy label, so adding one must fail here first.
    func testTipSignalsCarryTheTierAndNothingElse() {
        let tiers: [(TipProduct, String)] = [(.popcorn, "popcorn"), (.tvDinner, "tv_dinner"), (.pizzaNight, "pizza_night")]
        XCTAssertEqual(tiers.count, TipProduct.allCases.count)
        for (tip, wire) in tiers {
            let tier = tip.analyticsTier
            let events: [(AnalyticsEvent, String)] = [
                (.tipStarted(tier: tier), "tip.started"),
                (.tipCompleted(tier: tier), "tip.completed"),
                (.tipFailed(tier: tier), "tip.failed"),
            ]
            for (event, name) in events {
                XCTAssertEqual(event.name, name)
                XCTAssertEqual(event.parameters, ["tier": wire], name)
                XCTAssertNil(event.floatValue, name)
            }
        }
    }

    func testOnlyAThankYouOrAFailureIsCounted() {
        XCTAssertEqual(TipJarLogic.analyticsEvent(for: .thanks, tip: .popcorn)?.name, "tip.completed")
        XCTAssertEqual(TipJarLogic.analyticsEvent(for: .failed, tip: .pizzaNight)?.name, "tip.failed")
        XCTAssertEqual(TipJarLogic.analyticsEvent(for: .failed, tip: .pizzaNight)?.parameters, ["tier": "pizza_night"])
        XCTAssertNil(TipJarLogic.analyticsEvent(for: .none, tip: .popcorn), "a cancel or a repeat sends nothing")
        XCTAssertNil(TipJarLogic.analyticsEvent(for: .pending, tip: .popcorn), "waiting for approval sends nothing")
        XCTAssertNil(TipJarLogic.analyticsEvent(for: .thanks, tip: nil), "an unknown product sends nothing")
    }
}
