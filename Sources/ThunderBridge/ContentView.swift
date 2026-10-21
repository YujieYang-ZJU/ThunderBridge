import SwiftUI
import AppKit
import BridgeCore
import UniformTypeIdentifiers

private let accent = Color(red: 0.24, green: 0.32, blue: 0.92)
private let ink = Color(red: 0.12, green: 0.16, blue: 0.25)
private let secondary = Color(red: 0.47, green: 0.51, blue: 0.59)
private let strokeColor = Color(red: 0.89, green: 0.91, blue: 0.95)

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var hoveringDrop = false
    @State private var activityTab = 0
    @State private var activityExpanded = false
    @State private var showSidebar = true

    var body: some View {
        HStack(spacing: 0) {
            if showSidebar {
                sidebar.frame(width: 260)
                Rectangle().fill(strokeColor).frame(width: 1)
            }
            VStack(alignment: .leading, spacing: 12) {
                header
                VSplitView {
                    browser.frame(minHeight: 310, maxHeight: .infinity)
                    if activityExpanded {
                        activity.frame(minHeight: 180, idealHeight: 210, maxHeight: 340).padding(.top, 8)
                    }
                }
                dropZone
                if !activityExpanded {
                    activityHeader
                    if let active = model.jobs.first(where: { $0.isActive }) {
                        HStack {
                            Text((active.isDownload ? "正在下载：" : "正在发送：") + active.plan.source.lastPathComponent)
                                .font(.system(size: 11)).lineLimit(1)
                            ProgressView(value: active.progress).frame(maxWidth: 240)
                            Text(active.phase).font(.system(size: 10)).foregroundStyle(secondary)
                        }
                    } else if let recent = model.jobs.last {
                        HStack {
                            Text((recent.isDownload ? "下载" : "上传") + " · " + recent.state + " · " + recent.plan.source.lastPathComponent)
                                .font(.system(size: 11)).foregroundStyle(recent.state == "失败" ? .red : secondary).lineLimit(1)
                            Spacer()
                            if recent.isDownload, recent.state == "已完成", let path = recent.savedPath {
                                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                                    .font(.system(size: 11))
                            }
                            Button("查看详情") { activityExpanded = true }.font(.system(size: 11))
                        }
                    }
                }
            }
            .padding(.horizontal, 20).padding(.top, 28).padding(.bottom, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(red: 0.975, green: 0.98, blue: 0.99))
        }
        .foregroundStyle(ink).tint(accent).preferredColorScheme(.light)
        .alert("暂时无法完成", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("知道了", role: .cancel) { model.error = nil }
            if (model.error ?? "").contains("本地网络权限") {
                Button("本地网络权限设置") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!) }
            } else if (model.error ?? "").contains("权限") || (model.error ?? "").localizedCaseInsensitiveContains("permitted") {
                Button("文件访问权限设置") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!) }
            }
        } message: { Text(model.error ?? "") }
        .alert("在对方当前目录新建文件夹", isPresented: $model.showingNewFolder) {
            TextField("文件夹名称", text: $model.newFolder)
            Button("取消", role: .cancel) {}
            Button("创建") { model.makeFolder() }
        } message: { Text(model.path) }
        .alert("保存投递方案", isPresented: $model.showingPresetName) {
            TextField("方案名称", text: $model.presetName)
            Button("取消", role: .cancel) {}
            Button("保存") { model.savePreset() }
        } message: { Text("记录来源与目标。下次从“批量投递”中选择，即可读取来源的最新内容并发送。") }
        .alert("清理本机未完成的接收断点？", isPresented: $model.showingClearCache) {
            Button("取消", role: .cancel) {}
            Button("清理断点", role: .destructive) { model.clearResumeCache() }
        } message: { Text("清理后，这些未完成文件需要从头接收。已完成文件会保留；正在使用的断点会跳过。") }
        .alert("已完成", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("知道了", role: .cancel) { model.notice = nil }
        } message: { Text(model.notice ?? "") }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                HStack(spacing: 12) {
                    Image(systemName: "bolt.horizontal.fill")
                        .font(.system(size: 25, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(LinearGradient(colors: [accent, Color(red: 0.45, green: 0.35, blue: 0.96)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .clipShape(RoundedRectangle(cornerRadius: 15))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("雷桥").font(.system(size: 24, weight: .bold))
                        Text("THUNDERBRIDGE").font(.system(size: 9, weight: .semibold)).tracking(2.1).foregroundStyle(secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 13) {
                    sectionTitle("这台 Mac", number: "01")
                    HStack {
                        Label(Host.current().localizedName ?? "我的 Mac", systemImage: "laptopcomputer")
                            .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Spacer()
                        Circle().fill(model.sharing ? Color.green : secondary.opacity(0.4)).frame(width: 7, height: 7)
                    }
                    HStack {
                        Text("连接网络").font(.caption).foregroundStyle(secondary)
                        Spacer()
                        Button { model.refreshAddresses() } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.plain).disabled(model.sharing || model.connected || model.connecting || model.startingShare)
                            .help("刷新可用网络地址")
                    }
                    Picker("连接网络", selection: $model.localAddress) {
                        if model.addresses.isEmpty { Text("暂无可用地址").tag("") }
                        ForEach(model.addresses) { address in Text(address.label).tag(address.address) }
                    }
                    .labelsHidden().frame(maxWidth: .infinity).disabled(model.sharing || model.connected || model.connecting || model.startingShare)
                    Text(model.hasBridgeAddress ? "优先使用雷雳网桥，两台 Mac 选择相连的网络即可。" : "尚未检测到雷雳网桥 IPv4 地址。请先接线并检查网络设置；当前列出的是其他网络。")
                        .font(.system(size: 11)).foregroundStyle(model.hasBridgeAddress ? secondary : Color.orange).fixedSize(horizontal: false, vertical: true)
                    Button { model.toggleSharing() } label: {
                        HStack {
                            if model.startingShare { ProgressView().controlSize(.small) }
                            Image(systemName: model.sharing ? "stop.circle" : "antenna.radiowaves.left.and.right")
                            Text(model.sharing ? "停止本机共享" : "开启本机共享")
                        }.frame(maxWidth: .infinity).padding(.vertical, 5)
                    }
                    .buttonStyle(.borderedProminent).disabled(model.startingShare)
                    Label("开放当前用户可访问的所有文件夹", systemImage: "folder.badge.person.crop")
                        .font(.system(size: 10)).foregroundStyle(secondary).fixedSize(horizontal: false, vertical: true)
                    if model.sharing {
                        Text("此网络上的设备可直接浏览、下载和写入文件。仅在可信网络开启；停止共享会断开连接。")
                            .font(.system(size: 10)).foregroundStyle(secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Divider().overlay(strokeColor)
                VStack(alignment: .leading, spacing: 12) {
                    sectionTitle("附近的 Mac", number: "02")
                    if model.connected {
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title2)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.peerName).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                                Text("已连接 · 可上传与下载").font(.system(size: 11)).foregroundStyle(secondary)
                            }
                        }.padding(.vertical, 8)
                        Button { model.openScreenSharing() } label: {
                            HStack {
                                if model.openingScreenSharing { ProgressView().controlSize(.small) }
                                Label(model.openingScreenSharing ? "正在打开…" : "屏幕共享", systemImage: "rectangle.on.rectangle")
                            }.frame(maxWidth: .infinity).padding(.vertical, 3)
                        }
                        .buttonStyle(.bordered).disabled(!model.canOpenScreenSharing)
                        .help(model.peerAddress.map { "使用 Mac 自带的屏幕共享连接 \($0)" } ?? "未能取得对方地址，请重新连接设备。")
                        Text("对方需在系统设置 → 通用 → 共享中开启“屏幕共享”。")
                            .font(.system(size: 10)).foregroundStyle(secondary).fixedSize(horizontal: false, vertical: true)
                        Button("断开连接") { model.disconnect() }.disabled(model.running || model.preparing)
                    } else {
                        HStack(alignment: .top, spacing: 8) {
                            if model.sharing { ProgressView().controlSize(.small) }
                            Text(model.discoveryStatus).font(.system(size: 11)).foregroundStyle(secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(model.nearbyPeers) { peer in
                            Button { model.connect(to: peer) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "laptopcomputer").foregroundStyle(accent)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(peer.name).font(.system(size: 12, weight: .medium)).lineLimit(2)
                                        Text("已开启共享 · 点击连接").font(.system(size: 10)).foregroundStyle(secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.right").font(.system(size: 11))
                                }.padding(11).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.white).clipShape(RoundedRectangle(cornerRadius: 9))
                            }.buttonStyle(.plain).disabled(model.connecting || model.running || model.preparing)
                        }
                        if model.sharing && !model.connecting {
                            Button("重新尝试自动连接") { model.retryAutomaticConnection() }
                                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(accent)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Label("一根线，两台 Mac。", systemImage: "cable.connector").font(.system(size: 12, weight: .medium))
                    Text("两边开启共享，自动发现并连接。无需填写 IP、端口或连接码。")
                        .font(.system(size: 11)).foregroundStyle(secondary).lineSpacing(4)
                    Button("雷雳网桥设置指南 ↗") { NSWorkspace.shared.open(URL(string: "https://support.apple.com/zh-cn/guide/mac-help/mchld53dd2f5/mac")!) }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(accent)
                    Button("清理本机接收断点…") { model.showingClearCache = true }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(secondary)
                }.padding(.top, 6)
            }.padding(.horizontal, 18).padding(.top, 32).padding(.bottom, 26)
        }.background(Color(red: 0.94, green: 0.95, blue: 0.975))
    }

    private func sectionTitle(_ title: String, number: String) -> some View {
        HStack {
            Text(title).font(.system(size: 13, weight: .bold))
            Spacer()
            Text(number).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(secondary)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Button { showSidebar.toggle() } label: { Image(systemName: "sidebar.left").font(.system(size: 18)) }
                .buttonStyle(.plain).help(showSidebar ? "收起连接侧栏" : "展开连接侧栏")
            VStack(alignment: .leading, spacing: 3) {
                Text("文件传输").font(.system(size: 22, weight: .bold))
                Text("浏览对方文件，直接上传或下载到本机。")
                    .font(.system(size: 12)).foregroundStyle(secondary)
            }
            Spacer()
            Label("本地直连 · TLS 加密", systemImage: "lock.shield")
                .font(.system(size: 10, weight: .medium)).foregroundStyle(accent)
                .padding(.horizontal, 11).padding(.vertical, 8).background(accent.opacity(0.07)).clipShape(Capsule())
        }
    }

    private var browser: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "externaldrive.connected.to.line.below").foregroundStyle(accent)
                Text("对方的文件").font(.system(size: 15, weight: .semibold))
                if model.connected { Text("/  \(model.peerName)").font(.system(size: 11)).foregroundStyle(secondary).lineLimit(1) }
                Spacer()
                if model.loading { ProgressView().controlSize(.small) }
                if model.connected {
                    Button { model.chooseDownload() } label: {
                        Label(model.selectedEntries.isEmpty ? "下载到本机…" : "下载所选（\(model.selectedEntries.count)）…", systemImage: "arrow.down.to.line")
                    }.buttonStyle(.borderedProminent).disabled(!model.canDownload)
                    Toggle("隐藏文件", isOn: $model.showHidden).font(.system(size: 10)).toggleStyle(.checkbox)
                    Button { model.browse(model.path) } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).help("刷新目录")
                }
            }.padding(12)
            Divider().overlay(strokeColor)
            if model.connected {
                HStack(spacing: 10) {
                    Button { model.goUp() } label: { Image(systemName: "arrow.up") }.disabled(model.path == "/" || model.loading).help("上一级")
                    TextField("输入对方文件夹的绝对路径，按回车打开", text: $model.pathDraft)
                        .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced)).onSubmit { model.browse(model.pathDraft) }
                        .padding(8).background(Color.black.opacity(0.025)).clipShape(RoundedRectangle(cornerRadius: 6))
                    Button { model.toggleFavorite() } label: { Image(systemName: model.isFavorite ? "star.fill" : "star") }
                        .foregroundStyle(model.isFavorite ? Color.orange : secondary).disabled(model.loading)
                        .help(model.isFavorite ? "取消收藏当前目录" : "收藏当前目录")
                    Button { model.newFolder = "新建文件夹"; model.showingNewFolder = true } label: { Image(systemName: "folder.badge.plus") }
                        .disabled(!model.writable || model.loading).help("在对方当前目录新建文件夹")
                }.padding(.horizontal, 16).padding(.vertical, 10)
                HStack(spacing: 10) {
                    shortcut("个人", icon: "house", path: model.remoteHome)
                    shortcut("桌面", icon: "desktopcomputer", path: model.remoteHome + "/Desktop")
                    shortcut("下载", icon: "arrow.down.circle", path: model.remoteHome + "/Downloads")
                    shortcut("磁盘", icon: "externaldrive", path: "/Volumes")
                    shortcut("根目录", icon: "internaldrive", path: "/")
                    Menu("常用目标") {
                        if model.currentFavorites.isEmpty { Text("点击路径旁的星标收藏目录") }
                        ForEach(model.currentFavorites) { favorite in
                            Button(favorite.path) { model.browse(favorite.path) }
                        }
                        if !model.currentFavorites.isEmpty {
                            Divider()
                            Menu("移除收藏") {
                                ForEach(model.currentFavorites) { favorite in
                                    Button(favorite.path) { model.removeFavorite(favorite.id) }
                                }
                            }
                        }
                    }.font(.system(size: 10)).fixedSize().disabled(model.loading)
                    Spacer(minLength: 0)
                    TextField("筛选名称", text: $model.search).textFieldStyle(.roundedBorder).font(.system(size: 10)).frame(width: 110)
                }.padding(.horizontal, 16).padding(.bottom, 10)
                Divider().overlay(strokeColor)
                remoteTable
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(model.loading ? 0.45 : 1).disabled(model.loading)
                HStack {
                    Circle().fill(model.writable ? Color.green : Color.orange).frame(width: 6, height: 6)
                    Text(model.writable ? "可上传 · 双击文件夹进入 · ⌘ / ⇧ 多选" : "当前目录不可上传 · 仍可下载有读取权限的文件")
                    Spacer()
                    Text("\(model.visibleEntries.count) 项 · 已选 \(model.selectedEntries.count) 项")
                }.font(.system(size: 10)).foregroundStyle(secondary).padding(.horizontal, 16).padding(.vertical, 10).background(Color.black.opacity(0.015))
            } else {
                VStack(spacing: 16) {
                    HStack(spacing: 20) {
                        Image(systemName: "laptopcomputer").font(.system(size: 46, weight: .ultraLight))
                        Image(systemName: "bolt.horizontal.fill").font(.system(size: 24)).foregroundStyle(accent)
                        Image(systemName: "laptopcomputer").font(.system(size: 46, weight: .ultraLight))
                    }.foregroundStyle(ink.opacity(0.6))
                    Text("等待连接另一台 Mac").font(.system(size: 16, weight: .semibold))
                    Text("两边点击“开启本机共享”，即可自动发现对方。\n连接后可上传与下载，支持 ⌘ / ⇧ 多选。")
                        .font(.system(size: 12)).foregroundStyle(secondary).multilineTextAlignment(.center).lineSpacing(5)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(28)
            }
        }.background(.white).clipShape(RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(strokeColor, lineWidth: 1))
    }

    private func shortcut(_ title: String, icon: String, path: String) -> some View {
        Button { model.browse(path) } label: { Label(title, systemImage: icon).font(.system(size: 10)) }
            .buttonStyle(.plain).foregroundStyle(secondary).disabled(model.loading)
    }
    private var remoteTable: some View {
        Table(model.visibleEntries, selection: $model.selectedPaths, sortOrder: $model.sortOrder) {
            TableColumn("名称", sortUsing: RemoteEntryComparator(.name)) { entry in
                HStack(spacing: 9) {
                    Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                        .foregroundStyle(entry.isDirectory ? accent : secondary).font(.system(size: 20)).frame(width: 24)
                    Text(entry.name).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                    if entry.isSymbolicLink { Image(systemName: "arrow.turn.up.right").font(.caption) }
                }.frame(height: 24).help(entry.path)
            }.width(min: 240, ideal: 400)
            TableColumn("大小", sortUsing: RemoteEntryComparator(.size)) { entry in
                Text(entry.isDirectory ? "文件夹" : formatBytes(entry.size)).font(.system(size: 12)).foregroundStyle(secondary)
            }.width(min: 75, ideal: 90, max: 110)
            TableColumn("修改时间", sortUsing: RemoteEntryComparator(.modified)) { entry in
                Text(entry.modified?.formatted(date: .numeric, time: .shortened) ?? "—")
                    .font(.system(size: 12)).foregroundStyle(secondary)
            }.width(min: 130, ideal: 160, max: 190)
        }
        .contextMenu(forSelectionType: String.self) { paths in
            if paths.count == 1, let entry = model.entries.first(where: { paths.contains($0.path) }), entry.isDirectory {
                Button("打开文件夹") { model.browse(entry.path) }
            }
            Button("下载到本机…") { model.chooseDownload(paths: paths) }.disabled(paths.isEmpty || model.preparing)
        } primaryAction: { paths in
            if paths.count == 1, let entry = model.entries.first(where: { paths.contains($0.path) }), entry.isDirectory {
                model.browse(entry.path)
            } else { model.chooseDownload(paths: paths) }
        }
        .overlay {
            if model.visibleEntries.isEmpty {
                Text(model.search.isEmpty ? "此文件夹为空，可以上传文件。" : "没有匹配的项目")
                    .font(.system(size: 13)).foregroundStyle(secondary).allowsHitTesting(false)
            }
        }
    }

    private var dropZone: some View {
        HStack(spacing: 14) {
            Image(systemName: "square.and.arrow.up").font(.system(size: 26, weight: .light)).foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 5) {
                Text(model.preparing ? model.preparingName : "拖入文件，上传到当前目录")
                    .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(model.connected ? "目标：\(model.path)" : "先连接对方，并选择目标文件夹")
                    .font(.system(size: 10)).foregroundStyle(secondary).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 14) {
                    Toggle("拖入即发送", isOn: $model.directDrop)
                    Toggle("只传变化文件", isOn: $model.onlyChanged)
                        .help("新任务按 SHA-256 跳过相同内容；变化的同名文件另存副本。已有队列保持添加时的设置。")
                }.toggleStyle(.checkbox).font(.system(size: 10)).foregroundStyle(secondary)
            }
            Spacer()
            Menu {
                Button("保存当前目标为投递方案…") { model.choosePresetSources() }.disabled(!model.canAdd)
                if !model.currentPresets.isEmpty {
                    Divider()
                    ForEach(model.currentPresets) { preset in
                        Button(preset.name + " → " + URL(fileURLWithPath: preset.destination).lastPathComponent) { model.deliver(preset) }
                            .disabled(!model.connected || model.preparing)
                    }
                }
                if !model.presets.isEmpty {
                    Divider()
                    Menu("删除方案") {
                        ForEach(model.presets) { preset in
                            Button(preset.name + " · " + preset.peerName) { model.removePreset(preset.id) }
                        }
                    }
                }
            } label: { Label("批量投递", systemImage: "paperplane") }.fixedSize()
            if model.preparing {
                Button("停止准备") { model.cancelPreparation() }
            }
            Button { model.chooseFiles() } label: { Label("上传文件…", systemImage: "arrow.up.to.line").padding(.vertical, 4) }
                .buttonStyle(.bordered).disabled(!model.canAdd)
        }.padding(12).background(hoveringDrop ? accent.opacity(0.1) : accent.opacity(0.035))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(accent.opacity(hoveringDrop ? 0.7 : 0.25), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $hoveringDrop, perform: model.acceptDrop)
    }

    private var activityHeader: some View {
        HStack(spacing: 12) {
                Button { activityTab = 0; activityExpanded = true } label: { Text("传输队列  \(model.jobs.count)").font(.system(size: 13, weight: .semibold)).foregroundStyle(activityTab == 0 ? ink : secondary) }.buttonStyle(.plain)
                Button { activityTab = 1; activityExpanded = true } label: { Text("对方传入  \(model.incoming.count)").font(.system(size: 13, weight: .semibold)).foregroundStyle(activityTab == 1 ? ink : secondary) }.buttonStyle(.plain)
                Spacer()
                Button { activityExpanded.toggle() } label: {
                    Image(systemName: activityExpanded ? "chevron.down" : "chevron.up")
                }.buttonStyle(.plain).help(activityExpanded ? "收起队列，放大文件列表" : "展开传输队列")
                Menu {
                    Button("导出 CSV 表格…") { model.exportReport(csv: true) }
                    Button("导出 JSON 明细…") { model.exportReport(csv: false) }
                } label: { Image(systemName: "square.and.arrow.up") }
                    .fixedSize().disabled(model.jobs.isEmpty).accessibilityLabel("导出校验报告")
                    .help("导出全部上传与下载任务的校验报告，包括未完成项")
                if activityTab == 0 {
                    if model.running {
                        Button("暂停传输") { model.cancelTransfer() }
                    } else {
                        Button("清理已完成") { model.clearFinished() }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(secondary)
                        Button { model.sendPending() } label: { Label("开始传输\(model.pendingCount > 0 ? "（\(model.pendingCount)）" : "")", systemImage: "arrow.up.right").padding(.vertical, 2) }
                            .buttonStyle(.borderedProminent).disabled(model.pendingCount == 0 || !model.connected || model.preparing)
                    }
                }
            }
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 12) {
            activityHeader
            ScrollView {
                LazyVStack(spacing: 10) {
                    if activityTab == 0 {
                        if model.jobs.isEmpty { emptyActivity("上传或下载后，任务进度和校验结果会显示在这里。", icon: "tray") }
                        ForEach(model.jobs) { job in jobRow(job) }
                    } else {
                        if model.incoming.isEmpty { emptyActivity("开启本机共享后，对方发来的文件会显示在这里。", icon: "tray.and.arrow.down") }
                        ForEach(model.incoming) { event in incomingRow(event) }
                    }
                }
            }
            HStack(spacing: 14) {
                Label("同名自动另存", systemImage: "doc.on.doc")
                Label("SHA-256 完整性校验", systemImage: "checkmark.shield")
                Spacer()
                Text("v0.5.1 · 自动连接")
            }.font(.system(size: 9)).foregroundStyle(secondary)
        }
    }
    private func emptyActivity(_ title: String, icon: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 23, weight: .light)).foregroundStyle(secondary.opacity(0.6))
            Text(title).font(.system(size: 11)).foregroundStyle(secondary)
        }.frame(maxWidth: .infinity).frame(height: 130)
    }
    private func jobRow(_ job: TransferJob) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: job.state == "已完成" ? "checkmark.circle.fill" : (job.isDownload ? "arrow.down.circle" : "arrow.up.circle"))
                    .foregroundStyle(job.state == "已完成" ? Color.green : accent)
                Text((job.isDownload ? "下载 · " : "上传 · ") + job.plan.source.lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer()
                if job.isDownload, job.state == "已完成", let path = job.savedPath {
                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                }
                Text(job.state).foregroundStyle(job.state == "失败" ? Color.red : secondary)
                if job.retryable && !["等待发送", "等待下载"].contains(job.state) {
                    Button("继续") { model.continueJob(job.id) }
                        .disabled(model.running || !model.connected || model.peerID != job.peerID)
                }
                if !job.isActive { Button { model.removeJob(job.id) } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
            }.font(.system(size: 10))
            if job.isActive { ProgressView(value: job.progress).tint(accent) }
            if job.isActive {
                Text(job.phase + (job.currentFile.isEmpty ? "" : " · " + job.currentFile))
                    .font(.system(size: 9)).foregroundStyle(accent).lineLimit(1)
            }
            HStack {
                Text("\(formatBytes(job.sent)) / \(formatBytes(job.plan.totalBytes)) · 已核验 \(job.verifiedCount)/\(job.plan.fileCount) · 跳过 \(job.skippedCount)")
                Spacer()
                if !job.speed.isEmpty { Text(job.speed).monospacedDigit() }
            }.font(.system(size: 9)).foregroundStyle(secondary)
            Text(job.detail.isEmpty ? "→ \(job.isDownload ? "本机" : job.peerName) · \(job.savedPath ?? job.destination)" : job.detail)
                .font(.system(size: 9)).foregroundStyle(job.detail.isEmpty ? secondary : Color.red)
                .lineLimit(2).textSelection(.enabled)
            if !model.connected || model.peerID != job.peerID {
                Text(job.state == "已完成" ? "已完成的历史任务 · \(job.peerName)" : "此任务属于 \(job.peerName)，连接原设备后可继续。")
                    .font(.system(size: 9)).foregroundStyle(secondary)
            }
        }.padding(12).background(.white).clipShape(RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(strokeColor, lineWidth: 1))
    }
    private func incomingRow(_ event: IncomingEvent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: event.savedPath == nil ? "arrow.down.circle" : "checkmark.circle.fill").foregroundStyle(event.savedPath == nil ? accent : .green)
                Text(event.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer()
                Text(event.status).font(.system(size: 10)).lineLimit(1)
                if let path = event.savedPath {
                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }.font(.system(size: 10))
                }
            }
            if event.status == "接收中", event.total > 0 { ProgressView(value: Double(event.completed) / Double(event.total)) }
            Text(event.savedPath ?? "\(formatBytes(event.completed)) / \(formatBytes(event.total))")
                .font(.system(size: 9)).foregroundStyle(secondary).lineLimit(1).textSelection(.enabled)
        }.padding(12).background(.white).clipShape(RoundedRectangle(cornerRadius: 9))
    }
}
