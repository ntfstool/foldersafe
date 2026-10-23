import Foundation

/// 打开的文件句柄：随机读写，按 32 KiB 块加解密，只碰用到的块；文件头解开一次后缓存。
/// - 线程安全：所有方法都在 Vault 的锁里执行。同一个文件的多个句柄共用一份状态，看到的内容一致。
/// - 写入不直接改原文件：第一次写时把密文克隆成同目录的影子文件（APFS 克隆，几乎不花时间和空间），之后的写都落在影子上，
///   synchronize() / close() 时 fsync 并原子改名换上原文件。中途断电 = 原文件完好，只丢最后一次同步之后的写入。
///   文件系统不支持克隆时：16 MiB 以内复制一份；更大的文件退回原地写（与 Cryptomator 相同，断电可能坏掉正在写的块）。
/// - 改写的块都用新的随机 nonce（规范 §6.1）；写到文件末尾之后先补零；截断会重新加密新的最后一块。
/// - 文件被改名 / 移动后句柄照常可用；被删除后还能读写，但不会再落盘（同 POSIX unlink）。
/// - 用完必须 close()（deinit 也会兜底关闭，但那时出的错没人知道）。
public final class VaultFile: @unchecked Sendable {        // 可变状态都在 vault.lock 里访问
    let vault: Vault
    let file: OpenFile
    public let isWritable: Bool
    private var isClosed = false

    init(vault: Vault, file: OpenFile, writable: Bool) {
        self.vault = vault
        self.file = file
        self.isWritable = writable
    }

    deinit { try? close() }

    /// 明文大小（含还没同步的写入）。
    public var size: Int { vault.locked { file.size } }

    public func attributes() throws -> Vault.Attributes {
        try vault.locked { try check(); return file.attributes() }
    }

    /// 读 [offset, offset + count)，超出文件末尾的部分不返回（offset 在末尾之后返回空）。
    public func read(at offset: Int, count: Int) throws -> Data {
        try vault.locked { try check(); return try file.read(at: offset, count: count) }
    }

    public func write(_ data: Data, at offset: Int) throws {
        try vault.locked { try check(write: true); try file.write(data, at: offset) }
    }

    public func truncate(to size: Int) throws {
        try vault.locked { try check(write: true); try file.truncate(to: size) }
    }

    /// 把写入落盘：fsync 后把影子文件原子换上。
    public func synchronize() throws {
        try vault.locked { try check(); try file.commit() }
    }

    public func setModificationDate(_ date: Date) throws {
        try vault.locked { try check(write: true); try file.setModificationDate(date) }
    }

    /// 关闭；最后一个句柄关闭时同步。同步失败会抛错，影子文件留在盘上不删。重复关闭无害。
    public func close() throws {
        try vault.locked {
            guard !isClosed else { return }
            isClosed = true
            try vault.release(file)
        }
    }

    private func check(write: Bool = false) throws {
        if isClosed { throw VaultError.closed }
        if write && !isWritable { throw VaultError.readOnly }
    }
}

/// 一个打开的密文文件（同一路径的句柄共用）。所有方法都要求调用方已持有 vault.lock。
final class OpenFile {
    unowned let vault: Vault
    var url: URL                         // 节点内容文件；移动时由 Vault 更新
    var refs = 0
    var deleted = false                  // 已被删除或被替换：只在内存 / 临时文件里继续，不再换回 url
    private var fd: Int32                // 当前读写的文件：没有写入时是 url，有写入时是影子文件
    private var shadow: URL?
    private var inPlace = false
    private var needsSync = false
    private var header: FileCipher.Header
    private(set) var size: Int
    private var cache: (index: Int, plain: Data, dirty: Bool)?     // 只缓存一个块：顺序小块读写不用反复加解密
    private var touched: Date?                                     // 最后写入时间（缓存块还没落盘时也要反映出来）

    static let copyLimit = 16 << 20
    private static let cs = FileCipher.chunkPlainSize

    init(vault: Vault, url: URL) throws {
        self.vault = vault
        self.url = url
        let fd = Darwin.open(url.path, O_RDONLY)
        guard fd >= 0 else { throw VaultError.notFound(url.path) }
        do {
            (header, size) = try OpenFile.load(fd, vault.masterkey.encKey)
        } catch {
            Darwin.close(fd)
            throw error
        }
        self.fd = fd
    }

    private static func load(_ fd: Int32, _ encKey: Data) throws -> (FileCipher.Header, Int) {
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw IO.error("fstat") }
        guard let size = FileCipher.cleartextSize(ciphertextSize: Int(st.st_size)) else { throw VaultError.corrupted("ciphertext size") }
        return (try FileCipher.decryptHeader(try IO.pread(fd, count: FileCipher.headerSize, at: 0), encKey: encKey), size)
    }

    func attributes() -> Vault.Attributes {
        var st = stat()
        fstat(fd, &st)
        let s = FileStat(st)
        return Vault.Attributes(kind: .file, size: size, modificationDate: touched ?? s.modified,
                                creationDate: FileStat(url.path)?.created ?? s.created, directoryId: nil)
    }

    // MARK: 读

    func read(at offset: Int, count: Int) throws -> Data {
        guard offset >= 0, count >= 0 else { throw VaultError.invalidArgument("offset \(offset) count \(count)") }
        let end = offset > size ? offset : min(size, offset + min(count, size))
        var out = Data(capacity: max(0, end - offset))
        var pos = offset
        while pos < end {
            let i = pos / OpenFile.cs, start = pos - i * OpenFile.cs
            let c = try chunk(i)
            let n = min(c.count - start, end - pos)
            out.append(c[start..<start + n])
            pos += n
        }
        return out
    }

    /// 第 i 块的明文（0 起始下标）。
    private func chunk(_ i: Int) throws -> Data {
        if let c = cache, c.index == i { return c.plain }
        try flush()
        let len = min(OpenFile.cs, size - i * OpenFile.cs)
        let cipher = try IO.pread(fd, count: len + FileCipher.chunkOverhead,
                                  at: FileCipher.headerSize + i * FileCipher.chunkCipherSize)
        let plain = Data(try FileCipher.decryptChunk(cipher, index: UInt64(i), header: header))
        guard plain.count == len else { throw VaultError.corrupted("chunk \(i) size") }
        cache = (i, plain, false)
        return plain
    }

    // MARK: 写

    func write(_ data: Data, at offset: Int) throws {
        guard offset >= 0, offset <= Int.max - data.count else { throw VaultError.invalidArgument("offset \(offset)") }
        guard !data.isEmpty else { return }
        try beginWrite()
        try zeroFill(to: offset)
        try put(data, at: offset)
    }

    func truncate(to newSize: Int) throws {
        guard newSize >= 0 else { throw VaultError.invalidArgument("size \(newSize)") }
        guard newSize != size else { return }
        try beginWrite()
        if newSize > size { return try zeroFill(to: newSize) }
        let full = newSize / OpenFile.cs, rem = newSize % OpenFile.cs
        if let c = cache, c.index > full || (c.index == full && rem == 0) { cache = nil }   // 被截掉的块（脏的也不要了）
        if rem > 0 {
            let plain = try chunk(full)                    // 新的最后一块：截短后用新 nonce 重新加密
            cache = (full, Data(plain.prefix(rem)), true)
            try flush()
        }
        let length = FileCipher.headerSize + full * FileCipher.chunkCipherSize + (rem > 0 ? rem + FileCipher.chunkOverhead : 0)
        guard ftruncate(fd, off_t(length)) == 0 else { throw IO.error("truncate") }
        size = newSize
        touched = Date()
    }

    /// 文件末尾到 offset 之间补零（逐块，超大空洞也不会一次占很多内存）。
    private func zeroFill(to offset: Int) throws {
        while size < offset {
            try put(Data(count: min(offset - size, OpenFile.cs - size % OpenFile.cs)), at: size)
        }
    }

    /// 写入 data（offset 不超过当前大小）。整块覆盖的块不用先解密旧内容。
    private func put(_ data: Data, at offset: Int) throws {
        var pos = 0
        while pos < data.count {
            let at = offset + pos, i = at / OpenFile.cs, start = at - i * OpenFile.cs
            let n = min(OpenFile.cs - start, data.count - pos)
            let piece = data[(data.startIndex + pos)..<(data.startIndex + pos + n)]
            let existing = min(OpenFile.cs, max(0, size - i * OpenFile.cs))
            var plain: Data
            if start == 0 && n >= existing {
                plain = Data(piece)
            } else {
                plain = try chunk(i)
                if plain.count < start + n { plain.append(Data(count: start + n - plain.count)) }
                plain.replaceSubrange(start..<(start + n), with: piece)
            }
            if let c = cache, c.index != i { try flush() }
            cache = (i, plain, true)
            size = max(size, i * OpenFile.cs + plain.count)
            pos += n
        }
        touched = Date()
    }

    /// 缓存的脏块加密落盘（新的随机 nonce）。
    private func flush() throws {
        guard let c = cache, c.dirty else { return }
        let cipher = try FileCipher.encryptChunk(c.plain, index: UInt64(c.index), header: header, nonce: vault.random.bytes(12))
        try IO.pwrite(fd, cipher, at: FileCipher.headerSize + c.index * FileCipher.chunkCipherSize)
        cache?.dirty = false
    }

    /// 第一次写之前准备好可写的副本：克隆 → 复制 → 原地写，依次退让。
    private func beginWrite() throws {
        needsSync = true
        guard shadow == nil, !inPlace else { return }
        // 被删的文件原位置已经没了：副本放系统临时目录，只为让句柄继续可写
        let dir = deleted ? FileManager.default.temporaryDirectory : url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".fstmp-\(UUID().uuidString)")
        var ok = fclonefileat(fd, AT_FDCWD, tmp.path, 0) == 0           // 克隆 fd 指向的版本，不怕路径已被替换
        if !ok && (size <= OpenFile.copyLimit || deleted) {
            let out = Darwin.open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
            ok = out >= 0 && fcopyfile(fd, out, nil, copyfile_flags_t(COPYFILE_DATA)) == 0
            if out >= 0 { Darwin.close(out) }
        }
        if !ok {
            unlink(tmp.path)
            if deleted { throw IO.error("copy deleted file") }
            // 退回原地写。先确认路径上还是我们打开的那个文件，否则会用错文件头把别人的文件写坏
            let rw = Darwin.open(url.path, O_RDWR)
            guard rw >= 0 else { throw IO.error("open for writing") }
            var a = stat(), b = stat()
            guard fstat(fd, &a) == 0, fstat(rw, &b) == 0, a.st_ino == b.st_ino, a.st_dev == b.st_dev else {
                Darwin.close(rw)
                throw VaultError.io("file was replaced on disk")
            }
            Darwin.close(fd)
            fd = rw
            inPlace = true
            return
        }
        let rw = Darwin.open(tmp.path, O_RDWR)
        guard rw >= 0 else {
            unlink(tmp.path)
            throw IO.error("open shadow")
        }
        Darwin.close(fd)
        fd = rw
        shadow = tmp
    }

    // MARK: 同步 / 关闭

    func commit() throws {
        try flush()
        guard needsSync else { return }
        guard fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0 else { throw IO.error("fsync") }
        if let s = shadow, !deleted {
            Vault.copyCreationDate(from: url, to: s)
            try Vault.rename(s, url)             // fd 仍指向同一个 inode，它现在就是正式文件
            shadow = nil
        }
        needsSync = false
    }

    func setModificationDate(_ date: Date) throws {
        try flush()                              // 先落盘，免得之后的落盘把时间又改掉
        guard let path = shadow?.path ?? (deleted ? nil : url.path) else { return }
        try Vault.setDate(date, URL(fileURLWithPath: path))
        touched = nil
    }

    /// 文件被整文件写入替换后：丢掉影子和缓存，改读新文件。
    func reload() throws {
        if let s = shadow { unlink(s.path) }
        shadow = nil
        cache = nil
        inPlace = false
        needsSync = false
        touched = nil
        let nfd = Darwin.open(url.path, O_RDONLY)
        guard nfd >= 0 else { throw VaultError.notFound(url.path) }
        Darwin.close(fd)
        fd = nfd
        (header, size) = try OpenFile.load(fd, vault.masterkey.encKey)
    }

    /// 同步失败时影子文件留在盘上（数据还能救），错误照抛。
    func close() throws {
        defer {
            Darwin.close(fd)
            if deleted, let s = shadow { unlink(s.path) }
        }
        if !deleted { try commit() }
    }
}
