import Foundation
import CryptoKit
import FolderSafeCore

/// 一个条目当前的样子（交给 FileProviderItem 呈现）。根目录的 id 是 ""。
struct ItemInfo: Equatable {
    var id: String
    var parent: String              // 父目录 ID（根的父是自己 ""）
    var name: String
    var kind: ItemIndex.Kind
    var size: Int
    var modified: Date
    var created: Date
    var symlinkTarget: String?
    var contentVersion: Data
    var metadataVersion: Data
    var readOnly: Bool
    var isRoot: Bool { id == ItemIndex.rootDirId }
    var versionKey: String { contentVersion.base64EncodedString() + "|" + metadataVersion.base64EncodedString() }
}

enum StoreError: Error, Equatable {
    case noSuchItem
    case collision(existing: String?)        // 已存在的条目 ID
    case directoryNotEmpty
    case readOnly
    case invalidName
    case deletionRejected                     // 要删的条目在别处被改过：拒绝删除，让系统重新拿新内容
    case syncAnchorExpired
}

/// File Provider 扩展的后端：在 FolderSafeCore 的 Vault 之上维护条目 ID，做增删改查和外部变化检测。
/// 不依赖 FileProvider 框架，方便单独测试。线程安全：表的读写和所有写操作在一把锁里；导出（解密到临时文件）在锁外并发进行。
final class VaultStore {
    let vault: Vault
    let index: ItemIndex
    private let lock = NSRecursiveLock()
    /// 重扫发现外部变化后调用（在调用方线程，锁外）。
    var onExternalChange: (() -> Void)?

    init(vault: Vault, index: ItemIndex) {
        self.vault = vault
        self.index = index
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    var readOnly: Bool { vault.isReadOnly }

    // MARK: - 查

    func item(_ id: String) throws -> ItemInfo {
        try locked {
            if id == ItemIndex.rootDirId { return try rootInfo() }
            let (parent, entry) = try locate(id)
            return try info(id, entry, parent: parent)
        }
    }

    /// 列目录（顺便和表对账：新条目分配 ID，消失的条目从表里去掉；目录已经报给过系统的，记成外部变化）。
    func list(_ dirId: String) throws -> [ItemInfo] {
        try locked {
            if dirId != ItemIndex.rootDirId {
                guard let e = index.entry(dirId) ?? findDirectory(dirId), e.kind == .directory else { throw StoreError.noSuchItem }
            }
            guard vault.directoryExists(id: dirId) else { throw StoreError.noSuchItem }
            let entries = try mapVault { try vault.contentsOfDirectory(id: dirId) }
            let infos = reconcile(dirId, entries, record: index.isListed(dirId: dirId))
            index.markListed(dirId: dirId)
            try? index.saveIfNeeded()
            return infos
        }
    }

    /// 系统已知的所有条目（工作集）。
    func knownItems() -> [ItemInfo] {
        locked {
            index.allIDs.compactMap { id in
                guard let e = index.entry(id) else { return nil }
                return try? info(id, e, parent: e.parent)
            }
        }
    }

    // MARK: - 读内容

    /// 解密到 destination（流式）。返回导出时的条目信息。
    func export(_ id: String, to destination: URL) throws -> ItemInfo {
        let (parent, name) = try locked { () -> (String, String) in
            let (parent, e) = try locate(id)
            guard e.kind == .file else { throw StoreError.noSuchItem }
            return (parent, e.name)
        }
        try mapVault { try vault.exportFile(name, inDirectory: parent, to: destination) }
        return try item(id)
    }

    // MARK: - 写

    func create(parent: String, name rawName: String, kind: ItemIndex.Kind, contents: URL?, symlinkTarget: String?,
                modified: Date?, mayAlreadyExist: Bool) throws -> ItemInfo {
        try createItem(parent: parent, name: rawName, kind: kind, contents: contents, symlinkTarget: symlinkTarget,
                       modified: modified, mayAlreadyExist: mayAlreadyExist).info
    }

    /// 新建。mayAlreadyExist（系统重建数据库 / 重新导入时）且同名文件已在：内容相同就沿用；
    /// 不同就不覆盖 vault 里的版本（可能是别处更新的），新内容另存为冲突副本（conflictCopySaved = true，系统应重新取内容）。
    func createItem(parent: String, name rawName: String, kind: ItemIndex.Kind, contents: URL?, symlinkTarget: String?,
                    modified: Date?, mayAlreadyExist: Bool) throws -> (info: ItemInfo, conflictCopySaved: Bool) {
        try locked {
            var conflict = false
            guard !readOnly else { throw StoreError.readOnly }
            let name = rawName.precomposedStringWithCanonicalMapping
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { throw StoreError.invalidName }
            if parent != ItemIndex.rootDirId, index.entry(parent) == nil, findDirectory(parent) == nil { throw StoreError.noSuchItem }
            guard vault.directoryExists(id: parent) else { throw StoreError.noSuchItem }
            if let existing = try mapVault({ try vault.lookup(name, inDirectory: parent) }) {
                let id = identify(existing)
                guard mayAlreadyExist, kindOf(existing) == kind else { throw StoreError.collision(existing: id) }
                if kind == .file, let contents, !sameContents(name, in: parent, as: contents) {
                    try saveConflictCopy(of: name, in: parent, from: contents)
                    conflict = true
                }
            } else {
                try mapVault {
                    switch kind {
                    case .file:
                        if let contents { try vault.importFile(name, inDirectory: parent, from: contents) }
                        else { try vault.writeFile(name, inDirectory: parent, data: Data()) }
                    case .directory: try vault.createDirectory(name, inDirectory: parent)
                    case .symlink: try vault.createSymlink(name, inDirectory: parent, target: symlinkTarget ?? "")
                    }
                }
            }
            if let modified, !conflict { try? vault.setModificationDate(modified, of: name, inDirectory: parent) }
            guard let e = try mapVault({ try vault.lookup(name, inDirectory: parent) }) else { throw StoreError.noSuchItem }
            let id = identify(e)
            let info = try info(id, e, parent: parent)
            index.put(id, .init(parent: parent, name: e.name, kind: kind, version: info.versionKey,
                                listed: kind == .directory ? (index.entry(id)?.listed ?? true) : false))
            try? index.saveIfNeeded()
            return (info, conflict)
        }
    }

    /// 改名 / 移动、替换内容、改修改时间。
    /// baseContentVersion：系统改动所基于的内容版本。替换内容时如果 vault 里的内容已经被别处改过，
    /// 不覆盖它：新内容另存为"冲突副本"，原条目保持 vault 里的版本（两份都不丢）。
    func modify(_ id: String, newParent: String?, newName: String?, contents: URL?, replaceContents: Bool,
                modified: Date?, baseContentVersion: Data?) throws -> (info: ItemInfo, conflictCopySaved: Bool) {
        try locked {
            var conflict = false
            guard !readOnly else { throw StoreError.readOnly }
            guard id != ItemIndex.rootDirId else { return (try rootInfo(), false) }
            var (parent, e) = try locate(id)
            var name = e.name
            let targetParent = newParent ?? parent
            let targetName = (newName ?? name).precomposedStringWithCanonicalMapping
            if targetParent != parent || targetName != name {
                if targetParent != ItemIndex.rootDirId, index.entry(targetParent) == nil, findDirectory(targetParent) == nil {
                    throw StoreError.noSuchItem
                }
                if e.kind == .directory, targetParent == id || index.isDirectory(targetParent, inside: id) { throw StoreError.invalidName }
                do {
                    try mapVault { try vault.move(name, inDirectory: parent, to: targetName, inDirectory: targetParent) }
                } catch StoreError.collision {
                    let clash = try? vault.lookup(targetName, inDirectory: targetParent)
                    throw StoreError.collision(existing: clash.map(identify))
                }
                parent = targetParent
                name = targetName
                e.parent = parent
                e.name = name
                index.put(id, e)
            }
            if replaceContents, e.kind == .file {
                let current = try info(id, e, parent: parent)
                if let base = baseContentVersion, base != current.contentVersion, let contents {
                    try saveConflictCopy(of: name, in: parent, from: contents)
                    conflict = true
                } else if let contents {
                    try mapVault { try vault.importFile(name, inDirectory: parent, from: contents) }
                }
                // 没给新内容（系统不该这样调用）：不当成"清空"，原内容不动
            }
            if let modified, !conflict { try? vault.setModificationDate(modified, of: name, inDirectory: parent) }
            let info = try info(id, e, parent: parent)
            e.version = info.versionKey
            index.put(id, e)
            try? index.saveIfNeeded()
            return (info, conflict)
        }
    }

    /// 删除（目录递归）。条目已经不在了算成功。
    func delete(_ id: String, recursive: Bool, baseContentVersion: Data?) throws {
        try locked {
            guard !readOnly else { throw StoreError.readOnly }
            guard id != ItemIndex.rootDirId else { throw StoreError.invalidName }
            let parent: String, e: ItemIndex.Entry
            do { (parent, e) = try locate(id) } catch StoreError.noSuchItem { return }
            if e.kind == .file, let base = baseContentVersion, let cur = try? info(id, e, parent: parent), cur.contentVersion != base {
                throw StoreError.deletionRejected
            }
            if e.kind == .directory, !recursive,
               !(try mapVault { try vault.contentsOfDirectory(id: id) }).isEmpty {
                throw StoreError.directoryNotEmpty
            }
            // 递归删目录：里面有系统还不知道的新条目 / 别处改过的文件（网盘刚同步来的）就拒绝，免得删掉用户没见过的内容
            if e.kind == .directory, recursive, hasUnseenChanges(id) { throw StoreError.deletionRejected }
            do { try mapVault { try vault.remove(e.name, inDirectory: parent) } } catch StoreError.noSuchItem {}
            index.removeSubtree(id)
            try? index.saveIfNeeded()
        }
    }

    // MARK: - 外部变化

    /// 重扫所有已报给系统的目录，把外部变化记进日志。有变化时返回 true（并调用 onExternalChange）。
    @discardableResult
    func rescan() -> Bool {
        let changed: Bool = locked {
            let before = index.generation
            for dir in index.listedDirectories {
                guard dir == ItemIndex.rootDirId || index.entry(dir) != nil else { continue }   // 上层重扫时已去掉
                guard vault.directoryExists(id: dir), let entries = try? vault.contentsOfDirectory(id: dir) else { continue }
                _ = reconcile(dir, entries, record: true)
            }
            try? index.saveIfNeeded()
            return index.generation != before
        }
        if changed { onExternalChange?() }
        return changed
    }

    var anchor: (epoch: String, generation: Int) { locked { (index.epoch, index.generation) } }

    /// 某代之后的变化：更新的条目、删掉的 ID。only 不为 nil 时只要该目录下的。
    func changes(after generation: Int, epoch: String, only parent: String? = nil) throws -> (updated: [ItemInfo], deleted: [String]) {
        try locked {
            guard epoch == index.epoch, generation >= index.oldestKnownGeneration, generation <= index.generation else {
                throw StoreError.syncAnchorExpired
            }
            var last: [String: ItemIndex.Change] = [:]
            for c in index.changes(after: generation) where parent == nil || c.parent == parent { last[c.id] = c }
            var updated: [ItemInfo] = [], deleted: [String] = []
            for (id, c) in last.sorted(by: { $0.value.generation < $1.value.generation }) {
                if !c.deleted, let i = try? item(id) { updated.append(i) } else { deleted.append(id) }
            }
            return (updated, deleted)
        }
    }

    // MARK: - 内部

    private func rootInfo() throws -> ItemInfo {
        let a = try mapVault { try vault.attributes(ofDirectory: ItemIndex.rootDirId) }
        return ItemInfo(id: ItemIndex.rootDirId, parent: ItemIndex.rootDirId, name: "", kind: .directory, size: 0,
                        modified: a.modificationDate, created: a.creationDate, symlinkTarget: nil,
                        contentVersion: Data("d".utf8), metadataVersion: Data("root".utf8), readOnly: readOnly)
    }

    /// 条目 ID → （父目录 ID，表项）。核对 vault 里确实还在；目录不在表里时从 vault 重建。
    private func locate(_ id: String) throws -> (String, ItemIndex.Entry) {
        guard var e = index.entry(id) ?? findDirectory(id) else { throw StoreError.noSuchItem }
        guard let v = try? vault.lookup(e.name, inDirectory: e.parent), kindOf(v) == e.kind,
              e.kind != .directory || v.directoryId == id else {
            // 位置变了（外部改名 / 移动）：目录还能凭目录 ID 找回来，文件只能当作没了
            index.removeSubtree(id)
            if e.kind == .directory, let found = findDirectory(id) { e = found; return (e.parent, e) }
            throw StoreError.noSuchItem
        }
        return (e.parent, e)
    }

    /// 在 vault 里按目录 ID 找目录（表丢了 / 外部移动后重建用）：从已知目录和根开始广度优先，找到的都记进表。
    private func findDirectory(_ dirId: String) -> ItemIndex.Entry? {
        guard !ItemIndex.isFileID(dirId), dirId != ItemIndex.rootDirId, vault.directoryExists(id: dirId) else { return nil }
        var queue = [ItemIndex.rootDirId]
        var seen = Set(queue)
        var visited = 0
        while !queue.isEmpty, visited < 20000 {
            let dir = queue.removeFirst()
            visited += 1
            guard let entries = try? vault.contentsOfDirectory(id: dir) else { continue }
            for v in entries where v.kind == .directory {
                guard let d = v.directoryId, !seen.contains(d) else { continue }
                seen.insert(d)
                if d == dirId {
                    let e = ItemIndex.Entry(parent: dir, name: v.name, kind: .directory, version: "", listed: false)
                    index.put(d, e)
                    return e
                }
                queue.append(d)
            }
        }
        return nil
    }

    /// 目录（及已列过的子目录）里有没有系统还没见过的变化：新条目、类型变了、文件版本和上次报给系统的不同。
    /// 没列过的目录系统本来就不知道里面有什么，删它就是要删整个目录，不算。
    private func hasUnseenChanges(_ dirId: String) -> Bool {
        guard index.isListed(dirId: dirId), let entries = try? vault.contentsOfDirectory(id: dirId) else { return false }
        for v in entries {
            guard let id = index.id(parent: dirId, name: v.name), let known = index.entry(id), known.kind == kindOf(v) else { return true }
            if let d = v.directoryId {
                if d != id || hasUnseenChanges(d) { return true }
            } else if let i = try? info(id, v, parent: dirId), i.versionKey != known.version {
                return true
            }
        }
        return false
    }

    /// vault 里的文件内容和 url 是否逐字节相同（流式比较）。
    private func sameContents(_ name: String, in parent: String, as url: URL) -> Bool {
        guard let f = try? vault.openFile(name, inDirectory: parent) else { return false }
        defer { try? f.close() }
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        var offset = 0
        while true {
            guard let a = try? f.read(at: offset, count: 1 << 20), let b = try? (h.read(upToCount: 1 << 20) ?? Data()) else { return false }
            guard a == b else { return false }
            if a.isEmpty { return true }
            offset += a.count
        }
    }

    private func kindOf(_ v: Vault.Entry) -> ItemIndex.Kind {
        switch v.kind { case .file: return .file; case .directory: return .directory; case .symlink: return .symlink }
    }

    /// vault 条目 → 条目 ID：目录用目录 ID；文件沿用表里同位置同类型的 ID，否则新分配。
    private func identify(_ v: Vault.Entry) -> String {
        if let d = v.directoryId { return d }
        if let id = index.id(parent: v.parentId, name: v.name), ItemIndex.isFileID(id), index.entry(id)?.kind == kindOf(v) { return id }
        return ItemIndex.newFileID()
    }

    private func reconcile(_ dirId: String, _ entries: [Vault.Entry], record: Bool) -> [ItemInfo] {
        var seen = Set<String>()
        var out: [ItemInfo] = []
        for v in entries {
            let id = identify(v)
            guard let info = try? info(id, v, parent: dirId) else { continue }
            let old = index.entry(id)
            let e = ItemIndex.Entry(parent: dirId, name: v.name, kind: kindOf(v), version: info.versionKey, listed: old?.listed ?? false)
            if old != e {
                index.put(id, e)
                if record { index.recordChange(id, deleted: false, parent: dirId) }
            }
            seen.insert(id)
            out.append(info)
        }
        for child in index.childIDs(dirId) where !seen.contains(child) {
            index.removeSubtree(child)
            if record { index.recordChange(child, deleted: true, parent: dirId) }
        }
        return out
    }

    private func info(_ id: String, _ e: ItemIndex.Entry, parent: String) throws -> ItemInfo {
        guard let v = try mapVault({ try vault.lookup(e.name, inDirectory: parent) }) else { throw StoreError.noSuchItem }
        return try info(id, v, parent: parent)
    }

    private func info(_ id: String, _ v: Vault.Entry, parent: String) throws -> ItemInfo {
        let a = v.attributes
        let kind = kindOf(v)
        let ms = { (d: Date) in Int64((d.timeIntervalSince1970 * 1000).rounded()) }
        var target: String?
        if kind == .symlink { target = try? vault.readSymlink(v.name, inDirectory: parent) }
        let content: String, meta: String
        switch kind {
        case .directory:
            content = "d"
            meta = parent + "/" + v.name
        case .file, .symlink:
            content = "\(a.size)|\(ms(a.modificationDate))" + (target.map { "|" + $0 } ?? "")
            meta = parent + "/" + v.name + "|\(ms(a.modificationDate))|\(ms(a.creationDate))"
        }
        return ItemInfo(id: id, parent: parent, name: v.name, kind: kind, size: kind == .directory ? 0 : a.size,
                        modified: a.modificationDate, created: a.creationDate, symlinkTarget: target,
                        contentVersion: Self.digest(content), metadataVersion: Self.digest(meta), readOnly: readOnly)
    }

    private static func digest(_ s: String) -> Data { Data(SHA256.hash(data: Data(s.utf8)).prefix(16)) }

    /// 新内容另存为"<名字> (冲突 yyyy-MM-dd HHmmss).<扩展名>"，不覆盖 vault 里已被别处改过的版本。
    private func saveConflictCopy(of name: String, in parent: String, from contents: URL) throws {
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty || name.hasPrefix(".") ? name : (name as NSString).deletingPathExtension
        let dotExt = ext.isEmpty || name.hasPrefix(".") ? "" : "." + ext
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmmss"
        let stamp = f.string(from: Date())
        for i in 0..<100 {
            let candidate = "\(base) (conflict \(stamp)\(i == 0 ? "" : " \(i)"))\(dotExt)"
            let taken = (try? vault.lookup(candidate, inDirectory: parent)).flatMap { $0 } != nil
            if taken { continue }
            try mapVault { try vault.importFile(candidate, inDirectory: parent, from: contents) }
            if index.isListed(dirId: parent), let v = try? vault.lookup(candidate, inDirectory: parent) {
                let id = ItemIndex.newFileID()
                if let i = try? info(id, v, parent: parent) {
                    index.put(id, .init(parent: parent, name: candidate, kind: .file, version: i.versionKey, listed: false))
                    index.recordChange(id, deleted: false, parent: parent)
                }
            }
            return
        }
        throw StoreError.collision(existing: nil)
    }

    /// FolderSafeCore 的错误 → StoreError（其余原样抛出）。
    private func mapVault<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch let e as VaultError {
            switch e {
            case .notFound: throw StoreError.noSuchItem
            case .alreadyExists: throw StoreError.collision(existing: nil)
            case .readOnly: throw StoreError.readOnly
            case .invalidName: throw StoreError.invalidName
            default: throw e
            }
        }
    }
}
