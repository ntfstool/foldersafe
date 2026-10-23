import Foundation

/// 用户登记过的 vault 清单（App Group 共享，App 和扩展都能读）。只存位置和显示名，不存任何钥匙。
public struct VaultRecord: Codable, Identifiable, Equatable {
    public var id: String                 // vault ID（vault.cryptomator 里的 jti）
    public var name: String               // 显示名
    public var path: String               // vault 目录的路径（提示用；实际访问用 bookmark）
    public var bookmark: Data?            // 安全作用域书签（沙盒 App、iOS 必需）
    public var mountPoint: String?        // macOS FSKit：挂载到的文件夹
    public var lastOpened: Date?

    public init(id: String, name: String, path: String, bookmark: Data? = nil, mountPoint: String? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.bookmark = bookmark
        self.mountPoint = mountPoint
    }

    /// 解析书签得到可访问的 URL；调用方负责 start/stopAccessingSecurityScopedResource。
    public func resolveURL() -> URL? {
        guard let bookmark else { return URL(fileURLWithPath: path) }
        var stale = false
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
        #else
        let options: URL.BookmarkResolutionOptions = []
        #endif
        return try? URL(resolvingBookmarkData: bookmark, options: options, relativeTo: nil, bookmarkDataIsStale: &stale)
    }
}

public enum VaultRegistry {
    private static let key = "vaults.v1"

    public static func all() -> [VaultRecord] {
        guard let d = SharedConfig.defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([VaultRecord].self, from: d)) ?? []
    }

    public static func save(_ records: [VaultRecord]) {
        SharedConfig.defaults.set(try? JSONEncoder().encode(records), forKey: key)
    }

    public static func upsert(_ r: VaultRecord) {
        var list = all().filter { $0.id != r.id }
        list.append(r)
        save(list)
    }

    public static func remove(id: String) { save(all().filter { $0.id != id }) }

    public static func record(id: String) -> VaultRecord? { all().first { $0.id == id } }
}
