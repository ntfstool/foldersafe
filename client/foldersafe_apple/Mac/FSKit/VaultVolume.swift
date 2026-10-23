import Foundation
import FSKit
import FolderSafeCore

/// 一个已解锁 vault 的 FSKit 卷。
///
/// 条目身份：节点表 `nodes`（id → 父 id + 名字；目录另有 vault 目录 ID），`children`（父 id → NFC 名 → id）。
/// 同一路径在一次挂载内 id 不变；改名只改节点的父和名字，子孙不用动（vault 按目录 ID 寻址）。
/// 文件内容走内核的 VaultFile 句柄（按块随机读写），不整份解密。
/// 并发：卷的表和对 vault 的调用都在 `lock` 里串行（vault 自己也有锁，这里是为了表和 vault 的一致）。
final class VaultVolume: FSVolume {
    let vault: Vault
    let rootURL: URL
    private let lock = NSLock()

    static let rootID: UInt64 = FSItem.Identifier.rootDirectory.rawValue
    private var nextID: UInt64 = FSItem.Identifier.rootDirectory.rawValue + 1
    private var nodes: [UInt64: Node] = [:]
    private var children: [UInt64: [String: UInt64]] = [:]
    private var listings: [UInt64: Listing] = [:]
    private var verifiers: [UInt64: UInt64] = [:]
    private var live: [UInt64: VaultItem] = [:]
    private var contents: [UInt64: FileContent] = [:]
    private var idleCloserScheduled = false

    private let ownerUID: uid_t
    private let ownerGID: gid_t

    /// 别人（同步盘等）在挂载期间改了 vault 时，目录列表最多晚这么久看到。
    private let listingTTL: TimeInterval = 3
    /// 没被打开、却被写过 / 读过的句柄（内核延迟写回、mmap）空闲这么久后关闭（关闭即落盘）。
    private let idleClose: TimeInterval = 1
    static let maxXattrSize = 64 << 10
    static let maxXattrTotal = 256 << 10

    init(vault: Vault, rootURL: URL, volumeID: FSVolume.Identifier, name: String) {
        self.vault = vault
        self.rootURL = rootURL
        var st = stat()
        if stat(rootURL.path, &st) == 0 {
            ownerUID = st.st_uid
            ownerGID = st.st_gid
        } else {
            ownerUID = getuid()
            ownerGID = getgid()
        }
        super.init(volumeID: volumeID, volumeName: FSFileName(string: name))
        var root = Node(parent: FSItem.Identifier.parentOfRoot.rawValue, name: "", kind: .directory, dirId: Vault.rootDirectoryId,
                        mtime: .now, ctime: .now, atime: .now, birthtime: .now)
        if let a = try? vault.attributes(ofDirectory: Vault.rootDirectoryId) { root.update(a) }
        nodes[Self.rootID] = root
    }

    // MARK: - 锁与工具

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private static func key(_ name: String) -> String { name.precomposedStringWithCanonicalMapping }

    private func node(_ item: FSItem) throws -> (VaultItem, Node) {
        guard let it = item as? VaultItem, let n = nodes[it.id], !n.deleted else { throw POSIXFailure(ENOENT) }
        return (it, n)
    }

    private func dirNode(_ item: FSItem) throws -> (VaultItem, Node, String) {
        let (it, n) = try node(item)
        guard n.kind == .directory, let d = n.dirId else { throw POSIXFailure(ENOTDIR) }
        return (it, n, d)
    }

    /// 节点所在目录的 vault 目录 ID。
    private func parentDirId(_ n: Node) throws -> String {
        guard let p = nodes[n.parent], let d = p.dirId, !p.deleted else { throw POSIXFailure(ENOENT) }
        return d
    }

    private func liveItem(_ id: UInt64) -> VaultItem {
        if let it = live[id] { return it }
        let it = VaultItem(id: id)
        live[id] = it
        return it
    }

    private func bump(_ dir: UInt64) { verifiers[dir, default: 1] += 1 }

    private func checkName(_ name: FSFileName) throws -> String {
        guard let s = name.string, !s.isEmpty, s != ".", s != "..", !s.contains("/"), !s.contains("\0") else {
            throw POSIXFailure(EINVAL)
        }
        guard s.utf8.count <= 255 else { throw POSIXFailure(ENAMETOOLONG) }
        return s.precomposedStringWithCanonicalMapping
    }

    private func requireWritable() throws { if vault.isReadOnly { throw POSIXFailure(EROFS) } }

    // MARK: - 目录列表 / 查找

    @discardableResult
    private func listing(_ dir: UInt64, maxAge: TimeInterval? = nil) throws -> Listing {
        if let l = listings[dir], Date().timeIntervalSince(l.loadedAt) < (maxAge ?? listingTTL) { return l }
        guard let dn = nodes[dir], let dirId = dn.dirId else { throw POSIXFailure(ENOTDIR) }
        let entries = try vault.contentsOfDirectory(id: dirId)
        var index = children[dir] ?? [:]
        var seen = Set<UInt64>()
        var ids: [UInt64] = []
        ids.reserveCapacity(entries.count)
        var changed = listings[dir] == nil
        for e in entries {
            let id = remember(e, in: dir, index: &index)
            ids.append(id)
            seen.insert(id)
        }
        for (k, id) in index where !seen.contains(id) {   // 外部删掉的
            index[k] = nil
            forget(id)
            changed = true
        }
        if let old = listings[dir], old.ids.count != ids.count { changed = true }
        children[dir] = index
        ids.sort()
        let l = Listing(ids: ids, loadedAt: Date())
        listings[dir] = l
        if changed { bump(dir) }
        return l
    }

    /// 把 vault 里的一个条目登记进节点表（已有就刷新属性），返回 id。
    private func remember(_ e: Vault.Entry, in dir: UInt64, index: inout [String: UInt64]) -> UInt64 {
        let k = Self.key(e.name)
        if let id = index[k], var n = nodes[id], !n.deleted, n.kind == e.kind,
           n.kind != .directory || n.dirId == e.attributes.directoryId {
            if contents[id] == nil || e.kind != .file { n.update(e.attributes) }
            n.name = e.name
            nodes[id] = n
            return id
        }
        if let old = index[k] { forget(old) }
        let id = nextID
        nextID += 1
        nodes[id] = Node(parent: dir, entry: e)
        index[k] = id
        return id
    }

    /// 查子项：目录列表新鲜就直接用，否则只查这一个名字（大目录也快）。
    private func child(_ dir: UInt64, _ name: String) throws -> UInt64? {
        let k = Self.key(name)
        if let l = listings[dir], Date().timeIntervalSince(l.loadedAt) < listingTTL { return children[dir]?[k] }
        guard let dirId = nodes[dir]?.dirId else { throw POSIXFailure(ENOTDIR) }
        guard let e = try vault.lookup(k, inDirectory: dirId) else {
            if let old = children[dir]?[k] { detach(old); forget(old) }
            return nil
        }
        var index = children[dir] ?? [:]
        let had = index[k]
        let id = remember(e, in: dir, index: &index)
        children[dir] = index
        if had != id, var l = listings[dir] {          // 列表虽旧也保持一致：枚举时不漏
            if let h = had, let i = l.ids.firstIndex(of: h) { l.ids.remove(at: i) }
            l.ids.insert(id, at: l.ids.firstIndex { $0 > id } ?? l.ids.count)
            listings[dir] = l
            bump(dir)
        }
        return id
    }

    /// 新建节点（我们自己创建的条目），属性从 vault 读回。
    private func insert(_ name: String, in dir: UInt64, dirId: String) throws -> UInt64 {
        guard let e = try vault.lookup(name, inDirectory: dirId) else { throw POSIXFailure(EIO) }
        var index = children[dir] ?? [:]
        let id = remember(e, in: dir, index: &index)
        children[dir] = index
        if var l = listings[dir] {
            l.ids.insert(id, at: l.ids.firstIndex { $0 > id } ?? l.ids.count)
            listings[dir] = l
        }
        bump(dir)
        touch(dir)
        return id
    }

    private func attach(_ id: UInt64, to dir: UInt64) {
        guard let n = nodes[id] else { return }
        children[dir, default: [:]][Self.key(n.name)] = id
        if var l = listings[dir] {
            l.ids.insert(id, at: l.ids.firstIndex { $0 > id } ?? l.ids.count)
            listings[dir] = l
        }
        bump(dir)
    }

    private func detach(_ id: UInt64) {
        guard let n = nodes[id] else { return }
        if children[n.parent]?[Self.key(n.name)] == id { children[n.parent]?[Self.key(n.name)] = nil }
        if var l = listings[n.parent], let i = l.ids.firstIndex(of: id) {
            l.ids.remove(at: i)
            listings[n.parent] = l
        }
        bump(n.parent)
    }

    /// 条目已从 vault 里消失：从命名空间摘掉；FSKit 还拿着它时节点保留到 reclaim（打开着的句柄照常可读写，同 POSIX unlink）。
    private func forget(_ id: UInt64) {
        guard var n = nodes[id] else { return }
        if children[n.parent]?[Self.key(n.name)] == id { children[n.parent]?[Self.key(n.name)] = nil }
        if n.kind == .directory {
            for (_, c) in children[id] ?? [:] { forget(c) }
            children[id] = nil
            listings[id] = nil
        }
        if live[id] != nil || contents[id] != nil {
            n.deleted = true
            nodes[id] = n
        } else {
            nodes[id] = nil
        }
    }

    private func touch(_ id: UInt64) {
        let now = timespec.now
        nodes[id]?.mtime = now
        nodes[id]?.ctime = now
    }

    // MARK: - 属性

    private func attributes(_ id: UInt64, _ n: Node, _ wanted: FSItem.GetAttributesRequest?) -> FSItem.Attributes {
        let a = FSItem.Attributes()
        func want(_ x: FSItem.Attribute) -> Bool { wanted?.isAttributeWanted(x) ?? true }
        if want(.type) { a.type = n.kind.itemType }
        if want(.mode) { a.mode = n.kind.typeBits | (n.mode ?? n.kind.defaultPermissions) }
        if want(.linkCount) {
            if n.kind == .directory, let l = listings[id] {
                a.linkCount = UInt32(2 + l.ids.lazy.filter { self.nodes[$0]?.kind == .directory }.count)
            } else {
                a.linkCount = 1
            }
        }
        if want(.uid) { a.uid = ownerUID }
        if want(.gid) { a.gid = ownerGID }
        if want(.flags) { a.flags = n.flags }
        if want(.size) || want(.allocSize) {
            let s: UInt64
            switch n.kind {
            case .file: s = contents[id].map { UInt64($0.size) } ?? n.size
            case .directory: s = 64
            case .symlink: s = n.size
            }
            if want(.size) { a.size = s }
            if want(.allocSize) { a.allocSize = (s + 4095) / 4096 * 4096 }
        }
        if want(.fileID) { a.fileID = FSItem.Identifier(rawValue: id)! }
        if want(.parentID) { a.parentID = FSItem.Identifier(rawValue: n.parent)! }
        if want(.modifyTime) { a.modifyTime = n.mtime }
        if want(.changeTime) { a.changeTime = n.ctime }
        if want(.accessTime) { a.accessTime = n.atime }
        if want(.birthTime) { a.birthTime = n.birthtime }
        if want(.addedTime) { a.addedTime = n.birthtime }
        if want(.backupTime) { a.backupTime = timespec() }
        if want(.supportsLimitedXAttrs) { a.supportsLimitedXAttrs = false }
        if want(.inhibitKernelOffloadedIO) { a.inhibitKernelOffloadedIO = false }
        return a
    }

    /// setattr / 创建时的属性：大小（截断）和修改时间写进 vault；权限、标志、访问时间只记在内存里；属主不能改，静默接受。
    private func apply(_ req: FSItem.SetAttributesRequest, to id: UInt64, creating: Bool = false) throws {
        guard var n = nodes[id] else { throw POSIXFailure(ENOENT) }
        var consumed: FSItem.Attribute = []
        if req.isValid(.size) {
            if n.kind == .file && !(creating && req.size == 0) {
                try requireWritable()
                let c = try content(id, n)
                try c.truncate(to: Int(req.size))
                n.size = req.size
                let now = timespec.now
                n.mtime = now
                n.ctime = now
                if c.openModes.isEmpty { scheduleIdleClose() }
            }
            consumed.insert(.size)
        }
        if req.isValid(.mode) { n.mode = req.mode & 0o7777; n.ctime = .now; consumed.insert(.mode) }
        if req.isValid(.uid) { consumed.insert(.uid) }
        if req.isValid(.gid) { consumed.insert(.gid) }
        if req.isValid(.flags) { n.flags = req.flags; consumed.insert(.flags) }
        if req.isValid(.modifyTime) {
            if !vault.isReadOnly {
                let date = req.modifyTime.date
                do {
                    if let c = contents[id] {
                        try c.file.setModificationDate(date)
                    } else if id == Self.rootID {
                        try vault.setModificationDate(date, ofDirectory: Vault.rootDirectoryId)
                    } else {
                        try vault.setModificationDate(date, of: n.name, inDirectory: try parentDirId(n))
                    }
                } catch {
                    fsLog.error("set mtime failed: errno \(posixCode(error))")
                }
            }
            n.mtime = req.modifyTime
            consumed.insert(.modifyTime)
        }
        if req.isValid(.accessTime) { n.atime = req.accessTime; consumed.insert(.accessTime) }
        if req.isValid(.birthTime) { n.birthtime = req.birthTime; consumed.insert(.birthTime) }
        if req.isValid(.changeTime) { n.ctime = req.changeTime; consumed.insert(.changeTime) }
        if req.isValid(.addedTime) { consumed.insert(.addedTime) }
        if req.isValid(.backupTime) { consumed.insert(.backupTime) }
        nodes[id] = n
        req.consumedAttributes = consumed
    }

    // MARK: - 文件内容句柄

    private func content(_ id: UInt64, _ n: Node) throws -> FileContent {
        if let c = contents[id] { return c }
        guard !n.deleted else { throw POSIXFailure(ENOENT) }
        let f = try vault.openFile(n.name, inDirectory: try parentDirId(n), writable: !vault.isReadOnly)
        let c = FileContent(f)
        contents[id] = c
        return c
    }

    /// 关闭句柄（= 落盘），用 vault 读回的属性刷新节点。
    /// 先同步再摘掉：同步失败时句柄留在表里（写入还在影子文件里，读到的仍是新内容），之后的 fsync / 关闭 / 卸载会再试，
    /// 而不是摘掉句柄后让这些写入从卷上消失。
    private func closeContent(_ id: UInt64) throws {
        guard let c = contents[id] else { return }
        try c.synchronize()
        contents[id] = nil
        defer {
            if live[id] == nil, nodes[id]?.deleted == true { nodes[id] = nil }
        }
        try c.close()
        if var n = nodes[id], !n.deleted, let pd = try? parentDirId(n),
           let a = try? vault.attributes(of: n.name, inDirectory: pd) {
            n.update(a)
            nodes[id] = n
        }
    }

    /// 没人打开的句柄空闲一会儿后关闭（内核在 close 之后才写回的数据、mmap 的读写会走到这里）。
    private func scheduleIdleClose() {
        guard !idleCloserScheduled else { return }
        idleCloserScheduled = true
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + idleClose) { [weak self] in
            guard let self else { return }
            self.locked {
                self.idleCloserScheduled = false
                var pending = false
                for (id, c) in self.contents where c.openModes.isEmpty {
                    if Date().timeIntervalSince(c.lastUse) >= self.idleClose {
                        do { try self.closeContent(id) } catch {
                            fsLog.error("idle close failed: errno \(posixCode(error))")
                        }
                    } else {
                        pending = true
                    }
                }
                if pending { self.scheduleIdleClose() }
            }
        }
    }

    private func syncAll() -> Error? {
        var failure: Error?
        for (id, c) in contents {
            do { try c.synchronize() } catch {
                fsLog.error("sync \(id) failed: errno \(posixCode(error))")
                failure = failure ?? error
            }
        }
        return failure
    }

    func shutdown() {
        locked {
            for id in Array(contents.keys) {
                do { try closeContent(id) } catch {
                    // 卸载了没法再重试：关掉句柄（内核再试一次落盘，仍失败时影子文件留在 vault 目录里，不删）
                    fsLog.error("close on shutdown failed: errno \(posixCode(error))")
                    try? contents.removeValue(forKey: id)?.close()
                }
            }
        }
    }
}

// MARK: - FSVolume.Operations

extension VaultVolume: FSVolume.Operations {
    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let c = FSVolume.SupportedCapabilities()
        c.supportsSymbolicLinks = true
        c.supportsHardLinks = false
        c.supportsPersistentObjectIDs = false
        c.supports64BitObjectIDs = true
        c.supportsFastStatFS = true
        c.supports2TBFiles = true
        c.supportsHiddenFiles = true
        c.supportsSparseFiles = false
        c.supportsJournal = false
        c.doesNotSupportImmutableFiles = true
        c.doesNotSupportRootTimes = false
        c.caseFormat = .sensitive
        return c
    }

    var volumeStatistics: FSStatFSResult {
        let r = FSStatFSResult(fileSystemTypeName: "foldersafe")
        var s = statfs()
        let bs: UInt64 = 4096
        r.blockSize = Int(bs)
        r.ioSize = 1 << 20
        if statfs(rootURL.path, &s) == 0 {
            let total = UInt64(s.f_blocks) * UInt64(s.f_bsize)
            let free = UInt64(s.f_bfree) * UInt64(s.f_bsize)
            let avail = UInt64(s.f_bavail) * UInt64(s.f_bsize)
            r.totalBytes = total
            r.freeBytes = free
            r.availableBytes = avail
            r.usedBytes = total > free ? total - free : 0
            r.totalBlocks = total / bs
            r.freeBlocks = free / bs
            r.availableBlocks = avail / bs
            r.usedBlocks = r.usedBytes / bs
            r.totalFiles = UInt64(s.f_files)
            r.freeFiles = UInt64(s.f_ffree)
        }
        return r
    }

    var maximumLinkCount: Int { 1 }
    var maximumNameLength: Int { 255 }
    var restrictsOwnershipChanges: Bool { true }
    var truncatesLongNames: Bool { false }
    var maximumXattrSize: Int { Self.maxXattrSize }
    var maximumFileSize: UInt64 { UInt64(Int64.max) }

    var enableOpenUnlinkEmulation: Bool { true }

    func activate(options: FSTaskOptions, replyHandler reply: @escaping (FSItem?, (any Error)?) -> Void) {
        let root = locked { liveItem(Self.rootID) }
        reply(root, nil)
    }

    func deactivate(options: FSDeactivateOptions = [], replyHandler reply: @escaping ((any Error)?) -> Void) {
        shutdown()
        reply(nil)
    }

    func mount(options: FSTaskOptions, replyHandler reply: @escaping ((any Error)?) -> Void) {
        fsLog.info("mount \(self.rootURL.path, privacy: .public) options=\(options.taskOptions, privacy: .public)")
        reply(nil)
    }

    func unmount(replyHandler reply: @escaping () -> Void) {
        fsLog.info("unmount")
        shutdown()
        reply()
    }

    func synchronize(flags: FSSyncFlags, replyHandler reply: @escaping ((any Error)?) -> Void) {
        let failure = locked { syncAll() }
        reply(failure.map { fsError($0) })
    }

    func reclaimItem(_ item: FSItem, replyHandler reply: @escaping ((any Error)?) -> Void) {
        locked {
            guard let it = item as? VaultItem, it.id != Self.rootID else { return }
            live[it.id] = nil
            if let c = contents[it.id], c.openModes.isEmpty {
                do { try closeContent(it.id) } catch {
                    fsLog.error("close on reclaim failed: errno \(posixCode(error))")
                }
            }
            if nodes[it.id]?.deleted == true, contents[it.id] == nil { nodes[it.id] = nil }
        }
        reply(nil)
    }

    func lookupItem(named name: FSFileName, inDirectory directory: FSItem,
                    replyHandler reply: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void) {
        do {
            let (item, n): (VaultItem, String) = try locked {
                let (dir, _, _) = try dirNode(directory)
                guard let s = name.string else { throw POSIXFailure(ENOENT) }
                guard let id = try child(dir.id, s), let n = nodes[id] else { throw POSIXFailure(ENOENT) }
                return (liveItem(id), n.name)
            }
            reply(item, FSFileName(string: n), nil)
        } catch {
            reply(nil, nil, fsError(error))
        }
    }

    func createItem(named name: FSFileName, type: FSItem.ItemType, inDirectory directory: FSItem,
                    attributes newAttributes: FSItem.SetAttributesRequest,
                    replyHandler reply: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void) {
        do {
            let (item, n): (VaultItem, String) = try locked {
                try requireWritable()
                let (dir, _, dirId) = try dirNode(directory)
                let s = try checkName(name)
                guard try child(dir.id, s) == nil else { throw POSIXFailure(EEXIST) }
                switch type {
                case .file:
                    try vault.createFile(s, inDirectory: dirId).close()
                case .directory:
                    try vault.createDirectory(s, inDirectory: dirId)
                default:
                    throw POSIXFailure(ENOTSUP)
                }
                let id = try insert(s, in: dir.id, dirId: dirId)
                if type == .directory { listings[id] = Listing(ids: [], loadedAt: Date()) }
                try apply(newAttributes, to: id, creating: true)
                return (liveItem(id), nodes[id]!.name)
            }
            reply(item, FSFileName(string: n), nil)
        } catch {
            reply(nil, nil, fsError(error))
        }
    }

    func createSymbolicLink(named name: FSFileName, inDirectory directory: FSItem,
                            attributes newAttributes: FSItem.SetAttributesRequest, linkContents contents: FSFileName,
                            replyHandler reply: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void) {
        do {
            let (item, n): (VaultItem, String) = try locked {
                try requireWritable()
                let (dir, _, dirId) = try dirNode(directory)
                let s = try checkName(name)
                guard let target = contents.string else { throw POSIXFailure(EINVAL) }
                guard try child(dir.id, s) == nil else { throw POSIXFailure(EEXIST) }
                try vault.createSymlink(s, inDirectory: dirId, target: target)
                let id = try insert(s, in: dir.id, dirId: dirId)
                nodes[id]?.symlinkTarget = target
                try apply(newAttributes, to: id, creating: true)
                return (liveItem(id), nodes[id]!.name)
            }
            reply(item, FSFileName(string: n), nil)
        } catch {
            reply(nil, nil, fsError(error))
        }
    }

    func createLink(to item: FSItem, named name: FSFileName, inDirectory directory: FSItem,
                    replyHandler reply: @escaping (FSFileName?, (any Error)?) -> Void) {
        reply(nil, fsError(ENOTSUP))
    }

    func removeItem(_ item: FSItem, named name: FSFileName, fromDirectory directory: FSItem,
                    replyHandler reply: @escaping ((any Error)?) -> Void) {
        do {
            try locked {
                try requireWritable()
                let (it, n) = try node(item)
                if n.kind == .directory {
                    guard try listing(it.id, maxAge: 0).ids.isEmpty else { throw POSIXFailure(ENOTEMPTY) }
                }
                try vault.remove(n.name, inDirectory: try parentDirId(n))
                let parent = n.parent
                detach(it.id)
                forget(it.id)
                touch(parent)
            }
            reply(nil)
        } catch {
            reply(fsError(error))
        }
    }

    func renameItem(_ item: FSItem, inDirectory sourceDirectory: FSItem, named sourceName: FSFileName,
                    to destinationName: FSFileName, inDirectory destinationDirectory: FSItem, overItem: FSItem?,
                    replyHandler reply: @escaping (FSFileName?, (any Error)?) -> Void) {
        do {
            let newName: String = try locked {
                try requireWritable()
                let (it, n) = try node(item)
                let (dst, _, dstDirId) = try dirNode(destinationDirectory)
                let s = try checkName(destinationName)
                // 同目录、名字只差 Unicode 规范化：vault 里是同一个名字
                if n.parent == dst.id, Self.key(n.name) == s { return n.name }
                // 不能把目录挪进它自己里面
                var a = dst.id
                while a != Self.rootID {
                    if a == it.id { throw POSIXFailure(EINVAL) }
                    guard let p = nodes[a]?.parent else { break }
                    a = p
                }
                let existing = try child(dst.id, s)
                if let e = existing, e != it.id, let en = nodes[e] {
                    if en.kind == .directory {
                        guard n.kind == .directory else { throw POSIXFailure(EISDIR) }
                        guard try listing(e, maxAge: 0).ids.isEmpty else { throw POSIXFailure(ENOTEMPTY) }
                    } else if n.kind == .directory {
                        throw POSIXFailure(ENOTDIR)
                    }
                }
                try vault.move(n.name, inDirectory: try parentDirId(n), to: s, inDirectory: dstDirId, replacing: true)
                if let e = existing, e != it.id {
                    detach(e)
                    forget(e)
                }
                let oldParent = n.parent
                detach(it.id)
                nodes[it.id]?.parent = dst.id
                nodes[it.id]?.name = s
                nodes[it.id]?.ctime = .now
                attach(it.id, to: dst.id)
                touch(oldParent)
                touch(dst.id)
                return s
            }
            reply(FSFileName(string: newName), nil)
        } catch {
            reply(nil, fsError(error))
        }
    }

    func getAttributes(_ desiredAttributes: FSItem.GetAttributesRequest, of item: FSItem,
                       replyHandler reply: @escaping (FSItem.Attributes?, (any Error)?) -> Void) {
        do {
            let a = try locked {
                let (it, n) = try node(item)
                return attributes(it.id, n, desiredAttributes)
            }
            reply(a, nil)
        } catch {
            reply(nil, fsError(error))
        }
    }

    func setAttributes(_ newAttributes: FSItem.SetAttributesRequest, on item: FSItem,
                       replyHandler reply: @escaping (FSItem.Attributes?, (any Error)?) -> Void) {
        do {
            let a = try locked {
                let (it, _) = try node(item)
                try apply(newAttributes, to: it.id)
                return attributes(it.id, nodes[it.id]!, nil)
            }
            reply(a, nil)
        } catch {
            reply(nil, fsError(error))
        }
    }

    func enumerateDirectory(_ directory: FSItem, startingAt cookie: FSDirectoryCookie, verifier: FSDirectoryVerifier,
                            attributes: FSItem.GetAttributesRequest?, packer: FSDirectoryEntryPacker,
                            replyHandler reply: @escaping (FSDirectoryVerifier, (any Error)?) -> Void) {
        do {
            let v: UInt64 = try locked {
                let (dir, dn, _) = try dirNode(directory)
                // 新的一轮枚举：列表超过 1 秒就重读（看到同步盘之类的外部改动）
                let l = try listing(dir.id, maxAge: cookie == .initial ? 1 : nil)
                var c = cookie.rawValue
                if attributes == nil {
                    // cookie 0 → "."，1 → ".."，之后是子节点 id（≥ 3，升序；删改不会让后面的条目漏掉）
                    if c == 0 {
                        guard packer.packEntry(name: FSFileName(string: "."), itemType: .directory, itemID: dir.identifier,
                                               nextCookie: FSDirectoryCookie(rawValue: 1), attributes: nil) else {
                            return verifiers[dir.id, default: 1]
                        }
                        c = 1
                    }
                    if c == 1 {
                        let parent = dir.id == Self.rootID ? Self.rootID : dn.parent
                        guard packer.packEntry(name: FSFileName(string: ".."), itemType: .directory,
                                               itemID: FSItem.Identifier(rawValue: parent)!,
                                               nextCookie: FSDirectoryCookie(rawValue: 2), attributes: nil) else {
                            return verifiers[dir.id, default: 1]
                        }
                        c = 2
                    }
                }
                var lo = 0, hi = l.ids.count
                while lo < hi {
                    let mid = (lo + hi) / 2
                    if l.ids[mid] <= c { lo = mid + 1 } else { hi = mid }
                }
                for id in l.ids[lo...] {
                    guard let n = nodes[id], !n.deleted else { continue }
                    let attrs = attributes.map { self.attributes(id, n, $0) }
                    guard packer.packEntry(name: FSFileName(string: n.name), itemType: n.kind.itemType,
                                           itemID: FSItem.Identifier(rawValue: id)!,
                                           nextCookie: FSDirectoryCookie(rawValue: id), attributes: attrs) else { break }
                }
                return verifiers[dir.id, default: 1]
            }
            reply(FSDirectoryVerifier(rawValue: v), nil)
        } catch {
            reply(FSDirectoryVerifier(rawValue: 0), fsError(error))
        }
    }

    func readSymbolicLink(_ item: FSItem, replyHandler reply: @escaping (FSFileName?, (any Error)?) -> Void) {
        do {
            let target: String = try locked {
                let (it, n) = try node(item)
                guard n.kind == .symlink else { throw POSIXFailure(EINVAL) }
                if let t = n.symlinkTarget { return t }
                let t = try vault.readSymlink(n.name, inDirectory: try parentDirId(n))
                nodes[it.id]?.symlinkTarget = t
                return t
            }
            reply(FSFileName(string: target), nil)
        } catch {
            reply(nil, fsError(error))
        }
    }
}

// MARK: - 打开 / 关闭、读写

extension VaultVolume: FSVolume.OpenCloseOperations {
    func openItem(_ item: FSItem, modes: FSVolume.OpenModes, replyHandler reply: @escaping ((any Error)?) -> Void) {
        do {
            try locked {
                let (it, n) = try node(item)
                guard n.kind == .file else { return }
                if modes.contains(.write) { try requireWritable() }
                let c = try content(it.id, n)
                if modes.contains(.read) { c.openModes.insert(.read) }
                if modes.contains(.write) { c.openModes.insert(.write) }
            }
            reply(nil)
        } catch {
            reply(fsError(error))
        }
    }

    func closeItem(_ item: FSItem, modes: FSVolume.OpenModes, replyHandler reply: @escaping ((any Error)?) -> Void) {
        var failure: Error?
        locked {
            guard let it = item as? VaultItem, let c = contents[it.id] else { return }
            var keep: FSOpenSet = []
            if modes.contains(.read) { keep.insert(.read) }
            if modes.contains(.write) { keep.insert(.write) }
            c.openModes = keep
            guard keep.isEmpty else { return }
            do { try closeContent(it.id) } catch { failure = error }
        }
        reply(failure.map { fsError($0) })
    }
}

extension VaultVolume: FSVolume.ReadWriteOperations {
    func read(from item: FSItem, at offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer,
              replyHandler reply: @escaping (Int, (any Error)?) -> Void) {
        do {
            let n: Int = try locked {
                let (it, nd) = try node(item)
                guard nd.kind == .file else { throw POSIXFailure(EISDIR) }
                guard offset >= 0 else { throw POSIXFailure(EINVAL) }
                let c = try content(it.id, nd)
                let r = try buffer.withUnsafeMutableBytes { raw in
                    try c.read(at: Int(offset), into: UnsafeMutableRawBufferPointer(rebasing: raw[0..<min(length, raw.count)]))
                }
                if c.openModes.isEmpty { scheduleIdleClose() }
                return r
            }
            reply(n, nil)
        } catch {
            reply(0, fsError(error))
        }
    }

    func write(contents data: Data, to item: FSItem, at offset: off_t,
               replyHandler reply: @escaping (Int, (any Error)?) -> Void) {
        do {
            let n: Int = try locked {
                try requireWritable()
                let (it, nd) = try node(item)
                guard nd.kind == .file else { throw POSIXFailure(EISDIR) }
                guard offset >= 0 else { throw POSIXFailure(EINVAL) }
                let c = try content(it.id, nd)
                try c.write(data, at: Int(offset))
                nodes[it.id]?.size = UInt64(c.size)
                touch(it.id)
                if c.openModes.isEmpty { scheduleIdleClose() }
                return data.count
            }
            reply(n, nil)
        } catch {
            reply(0, fsError(error))
        }
    }
}

// MARK: - 扩展属性（只在内存里，让 Finder 拷贝、quarantine 之类正常工作，不生成 ._ 文件）

extension VaultVolume: FSVolume.XattrOperations {
    func getXattr(named name: FSFileName, of item: FSItem, replyHandler reply: @escaping (Data?, (any Error)?) -> Void) {
        do {
            let d: Data = try locked {
                let (_, n) = try node(item)
                guard let k = name.string, let v = n.xattrs[k] else { throw POSIXFailure(ENOATTR) }
                return v
            }
            reply(d, nil)
        } catch {
            reply(nil, fsError(error))
        }
    }

    func setXattr(named name: FSFileName, to value: Data?, on item: FSItem, policy: FSVolume.SetXattrPolicy,
                  replyHandler reply: @escaping ((any Error)?) -> Void) {
        do {
            try locked {
                let (it, n) = try node(item)
                guard let k = name.string, !k.isEmpty else { throw POSIXFailure(EINVAL) }
                var x = n.xattrs
                switch policy {
                case .delete:
                    guard x[k] != nil else { throw POSIXFailure(ENOATTR) }
                    x[k] = nil
                case .mustCreate:
                    guard x[k] == nil else { throw POSIXFailure(EEXIST) }
                    x[k] = value ?? Data()
                case .mustReplace:
                    guard x[k] != nil else { throw POSIXFailure(ENOATTR) }
                    x[k] = value ?? Data()
                default:
                    x[k] = value ?? Data()
                }
                if let v = x[k], v.count > Self.maxXattrSize { throw POSIXFailure(E2BIG) }
                guard x.values.reduce(0, { $0 + $1.count }) <= Self.maxXattrTotal else { throw POSIXFailure(ENOSPC) }
                nodes[it.id]?.xattrs = x
                nodes[it.id]?.ctime = .now
            }
            reply(nil)
        } catch {
            reply(fsError(error))
        }
    }

    func listXattrs(of item: FSItem, replyHandler reply: @escaping ([FSFileName]?, (any Error)?) -> Void) {
        do {
            let names: [String] = try locked { try node(item).1.xattrs.keys.sorted() }
            reply(names.map { FSFileName(string: $0) }, nil)
        } catch {
            reply(nil, fsError(error))
        }
    }
}
