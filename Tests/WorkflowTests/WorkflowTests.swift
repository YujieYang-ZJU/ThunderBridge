import Foundation
import Network
import Testing
import BridgeCore
@testable import ThunderBridge

@MainActor
@Suite(.serialized)
final class WorkflowTests {
    let root: URL
    let destination: URL
    let state: URL
    let identity = UUID().uuidString
    let server: BridgeServer
    let model: AppModel
    var port: UInt16

    init() async throws {
        root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".workflow-test-\(UUID().uuidString)")
        destination = root.appendingPathComponent("destination")
        state = root.appendingPathComponent("application-state")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        server = BridgeServer(stateDirectory: root.appendingPathComponent("receiver"), machineID: identity)
        port = try await server.start(address: "127.0.0.1", port: 0)
        model = AppModel(stateDirectory: state)
        model.host = "127.0.0.1"; model.port = String(port); model.localAddress = "127.0.0.1"
    }
    deinit { server.stop(); try? FileManager.default.removeItem(at: root) }
    func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(condition())
        if !condition() { throw BridgeError("工作流测试等待超时。") }
    }
    func connect() async throws {
        model.connect(); try await wait { !model.connecting }
        #expect(model.connected)
        model.browse(destination.path); try await wait { !model.loading }
        #expect(model.path == destination.path)
    }
    func source(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data((name + "内容").utf8).write(to: url)
        return url
    }
    @Test func queueSurvivesDisconnectAndRelaunchWithSharingOff() async throws {
        defer { model.shutdown() }
        try await connect()
        model.add([try source("保留.txt")], immediately: false)
        try await wait { !model.preparing }
        #expect(model.jobs.count == 1)
        model.disconnect()
        #expect(model.jobs.count == 1)
        let restored = AppModel(stateDirectory: state)
        defer { restored.shutdown() }
        #expect(restored.jobs.count == 1)
        #expect(restored.jobs[0].peerID == identity)
        #expect(!restored.jobs[0].approved)
        #expect(!restored.connected)
        #expect(!restored.sharing)
        let json = try String(contentsOf: state.appendingPathComponent("workspace-v3.json"), encoding: .utf8)
        #expect(!json.contains("remoteCode"))
    }
    @Test func immediateBatchDoesNotSendEarlierUnapprovedItems() async throws {
        defer { model.shutdown() }
        try await connect()
        model.add([try source("等待确认.txt")], immediately: false)
        try await wait { !model.preparing }
        model.add([try source("立即发送.txt")], immediately: true)
        try await wait { !model.preparing && !model.running }
        #expect(model.jobs[0].state == "等待发送")
        #expect(model.jobs[1].state == "已完成")
        #expect(model.jobs[1].verifiedCount == 1)
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("等待确认.txt").path))
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("立即发送.txt").path))
    }
    @Test func favoritesAndPresetsPersistByDeviceAndDeliverCurrentContents() async throws {
        defer { model.shutdown() }
        try await connect()
        let original = try source("来源.txt")
        model.toggleFavorite()
        let preset = DeliveryPreset(name: "每日资料", peerID: identity, peerName: "接收端", destination: destination.path, sources: [original], onlyChanged: true)
        model.presets.append(preset)
        model.disconnect() // flush persistence
        let restored = AppModel(stateDirectory: state)
        defer { restored.shutdown() }
        #expect(restored.favorites.count == 1 && restored.presets.count == 1)
        restored.peerID = UUID().uuidString
        #expect(restored.currentFavorites.isEmpty && restored.currentPresets.isEmpty)
        restored.peerID = identity
        #expect(restored.currentFavorites.count == 1 && restored.currentPresets.count == 1)
        try Data("投递前的新内容".utf8).write(to: original)
        try await connect()
        model.deliver(preset)
        try await wait { !model.preparing && !model.running }
        #expect(model.jobs.last?.state == "已完成")
        #expect(try Data(contentsOf: destination.appendingPathComponent("来源.txt")) == Data("投递前的新内容".utf8))
        model.deliver(preset)
        try await wait { !model.preparing && !model.running }
        #expect(model.jobs.last?.skippedCount == 1)
        #expect(model.jobs.last?.networkBytes == 0)
    }
    @Test func restoredRunningJobsArePausedAndOnlyCurrentPeerCanBeSent() async throws {
        defer { model.shutdown() }
        let plan = try TransferPlan.prepare(source("恢复.txt"))
        let another = UUID().uuidString
        let active = TransferJob(plan: plan, destination: destination.path, peerID: identity, peerName: "原设备", onlyChanged: true, state: "发送中", approved: true)
        let wrongPeer = TransferJob(plan: plan, destination: destination.path, peerID: another, peerName: "其他设备", onlyChanged: true, approved: true)
        try LocalStateStore.save(WorkspaceArchive(machineID: UUID().uuidString, jobs: [active, wrongPeer], favorites: [], presets: [], host: "127.0.0.1", port: String(port), onlyChanged: true, directDrop: true), to: state.appendingPathComponent("workspace-v3.json"))
        let restored = AppModel(stateDirectory: state)
        defer { restored.shutdown() }
        #expect(restored.jobs[0].state == "已暂停")
        #expect(restored.jobs.allSatisfy { !$0.approved })
        restored.localAddress = "127.0.0.1"
        restored.connect(); try await wait { !restored.connecting }
        restored.sendPending(); try await wait { !restored.running }
        #expect(restored.jobs[0].state == "已完成")
        #expect(restored.jobs[1].state == "等待发送")
    }
    @Test func changedPeerAtSameAddressCannotReceiveAnOldJob() async throws {
        defer { model.shutdown() }
        try await connect()
        model.add([try source("设备绑定.txt")], immediately: false)
        try await wait { !model.preparing }
        server.stop()
        let replacement = BridgeServer(stateDirectory: root.appendingPathComponent("replacement"), machineID: UUID().uuidString)
        defer { replacement.stop() }
        // NWListener.cancel releases its port asynchronously. Wait only for that
        // condition before reusing the endpoint with a different device.
        for attempt in 0..<20 {
            do { _ = try await replacement.start(address: "127.0.0.1", port: port); break }
            catch let error as Network.NWError {
                guard case .posix(.EADDRINUSE) = error, attempt < 19 else { throw error }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        model.sendPending(); try await wait { !model.running }
        #expect(model.jobs[0].state == "失败")
        #expect(model.jobs[0].detail.contains("另一台设备"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }
    @Test func queuedDownloadsRestoreDirectionAndRunWithoutEnablingLocalSharing() async throws {
        defer { model.shutdown() }
        try await connect()
        let remoteFile = destination.appendingPathComponent("远端文件.txt")
        try Data("远端内容".utf8).write(to: remoteFile)
        let localFolder = root.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: localFolder, withIntermediateDirectories: true)
        model.addDownloads([remoteFile.path], to: localFolder, immediately: false)
        try await wait { !model.preparing }
        #expect(model.jobs.count == 1 && model.jobs[0].isDownload)
        model.disconnect()
        let restored = AppModel(stateDirectory: state)
        defer { restored.shutdown() }
        #expect(restored.jobs[0].isDownload && !restored.jobs[0].approved)
        restored.localAddress = "127.0.0.1"
        restored.connect(); try await wait { !restored.connecting }
        restored.sendPending(); try await wait { !restored.running }
        #expect(!restored.sharing)
        #expect(restored.jobs[0].state == "已完成" && restored.jobs[0].verifiedCount == 1)
        #expect(restored.jobs[0].audit.direction == "download")
        #expect(try Data(contentsOf: localFolder.appendingPathComponent("远端文件.txt")) == Data("远端内容".utf8))
    }
    @Test func migratesVersionTwoStateWithoutTreatingUploadsAsDownloads() async throws {
        defer { model.shutdown() }
        let plan = try TransferPlan.prepare(source("旧队列.txt"))
        let job = TransferJob(plan: plan, destination: destination.path, peerID: identity, peerName: "旧设备", onlyChanged: true)
        var archive = WorkspaceArchive(machineID: UUID().uuidString, jobs: [job], favorites: [], presets: [], host: "", port: "49278", onlyChanged: true, directDrop: true)
        archive.schemaVersion = 2
        try FileManager.default.removeItem(at: state.appendingPathComponent("workspace-v3.json"))
        try LocalStateStore.save(archive, to: state.appendingPathComponent("workspace-v2.json"))
        let restored = AppModel(stateDirectory: state)
        defer { restored.shutdown() }
        #expect(restored.jobs.count == 1 && !restored.jobs[0].isDownload)
        let updated = try LocalStateStore.read(WorkspaceArchive.self, from: state.appendingPathComponent("workspace-v3.json"))
        #expect(updated.schemaVersion == 3 && updated.machineID == archive.machineID)
        #expect(FileManager.default.fileExists(atPath: state.appendingPathComponent("workspace-v2.json").path))
    }

}
