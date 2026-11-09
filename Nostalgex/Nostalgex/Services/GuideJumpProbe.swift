import Foundation
import Observation
import SwiftUI

/// Measures what a viewer sees when the guide comes back after full screen, or first appears: which row
/// the guide draws as highlighted, and when, against the channel that is playing. Debug builds only; a
/// release build has an empty stand-in, so nothing is logged, kept or drawn there.
///
/// Every line starts with `[GuideJump]` and a time in milliseconds from the moment the guide came back
/// (full screen closed) or first appeared. Two sequences are kept apart:
///
/// - `raw`: where tvOS puts focus (the guide's focus state), which can go to the row the viewer left
///   from before the guide moves it to the live channel;
/// - `shown`: the row the guide draws highlighted. This is what the viewer sees. It must be the live
///   channel from the first frame, never the old row.
///
/// With `-uiTestGuideJumpProbe` the summary is also readable by a UI test, through an invisible element.
#if DEBUG
@MainActor
@Observable
final class GuideJumpProbe {
    static let shared = GuideJumpProbe()

    /// `origin=fullScreenClosed live=9006 shown=[none@0.0,9006@3.1] raw=[none@0.0,9004@8.2,9006@16.9]`:
    /// each entry is a row id and the milliseconds from the moment the guide came back.
    private(set) var summary = "idle"

    static var isExposedToTests: Bool {
        ProcessInfo.processInfo.arguments.contains("-uiTestGuideJumpProbe")
    }

    private var origin = "none"
    private var startedAt: UInt64 = 0
    private var live: Int?
    private var shownIDs: [(id: Int?, at: Double)] = []
    private var rawIDs: [(id: Int?, at: Double)] = []
    /// The list's scroll offset, in points, whenever it changed: the one it had when the guide came back,
    /// then every change after. More than one entry means the list moved in front of the viewer.
    private var offsets: [(y: Double, at: Double)] = []
    private var lastOffset: Double?

    private func milliseconds() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- startedAt) / 1_000_000
    }

    private func name(_ id: Int?) -> String { id.map(String.init) ?? "none" }

    private func line(_ text: String) {
        print("[GuideJump] +\(String(format: "%.1f", milliseconds())) ms \(text)")
    }

    private func format(_ entries: [(id: Int?, at: Double)]) -> String {
        entries.map { "\(name($0.id))@\(String(format: "%.1f", $0.at))" }.joined(separator: ",")
    }

    private func refresh() {
        let scroll = offsets.map { "\(Int($0.y.rounded()))@\(String(format: "%.1f", $0.at))" }.joined(separator: ",")
        summary = "origin=\(origin) live=\(name(live)) shown=[\(format(shownIDs))] raw=[\(format(rawIDs))] scroll=[\(scroll)]"
    }

    /// The guide has come back (or first appeared): starts a new measurement.
    func begin(_ origin: String, live: Int?, shown: Int?, raw: Int?) {
        self.origin = origin
        startedAt = DispatchTime.now().uptimeNanoseconds
        self.live = live
        shownIDs = [(shown, 0)]
        rawIDs = [(raw, 0)]
        offsets = lastOffset.map { [($0, 0)] } ?? []
        line("\(origin): live=\(name(live)) shown=\(name(shown)) raw=\(name(raw))")
        refresh()
    }

    func rawFocusChanged(from old: Int?, to new: Int?) {
        guard origin != "none", rawIDs.last?.id != new else { return }
        rawIDs.append((new, milliseconds()))
        line("raw focus \(name(old)) -> \(name(new))\(new == live ? " (the live channel)" : "")")
        refresh()
    }

    func shownChanged(from old: Int?, to new: Int?) {
        guard origin != "none", shownIDs.last?.id != new else { return }
        shownIDs.append((new, milliseconds()))
        line("shown highlight \(name(old)) -> \(name(new))\(new == live ? " (the live channel)" : "")")
        refresh()
    }

    /// The list's scroll offset changed from `old` to `new`. The first entry of a measurement is the offset
    /// the list had when the guide came back, so a measurement with more than one entry is a list that
    /// moved in front of the viewer.
    func scrollOffsetChanged(from old: Double, to new: Double) {
        lastOffset = new
        guard origin != "none" else { return }
        if offsets.isEmpty { offsets.append((old, 0)) }
        offsets.append((new, milliseconds()))
        line("scroll offset \(Int(old.rounded())) -> \(Int(new.rounded())) pt")
        refresh()
    }

    func note(_ text: String) {
        guard origin != "none" else { return }
        line(text)
    }
}

/// An invisible element a UI test reads the summary from. Never added without `-uiTestGuideJumpProbe`.
struct GuideJumpProbeElement: View {
    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("guideJumpProbe")
            .accessibilityLabel("guideJumpProbe")
            .accessibilityValue(GuideJumpProbe.shared.summary)
    }
}
#else
@MainActor
struct GuideJumpProbe {
    static let shared = GuideJumpProbe()
    func begin(_ origin: String, live: Int?, shown: Int?, raw: Int?) {}
    func rawFocusChanged(from old: Int?, to new: Int?) {}
    func shownChanged(from old: Int?, to new: Int?) {}
    func note(_ text: String) {}
    func scrollOffsetChanged(from old: Double, to new: Double) {}
}
#endif
