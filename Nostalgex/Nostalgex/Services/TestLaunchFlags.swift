import Foundation

/// Launch arguments that exist for tests and delete or rewrite what the app has stored (sign-in,
/// library snapshot, settings, the remembered channel). On 2026-11-09 a UI test launched with
/// `-uiTestResetCredentials` on a real Apple TV and, with no harness root, wiped that TV's real
/// library snapshot, sign-in and settings.
///
/// Each flag in `destructive` is honoured only while `HarnessIsolation` is active, so what it
/// deletes or rewrites is the harness root's copy and never the TV's. Any other launch it is
/// ignored, with one log line, and the app starts as a normal launch would. A release build has no
/// `HarnessIsolation`, so it never honours them.
///
/// Add a flag here when it deletes or rewrites stored data, and read it through `isOn`, never with
/// `ProcessInfo.processInfo.arguments.contains`. `scripts/ui-test-isolation-check.mjs` reads this
/// list to check the UI tests.
enum TestLaunchFlags {
    static let destructive: [String] = [
        "-uiTestResetCredentials",      // deletes the sign-in, the settings copy of it and the library snapshot
        "-reproAppReviewFlow",          // the same, then overwrites the sign-in with a test token
        "-uiTestInstantAuth",           // overwrites the sign-in with a test token
        "-uiTestRescanRowFixture",      // rewrites the last-load time and the playback failure record
        "-uiTestLaunchMemoryInDemo",    // lets a demo tune overwrite the remembered channel
        "-uiTestForceLibrarySelection", // CONTINUE rewrites the library selection
        "-uiTestFranchiseFixture",      // rewrites the enabled packages and seeds the enrichment cache
    ]

    /// The whole rule, apart from where the answers come from.
    static func shouldHonour(_ flag: String, arguments: [String], isolationActive: Bool) -> Bool {
        guard arguments.contains(flag) else { return false }
        guard destructive.contains(flag) else { return true }
        return isolationActive
    }

    static var isolationActive: Bool {
        #if DEBUG
        HarnessIsolation.isActive
        #else
        false
        #endif
    }

    /// True when the flag is on the command line and may act.
    static func isOn(_ flag: String) -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains(flag) else { return false }
        let honour = shouldHonour(flag, arguments: arguments, isolationActive: isolationActive)
        if !honour { logIgnoredOnce(flag) }
        return honour
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var logged: Set<String> = []

    private static func logIgnoredOnce(_ flag: String) {
        lock.lock()
        let first = logged.insert(flag).inserted
        lock.unlock()
        guard first else { return }
        print("[Nostalgex] TEST FLAG: \(flag) ignored, it deletes or rewrites stored data and this launch has no harness isolation (NOSTALGEX_HARNESS_ROOT)")
    }
}
