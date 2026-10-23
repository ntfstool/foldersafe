import SwiftUI
import FolderSafeCore

/// 新建 vault：名字 → 位置 → 密码（这时建库）→ 抄 12 词 → 抽查 3 个词 → 完成（Face ID / 立即解锁）。
struct NewVaultWizard: View {
    enum Step: Int { case name, location, password, phrase, quiz, done }

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var step: Step
    @State private var name = ""
    @State private var parent: URL?
    @State private var showPicker = false
    @State private var password = ""
    @State private var confirm = ""
    @State private var record: VaultRecord?
    @State private var words: [String] = []
    @State private var wroteDown = false
    @State private var quizIndices: [Int] = []
    @State private var answers: [String] = ["", "", ""]
    @State private var quizFailed = false
    @State private var useBiometrics = false
    @State private var working = false
    @State private var error: String?
    @State private var screenshotWarning = false
    @FocusState private var nameFocused: Bool

    init(startAt: Step = .name) {
        _step = State(initialValue: startAt)
        if startAt != .name {
            _name = State(initialValue: String(localized: "Tax 2025"))
        }
        if startAt == .phrase {
            _words = State(initialValue: Snapshot.demoWords)
        }
        if startAt == .location {
            // 截图用：演示位置（只显示，不会写入）
            _parent = State(initialValue: URL(fileURLWithPath: "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Documents", isDirectory: true))
        }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(navigationTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
                .errorAlert($error)
                .animation(.default, value: step)
        }
        .sheet(isPresented: $showPicker) {
            FolderPicker { url in
                parent = url
                showPicker = false
            } onCancel: {
                showPicker = false
            }
            .ignoresSafeArea()
        }
        .alert("About screenshots", isPresented: $screenshotWarning) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("A screenshot of your recovery phrase can be synced to iCloud Photos or seen by other apps. Writing the words on paper is safer. Consider deleting the screenshot.")
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
            if step == .phrase && model.snapshot == nil { screenshotWarning = true }
        }

    }

    private var navigationTitle: LocalizedStringKey {
        switch step {
        case .name, .location, .password: return "New Vault"
        case .phrase, .quiz: return "Recovery Phrase"
        case .done: return "Done"
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        // 建好之后不能取消：找回短语必须走完
        if record == nil && step != .phrase {
            ToolbarItem(placement: step == .name ? .topBarLeading : .topBarTrailing) {
                Button("Cancel") { dismiss() }
            }
        }
        if step == .location || step == .password {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    step = Step(rawValue: step.rawValue - 1) ?? .name
                } label: {
                    Label("Back", systemImage: "chevron.backward")
                }
            }
        }
        if step == .quiz {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    step = .phrase
                } label: {
                    Label("Back", systemImage: "chevron.backward")
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .name: nameStep
        case .location: locationStep
        case .password: passwordStep
        case .phrase: phraseStep
        case .quiz: quizStep
        case .done: doneStep
        }
    }

    // MARK: 1. 名字

    private var nameStep: some View {
        Form {
            StepHeader(systemImage: "folder.badge.plus", title: "Name your vault",
                       text: "The name is shown in FolderSafe and the Files app. A folder with this name will hold the encrypted files.")
            Section {
                TextField("For example: Tax 2025", text: $name)
                    .focused($nameFocused)
                    .submitLabel(.next)
                    .onSubmit { if canContinueName { step = .location } }
            }
        }
        .safeAreaInset(edge: .bottom) {
            ContinueBar(title: "Continue", enabled: canContinueName) { step = .location }
        }
        .onAppear { nameFocused = true }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canContinueName: Bool { !trimmedName.isEmpty }

    // MARK: 2. 位置

    private var locationStep: some View {
        Form {
            StepHeader(systemImage: "externaldrive.badge.icloud", title: "Choose where to keep it",
                       text: "Pick any location from the Files app: iCloud Drive, On My iPhone, or another storage provider.")
            Section {
                if let parent {
                    HStack(spacing: 12) {
                        Image(systemName: parent.path.contains("Mobile Documents") ? "icloud.fill" : "folder.fill")
                            .foregroundStyle(Color.brand)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(VaultLocation.hint(forPath: parent.path, includeLast: true))
                                .font(.body.weight(.medium))
                            Text("New folder: “\(VaultLocation.folderName(for: trimmedName))”")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Change") { showPicker = true }
                            .font(.subheadline)
                    }
                    .padding(.vertical, 4)
                } else {
                    Button {
                        showPicker = true
                    } label: {
                        Label("Choose a Folder…", systemImage: "folder")
                    }
                }
                #if DEBUG
                if model.snapshot == nil {
                Button("Use App's Documents Folder (Debug)") {
                    parent = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                }
                .font(.footnote)
                }
                #endif
            } footer: {
                Text("FolderSafe creates a normal folder there that contains only encrypted data. If the location is iCloud Drive, it syncs like any other folder, and the encryption happens on this iPhone first.")
            }
        }
        .safeAreaInset(edge: .bottom) {
            ContinueBar(title: "Continue", enabled: parent != nil) { step = .password }
        }
    }

    // MARK: 3. 密码 → 建库

    private var passwordStep: some View {
        Form {
            StepHeader(systemImage: "key.fill", title: "Create a password",
                       text: "You'll use this password to unlock the vault. Use at least 8 characters; a longer passphrase is stronger.")
            Section {
                NewPasswordFields(password: $password, confirm: $confirm)
            }
            Section {
                Notice(text: "FolderSafe can't see or reset your password. If you forget it, only your recovery phrase can open this vault.")
            }
        }
        .safeAreaInset(edge: .bottom) {
            ContinueBar(title: "Create Vault", enabled: NewPasswordFields.isValid(password, confirm), working: working) {
                Task { await create() }
            }
        }
    }

    private func create() async {
        guard let parent, !working else { return }
        working = true
        defer { working = false }
        await Task.yield()
        do {
            let (rec, phrase) = try model.createVault(name: trimmedName, in: parent, password: password)
            record = rec
            words = phrase.words
            step = .phrase
        } catch {
            self.error = ErrorText.message(for: error)
        }
    }

    // MARK: 4. 找回短语

    private var phraseStep: some View {
        Form {
            StepHeader(systemImage: "list.number", title: "Write down your recovery phrase",
                       text: "If you forget your password, these 12 words are the only way to open this vault. Write them on paper, in order.")
            Section {
                PhraseGrid(words: words)
            }
            Section {
                Notice(text: "Anyone who has these words can open this vault. Keep them somewhere safe and private. Don't store them in a screenshot, a note or an email.")
                Toggle("I've written down all 12 words", isOn: $wroteDown)
                    .font(.body.weight(.medium))
            }
        }
        .safeAreaInset(edge: .bottom) {
            ContinueBar(title: "Continue", enabled: wroteDown) {
                quizIndices = Array((0..<words.count).shuffled().prefix(3)).sorted()
                answers = ["", "", ""]
                quizFailed = false
                step = .quiz
            }
        }
    }

    // MARK: 5. 抽查

    private var quizStep: some View {
        Form {
            StepHeader(systemImage: "checkmark.circle", title: "Check your copy",
                       text: "Enter these words from your recovery phrase to make sure you wrote it down correctly.")
            Section {
                ForEach(Array(quizIndices.enumerated()), id: \.offset) { i, idx in
                    HStack {
                        Text("Word \(idx + 1)")
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 80, alignment: .leading)
                        TextField("", text: $answers[i])
                            .font(.body.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.asciiCapable)
                    }
                }
            } footer: {
                if quizFailed {
                    Label("Some words don't match. Check your copy, or go back to see the phrase again.", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            ContinueBar(title: "Continue", enabled: answers.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                let ok = quizIndices.enumerated().allSatisfy { i, idx in
                    answers[i].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == words[idx]
                }
                if ok {
                    quizFailed = false
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    step = .done
                } else {
                    quizFailed = true
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                }
            }
        }
    }

    // MARK: 6. 完成

    private var doneStep: some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 60))
                        .foregroundStyle(.green)
                    Text("Your vault is ready")
                        .font(.title2.bold())
                    if let record {
                        Text("“\(record.name)” is in \(record.locationHint). It's locked until you unlock it.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .listRowBackground(Color.clear)

            if model.biometryAvailable {
                Section {
                    Toggle(isOn: Binding(get: { useBiometrics }, set: { on in Task { await setBiometrics(on) } })) {
                        Label("Unlock with \(model.biometryName)", systemImage: model.biometrySymbol)
                    }
                    .disabled(working)
                } footer: {
                    Text("Only works on this iPhone. You can change this later in Vault Settings.")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                Button {
                    Task { await unlockNow() }
                } label: {
                    if working { ProgressView().tint(.white) } else { Label("Unlock Now", systemImage: "lock.open.fill") }
                }
                .buttonStyle(WideButtonStyle())
                Button("Done") { finish() }
                    .buttonStyle(WideButtonStyle(prominent: false))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }

    private func setBiometrics(_ on: Bool) async {
        guard let record else { return }
        working = true
        defer { working = false }
        do {
            if on { try await model.enableBiometrics(record, password: password) } else { model.disableBiometrics(record) }
            useBiometrics = on
        } catch {
            useBiometrics = false
            if !ErrorText.isCancellation(error) { self.error = ErrorText.message(for: error) }
        }
    }

    private func unlockNow() async {
        guard let record, !working else { return }
        working = true
        defer { working = false }
        await Task.yield()
        do {
            try await model.unlock(record, with: .password(password))
            finish()
        } catch AppError.filesLocationDisabled {
            finish()                     // 库已建好；RootView 会提示去"文件"App 打开位置
        } catch {
            self.error = ErrorText.message(for: error)
        }
    }

    private func finish() {
        let id = record?.id
        password = ""
        confirm = ""
        words = []
        answers = ["", "", ""]
        dismiss()
        if let id { model.path = [id] }
    }
}

// MARK: - 向导里的小组件

struct StepHeader: View {
    var systemImage: String
    var title: LocalizedStringKey
    var text: LocalizedStringKey

    var body: some View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(Color.brand)
                    .frame(height: 50)
                Text(title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 4)
        }
        .listRowBackground(Color.clear)
    }
}

struct ContinueBar: View {
    var title: LocalizedStringKey
    var enabled: Bool
    var working = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            if working { ProgressView().tint(.white) } else { Text(title) }
        }
        .buttonStyle(WideButtonStyle(tint: enabled ? Color.brand : Color(.systemGray3)))
        .disabled(!enabled || working)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }
}
