import Foundation
import CryptoKit

enum FileSender {
    static func send(_ node: PlanNode, to directory: String, channel: Channel, onlyChanged: Bool,
                            progress: @escaping (Int64, Int64, String) -> Void) async throws -> FileTransferRecord {
        let input = try FileDigest.openRegular(node.url)
        defer { try? input.close() }
        let initial = try FileDigest.stamp(input)
        guard initial == node.stamp else {
            throw BridgeError("源文件在准备后发生变化，请重新添加：\(node.url.lastPathComponent)")
        }
        progress(0, 0, "比对目标 / 检查断点")
        try await channel.sendMessage(Message(command: "upload", path: directory, name: node.url.lastPathComponent,
            size: node.size, modified: node.modified, permissions: node.permissions, checksum: node.checksum,
            transferID: node.id.uuidString, onlyChanged: onlyChanged))
        var reply = try await channel.readMessage()
        func result(_ reply: Message, resumed: Int64, network: Int64) throws -> FileTransferRecord {
            guard reply.command == "saved", let path = reply.path, reply.size == node.size,
                  reply.checksum == node.checksum, try FileDigest.stamp(input) == initial else {
                throw BridgeError("没有收到有效的目标文件校验确认。")
            }
            let action = FileDisposition(rawValue: reply.disposition ?? "sent") ?? .sent
            let finalAction = action == .sent && resumed > 0 ? FileDisposition.resumed : action
            guard [.sent, .resumed, .skipped, .alreadyComplete].contains(finalAction) else {
                throw BridgeError("收到不正确的传输结果。")
            }
            return FileTransferRecord(id: node.id.uuidString, sourcePath: node.url.path, destinationPath: path,
                size: node.size, sourceSHA256: node.checksum, destinationSHA256: reply.checksum,
                disposition: finalAction, resumedBytes: resumed, networkBytes: network, checkedAt: Date(), detail: nil)
        }
        if reply.command == "saved" {
            progress(node.size, 0, "相同内容已验证")
            return try result(reply, resumed: 0, network: 0)
        }
        guard reply.command == "ready", let proposedOffset = reply.offset,
              proposedOffset >= 0, proposedOffset <= node.size else { throw BridgeError("对方返回了无效断点。") }
        var offset = proposedOffset
        progress(offset, 0, offset > 0 ? "核对已有片段" : "准备发送")
        var hasher = try FileDigest.prefix(input, count: offset)
        if reply.prefixChecksum != digestString(hasher.finalize()) {
            try await channel.sendMessage(Message(command: "reset"))
            reply = try await channel.readMessage()
            guard reply.command == "ready", reply.offset == 0,
                  reply.prefixChecksum == digestString(SHA256().finalize()) else {
                throw BridgeError("无法重置损坏的断点。")
            }
            offset = 0; hasher = SHA256(); try input.seek(toOffset: 0)
        }
        var sent = offset
        var lastReport = Date.distantPast
        while let data = try input.read(upToCount: Channel.chunkSize), !data.isEmpty {
            try Task.checkCancellation()
            guard Int64(data.count) <= node.size - sent else { throw BridgeError("源文件在传输中发生变化。") }
            hasher.update(data: data)
            try await channel.sendFrame(type: 2, data: data)
            sent += Int64(data.count)
            if Date().timeIntervalSince(lastReport) > 0.12 {
                progress(sent, sent - offset, offset > 0 ? "续传中" : "发送中"); lastReport = Date()
            }
        }
        guard sent == node.size, try FileDigest.stamp(input) == initial,
              digestString(hasher.finalize()) == node.checksum else {
            throw BridgeError("源文件在传输中发生变化，请重新添加任务。")
        }
        progress(sent, sent - offset, "目标文件复读校验中")
        try await channel.sendMessage(Message(command: "finish", checksum: node.checksum))
        let saved = try await channel.readMessage()
        return try result(saved, resumed: offset, network: sent - offset)
    }
}
