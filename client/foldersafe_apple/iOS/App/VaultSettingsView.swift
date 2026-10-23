import SwiftUI
import FolderSafeCore

/// 单个 vault 的设置：Face ID、改密码、新找回短语、用短语重设密码、从列表移除。
struct VaultSettingsView: View {
    enum Sheet: Int, Identifiable {
        case enableBiometrics, changePassword, newPhrase, resetPassword
        var id: Int { rawValue }
    }

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let vaultId: String

    @State private var sheet: Sheet?
    @State private var confirmForget = false
    @State private var done: String?

    var body: some View {
        if let r = model.record(id: vaultId) {
            List {
                Section {
                    Toggle(isOn: Binding(get: { model.biometricsEnabled(r) }, set: { on in
                        if on { sheet = .enableBiometrics } else { model.disableBiometrics(r) }
                    })) {
                        Label("Unlock with \(model.biometryName)", systemImage: model.biometrySymbol)
                    }
                    .disabled(!model.biometryAvailable && !model.biometricsEnabled(r))
                } footer: {
                    if model.biometryAvailable {
                        Text("The vault key is kept in this iPhone's Keychain and released only after \(model.biometryName). It isn't synced to other devices.")
                    } else {
                        Text("Set up Face ID and a passcode in the Settings app to use this.")
                    }
                }

                Section {
                    Button { sheet = .changePassword } label: {
                        Label("Change Password", systemImage: "key")
                    }
                    Button { sheet = .newPhrase } label: {
                        Label("Create New Recovery Phrase", systemImage: "list.number")
                    }
                    Button { sheet = .resetPassword } label: {
                        Label("Forgot Password? Reset with Recovery Phrase", systemImage: "arrow.counterclockwise")
                    }
                } header: {
                    Text("Password & Recovery")
                }

                Section {
                    LabeledContent("Name", value: r.name)
                    LabeledContent("Location") {
                        Text(VaultLocation.hint(forPath: r.path, includeLast: true))
                            .multilineTextAlignment(.trailing)
                    }
                    if let opened = r.lastOpened {
                        LabeledContent("Last Unlocked", value: opened.formatted(date: .abbreviated, time: .shortened))
                    }
                } header: {
                    Text("Vault")
                }

                Section {
                    Button(role: .destructive) { confirmForget = true } label: {
                        Label("Remove from FolderSafe", systemImage: "minus.circle")
                    }
                } footer: {
                    Text("Removes the vault from this list only. The vault folder and its encrypted files stay where they are, and you can add it again later.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Vault Settings")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $sheet) { s in
                switch s {
                case .enableBiometrics: EnableBiometricsSheet(record: r)
                case .changePassword: ChangePasswordSheet(record: r) { done = String(localized: "Password changed.") }
                case .newPhrase: NewPhraseSheet(record: r)
                case .resetPassword: ResetPasswordSheet(record: r) { done = String(localized: "Password changed.") }
                }
            }
            .confirmationDialog("Remove “\(r.name)” from FolderSafe?", isPresented: $confirmForget, titleVisibility: .visible) {
                Button("Remove from List", role: .destructive) {
                    Task {
                        await model.forget(r)
                        model.path = []
                    }
                }
            } message: {
                Text("No files are deleted. To use the vault again, add it with “Add Existing Vault”.")
            }
            .alert(done ?? "", isPresented: Binding(get: { done != nil }, set: { if !$0 { done = nil } })) {
                Button("OK", role: .cancel) {}
            }
        } else {
            ContentUnavailableView("Vault not found", systemImage: "questionmark.folder")
        }
    }
}

// MARK: - 打开 Face ID（要密码）

struct EnableBiometricsSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let record: VaultRecord
    @State private var password = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Vault Password", text: $password)
                        .textContentType(.password)
                        .onSubmit { Task { await submit() } }
                } footer: {
                    Text("Enter the vault's password once to turn on \(model.biometryName) for “\(record.name)” on this iPhone.")
                }
            }
            .navigationTitle(Text("Turn On \(model.biometryName)"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if working { ProgressView() } else {
                        Button("Turn On") { Task { await submit() } }.disabled(password.isEmpty)
                    }
                }
            }
            .errorAlert($error)
        }
        .presentationDetents([.medium])
    }

    private func submit() async {
        guard !password.isEmpty, !working else { return }
        working = true
        defer { working = false }
        await Task.yield()
        do {
            try await model.enableBiometrics(record, password: password)
            dismiss()
        } catch {
            if !ErrorText.isCancellation(error) { self.error = ErrorText.message(for: error) }
        }
    }
}

// MARK: - 改密码

struct ChangePasswordSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let record: VaultRecord
    var onDone: () -> Void
    @State private var current = ""
    @State private var new = ""
    @State private var confirm = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Current Password", text: $current)
                        .textContentType(.password)
                }
                Section {
                    NewPasswordFields(password: $new, confirm: $confirm, newLabel: "New Password")
                } footer: {
                    Text("Your recovery phrase and Face ID keep working. Other devices that use this vault will need the new password.")
                }
            }
            .navigationTitle("Change Password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if working { ProgressView() } else {
                        Button("Change") { Task { await submit() } }
                            .disabled(current.isEmpty || !NewPasswordFields.isValid(new, confirm))
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
            try await model.changePassword(record, current: current, new: new)
            dismiss()
            onDone()
        } catch {
            self.error = ErrorText.message(for: error)
        }
    }
}

// MARK: - 新找回短语（先验证密码）

struct NewPhraseSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let record: VaultRecord
    @State private var password = ""
    @State private var words: [String] = []
    @State private var wroteDown = false
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                if words.isEmpty {
                    Section {
                        SecureField("Vault Password", text: $password)
                            .textContentType(.password)
                    } footer: {
                        Text("A new 12-word phrase replaces the old one. The old phrase stops working immediately.")
                    }
                } else {
                    Section {
                        PhraseGrid(words: words)
                    } header: {
                        Text("Your New Recovery Phrase")
                    }
                    Section {
                        Notice(text: "Write these 12 words on paper, in order, and keep them somewhere safe. Your old phrase no longer works.")
                        Toggle("I've written down all 12 words", isOn: $wroteDown)
                    }
                }
            }
            .navigationTitle("New Recovery Phrase")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if words.isEmpty {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        if working { ProgressView() } else {
                            Button("Create") { Task { await submit() } }.disabled(password.isEmpty)
                        }
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { words = []; password = ""; dismiss() }.disabled(!wroteDown)
                    }
                }
            }
            .errorAlert($error)
        }
        .interactiveDismissDisabled(!words.isEmpty)
    }

    private func submit() async {
        working = true
        defer { working = false }
        await Task.yield()
        do {
            words = try await model.regeneratePhrase(record, password: password).words
            password = ""
        } catch {
            self.error = ErrorText.message(for: error)
        }
    }
}

// MARK: - 用找回短语重设密码

struct ResetPasswordSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let record: VaultRecord
    var onDone: () -> Void
    @State private var phrase = ""
    @State private var new = ""
    @State private var confirm = ""
    @State private var working = false
    @State private var error: String?

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
                    NewPasswordFields(password: $new, confirm: $confirm, newLabel: "New Password")
                } footer: {
                    Text("Your old password will stop working. The recovery phrase stays the same.")
                }
            }
            .navigationTitle("Reset Password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if working { ProgressView() } else {
                        Button("Reset") { Task { await submit() } }
                            .disabled(phrase.split(whereSeparator: \.isWhitespace).count != 12 || !NewPasswordFields.isValid(new, confirm))
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
            try await model.resetPassword(record, phrase: phrase, new: new)
            dismiss()
            onDone()
        } catch {
            self.error = ErrorText.message(for: error)
        }
    }
}
