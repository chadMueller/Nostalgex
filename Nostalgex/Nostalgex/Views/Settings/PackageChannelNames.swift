import SwiftUI

/// The channel names a focused package row grows to show (discussion #217). A small, dim run
/// of names with a dot between two names on the same line, under the row's description; the
/// ones short of content are amber, with one line saying what amber means. Names only, never
/// a channel number.
///
/// Drawn only while the row has focus (`SettingsToggleRow`), so the page is no longer than
/// before while a viewer scrolls past, and the list is not read on every row of the page.
struct PackageChannelNames: View {
    let listing: PackageChannelListing
    /// Whether the package is on: its names read brighter than an off package's.
    let isOn: Bool

    private static let font = Font.custom("DMMono-Regular", size: 18)
    private static let amber = Color(hex: "#FFB020")

    /// The colour a name is drawn in: amber when it is short of content, otherwise white, brighter
    /// for a package that is on than for one that is off.
    static func nameColor(isShort: Bool, isOn: Bool) -> Color {
        isShort ? amber : Color.white.opacity(isOn ? 0.7 : 0.45)
    }

    private var dotColor: Color { Color.white.opacity(isOn ? 0.35 : 0.25) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PackageNameFlowLayout(gap: 9, lineSpacing: 4) {
                ForEach(Array(listing.entries.enumerated()), id: \.offset) { index, entry in
                    if index > 0 {
                        // Between this name and the one before it. The layout draws it only when the two
                        // are on the same line, so a line never starts or ends with a dot.
                        Text("·")
                            .font(Self.font)
                            .foregroundStyle(dotColor)
                            .fixedSize()
                            .layoutValue(key: PackageNameSeparatorKey.self, value: true)
                    }
                    Text(entry.name)
                        .font(Self.font)
                        .foregroundStyle(Self.nameColor(isShort: entry.isShort, isOn: isOn))
                        .fixedSize()
                }
            }
            .clipped()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(listing.names.joined(separator: ", "))
            .accessibilityIdentifier("packageChannelNames")

            if !listing.shortChannels.isEmpty {
                Text("Amber: not enough titles yet")
                    .font(Self.font)
                    .foregroundStyle(Self.amber)
                    .accessibilityIdentifier("packageChannelNamesLegend")
            }
        }
    }
}

// MARK: - Wrapping

/// Where the names of a package break into lines, and which dots show. Pure, so it is tested
/// without a screen: names go left to right, a dot sits between two names on the same line, and a
/// name that does not fit starts the next line, so no line starts or ends with a dot.
enum PackageNameFlow {
    /// The indices of the names on each line, in order. A name wider than `maxWidth` has a line to
    /// itself. `gap` is the space on each side of a dot.
    static func lines(nameWidths: [CGFloat], separatorWidth: CGFloat, gap: CGFloat, maxWidth: CGFloat) -> [[Int]] {
        var lines: [[Int]] = []
        var used: CGFloat = 0
        for (index, width) in nameWidths.enumerated() {
            if lines.isEmpty {
                lines = [[index]]
                used = width
                continue
            }
            let joined = used + gap + separatorWidth + gap + width
            if joined <= maxWidth {
                lines[lines.count - 1].append(index)
                used = joined
            } else {
                lines.append([index])
                used = width
            }
        }
        return lines
    }
}

/// Marks the dot views among the children of `PackageNameFlowLayout`.
private struct PackageNameSeparatorKey: LayoutValueKey {
    static let defaultValue = false
}

/// Lays the names out in lines (`PackageNameFlow`). The children are, in order, the first name,
/// then a dot and a name for each name after it. A dot whose neighbours are on different lines is
/// placed out of sight; the container clips.
private struct PackageNameFlowLayout: Layout {
    let gap: CGFloat
    let lineSpacing: CGFloat

    private struct Measured {
        let names: [Int]        // subview index of each name
        let dots: [Int]         // subview index of the dot before each name but the first
        let widths: [CGFloat]
        let separatorWidth: CGFloat
        let lineHeight: CGFloat
    }

    private func measure(_ subviews: Subviews) -> Measured {
        var names: [Int] = [], dots: [Int] = []
        for (index, subview) in subviews.enumerated() {
            if subview[PackageNameSeparatorKey.self] { dots.append(index) } else { names.append(index) }
        }
        let sizes = names.map { subviews[$0].sizeThatFits(.unspecified) }
        return Measured(
            names: names,
            dots: dots,
            widths: sizes.map(\.width),
            separatorWidth: dots.first.map { subviews[$0].sizeThatFits(.unspecified).width } ?? 0,
            lineHeight: sizes.map(\.height).max() ?? 0
        )
    }

    private func lines(_ m: Measured, maxWidth: CGFloat) -> [[Int]] {
        PackageNameFlow.lines(nameWidths: m.widths, separatorWidth: m.separatorWidth, gap: gap, maxWidth: maxWidth)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let m = measure(subviews)
        let maxWidth = proposal.width ?? .infinity
        let lines = lines(m, maxWidth: maxWidth)
        guard !lines.isEmpty else { return .zero }
        let joiner: CGFloat = 2 * gap + m.separatorWidth
        var widest: CGFloat = 0
        for line in lines {
            var width: CGFloat = 0
            for name in line { width += m.widths[name] }
            width += CGFloat(line.count - 1) * joiner
            widest = max(widest, width)
        }
        let lineCount = CGFloat(lines.count)
        let height: CGFloat = lineCount * m.lineHeight + (lineCount - 1) * lineSpacing
        return CGSize(width: widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let m = measure(subviews)
        var shown = Set<Int>()
        for (row, line) in lines(m, maxWidth: bounds.width).enumerated() {
            let y = bounds.minY + CGFloat(row) * (m.lineHeight + lineSpacing)
            var x = bounds.minX
            for (position, name) in line.enumerated() {
                if position > 0 {
                    let dot = m.dots[name - 1]
                    subviews[dot].place(at: CGPoint(x: x + gap, y: y), anchor: .topLeading, proposal: .unspecified)
                    shown.insert(dot)
                    x += 2 * gap + m.separatorWidth
                }
                subviews[m.names[name]].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .unspecified)
                x += m.widths[name]
            }
        }
        for dot in m.dots where !shown.contains(dot) {
            subviews[dot].place(at: CGPoint(x: bounds.minX - 10_000, y: bounds.minY), anchor: .topLeading, proposal: .unspecified)
        }
    }
}
