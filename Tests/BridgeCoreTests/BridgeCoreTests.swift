import Testing
import Foundation
import Network
import CryptoKit
import Security
@testable import BridgeCore

@Suite(.serialized)
final class BridgeCoreTests {
    private var fixture: URL!
    private var server: BridgeServer!
    private var client: BridgeClient!
    private var journalDirectory: URL!
    private var port: UInt16!

    init() async throws {
        fixture = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".test-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        journalDirectory = fixture.appendingPathExtension("receiver")
        server = BridgeServer(stateDirectory: journalDirectory)
        port = try await server.start(address: "127.0.0.1", port: 0)
        client = BridgeClient(PeerConfiguration(host: "127.0.0.1", port: port))
    }
    deinit {
        server?.stop()
        if let fixture { try? FileManager.default.removeItem(at: fixture) }
        if let journalDirectory { try? FileManager.default.removeItem(at: journalDirectory) }
    }
    private func folder(_ name: String) throws -> URL {
        let url = fixture.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func rawChannel() async throws -> Channel {
        let connection = NWConnection(host: "127.0.0.1", port: .init(rawValue: port)!, using: ConnectionSecurity.parameters())
        let channel = Channel(connection)
        try await channel.start()
        return channel
    }
    @Test func testTLSUsesEphemeralKeyAgreement() async throws {
        let channel = try await rawChannel()
        defer { channel.close() }
        let metadata = try #require(channel.connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata)
        let cipher = sec_protocol_metadata_get_negotiated_tls_ciphersuite(metadata.securityProtocolMetadata)
        #expect(cipher.rawValue == UInt16(TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256))
    }
    @Test func testNonEphemeralPublicPSKCannotConnect() async throws {
        let tls = NWProtocolTLS.Options(), options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        let key = Data(SHA256.hash(data: Data("ThunderBridge/open-sharing/v4/public-protocol-key".utf8)))
        let identity = Data("ThunderBridge-open-v4".utf8)
        key.withUnsafeBytes { k in identity.withUnsafeBytes { i in
            sec_protocol_options_add_pre_shared_key(options, DispatchData(bytes: k) as __DispatchData, DispatchData(bytes: i) as __DispatchData)
        } }
        let channel = Channel(NWConnection(host: "127.0.0.1", port: .init(rawValue: port)!, using: NWParameters(tls: tls)))
        defer { channel.close() }
        do { try await channel.start(timeout: 2); Issue.record("Plain PSK cipher must never be accepted") } catch {}

        // A client which bypasses our local cipher check must still receive no
        // application data from the server after negotiating the legacy suite.
        let raw = NWConnection(host: "127.0.0.1", port: .init(rawValue: port)!, using: NWParameters(tls: tls))
        defer { raw.cancel() }
        let payload = try JSONEncoder().encode(Message(command: "hello"))
        let count = UInt32(payload.count + 1)
        let packet = Data([UInt8((count >> 24) & 255), UInt8((count >> 16) & 255), UInt8((count >> 8) & 255), UInt8(count & 255), 1]) + payload
        let response: Data = try await withCheckedThrowingContinuation { continuation in
            let gate = CompletionGate(continuation)
            let queue = DispatchQueue(label: "legacy-test")
            raw.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    raw.send(content: packet, completion: .contentProcessed { _ in })
                    raw.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                        gate.resolve(.success(data ?? Data()))
                    }
                case .failed, .cancelled: gate.resolve(.success(Data()))
                default: break
                }
            }
            queue.asyncAfter(deadline: .now() + 2) { gate.resolve(.failure(BridgeError("服务器未关闭不安全连接"))); raw.cancel() }
            raw.start(queue: queue)
        }
        #expect(response.isEmpty)
        _ = try await client.hello()
    }
    @Test func testCodeFreeHelloAndFullFilesystemBrowsing() async throws {
        let hello = try await client.hello()
        expectFalse(hello.name.isEmpty)
        #expect(hello.ipv4Address == "127.0.0.1")
        expectEqual(hello.home, FileManager.default.homeDirectoryForCurrentUser.path)
        let root = try await client.list("/")
        expectTrue(root.entries.contains { $0.name == "Users" })
        let nested = try folder("远端目录")
        let data = Data("hello 雷桥".utf8)
        try data.write(to: nested.appendingPathComponent("中文.txt"))
        let listed = try await client.list(nested.path)
        expectEqual(listed.entries.map(\.name), ["中文.txt"])
        expectEqual(listed.entries.first?.size, Int64(data.count))
        expectTrue(listed.writable)
    }
    @Test func testOldProtocolCannotBrowse() async throws {
        let channel = try await rawChannel()
        defer { channel.close() }
        try await channel.sendMessage(Message(command: "list", version: 3, path: fixture.path))
        do { _ = try await channel.readMessage(); Issue.record("Old protocol must fail") }
        catch { #expect(error.localizedDescription.contains("0.4")) }
        _ = try await client.hello()
    }
    @Test func testNestedUnicodeHiddenEmptyAndMultiChunkTransfer() async throws {
        let source = try folder("来源/项目资料")
        let destination = try folder("目标")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("子目录/空目录"), withIntermediateDirectories: true)
        let bytes = Data((0..<(Channel.chunkSize * 3 + 37)).map { UInt8($0 % 251) })
        try bytes.write(to: source.appendingPathComponent("子目录/大文件.bin"))
        try Data().write(to: source.appendingPathComponent("零字节.txt"))
        try Data("hidden\n".utf8).write(to: source.appendingPathComponent(".隐藏文件"))
        let plan = try TransferPlan.prepare(source)
        expectEqual(plan.fileCount, 3)
        let saved = try await client.upload(plan, to: destination.path)
        let output = URL(fileURLWithPath: saved)
        expectEqual(try Data(contentsOf: output.appendingPathComponent("子目录/大文件.bin")), bytes)
        expectTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("子目录/空目录").path))
        expectEqual(try Data(contentsOf: output.appendingPathComponent("零字节.txt")).count, 0)
        expectEqual(try Data(contentsOf: output.appendingPathComponent(".隐藏文件")), Data("hidden\n".utf8))
    }
    @Test func testFileAndDirectoryCollisionsNeverOverwrite() async throws {
        let source = try folder("来源"), destination = try folder("目标")
        let original = destination.appendingPathComponent("notes.txt")
        try Data("old".utf8).write(to: original)
        let new = source.appendingPathComponent("notes.txt")
        try Data("new".utf8).write(to: new)
        let saved = try await client.upload(TransferPlan.prepare(new), to: destination.path)
        expectEqual(URL(fileURLWithPath: saved).lastPathComponent, "notes (1).txt")
        expectEqual(try String(contentsOf: original), "old")
        expectEqual(try String(contentsOfFile: saved), "new")
        let first = try await client.createDirectory(parent: destination.path, name: "文档")
        let second = try await client.createDirectory(parent: destination.path, name: "文档")
        expectNotEqual(first, second)
    }
    @Test func testChecksumFailureCleansPartialFile() async throws {
        let channel = try await rawChannel()
        defer { channel.close() }
        try await channel.sendMessage(Message(command: "upload", path: fixture.path, name: "bad.txt", size: 3, checksum: digestString(SHA256.hash(data: Data("abc".utf8))), transferID: UUID().uuidString))
        let ready = try await channel.readMessage()
        expectEqual(ready.command, "ready")
        try await channel.sendFrame(type: 2, data: Data("abc".utf8))
        try await channel.sendMessage(Message(command: "finish", checksum: "incorrect"))
        do { _ = try await channel.readMessage(); Issue.record("Bad checksum must fail") } catch {}
        expectEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.path), [])
    }
    @Test func testInvalidPathsAndSymlinksRejected() async throws {
        for name in ["..", ".", "../escape", "/tmp/escape", "a\0b", ""] {
            do { _ = try await client.createDirectory(parent: fixture.path, name: name); Issue.record("Invalid name \(name)") }
            catch {}
        }
        let link = fixture.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture)
        expectThrows(try TransferPlan.prepare(link))
        do { _ = try await client.list("relative/path"); Issue.record("Relative path must fail") } catch {}
    }
    @Test func testSizeMismatchRejectedWithoutFile() async throws {
        let channel = try await rawChannel()
        defer { channel.close() }
        try await channel.sendMessage(Message(command: "upload", path: fixture.path, name: "too-long.txt", size: 2, checksum: digestString(SHA256.hash(data: Data("ab".utf8))), transferID: UUID().uuidString))
        _ = try await channel.readMessage()
        try await channel.sendFrame(type: 2, data: Data("abc".utf8))
        do { _ = try await channel.readMessage(); Issue.record("Oversize data must fail") } catch {}
        expectEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.path), [])
    }
    @Test func testEmptyFileAndPermissionsAndModificationDate() async throws {
        let source = try folder("source"), destination = try folder("destination")
        let file = source.appendingPathComponent("run.sh")
        try Data().write(to: file)
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.posixPermissions: 0o755, .modificationDate: modified], ofItemAtPath: file.path)
        let saved = try await client.upload(TransferPlan.prepare(file), to: destination.path)
        let attributes = try FileManager.default.attributesOfItem(atPath: saved)
        expectEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        expectEqual(attributes[.modificationDate] as? Date, modified)
        expectEqual((attributes[.size] as? NSNumber)?.intValue, 0)
    }
    @Test func testConcurrentCollisionCommitsAreExclusive() async throws {
        let source = try folder("source"), destination = try folder("destination")
        let file = source.appendingPathComponent("same.txt")
        try Data("identical source".utf8).write(to: file)
        let plan = try TransferPlan.prepare(file)
        async let first = client.upload(plan, to: destination.path)
        async let second = client.upload(TransferPlan.prepare(file), to: destination.path)
        let results = try await [first, second]
        expectNotEqual(results[0], results[1])
        for path in results { expectEqual(try String(contentsOfFile: path), "identical source") }
    }
    @Test func testSourceSizeChangeAfterPlanningFailsBeforeWrite() async throws {
        let source = try folder("source"), destination = try folder("destination")
        let file = source.appendingPathComponent("changed.txt")
        try Data("original".utf8).write(to: file)
        let plan = try TransferPlan.prepare(file)
        try Data("changed and longer".utf8).write(to: file)
        do { _ = try await client.upload(plan, to: destination.path); Issue.record("Changed source must fail") } catch {}
        expectEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
    }
}

// Autoclosure helpers retain concise assertions while allowing throwing file reads.
private func expectEqual<T: Equatable>(_ lhs: @autoclosure () throws -> T, _ rhs: @autoclosure () throws -> T) {
    do { let a = try lhs(), b = try rhs(); #expect(a == b) } catch { Issue.record(error) }
}
private func expectNotEqual<T: Equatable>(_ lhs: @autoclosure () throws -> T, _ rhs: @autoclosure () throws -> T) {
    do { let a = try lhs(), b = try rhs(); #expect(a != b) } catch { Issue.record(error) }
}
private func expectTrue(_ value: @autoclosure () throws -> Bool) {
    do { #expect(try value()) } catch { Issue.record(error) }
}
private func expectFalse(_ value: @autoclosure () throws -> Bool) {
    do { #expect(try !value()) } catch { Issue.record(error) }
}
private func expectThrows<T>(_ value: @autoclosure () throws -> T) {
    do { _ = try value(); Issue.record("Expected an error") } catch {}
}
private func expectNoThrow<T>(_ value: @autoclosure () throws -> T) {
    do { _ = try value() } catch { Issue.record(error) }
}
