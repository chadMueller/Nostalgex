import Foundation
import CoreGraphics

// MARK: - Package stripes in the guide
//
// A coloured stripe down the left edge of the guide with the package name written up it. Each row
// draws its own piece of the stripe, so the colour scrolls with the rows; only the name (a sticky
// label) is placed from the scroll offset. Everything here is pure: which package a channel is in, the
// runs of channels that make a stripe, the colour of a name, and where a label sits in the viewport.
// No stored data: all of it is worked out from the lineup on screen.

/// A package as the stripe names it.
struct GuidePackage: Equatable, Hashable {
    let id: String
    let name: String
}

/// A run of consecutive guide rows that are in the same package (or in none). A package can come back
/// as a second run if the guide lists its channels apart; each run is its own stripe.
struct GuideStripeGroup: Equatable, Identifiable {
    /// Nil for channels that are in no package on screen: their stripe has no name.
    let package: GuidePackage?
    let firstRow: Int
    let rowCount: Int

    var id: Int { firstRow }
    var lastRow: Int { firstRow + rowCount - 1 }
    var name: String? { package?.name }
}

enum GuideStripes {

    // MARK: Which package a channel is in

    /// Channel id to package, for the packages that are on. A channel is in the first package, in the order
    /// of `bundles`, that lists it. FRANCHISES is one package with every franchise channel in it, the way
    /// the package jump list reads it (`AppState.bundleJumpTargets`): the stock classics, the franchises
    /// found in the library, and the server's franchise collections, named by the stock package when it is on.
    static func membership(
        bundles: [ChannelBundle],
        enabledBundleIDs: Set<String>,
        foundFranchiseChannelIDs: [Int],
        franchisesBundleID: String,
        franchiseCollectionsBundleID: String
    ) -> [Int: GuidePackage] {
        let franchiseIDs: Set<String> = [franchisesBundleID, franchiseCollectionsBundleID]
        var entries: [(package: GuidePackage, ids: [Int])] = []
        for bundle in bundles where enabledBundleIDs.contains(bundle.id) {
            var ids = bundle.channelIDs
            if bundle.id == franchisesBundleID { ids += foundFranchiseChannelIDs }
            if franchiseIDs.contains(bundle.id),
               let i = entries.firstIndex(where: { franchiseIDs.contains($0.package.id) }) {
                entries[i].ids += ids
                if bundle.id == franchisesBundleID {
                    entries[i].package = GuidePackage(id: bundle.id, name: bundle.name)
                }
                continue
            }
            entries.append((GuidePackage(id: bundle.id, name: bundle.name), ids))
        }
        var result: [Int: GuidePackage] = [:]
        for entry in entries {
            for id in entry.ids where result[id] == nil { result[id] = entry.package }
        }
        return result
    }

    // MARK: The runs

    /// The stripes: consecutive rows with the same package, in guide order. A channel in no package is in a
    /// run of its own kind (`package == nil`), which draws a plain stripe with no name.
    static func groups(channels: [Channel], membership: [Int: GuidePackage]) -> [GuideStripeGroup] {
        var groups: [GuideStripeGroup] = []
        var current: (package: GuidePackage?, first: Int, count: Int)?
        for (row, channel) in channels.enumerated() {
            let package = membership[channel.id]
            if let c = current, c.package == package {
                current = (c.package, c.first, c.count + 1)
            } else {
                if let c = current { groups.append(GuideStripeGroup(package: c.package, firstRow: c.first, rowCount: c.count)) }
                current = (package, row, 1)
            }
        }
        if let c = current { groups.append(GuideStripeGroup(package: c.package, firstRow: c.first, rowCount: c.count)) }
        return groups
    }

    /// The run the row `row` is in.
    static func groupIndex(containingRow row: Int, in groups: [GuideStripeGroup]) -> Int? {
        groups.firstIndex { $0.firstRow <= row && row <= $0.lastRow }
    }

    /// The previous (`step` -1) or next (+1) run that is a package, from run `index`. Runs with no package
    /// are stepped over, and there is no wrap: past the first or last package there is nowhere to go (nil).
    static func neighbourIndex(from index: Int, step: Int, in groups: [GuideStripeGroup]) -> Int? {
        precondition(step == 1 || step == -1)
        var i = index + step
        while groups.indices.contains(i) {
            if groups[i].package != nil { return i }
            i += step
        }
        return nil
    }

    /// Whether there is any package to move between. With none, the stripe has nothing to offer and Left
    /// goes to the package list as it always did.
    static func hasPackages(_ groups: [GuideStripeGroup]) -> Bool {
        groups.contains { $0.package != nil }
    }

    /// What one row draws in the stripe's column: the colour (nil for a plain, unnamed stripe) and whether it is
    /// the first row of its run, which gets a thin dark line above it so two stripes never run together.
    struct RowCell: Equatable {
        let hex: String?
        let startsRun: Bool
    }

    static func rowCells(groups: [GuideStripeGroup], count: Int) -> [RowCell] {
        var cells = [RowCell](repeating: RowCell(hex: nil, startsRun: false), count: count)
        for group in groups {
            let hex = group.name.map(Palette.hex(for:))
            for row in group.firstRow...group.lastRow where cells.indices.contains(row) {
                cells[row] = RowCell(hex: hex, startsRun: row == group.firstRow)
            }
        }
        return cells
    }

    // MARK: Colour

    /// The ten colours a package stripe can be, all taken from the channel colours the app already uses,
    /// so a stripe reads as part of the same guide. `index(for:)` picks one from the name.
    enum Palette {
        static let hexes: [String] = [
            "#FF2DB4",   // pink
            "#E74C3C",   // red
            "#E67E22",   // orange
            "#F1C40F",   // yellow
            "#2ECC71",   // green
            "#2DC7B0",   // teal
            "#00BFFF",   // sky
            "#7B68EE",   // periwinkle
            "#8E44AD",   // purple
            "#B9770E",   // bronze
        ]

        /// FNV-1a over the upper-cased name, its two halves folded together, modulo the palette. Written out
        /// rather than `Hasher`, which is seeded differently on every launch: the same name must be the same
        /// colour on every launch and every Apple TV.
        static func index(for name: String) -> Int {
            var hash: UInt32 = 0x811c_9dc5
            for byte in name.uppercased().utf8 {
                hash ^= UInt32(byte)
                hash = hash &* 0x0100_0193
            }
            let folded = (hash >> 16) ^ (hash & 0xffff)
            return Int(folded) % hexes.count
        }

        static func hex(for name: String) -> String { hexes[index(for: name)] }

        // MARK: Contrast of the name on its stripe

        /// WCAG relative luminance of a "#RRGGBB" colour.
        static func luminance(ofHex hex: String) -> Double {
            let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
            func channel(_ shift: UInt32) -> Double {
                let v = Double((value >> shift) & 0xff) / 255
                return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
        }

        static func contrast(_ a: Double, _ b: Double) -> Double {
            (max(a, b) + 0.05) / (min(a, b) + 0.05)
        }

        /// Black or white, whichever reads better on the stripe. Never below 4.5 to 1 on any colour.
        static func nameIsBlack(onHex hex: String) -> Bool {
            let l = luminance(ofHex: hex)
            return contrast(l, 0) >= contrast(l, 1)
        }

        /// The colour a stripe is drawn in while it has focus: the same colour pushed a fifth of the way to white,
        /// so it reads brighter than its neighbours. The name is chosen for this colour, not the plain one.
        static func focusedHex(for hex: String) -> String {
            let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
            func lift(_ shift: UInt32) -> UInt32 {
                let c = Double((value >> shift) & 0xff)
                return UInt32((c + (255 - c) * 0.22).rounded())
            }
            return String(format: "#%02X%02X%02X", lift(16), lift(8), lift(0))
        }

        static func nameContrast(onHex hex: String) -> Double {
            let l = luminance(ofHex: hex)
            return max(contrast(l, 0), contrast(l, 1))
        }
    }

    // MARK: Where things are on the screen

    /// Width of the stripe. It sits in the slot at the left of every row (the row content is centred in a
    /// frame wider than the screen, which leaves 31.5 pt there, and 29.5 pt on the live and the focused row,
    /// whose accent bar is 8 pt), so it takes nothing from the channel names or the programs.
    static let stripeWidth: CGFloat = 28

    /// The part of a run that is on screen, in the viewport's own coordinates (0 at the top of the rows).
    /// The label and the focus ring use it, so a package whose first rows have scrolled away still has its
    /// name and its ring on the rows that are left.
    ///
    /// - Parameters:
    ///   - leading: height above the first channel row (the seasonal invite row, when it is on).
    ///   - rowPitch: height of one channel row with its divider.
    static func visibleSpan(
        of group: GuideStripeGroup, rowPitch: CGFloat, leading: CGFloat, offset: CGFloat, viewport: CGFloat
    ) -> (top: CGFloat, height: CGFloat)? {
        let top = leading + CGFloat(group.firstRow) * rowPitch
        let bottom = top + CGFloat(group.rowCount) * rowPitch
        let visibleTop = max(top, offset)
        let visibleBottom = min(bottom, offset + viewport)
        guard visibleBottom > visibleTop else { return nil }
        return (visibleTop - offset, visibleBottom - visibleTop)
    }

    /// A name written up the stripe: its viewport span, and the name itself. A span too short to show even
    /// a couple of letters has no label.
    struct Label: Equatable {
        let groupIndex: Int
        let name: String
        let top: CGFloat
        let height: CGFloat
    }

    static let minimumLabelHeight: CGFloat = 44

    static func labels(
        groups: [GuideStripeGroup], rowPitch: CGFloat, leading: CGFloat, offset: CGFloat, viewport: CGFloat
    ) -> [Label] {
        groups.enumerated().compactMap { index, group in
            guard let name = group.name,
                  let span = visibleSpan(of: group, rowPitch: rowPitch, leading: leading, offset: offset, viewport: viewport),
                  span.height >= minimumLabelHeight else { return nil }
            return Label(groupIndex: index, name: name, top: span.top, height: span.height)
        }
    }
}
