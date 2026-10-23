import Foundation
import AppKit
import Combine
import SwiftUI
import FolderSafeCore

/// 界面状态 + 对 VaultService 的薄封装。演示模式（截图）下 service 为 nil，只显示假数据，不碰任何真实 vault / 钥匙串。
@MainActor
final class AppModel: ObservableObject {
    enum Sheet: Identifiable, Equatable {
        case create
        case unlock(String)
        case changePassword(String)
        case newPhrase(String)
        case resetPassword(String)
        case enableTouchID(String)
        case fskitSetup
        case feedback

        var id: String {
            switch self {
            case .create: return "create"
            case .unlock(let v): return "unlock-\(v)"
            case .changePassword(let v): return "pw-\(v)"
            case .newPhrase(let v): return "phrase-\(v)"
            case .resetPassword(let v): return "reset-\(v)"
            case .enableTouchID(let v): return "touchid-\(v)"
            case .fskitSetup: return "fskit"
            case .feedback: return "feedback"
            }
        }
    }

    /// 上锁时有程序占用：列出来，让用户选择强制上锁。
    struct BusyLock: Identifiable {
        let id = UUID()
        let vaultIDs: [String]
        let lines: [String]          // "Preview" 或 "Tax 2025: Preview, TextEdit"
        let errorMessage: String?
    }

    struct Notice: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    private(set) var service: VaultService?
    var presenter: VaultPresenter? { service?.presenter }
    @Published private(set) var choice: PresenterChoice
    private let demo: Bool
    var isDemo: Bool { demo }

    @Published private(set) var records: [VaultRecord] = []
    @Published private(set) var unlocked: [String: URL] = [:]
    @Published private(set) var touchIDEnabled: Set<String> = []
    @Published private(set) var inProgress: Set<String> = []
    /// "挂成真正的文件夹（FSKit，测试版）"开着时，系统里扩展的状态。
    @Published private(set) var fskitStatus: FSKitStatus = .unknown
    @Published var selection: String?
    @Published var sheet: Sheet?
    @Published var busyLock: BusyLock?
    @Published var notice: Notice?

    /// 由带 openWindow 环境的视图注入（主窗口、菜单栏），用来在窗口关着时把它打开。
    var openMainWindow: (() -> Void)?

    private var bag = Set<AnyCancellable>()
    private var serviceBag = Set<AnyCancellable>()

    init(service: VaultService, choice: PresenterChoice) {
        self.demo = false
        self.choice = choice
        bind(service, choice: choice)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in Task { await self?.refreshFSKit() } }.store(in: &bag)
    }

    private func bind(_ service: VaultService, choice: PresenterChoice) {
        serviceBag.removeAll()
        self.service = service
        self.choice = choice
        service.$records.sink { [weak self] list in
            guard let self else { return }
            self.records = list
            self.touchIDEnabled = Set(list.filter { DeviceKeyStore.isEnabled(vaultId: $0.id) }.map(\.id))
            if let s = self.selection, !list.contains(where: { $0.id == s }) { self.selection = nil }
            if self.selection == nil { self.selection = list.first?.id }
        }.store(in: &serviceBag)
        service.$unlocked.sink { [weak self] in self?.unlocked = $0 }.store(in: &serviceBag)
    }

    /// 演示模式：截图用，所有操作都是空操作。
    init(demoRecords: [VaultRecord], unlocked: [String: URL], touchID: Set<String>, choice: PresenterChoice) {
        self.service = nil
        self.demo = true
        self.choice = choice
        self.records = demoRecords
        self.unlocked = unlocked
        self.touchIDEnabled = touchID
        self.selection = demoRecords.first?.id
    }

    // MARK: 查询

    func record(_ id: String?) -> VaultRecord? { records.first { $0.id == id } }
    func isUnlocked(_ id: String) -> Bool { unlocked[id] != nil }
    var anyUnlocked: Bool { !unlocked.isEmpty }
    var biometryAvailable: Bool { isDemo ? true : DeviceKeyStore.isAvailable }
    var biometryName: String {
        let n = isDemo ? "Touch ID" : DeviceKeyStore.biometryName
        return n.isEmpty || n == "Touch ID" ? String(localized: "Touch ID") : n
    }

    // MARK: 呈现方式（默认 File Provider；直装版 macOS 26+ 可选 FSKit）

    /// 直装版且 macOS 26+ 才提供"挂成真正的文件夹"。
    /// 1.0 先关掉：实测 FSKit 扩展的沙盒读不了 mount 传进来的 vault 路径（不认临时例外），
    /// 要改成 FSClient + 安全作用域 URL 的挂载方式后再打开（2026-10-23）。
    static let fskitEnabledInThisRelease = false

    static var fskitOfferable: Bool {
        #if APPSTORE
        return false
        #else
        return fskitEnabledInThisRelease && FSKitPresenter.isSystemSupported
        #endif
    }

    var wantsFSKit: Bool { Self.fskitOfferable && UserDefaults.standard.bool(forKey: Pref.useFSKit) }

    /// 用户打开了 FSKit 选项，但扩展还没在系统设置里打开。
    var needsFSKitSetup: Bool { wantsFSKit && choice != .fskit && fskitStatus != .checking && fskitStatus != .enabled }

    /// 查询扩展状态（后台线程，最多 5 秒），能用就切到 FSKit；不能用就留在 File Provider。只在全部上锁时切换。
    func refreshFSKit() async {
        #if !APPSTORE
        guard !isDemo, wantsFSKit else {
            if !isDemo && choice == .fskit && !anyUnlocked { switchPresenter(to: .fileProvider) }
            return
        }
        fskitStatus = .checking
        let state = await Task.detached(priority: .userInitiated) { FSKitPresenter.moduleState() }.value
        switch state {
        case .enabled: fskitStatus = .enabled
        case .disabled: fskitStatus = .disabled
        case .notInstalled: fskitStatus = .notInstalled
        case .unknown: fskitStatus = .unknown
        }
        if fskitStatus == .enabled, choice != .fskit, !anyUnlocked { switchPresenter(to: .fskit) }
        if fskitStatus != .enabled, choice == .fskit, !anyUnlocked { switchPresenter(to: .fileProvider) }
        #endif
    }

    /// 设置里切换"挂成真正的文件夹"。必须全部上锁。
    func setUseFSKit(_ on: Bool) {
        guard !anyUnlocked else { return }
        UserDefaults.standard.set(on, forKey: Pref.useFSKit)
        objectWillChange.send()
        if on {
            Task { await refreshFSKit() }
        } else if choice == .fskit {
            switchPresenter(to: .fileProvider)
        }
    }

    private func switchPresenter(to c: PresenterChoice) {
        guard !isDemo, !anyUnlocked, c != choice else { return }
        let presenter = PresenterChoice.presenter(for: c)
        bind(VaultService(presenter: presenter), choice: c)
    }

    func refreshTouchID() {
        guard !isDemo else { return }
        touchIDEnabled = Set(records.filter { DeviceKeyStore.isEnabled(vaultId: $0.id) }.map(\.id))
    }

    // MARK: 新建 / 添加 / 移除

    /// FSKit 挂载点默认 ~/FolderSafe/<名字>，和已有的不重名。
    func defaultMountPoint(for name: String) -> String? {
        guard Self.fskitOfferable else { return nil }
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("FolderSafe")
        let used = Set(records.compactMap(\.mountPoint))
        let clean = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var candidate = base.appendingPathComponent(clean).path
        var n = 2
        while used.contains(candidate) {
            candidate = base.appendingPathComponent("\(clean) \(n)").path
            n += 1
        }
        return candidate
    }

    /// 新建 vault。失败时不留下半成品：目录原本不存在就整个删掉，原本是空目录就清回空目录。
    func createVault(name: String, directory: URL, password: String) async throws -> (VaultRecord, RecoveryPhrase) {
        guard let service else { throw CocoaError(.featureUnsupported) }
        let fm = FileManager.default
        let scoped = directory.startAccessingSecurityScopedResource()
        defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
        let existed = fm.fileExists(atPath: directory.path)
        if existed {
            let items = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
            guard items.allSatisfy({ $0 == ".DS_Store" }) else { throw VaultError.alreadyExists(directory.path) }
        }
        try await Task.sleep(nanoseconds: 80_000_000)        // 让进度先画出来
        do {
            let (created, phrase) = try service.create(name: name, directory: directory, password: password,
                                                       bookmark: nil, mountPoint: defaultMountPoint(for: name))
            var rec = created
            if let bm = try? directory.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                rec.bookmark = bm
                service.update(rec)
            }
            selection = rec.id
            return (rec, phrase)
        } catch {
            cleanUpPartialVault(at: directory, existedBefore: existed)
            throw error
        }
    }

    private func cleanUpPartialVault(at dir: URL, existedBefore: Bool) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return }
        // 只删本次新建时写下的东西：目录在建库前不存在或是空的，所以里面的内容都是刚才写的。
        if !existedBefore {
            try? fm.removeItem(at: dir)
        } else {
            for item in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where item != ".DS_Store" {
                try? fm.removeItem(at: dir.appendingPathComponent(item))
            }
        }
    }

    /// 向导中途放弃：刚建好的空 vault 从清单移除，文件夹移到废纸篓（里面还没有用户文件）。
    func discardNewVault(_ r: VaultRecord) async {
        guard let service else { return }
        if await service.forget(r) != nil, service.records.contains(where: { $0.id == r.id }) { return }   // 没能移除就不动文件夹
        let url = r.resolveURL() ?? URL(fileURLWithPath: r.path)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    func showAddExisting() {
        guard !isDemo else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = String(localized: "Add Vault")
        panel.message = String(localized: "Choose a vault folder — the folder that contains “vault.cryptomator”. Vaults created with Cryptomator work too.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let problem = addExisting(at: url) { notice = problem }
    }

    /// 登记已有的 vault。返回 nil 表示成功（或已在清单里，已选中）。
    @discardableResult
    func addExisting(at url: URL) -> Notice? {
        guard let service else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("vault.cryptomator").path) else {
            return Notice(title: String(localized: "This folder isn’t a vault"),
                          message: String(localized: "Choose the folder that contains “vault.cryptomator”. If you picked a folder inside the vault, go one level up."))
        }
        do {
            let id = try Vault.vaultId(at: url)
            if let existing = records.first(where: { $0.id == id }) {
                selection = existing.id
                return Notice(title: String(localized: "Already added"),
                              message: String(localized: "“\(existing.name)” is already in your list."))
            }
            let bm = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            let name = url.lastPathComponent
            let r = try service.add(existing: url, name: name, bookmark: bm, mountPoint: defaultMountPoint(for: name))
            selection = r.id
            return nil
        } catch {
            return Notice(title: String(localized: "Couldn’t add the vault"), message: ErrorText.describe(error) ?? "")
        }
    }

    func forget(_ id: String) async {
        guard let service, let r = record(id) else { return }
        guard let error = await service.forget(r) else { return }
        if case FileProviderPresenter.Failure.unsavedChangesPreserved(let url) = error {
            notice = Notice(title: String(localized: "Locked — some changes were kept outside the vault"),
                            message: String(localized: "Some changes couldn’t be written into the vault in time. They were kept here so nothing is lost:\n\(url.path)\n\nUnlock the vault, move these files back into it, then delete them from that folder."))
        } else {
            // 没能上锁（例如有程序占着）：不移除，免得留下一个没人管的已解锁位置
            notice = Notice(title: String(localized: "Couldn’t remove the vault"),
                            message: String(localized: "FolderSafe couldn’t lock “\(r.name)” first, so it was not removed. Close any files from the vault and try again.") + "\n\n" + (ErrorText.describe(error) ?? error.localizedDescription))
        }
    }

    func rename(_ id: String, to name: String) {
        guard let service, var r = record(id) else { return }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n != r.name else { return }
        r.name = n
        service.update(r)
    }

    func setMountPoint(_ id: String, _ path: String?) {
        guard let service, var r = record(id) else { return }
        r.mountPoint = path ?? defaultMountPoint(for: r.name)
        service.update(r)
    }

    // MARK: 解锁

    func beginUnlock(_ id: String) {
        sheet = .unlock(id)
    }

    /// 菜单栏里的"解锁"：开了 Touch ID 就直接弹指纹，否则打开主窗口输密码。
    func quickUnlock(_ id: String) {
        guard let r = record(id) else { return }
        if touchIDEnabled.contains(id) {
            Task {
                do { _ = try await unlock(id, .biometrics(reason: unlockReason(r))) }
                catch {
                    if ErrorText.describe(error) == nil { return }      // 用户取消
                    showWindowAndUnlock(id)
                }
            }
        } else {
            showWindowAndUnlock(id)
        }
    }

    func showWindowAndUnlock(_ id: String) {
        bringMainWindowForward()
        selection = id
        beginUnlock(id)
    }

    func bringMainWindowForward() {
        NSApp.setActivationPolicy(.regular)
        openMainWindow?()
        NSApp.activate(ignoringOtherApps: true)
    }

    func unlockReason(_ r: VaultRecord) -> String { String(localized: "unlock “\(r.name)”") }

    @discardableResult
    func unlock(_ id: String, _ secret: VaultService.Secret) async throws -> URL {
        guard let service, let r = record(id) else { throw CocoaError(.featureUnsupported) }
        inProgress.insert(id)
        defer { inProgress.remove(id) }
        try await Task.sleep(nanoseconds: 50_000_000)
        let url = try await service.unlock(r, with: secret)
        if UserDefaults.standard.bool(forKey: Pref.openAfterUnlock) { NSWorkspace.shared.open(url) }
        return url
    }

    /// 用找回短语：可选同时设新密码。
    func unlockWithPhrase(_ id: String, phrase: String, newPassword: String?) async throws {
        guard let service, let r = record(id) else { return }
        if let newPassword {
            inProgress.insert(id)
            try await Task.sleep(nanoseconds: 50_000_000)
            do { try service.resetPassword(r, recoveryPhrase: phrase, new: newPassword) }
            catch { inProgress.remove(id); throw error }
            inProgress.remove(id)
            // 新密码生效后，旧的 Touch ID 钥匙仍然有效（主密钥没变），不用重设。
            try await unlock(id, .password(newPassword))
        } else {
            try await unlock(id, .recoveryPhrase(phrase))
        }
    }

    // MARK: 上锁

    func requestLock(_ id: String) {
        Task { await lock([id], force: false) }
    }

    func requestLockAll() {
        let open = records.filter { isUnlocked($0.id) }.map(\.id)
        guard !open.isEmpty else { return }
        Task { await lock(open, force: false) }
    }

    /// 上锁。非强制时被占用 / 还有改动没写回就提示，让用户选择强制上锁。
    func lock(_ ids: [String], force: Bool) async {
        guard service != nil else { return }
        var busyIDs: [String] = []
        var lines: [String] = []
        var messages: [String] = []
        var preserved: [String] = []
        for id in ids {
            guard let r = record(id), isUnlocked(id) else { continue }
            inProgress.insert(id)
            switch await lockOne(r, force: force) {
            case .locked: break
            case .lockedKeptFiles(let path): preserved.append(path)
            case .busy(let apps):
                busyIDs.append(id)
                lines.append(ids.count > 1 ? "\(r.name): \(apps.joined(separator: ", "))" : apps.joined(separator: ", "))
            case .failed(let msg):
                if force { messages.append("\(r.name): \(msg)") } else { busyIDs.append(id); messages.append(msg) }
            }
            inProgress.remove(id)
        }
        if !preserved.isEmpty {
            notice = Notice(title: String(localized: "Locked — some changes were kept outside the vault"),
                            message: String(localized: "Some changes couldn’t be written into the vault in time. They were kept here so nothing is lost:\n\(preserved.joined(separator: "\n"))\n\nUnlock the vault, move these files back into it, then delete them from that folder."))
        } else if !messages.isEmpty && force {
            notice = Notice(title: String(localized: "Some vaults couldn’t be locked"), message: messages.joined(separator: "\n"))
        }
        if !busyIDs.isEmpty && !force {
            busyLock = BusyLock(vaultIDs: busyIDs, lines: lines, errorMessage: messages.isEmpty ? nil : messages.joined(separator: "\n"))
        }
    }

    private enum LockOutcome { case locked, lockedKeptFiles(String), busy([String]), failed(String) }

    private func lockOne(_ r: VaultRecord, force: Bool) async -> LockOutcome {
        guard let service else { return .failed("") }
        do {
            try await service.lock(r, force: force)
            return .locked
        } catch FileProviderPresenter.Failure.unsavedChangesPreserved(let url) {
            // 域已经撤下（已上锁），只是没写回的文件被保留了：再调一次把钥匙删掉、状态清掉。
            try? await service.lock(r, force: true)
            return .lockedKeptFiles(url.path)
        } catch {
            #if !APPSTORE
            if case FSKitPresenter.Failure.busy(let apps) = error { return .busy(apps) }
            #endif
            return .failed(ErrorText.describe(error) ?? error.localizedDescription)
        }
    }

    /// 自动上锁（睡眠、锁屏、闲置、退出）：一律强制。
    func autoLockAll() async {
        let open = records.filter { isUnlocked($0.id) }.map(\.id)
        guard !open.isEmpty else { return }
        await lock(open, force: true)
    }

    // MARK: 打开

    func reveal(_ id: String) {
        if let url = unlocked[id] { NSWorkspace.shared.open(url) }
    }

    /// 在访达里显示加密后的 vault 文件夹（不是解锁后的内容）。
    func revealEncryptedFolder(_ id: String) {
        guard let r = record(id) else { return }
        let url = r.resolveURL() ?? URL(fileURLWithPath: r.path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: 钥匙管理

    private func run<T>(_ id: String, _ body: (VaultService, VaultRecord) throws -> T) async throws -> T {
        guard let service, let r = record(id) else { throw CocoaError(.featureUnsupported) }
        inProgress.insert(id)
        defer { inProgress.remove(id) }
        try await Task.sleep(nanoseconds: 50_000_000)
        return try body(service, r)
    }

    func changePassword(_ id: String, current: String, new: String) async throws {
        try await run(id) { s, r in try s.changePassword(r, current: current, new: new) }
    }

    func regeneratePhrase(_ id: String, password: String) async throws -> RecoveryPhrase {
        try await run(id) { s, r in try s.regenerateRecoveryPhrase(r, password: password) }
    }

    func resetPassword(_ id: String, phrase: String, new: String) async throws {
        try await run(id) { s, r in try s.resetPassword(r, recoveryPhrase: phrase, new: new) }
    }

    func enableTouchID(_ id: String, password: String) async throws {
        try await run(id) { s, r in try s.enableBiometrics(r, password: password) }
        refreshTouchID()
    }

    func disableTouchID(_ id: String) {
        guard let service, let r = record(id) else { return }
        service.disableBiometrics(r)
        refreshTouchID()
    }
}

/// 位置的友好显示：iCloud 云盘路径显示成"iCloud 云盘 › …"。
enum LocationText {
    static func display(_ path: String) -> String {
        let icloud = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs").path
        if path.hasPrefix(icloud) {
            let rest = path.dropFirst(icloud.count).split(separator: "/").joined(separator: " › ")
            return rest.isEmpty ? String(localized: "iCloud Drive") : String(localized: "iCloud Drive") + " › " + rest
        }
        return path.abbreviatingHome
    }

    /// 父目录（列表副标题用）。
    static func parent(_ path: String) -> String {
        display((path as NSString).deletingLastPathComponent)
    }
}
