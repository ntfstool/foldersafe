import Foundation
import FSKit
import ExtensionFoundation
import FolderSafeCore

@main
struct FolderSafeFSExtension: UnaryFileSystemExtension {
    var fileSystem: FolderSafeFileSystem { FolderSafeFileSystem.shared }
}

/// FolderSafe 的 FSKit 文件系统：资源是 vault 目录（FSPathURLResource），一个资源一个卷。
/// 钥匙来自 App 解锁时放进共享钥匙串的 rawKey；没有钥匙（已上锁）就拒绝加载（EPERM）。
final class FolderSafeFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations {
    static let shared = FolderSafeFileSystem()

    private var volume: VaultVolume?
    private var accessedURL: URL?

    private static func vaultInfo(_ resource: FSResource) -> (URL, String)? {
        guard let r = resource as? FSPathURLResource else { return nil }
        let url = r.url
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("vault.cryptomator").path),
              let id = try? Vault.vaultId(at: url) else { return nil }
        return (url, id)
    }

    private static func uuid(_ vaultId: String) -> UUID {
        UUID(uuidString: vaultId) ?? UUID()
    }

    func probeResource(resource: FSResource, replyHandler: @escaping (FSProbeResult?, (any Error)?) -> Void) {
        guard let (url, id) = Self.vaultInfo(resource) else {
            fsLog.info("probe: not a vault (\(String(describing: resource), privacy: .public))")
            replyHandler(FSProbeResult.notRecognized, nil)
            return
        }
        fsLog.info("probe: vault \(id, privacy: .public) at \(url.path, privacy: .public)")
        replyHandler(FSProbeResult.usable(name: url.lastPathComponent,
                                          containerID: FSContainerIdentifier(uuid: Self.uuid(id))), nil)
    }

    func loadResource(resource: FSResource, options: FSTaskOptions, replyHandler: @escaping (FSVolume?, (any Error)?) -> Void) {
        guard let r = resource as? FSPathURLResource else {
            replyHandler(nil, fs_errorForPOSIXError(EINVAL))
            return
        }
        let url = r.url
        let scoped = url.startAccessingSecurityScopedResource()
        do {
            let id: String
            do { id = try Vault.vaultId(at: url) } catch {
                fsLog.error("load: cannot read vault config at \(url.path, privacy: .public): \(String(describing: error), privacy: .public)")
                throw POSIXFailure(access(url.path, R_OK) == 0 ? EINVAL : EACCES)
            }
            guard let key = UnlockedKeyStore.get(vaultId: id) else {
                fsLog.error("load: no unlocked key for vault \(id, privacy: .public)")
                throw POSIXFailure(EPERM)
            }
            let vault = try Vault.open(at: url, rawKey: key)
            let v = VaultVolume(vault: vault, rootURL: url,
                                volumeID: FSVolume.Identifier(uuid: Self.uuid(id)),
                                name: Self.volumeName(options) ?? url.deletingPathExtension().lastPathComponent)
            volume = v
            accessedURL = scoped ? url : nil
            containerStatus = .ready
            fsLog.info("load: vault \(id, privacy: .public) ready (readOnly=\(vault.isReadOnly))")
            replyHandler(v, nil)
        } catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            fsLog.error("load failed: \(String(describing: error), privacy: .public)")
            replyHandler(nil, fsError(error))
        }
    }

    func unloadResource(resource: FSResource, options: FSTaskOptions, replyHandler: @escaping ((any Error)?) -> Void) {
        volume?.shutdown()
        volume = nil
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = nil
        containerStatus = .notReady(status: fs_errorForPOSIXError(ENODEV))
        fsLog.info("unload")
        replyHandler(nil)
    }

    /// `mount -o volname=名字` 指定卷名（Finder 侧栏显示用）。
    private static func volumeName(_ options: FSTaskOptions) -> String? {
        let opts = options.taskOptions
        for (i, o) in opts.enumerated() {
            let parts: [String]
            if o == "-o", i + 1 < opts.count { parts = opts[i + 1].split(separator: ",").map(String.init) }
            else if o.hasPrefix("-o") { parts = String(o.dropFirst(2)).split(separator: ",").map(String.init) }
            else { continue }
            for p in parts where p.hasPrefix("volname=") {
                let v = String(p.dropFirst("volname=".count))
                if !v.isEmpty { return v }
            }
        }
        return nil
    }
}
