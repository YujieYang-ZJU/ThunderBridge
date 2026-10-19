import Foundation
import Darwin

struct Receipt: Codable {
    let kind: String
    let transferID: String
    let parent: String
    let name: String
    let size: Int64
    let checksum: String
    var savedPath: String?
    var stamp: FileStamp?
    var completed = false
    var updatedAt = Date()
}

final class JournalLease {
    let descriptor: Int32
    init(_ url: URL) throws {
        descriptor = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw FileStore.posixError("无法打开断点记录") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw BridgeError("同一文件正在其他任务中接收，请稍后继续。")
        }
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}

final class TransferJournal: @unchecked Sendable {
    let directory: URL
    init(directory: URL) { self.directory = directory }
    func key(kind: String, parent: String, name: String, transferID: String) throws -> String {
        guard UUID(uuidString: transferID) != nil else { throw BridgeError("无效的传输任务标识。") }
        return FileDigest.key([kind, parent, name, transferID])
    }
    func lease(_ key: String) throws -> JournalLease {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return try JournalLease(directory.appendingPathComponent(key + ".lock"))
    }
    func read(_ key: String) throws -> Receipt? {
        let url = directory.appendingPathComponent(key + ".json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try LocalStateStore.read(Receipt.self, from: url)
    }
    func save(_ receipt: Receipt, key: String) throws {
        var updated = receipt; updated.updatedAt = Date()
        try LocalStateStore.save(updated, to: directory.appendingPathComponent(key + ".json"))
    }
    func temporary(parent: URL, key: String) -> URL {
        parent.appendingPathComponent(".leibridge-\(key).part")
    }
    func indexURL(kind: String, parent: String, name: String, checksum: String) -> URL {
        directory.appendingPathComponent("index-" + FileDigest.key([kind, parent, name, checksum]) + ".json")
    }
    func remember(_ receipt: Receipt) throws {
        try LocalStateStore.save(receipt, to: indexURL(kind: receipt.kind, parent: receipt.parent, name: receipt.name, checksum: receipt.checksum))
    }
    func previous(kind: String, parent: String, name: String, checksum: String) throws -> Receipt? {
        let url = indexURL(kind: kind, parent: parent, name: name, checksum: checksum)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let value = try LocalStateStore.read(Receipt.self, from: url)
        guard value.kind == kind, value.parent == parent, value.name == name, value.checksum == checksum else { return nil }
        return value
    }

    func directory(parent path: String, name: String, transferID: String, reuse: Bool) throws -> String {
        try FileStore.validateName(name)
        let parent = try FileStore.directory(path)
        let key = try key(kind: "directory", parent: parent.path, name: name, transferID: transferID)
        let lease = try lease(key); defer { withExtendedLifetime(lease) {} }
        if let receipt = try read(key), let saved = receipt.savedPath, let prior = receipt.stamp {
            var info = stat()
            guard lstat(saved, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_ino == prior.inode, UInt64(UInt32(bitPattern: info.st_dev)) == prior.device else {
                throw BridgeError("先前的目标文件夹已被移动或替换，请重新添加任务：\(saved)")
            }
            return saved
        }
        var candidate = parent.appendingPathComponent(name)
        var info = stat()
        if reuse, !(lstat(candidate.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR),
           let previous = try previous(kind: "directory", parent: parent.path, name: name, checksum: ""),
           let saved = previous.savedPath, let stamp = previous.stamp,
           lstat(saved, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
           info.st_ino == stamp.inode, UInt64(UInt32(bitPattern: info.st_dev)) == stamp.device {
            candidate = URL(fileURLWithPath: saved)
        }
        let canReuse = reuse && lstat(candidate.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
        let created = canReuse ? candidate : try FileStore.createDirectory(parent: parent.path, name: name)
        guard lstat(created.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw BridgeError("目标文件夹已发生变化。")
        }
        let receipt = Receipt(kind: "directory", transferID: transferID, parent: parent.path, name: name,
                              size: 0, checksum: "", savedPath: created.path, stamp: FileStamp(info), completed: true)
        try save(receipt, key: key)
        try remember(receipt)
        return created.path
    }

    /// Save a destination intent before rename, so a crash/lost reply can recover the committed inode.
    func commit(temporary: URL, parent: URL, name: String, receipt: inout Receipt, key: String) throws -> URL {
        var info = stat()
        guard lstat(temporary.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw BridgeError("断点文件不存在或类型不正确。")
        }
        receipt.stamp = FileStamp(info)
        for index in 0..<10000 {
            let candidate = FileStore.candidate(in: parent, name: name, index: index)
            receipt.savedPath = candidate.path; receipt.completed = false
            try save(receipt, key: key)
            if renamex_np(temporary.path, candidate.path, UInt32(RENAME_EXCL)) == 0 {
                receipt.completed = true
                try save(receipt, key: key)
                try remember(receipt)
                return candidate
            }
            if errno != EEXIST { throw FileStore.posixError("无法保存文件") }
        }
        throw BridgeError("同名文件过多。")
    }

    /// Removes only known, unfinished, regular staging files. Completed user files are never removed.
    func clearIncomplete() throws -> Int {
        guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
        var count = 0
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for url in urls where url.pathExtension == "json" {
            let key = url.deletingPathExtension().lastPathComponent
            guard FileDigest.validChecksum(key), let lease = try? lease(key) else { continue }
            defer { withExtendedLifetime(lease) {} }
            guard let receipt = try read(key), receipt.kind == "file", !receipt.completed,
                  key == (try self.key(kind: "file", parent: receipt.parent, name: receipt.name, transferID: receipt.transferID)) else { continue }
            let temp = temporary(parent: URL(fileURLWithPath: receipt.parent), key: key)
            var info = stat()
            if lstat(temp.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG {
                try FileManager.default.removeItem(at: temp)
                // Preserve the receipt for lost-ack recovery if a final file was already committed.
                count += 1
            }
        }
        return count
    }
}
