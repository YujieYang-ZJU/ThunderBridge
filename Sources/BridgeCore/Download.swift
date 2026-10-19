import Foundation

extension BridgeServer {
    func sendDownloadPlan(_ request: Message, channel: Channel) async throws {
        guard let path = request.path, path.hasPrefix("/"), !path.contains("\0") else {
            throw BridgeError("请输入有效的远端绝对路径。")
        }
        let source = URL(fileURLWithPath: path).standardizedFileURL
        let plan = try TransferPlan.prepare(source, check: channel.checkCancellation)
        try await channel.sendMessage(Message(command: "planBegin", path: source.path, size: plan.totalBytes,
                                              transferID: plan.id.uuidString))
        // One frame per entry keeps even large folder manifests below the frame limit.
        for node in plan.nodes {
            try channel.checkCancellation()
            try await channel.sendMessage(Message(command: "planNode", node: node))
        }
        try await channel.sendMessage(Message(command: "planEnd", size: Int64(plan.fileCount)))
    }
}

extension TransferPlan {
    static func validatedRemote(source: URL, id: UUID, nodes: [PlanNode], bytes: Int64, fileCount: Int64) throws -> TransferPlan {
        guard source.isFileURL, source.path.hasPrefix("/"), let root = nodes.first,
              root.relative.isEmpty, root.url == source else { throw BridgeError("远端文件清单无效。") }
        try FileStore.validateName(source.lastPathComponent)
        var paths = Set<String>(), ids = Set<UUID>(), directories = Set<String>()
        var total: Int64 = 0, count = 0
        for (index, node) in nodes.enumerated() {
            guard node.relative.count < 256, index == 0 || !node.relative.isEmpty else { throw BridgeError("远端文件层级无效。") }
            for name in node.relative { try FileStore.validateName(name) }
            let relative = node.relative.joined(separator: "/")
            let expectedURL = node.relative.reduce(source) { $0.appendingPathComponent($1) }
            guard node.url.isFileURL, node.url.standardizedFileURL.path == expectedURL.path,
                  ids.insert(node.id).inserted, paths.insert(relative).inserted,
                  index == 0 || directories.contains(node.relative.dropLast().joined(separator: "/")) else {
                throw BridgeError("远端文件清单包含重复或越界路径。")
            }
            if node.directory {
                guard node.size == 0 else { throw BridgeError("远端目录大小无效。") }
                directories.insert(relative)
            } else {
                guard node.size >= 0, total <= Int64.max - node.size, FileDigest.validChecksum(node.checksum),
                      let stamp = node.stamp, stamp.size == node.size else { throw BridgeError("远端文件指纹无效。") }
                total += node.size; count += 1
            }
        }
        guard total == bytes, Int64(count) == fileCount else { throw BridgeError("远端文件清单不完整。") }
        return TransferPlan(id: id, source: source, totalBytes: total, fileCount: count, nodes: nodes)
    }
}

extension BridgeClient {
    public func prepareDownload(_ path: String, progress: (String) -> Void = { _ in }) async throws -> TransferPlan {
        let channel = try await connect()
        defer { channel.close() }
        try await channel.sendMessage(Message(command: "downloadPlan", path: path))
        let begin = try await channel.readMessage()
        let requested = URL(fileURLWithPath: path).standardizedFileURL
        guard begin.command == "planBegin", begin.path == requested.path, let bytes = begin.size,
              let token = begin.transferID, let id = UUID(uuidString: token) else { throw BridgeError("未能读取下载清单。") }
        var nodes: [PlanNode] = []
        var lastUpdate = Date.distantPast
        while true {
            let reply = try await channel.readMessage()
            if reply.command == "planEnd", let count = reply.size {
                return try TransferPlan.validatedRemote(source: requested, id: id, nodes: nodes, bytes: bytes, fileCount: count)
            }
            guard reply.command == "planNode", let node = reply.node, nodes.count < 500_000 else {
                throw BridgeError("下载清单无效或超过 500,000 项，请选择更具体的子目录。")
            }
            nodes.append(node)
            if Date().timeIntervalSince(lastUpdate) > 0.15 { progress(node.url.lastPathComponent); lastUpdate = Date() }
        }
    }

    public func download(_ plan: TransferPlan, to destination: String, onlyChanged: Bool = true,
                         stateDirectory: URL = LocalStateStore.defaultDirectory.appendingPathComponent("Receiver"),
                         progress: @escaping (TransferProgress) -> Void = { _ in },
                         onFile: @escaping (FileTransferRecord) async -> Void = { _ in }) async throws -> TransferReport {
        // Revalidate persisted manifests before using their relative names for local writes.
        _ = try TransferPlan.validatedRemote(source: plan.source, id: plan.id, nodes: plan.nodes,
                                             bytes: plan.totalBytes, fileCount: Int64(plan.fileCount))
        let receiver = BridgeServer(stateDirectory: stateDirectory)
        let destination = try FileStore.directory(destination).path
        var directories: [String: String] = [:], records: [FileTransferRecord] = []
        var completed: Int64 = 0, networkTotal: Int64 = 0, rootPath = destination
        for node in plan.nodes {
            try Task.checkCancellation()
            let parent: String
            if node.relative.isEmpty { parent = destination }
            else {
                guard let mapped = directories[node.relative.dropLast().joined(separator: "/")] else { throw BridgeError("下载文件夹结构无效。") }
                parent = mapped
            }
            if node.directory {
                let created = try receiver.journal.directory(parent: parent, name: node.url.lastPathComponent,
                                                            transferID: node.id.uuidString, reuse: onlyChanged)
                directories[node.relative.joined(separator: "/")] = created
                if node.relative.isEmpty { rootPath = created }
                continue
            }
            let base = completed, networkBase = networkTotal
            do {
                let channel = try await connect()
                defer { channel.close() }
                try await channel.sendMessage(Message(command: "download", node: node))
                let offered = try await channel.readMessage()
                guard offered.command == "upload", offered.name == node.url.lastPathComponent,
                      offered.size == node.size, offered.checksum == node.checksum, offered.transferID == node.id.uuidString else {
                    throw BridgeError("对方提供的文件与下载清单不符。")
                }
                // The remote peer never chooses the local destination or overrides our options.
                let localRequest = Message(command: "upload", path: parent, name: node.url.lastPathComponent,
                    size: node.size, modified: node.modified, permissions: node.permissions, checksum: node.checksum,
                    transferID: node.id.uuidString, onlyChanged: onlyChanged)
                let result = try await receiver.receiveResumable(localRequest, channel: channel, id: node.id) { received, network, phase in
                    progress(TransferProgress(sent: base + received, total: plan.totalBytes, currentFile: node.url.lastPathComponent,
                                              networkBytes: networkBase + network, phase: phase == "接收中" ? "下载中" : phase))
                }
                let record = FileTransferRecord(id: node.id.uuidString, sourcePath: node.url.path, destinationPath: result.path,
                    size: node.size, sourceSHA256: node.checksum, destinationSHA256: node.checksum,
                    disposition: result.disposition, resumedBytes: result.resumedBytes, networkBytes: result.networkBytes,
                    checkedAt: Date(), detail: nil)
                records.append(record); await onFile(record)
                if node.relative.isEmpty { rootPath = result.path }
                completed += node.size; networkTotal += result.networkBytes
            } catch {
                await onFile(FileTransferRecord(id: node.id.uuidString, sourcePath: node.url.path,
                    destinationPath: URL(fileURLWithPath: parent).appendingPathComponent(node.url.lastPathComponent).path,
                    size: node.size, sourceSHA256: node.checksum, destinationSHA256: nil, disposition: .failed,
                    resumedBytes: 0, networkBytes: 0, checkedAt: nil, detail: error.localizedDescription))
                throw error
            }
        }
        progress(TransferProgress(sent: completed, total: plan.totalBytes, currentFile: plan.source.lastPathComponent,
                                  networkBytes: networkTotal, phase: "已完成"))
        return TransferReport(rootPath: rootPath, files: records)
    }
}
