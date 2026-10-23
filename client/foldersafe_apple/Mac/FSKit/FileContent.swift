import Foundation
import FolderSafeCore

/// 一个文件在挂载期间的内容句柄：包着内核的 VaultFile（按 32 KiB 块随机读写，写在影子副本上，
/// synchronize / close 时原子换上）。所有调用都在卷的锁里进行。
final class FileContent {
    let file: VaultFile
    /// FSKit 当前的打开模式（open 时并入，close 时换成 keepingModes）。为空表示没人打开。
    var openModes: FSOpenSet = []
    /// 上次同步之后有没有写过（决定 synchronize / 关闭时要不要落盘）。
    var dirty = false
    var lastUse = Date()

    init(_ file: VaultFile) { self.file = file }

    var size: Int { file.size }

    func read(at offset: Int, into buf: UnsafeMutableRawBufferPointer) throws -> Int {
        lastUse = Date()
        let d = try file.read(at: offset, count: buf.count)
        d.copyBytes(to: buf)
        return d.count
    }

    func write(_ data: Data, at offset: Int) throws {
        lastUse = Date()
        try file.write(data, at: offset)
        dirty = true
    }

    func truncate(to size: Int) throws {
        lastUse = Date()
        try file.truncate(to: size)
        dirty = true
    }

    func synchronize() throws {
        guard dirty else { return }
        try file.synchronize()
        dirty = false
    }

    /// 关闭（会同步）。失败时内核把影子文件留在盘上，错误照抛。
    func close() throws {
        try file.close()
        dirty = false
    }
}

/// FSKit 的 open 模式（读 / 写）。
struct FSOpenSet: OptionSet {
    let rawValue: Int
    static let read = FSOpenSet(rawValue: 1)
    static let write = FSOpenSet(rawValue: 2)
}
