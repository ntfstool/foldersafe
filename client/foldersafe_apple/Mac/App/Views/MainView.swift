import SwiftUI
import AppKit

/// 主窗口：左侧 vault 列表，右侧详情；没有 vault 时显示空状态。
struct MainView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage(Pref.keepInMenuBar) private var keepInMenuBar = true

    var body: some View {
        Group {
            if model.records.isEmpty {
                EmptyStateView()
                    .toolbar { toolbarContent }
            } else {
                NavigationSplitView {
                    VaultSidebar()
                        .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 340)
                } detail: {
                    if let id = model.selection, model.record(id) != nil {
                        VaultDetailView(id: id)
                    } else {
                        Text("Select a vault").font(.title3).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .toolbar { toolbarContent }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { Banners() }
        .frame(minWidth: 760, minHeight: 520)
        .sheet(item: $model.sheet) { sheet in
            SheetRouter(sheet: sheet).environmentObject(model)
        }
        .alert(item: $model.notice) { n in
            Alert(title: Text(n.title), message: Text(n.message))
        }
        .modifier(BusyLockAlert())
        .onAppear {
            model.openMainWindow = { openWindow(id: "main") }
            if !model.isDemo { NSApp.setActivationPolicy(.regular) }
        }
        .onDisappear {
            // 窗口关了：留在菜单栏（不占 Dock），自动上锁照常工作。
            if keepInMenuBar && !model.isDemo { NSApp.setActivationPolicy(.accessory) }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.requestLockAll()
            } label: {
                Label("Lock All", systemImage: "lock")
            }
            .help(Text("Lock all vaults (⌘L)"))
            .disabled(!model.anyUnlocked)

            Menu {
                Button("New Vault…") { model.sheet = .create }
                Button("Add Existing Vault…") { model.showAddExisting() }
            } label: {
                Label("Add Vault", systemImage: "plus")
            }
            .help(Text("Create a new vault or add an existing one"))
        }
    }
}

// MARK: - 侧栏

struct VaultSidebar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List(selection: $model.selection) {
            Section("Vaults") {
                ForEach(model.records) { r in
                    VaultRow(record: r)
                        .tag(r.id)
                        .contextMenu { VaultContextMenu(id: r.id) }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

struct VaultRow: View {
    @EnvironmentObject var model: AppModel
    let record: VaultRecord

    var body: some View {
        let unlocked = model.isUnlocked(record.id)
        HStack(spacing: 10) {
            VaultGlyph(unlocked: unlocked, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(record.name).lineLimit(1).truncationMode(.middle)
                Group {
                    if model.inProgress.contains(record.id) {
                        Text("Working…")
                    } else {
                        Text(unlocked ? LocalizedStringKey("Unlocked") : LocalizedStringKey("Locked"))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if model.touchIDEnabled.contains(record.id) {
                Image(systemName: "touchid")
                    .foregroundStyle(.secondary)
                    .help(Text("Touch ID is on"))
            }
        }
        .padding(.vertical, 3)
    }
}

struct VaultContextMenu: View {
    @EnvironmentObject var model: AppModel
    let id: String

    var body: some View {
        if model.isUnlocked(id) {
            Button("Open in Finder") { model.reveal(id) }
            Button("Lock") { model.requestLock(id) }
        } else {
            Button("Unlock…") { model.selection = id; model.beginUnlock(id) }
        }
        Divider()
        Button("Show Encrypted Folder in Finder") { model.revealEncryptedFolder(id) }
    }
}

// MARK: - 空状态

struct EmptyStateView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: 112, height: 112)
                .accessibilityHidden(true)
            Text("Keep files out of reach of AI agents")
                .font(.title.weight(.semibold))
            Text("A FolderSafe vault is an encrypted folder. While it’s locked, nothing on this Mac can read what’s inside — not AI agents, not other apps, not even admin (root) processes.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button {
                    model.sheet = .create
                } label: {
                    Text("New Vault…").frame(minWidth: 130)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                Button {
                    model.showAddExisting()
                } label: {
                    Text("Add Existing Vault…").frame(minWidth: 130)
                }
                .controlSize(.large)
            }
            .padding(.top, 6)
            if !model.isDemo {
                Text("Works with vaults in Cryptomator vault format 8.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 顶部横幅：FSKit 未开启、有更新

struct Banners: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if model.needsFSKitSetup {
                BannerRow(icon: "puzzlepiece.extension.fill", color: .orange,
                          text: Text("To open vaults as real folders, turn on the FolderSafe file system extension. Until then, unlocked vaults appear in Finder’s sidebar.")) {
                    Button("Set Up…") { model.sheet = .fskitSetup }
                }
            }
        }
    }
}

struct BannerRow<Actions: View>: View {
    let icon: String
    let color: Color
    let text: Text
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(color)
            text.font(.callout).lineLimit(2)
            Spacer()
            actions.controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(color.opacity(0.10))
        .overlay(alignment: .bottom) { Divider() }
    }
}

// MARK: - 占用提示

struct BusyLockAlert: ViewModifier {
    @EnvironmentObject var model: AppModel

    func body(content: Content) -> some View {
        content.alert(
            model.busyLock?.vaultIDs.count ?? 0 > 1 ? Text("Some vaults are in use") : Text("This vault is in use"),
            isPresented: Binding(get: { model.busyLock != nil }, set: { if !$0 { model.busyLock = nil } }),
            presenting: model.busyLock
        ) { info in
            Button("Force Lock", role: .destructive) {
                Task { await model.lock(info.vaultIDs, force: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { info in
            if info.lines.isEmpty {
                Text("FolderSafe couldn’t lock it: \(info.errorMessage ?? "")\n\nClose files from this vault in other apps and try again, or force lock now. Unsaved changes in those apps may be lost.")
            } else {
                Text("These apps have files open:\n\(info.lines.joined(separator: "\n"))\n\nSave your work in them first, or force lock now. Unsaved changes in those apps may be lost.")
            }
        }
    }
}
