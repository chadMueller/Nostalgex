import Foundation

/// The words of the loading pattern every platform shares (Chad, 2026-11-15): a library read in front of a guide
/// says so in the guide's own empty area, and the header says when it is done. The same lines, with a count the
/// viewer can read, on the Apple TV, Roku, the web tuner and Android (the reference is Android's `LoadNotice.kt`).
enum LoadNotice {
    /// The yellow title of the block in the empty guide area, after a server or library switch.
    static let changing = "CHANNEL GUIDE IS CHANGING"
    /// ...and for RESCAN LIBRARY.
    static let loading = "LOADING YOUR LIBRARY"
    /// How long GUIDE READY stays in the header.
    static let readySeconds: Double = 4
    /// The step names of a load, the same on every platform (Android's `LoadNotice.kt` set them): the channels are
    /// built while the library is read, the schedule once it is built.
    static let buildingChannels = "BUILDING CHANNELS"
    static let buildingSchedule = "BUILDING SCHEDULE"

    /// 4210 reads "4,210" whatever the TV's locale: the lines are the same on every platform.
    static func count(_ n: Int) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }

    private static func titles(_ n: Int) -> String { n == 1 ? "TITLE" : "TITLES" }

    /// The block's progress line: what has been read, and "OF n" only when the server gave a total.
    static func readLine(read: Int, total: Int? = nil) -> String {
        if let total, total >= read, total > 0 { return "READ \(count(read)) OF \(count(total)) \(titles(total))" }
        return "READ \(count(read)) \(titles(read))"
    }

    /// The library being read: its name, and how far through it when the server gave a total.
    static func libraryLine(_ name: String, done: Int? = nil, total: Int? = nil) -> String {
        let label = name.trimmingCharacters(in: .whitespaces).uppercased()
        if let done, let total, total > 0, done <= total { return "\(label): \(count(done)) OF \(count(total))" }
        return label
    }

    /// The line under the read count: the library being read while the scan runs (its name and how far through),
    /// otherwise the step the load is on. Nothing during the first, quiet step.
    static func detailLine(phase: LibraryLoadPhase, scanDetail: String) -> String {
        if phase == .scanningLibrary { return scanDetail }
        if phase == .preparing { return "" }
        return phase.title.uppercased()
    }

    /// The header's line while the library is read again behind a guide that is already up.
    static func updatingLine(read: Int?) -> String {
        guard let read, read > 0 else { return "UPDATING LIBRARY" }
        return "UPDATING LIBRARY: \(count(read)) \(titles(read)) READ"
    }

    /// The header's line when it is finished, for `readySeconds`.
    static func readyLine(_ n: Int) -> String { "GUIDE READY: \(count(n)) \(titles(n))" }
}

/// Which load is running in front of a guide that stays on screen.
enum GuideLoadKind: Equatable {
    /// A server or library switch from Settings.
    case changing
    /// RESCAN LIBRARY.
    case loading

    var title: String { self == .changing ? LoadNotice.changing : LoadNotice.loading }
}
