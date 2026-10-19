import SwiftUI
import AppKit
import BridgeCore
import UniformTypeIdentifiers

enum TransferDirection: String, Codable { case upload, download }

struct TransferJob: Codable, Identifiable {
    var id = UUID()
    let plan: TransferPlan
    let destination: String
    let peerID: String
    let peerName: String
    let onlyChanged: Bool
    var state = "等待发送"
    var sent: Int64 = 0
    var networkBytes: Int64 = 0
    var currentFile = ""
    var phase = ""
    var detail = ""
    var started: Date?
    var finished: Date?
    var savedPath: String?
    var approved = false
    var records: [FileTransferRecord] = []
    var direction: TransferDirection? = nil
    var isDownload: Bool { direction == .download }
    var isActive: Bool { ["发送中", "下载中"].contains(state) }
    var retryable: Bool { ["等待发送", "等待下载", "已暂停", "失败"].contains(state) }
    var progress: Double { plan.totalBytes > 0 ? min(1, Double(sent) / Double(plan.totalBytes)) : (state == "已完成" ? 1 : 0) }
    var speed: String {
        guard let started, networkBytes > 0 else { return "" }
        let seconds = (finished ?? Date()).timeIntervalSince(started)
        return seconds > 0.2 ? formatBytes(Int64(Double(networkBytes) / seconds)) + "/s" : ""
    }
    var verifiedCount: Int { records.filter(\.verified).count }
    var skippedCount: Int { records.filter { [.skipped, .alreadyComplete].contains($0.disposition) }.count }
    var audit: AuditJob {
        AuditJob(id: id, peerID: peerID, peerName: peerName, source: plan.source.path,
                 destination: savedPath ?? destination, state: state, onlyChanged: onlyChanged,
                 records: plan.auditRecords(existing: records, destination: destination), direction: isDownload ? "download" : "upload")
    }
}

struct SavedDestination: Codable, Identifiable {
    var id = UUID()
    let peerID: String
    let peerName: String
    let path: String
}
struct DeliveryPreset: Codable, Identifiable {
    var id = UUID()
    let name: String
    let peerID: String
    let peerName: String
    let destination: String
    let sources: [URL]
    let onlyChanged: Bool
}
struct WorkspaceArchive: Codable {
    var schemaVersion = 3
    let machineID: String
    let jobs: [TransferJob]
    let favorites: [SavedDestination]
    let presets: [DeliveryPreset]
    let host: String
    let port: String
    let onlyChanged: Bool
    let directDrop: Bool
    var downloadDirectory: String? = nil
}
func formatBytes(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

@MainActor
final class AppModel: ObservableObject {
    @Published var addresses = InterfaceAddress.available()
    @Published var localAddress = ""
    @Published var sharing = false
    @Published var startingShare = false
    @Published var listeningPort: UInt16 = 49278
    @Published var host = ""
    @Published var port = "49278"
    @Published var nearbyPeers: [DiscoveredPeer] = []
    @Published var discoveryStatus = "两边开启共享后，自动发现并连接。"
    @Published var automaticConnectionPaused = false
    private let discovery = PeerDiscovery()
    private var sharingTask: Task<Void, Never>?
    private var automaticConnectionTask: Task<Void, Never>?
    private var sharingGeneration = UUID()
    private var connectionGeneration = UUID()
    private var attemptedSessions = Set<String>()
    private var connectedSession: String?
    private var preferredAutomaticPeerID: String?
    @Published var connecting = false
    @Published var connected = false
    @Published var peerID = ""
    @Published var peerName = "另一台 Mac"
    @Published var remoteHome = ""
    @Published var path = ""
    @Published var pathDraft = ""
    @Published var entries: [RemoteEntry] = []
    @Published var selectedPaths = Set<String>()
    @Published var downloadDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].path
    @Published var writable = false
    @Published var loading = false
    @Published var showHidden = false
    @Published var search = ""
    @Published var jobs: [TransferJob] = []
    @Published var favorites: [SavedDestination] = []
    @Published var presets: [DeliveryPreset] = []
    @Published var incoming: [IncomingEvent] = []
    @Published var running = false { didSet { if !running { scheduleAutomaticConnection() } } }
    @Published var preparing = false { didSet { if !preparing { scheduleAutomaticConnection() } } }
    @Published var preparingName = ""
    @Published var directDrop = true { didSet { scheduleSave() } }
    @Published var onlyChanged = true { didSet { scheduleSave() } }
    @Published var error: String?
    @Published var notice: String?
    @Published var newFolder = "新建文件夹"
    @Published var showingNewFolder = false
    @Published var presetName = ""
    @Published var showingPresetName = false
    @Published var showingClearCache = false
    private var machineID = UUID().uuidString
    private let stateDirectory: URL
    private let stateURL: URL
    private var persistenceReady = false
    private var saveTask: Task<Void, Never>?
    private var presetDraft: DeliveryPreset?
    private var client: BridgeClient?
    private var browsingTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private var transferTask: Task<Void, Never>?
    private var preparationTask: Task<[Result<TransferPlan, Error>], Never>?
    private var activity: NSObjectProtocol?
    private lazy var server = BridgeServer(stateDirectory: stateDirectory.appendingPathComponent("Receiver"), machineID: machineID) { [weak self] event in
        Task { @MainActor in
            guard let self else { return }
            if let index = self.incoming.firstIndex(where: { $0.id == event.id }) { self.incoming[index] = event }
            else { self.incoming.insert(event, at: 0) }
            // Keep all active transfers visible even when many completed files arrive.
            let active = self.incoming.filter { Self.activeIncoming.contains($0.status) }
            self.incoming = active + Array(self.incoming.filter { !Self.activeIncoming.contains($0.status) }.prefix(50))
            self.updateActivity()
        }
    }
    private static let activeIncoming = ["接收中", "校验中", "准备续传"]

    init(stateDirectory: URL = LocalStateStore.defaultDirectory) {
        self.stateDirectory = stateDirectory
        self.stateURL = stateDirectory.appendingPathComponent("workspace-v3.json")
        localAddress = addresses.first?.address ?? ""
        let legacyURL = stateDirectory.appendingPathComponent("workspace-v2.json")
        let restoreURL = FileManager.default.fileExists(atPath: stateURL.path) ? stateURL : legacyURL
        if FileManager.default.fileExists(atPath: restoreURL.path) {
            do {
                let archive = try LocalStateStore.read(WorkspaceArchive.self, from: restoreURL)
                guard [2, 3].contains(archive.schemaVersion), UUID(uuidString: archive.machineID) != nil else { throw BridgeError("队列文件版本不受支持。") }
                machineID = archive.machineID; jobs = archive.jobs
                favorites = archive.favorites; presets = archive.presets
                downloadDirectory = archive.downloadDirectory ?? downloadDirectory
                host = archive.host; port = archive.port; onlyChanged = archive.onlyChanged; directDrop = archive.directDrop
                for index in jobs.indices {
                    jobs[index].approved = false
                    if jobs[index].isActive {
                        jobs[index].state = "已暂停"; jobs[index].detail = "重新连接原设备后，点击继续。"
                    }
                }
            } catch {
                let backup = restoreURL.deletingPathExtension().appendingPathExtension("backup-\(UUID().uuidString).json")
                do {
                    try FileManager.default.copyItem(at: restoreURL, to: backup)
                    self.error = "无法恢复上次队列，已备份原文件：\(backup.path)\n\(error.localizedDescription)"
                } catch {
                    self.error = "无法读取或备份队列，本次暂不保存状态：\(error.localizedDescription)"
                    return
                }
            }
        }
        persistenceReady = true
        saveNow()
    }
    private func scheduleSave() {
        guard persistenceReady, saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self else { return }
            self.saveTask = nil; self.saveNow()
        }
    }
    private func saveNow() {
        guard persistenceReady else { return }
        do {
            try LocalStateStore.save(WorkspaceArchive(machineID: machineID, jobs: jobs, favorites: favorites,
                presets: presets, host: host, port: port, onlyChanged: onlyChanged, directDrop: directDrop, downloadDirectory: downloadDirectory), to: stateURL)
        } catch { self.error = "无法保存队列，下次启动可能无法恢复：\(error.localizedDescription)" }
    }
    var visibleEntries: [RemoteEntry] {
        entries.filter { (showHidden || !$0.name.hasPrefix(".")) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }
    }
    var pendingCount: Int { jobs.filter { $0.retryable && $0.peerID == peerID }.count }
    var canAdd: Bool { connected && !loading && writable && !preparing }
    var selectedEntries: [RemoteEntry] { visibleEntries.filter { selectedPaths.contains($0.path) } }
    var canDownload: Bool { connected && !loading && !preparing && !selectedEntries.isEmpty }
    var hasTransfers: Bool { running || preparing || incoming.contains { Self.activeIncoming.contains($0.status) } }
    var networkLabel: String { addresses.first { $0.address == localAddress }?.label ?? "尚无可用网络地址" }
    var hasBridgeAddress: Bool { addresses.contains { $0.interface.hasPrefix("bridge") } }
    var currentFavorites: [SavedDestination] { favorites.filter { $0.peerID == peerID } }
    var currentPresets: [DeliveryPreset] { presets.filter { $0.peerID == peerID } }
    var isFavorite: Bool { currentFavorites.contains { $0.path == path } }

    func refreshAddresses() {
        addresses = InterfaceAddress.available()
        if !addresses.contains(where: { $0.address == localAddress }) { localAddress = addresses.first?.address ?? "" }
    }
    func toggleSharing() {
        if sharing || startingShare { stopSharing(); return }
        guard let address = addresses.first(where: { $0.address == localAddress }) else {
            error = "请先连接雷雳线，在系统设置 → 网络中启用雷雳网桥，然后刷新地址。"; return
        }
        startSharing(on: address.interface)
    }
    func startSharing(on interfaceName: String) {
        guard !sharing, !startingShare else { return }
        sharingGeneration = UUID()
        let token = sharingGeneration, address = localAddress
        startingShare = true; automaticConnectionPaused = false; preferredAutomaticPeerID = nil
        discoveryStatus = "正在开启共享…"
        sharingTask = Task {
            defer { if sharingGeneration == token { startingShare = false } }
            do {
                let interface = try await LocalNetworkInterface.resolve(named: interfaceName, address: address)
                try Task.checkCancellation()
                let actualPort = try await server.start(address: address, port: 0, interface: interface, advertise: true) { [weak self] message in
                    Task { @MainActor in
                        guard let self, self.sharingGeneration == token else { return }
                        self.stopSharing(); self.error = "共享已停止：\(message)"
                    }
                }
                try Task.checkCancellation()
                guard sharingGeneration == token else { return }
                listeningPort = actualPort; sharing = true
                discoveryStatus = "正在寻找已开启共享的 Mac…"
                discovery.start(interface: interface, localID: machineID, onChange: { [weak self] peers in
                    guard let self, self.sharingGeneration == token, self.sharing else { return }
                    self.updateNearbyPeers(peers)
                }, onFailure: { [weak self] message in
                    guard let self, self.sharingGeneration == token else { return }
                    self.stopSharing(); self.error = message
                })
            } catch {
                guard sharingGeneration == token else { return }
                stopSharing()
                if !(error is CancellationError) { self.error = "无法开启共享：\(error.localizedDescription)" }
            }
        }
    }
    func stopSharing() {
        sharingGeneration = UUID()
        sharingTask?.cancel(); automaticConnectionTask?.cancel()
        discovery.stop(); server.stop()
        sharing = false; startingShare = false; nearbyPeers = []; attemptedSessions = []
        preferredAutomaticPeerID = nil; automaticConnectionPaused = false
        disconnect(pauseAutomatic: false)
        discoveryStatus = "两边开启共享后，自动发现并连接。"
    }
    func updateNearbyPeers(_ peers: [DiscoveredPeer]) {
        guard sharing else { return }
        nearbyPeers = peers
        attemptedSessions.formIntersection(Set(peers.map(\.connectionID)))
        if let connectedSession, !peers.contains(where: { $0.connectionID == connectedSession }) {
            disconnect(pauseAutomatic: false)
            discoveryStatus = "对方已离线，等待重新开启共享。"
        }
        if !connected && !connecting {
            discoveryStatus = automaticConnectionPaused ? "自动连接已暂停，点选设备即可重新连接。" :
                (peers.isEmpty ? "正在寻找已开启共享的 Mac…" : (peers.count > 1 ? "发现多台 Mac，请选择要连接的设备。" : "已发现 Mac，正在准备连接…"))
        }
        scheduleAutomaticConnection()
    }
    private func scheduleAutomaticConnection() {
        automaticConnectionTask?.cancel()
        guard sharing, !connected, !connecting, !automaticConnectionPaused else { return }
        automaticConnectionTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, sharing, !connected, !connecting, !running, !preparing,
                  !automaticConnectionPaused, nearbyPeers.count == 1, let peer = nearbyPeers.first,
                  preferredAutomaticPeerID == nil || preferredAutomaticPeerID == peer.id,
                  !attemptedSessions.contains(peer.connectionID) else { return }
            connect(to: peer)
        }
    }
    func retryAutomaticConnection() {
        preferredAutomaticPeerID = nil
        automaticConnectionPaused = false; attemptedSessions = []
        updateNearbyPeers(nearbyPeers)
    }
    func connect(to peer: DiscoveredPeer) {
        guard sharing, !running, !preparing, !connecting,
              nearbyPeers.contains(where: { $0.connectionID == peer.connectionID }) else { return }
        automaticConnectionPaused = false; preferredAutomaticPeerID = peer.id
        attemptedSessions.insert(peer.connectionID)
        connect(configuration: PeerConfiguration(peer: peer, localAddress: localAddress), session: peer.connectionID)
    }
    // Direct endpoint entry is used by local integration tests; the UI uses discovered peers.
    func connect() {
        guard let portNumber = UInt16(port), portNumber > 0, !host.isEmpty else { return }
        connect(configuration: PeerConfiguration(host: host, port: portNumber, localAddress: localAddress.isEmpty ? nil : localAddress))
    }
    private func connect(configuration: PeerConfiguration, session: String? = nil) {
        guard !connecting, !running, !preparing else { return }
        disconnect(pauseAutomatic: false)
        let token = UUID(); connectionGeneration = token
        connecting = true; connectedSession = session
        discoveryStatus = "正在连接…"
        connectionTask = Task {
            defer { if connectionGeneration == token { connecting = false } }
            do {
                let candidate = BridgeClient(configuration), info = try await candidate.hello()
                let listing = try await candidate.list(info.home)
                try Task.checkCancellation()
                guard connectionGeneration == token else { return }
                client = candidate; peerID = info.id; peerName = info.name; remoteHome = info.home
                host = configuration.host; port = String(configuration.port)
                apply(listing); connected = true; discoveryStatus = "已连接，可上传与下载。"; saveNow()
            } catch {
                guard !Task.isCancelled, connectionGeneration == token else { return }
                connectedSession = nil
                discoveryStatus = "连接未成功，点击设备重试。"
                self.error = error.localizedDescription
            }
        }
    }
    func disconnect(pauseAutomatic: Bool = true) {
        if pauseAutomatic { automaticConnectionPaused = true }
        connectionGeneration = UUID(); automaticConnectionTask?.cancel()
        connectionTask?.cancel(); browsingTask?.cancel(); transferTask?.cancel(); preparationTask?.cancel()
        connecting = false; connected = false; connectedSession = nil; client = nil
        entries = []; selectedPaths = []; path = ""; pathDraft = ""; loading = false
        for index in jobs.indices { jobs[index].approved = false }
        if sharing { discoveryStatus = "连接已断开，点选设备即可重新连接。" }
        saveNow()
    }
    private func apply(_ listing: DirectoryListing) {
        path = listing.path; pathDraft = listing.path; entries = listing.entries; writable = listing.writable; search = ""; selectedPaths = []
    }
    func browse(_ requested: String) {
        guard let client else { return }
        browsingTask?.cancel(); loading = true
        let expanded = requested == "~" ? remoteHome : (requested.hasPrefix("~/") ? remoteHome + requested.dropFirst() : requested)
        browsingTask = Task {
            do { let listing = try await client.list(expanded); try Task.checkCancellation(); apply(listing); loading = false }
            catch { if !Task.isCancelled { self.error = error.localizedDescription; pathDraft = path; loading = false } }
        }
    }
    func goUp() { browse(URL(fileURLWithPath: path).deletingLastPathComponent().path) }
    func makeFolder() {
        guard let client else { return }
        let destination = path, name = newFolder
        Task {
            do { let created = try await client.createDirectory(parent: destination, name: name); browse(created) }
            catch { self.error = error.localizedDescription }
        }
    }
    func toggleFavorite() {
        guard connected, !loading else { return }
        if isFavorite { favorites.removeAll { $0.peerID == peerID && $0.path == path } }
        else { favorites.append(SavedDestination(peerID: peerID, peerName: peerName, path: path)) }
        saveNow()
    }
    func removeFavorite(_ id: UUID) { favorites.removeAll { $0.id == id }; saveNow() }
    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        panel.prompt = "添加到发送队列"
        if panel.runModal() == .OK { add(panel.urls, immediately: false) }
    }
    func choosePresetSources() {
        guard canAdd else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        panel.message = "选择以后要批量投递的文件或文件夹。每次投递都会重新读取其当前内容。"
        panel.prompt = "保存投递来源"
        let target = path, identity = peerID, name = peerName, changed = onlyChanged
        if panel.runModal() == .OK {
            presetDraft = DeliveryPreset(name: "", peerID: identity, peerName: name, destination: target, sources: panel.urls, onlyChanged: changed)
            presetName = "投递到 " + URL(fileURLWithPath: target).lastPathComponent
            showingPresetName = true
        }
    }
    func savePreset() {
        guard let draft = presetDraft else { return }
        let name = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { error = "投递方案需要一个名称，请重新保存。"; return }
        presets.append(DeliveryPreset(name: name, peerID: draft.peerID, peerName: draft.peerName,
            destination: draft.destination, sources: draft.sources, onlyChanged: draft.onlyChanged))
        presetDraft = nil; saveNow()
    }
    func deliver(_ preset: DeliveryPreset) {
        guard connected, preset.peerID == peerID else { error = "请先连接这个方案对应的 Mac。"; return }
        add(preset.sources, immediately: true, destinationOverride: preset.destination, onlyChangedOverride: preset.onlyChanged)
    }
    func removePreset(_ id: UUID) { presets.removeAll { $0.id == id }; saveNow() }

    func add(_ urls: [URL], immediately: Bool, destinationOverride: String? = nil, onlyChangedOverride: Bool? = nil) {
        guard connected, !preparing, destinationOverride != nil || canAdd, !urls.isEmpty else {
            if !connected { error = "请先连接对方 Mac，并打开目标文件夹。" }
            else if preparing { error = "正在读取上一批文件，请完成后再添加。" }
            return
        }
        guard let originalClient = client else { return }
        let destination = destinationOverride ?? path, identity = peerID, name = peerName
        let changed = onlyChangedOverride ?? onlyChanged
        preparing = true; preparingName = "正在读取并计算文件指纹…"; updateActivity()
        let preparation = Task.detached(priority: .userInitiated) { [weak self] in
            var lastUpdate = Date.distantPast
            return urls.map { url in Result { try TransferPlan.prepare(url) { filename in
                guard Date().timeIntervalSince(lastUpdate) > 0.15 else { return }
                lastUpdate = Date()
                Task { @MainActor [weak self] in if self?.preparing == true { self?.preparingName = "正在读取：" + filename } }
            } } }
        }
        preparationTask = preparation
        Task {
            defer { preparing = false; preparationTask = nil; updateActivity() }
            let results = await preparation.value
            guard connected, client === originalClient, !preparation.isCancelled else { return }
            var errors: [String] = []
            for result in results {
                switch result {
                case .success(let plan): jobs.append(TransferJob(plan: plan, destination: destination, peerID: identity,
                    peerName: name, onlyChanged: changed, approved: immediately))
                case .failure(let failure): errors.append(failure.localizedDescription)
                }
            }
            saveNow()
            if !errors.isEmpty { error = errors.joined(separator: "\n\n") }
            if immediately { runQueue() }
        }
    }
    func chooseDownload(paths: Set<String>? = nil) {
        let selection = paths ?? selectedPaths
        let selected = visibleEntries.filter { selection.contains($0.path) }
        guard connected, !preparing, !loading, !selected.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true; panel.directoryURL = URL(fileURLWithPath: downloadDirectory)
        panel.message = "选择本机保存位置，将下载 \(selected.count) 个文件或文件夹。"
        panel.prompt = "下载到这里"
        if panel.runModal() == .OK, let folder = panel.url { addDownloads(selected.map(\.path), to: folder) }
    }
    func addDownloads(_ paths: [String], to folder: URL, immediately: Bool = true) {
        guard connected, !preparing, !paths.isEmpty, let originalClient = client else { return }
        let identity = peerID, name = peerName, changed = onlyChanged
        downloadDirectory = folder.path
        preparing = true; preparingName = "正在读取对方文件并计算指纹…"; updateActivity()
        let preparation = Task.detached(priority: .userInitiated) { [weak self] in
            var results: [Result<TransferPlan, Error>] = []
            for path in paths {
                if Task.isCancelled { break }
                do {
                    let plan = try await originalClient.prepareDownload(path) { filename in
                        Task { @MainActor [weak self] in if self?.preparing == true { self?.preparingName = "正在读取对方：" + filename } }
                    }
                    results.append(.success(plan))
                } catch { results.append(.failure(error)) }
            }
            return results
        }
        preparationTask = preparation
        Task {
            defer { preparing = false; preparationTask = nil; updateActivity() }
            let results = await preparation.value
            guard connected, client === originalClient, !preparation.isCancelled else { return }
            var errors: [String] = []
            for result in results {
                switch result {
                case .success(let plan):
                    jobs.append(TransferJob(plan: plan, destination: folder.path, peerID: identity, peerName: name,
                        onlyChanged: changed, state: "等待下载", approved: immediately, direction: .download))
                case .failure(let failure): errors.append(failure.localizedDescription)
                }
            }
            saveNow()
            if !errors.isEmpty { error = errors.joined(separator: "\n\n") }
            if immediately { runQueue() }
        }
    }
    func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard canAdd else { return false }
        let direct = directDrop, changed = onlyChanged, destination = path, originalClient = client
        Task {
            var urls: [URL] = []
            for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                let url: URL? = await withCheckedContinuation { continuation in
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                        if let data = item as? Data { continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil)) }
                        else if let url = item as? URL { continuation.resume(returning: url) }
                        else { continuation.resume(returning: nil) }
                    }
                }
                if let url, url.isFileURL { urls.append(url) }
            }
            guard client === originalClient else { return }
            guard !urls.isEmpty else { error = "无法读取拖入的文件，请从 Finder 拖入实际文件或使用“选择文件”。"; return }
            add(urls, immediately: direct, destinationOverride: destination, onlyChangedOverride: changed)
        }
        return true
    }
    func sendPending() {
        guard connected else { return }
        for index in jobs.indices where jobs[index].retryable && jobs[index].peerID == peerID { jobs[index].approved = true }
        runQueue()
    }
    func continueJob(_ id: UUID) {
        guard connected, let index = jobs.firstIndex(where: { $0.id == id && $0.retryable && $0.peerID == peerID }) else { return }
        jobs[index].approved = true; runQueue()
    }
    private func runQueue() {
        guard !running, connected, let client, jobs.contains(where: { $0.retryable && $0.approved && $0.peerID == peerID }) else { return }
        let identity = peerID
        running = true; updateActivity()
        transferTask = Task {
            defer { running = false; saveNow(); updateActivity(); if connected { browse(path) } }
            while let index = jobs.firstIndex(where: { $0.retryable && $0.approved && $0.peerID == identity }) {
                if Task.isCancelled { break }
                let job = jobs[index], id = job.id
                jobs[index].state = job.isDownload ? "下载中" : "发送中"; jobs[index].started = Date(); jobs[index].finished = nil
                jobs[index].sent = 0; jobs[index].networkBytes = 0; jobs[index].detail = ""; jobs[index].phase = "准备发送"
                saveNow()
                do {
                    // Check identity again before every job, including restored jobs.
                    let peer = try await client.hello()
                    guard peer.id == identity else { throw BridgeError("这个地址现在对应另一台设备。请重新连接原设备后继续。") }
                    let updateProgress: (TransferProgress) -> Void = { progress in
                        Task { @MainActor in
                            guard let i = self.jobs.firstIndex(where: { $0.id == id }), self.jobs[i].isActive else { return }
                            self.jobs[i].sent = progress.sent; self.jobs[i].currentFile = progress.currentFile
                            self.jobs[i].networkBytes = progress.networkBytes; self.jobs[i].phase = progress.phase
                        }
                    }
                    let recordFile: (FileTransferRecord) async -> Void = { record in
                        await MainActor.run {
                            guard let i = self.jobs.firstIndex(where: { $0.id == id }), self.jobs[i].isActive else { return }
                            self.jobs[i].records.removeAll { $0.id == record.id }; self.jobs[i].records.append(record)
                            self.scheduleSave()
                        }
                    }
                    let report: TransferReport
                    if job.isDownload {
                        report = try await client.download(job.plan, to: job.destination, onlyChanged: job.onlyChanged,
                            stateDirectory: stateDirectory.appendingPathComponent("Receiver"), progress: updateProgress, onFile: recordFile)
                    } else {
                        report = try await client.transfer(job.plan, to: job.destination, onlyChanged: job.onlyChanged,
                            progress: updateProgress, onFile: recordFile)
                    }
                    if let i = jobs.firstIndex(where: { $0.id == id }) {
                        jobs[i].state = "已完成"; jobs[i].sent = job.plan.totalBytes; jobs[i].savedPath = report.rootPath
                        jobs[i].finished = Date(); jobs[i].records = report.files; jobs[i].networkBytes = report.networkBytes
                        jobs[i].approved = false; jobs[i].phase = "已完成"
                    }
                } catch {
                    if let i = jobs.firstIndex(where: { $0.id == id }) {
                        jobs[i].state = Task.isCancelled ? "已暂停" : "失败"
                        jobs[i].detail = Task.isCancelled ? "断点已保留，点击继续可恢复。" : error.localizedDescription
                        jobs[i].finished = Date()
                    }
                    for pending in jobs.indices where jobs[pending].retryable { jobs[pending].approved = false }
                    saveNow(); break
                }
                saveNow()
            }
        }
    }
    func cancelTransfer() {
        for index in jobs.indices where jobs[index].retryable { jobs[index].approved = false }
        transferTask?.cancel()
    }
    func cancelPreparation() { preparationTask?.cancel() }
    func removeJob(_ id: UUID) { jobs.removeAll { $0.id == id && !$0.isActive }; saveNow() }
    func clearFinished() { jobs.removeAll { $0.state == "已完成" }; saveNow() }
    func exportReport(csv: Bool) {
        let report = AuditReport(jobs: jobs.map(\.audit))
        let panel = NSSavePanel()
        panel.allowedContentTypes = csv ? [.commaSeparatedText] : [.json]
        panel.nameFieldStringValue = "雷桥校验报告-" + ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-") + (csv ? ".csv" : ".json")
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let data = csv ? Data(report.csv().utf8) : try report.json()
                try data.write(to: url, options: .atomic)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch { self.error = "报告导出失败：\(error.localizedDescription)" }
        }
    }
    func clearResumeCache() {
        Task {
            do {
                let server = self.server
                let count = try await Task.detached { try server.clearIncompleteTransfers() }.value
                notice = "已清理 \(count) 个未完成文件的本机断点。已完成的文件未受影响。"
            } catch { self.error = "清理断点失败：\(error.localizedDescription)" }
        }
    }
    func shutdown() {
        saveTask?.cancel(); preparationTask?.cancel()
        for i in jobs.indices { jobs[i].approved = false; if jobs[i].isActive { jobs[i].state = "已暂停" } }
        saveNow(); stopSharing()
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
    }
    private func updateActivity() {
        if hasTransfers && activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "雷桥正在传输文件")
        } else if !hasTransfers, let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
    }
}
