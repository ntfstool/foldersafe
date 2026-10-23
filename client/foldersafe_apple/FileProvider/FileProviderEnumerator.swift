import FileProvider

/// 同步锚点："<epoch>:<generation>"。epoch 变了（表重建）或日志不够旧，就让系统重新全量枚举。
enum SyncAnchorCodec {
    static func make(_ a: (epoch: String, generation: Int)) -> NSFileProviderSyncAnchor {
        NSFileProviderSyncAnchor(Data("\(a.epoch):\(a.generation)".utf8))
    }
    static func parse(_ anchor: NSFileProviderSyncAnchor) -> (epoch: String, generation: Int)? {
        guard let s = String(data: anchor.rawValue, encoding: .utf8), let i = s.lastIndex(of: ":"),
              let g = Int(s[s.index(after: i)...]) else { return nil }
        return (String(s[..<i]), g)
    }
}

/// 目录枚举器（container = 某个目录）和工作集枚举器（container = nil）。
final class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {
    private let ext: FileProviderExtension
    private let dirId: String?                   // nil = 工作集
    private var listing: [ItemInfo]?             // 第一页时列一次，后续页从这里取
    private let queue = DispatchQueue(label: "app.foldersafe.fileprovider.enumerator", qos: .userInitiated)

    init(ext: FileProviderExtension, dirId: String?) {
        self.ext = ext
        self.dirId = dirId
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        queue.async { [self] in
            let t0 = Date()
            do {
                let store = try ext.store()
                let isInitial = page.rawValue == NSFileProviderPage.initialPageSortedByName as Data
                    || page.rawValue == NSFileProviderPage.initialPageSortedByDate as Data
                if isInitial || listing == nil {
                    if let dirId {
                        listing = try store.list(dirId)
                    } else {
                        _ = ext.rescanIfDue(force: true)
                        listing = store.knownItems()
                    }
                }
                let all = listing ?? []
                #if DEBUG
                NSLog("FolderSafe FP: enumerate %@ start=%@ suggested=%d total=%d (%.3fs)", dirId ?? "workingSet",
                      String(data: page.rawValue, encoding: .utf8) ?? "initial", observer.suggestedPageSize ?? -1, all.count, Date().timeIntervalSince(t0))
                #endif
                let start = isInitial ? 0 : (String(data: page.rawValue, encoding: .utf8).flatMap(Int.init) ?? 0)
                let size = max(observer.suggestedPageSize ?? 0, 1000)        // 系统建议 200；一页多给些，少几次往返
                let end = min(start + size, all.count)
                if start < end { observer.didEnumerate(all[start..<end].map(FileProviderItem.init)) }
                if end < all.count {
                    observer.finishEnumerating(upTo: NSFileProviderPage(Data(String(end).utf8)))
                } else {
                    listing = nil
                    observer.finishEnumerating(upTo: nil)
                }
            } catch {
                observer.finishEnumeratingWithError(FileProviderExtension.nsError(error))
            }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        queue.async { [self] in
            do {
                let store = try ext.store()
                _ = ext.rescanIfDue(force: dirId == nil)
                guard let a = SyncAnchorCodec.parse(anchor) else { throw StoreError.syncAnchorExpired }
                let current = store.anchor
                let (updated, deleted) = try store.changes(after: a.generation, epoch: a.epoch, only: dirId)
                if !deleted.isEmpty { observer.didDeleteItems(withIdentifiers: deleted.map { NSFileProviderItemIdentifier(storeID: $0) }) }
                if !updated.isEmpty { observer.didUpdate(updated.map(FileProviderItem.init)) }
                observer.finishEnumeratingChanges(upTo: SyncAnchorCodec.make(current), moreComing: false)
            } catch {
                observer.finishEnumeratingWithError(FileProviderExtension.nsError(error))
            }
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        queue.async { [self] in
            guard let store = try? ext.store() else { return completionHandler(nil) }
            completionHandler(SyncAnchorCodec.make(store.anchor))
        }
    }
}
