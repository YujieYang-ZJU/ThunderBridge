import Foundation
import Network
import Testing
@testable import BridgeCore
@testable import ThunderBridge

@MainActor
@Suite(.serialized)
struct AutomaticConnectionTests {
    func wait(_ condition: () -> Bool, seconds: TimeInterval = 15) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        try #require(condition(), "自动连接工作流等待超时")
    }

    @Test func twoSharesDiscoverConnectTransferAndReconnectWithoutSendingPendingJobs() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".test-fixture-auto-\(UUID())")
        let first = AppModel(stateDirectory: root.appendingPathComponent("first-state"))
        let second = AppModel(stateDirectory: root.appendingPathComponent("second-state"))
        defer { first.shutdown(); second.shutdown(); try? FileManager.default.removeItem(at: root) }
        first.localAddress = "127.0.0.1"; second.localAddress = "127.0.0.1"
        first.startSharing(on: "lo0"); second.startSharing(on: "lo0")
        try await wait { first.connected && second.connected }
        #expect(first.error == nil && second.error == nil)
        #expect(first.nearbyPeers.count == 1 && second.nearbyPeers.count == 1)
        #expect(first.listeningPort != second.listeningPort)
        let remote = root.appendingPathComponent("remote"), local = root.appendingPathComponent("local")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let source = local.appendingPathComponent("自动连接.txt")
        try Data("自动发现后的真实文件传输".utf8).write(to: source)
        first.browse(remote.path); try await wait { !first.loading }
        first.add([source], immediately: true)
        try await wait { !first.preparing && !first.running }
        #expect(first.jobs.last?.state == "已完成")
        #expect(try Data(contentsOf: remote.appendingPathComponent(source.lastPathComponent)) == Data(contentsOf: source))
        let downloads = root.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        second.addDownloads([source.path], to: downloads, immediately: true)
        try await wait { !second.preparing && !second.running }
        #expect(second.jobs.last?.state == "已完成")
        #expect(try Data(contentsOf: downloads.appendingPathComponent(source.lastPathComponent)) == Data(contentsOf: source))
        first.add([source], immediately: false); try await wait { !first.preparing }
        let oldSession = first.nearbyPeers.first?.session
        second.stopSharing()
        try await wait { !first.connected && first.nearbyPeers.isEmpty }
        #expect(!second.sharing && !second.connected && first.sharing)
        first.preparing = true
        second.startSharing(on: "lo0")
        try await wait { first.nearbyPeers.count == 1 && second.connected }
        try await Task.sleep(nanoseconds: 1_200_000_000)
        #expect(!first.connected)
        first.preparing = false
        try await wait { first.connected && second.connected }
        #expect(first.nearbyPeers.first?.session != oldSession)
        #expect(first.jobs.last?.state == "等待发送" && first.jobs.last?.approved == false)
        #expect(!first.running)
        first.disconnect()
        first.updateNearbyPeers(first.nearbyPeers)
        try await Task.sleep(nanoseconds: 1_200_000_000)
        #expect(!first.connected && first.automaticConnectionPaused)
    }

    @Test func multiplePeersNeedSelectionAndSharingOffIgnoresResults() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".test-fixture-choice-\(UUID())")
        let model = AppModel(stateDirectory: root)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let interface = try await LocalNetworkInterface.resolve(named: "lo0")
        let peers = (1...2).map { i in DiscoveredPeer(id: UUID().uuidString, name: "Mac \(i)", session: UUID().uuidString,
            endpoint: .hostPort(host: "127.0.0.1", port: 1), interface: interface) }
        model.updateNearbyPeers(peers)
        #expect(model.nearbyPeers.isEmpty && !model.connecting)
        model.sharing = true
        model.updateNearbyPeers(peers)
        try await Task.sleep(nanoseconds: 1_200_000_000)
        #expect(!model.connecting && !model.connected)
        #expect(model.discoveryStatus.contains("多台"))
        model.stopSharing()
        #expect(model.nearbyPeers.isEmpty)
    }

    @Test func stoppingDuringStartupDoesNotReopenSharing() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".test-fixture-stop-\(UUID())")
        let model = AppModel(stateDirectory: root)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        model.localAddress = "127.0.0.1"
        model.startSharing(on: "lo0"); model.stopSharing()
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(!model.sharing && !model.startingShare && !model.connected)
    }
}
