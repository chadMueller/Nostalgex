import XCTest
@testable import Nostalgex

/// #146: STOP WAITING means the whole scan, and the scan has to be able to tell the viewer's tap from the
/// watchdog giving up. A section that had read some pages throws `LibraryScanInterrupted`, which cannot say why it
/// was cancelled, so `withLibraryLoadStallWatch` stamps it with the verdict it resolved to. The load loop stops at
/// the first server only when that stamp says the viewer asked.
@MainActor
final class StopWaitingVerdictStampTests: XCTestCase {

    /// A scan that has read nothing more and waits to be cancelled, then reports the sections it had.
    private func hangingScan() -> @Sendable () async throws -> Int {
        {
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 20_000_000) }
            throw LibraryScanInterrupted(partialItems: [])
        }
    }

    func testTheViewersTapStampsTheInterruptedScanAsUserInitiated() async {
        do {
            _ = try await withLibraryLoadStallWatch(
                pollInterval: 0.05,
                sample: { LibraryLoadProgressSample() },
                onVerdict: { _ in },
                abortRequested: { true },
                operation: hangingScan()
            )
            XCTFail("the scan was cancelled and had to throw")
        } catch let interrupted as LibraryScanInterrupted {
            XCTAssertTrue(interrupted.userInitiated, "the viewer pressed STOP WAITING")
        } catch {
            XCTFail("expected LibraryScanInterrupted, got \(error)")
        }
    }

    func testTheWatchdogGivingUpStampsItAsNotUserInitiated() async {
        do {
            _ = try await withLibraryLoadStallWatch(
                warnAfter: 0.05,
                stallAfter: 0.2,
                pollInterval: 0.05,
                sample: { LibraryLoadProgressSample() },
                onVerdict: { _ in },
                abortRequested: { false },
                operation: hangingScan()
            )
            XCTFail("the scan was cancelled and had to throw")
        } catch let interrupted as LibraryScanInterrupted {
            XCTAssertFalse(interrupted.userInitiated, "an automatic stall is not the viewer's tap")
        } catch {
            XCTFail("expected LibraryScanInterrupted, got \(error)")
        }
    }

    func testAnInterruptedScanThatNobodyCancelledIsNotStamped() async {
        do {
            _ = try await withLibraryLoadStallWatch(
                pollInterval: 0.05,
                sample: { LibraryLoadProgressSample() },
                onVerdict: { _ in },
                abortRequested: { false },
                operation: { throw LibraryScanInterrupted(partialItems: [], failedSections: ["Movies"]) } as @Sendable () async throws -> Int
            )
            XCTFail("the scan threw")
        } catch let interrupted as LibraryScanInterrupted {
            XCTAssertFalse(interrupted.userInitiated)
            XCTAssertEqual(interrupted.failedSections, ["Movies"], "a section that failed for good keeps its name")
        } catch {
            XCTFail("expected LibraryScanInterrupted, got \(error)")
        }
    }
}
