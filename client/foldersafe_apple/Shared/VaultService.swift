import Foundation
import FolderSafeCore

/// mac 与 iPhone 共用的业务层：界面只调用这里，不直接碰钥匙串和呈现层。
/// 解锁 = 验证钥匙 → rawKey 放进 UnlockedKeyStore → presenter.present；上锁 = presenter.dismiss → 删钥匙。
@MainActor
public final class VaultService: ObservableObject {
    @Published public private(set) var records: [VaultRecord] = []
    /// 已解锁的 vault：ID → 用户能打开的位置（挂载点 / File Provider 根目录）
    @Published public private(set) var unlocked: [String: URL] = [:]
    @Published public var lastError: String?

    public let presenter: VaultPresenter

    public init(presenter: VaultPresenter) {
        self.presenter = presenter
        reload()
        #if os(iOS)
        // iPhone：App 随时可能在后台被系统杀掉，那不等于用户上锁。还在自动上锁期限（unlockedUntil）内、钥匙也还在的
        // vault 照旧算解锁（扩展一直在按期限把关），其余残留钥匙清掉。
        var restored: [VaultRecord] = []
        for r in records {
            let until = SharedConfig.defaults.object(forKey: FileProviderPresenter.unlockedUntilKey(r.id)) as? Date
            if let until, until > Date(), UnlockedKeyStore.get(vaultId: r.id) != nil {
                unlocked[r.id] = URL(string: "shareddocuments://")!       // 占位，下面重新呈现后换成真实位置
                restored.append(r)
            } else {
                UnlockedKeyStore.remove(vaultId: r.id)
            }
        }
        if !restored.isEmpty { Task { await self.represent(restored) } }
        #else
        // 上次异常退出时可能残留钥匙：启动时一律清掉，保证"没在界面上解锁 = 锁着"
        for r in records { UnlockedKeyStore.remove(vaultId: r.id) }
        #endif
    }

    #if os(iOS)
    /// 重启后恢复的 vault 重新呈现一次（交接访问权、让扩展重试之前失败的请求、拿到真实位置）；呈现失败就按上锁处理。
    private func represent(_ list: [VaultRecord]) async {
        for r in list where unlocked[r.id] != nil {
            do {
                let url = try await presenter.present(r)
                if unlocked[r.id] != nil {
                    unlocked[r.id] = url
                } else {
                    try? await presenter.dismiss(r, force: true)     // 呈现期间已被上锁：present 可能又把位置加了回来
                }
            } catch {
                guard unlocked[r.id] != nil else { continue }
                UnlockedKeyStore.remove(vaultId: r.id)
                SharedConfig.defaults.removeObject(forKey: FileProviderPresenter.unlockedUntilKey(r.id))
                unlocked[r.id] = nil
                lastError = "\(r.name): \(error.localizedDescription)"
            }
        }
    }
    #endif

    public func reload() { records = VaultRegistry.all().sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }

    public func isUnlocked(_ r: VaultRecord) -> Bool { unlocked[r.id] != nil }

    // MARK: 建库 / 添加

    /// 在 directory 新建 vault（目录必须不存在或为空）。返回找回短语，界面必须让用户抄写并抽查。
    /// directory 若是沙盒外的位置，调用方负责传入已 startAccessing 的 URL，并给出可持久的 bookmark。
    public func create(name: String, directory: URL, password: String, bookmark: Data?, mountPoint: String? = nil) throws -> (VaultRecord, RecoveryPhrase) {
        let (vault, phrase) = try Vault.create(at: directory, password: password)
        let r = VaultRecord(id: vault.config.vaultId, name: name, path: directory.path, bookmark: bookmark, mountPoint: mountPoint)
        VaultRegistry.upsert(r)
        reload()
        return (r, phrase)
    }

    /// 添加已有的 vault（FolderSafe 或 Cryptomator 建的）：只登记，不需要密码。
    public func add(existing directory: URL, name: String, bookmark: Data?, mountPoint: String? = nil) throws -> VaultRecord {
        let id = try Vault.vaultId(at: directory)
        let r = VaultRecord(id: id, name: name, path: directory.path, bookmark: bookmark, mountPoint: mountPoint)
        VaultRegistry.upsert(r)
        reload()
        return r
    }

    /// 从清单里移除（不删除任何文件）。先强制上锁（也撤下上次没撤成、还留着没写回改动的位置 / 挂载）：
    /// 撤不下来就不移除并返回原因——否则那个位置和里面没写回的改动就再也没法从界面处理了。
    /// 返回 nil = 已移除；返回 unsavedChangesPreserved 时也已移除（界面要把保留文件的位置告诉用户）。
    @discardableResult
    public func forget(_ r: VaultRecord) async -> Error? {
        var preserved: Error?
        do {
            try await lock(r, force: true)
        } catch FileProviderPresenter.Failure.unsavedChangesPreserved(let url) {
            preserved = FileProviderPresenter.Failure.unsavedChangesPreserved(url)
        } catch {
            return error
        }
        UnlockedKeyStore.remove(vaultId: r.id)
        DeviceKeyStore.disable(vaultId: r.id)
        VaultRegistry.remove(id: r.id)
        reload()
        return preserved
    }

    public func update(_ r: VaultRecord) {
        VaultRegistry.upsert(r)
        reload()
    }

    // MARK: 解锁

    public enum Secret {
        case password(String)
        case recoveryPhrase(String)
        case biometrics(reason: String)
    }

    /// 解锁并呈现。返回用户能打开的位置。
    @discardableResult
    public func unlock(_ r: VaultRecord, with secret: Secret) async throws -> URL {
        let vault = try withVaultDirectory(r) { dir -> Vault in
            switch secret {
            case .password(let p): return try Vault.open(at: dir, password: p)
            case .recoveryPhrase(let p): return try Vault.open(at: dir, recoveryPhrase: p)
            case .biometrics(let reason): return try Vault.open(at: dir, rawKey: try DeviceKeyStore.read(vaultId: r.id, reason: reason))
            }
        }
        try UnlockedKeyStore.put(vault.masterkey.raw, vaultId: r.id)
        do {
            let url = try await presenter.present(r)
            unlocked[r.id] = url
            var rec = r
            rec.lastOpened = Date()
            VaultRegistry.upsert(rec)
            reload()
            return url
        } catch {
            UnlockedKeyStore.remove(vaultId: r.id)
            throw error
        }
    }

    // MARK: 上锁

    /// 上锁。非强制时撤不下来（有程序占用 / 还有改动没写回）就保持解锁并抛错，让界面问用户要不要强制。
    /// 强制（自动上锁、用户确认）时钥匙一定删掉、界面一定显示上锁：
    /// - unsavedChangesPreserved（macOS）：域已撤下，没写回的文件被系统保留在别处，照样抛给界面提示。
    /// - unsyncedChanges（iPhone 系统不支持保留）：为了不丢改动，域留着不删；钥匙删掉后扩展拒绝一切访问，
    ///   下次解锁时继续写回。照样抛给界面提示（那些文件的副本还留在本机）。
    public func lock(_ r: VaultRecord, force: Bool = false) async throws {
        do {
            try await presenter.dismiss(r, force: force)
        } catch FileProviderPresenter.Failure.unsavedChangesPreserved(let url) {
            // 已经撤下了，只是没写回的文件被系统保留在 url：照样算上锁，再把情况报给界面
            UnlockedKeyStore.remove(vaultId: r.id)
            unlocked[r.id] = nil
            throw FileProviderPresenter.Failure.unsavedChangesPreserved(url)
        } catch FileProviderPresenter.Failure.unsyncedChanges where force {
            UnlockedKeyStore.remove(vaultId: r.id)
            unlocked[r.id] = nil
            // 让扩展马上来一次请求：发现钥匙没了就丢掉内存里的 vault（否则要等下次访问或进程被回收）
            if let fp = presenter as? FileProviderPresenter { await fp.refresh(r) }
            throw FileProviderPresenter.Failure.unsyncedChanges
        }
        UnlockedKeyStore.remove(vaultId: r.id)
        unlocked[r.id] = nil
    }

    /// 退出时来不及正常上锁的兜底：删掉全部解锁钥匙（扩展从此拒绝访问；还挂着的位置下次启动时撤下）。
    public func removeAllUnlockedKeys() {
        for r in records { UnlockedKeyStore.remove(vaultId: r.id) }
        unlocked = [:]
    }

    /// 自动上锁（睡眠、锁屏、闲置、退出）：强制上锁全部，失败的记下来。
    public func lockAll(force: Bool = true) async {
        for r in records where isUnlocked(r) {
            do { try await lock(r, force: force) } catch { lastError = "\(r.name): \(error.localizedDescription)" }
        }
    }

    // MARK: 钥匙管理（需要已经能证明身份：传当前密码）

    public func changePassword(_ r: VaultRecord, current: String, new: String) throws {
        try withVaultDirectory(r) { dir in try Vault.open(at: dir, password: current).changePassword(to: new) }
    }

    /// 重新生成找回短语（旧短语立即失效）。
    public func regenerateRecoveryPhrase(_ r: VaultRecord, password: String) throws -> RecoveryPhrase {
        try withVaultDirectory(r) { dir in try Vault.open(at: dir, password: password).enableRecovery() }
    }

    /// 用找回短语重设密码。
    public func resetPassword(_ r: VaultRecord, recoveryPhrase: String, new: String) throws {
        try withVaultDirectory(r) { dir in try Vault.open(at: dir, recoveryPhrase: recoveryPhrase).changePassword(to: new) }
    }

    public func enableBiometrics(_ r: VaultRecord, password: String) throws {
        let key = try withVaultDirectory(r) { dir in try Vault.open(at: dir, password: password).masterkey.raw }
        try DeviceKeyStore.enable(key, vaultId: r.id)
    }

    public func disableBiometrics(_ r: VaultRecord) { DeviceKeyStore.disable(vaultId: r.id) }

    public func biometricsEnabled(_ r: VaultRecord) -> Bool { DeviceKeyStore.isEnabled(vaultId: r.id) }

    // MARK: 工具

    /// 在安全作用域内访问 vault 目录。
    public func withVaultDirectory<T>(_ r: VaultRecord, _ body: (URL) throws -> T) throws -> T {
        guard let url = r.resolveURL() else { throw VaultError.notFound(r.path) }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try body(url)
    }
}
