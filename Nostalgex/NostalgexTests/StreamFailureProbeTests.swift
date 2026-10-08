import XCTest
@testable import Nostalgex

/// The probe exists because tvOS will not tell us the HTTP status of a failed HLS request.
/// These pin the two things the failure card depends on: that a refusal is recognised, and
/// that a server which is serving the URL happily is never reported as a refusal.
final class StreamFailureProbeTests: XCTestCase {

    func testOnlyFourAndFiveHundredsCountAsTheServerSayingNo() {
        for ok in [200, 206, 301, 302, 399] {
            XCTAssertFalse(StreamFailureProbe.isRefusal(ok), "\(ok) is not a refusal")
        }
        for no in [400, 401, 403, 404, 500, 502, 503] {
            XCTAssertTrue(StreamFailureProbe.isRefusal(no), "\(no) is a refusal")
        }
    }

    /// 206 is the expected answer to the ranged request the probe makes. Treating it as a
    /// refusal would blame the server for every failure that is actually on this side.
    func testAPartialContentAnswerIsTheHealthyCase() {
        XCTAssertFalse(StreamFailureProbe.isRefusal(206))
    }

    func testNothingAnsweringYieldsNoStatusRatherThanAGuess() async {
        // Reserved, per RFC 6761, so this resolves nowhere and the probe must simply
        // give up instead of inventing a status.
        let url = URL(string: "http://localhost:1/does-not-exist.m3u8")!
        let status = await StreamFailureProbe.status(of: url, timeout: 2)
        XCTAssertNil(status)
    }

    /// A probe that answers 500 has to reach the card as a server refusal, which is the
    /// whole chain this feature rests on.
    func testARefusalFromTheProbeClassifiesAsServerRefused() {
        var e = PlaybackFailure.Evidence()
        e.httpStatuses = [500]
        XCTAssertEqual(PlaybackFailure.classify(backend: .emby, evidence: e),
                       .serverRefused(server: "Emby", status: 500))
    }
}
