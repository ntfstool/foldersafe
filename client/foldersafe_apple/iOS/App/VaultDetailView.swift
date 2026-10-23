import SwiftUI

/// 一个 vault 的主页面：上锁时是解锁界面，解锁后是"在文件 App 里打开"和大的上锁按钮。
struct VaultDetailView: View {
    @EnvironmentObject private var model: AppModel
    let vaultId: String

    var body: some View {
        if let r = model.record(id: vaultId) {
            Group {
                if model.isUnlocked(r) {
                    UnlockedVaultView(record: r)
                } else {
                    UnlockVaultView(record: r)
                }
            }
            .navigationTitle(r.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        VaultSettingsView(vaultId: r.id)
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel(Text("Vault Settings"))
                }
            }
            .animation(.default, value: model.isUnlocked(r))
        } else {
            ContentUnavailableView("Vault not found", systemImage: "questionmark.folder")
        }
    }
}

/// 页面顶部：大图标 + 名字 + 位置。
struct VaultHeader: View {
    var record: VaultRecord
    var unlocked: Bool

    var body: some View {
        VStack(spacing: 10) {
            VaultIcon(unlocked: unlocked, size: 76)
            Text(record.name)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text(record.locationHint)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            StatusBadge(unlocked: unlocked)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

// MARK: - 解锁

struct UnlockVaultView: View {
    @EnvironmentObject private var model: AppModel
    let record: VaultRecord

    @State private var password = ""
    @State private var working = false
    @State private var error: String?
    @State private var showRecovery = false
    @State private var autoPrompted = false
    @FocusState private var passwordFocused: Bool

    var body: some View {
        List {
            Section {
                VaultHeader(record: record, unlocked: false)
            }
            .listRowBackground(Color.clear)

            if model.biometricsEnabled(record) {
                Section {
                    Button {
                        Task { await unlockWithBiometrics() }
                    } label: {
                        Label("Unlock with \(model.biometryName)", systemImage: model.biometrySymbol)
                    }
                    .buttonStyle(WideButtonStyle())
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .disabled(working)
                }
            }

            Section {
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .focused($passwordFocused)
                    .submitLabel(.go)
                    .onSubmit { Task { await unlockWithPassword() } }
                Button {
                    Task { await unlockWithPassword() }
                } label: {
                    HStack {
                        Text("Unlock with Password")
                        Spacer()
                        if working { ProgressView() }
                    }
                }
                .disabled(password.isEmpty || working)
            } footer: {
                Button("Forgot your password? Use your recovery phrase") { showRecovery = true }
                    .font(.footnote)
                    .padding(.top, 6)
            }

            Section {
                Notice(systemImage: "info.circle.fill", tint: .brand,
                       text: "After you unlock, the vault appears in the Files app so you and other apps can open its files. Lock it again when you're done.")
            }
        }
        .listStyle(.insetGrouped)
        .errorAlert($error)
        .sheet(isPresented: $showRecovery) {
            RecoveryUnlockView(record: record)
        }
        .task {
            // 开了 Face ID 就自动弹一次
            guard !autoPrompted, model.snapshot == nil, model.biometricsEnabled(record) else { return }
            autoPrompted = true
            try? await Task.sleep(nanoseconds: 350_000_000)
            await unlockWithBiometrics()
        }
    }

    private func unlockWithBiometrics() async {
        await run(.biometrics(reason: String(localized: "Unlock “\(record.name)”")))
    }

    private func unlockWithPassword() async {
        guard !password.isEmpty else { return }
        await run(.password(password))
    }

    private func run(_ secret: VaultService.Secret) async {
        guard !working else { return }
        working = true
        defer { working = false }
        await Task.yield()
        do {
            try await model.unlock(record, with: secret)
            password = ""
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            if ErrorText.isCancellation(error) { passwordFocused = true; return }
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            self.error = ErrorText.message(for: error)
        }
    }
}

/// 用找回短语解锁，可顺便设新密码。
struct RecoveryUnlockView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let record: VaultRecord

    @State private var phrase = ""
    @State private var setNew = true
    @State private var newPassword = ""
    @State private var confirm = ""
    @State private var working = false
    @State private var error: String?

    private var canSubmit: Bool {
        phrase.split(whereSeparator: \.isWhitespace).count == 12 && (!setNew || NewPasswordFields.isValid(newPassword, confirm))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PhraseEditor(text: $phrase)
                } header: {
                    Text("Recovery Phrase")
                } footer: {
                    Text("Enter the 12 words in order, separated by spaces.")
                }

                Section {
                    Toggle("Set a New Password", isOn: $setNew)
                    if setNew {
                        NewPasswordFields(password: $newPassword, confirm: $confirm, newLabel: "New Password")
                    }
                } footer: {
                    Text(setNew ? "Your old password will stop working. The recovery phrase stays the same." : "The vault unlocks this time only. Your password doesn't change.")
                }
            }
            .navigationTitle("Use Recovery Phrase")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if working { ProgressView() } else {
                        Button("Unlock") { Task { await submit() } }.disabled(!canSubmit)
                    }
                }
            }
            .errorAlert($error)
        }
    }

    private func submit() async {
        working = true
        defer { working = false }
        await Task.yield()
        do {
            try await model.unlockWithRecovery(record, phrase: phrase, newPassword: setNew ? newPassword : nil)
            dismiss()
        } catch AppError.filesLocationDisabled {
            dismiss()
        } catch {
            self.error = ErrorText.message(for: error)
        }
    }
}

/// 输入 12 个词的多行框（不自动大写、不纠错）。
struct PhraseEditor: View {
    @Binding var text: String

    var body: some View {
        TextField("word1 word2 word3 …", text: $text, axis: .vertical)
            .lineLimit(3...6)
            .font(.body.monospaced())
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.asciiCapable)
    }
}

// MARK: - 已解锁

struct UnlockedVaultView: View {
    @EnvironmentObject private var model: AppModel
    let record: VaultRecord
    @State private var locking = false

    var body: some View {
        List {
            Section {
                VaultHeader(record: record, unlocked: true)
            }
            .listRowBackground(Color.clear)

            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Open it in the Files app", systemImage: "folder.fill")
                        .font(.headline)
                    Text("In Files, tap Browse, then find “\(record.name)” under Locations. You can open, edit and save files there, and other apps can use them too.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        FilesApp.open(model.filesURL(record))
                    } label: {
                        Label("Open Files App", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(WideButtonStyle(prominent: false))
                    .padding(.top, 2)
                }
                .padding(.vertical, 8)
            }

            Section {
                Button {
                    Task {
                        locking = true
                        await model.userLock(record)
                        locking = false
                    }
                } label: {
                    HStack {
                        if locking { ProgressView().tint(.white) } else { Image(systemName: "lock.fill") }
                        Text("Lock")
                    }
                }
                .buttonStyle(WideButtonStyle())
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .disabled(locking)
            } footer: {
                autoLockFooter
                    .padding(.top, 8)
            }

            Section {
                Notice(text: "While a vault is unlocked, apps on this iPhone that can use the Files app can read its files. Lock it when you're done.")
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder private var autoLockFooter: some View {
        if model.lockDeadline(record) != nil {
            Text("Locks automatically \(model.autoLockMinutes) minutes after you unlock it or leave FolderSafe.")
        } else {
            Text("Auto-lock is off. This vault stays unlocked until you lock it.")
        }
    }
}
