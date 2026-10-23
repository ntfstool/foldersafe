import SwiftUI
import AppKit

/// 菜单栏菜单：每个 vault 一个子菜单（解锁 / 上锁 / 在访达中打开），全部上锁，打开主窗口，退出。
struct MenuBarContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let _ = registerOpener()
        if model.records.isEmpty {
            Text("No vaults yet")
        } else {
            ForEach(model.records) { r in
                let unlocked = model.isUnlocked(r.id)
                Menu {
                    if unlocked {
                        Button("Open in Finder") { model.reveal(r.id) }
                        Button("Lock") { model.bringMainWindowForward(); model.requestLock(r.id) }
                    } else if model.touchIDEnabled.contains(r.id) {
                        Button("Unlock with \(model.biometryName)") { model.quickUnlock(r.id) }
                        Button("Unlock with Password…") { model.showWindowAndUnlock(r.id) }
                    } else {
                        Button("Unlock…") { model.showWindowAndUnlock(r.id) }
                    }
                } label: {
                    Label {
                        if unlocked { Text("\(r.name) — Unlocked") } else { Text(verbatim: r.name) }
                    } icon: {
                        Image(systemName: unlocked ? "lock.open.fill" : "lock.fill")
                    }
                }
            }
        }
        Divider()
        Button("Lock All") { model.requestLockAll() }
            .keyboardShortcut("l")
            .disabled(!model.anyUnlocked)
        Divider()
        Button("Open FolderSafe…") { model.bringMainWindowForward() }
            .keyboardShortcut("o")
        Button("New Vault…") { model.bringMainWindowForward(); model.sheet = .create }
        SettingsMenuButton()
        Divider()
        Button("Quit FolderSafe") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func registerOpener() {
        let open = openWindow
        DispatchQueue.main.async { model.openMainWindow = { open(id: "main") } }
    }
}

/// "设置…"：macOS 14+ 用 SettingsLink，13 用 showSettingsWindow: 选择器。
struct SettingsMenuButton: View {
    var body: some View {
        if #available(macOS 14.0, *) {
            SettingsLink { Text("Settings…") }
                .keyboardShortcut(",")
                .simultaneousGesture(TapGesture().onEnded { NSApp.activate(ignoringOtherApps: true) })
        } else {
            Button("Settings…") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            .keyboardShortcut(",")
        }
    }
}
