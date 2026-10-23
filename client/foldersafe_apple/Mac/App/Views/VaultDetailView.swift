import SwiftUI
import AppKit

/// 右侧详情：状态、主操作、解锁方式、位置、移除。
struct VaultDetailView: View {
    @EnvironmentObject var model: AppModel
    let id: String
    @State private var confirmForget = false
    @State private var editedName = ""
    @State private var renaming = false

    var body: some View {
        if let r = model.record(id) {
            let unlocked = model.isUnlocked(id)
            let working = model.inProgress.contains(id)
            Form {
                Section {
                    header(r, unlocked: unlocked, working: working)
                    statusNote(r, unlocked: unlocked)
                }

                Section {
                    touchIDRow
                    LabeledContent {
                        Button("Change…") { model.sheet = .changePassword(id) }
                    } label: {
                        Label { VStack(alignment: .leading, spacing: 2) {
                            Text("Password")
                            Text("Needed to unlock, and to change other settings.").font(.caption).foregroundStyle(.secondary)
                        } } icon: { Image(systemName: "key.fill") }
                    }
                    LabeledContent {
                        HStack {
                            Button("Reset Password…") { model.sheet = .resetPassword(id) }
                            Button("New Phrase…") { model.sheet = .newPhrase(id) }
                        }
                    } label: {
                        Label { VStack(alignment: .leading, spacing: 2) {
                            Text("Recovery phrase")
                            Text("12 words that unlock the vault if you forget the password.").font(.caption).foregroundStyle(.secondary)
                        } } icon: { Image(systemName: "list.number") }
                    }
                } header: {
                    Text("Unlocking")
                }

                Section {
                    LabeledContent("Name") {
                        HStack(spacing: 8) {
                            Text(r.name).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Button("Rename…") { editedName = r.name; renaming = true }.disabled(unlocked)
                        }
                    }
                    LabeledContent {
                        HStack(spacing: 8) {
                            Text(LocationText.display(r.path))
                                .lineLimit(1).truncationMode(.middle)
                                .foregroundStyle(.secondary)
                                .help(r.path)
                            Button {
                                model.revealEncryptedFolder(id)
                            } label: {
                                Image(systemName: "arrow.right.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .help(Text("Show the encrypted folder in Finder"))
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Encrypted folder")
                            Text("Only encrypted data. Back it up or sync it like any folder.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if model.choice == .fskit || model.wantsFSKit {
                        LabeledContent {
                            HStack(spacing: 8) {
                                Text(mountPointText(r))
                                    .lineLimit(1).truncationMode(.middle)
                                    .foregroundStyle(.secondary)
                                Menu {
                                    Button("Choose Folder…") { chooseMountPoint(r) }
                                    Button("Use Default (~/FolderSafe)") { model.setMountPoint(id, nil) }
                                } label: {
                                    Text("Change")
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                                .disabled(unlocked)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Opens at")
                                Text("Where the unlocked files appear.").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Location")
                } footer: {
                    // 截图（演示模式）里不出现 Cryptomator 名字（App Store 截图规则）
                    if !model.isDemo {
                        Text("Open format, compatible with Cryptomator vault format 8.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section {
                    LabeledContent {
                        Button("Remove…", role: .destructive) { confirmForget = true }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Remove from FolderSafe")
                            Text("Takes the vault off this list. The encrypted folder and your files are not deleted.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(working)
            .navigationTitle(r.name)
            .alert(Text("Rename Vault"), isPresented: $renaming) {
                TextField("Name", text: $editedName)
                Button("Rename") { model.rename(id, to: editedName) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This only changes the name shown in FolderSafe. The encrypted folder isn’t renamed.")
            }
            .confirmationDialog(Text("Remove “\(r.name)” from FolderSafe?"), isPresented: $confirmForget) {
                Button("Remove", role: .destructive) { Task { await model.forget(id) } }
            } message: {
                Text("The vault will be locked and removed from this list. Its encrypted folder stays where it is, so you can add it again later. Touch ID for this vault will be turned off.")
            }
        }
    }

    // MARK: 头部

    @ViewBuilder
    private func header(_ r: VaultRecord, unlocked: Bool, working: Bool) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VaultGlyph(unlocked: unlocked, size: 56)
            VStack(alignment: .leading, spacing: 6) {
                Text(r.name).font(.title2.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 8) {
                    StatusBadge(unlocked: unlocked)
                    if model.touchIDEnabled.contains(id) {
                        Label("Touch ID", systemImage: "touchid")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                    }
                }
            }
            Spacer(minLength: 12)
            if working {
                ProgressView().controlSize(.small)
            } else if unlocked {
                Button {
                    model.reveal(id)
                } label: {
                    Label("Open in Finder", systemImage: "folder")
                }
                .controlSize(.large)
                Button {
                    model.requestLock(id)
                } label: {
                    Label("Lock", systemImage: "lock.fill").frame(minWidth: 60)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    model.beginUnlock(id)
                } label: {
                    Label("Unlock…", systemImage: "lock.open.fill").frame(minWidth: 80)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func statusNote(_ r: VaultRecord, unlocked: Bool) -> some View {
        if unlocked {
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text("While unlocked, apps on this Mac — including AI tools — can read and change these files. Lock the vault when you’re done.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                if let url = model.unlocked[id], url.isFileURL {
                    Text("Open at \(url.path.abbreviatingHome)")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        .padding(.leading, 26)
                }
            }
            .font(.callout)
        } else {
            Label {
                Text("Encrypted on disk. Nothing on this Mac can read these files until you unlock the vault — not AI agents, not other apps, not admin (root) processes.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "checkmark.shield.fill").foregroundStyle(.green)
            }
            .font(.callout)
        }
    }

    // MARK: Touch ID

    @ViewBuilder
    private var touchIDRow: some View {
        let on = model.touchIDEnabled.contains(id)
        LabeledContent {
            Toggle("", isOn: Binding(get: { on }, set: { new in
                if new { model.sheet = .enableTouchID(id) } else { model.disableTouchID(id) }
            }))
            .toggleStyle(.switch)
            .labelsHidden()
            .disabled(!model.biometryAvailable && !on)
        } label: {
            Label { VStack(alignment: .leading, spacing: 2) {
                Text("Unlock with \(model.biometryName)")
                Text(model.biometryAvailable
                     ? LocalizedStringKey("The key is kept in this Mac’s keychain and works only on this Mac.")
                     : LocalizedStringKey("Touch ID isn’t available on this Mac."))
                    .font(.caption).foregroundStyle(.secondary)
            } } icon: { Image(systemName: "touchid") }
        }
    }

    private func mountPointText(_ r: VaultRecord) -> String {
        #if APPSTORE
        return ""
        #else
        return FSKitPresenter.mountPoint(for: r).abbreviatingHome
        #endif
    }

    private func chooseMountPoint(_ r: VaultRecord) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Use This Folder")
        panel.message = String(localized: "Choose an empty folder where “\(r.name)” appears when unlocked.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let items = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        if !items.allSatisfy({ $0 == ".DS_Store" }) {
            model.notice = .init(title: String(localized: "Choose an empty folder"),
                                 message: String(localized: "Files in that folder would be hidden while the vault is unlocked."))
            return
        }
        model.setMountPoint(id, url.path)
    }
}
