import Foundation
@preconcurrency import Dispatch
import Network
import Security
import CryptoKit

public struct BridgeError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Open sharing: TLS encrypts each connection but does not authenticate a device.
/// The public PSK is a protocol identifier, NOT a secret or an access credential.
/// ECDHE is mandatory: never fall back to plain PSK suites with this public value.
public enum ConnectionSecurity {
    static func validate(_ connection: NWConnection) throws {
        guard let tls = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata,
              sec_protocol_metadata_get_negotiated_tls_ciphersuite(tls.securityProtocolMetadata).rawValue == UInt16(TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256) else {
            throw BridgeError("对方使用了不支持的加密方式，已拒绝连接。请将两边更新到最新版。")
        }
    }
    public static func parameters(bindAddress: String? = nil, port: UInt16 = 0,
                                  interface: NWInterface? = nil) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: UInt16(TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256))!)
        let key = Data(SHA256.hash(data: Data("ThunderBridge/open-sharing/v4/public-protocol-key".utf8)))
        let identity = Data("ThunderBridge-open-v4".utf8)
        key.withUnsafeBytes { keyBytes in
            identity.withUnsafeBytes { identityBytes in
                sec_protocol_options_add_pre_shared_key(options,
                    DispatchData(bytes: keyBytes) as __DispatchData, DispatchData(bytes: identityBytes) as __DispatchData)
            }
        }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 15
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = false
        parameters.requiredInterface = interface
        if let bindAddress, !bindAddress.isEmpty {
            parameters.requiredLocalEndpoint = .hostPort(host: .init(bindAddress), port: .init(rawValue: port)!)
        }
        return parameters
    }
}

public struct RemoteEntry: Codable, Identifiable, Sendable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let isSymbolicLink: Bool
    public let size: Int64
    public let modified: Date?
}

struct Message: Codable {
    var command: String
    var version: Int? = 4
    var path: String? = nil
    var name: String? = nil
    var size: Int64? = nil
    var modified: Date? = nil
    var permissions: UInt16? = nil
    var checksum: String? = nil
    var error: String? = nil
    var entries: [RemoteEntry]? = nil
    var home: String? = nil
    var machine: String? = nil
    var writable: Bool? = nil
    var machineID: String? = nil
    var transferID: String? = nil
    var onlyChanged: Bool? = nil
    var offset: Int64? = nil
    var prefixChecksum: String? = nil
    var disposition: String? = nil
    var node: PlanNode? = nil
}

final class CompletionGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }
    func resolve(_ result: Result<Value, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

/// A single sequential request stream, with bounded frames and cancellable I/O.
final class Channel: @unchecked Sendable {
    static let chunkSize = 1024 * 1024
    static let maxFrame = 16 * 1024 * 1024
    let connection: NWConnection
    let queue = DispatchQueue(label: "ThunderBridge.channel", qos: .userInitiated)

    init(_ connection: NWConnection) { self.connection = connection }
    func close() { connection.cancel() }
    func checkCancellation() throws {
        try Task.checkCancellation()
        switch connection.state {
        case .cancelled, .failed: throw CancellationError()
        default: break
        }
    }

    func start(timeout: TimeInterval = 12) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async {
                    let gate = CompletionGate(continuation)
                    let timer = DispatchWorkItem { self.connection.cancel() }
                    self.connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            timer.cancel(); self.connection.stateUpdateHandler = nil
                            // The OS can enable additional PSK suites. Validate the
                            // negotiated cipher on BOTH ends before any application I/O.
                            do { try ConnectionSecurity.validate(self.connection); gate.resolve(.success(())) }
                            catch { self.connection.cancel(); gate.resolve(.failure(error)) }
                        case .failed(let error):
                            timer.cancel(); self.connection.stateUpdateHandler = nil
                            gate.resolve(.failure(BridgeError("连接失败，请检查对方是否仍开启共享、网络连接及防火墙。\n\(error.localizedDescription)")))
                        case .cancelled:
                            timer.cancel(); self.connection.stateUpdateHandler = nil
                            gate.resolve(.failure(BridgeError("连接已取消或超时。请检查两台 Mac 的雷雳网桥地址。")))
                        default: break
                        }
                    }
                    self.queue.asyncAfter(deadline: .now() + timeout, execute: timer)
                    self.connection.start(queue: self.queue)
                }
            }
        }, onCancel: { self.close() })
    }

    private func send(_ data: Data) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let timer = DispatchWorkItem { self.connection.cancel() }
                queue.asyncAfter(deadline: .now() + 60, execute: timer)
                connection.send(content: data, completion: .contentProcessed { error in
                    timer.cancel()
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                })
            }
        }, onCancel: { self.close() })
    }

    private func readExactly(_ count: Int) async throws -> Data {
        var result = Data()
        while result.count < count {
            try Task.checkCancellation()
            let remaining = count - result.count
            let part: Data = try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { continuation in
                    let timer = DispatchWorkItem { self.connection.cancel() }
                    // A control reply may require hashing a large file on the peer's disk.
                    queue.asyncAfter(deadline: .now() + 600, execute: timer)
                    connection.receive(minimumIncompleteLength: remaining, maximumLength: remaining) { data, _, complete, error in
                        timer.cancel()
                        if let data, !data.isEmpty { continuation.resume(returning: data) }
                        else if let error { continuation.resume(throwing: error) }
                        else { continuation.resume(throwing: BridgeError(complete ? "对方已断开连接。" : "未收到有效数据。")) }
                    }
                }
            }, onCancel: { self.close() })
            result.append(part)
        }
        return result
    }

    func sendFrame(type: UInt8, data: Data) async throws {
        guard data.count < Self.maxFrame else { throw BridgeError("数据帧过大。") }
        let length = UInt32(data.count + 1)
        var packet = Data([UInt8((length >> 24) & 255), UInt8((length >> 16) & 255),
                           UInt8((length >> 8) & 255), UInt8(length & 255), type])
        packet.append(data)
        try await send(packet)
    }

    func readFrame() async throws -> (UInt8, Data) {
        let header = try await readExactly(4)
        let count = header.reduce(0) { ($0 << 8) | Int($1) }
        guard count > 0, count <= Self.maxFrame else { throw BridgeError("无效的数据帧长度。") }
        let payload = try await readExactly(count)
        return (payload.first!, Data(payload.dropFirst()))
    }

    func sendMessage(_ message: Message) async throws {
        try await sendFrame(type: 1, data: JSONEncoder().encode(message))
    }

    func readMessage() async throws -> Message {
        let (type, data) = try await readFrame()
        guard type == 1 else { throw BridgeError("收到了意外的数据。") }
        let message = try JSONDecoder().decode(Message.self, from: data)
        if let error = message.error { throw BridgeError(error) }
        return message
    }
}

func digestString(_ digest: SHA256.Digest) -> String {
    digest.map { String(format: "%02x", $0) }.joined()
}
