import Foundation
import Network
import CryptoKit
import Darwin

public struct IncomingEvent: Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let completed: Int64
    public let total: Int64
    public let status: String
    public let savedPath: String?
}

public final class BridgeServer: @unchecked Sendable {
    private let lock = NSLock()
    private var listener: NWListener?
    private var channels: [UUID: Channel] = [:]
    let onEvent: (IncomingEvent) -> Void
    let journal: TransferJournal
    private let machineID: String
    public init(stateDirectory: URL = LocalStateStore.defaultDirectory.appendingPathComponent("Receiver"),
                machineID: String = UUID().uuidString,
                onEvent: @escaping (IncomingEvent) -> Void = { _ in }) {
        journal = TransferJournal(directory: stateDirectory)
        self.machineID = machineID; self.onEvent = onEvent
    }
    public func clearIncompleteTransfers() throws -> Int { try journal.clearIncomplete() }

    public func start(address: String?, port: UInt16 = 49278, interface: NWInterface? = nil,
                      advertise: Bool = false, onFailure: @escaping (String) -> Void = { _ in }) async throws -> UInt16 {
        stop()
        let parameters = ConnectionSecurity.parameters(bindAddress: address, port: port, interface: interface)
        // requiredLocalEndpoint already contains the bound port. Supplying it twice
        // makes Network.framework reject a fixed-port listener with EINVAL.
        let listener = try NWListener(using: parameters,
            on: address?.isEmpty == false ? .any : NWEndpoint.Port(rawValue: port)!)
        if advertise {
            guard interface != nil, address?.isEmpty == false else { throw BridgeError("自动共享需要指定本机网络接口。") }
            listener.service = NWListener.Service(name: machineID, type: PeerDiscovery.serviceType,
                domain: "local.", txtRecord: NWTXTRecord(["v": "4", "id": machineID,
                    "name": String((Host.current().localizedName ?? "Mac").prefix(60)), "session": UUID().uuidString]))
        }
        setListener(listener)
        listener.newConnectionHandler = { [weak self, weak listener] connection in
            guard let self, let listener else { connection.cancel(); return }
            let id = UUID(), channel = Channel(connection)
            guard self.add(channel, id: id, listener: listener) else { connection.cancel(); return }
            Task.detached(priority: .userInitiated) {
                defer { channel.close(); self.remove(id) }
                do {
                    try await channel.start()
                    let request = try await channel.readMessage()
                    guard request.version == 4 else { throw BridgeError("请将两台 Mac 的雷桥都升级到 0.4 或更新的兼容版本。") }
                    try await self.handle(request, channel: channel, id: id)
                } catch {
                    try? await channel.sendMessage(Message(command: "error", error: error.localizedDescription))
                }
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            let gate = CompletionGate(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    gate.resolve(.success(listener.port!.rawValue))
                case .failed(let error):
                    gate.resolve(.failure(error))
                    onFailure(error.localizedDescription)
                case .waiting(let error):
                    gate.resolve(.failure(error))
                    onFailure(error.localizedDescription)
                case .cancelled:
                    listener.stateUpdateHandler = nil
                    gate.resolve(.failure(BridgeError("共享已停止。")))
                default: break
                }
            }
            listener.start(queue: DispatchQueue(label: "ThunderBridge.listener"))
        }
    }

    private func setListener(_ listener: NWListener) { lock.lock(); self.listener = listener; lock.unlock() }
    private func add(_ channel: Channel, id: UUID, listener: NWListener) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard self.listener === listener, channels.count < 8 else { return false }
        channels[id] = channel
        return true
    }
    private func remove(_ id: UUID) { lock.lock(); channels.removeValue(forKey: id); lock.unlock() }
    public func stop() {
        lock.lock()
        let old = listener, active = Array(channels.values)
        listener = nil; channels.removeAll()
        lock.unlock()
        old?.cancel(); active.forEach { $0.close() }
    }

    private func handle(_ request: Message, channel: Channel, id: UUID) async throws {
        switch request.command {
        case "hello":
            try await channel.sendMessage(Message(command: "hello", version: 4,
                home: FileManager.default.homeDirectoryForCurrentUser.path,
                machine: Host.current().localizedName ?? "Mac", machineID: machineID))
        case "list":
            guard let path = request.path else { throw BridgeError("缺少目录路径。") }
            try await channel.sendMessage(FileStore.list(path))
        case "mkdir":
            guard let path = request.path, let name = request.name else { throw BridgeError("缺少文件夹名称。") }
            let created = try FileStore.createDirectory(parent: path, name: name)
            try await channel.sendMessage(Message(command: "created", path: created.path))
        case "downloadPlan":
            try await sendDownloadPlan(request, channel: channel)
        case "download":
            guard let node = request.node, !node.directory, node.url.isFileURL,
                  node.url.path.hasPrefix("/"), !node.url.path.contains("\0"),
                  node.size >= 0, FileDigest.validChecksum(node.checksum) else {
                throw BridgeError("下载请求缺少有效文件信息。")
            }
            _ = try await FileSender.send(node, to: "", channel: channel, onlyChanged: false, progress: { _, _, _ in })
        case "upload":
            try await receiveResumable(request, channel: channel, id: id)
        case "directory":
            guard let path = request.path, let name = request.name, let token = request.transferID else {
                throw BridgeError("缺少文件夹任务信息。")
            }
            let created = try journal.directory(parent: path, name: name, transferID: token, reuse: request.onlyChanged ?? false)
            try await channel.sendMessage(Message(command: "created", path: created))
        default: throw BridgeError("无法识别的操作。")
        }
    }

}
