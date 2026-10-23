import SwiftUI
import Combine
import FolderSafeCore

/// 自动上锁约定（App 与 File Provider 扩展共用，存在 App Group 的 SharedConfig.defaults 里）：
/// - `autoLock.enabled`（Bool，缺省 true）、`autoLock.minutes`（Int，缺省 15）
/// - `unlockedUntil.<vaultId>`（Date）：这个时间之后该 vault 必须视为已上锁。
///   App 在解锁、回到前台、进入后台时写成 now + N 分钟；关闭自动上锁时写 Date.distantFuture；上锁时删除。
///   扩展独立运行（App 可能被系统挂起或杀掉），应在每次访问前检查：过期就丢掉内存里的钥匙、
///   删除 UnlockedKeyStore 里的钥匙并拒绝读写。键不存在 = 不限时（只看钥匙是否存在）。
enum AutoLock {
    static let enabledKey = "autoLock.enabled"
    static let minutesKey = "autoLock.minutes"
    static func untilKey(_ vaultId: String) -> String { "unlockedUntil.\(vaultId)" }
    static let choices = [1, 5, 15, 30, 60]

    private static var defaults: UserDefaults { SharedConfig.defaults }

    static var isEnabled: Bool {
        get { defaults.object(forKey: enabledKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: enabledKey) }
    }

    static var minutes: Int {
        get { let m = defaults.integer(forKey: minutesKey); return m > 0 ? m : 15 }
        set { defaults.set(newValue, forKey: minutesKey) }
    }

    static func until(_ vaultId: String) -> Date? { defaults.object(forKey: untilKey(vaultId)) as? Date }

    static func setUntil(_ date: Date?, for vaultId: String) {
        if let date { defaults.set(date, forKey: untilKey(vaultId)) } else { defaults.removeObject(forKey: untilKey(vaultId)) }
    }

    /// 从现在起算的新期限。
    static func freshDeadline(from now: Date = Date()) -> Date {
        isEnabled ? now.addingTimeInterval(TimeInterval(minutes * 60)) : .distantFuture
    }

    static func isExpired(_ vaultId: String, now: Date = Date()) -> Bool {
        guard let d = until(vaultId) else { return false }
        return d <= now
    }
}

enum AppSheet: Identifiable {
    case newVault, addExisting, settings
    var id: Int { hashValue }
}

/// 界面的总状态：包一层 VaultService，加上自动上锁、Face ID 状态缓存、演示数据（截图用）。
@MainActor
final class AppModel: ObservableObject {
    let service: VaultService
    let snapshot: Snapshot.Screen?

    @Published var path: [String] = []                 // NavigationStack：vault ID
    @Published var sheet: AppSheet?
    @Published var lockFailure: VaultRecord?            // 普通上锁失败，询问是否强制
    @Published var alertMessage: String?
    /// 用户在"文件"App 里关掉了 FolderSafe 的位置：解锁时提示怎么打开。
    @Published var filesDisabledVault: VaultRecord?

    @Published private(set) var biometricIDs: Set<String> = []
    @Published private(set) var demo: DemoState?
    @Published private(set) var autoLockEnabled = AutoLock.isEnabled
    @Published private(set) var autoLockMinutes = AutoLock.minutes

    private var bag: Set<AnyCancellable> = []
    private var timer: AnyCancellable?

    init() {
        snapshot = Snapshot.current
        if let snapshot {
            service = VaultService(presenter: DemoPresenter())
            demo = DemoState.make(for: snapshot)
        } else {
            // App 被系统杀掉后重启：还在自动上锁期限内的 vault 由 VaultService 照旧按已解锁恢复，其余钥匙清掉。
            service = VaultService(presenter: PresenterFactory.make())
            cleanUpStaleLocations()
        }
        service.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
        refreshBiometrics()
        if snapshot == nil { startTimer() }
    }

    /// 没有解锁的 vault 一律撤下（上次异常退出可能留下"文件"App 里的位置），并清掉期限。
    private func cleanUpStaleLocations() {
        let stale = service.records.filter { !service.isUnlocked($0) }
        for r in stale { AutoLock.setUntil(nil, for: r.id) }
        if service.presenter is FileProviderPresenter {
            // 撤下所有没有钥匙或已不在清单里的域（钥匙在上面已按期限放回）
            Task { await FileProviderPresenter.removeStaleDomains() }
        } else {
            let presenter = service.presenter
            Task { for r in stale { try? await presenter.dismiss(r, force: true) } }
        }
    }

    // MARK: 读

    var records: [VaultRecord] { demo?.records ?? service.records }

    func record(id: String) -> VaultRecord? { records.first { $0.id == id } }

    func isUnlocked(_ r: VaultRecord) -> Bool {
        if let demo { return demo.unlocked.contains(r.id) }
        return service.isUnlocked(r)
    }

    var anyUnlocked: Bool { records.contains { isUnlocked($0) } }

    func biometricsEnabled(_ r: VaultRecord) -> Bool { biometricIDs.contains(r.id) }

    var biometryAvailable: Bool { demo != nil || DeviceKeyStore.isAvailable }

    /// "Face ID" / "Touch ID"；模拟器上没有生物识别时也显示 Face ID（本 App 只上 iPhone）。
    private lazy var isTouchID = DeviceKeyStore.biometryName == "Touch ID"
    var biometryName: String { isTouchID ? String(localized: "Touch ID") : String(localized: "Face ID") }
    var biometrySymbol: String { isTouchID ? "touchid" : "faceid" }

    func filesURL(_ r: VaultRecord) -> URL? { service.unlocked[r.id] }

    func lockDeadline(_ r: VaultRecord) -> Date? {
        if let demo { return demo.unlocked.contains(r.id) ? Date().addingTimeInterval(TimeInterval(autoLockMinutes * 60)) : nil }
        guard let d = AutoLock.until(r.id), d != .distantFuture else { return nil }
        return d
    }

    func refreshBiometrics() {
        if let demo { biometricIDs = demo.biometrics; return }
        biometricIDs = Set(service.records.filter { service.biometricsEnabled($0) }.map(\.id))
    }

    // MARK: 建库 / 添加

    /// 在用户选的 parent 文件夹里新建 `<name>` 子文件夹作为 vault。parent 是文件选择器给的安全作用域 URL。
    func createVault(name: String, in parent: URL, password: String) throws -> (VaultRecord, RecoveryPhrase) {
        if demo != nil { throw DemoError.notInDemo }
        let scoped = parent.startAccessingSecurityScopedResource()
        defer { if scoped { parent.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        let dir = VaultLocation.uniqueChild(of: parent, named: name)
        try fm.createDirectory(at: dir, withIntermediateDirectories: false)
        do {
            let bookmark = try dir.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            return try service.create(name: name, directory: dir, password: password, bookmark: bookmark)
        } catch {
            // 文件夹是上面刚新建的（不会和已有文件夹重名），里面只有这次写下的半成品：整个删掉，不留半个 vault
            try? fm.removeItem(at: dir)
            throw error
        }
    }

    /// 添加已有的 vault：用户选的文件夹里要有 vault.cryptomator。
    func addExisting(_ url: URL) async throws -> VaultRecord {
        if demo != nil { throw DemoError.notInDemo }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        await VaultLocation.prefetch(["vault.cryptomator", "masterkey.cryptomator"], in: url)
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("vault.cryptomator").path) else {
            throw AppError.notAVault
        }
        let id = try Vault.vaultId(at: url)
        if service.records.contains(where: { $0.id == id }) { throw AppError.alreadyAdded }
        let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let rec = try service.add(existing: url, name: url.lastPathComponent, bookmark: bookmark)
        refreshBiometrics()
        return rec
    }

    func forget(_ r: VaultRecord) async {
        if demo != nil { demo?.records.removeAll { $0.id == r.id }; return }
        if let error = await service.forget(r), service.records.contains(where: { $0.id == r.id }) {
            // 没能撤下（还有改动没写回）：不移除，免得那些改动再也没法写回
            _ = error
            alertMessage = String(localized: "“\(r.name)” wasn't removed: some changes from the Files app still need to be saved into it. Unlock it once so they can be saved, then remove it.")
            return
        }
        AutoLock.setUntil(nil, for: r.id)
        path.removeAll { $0 == r.id }
        refreshBiometrics()
    }

    // MARK: 解锁 / 上锁

    func unlock(_ r: VaultRecord, with secret: VaultService.Secret) async throws {
        if demo != nil { demo?.unlocked.insert(r.id); return }
        await prefetchKeyFiles(r)
        do {
            try await service.unlock(r, with: secret)
        } catch FileProviderPresenter.Failure.disabledByUser {
            filesDisabledVault = r
            throw AppError.filesLocationDisabled
        } catch DeviceKeyStore.Failure.keychain(let status) where status == errSecItemNotFound {
            // 换过面容 / 指纹后钥匙自动失效：关掉 Face ID，让用户用密码
            service.disableBiometrics(r)
            refreshBiometrics()
            throw AppError.biometricsInvalidated
        }
        AutoLock.setUntil(AutoLock.freshDeadline(), for: r.id)
        objectWillChange.send()
    }

    /// 用找回短语解锁；给了新密码就先重设密码。
    func unlockWithRecovery(_ r: VaultRecord, phrase: String, newPassword: String?) async throws {
        if demo != nil { demo?.unlocked.insert(r.id); return }
        await prefetchKeyFiles(r)
        if let newPassword {
            try service.resetPassword(r, recoveryPhrase: phrase, new: newPassword)
        }
        try await unlock(r, with: .recoveryPhrase(phrase))
    }

    func lock(_ r: VaultRecord, force: Bool = false) async throws {
        if demo != nil { demo?.unlocked.remove(r.id); return }
        do {
            try await service.lock(r, force: force)
        } catch let error where force && AppModel.isUnsyncedLockFailure(error) {
            // VaultService 已删钥匙、按上锁处理（扩展从此拒绝访问），没写回的改动留在域里，下次解锁时继续写回。
            _ = error
            alertMessage = String(localized: "“\(r.name)” is locked, but some recent changes from the Files app couldn't be saved into it yet. They'll be saved the next time you unlock this vault. Until then, copies of those files remain on this iPhone.")
        }
        AutoLock.setUntil(nil, for: r.id)
        objectWillChange.send()
    }

    private static func isUnsyncedLockFailure(_ error: Error) -> Bool {
        switch error {
        case FileProviderPresenter.Failure.unsyncedChanges, FileProviderPresenter.Failure.unsavedChangesPreserved: return true
        default: return false
        }
    }

    /// 界面上的"上锁"：普通上锁失败时问用户要不要强制。
    func userLock(_ r: VaultRecord) async {
        do { try await lock(r) } catch { lockFailure = r }
    }

    func lockAll(force: Bool = true) async {
        for r in records where isUnlocked(r) {
            do { try await lock(r, force: force) } catch { alertMessage = "\(r.name): \(ErrorText.message(for: error))" }
        }
    }

    // MARK: 钥匙管理

    func changePassword(_ r: VaultRecord, current: String, new: String) async throws {
        if demo != nil { return }
        await prefetchKeyFiles(r)
        try service.changePassword(r, current: current, new: new)
    }

    func regeneratePhrase(_ r: VaultRecord, password: String) async throws -> RecoveryPhrase {
        if demo != nil { throw DemoError.notInDemo }
        await prefetchKeyFiles(r)
        return try service.regenerateRecoveryPhrase(r, password: password)
    }

    func resetPassword(_ r: VaultRecord, phrase: String, new: String) async throws {
        if demo != nil { return }
        await prefetchKeyFiles(r)
        try service.resetPassword(r, recoveryPhrase: phrase, new: new)
    }

    func enableBiometrics(_ r: VaultRecord, password: String) async throws {
        if demo != nil { demo?.biometrics.insert(r.id); refreshBiometrics(); return }
        await prefetchKeyFiles(r)
        try service.enableBiometrics(r, password: password)
        refreshBiometrics()
    }

    func disableBiometrics(_ r: VaultRecord) {
        if demo != nil { demo?.biometrics.remove(r.id); refreshBiometrics(); return }
        service.disableBiometrics(r)
        refreshBiometrics()
    }

    /// iCloud 云盘里的钥匙文件可能还没下载：先协调读取一遍，让系统把它们下载下来。
    private func prefetchKeyFiles(_ r: VaultRecord) async {
        guard let url = r.resolveURL() else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        await VaultLocation.prefetch(["vault.cryptomator", "masterkey.cryptomator", "foldersafe/recovery.json", "foldersafe/extensions.json"], in: url)
    }

    // MARK: 自动上锁

    func setAutoLock(enabled: Bool) {
        AutoLock.isEnabled = enabled
        autoLockEnabled = enabled
        extendDeadlines()
    }

    func setAutoLock(minutes: Int) {
        AutoLock.minutes = minutes
        autoLockMinutes = minutes
        extendDeadlines()
    }

    /// 已解锁的 vault 期限重新从现在算起。
    func extendDeadlines() {
        guard demo == nil else { return }
        for r in records where isUnlocked(r) { AutoLock.setUntil(AutoLock.freshDeadline(), for: r.id) }
        objectWillChange.send()
    }

    /// 到期的上锁（扩展那边也会各自检查）。
    func enforceAutoLock() async {
        guard demo == nil else { return }
        let now = Date()
        for r in records where isUnlocked(r) && AutoLock.isExpired(r.id, now: now) {
            try? await lock(r, force: true)
        }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        guard demo == nil else { return }
        switch phase {
        case .active:
            Task {
                await enforceAutoLock()
                extendDeadlines()
                refreshBiometrics()
                startTimer()
            }
        case .background:
            timer = nil
            extendDeadlines()               // 离开 App 时开始计时
        default:
            break
        }
    }

    private func startTimer() {
        timer = Timer.publish(every: 15, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            guard let self else { return }
            Task { await self.enforceAutoLock() }
        }
    }
}

enum AppError: LocalizedError {
    case notAVault, alreadyAdded, biometricsInvalidated, filesLocationDisabled

    var errorDescription: String? {
        switch self {
        case .notAVault:
            return String(localized: "This folder isn't a vault. Choose the folder that contains the file “vault.cryptomator”.")
        case .alreadyAdded:
            return String(localized: "This vault is already in your list.")
        case .filesLocationDisabled:
            return String(localized: "FolderSafe is turned off in the Files app.")
        case .biometricsInvalidated:
            return String(localized: "Face ID unlock was turned off because the Face ID settings on this iPhone changed. Unlock with your password, then turn it on again in Vault Settings.")
        }
    }
}

enum DemoError: LocalizedError {
    case notInDemo
    var errorDescription: String? { "Not available in demo mode." }
}
