import FileProvider
import UniformTypeIdentifiers
import FolderSafeCore

/// FolderSafe 的 File Provider 扩展（macOS 与 iPhone 共用）：把一个已解锁的 vault 呈现成一个 File Provider 域。
///
/// - 每个已解锁的 vault 一个域，域 ID = vault ID（FileProviderPresenter 负责增删域）。
/// - 钥匙只从共享钥匙串（UnlockedKeyStore）拿，只放内存；没有钥匙（已上锁）或 iPhone 自动上锁时间已过，一律回 .notAuthenticated。
/// - vault 目录通过 VaultRecord 里的安全作用域书签访问。
/// - 明文只出现在系统要求的地方：系统的副本（macOS ~/Library/CloudStorage/…，iPhone 的 File Provider Storage）和
///   fetchContents 交给系统前的临时文件（域自己的临时目录，系统接手后挪走）。上锁时整个域删掉。
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    let domain: NSFileProviderDomain
    let vaultId: String
    private let lock = NSLock()
    private var current: (store: VaultStore, key: Data, url: URL, scoped: Bool)?
    private var watcher: VaultWatcher?
    private var lastRescan = Date.distantPast
    private var wasUnlocked = false

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        self.vaultId = domain.identifier.rawValue
        super.init()
    }

    func invalidate() { drop() }

    /// App 交接了新的 vault 访问权：下次请求重新打开。
    func resetSession() { drop() }

    /// XPC 服务（App 交接 vault 访问权用），整个扩展实例期间保持。
    private var _accessService: VaultAccessServiceSource?
    var accessService: VaultAccessServiceSource {
        lock.lock(); defer { lock.unlock() }
        if let s = _accessService { return s }
        let s = VaultAccessServiceSource(ext: self)
        _accessService = s
        return s
    }

    // MARK: - 会话（钥匙 / vault）

    #if DEBUG
    /// 单元测试用：绕过钥匙串 / App Group，直接给 VaultStore。
    static var testStoreProvider: ((NSFileProviderDomain) throws -> VaultStore)?
    #endif

    /// 当前可用的 VaultStore。已上锁（没有钥匙或已过自动上锁时间）时抛 .notAuthenticated。
    func store() throws -> VaultStore {
        #if DEBUG
        if let p = Self.testStoreProvider { return try p(domain) }
        #endif
        if let until = SharedConfig.defaults.object(forKey: FileProviderPresenter.unlockedUntilKey(vaultId)) as? Date, until < Date() {
            // iPhone 自动上锁时间到了：删钥匙、丢掉内存里的 vault，尽量把已下载的明文副本清掉
            UnlockedKeyStore.remove(vaultId: vaultId)
            expireOnce()
            throw NSFileProviderError(.notAuthenticated)
        }
        guard let key = UnlockedKeyStore.get(vaultId: vaultId) else {
            drop()
            throw NSFileProviderError(.notAuthenticated)
        }
        lock.lock()
        defer { lock.unlock() }
        if let c = current, c.key == key { return c.store }
        dropLocked()
        guard let record = VaultRegistry.record(id: vaultId) else {
            throw NSFileProviderError(.notAuthenticated)
        }
        // vault 目录：先用 App 经 XPC 交接后扩展自己建的书签（macOS 必需），再试 App 登记的书签 / 路径
        var candidates: [URL] = []
        if let bm = SharedConfig.defaults.data(forKey: FileProviderPresenter.extensionBookmarkKey(vaultId)) {
            var stale = false
            #if os(macOS)
            let opts: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
            #else
            let opts: URL.BookmarkResolutionOptions = []
            #endif
            if let u = try? URL(resolvingBookmarkData: bm, options: opts, relativeTo: nil, bookmarkDataIsStale: &stale) { candidates.append(u) }
        }
        if let u = FileProviderPresenter.resolveVaultURL(record) { candidates.append(u) }
        var opened: (Vault, URL, Bool)?
        for url in candidates {
            let scoped = url.startAccessingSecurityScopedResource()
            if (try? Vault.vaultId(at: url)) == vaultId {
                do {
                    opened = (try Vault.open(at: url, rawKey: key), url, scoped)
                    break
                } catch {
                    if scoped { url.stopAccessingSecurityScopedResource() }
                    NSLog("FolderSafe FP: cannot open vault %@: %@", vaultId, String(describing: error))
                    throw NSFileProviderError(.notAuthenticated)        // 钥匙不对
                }
            }
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        guard let (vault, url, scoped) = opened else {
            NSLog("FolderSafe FP: vault %@ not reachable from the extension (%d candidate locations)", vaultId, candidates.count)
            throw NSFileProviderError(.serverUnreachable)
        }
        let index = ItemIndex(fileURL: FileProviderPresenter.indexFile(vaultId), rawKey: key, vaultId: vaultId)
        let store = VaultStore(vault: vault, index: index)
        store.onExternalChange = { [weak self] in self?.signalWorkingSet() }
        current = (store, key, url, scoped)
        wasUnlocked = true
        watcher = VaultWatcher(root: url) { [weak self] in
            guard let self, (try? self.store()) != nil else { return }
            _ = self.rescanIfDue(force: true)
        }
        return store
    }

    private func drop() {
        lock.lock()
        dropLocked()
        lock.unlock()
    }

    private func dropLocked() {
        watcher?.stop()
        watcher = nil
        if let c = current, c.scoped { c.url.stopAccessingSecurityScopedResource() }
        current = nil
    }

    private func expireOnce() {
        lock.lock()
        let had = wasUnlocked || current != nil
        wasUnlocked = false
        dropLocked()
        lock.unlock()
        guard had, let m = NSFileProviderManager(for: domain) else { return }
        m.evictItem(identifier: .rootContainer) { _ in }      // 有未上传改动的条目系统不会清（不丢数据）
    }

    /// 重扫 vault 找外部变化（网盘同步等）。force 也至少间隔 1 秒，否则 5 秒。
    func rescanIfDue(force: Bool) -> Bool {
        lock.lock()
        let due = Date().timeIntervalSince(lastRescan) > (force ? 1 : 5)
        if due { lastRescan = Date() }
        lock.unlock()
        guard due, let store = try? store() else { return false }
        return store.rescan()
    }

    private func signalWorkingSet() {
        NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet) { _ in }
    }

    private func temporaryFile() -> URL {
        let dir = (try? NSFileProviderManager(for: domain)?.temporaryDirectoryURL()) ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("fs-" + UUID().uuidString)
    }

    static func nsError(_ error: Error) -> NSError {
        if let e = error as? StoreError {
            switch e {
            case .noSuchItem: return NSFileProviderError(.noSuchItem) as NSError
            case .collision: return NSFileProviderError(.filenameCollision) as NSError
            case .directoryNotEmpty: return NSFileProviderError(.directoryNotEmpty) as NSError
            case .readOnly: return NSError(domain: NSCocoaErrorDomain, code: NSFileWriteVolumeReadOnlyError)
            case .invalidName: return NSError(domain: NSCocoaErrorDomain, code: NSFileWriteInvalidFileNameError)
            case .deletionRejected: return NSFileProviderError(.deletionRejected) as NSError
            case .syncAnchorExpired: return NSFileProviderError(.syncAnchorExpired) as NSError
            }
        }
        if let e = error as? VaultError {
            if case .io = e { return NSError(domain: NSPOSIXErrorDomain, code: Int(e.posixCode)) }
            return NSError(domain: NSPOSIXErrorDomain, code: Int(e.posixCode), userInfo: [NSDebugDescriptionErrorKey: "\(e)"])
        }
        return error as NSError
    }

    /// 在后台执行一个请求，返回系统要的 Progress。
    private func run(_ body: @escaping () -> Void) -> Progress {
        let p = Progress(totalUnitCount: 1)
        DispatchQueue.global(qos: .userInitiated).async {
            body()
            p.completedUnitCount = 1
        }
        return p
    }

    // MARK: - NSFileProviderReplicatedExtension

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        run { [self] in
            do {
                guard identifier != .trashContainer, identifier != .workingSet else { throw StoreError.noSuchItem }
                completionHandler(FileProviderItem(try store().item(identifier.storeID)), nil)
            } catch let e as NSError where identifier == .rootContainer && e.domain == NSFileProviderErrorDomain
                        && e.code == NSFileProviderError.serverUnreachable.rawValue {
                // vault 暂时够不着（App 还没交接访问权）：根目录照样给出来，XPC 服务才能挂在它上面
                completionHandler(FileProviderItem(ItemInfo(id: ItemIndex.rootDirId, parent: ItemIndex.rootDirId, name: "", kind: .directory,
                    size: 0, modified: Date(timeIntervalSince1970: 0), created: Date(timeIntervalSince1970: 0), symlinkTarget: nil,
                    contentVersion: Data("d".utf8), metadataVersion: Data("root".utf8), readOnly: false)), nil)
            } catch { completionHandler(nil, Self.nsError(error)) }
        }
    }

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest, completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        run { [self] in
            let tmp = temporaryFile()
            do {
                let info = try store().export(itemIdentifier.storeID, to: tmp)
                completionHandler(tmp, FileProviderItem(info), nil)
            } catch {
                try? FileManager.default.removeItem(at: tmp)
                completionHandler(nil, nil, Self.nsError(error))
            }
        }
    }

    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        run { [self] in
            do {
                let store = try store()
                let name = itemTemplate.filename
                // Finder 的 .DS_Store 只留在本机副本里，不写进 vault
                if name == ".DS_Store" {
                    return completionHandler(nil, [], false, NSFileProviderError(.excludedFromSync))
                }
                let parent = itemTemplate.parentItemIdentifier
                guard parent != .trashContainer else { throw StoreError.noSuchItem }
                let type = itemTemplate.contentType ?? .data
                let kind: ItemIndex.Kind = type.conforms(to: .symbolicLink) ? .symlink
                    : type.conforms(to: .directory) ? .directory : .file
                let modified = fields.contains(.contentModificationDate) ? (itemTemplate.contentModificationDate ?? nil) : nil
                let r = try store.createItem(parent: parent.storeID, name: name, kind: kind,
                                             contents: kind == .file && fields.contains(.contents) ? url : nil,
                                             symlinkTarget: itemTemplate.symlinkTargetPath ?? nil, modified: modified,
                                             mayAlreadyExist: options.contains(.mayAlreadyExist))
                // 同名文件已在且内容不同：本地内容已另存为冲突副本，让系统重新取 vault 里的版本
                completionHandler(FileProviderItem(r.info), [], r.conflictCopySaved, nil)
                if r.conflictCopySaved { signalWorkingSet() }
            } catch StoreError.collision(let existing) {
                completionHandler(nil, [], false, collisionError(existing))
            } catch {
                completionHandler(nil, [], false, Self.nsError(error))
            }
        }
    }

    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion, changedFields: NSFileProviderItemFields,
                    contents newContents: URL?, options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        run { [self] in
            do {
                let store = try store()
                let newParent = changedFields.contains(.parentItemIdentifier) ? item.parentItemIdentifier : nil
                guard newParent != .trashContainer else { throw StoreError.noSuchItem }      // 不支持废纸篓
                let modified = changedFields.contains(.contentModificationDate) ? (item.contentModificationDate ?? nil) : nil
                let r = try store.modify(item.itemIdentifier.storeID, newParent: newParent?.storeID,
                                         newName: changedFields.contains(.filename) ? item.filename : nil,
                                         contents: newContents, replaceContents: changedFields.contains(.contents),
                                         modified: modified, baseContentVersion: version.contentVersion)
                // 冲突时本地改动已另存为冲突副本，让系统重新取 vault 里的版本
                completionHandler(FileProviderItem(r.info), [], r.conflictCopySaved, nil)
                if r.conflictCopySaved { signalWorkingSet() }
            } catch StoreError.collision(let existing) {
                completionHandler(nil, [], false, collisionError(existing))
            } catch {
                completionHandler(nil, [], false, Self.nsError(error))
            }
        }
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        run { [self] in
            do {
                try store().delete(identifier.storeID, recursive: options.contains(.recursive),
                                   baseContentVersion: version.contentVersion)
                completionHandler(nil)
            } catch { completionHandler(Self.nsError(error)) }
        }
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        _ = try store()
        switch containerItemIdentifier {
        case .workingSet: return FileProviderEnumerator(ext: self, dirId: nil)
        case .trashContainer: throw NSFileProviderError(.noSuchItem)
        default:
            guard !ItemIndex.isFileID(containerItemIdentifier.rawValue) else { throw NSFileProviderError(.noSuchItem) }
            return FileProviderEnumerator(ext: self, dirId: containerItemIdentifier.storeID)
        }
    }

    private func collisionError(_ existing: String?) -> Error {
        if let existing, let info = try? store().item(existing) {
            return NSError.fileProviderErrorForCollision(with: FileProviderItem(info))
        }
        return NSFileProviderError(.filenameCollision)
    }
}
