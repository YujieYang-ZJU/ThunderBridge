import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model?.hasTransfers == true {
            let alert = NSAlert()
            alert.messageText = "文件仍在传输，确定退出？"
            alert.informativeText = "未完成的传输会暂停，断点与已保存队列会保留，下次连接原设备后可以继续。尚在准备的项目需要重新添加。"
            alert.addButton(withTitle: "继续传输"); alert.addButton(withTitle: "退出")
            if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        }
        model?.shutdown()
        return .terminateNow
    }
}

@main
struct ThunderBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("雷桥 · ThunderBridge") {
            ContentView(model: model)
                .frame(minWidth: 1040, minHeight: 730)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 1320, height: 900)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .help) {
                Button("雷雳网桥设置指南") {
                    NSWorkspace.shared.open(URL(string: "https://support.apple.com/zh-cn/guide/mac-help/mchld53dd2f5/mac")!)
                }
            }
        }
    }
}
