import Foundation

/// How a click should change the selection, following Finder's conventions.
public enum SelectionClick: Equatable {
    /// Plain click: select only this item.
    case replace
    /// ⌘-click or Control-click: add or remove this item, keeping the rest.
    case toggle
    /// Shift-click: select the range from the anchor to this item.
    case extend
    /// ⌘-Shift-click: add the range from the anchor to this item to the current selection.
    case extendAdding

    public init(command: Bool, control: Bool, shift: Bool) {
        let toggle = command || control
        switch (toggle, shift) {
        case (true, true): self = .extendAdding
        case (false, true): self = .extend
        case (true, false): self = .toggle
        case (false, false): self = .replace
        }
    }
}

public enum SelectionMove: Equatable {
    case left, right, up, down, first, last, pageUp, pageDown
}

public enum GroupSelection: Equatable {
    case none, some, all
}

/// Selection with an anchor (start of Shift ranges) and a cursor (the item the keyboard moves from).
public struct SelectionState: Equatable {
    public private(set) var selected: Set<UInt32> = []
    public private(set) var anchor: UInt32?
    public private(set) var cursor: UInt32?
    /// Items selected before the current Shift range started, kept when the range grows or shrinks.
    private var base: Set<UInt32> = []

    public init() {}

    public func contains(_ id: UInt32) -> Bool { selected.contains(id) }

    public mutating func click(_ id: UInt32, kind: SelectionClick, order: [UInt32]) {
        switch kind {
        case .replace:
            selected = [id]
            base = []
            anchor = id
        case .toggle:
            if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
            anchor = id
            base = selected.subtracting([id])
        case .extend, .extendAdding:
            guard let anchor, order.contains(anchor) else {
                click(id, kind: kind == .extend ? .replace : .toggle, order: order)
                return
            }
            // ⌘-Shift keeps everything already selected; plain Shift keeps only what preceded the current range.
            if kind == .extendAdding { base = selected }
            selected = base.union(Self.range(from: anchor, to: id, in: order))
        }
        cursor = id
    }

    /// Moves the cursor to `target`; with `extend`, grows or shrinks the Shift range instead of replacing the selection.
    public mutating func move(to target: UInt32, extend: Bool, order: [UInt32]) {
        if extend, let anchor, order.contains(anchor) {
            selected = base.union(Self.range(from: anchor, to: target, in: order))
        } else {
            selected = [target]
            base = []
            anchor = target
        }
        cursor = target
    }

    public mutating func selectAll(_ order: [UInt32]) {
        selected = Set(order)
        base = []
        anchor = order.first
        cursor = cursor.flatMap { order.contains($0) ? $0 : nil } ?? order.first
    }

    /// Selects every item in a group (keeping the rest of the selection unless `exclusive`), or deselects the group
    /// when all of its items are already selected. The group's first item becomes the anchor for Shift ranges.
    public mutating func toggleGroup(_ ids: [UInt32], exclusive: Bool = false) {
        guard let first = ids.first else { return }
        let group = Set(ids)
        if !exclusive, group.isSubset(of: selected) {
            selected.subtract(group)
        } else {
            selected = exclusive ? group : selected.union(group)
        }
        base = selected
        anchor = first
        cursor = first
    }

    public mutating func deselectGroup(_ ids: [UInt32]) {
        selected.subtract(ids)
        base = selected
    }

    public func groupState(_ ids: [UInt32]) -> GroupSelection {
        let count = ids.reduce(0) { $0 + (selected.contains($1) ? 1 : 0) }
        if count == 0 { return .none }
        return count == ids.count ? .all : .some
    }

    public mutating func clear() {
        self = SelectionState()
    }

    /// Drops items that are no longer listed (after a refresh or delete).
    public mutating func retain(_ ids: Set<UInt32>) {
        selected.formIntersection(ids)
        base.formIntersection(ids)
        if let anchor, !ids.contains(anchor) { self.anchor = nil }
        if let cursor, !ids.contains(cursor) { self.cursor = nil }
    }

    private static func range(from start: UInt32, to end: UInt32, in order: [UInt32]) -> Set<UInt32> {
        guard let first = order.firstIndex(of: start), let last = order.firstIndex(of: end) else { return [end] }
        return Set(order[min(first, last)...max(first, last)])
    }
}

/// Keyboard navigation for a list (one column) or a sectioned grid, where every section starts a new row.
public enum SelectionNavigator {
    public static func target(
        from current: UInt32?, move: SelectionMove, sections: [[UInt32]], columns: Int, pageRows: Int = 5
    ) -> UInt32? {
        let rows = sections.flatMap { section in
            stride(from: 0, to: section.count, by: max(columns, 1)).map {
                Array(section[$0..<min($0 + max(columns, 1), section.count)])
            }
        }
        let order = rows.flatMap { $0 }
        guard let first = order.first, let last = order.last else { return nil }
        guard let current, let index = order.firstIndex(of: current) else {
            switch move {
            case .up, .left, .last, .pageUp: return last
            default: return first
            }
        }
        switch move {
        case .left: return order[max(index - 1, 0)]
        case .right: return order[min(index + 1, order.count - 1)]
        case .first: return first
        case .last: return last
        case .up, .down, .pageUp, .pageDown:
            guard let row = rows.firstIndex(where: { $0.contains(current) }),
                  let column = rows[row].firstIndex(of: current) else { return current }
            let step: Int
            switch move {
            case .up: step = -1
            case .down: step = 1
            case .pageUp: step = -max(pageRows, 1)
            default: step = max(pageRows, 1)
            }
            let targetRow = min(max(row + step, 0), rows.count - 1)
            if targetRow == row {
                // Already on the first or last row: go to the very first or last item, like Finder.
                return step < 0 ? rows[row].first : rows[row].last
            }
            return rows[targetRow][min(column, rows[targetRow].count - 1)]
        }
    }

    /// Mirrors `GridItem.adaptive(minimum:maximum:)` column fitting.
    public static func adaptiveColumns(width: Double, minimum: Double, spacing: Double, padding: Double) -> Int {
        let available = width - padding * 2
        return max(1, Int(((available + spacing) / (minimum + spacing)).rounded(.down)))
    }
}
