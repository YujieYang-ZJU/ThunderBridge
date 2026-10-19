import Foundation
import Network

public struct DiscoveredPeer: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let session: String
    public let endpoint: NWEndpoint
    public let interface: NWInterface
    public var connectionID: String { id + "/" + session }

    // Discovery metadata is untrusted. Only accept this protocol on the selected interface.
    static func parse(endpoint: NWEndpoint, metadata: NWBrowser.Result.Metadata,
                      interfaces: [NWInterface], localID: String, interface: NWInterface) -> DiscoveredPeer? {
        guard interfaces.contains(where: { $0.index == interface.index }),
              case .bonjour(let record) = metadata, record["v"] == "4",
              let id = record["id"], UUID(uuidString: id) != nil, id != localID,
              let session = record["session"], UUID(uuidString: session) != nil,
              case .service(let serviceName, let type, let domain, _) = endpoint,
              type == PeerDiscovery.serviceType, domain == "local." else { return nil }
        let name = String((record["name"] ?? "Mac").filter { !$0.isNewline && !$0.isASCIIControl }.prefix(80))
        return DiscoveredPeer(id: id, name: name.isEmpty ? "Mac" : name, session: session,
            endpoint: .service(name: serviceName, type: type, domain: domain, interface: interface), interface: interface)
    }
}

private extension Character {
    var isASCIIControl: Bool { unicodeScalars.contains { $0.value < 32 || $0.value == 127 } }
}

/// A default path monitor omits direct-link interfaces without a default route.
/// Evaluate a UDP path bound to the selected IPv4 address instead. The destination
/// is that same local address; no send/receive is issued and no peer is contacted.
/// Keep the exact interface check: never fall back to Wi-Fi or all interfaces.
public enum LocalNetworkInterface {
    public static func resolve(named name: String, address: String? = nil) async throws -> NWInterface {
        try Task.checkCancellation()
        guard let selected = InterfaceAddress.available(includeLoopback: true).first(where: {
            $0.interface == name && (address == nil || $0.address == address)
        }) else { throw BridgeError("所选网络不可用或地址已变化，请刷新网络地址后重试。") }
        let lookup = InterfaceLookup(name: name, address: selected.address)
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { lookup.start($0) }
        }, onCancel: { lookup.cancel() })
    }
}

private final class InterfaceLookup: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ThunderBridge.interfaceLookup")
    private var connection: NWConnection?
    private var continuation: CheckedContinuation<NWInterface, Error>?
    private var cancelled = false
    private let name: String
    private let address: String
    init(name: String, address: String) { self.name = name; self.address = address }
    func start(_ continuation: CheckedContinuation<NWInterface, Error>) {
        queue.async {
            self.continuation = continuation
            if self.cancelled { self.finish(.failure(CancellationError())); return }
            let parameters = NWParameters.udp
            parameters.requiredLocalEndpoint = .hostPort(host: .init(self.address), port: .any)
            parameters.includePeerToPeer = false
            let connection = NWConnection(host: .init(self.address), port: 9, using: parameters)
            self.connection = connection
            connection.pathUpdateHandler = { [weak self] path in
                guard let self, path.status == .satisfied,
                      let found = path.availableInterfaces.first(where: { $0.name == self.name }) else { return }
                self.finish(.success(found))
            }
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                if case .failed(let error) = state {
                    self.finish(.failure(BridgeError("无法识别所选网络接口（\(self.name) · \(self.address)）：\(error.localizedDescription)")))
                }
            }
            connection.start(queue: self.queue)
            self.queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self else { return }
                self.finish(.failure(BridgeError("无法识别所选网络接口（\(self.name) · \(self.address)），请刷新网络地址后重试。")))
            }
        }
    }
    func cancel() { queue.async { self.cancelled = true; self.finish(.failure(CancellationError())) } }
    private func finish(_ result: Result<NWInterface, Error>) {
        guard let pending = continuation else { return }
        continuation = nil
        connection?.pathUpdateHandler = nil; connection?.stateUpdateHandler = nil
        connection?.cancel(); connection = nil
        pending.resume(with: result)
    }
}

@MainActor
public final class PeerDiscovery {
    nonisolated public static let serviceType = "_leibridge._tcp"
    private var browser: NWBrowser?
    private var generation = UUID()
    public init() {}

    public func start(interface: NWInterface, localID: String,
                      onChange: @escaping ([DiscoveredPeer]) -> Void,
                      onFailure: @escaping (String) -> Void) {
        stop()
        let token = generation
        let parameters = NWParameters.tcp
        parameters.requiredInterface = interface
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: "local."), using: parameters)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let peers = results.compactMap {
                DiscoveredPeer.parse(endpoint: $0.endpoint, metadata: $0.metadata, interfaces: $0.interfaces,
                                     localID: localID, interface: interface)
            }
            let unique = Dictionary(peers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let sorted = Array(unique.values.sorted { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }.prefix(128))
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                onChange(sorted)
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error), .waiting(let error):
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    onFailure("无法搜索设备，请检查本地网络权限与所选网络。\n\(error.localizedDescription)")
                }
            default: break
            }
        }
        browser.start(queue: DispatchQueue(label: "ThunderBridge.discovery"))
    }
    public func stop() {
        generation = UUID()
        browser?.browseResultsChangedHandler = nil; browser?.stateUpdateHandler = nil
        browser?.cancel(); browser = nil
    }
}
