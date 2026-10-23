import Foundation
import CryptoKit

/// File Provider 条目 ID ↔ vault 里位置的对照表（每个 vault 一份，放 App Group 容器）。
///
/// - 目录的条目 ID 就是它的目录 ID（vault 格式里改名 / 移动都不变）；根目录是 rootContainer ↔ 目录 ID ""。
/// - 文件 / 符号链接在格式里没有稳定 ID：给一个随机 ID（"f." 开头），记成（父目录 ID，明文名），经本扩展改名 / 移动时更新。
/// - 内容含明文名，所以落盘前用 vault 钥匙派生的钥匙整份 AES-GCM 加密：没有钥匙（上锁后）读不出任何名字。
/// - 只在一次解锁期间有意义：上锁时 File Provider 域连同这份表一起删掉。丢了也能从 vault 重建：
///   目录 ID 本来就在 vault 里；文件会拿到新 ID（系统按"删除 + 新建"处理）。
/// - 另有一个变化日志（代数 generation），给同步锚点用：重扫 vault 发现的外部变化（网盘同步等）记在这里。
/// 不是线程安全的：调用方（VaultStore）加锁。
final class ItemIndex {
    enum Kind: String, Codable { case file, directory, symlink }

    struct Entry: Codable, Equatable {
        var parent: String          // 父目录 ID（根是 ""）
        var name: String            // NFC 明文名
        var kind: Kind
        var version: String         // 上次报给系统的版本（内容 + 元数据），重扫时比较
        var listed: Bool            // 目录：子项已经报给过系统，之后的外部变化要通知
    }

    struct Change: Codable { var generation: Int; var id: String; var deleted: Bool; var parent: String }

    private struct State: Codable {
        var epoch: String
        var generation: Int
        var entries: [String: Entry]
        var rootListed: Bool
        var changes: [Change]
    }

    static let rootDirId = ""
    private static let maxChanges = 5000

    private var state: State
    private var byLocation: [String: String] = [:]          // "parent\0name" → id
    private var children: [String: Set<String>] = [:]       // parent dirId → ids
    private let fileURL: URL?
    private let key: SymmetricKey
    private(set) var dirty = false

    var epoch: String { state.epoch }
    var generation: Int { state.generation }
    /// 日志里还留着的最早代数；锚点比它还旧就只能让系统重新全量枚举。
    var oldestKnownGeneration: Int { (state.changes.first?.generation ?? state.generation + 1) - 1 }

    /// fileURL 为 nil 时只在内存里（测试用）。
    init(fileURL: URL?, rawKey: Data, vaultId: String) {
        self.fileURL = fileURL
        self.key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: rawKey), salt: Data(vaultId.utf8),
                                          info: Data("foldersafe.fileprovider.index.v1".utf8), outputByteCount: 32)
        state = State(epoch: UUID().uuidString, generation: 0, entries: [:], rootListed: false, changes: [])
        if let fileURL, let blob = try? Data(contentsOf: fileURL),
           let box = try? AES.GCM.SealedBox(combined: blob),
           let plain = try? AES.GCM.open(box, using: key),
           let s = try? JSONDecoder().decode(State.self, from: plain) {
            state = s
        }
        for (id, e) in state.entries {
            byLocation[Self.loc(e.parent, e.name)] = id
            children[e.parent, default: []].insert(id)
        }
    }

    private static func loc(_ parent: String, _ name: String) -> String { parent + "\u{0}" + name }

    static func newFileID() -> String { "f." + UUID().uuidString.lowercased() }
    static func isFileID(_ id: String) -> Bool { id.hasPrefix("f.") }

    // MARK: - 查

    func entry(_ id: String) -> Entry? { state.entries[id] }
    func id(parent: String, name: String) -> String? { byLocation[Self.loc(parent, name)] }
    func childIDs(_ parent: String) -> Set<String> { children[parent] ?? [] }
    func isListed(dirId: String) -> Bool { dirId == Self.rootDirId ? state.rootListed : (state.entries[dirId]?.listed ?? false) }
    var allIDs: [String] { state.entries.keys.sorted() }
    /// 已列过的目录，父目录在前（重扫时先扫上层，被删掉的子树就不用再扫）。
    var listedDirectories: [String] {
        var out = state.rootListed ? [Self.rootDirId] : []
        out += state.entries.filter { $0.value.kind == .directory && $0.value.listed }.map(\.key)
            .sorted { depth($0) < depth($1) }
        return out
    }

    private func depth(_ id: String) -> Int {
        var d = 0, cur = id
        while let e = state.entries[cur], d < 4096 { d += 1; cur = e.parent }
        return d
    }

    /// 目录 a 是否是 b 本身或在 b 下面（按表里已知的关系）。
    func isDirectory(_ a: String, inside b: String) -> Bool {
        var cur = a, n = 0
        while n < 4096 {
            if cur == b { return true }
            guard let e = state.entries[cur] else { return false }
            cur = e.parent
            n += 1
        }
        return false
    }

    // MARK: - 改

    func put(_ id: String, _ e: Entry) {
        if let old = state.entries[id] {
            if old == e { return }
            detach(id, old)
        }
        if let clash = byLocation[Self.loc(e.parent, e.name)], clash != id { removeSubtree(clash) }
        state.entries[id] = e
        byLocation[Self.loc(e.parent, e.name)] = id
        children[e.parent, default: []].insert(id)
        dirty = true
    }

    private func detach(_ id: String, _ e: Entry) {
        if byLocation[Self.loc(e.parent, e.name)] == id { byLocation[Self.loc(e.parent, e.name)] = nil }
        children[e.parent]?.remove(id)
        if children[e.parent]?.isEmpty == true { children[e.parent] = nil }
    }

    /// 删掉条目和表里它下面的所有条目，返回删掉的 ID。
    @discardableResult
    func removeSubtree(_ id: String) -> [String] {
        var removed: [String] = []
        var stack = [id]
        while let cur = stack.popLast() {
            stack.append(contentsOf: childIDs(cur))
            if let e = state.entries[cur] {
                detach(cur, e)
                state.entries[cur] = nil
                removed.append(cur)
            }
            children[cur] = nil
        }
        if !removed.isEmpty { dirty = true }
        return removed
    }

    func markListed(dirId: String) {
        if dirId == Self.rootDirId {
            if !state.rootListed { state.rootListed = true; dirty = true }
        } else if var e = state.entries[dirId], !e.listed {
            e.listed = true
            state.entries[dirId] = e
            dirty = true
        }
    }

    /// 记一次外部变化（给同步锚点用）。
    func recordChange(_ id: String, deleted: Bool, parent: String) {
        state.generation += 1
        state.changes.append(Change(generation: state.generation, id: id, deleted: deleted, parent: parent))
        if state.changes.count > Self.maxChanges { state.changes.removeFirst(state.changes.count - Self.maxChanges) }
        dirty = true
    }

    func changes(after generation: Int) -> [Change] { state.changes.filter { $0.generation > generation } }

    // MARK: - 落盘

    func saveIfNeeded() throws {
        guard dirty else { return }
        guard let fileURL else { dirty = false; return }
        let plain = try JSONEncoder().encode(state)
        guard let sealed = try AES.GCM.seal(plain, using: key).combined else { return }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try sealed.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try sealed.write(to: fileURL, options: [.atomic])
        #endif
        dirty = false
    }
}
