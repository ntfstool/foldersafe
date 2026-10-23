import SwiftUI
import AppKit

enum SettingsTab: String { case general, autoLock, privacy, about }

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State var tab: SettingsTab = .general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            AutoLockSettings()
                .tabItem { Label("Auto-Lock", systemImage: "lock.rotation") }
                .tag(SettingsTab.autoLock)
            PrivacySettings()
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
                .tag(SettingsTab.privacy)
            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        .frame(width: 540)
        .frame(minHeight: 380)
    }
}

// MARK: - 通用

struct GeneralSettings: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(Pref.keepInMenuBar) private var keepInMenuBar = true
    @AppStorage(Pref.openAfterUnlock) private var openAfterUnlock = true
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Open FolderSafe at login", isOn: Binding(get: { launchAtLogin }, set: { on in
                    do { try LoginItem.set(on); loginError = nil } catch { loginError = error.localizedDescription }
                    launchAtLogin = LoginItem.isEnabled
                }))
                if LoginItem.needsApproval {
                    HStack {
                        Text("Allow FolderSafe in System Settings › General › Login Items.").font(.caption).foregroundStyle(.secondary)
                        Button("Open") { LoginItem.openSystemSettings() }.controlSize(.small)
                    }
                }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                Toggle(isOn: $keepInMenuBar) {
                    Text("Keep running in the menu bar")
                    Text("When you close the window, FolderSafe stays in the menu bar so you can lock and unlock quickly and auto-lock keeps working.")
                }
                Toggle("Open the vault in Finder after unlocking", isOn: $openAfterUnlock)
            }
            Section {
                LabeledContent("Unlocked vaults appear") {
                    Text(model.choice == .fskit ? LocalizedStringKey("As real folders (~/FolderSafe)")
                                                : LocalizedStringKey("In Finder’s sidebar, under Locations"))
                        .foregroundStyle(.secondary)
                }
                if AppModel.fskitOfferable {
                    Toggle(isOn: Binding(get: { model.wantsFSKit }, set: { model.setUseFSKit($0) })) {
                        Text("Open vaults as real folders (beta)")
                        Text(model.anyUnlocked
                             ? LocalizedStringKey("Lock all vaults to change this.")
                             : LocalizedStringKey("Uses a macOS file system extension so unlocked vaults open as ordinary folders that every app can use. Requires turning the extension on once in System Settings."))
                    }
                    .disabled(model.anyUnlocked)
                    if model.wantsFSKit && model.fskitStatus != .enabled {
                        FSKitSetupSteps()
                        HStack {
                            Button("Open System Settings") { FSKitSetupSteps.openSettings() }
                            Button("Check Again") { Task { await model.refreshFSKit() } }
                                .disabled(model.fskitStatus == .checking)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = LoginItem.isEnabled }
    }
}

// MARK: - 自动上锁

struct AutoLockSettings: View {
    @AppStorage(Pref.lockOnSleep) private var onSleep = true
    @AppStorage(Pref.lockOnScreenLock) private var onScreenLock = true
    @AppStorage(Pref.lockWhenIdle) private var whenIdle = true
    @AppStorage(Pref.idleMinutes) private var idleMinutes = 30

    var body: some View {
        Form {
            Section {
                Toggle("Lock when the Mac goes to sleep", isOn: $onSleep)
                Toggle("Lock when the screen locks or the screen saver starts", isOn: $onScreenLock)
                Toggle("Lock when the Mac is idle", isOn: $whenIdle)
                Picker("Idle time", selection: $idleMinutes) {
                    ForEach([5, 10, 15, 30, 60, 120], id: \.self) { m in
                        Text(m < 60 ? "\(m) minutes" : (m == 60 ? "1 hour" : "2 hours")).tag(m)
                    }
                }
                .disabled(!whenIdle)
            } header: {
                Text("Lock all vaults automatically")
            } footer: {
                Text("FolderSafe also locks all vaults when it quits. Automatic locking closes vaults even if apps still have files open in them, so save your work regularly.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Label {
                    Text("A locked vault is only encrypted data. While a vault is unlocked, any app on this Mac — including AI tools — can read its files, so the shorter it stays open, the better.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "lightbulb").foregroundStyle(.yellow)
                }
                .font(.callout)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 隐私

struct PrivacySettings: View {

    var body: some View {
        Form {
            Section {
                Label("This version of FolderSafe never connects to the internet.", systemImage: "network.slash")
                Label("No account, no ads, no tracking.", systemImage: "person.crop.circle.badge.xmark")
                Label("FolderSafe never sends your password, recovery phrase or keys anywhere.", systemImage: "key.fill")
            }
            Section {
                Link(destination: AppInfo.privacyURL) {
                    Label("Privacy Policy", systemImage: "arrow.up.right.square")
                }
            }
        }
        .formStyle(.grouped)
    }
}
