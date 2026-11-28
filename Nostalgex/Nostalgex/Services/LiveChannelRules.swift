import Foundation

/// When a new live channels.json (N-074) is applied to the guide that is on screen.
///
/// A check (`ChannelConfigStore.checkInterval`) only writes the file. Applying it rebuilds every channel's pool from
/// the library already in memory, with no server scan, so it happens only at a safe point:
///   - never while a programme is full screen, and never while a library load or another rebuild is running;
///   - at the next time the viewer is on the guide, or at the next launch (the guide is not on screen yet and
///     nothing plays);
///   - only when the file's content `version` is newer than the one the guide was built from. A file that is the
///     same, older or invalid never gets this far: `ChannelConfigStore.store` refuses it, so the kept version does
///     not move.
///
/// Rollback: a TV accepts a `version` at least as new as the one it holds and never an older one (the same rule on
/// every platform). To roll back, push the old content under a HIGHER version number.
enum LiveChannelRules {
    /// Whether a rebuild may run while the app is open. Measured on a 30,000 title library (dev log, 2026-11-16);
    /// when false a new copy waits for the next launch.
    static let appliesWhileRunning = true

    enum Decision: Equatable {
        /// No newer version than the guide was built from.
        case nothing
        /// Newer, but not now: a programme is full screen, or a load or rebuild is running, or the viewer is not on the guide.
        case waitForGuide
        /// Newer, but applying while the app is open is switched off (`appliesWhileRunning`): the next launch does it.
        case waitForLaunch
        case applyNow
    }

    struct Moment: Equatable {
        var isFullScreen = false
        var isLoading = false
        var isRebuilding = false
        var onGuide = false
        /// The app has just started: nothing plays and the guide is not up yet.
        var atLaunch = false
    }

    static func decide(appliedVersion: Int, keptVersion: Int, moment: Moment,
                       appliesWhileRunning: Bool = LiveChannelRules.appliesWhileRunning) -> Decision {
        guard keptVersion > appliedVersion else { return .nothing }
        guard appliesWhileRunning || moment.atLaunch else { return .waitForLaunch }
        guard !moment.isFullScreen, !moment.isLoading, !moment.isRebuilding else { return .waitForGuide }
        guard moment.onGuide || moment.atLaunch else { return .waitForGuide }
        return .applyNow
    }
}
