import Foundation
import BridgeCore

struct RemoteEntryComparator: SortComparator {
    enum Column: Hashable { case name, size, modified }

    let column: Column
    var order: SortOrder

    init(_ column: Column, order: SortOrder = .forward) {
        self.column = column
        self.order = order
    }

    func compare(_ lhs: RemoteEntry, _ rhs: RemoteEntry) -> ComparisonResult {
        // Keep the existing folder-first layout in either direction.
        if lhs.isDirectory != rhs.isDirectory {
            return lhs.isDirectory ? .orderedAscending : .orderedDescending
        }
        let result: ComparisonResult
        switch column {
        case .name:
            result = lhs.name.localizedStandardCompare(rhs.name)
        case .size:
            // Folder rows display “文件夹”, not a recursive byte count.
            result = lhs.isDirectory ? .orderedSame : compareValues(lhs.size, rhs.size)
        case .modified:
            switch (lhs.modified, rhs.modified) {
            case let (left?, right?): result = compareValues(left, right)
            case (nil, nil): result = .orderedSame
            case (nil, _): return .orderedDescending
            case (_, nil): return .orderedAscending
            }
        }
        guard order == .reverse else { return result }
        switch result {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }

    private func compareValues<Value: Comparable>(_ lhs: Value, _ rhs: Value) -> ComparisonResult {
        lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
    }
}
