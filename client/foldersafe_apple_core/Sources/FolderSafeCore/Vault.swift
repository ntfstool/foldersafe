import Foundation
import CryptoKit

/// 一个已解锁的 v1 vault。两种寻址方式，结果完全一样：
/// - 目录 ID + 名字：目录 ID 改名、移动都不变（根目录是 `Vault.rootDirectoryId`，即空字符串），File Provider 用它做稳定标识。
///   文件在格式里没有稳定 ID：上层自己维护"自己的 ID → (父目录 ID, 名字)"映射，经本接口移动 / 改名后更新即可。
/// - 明文路径（"/a/b.txt" 或 "a/b.txt"）：先逐级解析成 (父目录 ID, 名字)，是上面的薄封装。
/// 线程安全：所有操作（含打开的文件句柄）在一把递归锁里串行执行；整文件写入 / 导入的加密、整文件读取的解密在锁外进行。
/// 断电安全：整文件写入是"临时文件 + fsync + 原子改名"；句柄写在影子副本上，synchronize / close 时原子换上（见 VaultFile）。
public final class Vault: @unchecked Sendable {            // 可变状态（openFiles）都由 lock 保护
    public enum Kind: String, Sendable { case file, directory, symlink }

    public static let rootDirectoryId = ""

    /// 条目属性。日期取自密文节点（目录取它的存储目录 d/XX/…），云端同样看得到（规范 §9）。
    public struct Attributes: Equatable, Sendable {
        public let kind: Kind
        public let size: Int                       // 文件：明文大小（含句柄里还没同步的写入）；符号链接：目标 UTF-8 字节数；目录：0
        public let modificationDate: Date
        public let creationDate: Date
        public let directoryId: String?            // 只有目录有
    }

    public struct Entry: Equatable, Sendable {
        public let name: String
        public let parentId: String                // 所在目录的 ID：(parentId, name) 就能重新找到它
        public let attributes: Attributes
        public var kind: Kind { attributes.kind }
        public var size: Int? { kind == .file ? attributes.size : nil }      // 只有文件有：明文大小
        public var directoryId: String? { attributes.directoryId }           // 只有目录有：改名、移动都不变
    }

    public let root: URL
    public let config: VaultConfig
    public let masterkey: Masterkey               // 设备钥匙（Touch ID 等）包装的就是 masterkey.raw
    public let isReadOnly: Bool
    let names: NameCipher
    let random: RandomSource
    let fm = FileManager.default
    let lock = NSRecursiveLock()
    var openFiles: [String: OpenFile] = [:]       // 内容文件路径 → 打开的文件（多个句柄共用）

    init(root: URL, config: VaultConfig, masterkey: Masterkey, random: RandomSource) throws {
        self.root = root
        self.config = config
        self.masterkey = masterkey
        self.names = NameCipher(masterkey)
        self.random = random
        if let d = try? Data(contentsOf: root.appendingPathComponent(ExtensionsFile.path)) {
            isReadOnly = !(try ExtensionsFile(data: d)).allowsWriting
        } else {
            isReadOnly = false
        }
    }

    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: - 建库 / 打开

    /// 新建 vault（目录必须不存在或为空），返回找回短语——只在这时出现一次，界面要让用户抄下来。
    @discardableResult
    public static func create(at root: URL, password: String, random: RandomSource = SystemRandom.shared,
                              scryptN: Int = 32768) throws -> (Vault, RecoveryPhrase) {
        try checkPassword(password)
        let fm = FileManager.default
        if fm.fileExists(atPath: root.path) {
            guard (try fm.contentsOfDirectory(atPath: root.path)).filter({ $0 != ".DS_Store" }).isEmpty else {
                throw VaultError.alreadyExists(root.path)
            }
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let key = Masterkey.generate(random)
        let config = VaultConfig(vaultId: uuid(random))
        try atomicWrite(try MasterkeyFile.make(key, password: password, random: random, n: scryptN).serialized(),
                        to: root.appendingPathComponent(MasterkeyFile.name))
        try atomicWrite(Data(config.token(signedWith: key).utf8), to: root.appendingPathComponent(VaultConfig.fileName))
        let vault = try Vault(root: root, config: config, masterkey: key, random: random)
        try vault.createStorageDir(dirId: "")
        let phrase = try vault.enableRecovery()
        return (vault, phrase)
    }

    public static func open(at root: URL, password: String, random: RandomSource = SystemRandom.shared) throws -> Vault {
        let u = try unverifiedConfig(root)
        guard u.kid == VaultConfig.masterkeyKid else { throw VaultError.unsupported("key source \(u.kid)") }
        let file = try MasterkeyFile(data: try read(root.appendingPathComponent(MasterkeyFile.name)))
        let key = try file.unlock(password: password)
        return try Vault(root: root, config: try VaultConfig.verify(u, with: key), masterkey: key, random: random)
    }

    public static func open(at root: URL, recoveryPhrase: String, random: RandomSource = SystemRandom.shared) throws -> Vault {
        let phrase = try RecoveryPhrase(phrase: recoveryPhrase)
        let u = try unverifiedConfig(root)
        guard let d = try? Data(contentsOf: root.appendingPathComponent(RecoveryFile.path)) else {
            throw VaultError.unsupported("this vault has no recovery phrase")
        }
        let key = try RecoveryFile(data: d).unlock(phrase, vaultId: u.config.vaultId)
        return try Vault(root: root, config: try VaultConfig.verify(u, with: key), masterkey: key, random: random)
    }

    /// 用设备钥匙（Touch ID / Windows Hello 等，规范 §7.4）解出的 rawKey 打开。
    public static func open(at root: URL, rawKey: Data, random: RandomSource = SystemRandom.shared) throws -> Vault {
        let key = try Masterkey(raw: rawKey)
        return try Vault(root: root, config: try VaultConfig.verify(try unverifiedConfig(root), with: key), masterkey: key, random: random)
    }

    /// 不解锁就能读到的 vault ID（设备钥匙按它存放）。
    public static func vaultId(at root: URL) throws -> String { try unverifiedConfig(root).config.vaultId }

    // MARK: - 钥匙管理

    /// 改密码：只重写 masterkey.cryptomator。旧文件先留一份 .bkup，新文件验证通过后才删。
    public func changePassword(to newPassword: String) throws {
        try requireWritable()
        try Vault.checkPassword(newPassword)
        try locked {
            let url = root.appendingPathComponent(MasterkeyFile.name)
            let old = try Vault.read(url)
            let backup = root.appendingPathComponent(Vault.backupName(MasterkeyFile.name, old))
            try Vault.atomicWrite(old, to: backup)
            try Vault.atomicWrite(try MasterkeyFile.make(masterkey, password: newPassword, random: random).serialized(), to: url)
            guard (try? MasterkeyFile(data: try Vault.read(url)).unlock(password: newPassword)) == masterkey else {
                try Vault.atomicWrite(old, to: url)                       // 验证失败就恢复旧文件
                throw VaultError.corrupted("new masterkey file did not verify")
            }
            try? fm.removeItem(at: backup)
        }
    }

    /// 给 vault 加上（或重新生成）找回短语。Cryptomator 建的 vault 也可以加：只新增 foldersafe/ 目录。
    @discardableResult
    public func enableRecovery() throws -> RecoveryPhrase {
        try requireWritable()
        return try locked {
            let phrase = RecoveryPhrase.generate(random)
            try fm.createDirectory(at: root.appendingPathComponent("foldersafe"), withIntermediateDirectories: true)
            try Vault.atomicWrite(try RecoveryFile.make(masterkey, phrase: phrase, vaultId: config.vaultId, random: random).serialized(),
                                  to: root.appendingPathComponent(RecoveryFile.path))
            let extURL = root.appendingPathComponent(ExtensionsFile.path)
            var ext = (try? ExtensionsFile(data: Data(contentsOf: extURL))) ?? ExtensionsFile.current
            ext.extensions["recovery"] = 1
            try Vault.atomicWrite(ext.serialized(), to: extURL)
            return phrase
        }
    }

    // MARK: - 按目录 ID 寻址：读

    /// 目录 ID 对应的目录是否还在（被删掉后为 false）。
    public func directoryExists(id: String) -> Bool { FileStat(storageURL(id).path)?.isDirectory == true }

    /// 列目录。可写的 vault 会顺便整理网盘同步冲突副本（规范 §6.5）。
    public func contentsOfDirectory(id: String) throws -> [Entry] { try locked { try list(id) } }

    /// 按名字查一个条目；不存在返回 nil，目录本身不存在则抛 notFound。
    public func lookup(_ name: String, inDirectory id: String) throws -> Entry? {
        try locked {
            let name = try Vault.checkName(name)
            try requireDirectory(id)
            let n = node(name, in: id)
            guard let kind = nodeKind(n) else { return nil }
            return Entry(name: name, parentId: id, attributes: try attributes(n, kind))
        }
    }

    public func attributes(of name: String, inDirectory id: String) throws -> Attributes {
        guard let e = try lookup(name, inDirectory: id) else { throw VaultError.notFound(name) }
        return e.attributes
    }

    /// 目录自身的属性（根目录没有节点，只能这样取）。
    public func attributes(ofDirectory id: String) throws -> Attributes {
        guard let s = FileStat(storageURL(id).path), s.isDirectory else { throw VaultError.notFound("directory \(id)") }
        return Attributes(kind: .directory, size: 0, modificationDate: s.modified, creationDate: s.created, directoryId: id)
    }

    public func readFile(_ name: String, inDirectory id: String) throws -> Data {
        let (data, isPlain) = try locked { () -> (Data, Bool) in
            let n = try existingNode(name, id, as: .file)
            if let f = openFiles[n.contentURL.path] { return (try f.read(at: 0, count: f.size), true) }
            return (try Vault.read(n.contentURL), false)
        }
        return isPlain ? data : try FileCipher.decrypt(data, encKey: masterkey.encKey)
    }

    /// 解密导出到普通文件（流式，内存占用固定；File Provider 的 fetchContents 用）。
    public func exportFile(_ name: String, inDirectory id: String, to destination: URL) throws {
        let f = try openFile(name, inDirectory: id)
        defer { try? f.close() }
        guard fm.createFile(atPath: destination.path, contents: nil) else { throw VaultError.io("cannot create \(destination.path)") }
        let out = try FileHandle(forWritingTo: destination)
        defer { try? out.close() }
        var offset = 0
        while true {
            let piece = try f.read(at: offset, count: Vault.streamPiece)
            if piece.isEmpty { break }
            try out.write(contentsOf: piece)
            offset += piece.count
        }
        try out.synchronize()
    }

    public func readSymlink(_ name: String, inDirectory id: String) throws -> String {
        let url = try locked { try existingNode(name, id, as: .symlink).url.appendingPathComponent("symlink.c9r") }
        let target = try FileCipher.decrypt(try Vault.read(url), encKey: masterkey.encKey)
        guard let s = String(data: target, encoding: .utf8) else { throw VaultError.corrupted("symlink target") }
        return s
    }

    /// 打开文件做随机读写（见 VaultFile）。用完必须 close()，写入在 synchronize() / close() 时才落到原文件。
    public func openFile(_ name: String, inDirectory id: String, writable: Bool = false) throws -> VaultFile {
        if writable { try requireWritable() }
        return try locked {
            let n = try existingNode(name, id, as: .file)
            return VaultFile(vault: self, file: try openShared(n.contentURL), writable: writable)
        }
    }

    // MARK: - 按目录 ID 寻址：写

    /// 新建文件并打开（可写）。已存在就抛 alreadyExists。先原子写好只有文件头的空文件，之后才有句柄写入。
    public func createFile(_ name: String, inDirectory id: String) throws -> VaultFile {
        try requireWritable()
        return try locked {
            let (n, name) = try newNode(name, id)
            try prepare(n, name: name, parentId: id)
            try Vault.atomicWrite(try FileCipher.encryptHeader(FileCipher.newHeader(random), encKey: masterkey.encKey), to: n.contentURL)
            return VaultFile(vault: self, file: try openShared(n.contentURL), writable: true)
        }
    }

    /// 整文件写入（覆盖已有文件）。打开着的句柄会看到新内容，它们还没同步的写入作废（同 POSIX 的"原子替换"语义）。
    public func writeFile(_ name: String, inDirectory id: String, data: Data) throws {
        var offset = data.startIndex
        try install(name, id) { max in
            let end = min(offset + max, data.endIndex)
            defer { offset = end }
            return data[offset..<end]
        }
    }

    /// 从普通文件加密导入（流式，内存占用固定；File Provider 的 createItem / modifyItem 用）。语义同 writeFile。
    public func importFile(_ name: String, inDirectory id: String, from source: URL) throws {
        let input: FileHandle
        do { input = try FileHandle(forReadingFrom: source) } catch { throw VaultError.notFound(source.path) }
        defer { try? input.close() }
        try install(name, id) { try input.read(upToCount: $0) ?? Data() }
    }

    /// 新建目录，返回它的目录 ID。
    @discardableResult
    public func createDirectory(_ name: String, inDirectory parentId: String) throws -> String {
        try requireWritable()
        return try locked {
            let (n, name) = try newNode(name, parentId)
            let id = Vault.uuid(random)
            try createStorageDir(dirId: id)                 // 先建存储目录，再挂节点：中途断电只会留下没人引用的空目录
            try prepare(n, name: name, parentId: parentId, asDirectory: true)
            try Vault.atomicWrite(Data(id.utf8), to: n.url.appendingPathComponent("dir.c9r"))
            return id
        }
    }

    public func createSymlink(_ name: String, inDirectory parentId: String, target: String) throws {
        try requireWritable()
        try locked {
            let (n, name) = try newNode(name, parentId)
            try prepare(n, name: name, parentId: parentId, asDirectory: true)
            try Vault.atomicWrite(try FileCipher.encrypt(Data(target.utf8), encKey: masterkey.encKey, random: random),
                                  to: n.url.appendingPathComponent("symlink.c9r"))
        }
    }

    /// 删除文件、符号链接或整个目录（递归）。打开着的句柄还能读写，但内容不会再落盘（同 POSIX unlink）。
    public func remove(_ name: String, inDirectory id: String) throws {
        try requireWritable()
        try locked {
            let name = try Vault.checkName(name)
            let n = node(name, in: id)
            guard let kind = nodeKind(n) else { throw VaultError.notFound(name) }
            try removeNode(n, kind)
        }
    }

    /// 移动 / 改名。内容不用重新加密：文件内容与名字、位置无关；目录的 ID 也不变。
    /// replacing：目标已存在时替换它（文件 / 符号链接，或空目录换目录，同 POSIX rename）；否则抛 alreadyExists。
    public func move(_ name: String, inDirectory srcId: String, to newName: String, inDirectory dstId: String,
                     replacing: Bool = false) throws {
        try requireWritable()
        try locked {
            let sn = try Vault.checkName(name), dn = try Vault.checkName(newName)
            try requireDirectory(dstId)
            let s = node(sn, in: srcId), d = node(dn, in: dstId)
            guard let kind = nodeKind(s) else { throw VaultError.notFound(name) }
            if srcId == dstId && sn == dn { return }
            if kind == .directory, srcId != dstId {           // 不能挪进自己或自己的子目录
                let id = try dirIdOfNode(s)
                if id == dstId || subtreeContains(dstId, under: id) { throw VaultError.invalidName(newName) }
            }
            if let dk = nodeKind(d) {
                guard replacing else { throw VaultError.alreadyExists(newName) }
                if dk == .directory, kind != .directory { throw VaultError.alreadyExists(newName) }
                if dk != .directory, kind == .directory { throw VaultError.notADirectory(newName) }
                if dk == .directory, !isEmptyStorage(try dirIdOfNode(d)) { throw VaultError.alreadyExists(newName) }
                if kind == .file, dk == .file, !s.shortened, !d.shortened {   // 最常见的"保存时替换"：一次 rename(2)，原子
                    try openFiles[s.contentURL.path]?.commit()
                    detach(d.contentURL.path)
                    try Vault.rename(s.url, d.url)
                    rekey(s.contentURL, d.contentURL)
                    return
                }
                try removeNode(d, dk)
            } else {
                try clearLeftover(d)
            }
            try openFiles[s.contentURL.path]?.commit()          // 有影子文件先换上，再挪
            if !s.shortened && !d.shortened {
                do { try fm.moveItem(at: s.url, to: d.url) } catch { throw VaultError.io("move: \(error.localizedDescription)") }
            } else {
                // 长短名之间转换：重建节点外壳，把里面的内容文件挪过去
                let inner = kind == .file ? "contents.c9r" : kind == .directory ? "dir.c9r" : "symlink.c9r"
                try prepare(d, name: dn, parentId: dstId, asDirectory: kind != .file)
                let srcInner = kind == .file ? s.contentURL : s.url.appendingPathComponent(inner)
                let dstInner = kind == .file ? d.contentURL : d.url.appendingPathComponent(inner)
                try Vault.rename(srcInner, dstInner)
                if s.shortened || kind != .file { try? fm.removeItem(at: s.url) }   // 空外壳，删不掉也不影响数据
            }
            if kind == .file { rekey(s.contentURL, d.contentURL) }
        }
    }

    /// 设置修改时间（写在密文节点上；目录写在存储目录上）。
    public func setModificationDate(_ date: Date, of name: String, inDirectory id: String) throws {
        try requireWritable()
        try locked {
            let n = node(try Vault.checkName(name), in: id)
            let target: URL
            switch nodeKind(n) {
            case nil: throw VaultError.notFound(name)
            case .file?:
                if let f = openFiles[n.contentURL.path] { return try f.setModificationDate(date) }
                target = n.contentURL
            case .directory?: target = storageURL(try dirIdOfNode(n))
            case .symlink?: target = n.url.appendingPathComponent("symlink.c9r")
            }
            try Vault.setDate(date, target)
        }
    }

    public func setModificationDate(_ date: Date, ofDirectory id: String) throws {
        try requireWritable()
        try locked { try Vault.setDate(date, storageURL(id)) }
    }

    // MARK: - 按路径寻址（薄封装）

    public func directoryId(of path: String) throws -> String { try locked { try dirId(of: try Vault.components(path)) } }

    public func kind(of path: String) throws -> Kind? {
        try locked {
            let c = try Vault.components(path)
            guard let name = c.last else { return .directory }
            return nodeKind(node(name, in: try dirId(of: Array(c.dropLast()))))
        }
    }

    public func contentsOfDirectory(_ path: String) throws -> [Entry] { try locked { try list(try directoryId(of: path)) } }

    public func attributes(of path: String) throws -> Attributes {
        guard let (p, n) = try locate(path) else { return try attributes(ofDirectory: Vault.rootDirectoryId) }
        return try attributes(of: n, inDirectory: p)
    }

    public func readFile(_ path: String) throws -> Data { let (p, n) = try parent(of: path); return try readFile(n, inDirectory: p) }
    public func exportFile(_ path: String, to destination: URL) throws {
        let (p, n) = try parent(of: path); try exportFile(n, inDirectory: p, to: destination)
    }
    public func readSymlink(_ path: String) throws -> String { let (p, n) = try parent(of: path); return try readSymlink(n, inDirectory: p) }
    public func openFile(_ path: String, writable: Bool = false) throws -> VaultFile {
        let (p, n) = try parent(of: path); return try openFile(n, inDirectory: p, writable: writable)
    }
    public func createFile(_ path: String) throws -> VaultFile { let (p, n) = try parent(of: path); return try createFile(n, inDirectory: p) }
    public func writeFile(_ path: String, data: Data) throws { let (p, n) = try parent(of: path); try writeFile(n, inDirectory: p, data: data) }
    public func importFile(_ path: String, from source: URL) throws {
        let (p, n) = try parent(of: path); try importFile(n, inDirectory: p, from: source)
    }
    @discardableResult
    public func createDirectory(_ path: String) throws -> String {
        let (p, n) = try parent(of: path); return try createDirectory(n, inDirectory: p)
    }
    public func createSymlink(_ path: String, target: String) throws {
        let (p, n) = try parent(of: path); try createSymlink(n, inDirectory: p, target: target)
    }
    public func remove(_ path: String) throws { let (p, n) = try parent(of: path); try remove(n, inDirectory: p) }
    public func move(_ from: String, to: String, replacing: Bool = false) throws {
        let (sp, sn) = try parent(of: from), (dp, dn) = try parent(of: to)
        try move(sn, inDirectory: sp, to: dn, inDirectory: dp, replacing: replacing)
    }
    public func setModificationDate(_ date: Date, of path: String) throws {
        guard let (p, n) = try locate(path) else { return try setModificationDate(date, ofDirectory: Vault.rootDirectoryId) }
        try setModificationDate(date, of: n, inDirectory: p)
    }

    // MARK: - 列目录

    func list(_ id: String) throws -> [Entry] {
        let dir = storageURL(id)
        guard let items = try? fm.contentsOfDirectory(atPath: dir.path) else { throw VaultError.notFound("directory \(id)") }
        var out: [String: Entry] = [:]
        for item in items where item != "dirid.c9r" && !item.hasPrefix(".") {
            let url = dir.appendingPathComponent(item)
            let shortened = item.hasSuffix(".c9s")
            let encName: String
            if shortened {
                guard let n = try? String(contentsOf: url.appendingPathComponent("name.c9s"), encoding: .utf8) else { continue }
                encName = n.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if item.hasSuffix(".c9r") {
                encName = item
            } else { continue }
            var node = Node(url: url, shortened: shortened)
            let name: String
            if let n = try? names.decrypt(encName, parentDirId: id) {
                name = n
            } else if !shortened, let (n, u) = resolveConflict(item, in: dir, dirId: id) {
                name = n
                node = Node(url: u, shortened: false)
            } else { continue }
            guard let kind = nodeKind(node), let a = try? attributes(node, kind) else { continue }
            // 同名只留规范位置那个（只有手工拷贝或损坏才会出现）
            if out[name] != nil, node.url != self.node(name, in: id).url { continue }
            out[name] = Entry(name: name, parentId: id, attributes: a)
        }
        return out.values.sorted { $0.name < $1.name }
    }

    func attributes(_ n: Node, _ kind: Kind) throws -> Attributes {
        switch kind {
        case .file:
            if let f = openFiles[n.contentURL.path] { return f.attributes() }
            guard let s = FileStat(n.contentURL.path) else { throw VaultError.notFound(n.url.path) }
            return Attributes(kind: .file, size: FileCipher.cleartextSize(ciphertextSize: s.size) ?? 0,
                              modificationDate: s.modified, creationDate: s.created, directoryId: nil)
        case .directory:
            let id = try dirIdOfNode(n)
            // 存储目录丢了（损坏）时退回节点自己的日期，条目照样列出来
            guard let s = FileStat(storageURL(id).path) ?? FileStat(n.url.path) else { throw VaultError.notFound(n.url.path) }
            return Attributes(kind: .directory, size: 0, modificationDate: s.modified, creationDate: s.created, directoryId: id)
        case .symlink:
            guard let s = FileStat(n.url.appendingPathComponent("symlink.c9r").path) else { throw VaultError.notFound(n.url.path) }
            return Attributes(kind: .symlink, size: FileCipher.cleartextSize(ciphertextSize: s.size) ?? 0,
                              modificationDate: s.modified, creationDate: s.created, directoryId: nil)
        }
    }

    // MARK: - 同步冲突（规范 §6.5，规则与 Cryptomator 相同）

    /// 网盘同步冲突会产生 `<密文名> (1).c9r`、`<密文名> (conflicted copy …).c9r` 之类的副本。
    /// 找出里面能解密的那段密文名：正本不存在就改回正本；内容相同的目录 / 符号链接副本删掉
    /// （两个目录节点指向同一个目录 ID 很危险：删一个会清空另一个）；其余改名为 `基名 + 冲突后缀 + 扩展名`。
    /// 返回整理后的明文名和节点位置；无法处理（或只读）时返回 nil，条目原样保留、不显示。
    func resolveConflict(_ item: String, in dir: URL, dirId: String) -> (String, URL)? {
        guard !isReadOnly else { return nil }
        let stem = String(item.dropLast(4))
        guard let (clear, range) = conflictCandidate(stem, decrypt: { try? self.names.decrypt($0 + ".c9r", parentDirId: dirId) })
        else { return nil }
        let copyURL = dir.appendingPathComponent(item)
        let canonicalNode = node(clear, in: dirId)
        guard !canonicalNode.shortened else { return nil }
        guard let canonicalKind = nodeKind(canonicalNode) else {
            return (try? fm.moveItem(at: copyURL, to: canonicalNode.url)).map { (clear, canonicalNode.url) }
        }
        let copy = Node(url: copyURL, shortened: false)
        if let k = nodeKind(copy), k == canonicalKind, k != .file {
            let inner = k == .directory ? "dir.c9r" : "symlink.c9r"
            let same = k == .directory
                ? (try? Data(contentsOf: copyURL.appendingPathComponent(inner))) == (try? Data(contentsOf: canonicalNode.url.appendingPathComponent(inner)))
                : (try? FileCipher.decrypt(Data(contentsOf: copyURL.appendingPathComponent(inner)), encKey: masterkey.encKey))
                    == (try? FileCipher.decrypt(Data(contentsOf: canonicalNode.url.appendingPathComponent(inner)), encKey: masterkey.encKey))
            if same {
                try? fm.removeItem(at: copyURL)
                return nil
            }
        }
        // 新名字：基名 + 冲突后缀（最多占可用长度的一半）+ 扩展名；不行就 (1)…(9)
        let ext = (clear as NSString).pathExtension, base = ext.isEmpty || clear.hasPrefix(".") ? clear : (clear as NSString).deletingPathExtension
        let dotExt = ext.isEmpty || clear.hasPrefix(".") ? "" : "." + ext
        let available = (config.shorteningThreshold - 4) / 4 * 3 - 16
        var suffix = String(stem[range.upperBound...])
        while suffix.utf8.count > available / 2 { suffix.removeLast() }
        var tries = suffix.trimmingCharacters(in: .whitespaces).isEmpty ? [] : [base + suffix + dotExt]
        tries += (1...9).map { "\(base) (\($0))\(dotExt)" }
        for candidate in tries {
            let n = node(candidate, in: dirId)
            guard !n.shortened, nodeKind(n) == nil else { continue }
            if (try? fm.moveItem(at: copyURL, to: n.url)) != nil { return (candidate, n.url) }
        }
        return nil
    }

    /// 在去掉 .c9r 的名字里从长到短找能解密的 base64url 片段（也试在 - / _ 处切开的子段），返回明文名和片段位置。
    func conflictCandidate(_ stem: String, decrypt: (String) -> String?) -> (String, Range<String.Index>)? {
        let chars = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        var runs: [Range<String.Index>] = []
        var i = stem.startIndex
        while i < stem.endIndex {
            guard chars.contains(stem[i]) else { i = stem.index(after: i); continue }
            var j = i
            while j < stem.endIndex, chars.contains(stem[j]) { j = stem.index(after: j) }
            var k = j
            while k < stem.endIndex, stem[k] == "=", stem.distance(from: j, to: k) < 2 { k = stem.index(after: k) }
            runs.append(i..<k)
            i = k
        }
        var candidates: [Range<String.Index>] = []
        for r in runs {
            // 片段起点：run 开头或 - / _ 之后；终点：run 结尾或 - / _ 之前
            let starts = [r.lowerBound] + stem[r].indices.filter { "-_".contains(stem[$0]) }.map { stem.index(after: $0) }
            let ends = [r.upperBound] + stem[r].indices.filter { "-_".contains(stem[$0]) }
            for s in starts { for e in ends where s < e { candidates.append(s..<e) } }
        }
        for r in candidates.sorted(by: { stem.distance(from: $0.lowerBound, to: $0.upperBound) > stem.distance(from: $1.lowerBound, to: $1.upperBound) }) {
            let s = String(stem[r])
            if s.count >= 24, s.count % 4 == 0, let clear = decrypt(s) { return (clear, r) }
        }
        return nil
    }

    // MARK: - 节点（以下都要求已持有 lock）

    struct Node {
        let url: URL               // <encName>.c9r 或 <shortened>.c9s
        let shortened: Bool
        var contentURL: URL { shortened ? url.appendingPathComponent("contents.c9r") : url }
    }

    func storageURL(_ dirId: String) -> URL { root.appendingPathComponent(names.dirPath(dirId)) }

    func node(_ name: String, in parentDirId: String) -> Node {
        let enc = names.encrypt(name, parentDirId: parentDirId)
        let dir = storageURL(parentDirId)
        if enc.count > config.shorteningThreshold {
            return Node(url: dir.appendingPathComponent(NameCipher.shortened(enc)), shortened: true)
        }
        return Node(url: dir.appendingPathComponent(enc), shortened: false)
    }

    func nodeKind(_ n: Node) -> Kind? {
        guard let s = FileStat(n.url.path) else { return nil }
        if !s.isDirectory { return n.shortened || !s.isRegular ? nil : .file }
        if FileStat(n.url.appendingPathComponent("dir.c9r").path) != nil { return .directory }
        if FileStat(n.url.appendingPathComponent("symlink.c9r").path) != nil { return .symlink }
        if n.shortened && FileStat(n.url.appendingPathComponent("contents.c9r").path) != nil { return .file }
        return nil
    }

    /// 新建前的检查：名字合法、父目录在、同名条目不存在（断电残留的空节点外壳会被清掉）。
    private func newNode(_ name: String, _ parentId: String) throws -> (Node, String) {
        let name = try Vault.checkName(name)
        try requireDirectory(parentId)
        let n = node(name, in: parentId)
        guard nodeKind(n) == nil else { throw VaultError.alreadyExists(name) }
        try clearLeftover(n)
        return (n, name)
    }

    /// 断电残留：节点目录在，里面却没有 dir.c9r / symlink.c9r / contents.c9r（nodeKind 为 nil）。
    /// 里面只有 name.c9s 和临时文件时清掉以便重建；有别的东西就不动它，报已存在。
    private func clearLeftover(_ n: Node) throws {
        guard let s = FileStat(n.url.path) else { return }
        guard s.isDirectory, let items = try? fm.contentsOfDirectory(atPath: n.url.path),
              items.allSatisfy({ $0.hasPrefix(".") || $0 == "name.c9s" })
        else { throw VaultError.alreadyExists(n.url.lastPathComponent) }
        try fm.removeItem(at: n.url)
    }

    /// 写之前准备好节点外壳：长名要有 .c9s 目录和 name.c9s；目录 / 符号链接节点本身是个目录。
    private func prepare(_ n: Node, name: String, parentId: String, asDirectory: Bool = false) throws {
        if n.shortened {
            try fm.createDirectory(at: n.url, withIntermediateDirectories: true)
            let nameFile = n.url.appendingPathComponent("name.c9s")
            if !fm.fileExists(atPath: nameFile.path) {
                try Vault.atomicWrite(Data(names.encrypt(name, parentDirId: parentId).utf8), to: nameFile)
            }
        } else if asDirectory {
            try fm.createDirectory(at: n.url, withIntermediateDirectories: false)
        }
    }

    /// 锁外把明文流加密进父目录里的临时文件，再在锁内检查、原子改名换上；打开着的句柄随即改读新内容。
    private func install(_ name: String, _ parentId: String, _ next: (Int) throws -> Data) throws {
        try requireWritable()
        let name = try Vault.checkName(name)
        guard directoryExists(id: parentId) else { throw VaultError.notFound("directory \(parentId)") }
        let tmp = try encryptToTemp(in: storageURL(parentId), next)
        do {
            try locked {
                let n = node(name, in: parentId)
                switch nodeKind(n) {
                case .directory?, .symlink?: throw VaultError.alreadyExists(name)
                case .file?: break
                case nil: try clearLeftover(n)
                }
                try prepare(n, name: name, parentId: parentId)
                Vault.copyCreationDate(from: n.contentURL, to: tmp)
                try Vault.rename(tmp, n.contentURL)
                try openFiles[n.contentURL.path]?.reload()
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    /// 明文流 → 加密好的临时文件（.fstmp-*，列目录时忽略），已 fsync。不碰共享状态，可在锁外执行。
    func encryptToTemp(in dir: URL, _ next: (Int) throws -> Data) throws -> URL {
        let tmp = dir.appendingPathComponent(".fstmp-\(UUID().uuidString)")
        let fd = Darwin.open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard fd >= 0 else { throw IO.error("create temp file") }
        do {
            defer { Darwin.close(fd) }
            let h = FileCipher.newHeader(random)
            var out = try FileCipher.encryptHeader(h, encKey: masterkey.encKey)
            var written = 0, index: UInt64 = 0, pending = Data()
            while true {
                let more = try next(Vault.streamPiece)
                pending += more
                let eof = more.isEmpty
                var start = pending.startIndex
                while pending.endIndex - start >= FileCipher.chunkPlainSize || (eof && start < pending.endIndex) {
                    let end = min(start + FileCipher.chunkPlainSize, pending.endIndex)
                    out += try FileCipher.encryptChunk(pending[start..<end], index: index, header: h, nonce: random.bytes(12))
                    index += 1
                    start = end
                }
                pending = Data(pending[start...])
                if out.count >= Vault.streamPiece || eof {
                    try IO.pwrite(fd, out, at: written)
                    written += out.count
                    out = Data()
                }
                if eof { break }
            }
            guard fsync(fd) == 0 else { throw IO.error("fsync") }
        } catch {
            unlink(tmp.path)
            throw error
        }
        return tmp
    }

    /// 删除节点。目录节点先整个改名成临时名（原子地消失），再删它的整棵存储子树；中途断电只留下被忽略的残留。
    private func removeNode(_ n: Node, _ kind: Kind) throws {
        let dirId = kind == .directory ? try dirIdOfNode(n) : nil
        if kind == .file { detach(n.contentURL.path) }
        if n.shortened || kind != .file {
            let trash = n.url.deletingLastPathComponent().appendingPathComponent(".fstmp-\(UUID().uuidString)")
            try Vault.rename(n.url, trash)
            try? fm.removeItem(at: trash)
        } else {
            do { try fm.removeItem(at: n.url) } catch { throw VaultError.io("remove: \(error.localizedDescription)") }
        }
        if let id = dirId {
            var seen = Set<String>()
            purge(id, &seen)
        }
    }

    /// 删除目录 ID 对应的存储目录，并按其中的 dir.c9r 递归删除子目录。根目录永远不删。
    private func purge(_ id: String, _ seen: inout Set<String>) {
        guard !id.isEmpty, seen.insert(id).inserted else { return }
        let dir = storageURL(id)
        for item in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
            if let child = Vault.readDirId(dir.appendingPathComponent(item)) { purge(child, &seen) }
        }
        for path in openFiles.keys where path.hasPrefix(dir.path + "/") { detach(path) }
        try? fm.removeItem(at: dir)
    }

    /// target 是不是 root 目录下面（任意深度）的某个目录。按 dir.c9r 广度遍历，防环。
    private func subtreeContains(_ target: String, under root: String) -> Bool {
        var queue = [root], seen: Set<String> = [root]
        while let id = queue.popLast() {
            let dir = storageURL(id)
            for item in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
                guard let child = Vault.readDirId(dir.appendingPathComponent(item)) else { continue }
                if child == target { return true }
                if seen.insert(child).inserted { queue.append(child) }
            }
        }
        return false
    }

    private func isEmptyStorage(_ id: String) -> Bool {
        let items = (try? fm.contentsOfDirectory(atPath: storageURL(id).path)) ?? []
        return !items.contains { $0 != "dirid.c9r" && ($0.hasSuffix(".c9r") || $0.hasSuffix(".c9s")) }
    }

    /// 打开的文件被删 / 被替换：从表里摘掉，句柄还能用，但不会再换回原位置。
    private func detach(_ path: String) {
        openFiles.removeValue(forKey: path)?.deleted = true
    }

    private func rekey(_ from: URL, _ to: URL) {
        guard let f = openFiles.removeValue(forKey: from.path) else { return }
        f.url = to
        openFiles[to.path] = f
    }

    func openShared(_ url: URL) throws -> OpenFile {
        if let f = openFiles[url.path] {
            f.refs += 1
            return f
        }
        let f = try OpenFile(vault: self, url: url)
        f.refs = 1
        openFiles[url.path] = f
        return f
    }

    /// 最后一个句柄关闭时：换上影子文件、关掉文件描述符。
    func release(_ f: OpenFile) throws {
        f.refs -= 1
        guard f.refs == 0 else { return }
        if openFiles[f.url.path] === f { openFiles[f.url.path] = nil }
        try f.close()
    }

    private func createStorageDir(dirId: String) throws {
        let dir = storageURL(dirId)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // 目录 ID 备份（根目录也写，内容为空）：目录树损坏时可据此重建（规范 §6.2）
        try Vault.atomicWrite(try FileCipher.encrypt(Data(dirId.utf8), encKey: masterkey.encKey, random: random),
                              to: dir.appendingPathComponent("dirid.c9r"))
    }

    func dirIdOfNode(_ n: Node) throws -> String {
        guard let id = Vault.readDirId(n.url) else { throw VaultError.corrupted("dir.c9r") }
        return id
    }

    /// 节点里的 dir.c9r：1–36 字节 UTF-8（空的会指回根目录，形成环，按损坏处理）。
    static func readDirId(_ nodeURL: URL) -> String? {
        guard nodeURL.lastPathComponent.hasSuffix(".c9r") || nodeURL.lastPathComponent.hasSuffix(".c9s"),
              let d = try? Data(contentsOf: nodeURL.appendingPathComponent("dir.c9r")), (1...36).contains(d.count)
        else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// 明文目录路径 → 目录 ID。
    func dirId(of components: [String]) throws -> String {
        var id = ""
        for (i, name) in components.enumerated() {
            let n = node(name, in: id)
            guard let kind = nodeKind(n) else { throw VaultError.notFound("/" + components[...i].joined(separator: "/")) }
            guard kind == .directory else { throw VaultError.notADirectory("/" + components[...i].joined(separator: "/")) }
            id = try dirIdOfNode(n)
        }
        return id
    }

    /// 路径 → (父目录 ID, 名字)；根目录返回 nil。
    private func locate(_ path: String) throws -> (String, String)? {
        let c = try Vault.components(path)
        guard let name = c.last else { return nil }
        return (try locked { try dirId(of: Array(c.dropLast())) }, name)
    }

    private func parent(of path: String) throws -> (String, String) {
        guard let r = try locate(path) else { throw VaultError.invalidName(path) }
        return r
    }

    private func requireDirectory(_ id: String) throws {
        guard directoryExists(id: id) else { throw VaultError.notFound("directory \(id)") }
    }

    private func existingNode(_ name: String, _ parentId: String, as kind: Kind) throws -> Node {
        let n = node(try Vault.checkName(name), in: parentId)
        guard let k = nodeKind(n) else { throw VaultError.notFound(name) }
        guard k == kind else { throw kind == .directory ? VaultError.notADirectory(name) : VaultError.notFound(name) }
        return n
    }

    private func requireWritable() throws { if isReadOnly { throw VaultError.readOnly } }

    // MARK: - 工具

    static let streamPiece = 32 * FileCipher.chunkPlainSize      // 流式导入 / 导出每次 1 MiB

    static func components(_ path: String) throws -> [String] {
        let c = path.split(separator: "/").map { String($0).precomposedStringWithCanonicalMapping }
        for n in c where n == "." || n == ".." || n.contains("\0") { throw VaultError.invalidName(path) }
        return c
    }

    /// 单个名字：非空、不是 . / ..、不含 / 和 NUL；转成 NFC（规范 §3）。
    static func checkName(_ name: String) throws -> String {
        let n = name.precomposedStringWithCanonicalMapping
        guard !n.isEmpty, n != ".", n != "..", !n.contains("/"), !n.contains("\0") else { throw VaultError.invalidName(name) }
        return n
    }

    static func checkPassword(_ p: String) throws {
        guard p.count >= 8 else { throw VaultError.invalidPassword("at least 8 characters") }
        guard !p.contains("\0"), !p.contains(where: \.isNewline) else { throw VaultError.invalidPassword("no NUL or line breaks") }
    }

    /// 随机 UUID v4，小写（目录 ID、vault ID）。
    static func uuid(_ random: RandomSource) -> String {
        var b = [UInt8](random.bytes(16))
        b[6] = (b[6] & 0x0f) | 0x40
        b[8] = (b[8] & 0x3f) | 0x80
        let h = Encoding.hex(b)
        let parts = [h.prefix(8), h.dropFirst(8).prefix(4), h.dropFirst(12).prefix(4), h.dropFirst(16).prefix(4), h.dropFirst(20)]
        return parts.joined(separator: "-")
    }

    /// 备份文件名：<原名>.<旧文件 SHA-256 前 4 字节，大写十六进制>.bkup，与 Cryptomator 相同（规范 §5.2）。
    static func backupName(_ name: String, _ contents: Data) -> String {
        "\(name).\(Encoding.hex(SHA256.hash(data: contents).prefix(4)).uppercased()).bkup"
    }

    static func unverifiedConfig(_ root: URL) throws -> VaultConfig.Unverified {
        let url = root.appendingPathComponent(VaultConfig.fileName)
        guard let d = try? Data(contentsOf: url), let s = String(data: d, encoding: .utf8) else {
            throw VaultError.notFound(url.path)
        }
        return try VaultConfig.decodeUnverified(s)
    }

    static func read(_ url: URL) throws -> Data {
        do { return try Data(contentsOf: url) } catch { throw VaultError.notFound(url.path) }
    }

    static func rename(_ from: URL, _ to: URL) throws {
        guard Darwin.rename(from.path, to.path) == 0 else { throw IO.error("rename") }
    }

    static func setDate(_ date: Date, _ url: URL) throws {
        do { try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path) }
        catch { throw VaultError.notFound(url.path) }
    }

    /// 替换文件时保留原来的创建时间（尽力而为）。
    static func copyCreationDate(from old: URL, to new: URL) {
        guard let s = FileStat(old.path) else { return }
        try? FileManager.default.setAttributes([.creationDate: s.created], ofItemAtPath: new.path)
    }

    /// 同目录临时文件 + fsync + rename(2)：要么是旧内容，要么是完整的新内容。
    static func atomicWrite(_ data: Data, to url: URL) throws {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".fstmp-\(UUID().uuidString)")
        let fd = Darwin.open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard fd >= 0 else { throw IO.error("create temp file") }
        do {
            defer { Darwin.close(fd) }
            try IO.pwrite(fd, data, at: 0)
            guard fsync(fd) == 0 else { throw IO.error("fsync") }
        } catch {
            unlink(tmp.path)
            throw error
        }
        do { try rename(tmp, url) } catch { unlink(tmp.path); throw error }
    }
}

/// lstat 的结果（不跟随符号链接）。
struct FileStat {
    let size: Int
    let isDirectory: Bool
    let isRegular: Bool
    let modified: Date
    let created: Date

    init?(_ path: String) {
        var s = stat()
        guard lstat(path, &s) == 0 else { return nil }
        self.init(s)
    }

    init(_ s: stat) {
        size = Int(s.st_size)
        isDirectory = (s.st_mode & S_IFMT) == S_IFDIR
        isRegular = (s.st_mode & S_IFMT) == S_IFREG
        modified = FileStat.date(s.st_mtimespec)
        created = FileStat.date(s.st_birthtimespec)
    }

    static func date(_ t: timespec) -> Date { Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_nsec) / 1e9) }
}

/// 按偏移读写文件描述符，处理短读写和 EINTR。
enum IO {
    static func error(_ what: String) -> VaultError { VaultError.io("\(what): \(String(cString: strerror(errno)))") }

    static func pread(_ fd: Int32, count: Int, at offset: Int) throws -> Data {
        var d = Data(count: count)
        var done = 0
        while done < count {
            let n = d.withUnsafeMutableBytes { Darwin.pread(fd, $0.baseAddress! + done, count - done, off_t(offset + done)) }
            if n < 0 { if errno == EINTR { continue }; throw error("read") }
            if n == 0 { throw VaultError.corrupted("unexpected end of file") }
            done += n
        }
        return d
    }

    static func pwrite(_ fd: Int32, _ data: Data, at offset: Int) throws {
        var done = 0
        try data.withUnsafeBytes { buf in
            while done < buf.count {
                let n = Darwin.pwrite(fd, buf.baseAddress! + done, buf.count - done, off_t(offset + done))
                if n < 0 { if errno == EINTR { continue }; throw error("write") }
                done += n
            }
        }
    }
}
