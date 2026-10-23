import SwiftUI
import AppKit
import FolderSafeCore

struct SheetRouter: View {
    @EnvironmentObject var model: AppModel
    let sheet: AppModel.Sheet

    var body: some View {
        switch sheet {
        case .create: CreateVaultWizard()
        case .unlock(let id): UnlockSheet(id: id)
        case .changePassword(let id): ChangePasswordSheet(id: id)
        case .newPhrase(let id): NewPhraseSheet(id: id)
        case .resetPassword(let id): ResetPasswordSheet(id: id)
        case .enableTouchID(let id): EnableTouchIDSheet(id: id)
        case .fskitSetup: FSKitSetupSheet()
        case .feedback:
            EmptyView()
        }
    }
}

/// 弹窗底部：取消 + 主按钮 + 进行中提示。
struct SheetFooter: View {
    let primary: LocalizedStringKey
    var working = false
    var workingTitle: LocalizedStringKey = "Working…"
    var enabled = true
    var showCancel = true
    let cancel: () -> Void
    let action: () -> Void

    var body: some View {
        HStack {
            Spacer()
            if working { WorkingLabel(title: workingTitle) }
            if showCancel {
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction).disabled(working)
            }
            Button(primary, action: action)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!enabled || working)
        }
    }
}

// MARK: - 改密码

struct ChangePasswordSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let id: String
    @State private var current = ""
    @State private var new = ""
    @State private var confirm = ""
    @State private var working = false
    @State private var error: String?
    @State private var done = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetHeader(title: "Change Password",
                        subtitle: Text("For “\(model.record(id)?.name ?? "")”. Your recovery phrase and Touch ID keep working."),
                        systemImage: "key.fill")
            if done {
                Callout(.success, Text("The password has been changed. Use the new password from now on."))
            } else {
                SecureField("Current password", text: $current).textFieldStyle(.roundedBorder).frame(width: 340)
                NewPasswordFields(password: $new, confirm: $confirm, newLabel: "New password", confirmLabel: "Confirm new password")
                    .frame(width: 340)
                Text("Other devices that open this vault will need the new password too.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ErrorLine(message: error)
            if done {
                HStack { Spacer(); Button("Done") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
            } else {
                SheetFooter(primary: "Change Password", working: working,
                            enabled: !current.isEmpty && NewPasswordFields.isValid(new, confirm),
                            cancel: { dismiss() }) { Task { await submit() } }
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func submit() async {
        error = nil
        working = true
        defer { working = false }
        do {
            try await model.changePassword(id, current: current, new: new)
            current = ""; new = ""; confirm = ""
            done = true
        } catch {
            self.error = ErrorText.describe(error)
        }
    }
}

// MARK: - 重新生成找回短语（先验证密码）

struct NewPhraseSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let id: String
    @State private var stage = 0           // 0 输密码，1 显示，2 抽查
    @State private var password = ""
    @State private var words: [String] = []
    @State private var wrote = false
    @State private var quiz: [Int] = []
    @State private var answers = ["", "", ""]
    @State private var working = false
    @State private var error: String?

    var body: some View {
        let name = model.record(id)?.name ?? ""
        VStack(alignment: .leading, spacing: 18) {
            switch stage {
            case 0:
                SheetHeader(title: "Create a New Recovery Phrase",
                            subtitle: Text("Enter the password for “\(name)” to continue."),
                            systemImage: "list.number")
                Callout(.warning, Text("Your current recovery phrase will stop working immediately. Do this if your phrase was lost or someone else may have seen it."))
                SecureField("Password", text: $password).textFieldStyle(.roundedBorder).frame(width: 340)
                    .onSubmit { Task { await generate() } }
                ErrorLine(message: error)
                SheetFooter(primary: "Create New Phrase", working: working, enabled: !password.isEmpty,
                            cancel: { close() }) { Task { await generate() } }
            case 1:
                SheetHeader(title: "Write Down Your New Recovery Phrase",
                            subtitle: Text("The old phrase no longer works. Write these 12 words on paper, in order, and keep them somewhere safe."),
                            systemImage: "list.number")
                PhraseGrid(words: words)
                HStack {
                    Toggle("I’ve written down all 12 words", isOn: $wrote)
                    Spacer()
                    Button("Save as Text…") { PhraseExport.saveAsText(words: words, vaultName: name) }.controlSize(.small)
                }
                SheetFooter(primary: "Continue", enabled: wrote, showCancel: false, cancel: {}) {
                    quiz = PhraseQuiz.pick(); answers = ["", "", ""]; stage = 2
                }
            default:
                SheetHeader(title: "Check Your Recovery Phrase",
                            subtitle: Text("Enter these words from your written copy."),
                            systemImage: "checklist")
                PhraseQuiz(words: words, indices: quiz, answers: $answers)
                HStack {
                    Button("Back") { stage = 1 }
                    Spacer()
                    Button("Done") { close() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!PhraseQuiz(words: words, indices: quiz, answers: $answers).allCorrect)
                }
            }
        }
        .padding(24)
        .frame(width: 580)
        .interactiveDismissDisabled(stage > 0)
    }

    private func generate() async {
        guard !password.isEmpty, !working else { return }
        error = nil
        working = true
        defer { working = false }
        do {
            let phrase = try await model.regeneratePhrase(id, password: password)
            password = ""
            words = phrase.words
            stage = 1
        } catch {
            self.error = ErrorText.describe(error)
        }
    }

    private func close() {
        password = ""; words = []
        dismiss()
    }
}

// MARK: - 用找回短语重设密码

struct ResetPasswordSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let id: String
    @State private var phrase = ""
    @State private var new = ""
    @State private var confirm = ""
    @State private var working = false
    @State private var error: String?
    @State private var done = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: "Reset Password",
                        subtitle: Text("Forgot the password for “\(model.record(id)?.name ?? "")”? Enter its recovery phrase and choose a new password."),
                        systemImage: "key.viewfinder")
            if done {
                Callout(.success, Text("The password has been reset. Use the new password from now on. Your recovery phrase stays the same."))
                HStack { Spacer(); Button("Done") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
            } else {
                PhraseInput(text: $phrase)
                NewPasswordFields(password: $new, confirm: $confirm, newLabel: "New password", confirmLabel: "Confirm new password")
                    .frame(width: 340)
                ErrorLine(message: error)
                SheetFooter(primary: "Reset Password", working: working,
                            enabled: !phrase.isEmpty && NewPasswordFields.isValid(new, confirm),
                            cancel: { dismiss() }) { Task { await submit() } }
            }
        }
        .padding(24)
        .frame(width: 500)
    }

    private func submit() async {
        error = nil
        working = true
        defer { working = false }
        do {
            try await model.resetPassword(id, phrase: phrase, new: new)
            phrase = ""; new = ""; confirm = ""
            done = true
        } catch {
            self.error = ErrorText.describe(error)
        }
    }
}

// MARK: - 打开 Touch ID

struct EnableTouchIDSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let id: String
    @State private var password = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetHeader(title: "Turn On \(model.biometryName)",
                        subtitle: Text("Enter the password for “\(model.record(id)?.name ?? "")”."),
                        systemImage: "touchid")
            SecureField("Password", text: $password).textFieldStyle(.roundedBorder).frame(width: 340)
                .onSubmit { Task { await submit() } }
            Text("FolderSafe keeps the vault’s key in this Mac’s keychain, protected by \(model.biometryName). It works only on this Mac and turns off automatically if the enrolled fingerprints change. Your password still works.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ErrorLine(message: error)
            SheetFooter(primary: "Turn On", working: working, enabled: !password.isEmpty,
                        cancel: { dismiss() }) { Task { await submit() } }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func submit() async {
        guard !password.isEmpty, !working else { return }
        error = nil
        working = true
        defer { working = false }
        do {
            try await model.enableTouchID(id, password: password)
            password = ""
            dismiss()
        } catch {
            self.error = ErrorText.describe(error)
        }
    }
}

// MARK: - FSKit 引导（直装版，macOS 26+，用户在设置里选了"挂成真正的文件夹"）

struct FSKitSetupSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var checked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetHeader(title: "Turn On the FolderSafe File System",
                        subtitle: Text("To open unlocked vaults as real folders, FolderSafe uses a macOS file system extension. macOS asks you to turn it on once."),
                        systemImage: "puzzlepiece.extension.fill")
            FSKitSetupSteps()
            HStack {
                Button("Open System Settings") { FSKitSetupSteps.openSettings() }
                Spacer()
                if model.fskitStatus == .enabled {
                    Button("Done") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                } else {
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Check Again") { Task { await model.refreshFSKit() } }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.fskitStatus == .checking)
                }
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

/// 步骤说明 + 状态（弹窗和设置页共用）。
struct FSKitSetupSteps: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                stepRow(1, Text("Click **Open System Settings**."))
                stepRow(2, Text("Go to **General › Login Items & Extensions**, then **File System Extensions**."))
                stepRow(3, Text("Turn on **FolderSafe**, then come back and click **Check Again**."))
            }
            Text("System Settings › General › Login Items & Extensions › File System Extensions › FolderSafe")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            switch model.fskitStatus {
            case .enabled:
                Callout(.success, Text("The extension is on. Vaults now open as real folders."))
            case .checking:
                WorkingLabel(title: "Checking…")
            case .notInstalled:
                Callout(.warning, Text("macOS hasn’t registered the FolderSafe extension yet. Make sure FolderSafe is in your Applications folder, open it once, then check again."))
            default:
                Callout(.warning, Text("The extension is off. Until it’s on, unlocked vaults appear in Finder’s sidebar instead."))
            }
        }
    }

    private func stepRow(_ n: Int, _ text: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(.callout.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.fsAccent))
            text.fixedSize(horizontal: false, vertical: true)
        }
    }

    static func openSettings() {
        #if !APPSTORE
        FSKitPresenter.openExtensionSettings()
        #endif
    }
}
