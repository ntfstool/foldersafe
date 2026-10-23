import FileProvider
import UniformTypeIdentifiers

extension NSFileProviderItemIdentifier {
    /// VaultStore 的条目 ID（根是 ""）↔ 系统的条目 ID（根是 .rootContainer）。
    init(storeID: String) {
        self = storeID == ItemIndex.rootDirId ? .rootContainer : NSFileProviderItemIdentifier(storeID)
    }
    var storeID: String { self == .rootContainer ? ItemIndex.rootDirId : rawValue }
}

final class FileProviderItem: NSObject, NSFileProviderItem {
    let info: ItemInfo

    init(_ info: ItemInfo) { self.info = info }

    var itemIdentifier: NSFileProviderItemIdentifier { NSFileProviderItemIdentifier(storeID: info.id) }
    var parentItemIdentifier: NSFileProviderItemIdentifier { NSFileProviderItemIdentifier(storeID: info.parent) }
    var filename: String { info.isRoot ? "/" : info.name }

    var contentType: UTType {
        switch info.kind {
        case .directory:
            // 包（.app、.rtfd 等）在 vault 里就是目录，类型要和扩展名一致
            if let t = UTType(filenameExtension: (info.name as NSString).pathExtension), t.conforms(to: .package) { return t }
            return .folder
        case .symlink: return .symbolicLink
        case .file:
            // 文件不能被当成包（目录）
            guard let t = UTType(filenameExtension: (info.name as NSString).pathExtension), !t.conforms(to: .directory) else { return .data }
            return t
        }
    }

    var capabilities: NSFileProviderItemCapabilities {
        if info.readOnly {
            return info.kind == .directory ? [.allowsReading, .allowsContentEnumerating] : [.allowsReading]
        }
        // 没有 .allowsTrashing：删除就是真删（不提供废纸篓）
        var c: NSFileProviderItemCapabilities = [.allowsReading, .allowsWriting, .allowsRenaming, .allowsReparenting, .allowsDeleting]
        if info.kind == .directory { c.formUnion([.allowsAddingSubItems, .allowsContentEnumerating]) }
        if info.isRoot { c = [.allowsReading, .allowsWriting, .allowsAddingSubItems, .allowsContentEnumerating] }
        return c
    }

    var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(contentVersion: info.contentVersion, metadataVersion: info.metadataVersion)
    }

    var documentSize: NSNumber? { info.kind == .directory ? nil : NSNumber(value: info.size) }
    var contentModificationDate: Date? { info.modified }
    var creationDate: Date? { info.created }
    var symlinkTargetPath: String? { info.symlinkTarget }

    var fileSystemFlags: NSFileProviderFileSystemFlags {
        var f: NSFileProviderFileSystemFlags = [.userReadable]
        if !info.readOnly { f.insert(.userWritable) }
        if info.kind == .directory { f.insert(.userExecutable) }
        return f
    }

    /// 根目录：按需下载、远端一改就把本地副本清掉（明文副本尽量少）；其余条目继承。
    var contentPolicy: NSFileProviderContentPolicy {
        info.isRoot ? .downloadLazilyAndEvictOnRemoteUpdate : .inherited
    }
}
