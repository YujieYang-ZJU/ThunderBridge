import Foundation
import Network
import Testing
import BridgeCore
@testable import ThunderBridge

@MainActor
@Suite(.serialized)
final class ScreenSharingTests {
    let root: URL
    let identity = UUID().uuidString
    let server: BridgeServer
    let port: UInt16

    init() async throws {
        root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".test-fixture-screen-\(UUID())")
        server = BridgeServer(stateDirectory: root.appendingPathComponent("receiver"), machineID: identity)
        port = try await server.start(address: "127.0.0.1", port: 0)
    }
    deinit { server.stop(); try? FileManager.default.removeItem(at: root) }

    func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        try #require(condition(), "屏幕共享工作流等待超时")
    }
    func connectedModel(opener: @escaping @MainActor (URL) async throws -> Void) async throws -> AppModel {
        let model = AppModel(stateDirectory: root.appendingPathComponent("state"), screenSharingOpener: opener)
        model.host = "127.0.0.1"; model.port = String(port); model.localAddress = "127.0.0.1"
        model.connect()
        try await wait { !model.connecting }
        try #require(model.connected)
        return model
    }

    @Test func connectionURLAcceptsOnlyNumericIPv4WithoutCredentialsOrTransferPort() throws {
        let url = try ScreenSharing.connectionURL(address: "192.168.88.2")
        #expect(url.absoluteString == "vnc://192.168.88.2")
        #expect(url.port == nil && url.user == nil && url.password == nil)
        #expect(ScreenSharing.applicationBundleID == "com.apple.ScreenSharing")
        for address: String? in [nil, "", "另一台 Mac", "example.local", "vnc://192.168.88.2", "192.168.88.2:49278", "user@192.168.88.2", "192.168.88.2/path", "192.168.88.2%bridge0", "::1"] {
            #expect(throws: (any Error).self) { try ScreenSharing.connectionURL(address: address) }
        }
    }

    @Test func launchIsExplicitUsesTransportAddressAndPreventsRepeatedClicks() async throws {
        var opened: [URL] = []
        let model = try await connectedModel { opened.append($0) }
        defer { model.shutdown() }
        #expect(model.peerAddress == "127.0.0.1" && model.canOpenScreenSharing && opened.isEmpty)
        model.host = "显示名称不是网络地址"
        model.openScreenSharing(); model.openScreenSharing()
        #expect(model.openingScreenSharing && !model.canOpenScreenSharing)
        try await wait { !model.openingScreenSharing }
        #expect(opened.map(\.absoluteString) == ["vnc://127.0.0.1"])
        #expect(model.error == nil && model.connected)
        model.disconnect(); model.openScreenSharing()
        #expect(model.peerAddress == nil && !model.canOpenScreenSharing && opened.count == 1)
    }

    @Test func launchFailureIsVisibleAndLeavesFileConnectionUsable() async throws {
        let model = try await connectedModel { _ in throw BridgeError("测试启动失败") }
        defer { model.shutdown() }
        model.openScreenSharing()
        try await wait { !model.openingScreenSharing }
        #expect(model.error?.contains("测试启动失败") == true)
        #expect(model.connected && model.canOpenScreenSharing)
        model.browse(root.path); try await wait { !model.loading }
        #expect(model.path == root.path)
    }

    @Test func disconnectCancelsPendingLaunch() async throws {
        var opened = false
        let model = try await connectedModel { _ in opened = true }
        defer { model.shutdown() }
        model.openScreenSharing(); model.disconnect()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(!opened && !model.openingScreenSharing && model.peerAddress == nil && model.error == nil)
    }

    @Test func changedDeviceAtSameAddressCannotLaunchOldScreenSession() async throws {
        var opened = false
        let model = try await connectedModel { _ in opened = true }
        defer { model.shutdown() }
        server.stop()
        let replacement = BridgeServer(stateDirectory: root.appendingPathComponent("replacement"), machineID: UUID().uuidString)
        defer { replacement.stop() }
        for attempt in 0..<20 {
            do { _ = try await replacement.start(address: "127.0.0.1", port: port); break }
            catch let error as NWError {
                guard case .posix(.EADDRINUSE) = error, attempt < 19 else { throw error }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        model.openScreenSharing()
        try await wait { !model.openingScreenSharing }
        #expect(!opened && model.error?.contains("另一台设备") == true)
    }
}
