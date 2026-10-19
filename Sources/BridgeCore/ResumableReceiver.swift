import Foundation
import CryptoKit
import Darwin

struct ReceiveResult {
    let path: String
    let disposition: FileDisposition
    let resumedBytes: Int64
    let networkBytes: Int64
}

extension BridgeServer {
    @discardableResult
    func receiveResumable(_ request: Message, channel: Channel, id: UUID,
                         progress: (Int64, Int64, String) -> Void = { _, _, _ in }) async throws -> ReceiveResult {
        guard let path = request.path, let name = request.name, let expected = request.size, expected >= 0,
              let checksum = request.checksum, FileDigest.validChecksum(checksum), let token = request.transferID else {
            throw BridgeError("缺少文件指纹或断点任务信息。")
        }
        try FileStore.validateName(name)
        let parent = try FileStore.directory(path)
        let key = try journal.key(kind: "file", parent: parent.path, name: name, transferID: token)
        let lease = try journal.lease(key); defer { withExtendedLifetime(lease) {} }
        let temporary = journal.temporary(parent: parent, key: key)
        var receipt = try journal.read(key) ?? Receipt(kind: "file", transferID: token,
            parent: parent.path, name: name, size: expected, checksum: checksum)
        guard receipt.size == expected, receipt.checksum == checksum else {
            throw BridgeError("同一续传任务的源文件已改变，请重新添加任务。")
        }
        let eventID = UUID(uuidString: token) ?? id
        var received: Int64 = 0
        var resumed: Int64 = 0
        var activeEvent = false
        func report(_ status: String, saved: String? = nil) {
            activeEvent = ["接收中", "校验中", "准备续传"].contains(status)
            onEvent(IncomingEvent(id: eventID, name: name, completed: received, total: expected, status: status, savedPath: saved))
            progress(received, max(0, received - resumed), status)
        }
        defer { if activeEvent { report("已暂停，可重试") } }
        func sendVerified(path: String, disposition: String) async throws {
            received = expected; resumed = expected
            report(disposition == "skipped" ? "相同已跳过" : "已复核", saved: path)
            try await channel.sendMessage(Message(command: "saved", path: path, size: expected, checksum: checksum,
                                                  offset: expected, disposition: disposition))
        }

        // Recovery after rename succeeded but the process/reply was interrupted.
        if let saved = receipt.savedPath, let stamp = receipt.stamp {
            var info = stat()
            let sameInode = lstat(saved, &info) == 0 && info.st_mode & S_IFMT == S_IFREG &&
                info.st_ino == stamp.inode && UInt64(UInt32(bitPattern: info.st_dev)) == stamp.device
            if sameInode {
                report("校验中")
                let (actual, current) = try FileDigest.hash(URL(fileURLWithPath: saved), check: channel.checkCancellation)
                guard actual == checksum, current.size == expected else {
                    throw BridgeError("先前完成的目标文件已被修改，请重新添加任务：\(saved)")
                }
                receipt.completed = true; try journal.save(receipt, key: key); try journal.remember(receipt)
                try await sendVerified(path: saved, disposition: "alreadyComplete")
                return ReceiveResult(path: saved, disposition: .alreadyComplete, resumedBytes: 0, networkBytes: 0)
            } else if receipt.completed {
                throw BridgeError("先前完成的目标文件已被移动或替换，请重新添加任务：\(saved)")
            }
        }

        // Compare actual contents, never just a timestamp/size match. No existing file is overwritten.
        var candidates = [parent.appendingPathComponent(name)]
        if request.onlyChanged == true,
           let previous = try journal.previous(kind: "file", parent: parent.path, name: name, checksum: checksum),
           let saved = previous.savedPath, !candidates.contains(URL(fileURLWithPath: saved)) {
            candidates.append(URL(fileURLWithPath: saved))
        }
        var info = stat()
        for existing in candidates where request.onlyChanged == true {
            guard lstat(existing.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size == expected else { continue }
            report("校验中")
            let (actual, stamp) = try FileDigest.hash(existing, check: channel.checkCancellation)
            if actual == checksum {
                receipt.savedPath = existing.path; receipt.stamp = stamp; receipt.completed = true
                try journal.save(receipt, key: key)
                try journal.remember(receipt)
                // Remove an older partial of this exact task if an identical final file now exists.
                if lstat(temporary.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG { try FileManager.default.removeItem(at: temporary) }
                try await sendVerified(path: existing.path, disposition: "skipped")
                return ReceiveResult(path: existing.path, disposition: .skipped, resumedBytes: 0, networkBytes: 0)
            }
        }

        receipt.savedPath = nil; receipt.stamp = nil; receipt.completed = false
        try journal.save(receipt, key: key)
        let fd = open(temporary.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw FileStore.posixError("无法写入目标目录，请检查权限") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        let initial = try FileDigest.stamp(handle)
        if initial.size > expected { try handle.truncate(atOffset: 0) }
        received = min(initial.size, expected)
        if initial.size > expected { received = 0 }
        resumed = received
        let free = try? parent.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = free?.volumeAvailableCapacityForImportantUsage, available < expected - received {
            throw BridgeError("目标磁盘空间不足，已保留断点。")
        }
        report("准备续传")
        var hasher = try FileDigest.prefix(handle, count: received, check: channel.checkCancellation)
        var invalidPartial = false, committed = false, acceptedData = false
        var lastUpdate = Date.distantPast
        do {
            try await channel.sendMessage(Message(command: "ready", offset: received,
                prefixChecksum: digestString(hasher.finalize())))
            report("接收中")
            while true {
                let (type, payload) = try await channel.readFrame()
                if type == 2 {
                    guard !payload.isEmpty, payload.count <= Channel.chunkSize,
                          Int64(payload.count) <= expected - received else {
                        invalidPartial = true; throw BridgeError("文件大小不匹配，已清除损坏断点。")
                    }
                    try handle.write(contentsOf: payload)
                    hasher.update(data: payload); received += Int64(payload.count); acceptedData = true
                    if Date().timeIntervalSince(lastUpdate) > 0.2 { report("接收中"); lastUpdate = Date() }
                } else if type == 1 {
                    let control = try JSONDecoder().decode(Message.self, from: payload)
                    if control.command == "reset", !acceptedData {
                        try handle.truncate(atOffset: 0); try handle.seek(toOffset: 0)
                        received = 0; resumed = 0; hasher = SHA256()
                        try await channel.sendMessage(Message(command: "ready", offset: 0,
                            prefixChecksum: digestString(hasher.finalize())))
                        continue
                    }
                    guard control.command == "finish", received == expected,
                          control.checksum == checksum, digestString(hasher.finalize()) == checksum else {
                        invalidPartial = true; throw BridgeError("文件完整性校验未通过，已清除损坏断点。")
                    }
                    report("校验中")
                    try handle.synchronize()
                    let before = try FileDigest.stamp(handle)
                    let diskHash = try FileDigest.prefix(handle, count: expected, check: channel.checkCancellation)
                    guard digestString(diskHash.finalize()) == checksum, try FileDigest.stamp(handle) == before else {
                        invalidPartial = true; throw BridgeError("目标文件复读校验失败，未保存最终文件。")
                    }
                    if let mode = request.permissions, fchmod(fd, mode_t(mode & 0o777)) != 0 {
                        throw FileStore.posixError("无法保存文件权限")
                    }
                    if let modified = request.modified {
                        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: temporary.path)
                    }
                    let saved = try journal.commit(temporary: temporary, parent: parent, name: name, receipt: &receipt, key: key)
                    committed = true; report("已接收并校验", saved: saved.path)
                    try await channel.sendMessage(Message(command: "saved", path: saved.path, size: received,
                        checksum: checksum, disposition: "sent"))
                    return ReceiveResult(path: saved.path, disposition: resumed > 0 ? .resumed : .sent,
                                         resumedBytes: resumed, networkBytes: expected - resumed)
                } else { invalidPartial = true; throw BridgeError("收到无效的数据。") }
            }
        } catch {
            if !committed {
                if invalidPartial { try? handle.truncate(atOffset: 0); try? FileManager.default.removeItem(at: temporary) }
                else { try? handle.synchronize() }
                report(invalidPartial ? "校验失败" : "已暂停，可续传")
            }
            throw error
        }
    }
}
