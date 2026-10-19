import AppKit
import BridgeCore
import Network

enum ScreenSharing {
    static let applicationBundleID = "com.apple.ScreenSharing"

    static func connectionURL(address: String?) throws -> URL {
        guard let address, let ipv4 = IPv4Address(address),
              ipv4.rawValue.map({ String($0) }).joined(separator: ".") == address else {
            throw BridgeError("未能取得对方的网络地址，请重新连接设备后再试。")
        }
        var components = URLComponents()
        components.scheme = "vnc"
        components.host = address
        guard let url = components.url else { throw BridgeError("无法创建屏幕共享连接。") }
        return url
    }

    @MainActor
    static func open(_ url: URL) async throws {
        guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: applicationBundleID) else {
            throw BridgeError("找不到 Mac 自带的“屏幕共享”应用，请检查系统中的应用是否可用。")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.open([url], withApplicationAt: application, configuration: configuration) { app, error in
                if let error { continuation.resume(throwing: error) }
                else if app != nil { continuation.resume() }
                else { continuation.resume(throwing: BridgeError("系统未能打开“屏幕共享”应用。")) }
            }
        }
    }
}
