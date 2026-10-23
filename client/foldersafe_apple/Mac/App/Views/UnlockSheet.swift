import SwiftUI
import AppKit

/// 解锁：密码 / Touch ID（开着就自动弹）/ 找回短语（可顺便设新密码）。
struct UnlockSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let id: String

    @State var usePhrase = false
    @State var password = ""
    @State var phrase = ""
    @State var setNewPassword = true
    @State var newPassword = ""
    @State var confirm = ""
    @State var error: String?
    @State private var needsFileProviderSetup = false
    @State private var working = false
    @State private var autoPrompted = false
    @FocusState private var focused: Bool

    init(id: String, demoPassword: String = "") {
        self.id = id
        _password = State(initialValue: demoPassword)
    }

    var body: some View {
        if let r = model.record(id) {
            VStack(alignment: .leading, spacing: 18) {
                SheetHeader(title: usePhrase ? "Unlock with Recovery Phrase" : "Unlock “\(r.name)”",
                            subtitle: Text(usePhrase ? LocalizedStringKey("Enter the 12-word recovery phrase for “\(r.name)”.")
                                                     : LocalizedStringKey("Enter the vault’s password.")),
                            unlockedGlyph: false)
                if usePhrase { phraseForm } else { passwordForm(r) }
                if needsFileProviderSetup {
                    FileProviderSetupBox {
                        Task {
                            if !usePhrase && password.isEmpty && model.touchIDEnabled.contains(id) { await unlockWithTouchID(r) }
                            else { await submit() }
                        }
                    }
                } else {
                    ErrorLine(message: error)
                }
                Text("While unlocked, apps on this Mac can read the files in this vault.")
                    .font(.caption).foregroundStyle(.secondary)
                footer(r)
            }
            .padding(24)
            .frame(width: 480)
            .animation(.easeOut(duration: 0.15), value: usePhrase)
            .onAppear {
                focused = true
                if model.touchIDEnabled.contains(id) && !autoPrompted && !model.isDemo {
                    autoPrompted = true
                    Task { try? await Task.sleep(nanoseconds: 350_000_000); await unlockWithTouchID(r) }
                }
            }
        }
    }

    @ViewBuilder
    private func passwordForm(_ r: VaultRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .focused($focused)
                .onSubmit { Task { await submit() } }
            HStack {
                if model.touchIDEnabled.contains(id) {
                    Button {
                        Task { await unlockWithTouchID(r) }
                    } label: {
                        Label("Use \(model.biometryName)", systemImage: "touchid")
                    }
                    .disabled(working)
                }
                Spacer()
                Button("Forgot password? Use recovery phrase") {
                    error = nil
                    usePhrase = true
                }
                .buttonStyle(.link)
                .font(.callout)
            }
        }
    }

    private var phraseForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            PhraseInput(text: $phrase)
            Toggle("Also set a new password", isOn: $setNewPassword)
            if setNewPassword {
                NewPasswordFields(password: $newPassword, confirm: $confirm,
                                  newLabel: "New password", confirmLabel: "Confirm new password")
                    .frame(width: 340)
                    .padding(.leading, 20)
            }
        }
    }

    private func footer(_ r: VaultRecord) -> some View {
        HStack {
            if usePhrase {
                Button("Back") { error = nil; usePhrase = false }.disabled(working)
            }
            Spacer()
            if working { WorkingLabel(title: "Unlocking…") }
            Button("Cancel") { close() }
                .keyboardShortcut(.cancelAction)
                .disabled(working)
            Button("Unlock") { Task { await submit() } }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit || working)
        }
    }

    private var canSubmit: Bool {
        if usePhrase {
            return !phrase.trimmingCharacters(in: .whitespaces).isEmpty
                && (!setNewPassword || NewPasswordFields.isValid(newPassword, confirm))
        }
        return !password.isEmpty
    }

    private func submit() async {
        guard canSubmit, !working else { return }
        error = nil
        needsFileProviderSetup = false
        working = true
        defer { working = false }
        do {
            if usePhrase {
                try await model.unlockWithPhrase(id, phrase: phrase, newPassword: setNewPassword ? newPassword : nil)
            } else {
                try await model.unlock(id, .password(password))
            }
            close()
        } catch FileProviderPresenter.Failure.disabledByUser {
            needsFileProviderSetup = true          // 密码保留，打开开关后直接"再试一次"
        } catch {
            self.error = ErrorText.describe(error)
            if !usePhrase { password = "" }
        }
    }

    private func unlockWithTouchID(_ r: VaultRecord) async {
        guard !working else { return }
        error = nil
        working = true
        defer { working = false }
        do {
            try await model.unlock(id, .biometrics(reason: model.unlockReason(r)))
            close()
        } catch FileProviderPresenter.Failure.disabledByUser {
            needsFileProviderSetup = true
        } catch {
            self.error = ErrorText.describe(error)
            model.refreshTouchID()
            focused = true
        }
    }

    private func close() {
        password = ""; phrase = ""; newPassword = ""; confirm = ""
        dismiss()
    }
}

/// macOS 上 File Provider 需要用户在系统设置里打开一次（"文件提供程序"里的 FolderSafe）。
struct FileProviderSetupBox: View {
    let tryAgain: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text("Turn on FolderSafe in Finder")
                    .font(.headline)
            } icon: {
                Image(systemName: "puzzlepiece.extension.fill").foregroundStyle(.orange)
            }
            Text("macOS asks you to allow FolderSafe once before unlocked vaults can appear in Finder. Go to **General › Login Items & Extensions › File Providers** and turn on **FolderSafe**, then click Try Again.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text("System Settings › General › Login Items & Extensions › File Providers › FolderSafe")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack {
                Button("Open System Settings") { FileProviderPresenter.openExtensionSettings() }
                Button("Try Again", action: tryAgain)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.orange.opacity(0.25)))
    }
}
