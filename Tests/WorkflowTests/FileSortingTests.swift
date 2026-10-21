import Foundation
import Testing
@testable import BridgeCore
@testable import ThunderBridge

@MainActor
@Suite
final class FileSortingTests {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".test-fixture-sort-\(UUID())")
    let model: AppModel

    init() { model = AppModel(stateDirectory: root) }
    deinit { try? FileManager.default.removeItem(at: root) }

    func entry(_ name: String, size: Int64 = 0, modified: Date? = nil, folder: Bool = false) -> RemoteEntry {
        RemoteEntry(name: name, path: "/fixture/" + name, isDirectory: folder, isSymbolicLink: false,
                    size: size, modified: modified)
    }
    var names: [String] { model.visibleEntries.map(\.name) }

    @Test func namesUseNaturalOrderInBothDirectionsWithFoldersFirst() {
        defer { model.shutdown() }
        model.entries = [entry("报告10.pdf"), entry("资料10", folder: true), entry("报告2.pdf"), entry("资料2", folder: true)]
        #expect(names == ["资料2", "资料10", "报告2.pdf", "报告10.pdf"])
        model.sortOrder[0].order = .reverse
        #expect(names == ["资料10", "资料2", "报告10.pdf", "报告2.pdf"])
    }

    @Test func sizeUsesBytesAcrossUnitsAndKeepsFolderRowsTogether() {
        defer { model.shutdown() }
        model.entries = [entry("A.txt", size: 1024), entry("B.mov", size: 2_000_000), entry("Z.txt", size: 2),
                         entry("空文件", size: 0), entry("资料", size: 9_000_000, folder: true)]
        model.sortOrder = [RemoteEntryComparator(.size)]
        #expect(names == ["资料", "空文件", "Z.txt", "A.txt", "B.mov"])
        model.sortOrder[0].order = .reverse
        #expect(names == ["资料", "B.mov", "A.txt", "Z.txt", "空文件"])
    }

    @Test func datesUseChronologicalOrderAndUnknownDatesStayLast() {
        defer { model.shutdown() }
        model.entries = [entry("最新", modified: Date(timeIntervalSince1970: 1_700_000_000)), entry("未知"),
                         entry("最早", modified: Date(timeIntervalSince1970: 0)), entry("中间", modified: Date(timeIntervalSince1970: 100))]
        model.sortOrder = [RemoteEntryComparator(.modified)]
        #expect(names == ["最早", "中间", "最新", "未知"])
        model.sortOrder[0].order = .reverse
        #expect(names == ["最新", "中间", "最早", "未知"])
    }

    @Test func equalValuesUseStableNamesAndSecondarySortColumns() {
        defer { model.shutdown() }
        let date = Date(timeIntervalSince1970: 100)
        let entries = [entry("报告10.pdf", size: 7, modified: date), entry("报告2.pdf", size: 7, modified: date)]
        model.entries = entries
        model.sortOrder = [RemoteEntryComparator(.size, order: .reverse)]
        #expect(names == ["报告2.pdf", "报告10.pdf"])
        model.entries.reverse()
        #expect(names == ["报告2.pdf", "报告10.pdf"])
        model.sortOrder = [RemoteEntryComparator(.modified), RemoteEntryComparator(.name, order: .reverse)]
        #expect(names == ["报告10.pdf", "报告2.pdf"])
        let sameNameEntries = [entry("a.txt", size: 7), entry("A.txt", size: 7)]
        model.entries = sameNameEntries
        model.sortOrder = [RemoteEntryComparator(.size)]
        let firstOrder = names
        model.entries.reverse()
        #expect(names == firstOrder)
    }

    @Test func filteringAndDirectoryUpdatesRefreshTheCacheWithoutChangingSelection() {
        defer { model.shutdown() }
        let selected = entry("报告2.pdf", size: 20)
        model.entries = [entry("报告10.pdf", size: 100), selected, entry(".隐藏", size: 50)]
        model.selectedPaths = [selected.path]
        #expect(names == ["报告2.pdf", "报告10.pdf"])
        model.sortOrder = [RemoteEntryComparator(.size, order: .reverse)]
        #expect(names == ["报告10.pdf", "报告2.pdf"])
        model.showHidden = true
        #expect(names == ["报告10.pdf", ".隐藏", "报告2.pdf"])
        model.search = "报告2"
        #expect(names == ["报告2.pdf"])
        #expect(model.selectedEntries.map(\.path) == [selected.path])
        model.search = ""
        model.entries.append(entry("追加", size: 200))
        #expect(names.first == "追加")
        #expect(model.selectedPaths == [selected.path])
        model.entries = [entry("新目录小文件", size: 1), entry("新目录大文件", size: 500)]
        #expect(names == ["新目录大文件", "新目录小文件"])
        model.sortOrder = []
        #expect(names == model.entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map(\.name))
    }
}
