import SwiftUI
import AppKit
import FolderSafeCore

@main
struct FolderSafeMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model: AppModel
    @AppStorage(Pref.keepInMenuBar) private var keepInMenuBar = true

    init() {
        Pref.registerDefaults()
        let m: AppModel
        if Snapshot.request != nil {
            Snapshot.prepare()
            m = Snapshot.demoModel()
        } else {
            // 先用 File Provider 启动；用户选了 FSKit 且扩展已打开时，启动后再切过去（查询扩展状态可能要几秒）。
            m = AppModel(service: VaultService(presenter: FileProviderPresenter()), choice: .fileProvider)
        }
        _model = StateObject(wrappedValue: m)
        AppDelegate.model = m
    }

    var body: some Scene {
        Window("FolderSafe", id: "main") {
            MainView()
                .environmentObject(model)
        }
        .defaultSize(width: 920, height: 620)
        .commands { AppCommands(model: model) }

        Window("About FolderSafe", id: "about") {
            AboutView()
                .frame(width: 480)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environmentObject(model)
        }

        MenuBarExtra(isInserted: Binding(get: { keepInMenuBar && !model.isDemo }, set: { keepInMenuBar = $0 })) {
            MenuBarContent().environmentObject(model)
        } label: {
            Image(systemName: model.anyUnlocked ? "lock.open.fill" : "lock.fill")
                .accessibilityLabel(Text("FolderSafe"))
        }
    }
}

struct AppCommands: Commands {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About FolderSafe") { openWindow(id: "about") }
        }
        CommandGroup(replacing: .newItem) {
            Button("New Vault…") { model.bringMainWindowForward(); model.sheet = .create }
                .keyboardShortcut("n")
            Button("Add Existing Vault…") { model.bringMainWindowForward(); model.showAddExisting() }
                .keyboardShortcut("o")
            Divider()
            Button("Lock All") { model.requestLockAll() }
                .keyboardShortcut("l")
                .disabled(!model.anyUnlocked)
        }
        CommandGroup(replacing: .help) {
            Button("Send Feedback…") {
                NSWorkspace.shared.open(Feedback.mailto)
            }
            Divider()
            Button("FolderSafe Website") { NSWorkspace.shared.open(AppInfo.website) }
            Button("Privacy Policy") { NSWorkspace.shared.open(AppInfo.privacyURL) }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var model: AppModel?
    @MainActor private var autoLock: AutoLockMonitor?
    @MainActor private var terminating = false

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        if Snapshot.request != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { Snapshot.run() }
            return
        }
        guard let model = Self.model else { return }
        let monitor = AutoLockMonitor(model: model)
        monitor.start()
        autoLock = monitor
        Task {
            // 上次异常退出时留下的 File Provider 位置、FSKit 挂载一律撤下（启动时所有 vault 都是锁着的）
            await FileProviderPresenter.removeStaleDomains()
            #if !APPSTORE
            if FSKitPresenter.isSystemSupported {
                let active = Set(model.unlocked.values.map { ($0.path as NSString).standardizingPath })
                await Task.detached(priority: .userInitiated) { FSKitPresenter.unmountStale(except: active) }.value
            }
            #endif
            await model.refreshFSKit()
        }
    }


    @MainActor
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        if Snapshot.request != nil { return false }
        return !UserDefaults.standard.bool(forKey: Pref.keepInMenuBar)
    }

    @MainActor
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Self.model?.bringMainWindowForward() }
        return true
    }

    /// 退出时一律强制上锁全部 vault（最多等 15 秒）。
    /// 超时还没锁完：先删掉全部解锁钥匙再退出（File Provider 扩展从此拒绝访问），没撤下的位置 / 挂载下次启动时撤下。
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model, model.anyUnlocked, !terminating else { return .terminateNow }
        terminating = true
        var replied = false
        let reply = {
            if !replied { replied = true; sender.reply(toApplicationShouldTerminate: true) }
        }
        Task { @MainActor in
            await model.autoLockAll()
            reply()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            if !replied { model.service?.removeAllUnlockedKeys() }
            reply()
        }
        return .terminateLater
    }
}
