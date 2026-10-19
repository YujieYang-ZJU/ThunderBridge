import Testing
import Foundation
@testable import BridgeCore

@Suite(.serialized)
final class DownloadTests {
    let root: URL
    let source: URL
    let destination: URL
    let receivingState: URL
    let identity = UUID().uuidString
    var server: BridgeServer
    var client: BridgeClient
    init() async throws {
        root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".download-test-\(UUID().uuidString)")
        source = root.appendingPathComponent("remote")
        destination = root.appendingPathComponent("local")
        receivingState = root.appendingPathComponent("receipts")
        for url in [source, destination] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        server = BridgeServer(stateDirectory: root.appendingPathComponent("server"), machineID: identity)
        let port = try await server.start(address: "127.0.0.1", port: 0)
        client = BridgeClient(PeerConfiguration(host: "127.0.0.1", port: port))
    }
    deinit { server.stop(); try? FileManager.default.removeItem(at: root) }
    func restart() async throws {
        server.stop()
        server = BridgeServer(stateDirectory: root.appendingPathComponent("server"), machineID: identity)
        let port = try await server.start(address: "127.0.0.1", port: 0)
        client = BridgeClient(PeerConfiguration(host: "127.0.0.1", port: port))
    }
    func write(_ name: String, data: Data) throws -> URL {
        let url = source.appendingPathComponent(name)
        try data.write(to: url); return url
    }
    func download(_ plan: TransferPlan, changed: Bool = true) async throws -> TransferReport {
        try await client.download(plan, to: destination.path, onlyChanged: changed, stateDirectory: receivingState)
    }
    @Test func pullsNestedFolderHiddenEmptyFilesAndEmptyDirectories() async throws {
        let folder = source.appendingPathComponent("实验资料")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("空目录"), withIntermediateDirectories: true)
        try Data("中文内容".utf8).write(to: folder.appendingPathComponent("数据.txt"))
        try Data([3, 5, 8]).write(to: folder.appendingPathComponent(".隐藏"))
        try Data().write(to: folder.appendingPathComponent("空文件"))
        let plan = try await client.prepareDownload(folder.path)
        #expect(plan.fileCount == 3)
        let report = try await download(plan)
        #expect(report.files.allSatisfy { $0.verified })
        #expect(try Data(contentsOf: URL(fileURLWithPath: report.rootPath).appendingPathComponent("数据.txt")) == Data("中文内容".utf8))
        #expect(FileManager.default.fileExists(atPath: URL(fileURLWithPath: report.rootPath).appendingPathComponent("空目录").path))
        #expect(FileManager.default.fileExists(atPath: URL(fileURLWithPath: report.rootPath).appendingPathComponent(".隐藏").path))
    }
    @Test func uploadAndDownloadUseTheSameConnectionConfigurationWithoutLocalListener() async throws {
        let input = root.appendingPathComponent("上传再下载.bin")
        let bytes = Data(repeating: 0xB2, count: 2 * 1024 * 1024 + 17)
        try bytes.write(to: input)
        let uploaded = try await client.upload(TransferPlan.prepare(input), to: source.path)
        let plan = try await client.prepareDownload(uploaded)
        let received = try await download(plan)
        #expect(received.networkBytes == bytes.count)
        #expect(try Data(contentsOf: URL(fileURLWithPath: received.rootPath)) == bytes)
        #expect(received.files[0].verified)
    }
    @Test func downloadDeltaProtectsLocalOriginalAndRemembersRenamedCopy() async throws {
        let url = try write("同名.txt", data: Data("新内容".utf8))
        let original = destination.appendingPathComponent("同名.txt")
        try Data("原内容".utf8).write(to: original)
        let first = try await download(client.prepareDownload(url.path))
        #expect(first.rootPath != original.path)
        #expect(try Data(contentsOf: original) == Data("原内容".utf8))
        let again = try await download(client.prepareDownload(url.path))
        #expect(again.rootPath == first.rootPath)
        #expect(again.skippedCount == 1 && again.networkBytes == 0)
        let continuation = try await download(TransferPlan.prepare(url))
        #expect(continuation.skippedCount == 1)
    }
    @Test func changedRemoteSourceFailsBeforeCreatingFinalFile() async throws {
        let url = try write("会变化.txt", data: Data("before".utf8))
        let plan = try await client.prepareDownload(url.path)
        try Data("after changed".utf8).write(to: url)
        var records: [FileTransferRecord] = []
        do {
            _ = try await client.download(plan, to: destination.path, stateDirectory: receivingState, onFile: { records.append($0) })
            Issue.record("Changed source unexpectedly downloaded")
        } catch { #expect(error.localizedDescription.contains("变化")) }
        #expect(records.count == 1 && records[0].disposition == .failed && !records[0].verified)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }
    func interruptedDownload() async throws -> (TransferPlan, Data, URL) {
        let bytes = Data(repeating: 0xA5, count: 32 * 1024 * 1024 + 31)
        let url = try write("续传.bin", data: bytes)
        let plan = try await client.prepareDownload(url.path)
        var stopped = false
        do {
            _ = try await client.download(plan, to: destination.path, stateDirectory: receivingState, progress: { progress in
                if progress.phase == "下载中", progress.networkBytes > 0, !stopped {
                    stopped = true; self.server.stop()
                }
            })
            Issue.record("Interrupted download unexpectedly finished")
        } catch { #expect(stopped) }
        let journal = TransferJournal(directory: receivingState), node = plan.nodes[0]
        let key = try journal.key(kind: "file", parent: destination.path, name: node.url.lastPathComponent, transferID: node.id.uuidString)
        let partial = journal.temporary(parent: destination, key: key)
        #expect(FileManager.default.fileExists(atPath: partial.path))
        return (plan, bytes, partial)
    }
    @Test func reconnectAndReloadPlanResumesDownload() async throws {
        let (plan, bytes, partial) = try await interruptedDownload()
        let prior = try Data(contentsOf: partial).count
        #expect(prior > 0 && prior < bytes.count)
        let saved = root.appendingPathComponent("plan.json")
        try LocalStateStore.save(plan, to: saved)
        let restored = try LocalStateStore.read(TransferPlan.self, from: saved)
        try await restart()
        let report = try await download(restored)
        #expect(report.files[0].disposition == .resumed)
        #expect(report.files[0].resumedBytes == prior)
        #expect(report.networkBytes == bytes.count - prior)
        #expect(try Data(contentsOf: URL(fileURLWithPath: report.rootPath)) == bytes)
        let repeated = try await download(restored)
        #expect(repeated.files[0].disposition == .alreadyComplete && repeated.networkBytes == 0)
    }
    @Test func corruptedLocalPartialIsResetBeforeDownload() async throws {
        let (plan, bytes, partial) = try await interruptedDownload()
        let handle = try FileHandle(forWritingTo: partial)
        try handle.write(contentsOf: Data([0, 0, 0])); try handle.close()
        try await restart()
        let report = try await download(plan)
        #expect(report.networkBytes == bytes.count)
        #expect(report.files[0].resumedBytes == 0)
        #expect(try Data(contentsOf: URL(fileURLWithPath: report.rootPath)) == bytes)
    }
    @Test func symlinkDownloadIsRejected() async throws {
        let original = try write("真实.txt", data: Data("real".utf8))
        let link = source.appendingPathComponent("链接.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        do { _ = try await client.prepareDownload(link.path); Issue.record("Symlink unexpectedly accepted") }
        catch { #expect(error.localizedDescription.contains("符号链接")) }
    }
    @Test func invalidManifestCannotEscapeSelectedLocalDirectory() async throws {
        let url = try write("合法.txt", data: Data("data".utf8))
        let valid = try TransferPlan.prepare(url), node = valid.nodes[0]
        let invalid = PlanNode(id: node.id, url: url, relative: ["..", "outside.txt"], directory: false,
            size: node.size, modified: node.modified, permissions: node.permissions, checksum: node.checksum, stamp: node.stamp)
        let plan = TransferPlan(id: valid.id, source: valid.source, totalBytes: valid.totalBytes, fileCount: 1, nodes: [invalid])
        do { _ = try await download(plan); Issue.record("Invalid path unexpectedly accepted") }
        catch { #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty) }
    }
}
