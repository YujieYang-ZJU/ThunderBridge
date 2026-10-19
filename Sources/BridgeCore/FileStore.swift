import Foundation
import Darwin

enum FileStore {
    static let manager = FileManager.default

    static func directory(_ path: String) throws -> URL {
        guard path.hasPrefix("/"), !path.contains("\0") else { throw BridgeError("请输入绝对文件夹路径。") }
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw BridgeError("文件夹不存在：\(path)")
        }
        return url
    }

    static func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
              !name.contains("\0"), name.utf8.count <= 255 else { throw BridgeError("无效的文件名称。") }
    }

    static func list(_ path: String) throws -> Message {
        let directory = try directory(path)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        let urls = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
        guard urls.count <= 20000 else { throw BridgeError("此目录超过 20,000 项，请直接输入更具体的文件夹路径。") }
        let entries = urls.map { url -> RemoteEntry in
            let values = try? url.resourceValues(forKeys: keys)
            var isDirectory: ObjCBool = false
            _ = manager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            return RemoteEntry(name: url.lastPathComponent, path: url.path,
                isDirectory: isDirectory.boolValue, isSymbolicLink: values?.isSymbolicLink ?? false,
                size: Int64(values?.fileSize ?? 0), modified: values?.contentModificationDate)
        }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return Message(command: "listing", path: directory.path, entries: entries,
                       writable: manager.isWritableFile(atPath: directory.path))
    }

    static func candidate(in directory: URL, name: String, index: Int) -> URL {
        guard index > 0 else { return directory.appendingPathComponent(name) }
        let url = URL(fileURLWithPath: name)
        let ext = url.pathExtension
        let suffix = " (\(index))" + (ext.isEmpty ? "" : "." + ext)
        var stem = ext.isEmpty ? name : url.deletingPathExtension().lastPathComponent
        while (stem + suffix).utf8.count > 255 { stem.removeLast() }
        return directory.appendingPathComponent(stem + suffix)
    }

    static func createDirectory(parent: String, name: String) throws -> URL {
        try validateName(name)
        let parentURL = try directory(parent)
        for i in 0..<10000 {
            let candidate = candidate(in: parentURL, name: name, index: i)
            if mkdir(candidate.path, 0o755) == 0 { return candidate }
            if errno != EEXIST { throw posixError("无法创建文件夹") }
        }
        throw BridgeError("同名文件夹过多。")
    }

    static func commit(temporary: URL, parent: URL, name: String) throws -> URL {
        try validateName(name)
        for i in 0..<10000 {
            let destination = candidate(in: parent, name: name, index: i)
            if renamex_np(temporary.path, destination.path, UInt32(RENAME_EXCL)) == 0 { return destination }
            if errno != EEXIST { throw posixError("无法保存文件") }
        }
        throw BridgeError("同名文件过多。")
    }

    static func posixError(_ prefix: String) -> BridgeError {
        BridgeError("\(prefix)：\(String(cString: strerror(errno)))")
    }
}

public struct InterfaceAddress: Identifiable, Hashable, Sendable {
    public var id: String { "\(interface)/\(address)" }
    public let interface: String
    public let address: String
    public init(interface: String, address: String) { self.interface = interface; self.address = address }
    public var label: String {
        let name = interface.hasPrefix("bridge") ? "雷雳网桥 / \(interface)" : interface
        return "\(name) · \(address)"
    }
    public static func available(includeLoopback: Bool = false) -> [InterfaceAddress] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [] }
        defer { freeifaddrs(first) }
        var result: [InterfaceAddress] = []
        var cursor = first
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            guard let addr = item.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET),
                  item.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  (includeLoopback || item.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result.append(InterfaceAddress(interface: String(cString: item.pointee.ifa_name), address: String(cString: host)))
            }
        }
        return result.sorted {
            let l = $0.interface.hasPrefix("bridge"), r = $1.interface.hasPrefix("bridge")
            return l != r ? l : $0.interface < $1.interface
        }
    }
}
