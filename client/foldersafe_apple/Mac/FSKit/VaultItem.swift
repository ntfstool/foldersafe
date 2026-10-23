import Foundation
import FSKit
import FolderSafeCore

/// 交给 FSKit 的条目对象。身份（id）在一次挂载内对同一路径稳定；路径由节点表按 parent 链现算，
/// 所以目录改名后里面的条目不用逐个更新。
final class VaultItem: FSItem {
    let id: UInt64
    init(id: UInt64) {
        self.id = id
        super.init()
    }
    var identifier: FSItem.Identifier { FSItem.Identifier(rawValue: id)! }
}

/// 节点表里的一条：挂载期间见过的每个路径一条（删掉时移除）。
struct Node {
    var parent: UInt64
    var name: String                 // 显示名（vault 里存的名字，NFC）
    var kind: Vault.Kind
    var dirId: String?               // 目录：vault 里的目录 ID（改名、移动都不变）
    var size: UInt64 = 0             // 文件：明文大小；符号链接：目标长度
    var symlinkTarget: String?
    var mode: UInt32?                // chmod 只记在内存里（v1 格式不存权限）
    var flags: UInt32 = 0
    var mtime: timespec              // 取自密文节点（内核 Attributes），setattr 时写回
    var ctime: timespec
    var atime: timespec              // 只在内存里
    var birthtime: timespec
    var xattrs: [String: Data] = [:] // Finder 元数据等，只在内存里
    var deleted = false
}

/// 目录的明文列表缓存：子节点 id（按 id 排序 = 枚举 cookie 的顺序）。
struct Listing {
    var ids: [UInt64]                // 升序
    var loadedAt: Date
}

extension Node {
    init(parent: UInt64, entry e: Vault.Entry) {
        let m = timespec.from(e.attributes.modificationDate)
        self.init(parent: parent, name: e.name, kind: e.kind, dirId: e.attributes.directoryId,
                  size: UInt64(max(0, e.attributes.size)), mtime: m, ctime: m, atime: m,
                  birthtime: timespec.from(e.attributes.creationDate))
    }

    /// 用内核读到的最新属性刷新（权限、xattr 这些只在内存里的保留）。
    mutating func update(_ a: Vault.Attributes) {
        kind = a.kind
        dirId = a.directoryId
        size = UInt64(max(0, a.size))
        let m = timespec.from(a.modificationDate)
        if m != mtime { mtime = m; ctime = m }
        birthtime = timespec.from(a.creationDate)
    }
}

extension timespec: @retroactive Equatable {
    public static func == (a: timespec, b: timespec) -> Bool { a.tv_sec == b.tv_sec && a.tv_nsec == b.tv_nsec }
}

extension timespec {
    var date: Date { Date(timeIntervalSince1970: TimeInterval(tv_sec) + TimeInterval(tv_nsec) / 1_000_000_000) }
}

extension timespec {
    static func from(_ date: Date) -> timespec {
        let t = date.timeIntervalSince1970
        let s = floor(t)
        return timespec(tv_sec: Int(s), tv_nsec: Int((t - s) * 1_000_000_000))
    }
    static var now: timespec {
        var ts = timespec()
        clock_gettime(CLOCK_REALTIME, &ts)
        return ts
    }
}

extension Vault.Kind {
    var itemType: FSItem.ItemType {
        switch self {
        case .file: return .file
        case .directory: return .directory
        case .symlink: return .symlink
        }
    }
    var typeBits: UInt32 {
        switch self {
        case .file: return UInt32(S_IFREG)
        case .directory: return UInt32(S_IFDIR)
        case .symlink: return UInt32(S_IFLNK)
        }
    }
    var defaultPermissions: UInt32 {
        switch self {
        case .file: return 0o644
        case .directory, .symlink: return 0o755
        }
    }
}
