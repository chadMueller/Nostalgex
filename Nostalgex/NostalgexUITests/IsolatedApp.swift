import XCTest

/// The one way a UI test makes the app it launches.
///
/// `TEST_RUNNER_NOSTALGEX_HARNESS_ROOT` only reaches the test runner, not the app a test launches. A UI test is
/// isolated from the Apple TV's real library snapshot, sign-in and settings only if it sets `NOSTALGEX_HARNESS_ROOT` on the
/// app's own `launchEnvironment`. On 2026-11-09 a test that did not wiped a real TV with `-uiTestResetCredentials`.
/// `isolatedApp` sets it every time, with a root of its own per test, so a new test cannot forget.
///
/// `scripts/ui-test-isolation-check.mjs` fails when any other file in this folder calls `XCUIApplication(`.
/// On the app side, the launch flags that delete or rewrite stored data (`TestLaunchFlags.destructive`) are
/// ignored unless that root is set.
extension XCTestCase {
    /// The app, set to keep everything under a harness root named for this test. Every call in one test shares the root,
    /// so an app made again (or `terminate()` then `launch()`) in the same test sees what the first launch saved; a
    /// different test, or the same test on a later run, gets a different one.
    func isolatedApp(arguments: [String] = [], environment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        for (key, value) in environment { app.launchEnvironment[key] = value }
        app.launchEnvironment[IsolatedAppRoots.environmentKey] = IsolatedAppRoots.root(for: self)
        // Silent: demo mode streams Apple's BipBop sample, which beeps through the Mac's speakers. The app honours
        // the flag only under the harness root set above.
        app.launchArguments = arguments + [IsolatedAppRoots.muteFlag]
        return app
    }

    /// For a test that genuinely needs the app's real stores (it reads what the app already holds, such as a real
    /// sign-in). It runs on the simulator only and skips on a real Apple TV, where the real stores are a viewer's
    /// library and sign-in. `reason` says why it cannot be isolated. No flag that deletes or rewrites stored data is
    /// accepted here: the app would ignore it, so it fails the test now rather than later.
    func realStoresApp(because reason: String, arguments: [String] = []) throws -> XCUIApplication {
        precondition(!reason.trimmingCharacters(in: .whitespaces).isEmpty, "say why this test needs the real stores")
        #if !targetEnvironment(simulator)
        throw XCTSkip("Uses the app's real stores (\(reason)); simulator only.")
        #else
        let destructive = arguments.filter { IsolatedAppRoots.destructiveFlags.contains($0) }
        XCTAssertTrue(destructive.isEmpty, "\(destructive) delete or rewrite stored data and only act under NOSTALGEX_HARNESS_ROOT")
        let app = XCUIApplication()
        app.launchArguments = arguments
        return app
        #endif
    }
}

enum IsolatedAppRoots {
    static let environmentKey = "NOSTALGEX_HARNESS_ROOT"
    /// Mirrors `TestLaunchFlags.muteAudio`; the app honours it only under the harness root.
    static let muteFlag = "-uiTestMuteAudio"

    /// Mirrors `TestLaunchFlags.destructive` in the app. `scripts/ui-test-isolation-check.mjs` fails when they differ.
    static let destructiveFlags: Set<String> = [
        "-uiTestResetCredentials",
        "-reproAppReviewFlow",
        "-uiTestInstantAuth",
        "-uiTestRescanRowFixture",
        "-uiTestLaunchMemoryInDemo",
        "-uiTestForceLibrarySelection",
        "-uiTestFranchiseFixture",
    ]

    private static let lock = NSLock()
    nonisolated(unsafe) private static var roots: [String: String] = [:]
    private static let run = String(UUID().uuidString.prefix(8)).lowercased()

    /// `uitest-<Class>-<test>-<run>`: one per test in a run, new on every run.
    static func root(for test: XCTestCase) -> String {
        lock.lock(); defer { lock.unlock() }
        if let known = roots[test.name] { return known }
        let readable = test.name.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
        let root = "uitest-\(readable)-\(run)"
        roots[test.name] = root
        return root
    }
}
