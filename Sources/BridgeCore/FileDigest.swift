import Foundation
import CryptoKit
import Darwin

struct FileStamp: Codable, Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let seconds: Int64
    let nanos: Int64
    init(_ info: stat) {
        device = UInt64(UInt32(bitPattern: info.st_dev)); inode = info.st_ino
        size = info.st_size; seconds = Int64(info.st_mtimespec.tv_sec); nanos = Int64(info.st_mtimespec.tv_nsec)
    }
    var date: Date { Date(timeIntervalSince1970: Double(seconds) + Double(nanos) / 1_000_000_000) }
}

enum FileDigest {
    static func openRegular(_ url: URL) throws -> FileHandle {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw FileStore.posixError("无法读取 \(url.lastPathComponent)") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do { _ = try stamp(handle); return handle }
        catch { try? handle.close(); throw error }
    }
    static func stamp(_ handle: FileHandle) throws -> FileStamp {
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw BridgeError("只能传输普通文件，不能读取符号链接或特殊文件。")
        }
        return FileStamp(info)
    }
    static func hash(_ url: URL, check: () throws -> Void = { try Task.checkCancellation() }) throws -> (String, FileStamp) {
        let handle = try openRegular(url)
        defer { try? handle.close() }
        let before = try stamp(handle)
        let hasher = try prefix(handle, count: before.size, check: check)
        guard try stamp(handle) == before else { throw BridgeError("校验期间文件发生变化：\(url.lastPathComponent)") }
        return (digestString(hasher.finalize()), before)
    }
    static func prefix(_ handle: FileHandle, count: Int64, check: () throws -> Void = { try Task.checkCancellation() }) throws -> SHA256 {
        try handle.seek(toOffset: 0)
        var remaining = count, hasher = SHA256()
        while remaining > 0 {
            try check()
            guard let data = try handle.read(upToCount: Int(min(Int64(Channel.chunkSize), remaining))), !data.isEmpty else {
                throw BridgeError("文件长度发生变化，无法完成校验。")
            }
            hasher.update(data: data); remaining -= Int64(data.count)
        }
        try check()
        return hasher
    }
    static func validChecksum(_ checksum: String) -> Bool {
        checksum.count == 64 && checksum.allSatisfy { "0123456789abcdef".contains($0) }
    }
    static func key(_ fields: [String]) -> String {
        digestString(SHA256.hash(data: (try? JSONEncoder().encode(fields)) ?? Data()))
    }
}
