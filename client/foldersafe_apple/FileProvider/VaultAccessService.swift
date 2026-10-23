import FileProvider
import FolderSafeCore

/// App → 扩展 交接 vault 目录的访问权（XPC，NSFileProviderService）。
///
/// 为什么需要：macOS 上 App 建的安全作用域书签是"App 专属"的，扩展（另一个签名身份、沙盒里）解析不出访问权
/// （2026-10-23 实测：别的沙盒进程解析 App 的书签报 "isn't in the correct format"；指向文件夹的文档作用域书签系统不允许建）。
/// 做法：App 解析自己的书签拿到带访问权的 URL，经 XPC 发给扩展（NSURL 过 XPC 时会带上访问权）；
/// 扩展用它建一份**自己的**书签存进 App Group defaults，以后扩展进程重启也能自己解析。书签本身不含钥匙，也不含明文名。
/// macOS 直装版的 App 不在沙盒里，发来的 URL 不带访问权；扩展靠沙盒例外（家目录、/Volumes）直接读，
/// 这里只确认读得到（读不到回 vaultUnreadableReason，App 据此提示换位置）。
final class VaultAccessServiceSource: NSObject, NSFileProviderServiceSource, NSXPCListenerDelegate, FolderSafeVaultAccessXPC {
    let serviceName = NSFileProviderServiceName(FileProviderPresenter.vaultAccessServiceName)
    private weak var ext: FileProviderExtension?
    private let listener = NSXPCListener.anonymous()

    init(ext: FileProviderExtension) {
        self.ext = ext
        super.init()
        listener.delegate = self
        listener.resume()
    }

    var isRestricted: Bool { true }          // 只有能管理这个域的进程（我们的 App）能连

    func makeListenerEndpoint() throws -> NSXPCListenerEndpoint { listener.endpoint }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        c.exportedInterface = NSXPCInterface(with: FolderSafeVaultAccessXPC.self)
        c.exportedObject = self
        c.resume()
        return true
    }

    func grantVaultAccess(_ url: URL, vaultId: String, reply: @escaping (Bool, String?) -> Void) {
        guard let ext, vaultId == ext.vaultId else { return reply(false, "wrong domain") }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard (try? Vault.vaultId(at: url)) == vaultId else {
            return reply(false, FileProviderPresenter.vaultUnreadableReason + ": " + url.path)
        }
        let key = FileProviderPresenter.extensionBookmarkKey(vaultId)
        do {
            #if os(macOS)
            let bm = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            #else
            let bm = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            #endif
            SharedConfig.defaults.set(bm, forKey: key)
        } catch {
            // 读得到却建不了书签（直装版靠沙盒例外读到时可能如此）：不存书签，store() 按登记的路径打开；
            // 旧书签可能指向别处，删掉
            SharedConfig.defaults.removeObject(forKey: key)
            NSLog("FolderSafe FP: vault readable but no bookmark (%@); using the registered path", String(describing: error))
        }
        ext.resetSession()
        reply(true, nil)
    }
}

extension FileProviderExtension: NSFileProviderServicing {
    func supportedServiceSources(for itemIdentifier: NSFileProviderItemIdentifier,
                                 completionHandler: @escaping ([NSFileProviderServiceSource]?, Error?) -> Void) -> Progress {
        completionHandler([accessService], nil)
        let p = Progress(totalUnitCount: 1)
        p.completedUnitCount = 1
        return p
    }
}
