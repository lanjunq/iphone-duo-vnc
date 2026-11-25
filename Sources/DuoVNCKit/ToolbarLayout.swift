import Foundation
import CoreGraphics

/// Places the session toolbar's buttons inside `LayoutEngine.Output.toolbarFrame`.
///
/// The toolbar is split into lanes (rows for a bottom bar, columns for a side bar). Each lane is cut
/// into segments around the keep-out rects (the fold crossing the bar). Items keep their visual order
/// and are spread over the segments in reading order; an item's length is proportional to its weight.
/// The fewest lanes that fit every item are used (each unit of weight needs `minItemLength`); if even
/// the maximum number of lanes is not enough, items with the largest `priority` value are hidden first
/// (the app shows those in an overflow menu).
public enum ToolbarLayout {
    public struct Item: Equatable, Sendable {
        public var id: String
        /// Relative length (1 = normal button, 2 = the big click button). Values < 1 count as 1.
        public var weight: Int
        /// Lower = more important. Items with higher values are hidden first when space runs out.
        public var priority: Int

        public init(id: String, weight: Int = 1, priority: Int = 0) {
            self.id = id
            self.weight = max(1, weight)
            self.priority = priority
        }
    }

    public struct Placement: Equatable, Sendable {
        /// Frame of every visible item, in the same coordinate space as the toolbar frame.
        public var frames: [String: CGRect]
        /// Items that did not fit, in their visual order.
        public var hidden: [String]
        /// Number of lanes used.
        public var lanes: Int
    }

    public static func layout(items: [Item], in frame: CGRect, axis: LayoutEngine.ToolbarAxis,
                              keepOut: [CGRect] = [], minItemLength: CGFloat = 44,
                              minLaneThickness: CGFloat = 44, maxLaneThickness: CGFloat = 72,
                              maxLanes: Int = 6, spacing: CGFloat = 4, inset: CGFloat = 4) -> Placement {
        let allIDs = items.map { $0.id }
        let f = frame.standardized
        guard !items.isEmpty, f.width.isFinite, f.height.isFinite, f.origin.x.isFinite, f.origin.y.isFinite else {
            return Placement(frames: [:], hidden: allIDs, lanes: 0)
        }
        let content = f.insetBy(dx: inset, dy: inset)
        guard !content.isNull, content.width > 0, content.height > 0 else {
            return Placement(frames: [:], hidden: allIDs, lanes: 0)
        }
        let thickness = axis == .bottom ? content.height : content.width
        let unit = max(1, minItemLength)
        let laneMin = max(1, minLaneThickness)
        let possibleLanes = max(1, min(max(1, maxLanes), Int(((thickness + spacing) / (laneMin + spacing)).rounded(.down))))

        let totalWeight = items.reduce(0) { $0 + $1.weight }
        var chosenLanes = possibleLanes
        var chosenSegments: [CGRect] = []
        for k in 1...possibleLanes {
            let segs = segments(lanes: k, content: content, axis: axis, keepOut: keepOut,
                                spacing: spacing, minLength: unit, maxLaneThickness: maxLaneThickness)
            let cap = segs.reduce(0) { $0 + capacity(of: $1, axis: axis, unit: unit, spacing: spacing) }
            if cap >= totalWeight || k == possibleLanes {
                chosenLanes = k
                chosenSegments = segs
                break
            }
        }

        // Drop items by priority until everything can be distributed.
        var visible = items
        var hidden: Set<String> = []
        while !visible.isEmpty {
            if let frames = distribute(visible, segments: chosenSegments, axis: axis, unit: unit, spacing: spacing) {
                let hiddenOrdered = allIDs.filter { hidden.contains($0) }
                return Placement(frames: frames, hidden: hiddenOrdered, lanes: chosenLanes)
            }
            // Remove the least important item (highest priority value; the later one on ties).
            var worst = 0
            for i in visible.indices where visible[i].priority >= visible[worst].priority { worst = i }
            hidden.insert(visible[worst].id)
            visible.remove(at: worst)
        }
        return Placement(frames: [:], hidden: allIDs, lanes: chosenLanes)
    }

    // MARK: Internals

    static func capacity(of segment: CGRect, axis: LayoutEngine.ToolbarAxis, unit: CGFloat, spacing: CGFloat) -> Int {
        let len = axis == .bottom ? segment.width : segment.height
        return max(0, Int(((len + spacing) / (unit + spacing)).rounded(.down)))
    }

    /// Lanes packed toward the outer edge (bottom of a bottom bar, right of a side bar), each cut around keep-outs.
    static func segments(lanes k: Int, content: CGRect, axis: LayoutEngine.ToolbarAxis, keepOut: [CGRect],
                         spacing: CGFloat, minLength: CGFloat, maxLaneThickness: CGFloat) -> [CGRect] {
        let thickness = axis == .bottom ? content.height : content.width
        let laneT = min(max(1, maxLaneThickness), (thickness - spacing * CGFloat(k - 1)) / CGFloat(k))
        guard laneT > 0 else { return [] }
        let used = laneT * CGFloat(k) + spacing * CGFloat(k - 1)
        let start = (axis == .bottom ? content.minY : content.minX) + (thickness - used)
        var out: [CGRect] = []
        for lane in 0..<k {
            let p = start + CGFloat(lane) * (laneT + spacing)
            let laneRect: CGRect = axis == .bottom
                ? CGRect(x: content.minX, y: p, width: content.width, height: laneT)
                : CGRect(x: p, y: content.minY, width: laneT, height: content.height)
            // Blocked intervals along the lane's length axis.
            var blocked: [(CGFloat, CGFloat)] = []
            for r in keepOut {
                let s = r.standardized
                guard s.origin.x.isFinite, s.origin.y.isFinite, s.width.isFinite, s.height.isFinite else { continue }
                let i = s.intersection(laneRect)
                if i.isNull || (i.width <= 0 && i.height <= 0) { continue }
                if axis == .bottom {
                    blocked.append((s.minX - spacing, s.maxX + spacing))
                } else {
                    blocked.append((s.minY - spacing, s.maxY + spacing))
                }
            }
            blocked.sort { $0.0 < $1.0 }
            var cursor = axis == .bottom ? laneRect.minX : laneRect.minY
            let end = axis == .bottom ? laneRect.maxX : laneRect.maxY
            func emit(_ a: CGFloat, _ b: CGFloat) {
                guard b - a >= minLength else { return }
                if axis == .bottom {
                    out.append(CGRect(x: a, y: laneRect.minY, width: b - a, height: laneRect.height))
                } else {
                    out.append(CGRect(x: laneRect.minX, y: a, width: laneRect.width, height: b - a))
                }
            }
            for (a, b) in blocked {
                if a > cursor { emit(cursor, min(a, end)) }
                cursor = max(cursor, b)
                if cursor >= end { break }
            }
            if cursor < end { emit(cursor, end) }
        }
        return out
    }

    /// Spreads items over segments in order. Returns nil if they do not all fit.
    static func distribute(_ items: [Item], segments: [CGRect], axis: LayoutEngine.ToolbarAxis,
                           unit: CGFloat, spacing: CGFloat) -> [String: CGRect]? {
        let caps = segments.map { capacity(of: $0, axis: axis, unit: unit, spacing: spacing) }
        var remainingWeight = items.reduce(0) { $0 + $1.weight }
        var remainingCap = caps.reduce(0, +)
        guard remainingCap >= remainingWeight else { return nil }
        var frames: [String: CGRect] = [:]
        var index = 0
        for (j, seg) in segments.enumerated() {
            guard index < items.count else { break }
            let cap = caps[j]
            if cap == 0 { continue }
            let isLast = j == segments.count - 1
            let share = Int((Double(remainingWeight) * Double(cap) / Double(max(1, remainingCap))).rounded(.up))
            let target = isLast ? cap : min(cap, share)
            var taken: [Item] = []
            var w = 0
            while index < items.count {
                let it = items[index]
                if w + it.weight <= target || (taken.isEmpty && it.weight <= cap) {
                    taken.append(it)
                    w += it.weight
                    index += 1
                } else {
                    break
                }
            }
            remainingWeight -= w
            remainingCap -= cap
            guard !taken.isEmpty else { continue }
            let len = axis == .bottom ? seg.width : seg.height
            let usable = len - spacing * CGFloat(taken.count - 1)
            var pos = axis == .bottom ? seg.minX : seg.minY
            for it in taken {
                let l = usable * CGFloat(it.weight) / CGFloat(w)
                let r: CGRect = axis == .bottom
                    ? CGRect(x: pos, y: seg.minY, width: l, height: seg.height)
                    : CGRect(x: seg.minX, y: pos, width: seg.width, height: l)
                frames[it.id] = r
                pos += l + spacing
            }
        }
        return index == items.count ? frames : nil
    }
}
