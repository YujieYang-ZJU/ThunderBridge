import Testing
import Foundation
import Network
import CryptoKit
@testable import BridgeCore

@Suite(.serialized)
final class ResumeAndDeltaTests {
    let root: URL
    let journal: URL
    let source: URL
    let destination: URL
    let identity = UUID().uuidString
    var server: BridgeServer
    var client: BridgeClient
    var port: UInt16

    init() async throws {
        root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".test-fixture-\(UUID().uuidString)")
        journal = root.appendingPathComponent("journal")
        source = root.appendingPathComponent("source")
        destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        server = BridgeServer(stateDirectory: journal, machineID: identity)
        port = try await server.start(address: "127.0.0.1", port: 0)
        client = BridgeClient(PeerConfiguration(host: "127.0.0.1", port: port))
    }
    deinit { server.stop(); try? FileManager.default.removeItem(at: root) }

    func file(_ name: String = "数据.bin", bytes: Data) throws -> TransferPlan {
        let url = source.appendingPathComponent(name)
        try bytes.write(to: url)
        return try TransferPlan.prepare(url)
    }
    func channel() async throws -> Channel {
        let c = Channel(NWConnection(host: "127.0.0.1", port: .init(rawValue: port)!, using: ConnectionSecurity.parameters()))
        try await c.start(); return c
    }
    func begin(_ plan: TransferPlan) async throws -> Channel {
        let c = try await channel(), node = plan.nodes[0]
        try await c.sendMessage(Message(command: "upload", path: destination.path, name: node.url.lastPathComponent,
            size: node.size, checksum: node.checksum, transferID: node.id.uuidString, onlyChanged: false))
        let ready = try await c.readMessage()
        #expect(ready.command == "ready")
        return c
    }
    func partialURL(_ plan: TransferPlan) throws -> URL {
        let node = plan.nodes[0]
        let key = try server.journal.key(kind: "file", parent: destination.path, name: node.url.lastPathComponent, transferID: node.id.uuidString)
        return server.journal.temporary(parent: destination, key: key)
    }
    func interrupt(_ plan: TransferPlan, prefix: Data) async throws {
        let c = try await begin(plan)
        try await c.sendFrame(type: 2, data: prefix)
        let part = try partialURL(plan)
        for _ in 0..<100 {
            if (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.intValue == prefix.count { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(try Data(contentsOf: part) == prefix)
        let waiting = Task { try await c.readMessage() }
        waiting.cancel()
        do { _ = try await waiting.value; Issue.record("Cancellation must fail") } catch {}
        c.close()
        let node = plan.nodes[0]
        let key = try server.journal.key(kind: "file", parent: destination.path, name: node.url.lastPathComponent, transferID: node.id.uuidString)
        for _ in 0..<100 {
            if let lease = try? server.journal.lease(key) { withExtendedLifetime(lease) {}; return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("Receiver did not release its lease")
    }

    @Test func restartAndRePairResumesOnlyRemainingBytes() async throws {
        let bytes = Data((0..<(Channel.chunkSize * 3 + 17)).map { UInt8($0 % 251) })
        let plan = try file(bytes: bytes)
        try await interrupt(plan, prefix: Data(bytes.prefix(Channel.chunkSize)))
        let manifest = root.appendingPathComponent("saved-plan.json")
        try LocalStateStore.save(plan, to: manifest)
        let restored = try LocalStateStore.read(TransferPlan.self, from: manifest)
        #expect(restored.nodes[0].id == plan.nodes[0].id)
        server.stop()
        server = BridgeServer(stateDirectory: journal, machineID: identity)
        port = try await server.start(address: "127.0.0.1", port: 0)
        client = BridgeClient(PeerConfiguration(host: "127.0.0.1", port: port))
        #expect(try await client.hello().id == identity)
        let report = try await client.transfer(restored, to: destination.path)
        #expect(report.files[0].disposition == .resumed)
        #expect(report.files[0].resumedBytes == Channel.chunkSize)
        #expect(report.networkBytes == bytes.count - Channel.chunkSize)
        #expect(report.files[0].verified)
        #expect(try Data(contentsOf: URL(fileURLWithPath: report.rootPath)) == bytes)
        #expect(!FileManager.default.fileExists(atPath: try partialURL(plan).path))
    }

    @Test func corruptedPartialRestartsAndVerifiesWholeFile() async throws {
        let bytes = Data(repeating: 0x42, count: Channel.chunkSize + 123)
        let plan = try file(bytes: bytes)
        try await interrupt(plan, prefix: Data(repeating: 0xFF, count: 1024))
        let report = try await client.transfer(plan, to: destination.path)
        #expect(report.networkBytes == bytes.count)
        #expect(report.files[0].resumedBytes == 0)
        #expect(report.files[0].verified)
        #expect(try Data(contentsOf: URL(fileURLWithPath: report.rootPath)) == bytes)
    }

    @Test func repeatedCompletionDoesNotDuplicateEvenWithRenamedTarget() async throws {
        try Data("original".utf8).write(to: destination.appendingPathComponent("same.txt"))
        let plan = try file("same.txt", bytes: Data("new".utf8))
        let first = try await client.transfer(plan, to: destination.path, onlyChanged: false)
        let retry = try await client.transfer(plan, to: destination.path, onlyChanged: false)
        #expect(first.rootPath == retry.rootPath)
        #expect(retry.files[0].disposition == .alreadyComplete)
        #expect(retry.networkBytes == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).count == 2)
        #expect(try String(contentsOf: destination.appendingPathComponent("same.txt")) == "original")
    }

    @Test func renameIntentRecoversAfterCommitWithoutReceiptAcknowledgement() async throws {
        let plan = try file(bytes: Data("committed".utf8))
        let first = try await client.transfer(plan, to: destination.path)
        let node = plan.nodes[0]
        let key = try server.journal.key(kind: "file", parent: destination.path, name: node.url.lastPathComponent, transferID: node.id.uuidString)
        var receipt = try #require(try server.journal.read(key))
        receipt.completed = false
        try server.journal.save(receipt, key: key)
        let retry = try await client.transfer(plan, to: destination.path)
        #expect(retry.rootPath == first.rootPath)
        #expect(retry.files[0].disposition == .alreadyComplete)
    }

    @Test func deltaUsesContentAndRemembersConflictCopies() async throws {
        let a = source.appendingPathComponent("same.txt"), b = destination.appendingPathComponent("same.txt")
        try Data("old".utf8).write(to: b)
        try Data("new".utf8).write(to: a)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: a.path)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: b.path)
        let changed = try await client.transfer(TransferPlan.prepare(a), to: destination.path)
        #expect(changed.networkBytes == 3)
        #expect(changed.rootPath.hasSuffix("same (1).txt"))
        let unchanged = try await client.transfer(TransferPlan.prepare(a), to: destination.path)
        #expect(unchanged.files[0].disposition == .skipped)
        #expect(unchanged.rootPath == changed.rootPath)
        #expect(unchanged.networkBytes == 0)
        #expect(try String(contentsOf: b) == "old")
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).count == 2)
    }

    @Test func incrementalFolderAddsOneFileAndDoesNotDeleteRemoteExtras() async throws {
        let project = source.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("unchanged".utf8).write(to: project.appendingPathComponent("a.txt"))
        let first = try await client.transfer(TransferPlan.prepare(project), to: destination.path)
        try Data("remote-only".utf8).write(to: URL(fileURLWithPath: first.rootPath).appendingPathComponent("keep.txt"))
        try Data("new file".utf8).write(to: project.appendingPathComponent("b.txt"))
        let delta = try await client.transfer(TransferPlan.prepare(project), to: destination.path)
        #expect(delta.rootPath == first.rootPath)
        #expect(delta.skippedCount == 1)
        #expect(delta.networkBytes == 8)
        #expect(FileManager.default.fileExists(atPath: first.rootPath + "/keep.txt"))
        #expect(delta.files.allSatisfy { $0.verified })
    }

    @Test func sameTaskCannotWritePartialConcurrently() async throws {
        let plan = try file(bytes: Data(repeating: 1, count: 100))
        let first = try await begin(plan)
        defer { first.close() }
        do { _ = try await client.transfer(plan, to: destination.path); Issue.record("Duplicate task must be locked") }
        catch { #expect(error.localizedDescription.contains("其他任务")) }
    }

    @Test func clearingResumeCacheKeepsFinalFilesAndRestartsPendingFile() async throws {
        let complete = try file("keep.txt", bytes: Data("keep".utf8))
        let saved = try await client.transfer(complete, to: destination.path)
        let bytes = Data(repeating: 7, count: 2048), plan = try file("paused.bin", bytes: bytes)
        try await interrupt(plan, prefix: Data(bytes.prefix(100)))
        #expect(try server.clearIncompleteTransfers() == 1)
        #expect(FileManager.default.fileExists(atPath: saved.rootPath))
        let restarted = try await client.transfer(plan, to: destination.path)
        #expect(restarted.networkBytes == 2048)
        #expect(restarted.files[0].verified)
    }

    @Test func changedCompletedTargetIsNotSilentlyTrusted() async throws {
        let plan = try file(bytes: Data("original".utf8))
        let saved = try await client.transfer(plan, to: destination.path)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: saved.rootPath))
        try handle.write(contentsOf: Data("tampered".utf8)); try handle.close()
        do { _ = try await client.transfer(plan, to: destination.path); Issue.record("Modified destination must fail revalidation") }
        catch { #expect(error.localizedDescription.contains("修改")) }
    }

    @Test func auditExportsVerifiedAndPendingEntriesWithEscapedCSV() async throws {
        let plan = try file("quoted,\"file\".txt", bytes: Data("verified".utf8))
        let before = plan.auditRecords(existing: [], destination: destination.path)
        #expect(before.count == 1 && !before[0].verified && before[0].disposition == .pending)
        let transferred = try await client.transfer(plan, to: destination.path)
        let job = AuditJob(id: UUID(), peerID: identity, peerName: "=UNTRUSTED()", source: plan.source.path,
            destination: destination.path, state: "已完成", onlyChanged: true, records: transferred.files)
        let report = AuditReport(jobs: [job])
        let json = try report.json(), decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AuditReport.self, from: json)
        #expect(decoded.jobs[0].records[0].verified)
        #expect(report.csv().contains("'=UNTRUSTED()"))
        #expect(report.csv().contains("quoted,\"\"file\"\".txt"))
    }
}
