import Foundation
import Network
import CryptoKit
import Darwin

public struct PeerConfiguration: Sendable {
    public let host: String
    public let port: UInt16
    public let endpoint: NWEndpoint
    public let interface: NWInterface?
    public let expectedPeerID: String?
    public let localAddress: String?
    public init(host: String, port: UInt16 = 49278, localAddress: String? = nil) {
        self.host = host; self.port = port; self.localAddress = localAddress
        self.endpoint = .hostPort(host: .init(host), port: .init(rawValue: port)!)
        self.interface = nil; self.expectedPeerID = nil
    }
    public init(peer: DiscoveredPeer, localAddress: String) {
        self.host = peer.name; self.port = 0; self.localAddress = localAddress
        self.endpoint = peer.endpoint; self.interface = peer.interface; self.expectedPeerID = peer.id
    }
}

public struct PeerInfo: Sendable {
    public let id: String
    public let name: String
    public let home: String
    /// Numeric address of the successful connection, never a Bonjour display name.
    public let ipv4Address: String?
}

public struct DirectoryListing: Sendable {
    public let path: String
    public let entries: [RemoteEntry]
    public let writable: Bool
}

public struct TransferProgress: Sendable {
    public let sent: Int64
    public let total: Int64
    public let currentFile: String
    public let networkBytes: Int64
    public let phase: String
}

struct PlanNode: Codable, Sendable {
    let id: UUID
    let url: URL
    let relative: [String]
    let directory: Bool
    let size: Int64
    let modified: Date?
    let permissions: UInt16
    let checksum: String
    let stamp: FileStamp?
}

public struct TransferPlan: Codable, Sendable {
    public let id: UUID
    public let source: URL
    public let totalBytes: Int64
    public let fileCount: Int
    let nodes: [PlanNode]

    public static func prepare(_ source: URL, progress: (String) -> Void = { _ in },
                               check: () throws -> Void = { try Task.checkCancellation() }) throws -> TransferPlan {
        var nodes: [PlanNode] = [], total: Int64 = 0, count = 0
        func walk(_ url: URL, relative: [String]) throws {
            try check()
            guard relative.count < 256 else { throw BridgeError("文件夹层级过深。") }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let kind = attributes[.type] as? FileAttributeType
            guard kind == .typeRegular || kind == .typeDirectory else {
                throw BridgeError("暂不支持符号链接或特殊文件：\(url.path)\n请先在 Finder 压缩此项目，再传输压缩包。")
            }
            try FileStore.validateName(url.lastPathComponent)
            let directory = kind == .typeDirectory
            progress(url.lastPathComponent)
            let fingerprint = directory ? nil : try FileDigest.hash(url, check: check)
            let size = fingerprint?.1.size ?? 0
            guard size >= 0, total <= Int64.max - size else { throw BridgeError("文件总大小超出支持范围。") }
            total += size
            if !directory { count += 1 }
            nodes.append(PlanNode(id: UUID(), url: url, relative: relative, directory: directory, size: size,
                modified: fingerprint?.1.date,
                permissions: (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o644,
                checksum: fingerprint?.0 ?? "", stamp: fingerprint?.1))
            if directory {
                let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                for child in children {
                    let name = child.lastPathComponent
                    if name.hasPrefix(".leibridge-"), name.hasSuffix(".part"),
                       FileDigest.validChecksum(String(name.dropFirst(11).dropLast(5))) { continue }
                    try walk(child, relative: relative + [name])
                }
            }
        }
        try walk(source, relative: [])
        return TransferPlan(id: UUID(), source: source, totalBytes: total, fileCount: count, nodes: nodes)
    }

    public func auditRecords(existing: [FileTransferRecord], destination: String) -> [FileTransferRecord] {
        let recorded = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
        return nodes.filter { !$0.directory }.map { node in
            if let entry = recorded[node.id.uuidString] { return entry }
            let expected = ([destination, source.lastPathComponent] + node.relative).joined(separator: "/")
            return FileTransferRecord(id: node.id.uuidString, sourcePath: node.url.path, destinationPath: expected,
                size: node.size, sourceSHA256: node.checksum, destinationSHA256: nil, disposition: .pending,
                resumedBytes: 0, networkBytes: 0, checkedAt: nil,
                detail: "尚未确认；目标为预期路径，可能因同名保护另存。")
        }
    }
}

public final class BridgeClient: @unchecked Sendable {
    public let configuration: PeerConfiguration
    public init(_ configuration: PeerConfiguration) { self.configuration = configuration }

    func connect() async throws -> Channel {
        let parameters = ConnectionSecurity.parameters(bindAddress: configuration.localAddress, interface: configuration.interface)
        let connection = NWConnection(to: configuration.endpoint, using: parameters)
        let channel = Channel(connection)
        do { try await channel.start(); return channel }
        catch { channel.close(); throw error }
    }

    private func request(_ message: Message) async throws -> Message {
        let channel = try await connect()
        defer { channel.close() }
        try await channel.sendMessage(message)
        return try await channel.readMessage()
    }

    public func hello() async throws -> PeerInfo {
        let channel = try await connect()
        defer { channel.close() }
        try await channel.sendMessage(Message(command: "hello"))
        let reply = try await channel.readMessage()
        guard reply.version == 4, let name = reply.machine, let home = reply.home,
              let id = reply.machineID, UUID(uuidString: id) != nil else {
            throw BridgeError("请将两台 Mac 的雷桥都升级到 0.4 或更新的兼容版本。")
        }
        if let expected = configuration.expectedPeerID, id != expected {
            throw BridgeError("发现的设备与实际连接的设备不一致，请刷新设备列表。")
        }
        let address: String?
        if case .hostPort(host: .ipv4(let ipv4), port: _) = channel.connection.currentPath?.remoteEndpoint {
            address = ipv4.rawValue.map { String($0) }.joined(separator: ".")
        } else { address = nil }
        return PeerInfo(id: id, name: name, home: home, ipv4Address: address)
    }

    public func list(_ path: String) async throws -> DirectoryListing {
        let reply = try await request(Message(command: "list", path: path))
        guard let path = reply.path, let entries = reply.entries else { throw BridgeError("未能读取目录。") }
        return DirectoryListing(path: path, entries: entries, writable: reply.writable ?? false)
    }

    public func createDirectory(parent: String, name: String) async throws -> String {
        let reply = try await request(Message(command: "mkdir", path: parent, name: name))
        guard let path = reply.path else { throw BridgeError("未能创建目录。") }
        return path
    }

    @discardableResult
    public func upload(_ plan: TransferPlan, to destination: String,
                       progress: @escaping (TransferProgress) -> Void = { _ in }) async throws -> String {
        try await transfer(plan, to: destination, onlyChanged: false, progress: progress).rootPath
    }

    public func transfer(_ plan: TransferPlan, to destination: String, onlyChanged: Bool = true,
                         progress: @escaping (TransferProgress) -> Void = { _ in },
                         onFile: @escaping (FileTransferRecord) async -> Void = { _ in }) async throws -> TransferReport {
        var directories: [String: String] = [:], records: [FileTransferRecord] = []
        var completed: Int64 = 0, networkTotal: Int64 = 0
        var rootPath = destination
        for node in plan.nodes {
            try Task.checkCancellation()
            let parentKey = node.relative.dropLast().joined(separator: "/")
            let parent: String
            if node.relative.isEmpty { parent = destination }
            else {
                guard let mapped = directories[parentKey] else { throw BridgeError("文件夹结构无效。") }
                parent = mapped
            }
            if node.directory {
                let reply = try await request(Message(command: "directory", path: parent, name: node.url.lastPathComponent,
                    transferID: node.id.uuidString, onlyChanged: onlyChanged))
                guard let created = reply.path else { throw BridgeError("未能创建目标文件夹。") }
                directories[node.relative.joined(separator: "/")] = created
                if node.relative.isEmpty { rootPath = created }
            } else {
                let base = completed, networkBase = networkTotal
                do {
                    let result = try await uploadFile(node, to: parent, onlyChanged: onlyChanged) { processed, network, phase in
                        progress(TransferProgress(sent: base + processed, total: plan.totalBytes,
                            currentFile: node.url.lastPathComponent, networkBytes: networkBase + network, phase: phase))
                    }
                    if node.relative.isEmpty { rootPath = result.destinationPath }
                    records.append(result); await onFile(result)
                    completed += node.size; networkTotal += result.networkBytes
                } catch {
                    let failure = FileTransferRecord(id: node.id.uuidString, sourcePath: node.url.path,
                        destinationPath: URL(fileURLWithPath: parent).appendingPathComponent(node.url.lastPathComponent).path,
                        size: node.size, sourceSHA256: node.checksum, destinationSHA256: nil, disposition: .failed,
                        resumedBytes: 0, networkBytes: 0, checkedAt: nil, detail: error.localizedDescription)
                    await onFile(failure)
                    throw error
                }
            }
        }
        progress(TransferProgress(sent: completed, total: plan.totalBytes, currentFile: plan.source.lastPathComponent,
                                  networkBytes: networkTotal, phase: "已完成"))
        return TransferReport(rootPath: rootPath, files: records)
    }

    private func uploadFile(_ node: PlanNode, to directory: String, onlyChanged: Bool,
                            progress: @escaping (Int64, Int64, String) -> Void) async throws -> FileTransferRecord {
        let channel = try await connect()
        defer { channel.close() }
        return try await FileSender.send(node, to: directory, channel: channel, onlyChanged: onlyChanged, progress: progress)
    }
}
