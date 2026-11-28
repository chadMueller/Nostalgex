import Foundation

/// The loading pattern inside Settings (Chad, 2026-11-16): a switch of server or library, a RESCAN or a refresh does
/// not take the viewer out of Settings, and Settings says what is going on, with the words every platform shares
/// (`LoadNotice`): BUILDING CHANNELS, READ n TITLES, the library being read, then BUILDING SCHEDULE, then
/// GUIDE READY: n TITLES for four seconds. Read-only: it shows state the load already keeps and changes none of it.
struct SettingsLoadStatus: Equatable {
    /// The line in yellow: the step, or GUIDE READY.
    var title: String
    var isReady: Bool
    /// READ n TITLES, once something has been read.
    var readLine: String?
    /// The library being read, or the step after it.
    var detailLine: String?

    /// What Settings shows now, or nil when nothing is going on.
    /// - inPlaceLoad: a switch or RESCAN reading the library in front of a guide that stays up.
    /// - backgroundRefresh: the library read again behind the guide (the header's UPDATING LIBRARY).
    static func current(inPlaceLoad: Bool, backgroundRefresh: Bool, phase: LibraryLoadPhase, titlesRead: Int,
                        scanDetail: String, readyTitles: Int?) -> SettingsLoadStatus? {
        if inPlaceLoad {
            let scheduling = phase == .finishing
            let read = titlesRead > 0 || phase > .scanningLibrary ? LoadNotice.readLine(read: titlesRead) : nil
            let detail = scheduling ? "" : LoadNotice.detailLine(phase: phase, scanDetail: scanDetail)
            return SettingsLoadStatus(title: scheduling ? LoadNotice.buildingSchedule : LoadNotice.buildingChannels,
                                      isReady: false, readLine: read, detailLine: detail.isEmpty ? nil : detail)
        }
        if backgroundRefresh {
            return SettingsLoadStatus(title: LoadNotice.updatingLine(read: titlesRead), isReady: false, readLine: nil, detailLine: nil)
        }
        if let n = readyTitles {
            return SettingsLoadStatus(title: LoadNotice.readyLine(n), isReady: true, readLine: nil, detailLine: nil)
        }
        return nil
    }
}
