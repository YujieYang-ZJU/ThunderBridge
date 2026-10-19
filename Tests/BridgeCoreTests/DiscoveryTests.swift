import Foundation
import Network
import Testing
@testable import BridgeCore

@Suite(.serialized)
struct DiscoveryTests {
    @Test func discoveryRejectsSelfOlderVersionsAndMalformedRecords() async throws {
        let interface = try await LocalNetworkInterface.resolve(named: "lo0")
        let id = UUID().uuidString, localID = UUID().uuidString
        let endpoint = NWEndpoint.service(name: id, type: PeerDiscovery.serviceType, domain: "local.", interface: nil)
        var txt = NWTXTRecord(["v": "4", "id": id, "session": UUID().uuidString, "name": "另一台 Mac"])
        func parse(_ local: String = localID, interfaces: [NWInterface]? = nil) -> DiscoveredPeer? {
            DiscoveredPeer.parse(endpoint: endpoint, metadata: .bonjour(txt), interfaces: interfaces ?? [interface], localID: local, interface: interface)
        }
        #expect(parse()?.name == "另一台 Mac")
        #expect(parse(id) == nil)
        #expect(parse(interfaces: []) == nil)
        txt["v"] = "3"; #expect(parse() == nil)
        txt["v"] = "4"; txt["session"] = "invalid"; #expect(parse() == nil)
        txt["session"] = UUID().uuidString; txt["id"] = "invalid"; #expect(parse() == nil)
    }

    @Test func selectedInterfaceIsRequiredForEveryConnection() async throws {
        let interface = try await LocalNetworkInterface.resolve(named: "lo0")
        let parameters = ConnectionSecurity.parameters(bindAddress: "127.0.0.1", interface: interface)
        #expect(parameters.requiredInterface?.name == "lo0")
        #expect(!parameters.includePeerToPeer)
        #expect(parameters.requiredLocalEndpoint != nil)
        do { _ = try await LocalNetworkInterface.resolve(named: "nonexistent-bridge"); Issue.record("Missing interface must fail") }
        catch { #expect(error.localizedDescription.contains("所选网络不可用")) }
    }

    @Test func staleAddressCannotFallBackToAnotherInterface() async throws {
        do {
            _ = try await LocalNetworkInterface.resolve(named: "lo0", address: "192.0.2.19")
            Issue.record("A stale address must not select another interface")
        } catch { #expect(error.localizedDescription.contains("地址已变化")) }
        let interface = try await LocalNetworkInterface.resolve(named: "lo0", address: "127.0.0.1")
        #expect(interface.name == "lo0")
    }

    @Test(.enabled(if: InterfaceAddress.available().contains { $0.interface.hasPrefix("bridge") }))
    func thunderboltWithoutDefaultRouteCanStartScopedListener() async throws {
        let address = try #require(InterfaceAddress.available().first { $0.interface.hasPrefix("bridge") })
        let interface = try await LocalNetworkInterface.resolve(named: address.interface, address: address.address)
        #expect(interface.name == address.interface)
        let parameters = ConnectionSecurity.parameters(bindAddress: address.address, interface: interface)
        #expect(parameters.requiredInterface?.name == address.interface)
        // Listener exposes no files and accepts no application requests.
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { $0.cancel() }
        defer { listener.cancel() }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let gate = CompletionGate(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: gate.resolve(.success(listener.port!.rawValue))
                case .failed(let error), .waiting(let error): gate.resolve(.failure(error))
                case .cancelled: gate.resolve(.failure(CancellationError()))
                default: break
                }
            }
            let queue = DispatchQueue(label: "bridge-listener-regression")
            queue.asyncAfter(deadline: .now() + 5) { gate.resolve(.failure(BridgeError("网桥监听超时"))) }
            listener.start(queue: queue)
        }
        #expect(port > 0)
    }

    @Test func serviceIdentityMustMatchHello() async throws {
        let interface = try await LocalNetworkInterface.resolve(named: "lo0")
        let state = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".test-fixture-identity-\(UUID())")
        let server = BridgeServer(stateDirectory: state)
        defer { server.stop(); try? FileManager.default.removeItem(at: state) }
        let port = try await server.start(address: "127.0.0.1", port: 0)
        let peer = DiscoveredPeer(id: UUID().uuidString, name: "Mac", session: UUID().uuidString,
            endpoint: .hostPort(host: "127.0.0.1", port: .init(rawValue: port)!), interface: interface)
        do { _ = try await BridgeClient(PeerConfiguration(peer: peer, localAddress: "127.0.0.1")).hello(); Issue.record("Mismatched device must fail") }
        catch { #expect(error.localizedDescription.contains("不一致")) }
    }
}
