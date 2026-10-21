import Foundation

public enum FileDisposition: String, Codable, Sendable {
    case sent, resumed, skipped, alreadyComplete, failed, pending
    public var title: String {
        switch self {
        case .sent: return "已传输并复读校验"
        case .resumed: return "已续传并复读校验"
        case .skipped: return "内容相同，已跳过"
        case .alreadyComplete: return "先前已完成，已复核"
        case .failed: return "未确认完成"
        case .pending: return "尚未处理"
        }
    }
}

public struct FileTransferRecord: Codable, Identifiable, Sendable {
    public let id: String
    public let sourcePath: String
    public let destinationPath: String
    public let size: Int64
    public let sourceSHA256: String
    public let destinationSHA256: String?
    public let disposition: FileDisposition
    public let resumedBytes: Int64
    public let networkBytes: Int64
    public let checkedAt: Date?
    public let detail: String?
    public var verified: Bool {
        disposition != .failed && disposition != .pending && destinationSHA256 == sourceSHA256
    }
}

public struct TransferReport: Codable, Sendable {
    public let rootPath: String
    public let files: [FileTransferRecord]
    public var networkBytes: Int64 { files.reduce(0) { $0 + $1.networkBytes } }
    public var skippedCount: Int { files.filter { $0.disposition == .skipped || $0.disposition == .alreadyComplete }.count }
    public var resumedCount: Int { files.filter { $0.disposition == .resumed }.count }
}

public struct AuditJob: Codable, Sendable {
    public let id: UUID
    public let peerID: String
    public let peerName: String
    public let source: String
    public let destination: String
    public let state: String
    public let onlyChanged: Bool
    public let records: [FileTransferRecord]
    public let direction: String?
    public init(id: UUID, peerID: String, peerName: String, source: String, destination: String,
                state: String, onlyChanged: Bool, records: [FileTransferRecord], direction: String = "upload") {
        self.id = id; self.peerID = peerID; self.peerName = peerName; self.source = source
        self.destination = destination; self.state = state; self.onlyChanged = onlyChanged; self.records = records; self.direction = direction
    }
}

public struct AuditReport: Codable, Sendable {
    public let schemaVersion: Int
    public let applicationVersion: String
    public let exportedAt: Date
    public let jobs: [AuditJob]
    public init(jobs: [AuditJob], exportedAt: Date = Date()) {
        self.schemaVersion = 1; self.applicationVersion = "0.5.1"
        self.jobs = jobs; self.exportedAt = exportedAt
    }
    public func json() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
    public func csv() -> String {
        let header = ["方向", "任务ID", "对方设备ID", "对方名称", "任务状态", "源路径", "目标路径", "字节数", "结果", "验证通过", "源SHA256", "目标SHA256", "复用断点字节", "本次发送字节", "校验时间", "说明"]
        var rows = [header]
        let formatter = ISO8601DateFormatter()
        for job in jobs {
            if job.records.isEmpty {
                rows.append([job.direction == "download" ? "下载" : "发送", job.id.uuidString, job.peerID, job.peerName, job.state, job.source, job.destination,
                             "0", "无普通文件", "不适用", "", "", "0", "0", "", "目录任务没有文件校验项"])
            }
            for file in job.records {
                rows.append([job.direction == "download" ? "下载" : "发送", job.id.uuidString, job.peerID, job.peerName, job.state, file.sourcePath, file.destinationPath,
                    String(file.size), file.disposition.title, file.verified ? "是" : "否", file.sourceSHA256,
                    file.destinationSHA256 ?? "", String(file.resumedBytes), String(file.networkBytes),
                    file.checkedAt.map { formatter.string(from: $0) } ?? "", file.detail ?? ""])
            }
        }
        func cell(_ value: String) -> String {
            // Prevent spreadsheet formula evaluation when opening exported CSV.
            let prefix = value.trimmingCharacters(in: .whitespacesAndNewlines).first
            let safe = prefix.map { "=+-@".contains($0) } == true ? "'" + value : value
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return "\u{FEFF}" + rows.map { $0.map(cell).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }
}

public enum LocalStateStore {
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ThunderBridge", isDirectory: true)
    }
    public static func save<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(value)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
}
