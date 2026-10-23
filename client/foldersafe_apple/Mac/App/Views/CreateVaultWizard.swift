import SwiftUI
import AppKit
import FolderSafeCore

/// 新建向导：名字和位置 → 密码 → （建库）→ 抄写找回短语 → 抽查 3 个词 → 完成（可开 Touch ID / 立即解锁）。
/// 找回短语由内核在建库时生成，所以建库发生在密码之后；之后放弃会把这个还没放文件的新 vault 移到废纸篓。
struct CreateVaultWizard: View {
    enum Step: Int, CaseIterable { case location, password, phrase, quiz, done }

    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State var step: Step = .location
    @State var name = String(localized: "My Vault")
    @State var parent: URL? = CreateVaultWizard.defaultParent
    @State var password = ""
    @State var confirm = ""
    @State var words: [String] = []
    @State var wroteDown = false
    @State var quizIndices: [Int] = []
    @State var answers = ["", "", ""]
    @State var created: VaultRecord?
    @State private var working = false
    @State private var error: String?
    @State private var confirmDiscard = false
    @State private var touchIDOn = false

    init() {}

    /// 截图用：直接停在找回短语页，显示演示短语（不是任何真实 vault 的）。
    init(demoName: String, demoParent: URL, demoWords: [String]) {
        _step = State(initialValue: .phrase)
        _name = State(initialValue: demoName)
        _parent = State(initialValue: demoParent)
        _words = State(initialValue: demoWords)
        _created = State(initialValue: VaultRecord(id: "demo", name: demoName, path: demoParent.appendingPathComponent(demoName).path))
    }

    static var defaultParent: URL? {
        #if APPSTORE
        return nil                                  // 沙盒里必须让用户亲自选位置
        #else
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        #endif
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var target: URL? { parent?.appendingPathComponent(trimmedName, isDirectory: true) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepIndicator(current: step)
                .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 18)
            Divider()
            ScrollView {
                Group {
                    switch step {
                    case .location: locationStep
                    case .password: passwordStep
                    case .phrase: phraseStep
                    case .quiz: quizStep
                    case .done: doneStep
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(28)
            }
            Divider()
            footer.padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(width: 620, height: 600)
        .interactiveDismissDisabled(created != nil)
        .alert(Text("Discard the new vault?"), isPresented: $confirmDiscard) {
            Button("Discard Vault", role: .destructive) {
                if let created { Task { await model.discardNewVault(created); close() } }
            }
            Button("Continue Setup", role: .cancel) {}
        } message: {
            Text("“\(trimmedName)” has been created, but setup isn’t finished. If you discard it, its folder (which has no files of yours yet) is moved to the Trash.")
        }
    }

    // MARK: 步骤 1：名字和位置

    private var locationStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetHeader(title: "Create a Vault",
                        subtitle: Text("A vault is a normal folder that holds only encrypted files. Put it anywhere — on this Mac, an external drive, or a synced folder such as iCloud Drive."))
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 14) {
                GridRow {
                    Text("Name").gridColumnAlignment(.trailing)
                    TextField("", text: $name, prompt: Text("For example, Tax 2025"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 300)
                }
                GridRow {
                    Text("Location")
                    HStack(spacing: 8) {
                        if let parent {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: parent.path))
                                .resizable().frame(width: 18, height: 18)
                            Text(LocationText.display(parent.path)).lineLimit(1).truncationMode(.middle)
                        } else {
                            Text("Not chosen").foregroundStyle(.secondary)
                        }
                        Button("Choose…", action: chooseParent)
                    }
                }
            }
            if let target, !trimmedName.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: "folder.fill").foregroundStyle(Color.fsAccent).font(.title2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("FolderSafe will create this folder:").font(.caption).foregroundStyle(.secondary)
                            Text(LocationText.display(target.path)).font(.callout.weight(.medium))
                                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                        }
                    }
                    Text("It will contain only encrypted data, so don’t edit it directly — unlock it with FolderSafe to use your files. You can back it up, move it, or sync it like any other folder.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045)))
            }
            ErrorLine(message: error)
        }
    }

    private func chooseParent() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = String(localized: "Choose")
        p.message = String(localized: "Choose where to put the new vault folder.")
        if let parent { p.directoryURL = parent }
        if p.runModal() == .OK, let u = p.url { parent = u; error = nil }
    }

    private var nameProblem: String? {
        if trimmedName.isEmpty { return String(localized: "Enter a name.") }
        if trimmedName.hasPrefix(".") || trimmedName.contains("/") || trimmedName.contains(":") {
            return String(localized: "The name can’t start with a period or contain “/” or “:”.")
        }
        return nil
    }

    // MARK: 步骤 2：密码

    private var passwordStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetHeader(title: "Choose a Password",
                        subtitle: Text("You’ll use it to unlock “\(trimmedName)”. Use something long that you don’t use anywhere else."))
            NewPasswordFields(password: $password, confirm: $confirm)
                .frame(width: 340)
            Callout(.warning, Text("FolderSafe can’t reset or recover your password. If you forget it, only the recovery phrase on the next page can get you back in. If you lose both, your files can’t be recovered by anyone — including us."))
            ErrorLine(message: error)
        }
    }

    // MARK: 步骤 3：找回短语

    private var phraseStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: "Write Down Your Recovery Phrase",
                        subtitle: Text("If you forget your password, these 12 words unlock the vault so you can set a new one."))
            PhraseGrid(words: words)
            Callout(.warning, Text("Write the words on paper, in order, and keep it somewhere safe. Anyone with these words can open the vault. Don’t take a screenshot or store them in this vault. They won’t be shown again."))
            HStack {
                Toggle("I’ve written down all 12 words", isOn: $wroteDown)
                Spacer()
                Button("Save as Text…") { PhraseExport.saveAsText(words: words, vaultName: trimmedName) }
                    .controlSize(.small)
            }
        }
    }

    // MARK: 步骤 4：抽查

    private var quizStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetHeader(title: "Check Your Recovery Phrase",
                        subtitle: Text("Enter these words from your written copy, to make sure it’s complete and readable."))
            PhraseQuiz(words: words, indices: quizIndices, answers: $answers)
                .padding(.vertical, 6)
            Text("Missing a word? Click Back to see the phrase again.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: 完成

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 40)).foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 4) {
                    Text("“\(trimmedName)” Is Ready").font(.title2.weight(.semibold))
                    Text("The vault is created and locked.").foregroundStyle(.secondary)
                }
            }
            if model.biometryAvailable {
                HStack(spacing: 12) {
                    Image(systemName: "touchid").font(.title).foregroundStyle(Color.fsAccent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Unlock with \(model.biometryName)").font(.headline)
                        Text("Unlock with your fingerprint instead of typing the password. The key stays in this Mac’s keychain and works only on this Mac.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if touchIDOn {
                        Label("On", systemImage: "checkmark").foregroundStyle(.green)
                    } else {
                        Button("Turn On") { Task { await enableTouchID() } }.disabled(working)
                    }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045)))
            }
            Callout(.info, Text("While a vault is unlocked, apps on this Mac can read its files. FolderSafe locks vaults automatically when your Mac sleeps, the screen locks, or after a period of inactivity — you can change this in Settings."))
            ErrorLine(message: error)
        }
    }

    // MARK: 底部按钮

    private var footer: some View {
        HStack {
            if step != .done {
                Button("Cancel") {
                    if created != nil { confirmDiscard = true } else { close() }
                }
                .keyboardShortcut(.cancelAction)
                .disabled(working)
            }
            Spacer()
            if working { WorkingLabel(title: step == .password ? "Creating vault…" : "Working…") }
            if step == .password || step == .quiz {
                Button("Back") { error = nil; step = Step(rawValue: step.rawValue - 1)! }
                    .disabled(working)
            }
            switch step {
            case .done:
                Button("Done") { close() }
                Button("Unlock Now") { unlockNow() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            default:
                Button(step == .password ? LocalizedStringKey("Create Vault") : LocalizedStringKey("Continue")) { next() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canContinue || working)
            }
        }
    }

    private var canContinue: Bool {
        switch step {
        case .location: return nameProblem == nil && parent != nil
        case .password: return NewPasswordFields.isValid(password, confirm)
        case .phrase: return wroteDown
        case .quiz: return PhraseQuiz(words: words, indices: quizIndices, answers: $answers).allCorrect
        case .done: return true
        }
    }

    private func next() {
        error = nil
        switch step {
        case .location:
            if let p = nameProblem { error = p; return }
            guard let target else { return }
            let fm = FileManager.default
            if fm.fileExists(atPath: target.path) {
                let items = (try? fm.contentsOfDirectory(atPath: target.path)) ?? ["?"]
                if !items.allSatisfy({ $0 == ".DS_Store" }) {
                    error = String(localized: "A folder named “\(trimmedName)” already exists there. Choose another name or location.")
                    return
                }
            }
            step = .password
        case .password:
            Task { await create() }
        case .phrase:
            quizIndices = PhraseQuiz.pick()
            answers = ["", "", ""]
            step = .quiz
        case .quiz:
            step = .done
        case .done:
            close()
        }
    }

    private func create() async {
        guard let target else { return }
        working = true
        defer { working = false }
        do {
            let (rec, phrase) = try await model.createVault(name: trimmedName, directory: target, password: password)
            created = rec
            words = phrase.words
            wroteDown = false
            step = .phrase
        } catch {
            self.error = ErrorText.describe(error)
        }
    }

    private func enableTouchID() async {
        guard let created else { return }
        working = true
        defer { working = false }
        do {
            try await model.enableTouchID(created.id, password: password)
            touchIDOn = true
        } catch {
            self.error = ErrorText.describe(error)
        }
    }

    private func unlockNow() {
        guard let created else { return close() }
        let pw = password
        close()
        Task {
            do { try await model.unlock(created.id, .password(pw)) }
            catch FileProviderPresenter.Failure.disabledByUser {
                model.showWindowAndUnlock(created.id)       // 解锁面板里有打开系统设置的引导
            } catch {
                if let msg = ErrorText.describe(error) {
                    model.notice = .init(title: String(localized: "Couldn’t unlock"), message: msg)
                }
            }
        }
    }

    private func close() {
        password = ""
        confirm = ""
        words = []
        answers = ["", "", ""]
        dismiss()
    }
}

struct StepIndicator: View {
    let current: CreateVaultWizard.Step

    private let titles: [LocalizedStringKey] = ["Name", "Password", "Recovery Phrase", "Check", "Done"]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(titles.enumerated()), id: \.offset) { i, t in
                let state = i < current.rawValue ? 0 : (i == current.rawValue ? 1 : 2)
                HStack(spacing: 6) {
                    ZStack {
                        Circle().fill(state == 2 ? Color.primary.opacity(0.08) : Color.fsAccent)
                            .frame(width: 20, height: 20)
                        if state == 0 {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        } else {
                            Text("\(i + 1)").font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(state == 1 ? Color.white : Color.secondary)
                        }
                    }
                    Text(t).font(.callout.weight(state == 1 ? .semibold : .regular))
                        .foregroundStyle(state == 2 ? Color.secondary : Color.primary)
                        .lineLimit(1)
                        .fixedSize()
                }
                if i < titles.count - 1 {
                    Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1).frame(minWidth: 8)
                }
            }
        }
    }
}
