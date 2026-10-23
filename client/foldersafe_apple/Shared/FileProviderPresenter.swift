import Foundation
import FileProvider
import FolderSafeCore
#if os(macOS)
import AppKit
#endif

/// 用 File Provider 呈现 vault（iPhone；macOS 13–25；Mac App Store 版；直装版在 FSKit 不可用时）。
///
/// 每个已解锁的 vault 一个 NSFileProviderDomain：域 ID = vault ID，显示名 = vault 名。
/// 调用约定（同 VaultPresenter）：present 之前 App 已把 rawKey 放进 UnlockedKeyStore、VaultRecord 已登记（含书签）；
/// dismiss 成功之后 App 再删钥匙（dismiss 期间扩展还要用钥匙把没写回的改动写进 vault）。
///
/// 明文落盘情况：解锁期间，用户打开过 / 拷进来的文件在系统副本里是明文
/// （macOS：~/Library/CloudStorage/<App 名>-<vault 名>/；iPhone：File Provider Storage）。dismiss 删除整个域，副本随之删除。
public final class FileProviderPresenter: VaultPresenter {
    public enum Failure: LocalizedError {
        /// 还有改动没写回 vault，这次没有上锁（域和钥匙都还在）。稍后再试，或 force。
        case unsyncedChanges
        /// 仅 macOS、force：域已删除、已上锁，但来不及写回 vault 的文件以明文保留在这个位置，界面应提示用户拷回 vault 后删除。
        case unsavedChangesPreserved(URL)
        /// 系统没给出域的位置。
        case noUserVisibleURL
        /// 没能把 vault 目录的访问权交给扩展（扩展在沙盒里，自己打不开用户选的目录）。
        case vaultNotAccessible(String)
        /// 仅 macOS 直装版：vault 放在扩展够不着的位置（扩展的沙盒例外只覆盖家目录和外接盘 /Volumes）。
        /// 界面应提示把 vault 文件夹挪到家目录里或外接盘上，再重新添加。
        case vaultLocationNotSupported(String)
        /// 系统没能启动 FolderSafe 的 File Provider 扩展（macOS 实测：LaunchServices 里登记的是另一份已经不存在的
        /// FolderSafe.app 的扩展时，runningboardd 拒绝启动，App 侧报 extensionKit Code=2 / "Client not authorized"）。
        case extensionUnavailable(String)
        /// 用户在系统里关掉了这个位置（macOS：系统设置 → 通用 → 登录项与扩展 → 文件提供程序 → FolderSafe）。
        /// 域已经加上了，用户打开开关后再调一次 present 即可。
        case disabledByUser

        public var errorDescription: String? {
            switch self {
            case .unsyncedChanges: return "Some changes have not been saved into the vault yet. Try again in a moment."
            case .unsavedChangesPreserved(let u): return "Unsaved files were kept at \(u.path). Move them back into the vault, then delete them."
            case .noUserVisibleURL: return "The system did not provide a location for this vault."
            case .vaultNotAccessible(let why): return "FolderSafe could not give its Finder extension access to the vault folder (\(why))."
            case .vaultLocationNotSupported(let path): return "FolderSafe's Finder extension can't open vaults at \(path). Move the vault folder into your home folder or onto an external drive, then add it again."
            case .extensionUnavailable(let why): return "The system could not start FolderSafe's Finder extension (\(why))."
            case .disabledByUser:
                #if os(macOS)
                return "FolderSafe is turned off in System Settings > General > Login Items & Extensions > File Providers."
                #else
                return "FolderSafe is turned off in the Files app. Turn it on under Browse > More (…) > Edit."
                #endif
            }
        }
    }

    public init() {}

    public var kind: String { "fileprovider" }
    public var isAvailable: Bool { true }

    // MARK: - 与扩展共用的约定

    /// App → 扩展交接 vault 访问权的 XPC 服务名（见 FileProvider/VaultAccessService.swift）。
    public static let vaultAccessServiceName = "app.foldersafe.vault-access.v1"
    /// 扩展回复"vault 读不到"时 reason 的前缀（App 据此给出 vaultLocationNotSupported，而不是笼统的交接失败）。
    static let vaultUnreadableReason = "vault-unreadable"
    /// 扩展自己建的 vault 目录书签（App Group defaults，只有扩展能解析）。
    static func extensionBookmarkKey(_ vaultId: String) -> String { "fp.extensionBookmark.\(vaultId)" }

    /// iPhone 自动上锁：App 在 App Group defaults 里写的"解锁到何时"。过期后扩展删钥匙、拒绝访问。
    public static func unlockedUntilKey(_ vaultId: String) -> String { "unlockedUntil.\(vaultId)" }

    /// 扩展的条目对照表（加密，见 ItemIndex）所在目录。域删掉时一起删。
    static func indexDirectory(_ vaultId: String) -> URL? {
        SharedConfig.containerURL?.appendingPathComponent("FileProvider", isDirectory: true).appendingPathComponent(vaultId, isDirectory: true)
    }
    static func indexFile(_ vaultId: String) -> URL? { indexDirectory(vaultId)?.appendingPathComponent("index.bin") }

    /// 解析 VaultRecord 的书签得到 vault 目录（调用方负责 start/stopAccessingSecurityScopedResource）。
    public static func resolveVaultURL(_ record: VaultRecord) -> URL? {
        if let bookmark = record.bookmark {
            var stale = false
            #if os(macOS)
            if let u = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) { return u }
            if let u = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) { return u }
            #else
            if let u = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) { return u }
            #endif
        }
        return record.path.isEmpty ? nil : URL(fileURLWithPath: record.path, isDirectory: true)
    }

    static func domain(for record: VaultRecord) -> NSFileProviderDomain {
        let d = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(record.id), displayName: record.name)
        #if os(macOS)
        d.supportsSyncingTrash = false          // 不提供废纸篓：删除是真删
        #else
        if #available(iOS 18.0, *) { d.supportsSyncingTrash = false }
        #endif
        return d
    }

    static func existingDomain(_ vaultId: String) async -> NSFileProviderDomain? {
        let all = (try? await NSFileProviderManager.domains()) ?? []
        return all.first { $0.identifier.rawValue == vaultId }
    }

    // MARK: - VaultPresenter

    /// 加域（已存在就沿用：上次没删成时里面可能还有没写回的改动），返回域根目录的位置。
    /// iPhone：返回的是系统里的位置（可用 filesAppURL(for:) 换成打开"文件"App 的链接）；拿不到时返回 shareddocuments://。
    public func present(_ record: VaultRecord) async throws -> URL {
        let existing = await Self.existingDomain(record.id)
        if existing == nil, let dir = Self.indexDirectory(record.id) {
            try? FileManager.default.removeItem(at: dir)          // 上次留下的对照表作废
        }
        let domain = existing ?? Self.domain(for: record)
        if existing == nil { try await NSFileProviderManager.add(domain) }
        #if os(macOS)
        // 只在 macOS 看 userEnabled：iOS 27 模拟器实测新域 userEnabled 恒为 false，但域实际正常工作（2026-10-23）
        if let d = await Self.existingDomain(record.id), !d.userEnabled { throw Failure.disabledByUser }
        #endif
        guard let m = NSFileProviderManager(for: domain) else { throw Failure.noUserVisibleURL }
        do {
            try await Self.grantVaultAccess(record, manager: m)
        } catch {
            #if os(macOS)
            // macOS：扩展没有这一步就打不开 vault。这次新加的域里什么都没有，撤掉，免得 Finder 侧栏留一个打不开的位置；
            // 原来就在的域不动（里面可能还有上次没写回的改动）。
            if existing == nil {
                _ = try? await NSFileProviderManager.remove(domain, mode: .removeAll)
                Self.removeIndex(record.id)
            }
            throw error
            #else
            NSLog("FolderSafe: vault access hand-off failed (%@); relying on the registered bookmark", String(describing: error))
            #endif
        }
        // 之前因上锁失败的请求重新来过；外部变化重扫一次
        try? await m.signalErrorResolved(NSFileProviderError(.notAuthenticated))
        try? await m.signalEnumerator(for: .workingSet)
        var lastError: Error?
        for _ in 0..<20 {
            do { return try await m.getUserVisibleURL(for: .rootContainer) } catch { lastError = error }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        #if os(macOS)
        throw lastError ?? Failure.noUserVisibleURL
        #else
        return URL(string: "shareddocuments://")!
        #endif
    }

    /// 撤下 vault：先等所有改动写回 vault，再删域（系统副本里的明文一起删除）。
    /// - 非 force：60 秒内写不完 → 抛 .unsyncedChanges，什么都不删。
    /// - force（自动上锁）：最多等 10 秒。写完了就全部删除；没写完时
    ///   macOS 删域但把没写回的文件保留下来（抛 .unsavedChangesPreserved(位置)，此时已上锁）；
    ///   iPhone 系统不支持保留，为了不丢数据不删域，抛 .unsyncedChanges（钥匙删掉后扩展拒绝访问，下次解锁会继续写回）。
    /// 系统没给出域的管理对象时没法确认写完了，按"没写完"处理（不会用 .removeAll 删掉域）。
    public func dismiss(_ record: VaultRecord, force: Bool) async throws {
        guard let domain = await Self.existingDomain(record.id) else {
            Self.removeIndex(record.id)
            return
        }
        let m = NSFileProviderManager(for: domain)
        var synced = false
        if let m, UnlockedKeyStore.get(vaultId: record.id) != nil {
            synced = await Self.withTimeout(seconds: force ? 10 : 60) {
                try await m.waitForChanges(below: .rootContainer)
            }
        }
        if !synced, let m {
            // 钥匙已经没了（或等超时）：试着清掉所有本地副本，成功就说明没有未写回的改动
            synced = await Self.withTimeout(seconds: 10) { try await m.evictItem(identifier: .rootContainer) }
        }
        if !synced && !force { throw Failure.unsyncedChanges }
        #if os(macOS)
        let preserved = try await NSFileProviderManager.remove(domain, mode: synced ? .removeAll : .preserveDirtyUserData)
        Self.removeIndex(record.id)
        if let preserved {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: preserved.path)) ?? []
            if contents.isEmpty { try? FileManager.default.removeItem(at: preserved) }
            else { throw Failure.unsavedChangesPreserved(preserved) }
        }
        #else
        guard synced else { throw Failure.unsyncedChanges }
        _ = try await NSFileProviderManager.remove(domain, mode: .removeAll)
        Self.removeIndex(record.id)
        #endif
    }

    public func busyProcesses(_ record: VaultRecord) -> [String] { [] }

    // MARK: - 域状态 / 系统设置

    public enum DomainState: Equatable {
        case notAdded            // 没有这个域（未解锁或已撤下）
        case enabled             // 正常
        case disabledByUser      // 用户在系统里关掉了（macOS 系统设置的"文件提供程序"开关 / iPhone"文件"App 的位置开关）
    }

    /// 便宜的状态查询，界面可以轮询（例如在提示用户打开开关时每秒查一次，变成 .enabled 后再调 present）。
    public static func domainState(_ vaultId: String) async -> DomainState {
        guard let d = await existingDomain(vaultId) else { return .notAdded }
        #if os(macOS)
        return d.userEnabled ? .enabled : .disabledByUser
        #else
        _ = d
        return .enabled                     // iOS 上 userEnabled 不可靠（见 present）
        #endif
    }

    #if os(macOS)
    /// "系统设置 → 通用 → 登录项与扩展"（文件提供程序的开关在这里）。
    public static let extensionSettingsURL = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!

    /// 打开上面的设置页（只在 App 里调用）。
    @MainActor public static func openExtensionSettings() {
        NSWorkspace.shared.open(extensionSettingsURL)
    }
    #endif

    // MARK: - 其它

    /// 让扩展重扫 vault（例如 App 知道网盘刚同步过）。
    public func refresh(_ record: VaultRecord) async {
        guard let d = await Self.existingDomain(record.id), let m = NSFileProviderManager(for: d) else { return }
        try? await m.signalEnumerator(for: .workingSet)
    }

    /// App 启动时调用：撤下所有没有钥匙（已上锁）或已不在登记表里的 vault 的域（例如上次崩溃 / 断电时还开着）。
    /// 返回没能撤下的 vault ID 和原因。
    @discardableResult
    public static func removeStaleDomains() async -> [String: Error] {
        var failures: [String: Error] = [:]
        let all = (try? await NSFileProviderManager.domains()) ?? []
        for d in all {
            let id = d.identifier.rawValue
            guard UnlockedKeyStore.get(vaultId: id) == nil || VaultRegistry.record(id: id) == nil else { continue }
            let record = VaultRecord(id: id, name: d.displayName, path: "")
            do { try await FileProviderPresenter().dismiss(record, force: true) } catch { failures[id] = error }
        }
        return failures
    }

    /// iPhone：把 present 返回的位置换成能打开"文件"App 对应目录的链接。
    public static func filesAppURL(for url: URL) -> URL? {
        if url.scheme == "shareddocuments" { return url }
        return URL(string: "shareddocuments://" + url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!)
    }

    #if os(macOS)
    /// 错误链里有"扩展没能启动 / 连不上"（NSFileProviderInternalErrorDomain 7、extensionKit、RunningBoard）。
    static func isExtensionLaunchFailure(_ error: Error) -> Bool {
        var e: NSError? = error as NSError
        while let cur = e {
            if cur.domain == "NSFileProviderInternalErrorDomain" && cur.code == 7 { return true }
            if cur.domain == "com.apple.extensionKit.errorDomain" || cur.domain == "RBSServiceErrorDomain" { return true }
            e = cur.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }
    #endif

    /// 把 vault 目录（带访问权的 URL）经 XPC 交给扩展；扩展确认能读到 vault 后存一份自己的书签。扩展刚起来时可能要重试。
    ///
    /// URL 过 XPC 时只有发送方**在沙盒里**、URL 带着沙盒扩展（来自安全作用域书签 / 打开面板）才会把访问权一起带过去：
    /// - Mac App Store 版、iPhone：App 在沙盒里，靠这一步把访问权交给扩展。
    /// - macOS 直装版：App 不在沙盒里，URL 不带访问权（2026-10-23 实测：扩展 deny file-read-data）；
    ///   扩展靠自己的沙盒例外（家目录、/Volumes，见 Config/FileProvider-mac-Direct.entitlements）直接打开，
    ///   这一步只用来确认扩展确实读得到。读不到 → vaultLocationNotSupported。
    static func grantVaultAccess(_ record: VaultRecord, manager m: NSFileProviderManager) async throws {
        guard let url = resolveVaultURL(record) else { throw Failure.vaultNotAccessible("no location for the vault") }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var last = "no reply"
        var unreadable = false
        var launchFailed = false
        for attempt in 0..<10 where !unreadable {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 500_000_000) }
            launchFailed = false
            do {
                let service: NSFileProviderService? = try await withCheckedThrowingContinuation { c in
                    m.getService(named: NSFileProviderServiceName(vaultAccessServiceName), for: .rootContainer) { s, e in
                        if let e { c.resume(throwing: e) } else { c.resume(returning: s) }
                    }
                }
                guard let service else { last = "service not offered"; continue }
                let conn: NSXPCConnection = try await withCheckedThrowingContinuation { c in
                    service.getFileProviderConnection { conn, e in
                        if let conn { c.resume(returning: conn) } else { c.resume(throwing: e ?? Failure.vaultNotAccessible("no connection")) }
                    }
                }
                conn.remoteObjectInterface = NSXPCInterface(with: FolderSafeVaultAccessXPC.self)
                conn.resume()
                defer { conn.invalidate() }
                let once = OnceReply()
                let (ok, why): (Bool, String?) = await withCheckedContinuation { c in
                    once.cont = c
                    let proxy = conn.remoteObjectProxyWithErrorHandler { e in once.finish((false, "\(e)")) } as? FolderSafeVaultAccessXPC
                    guard let proxy else { return once.finish((false, "bad proxy")) }
                    proxy.grantVaultAccess(url, vaultId: record.id) { once.finish(($0, $1)) }
                }
                if ok { return }
                last = why ?? "refused"
                unreadable = last.hasPrefix(vaultUnreadableReason)     // 扩展起来了、连上了，就是读不到：重试没用
            } catch {
                last = "\(error)"
                #if os(macOS)
                launchFailed = isExtensionLaunchFailure(error)
                #endif
            }
        }
        #if os(macOS) && !APPSTORE
        if unreadable { throw Failure.vaultLocationNotSupported(url.path) }
        #endif
        if launchFailed { throw Failure.extensionUnavailable(last) }
        throw Failure.vaultNotAccessible(last)
    }

    private final class OnceReply: @unchecked Sendable {
        let lock = NSLock()
        var cont: CheckedContinuation<(Bool, String?), Never>?
        func finish(_ v: (Bool, String?)) {
            lock.lock(); let c = cont; cont = nil; lock.unlock()
            c?.resume(returning: v)
        }
    }

    static func removeIndex(_ vaultId: String) {
        if let dir = indexDirectory(vaultId) { try? FileManager.default.removeItem(at: dir) }
        SharedConfig.defaults.removeObject(forKey: extensionBookmarkKey(vaultId))
    }

    /// 在限定时间内完成返回 true；出错或超时返回 false（超时后 op 继续在后台跑，结果丢弃）。
    static func withTimeout(seconds: Double, _ op: @escaping @Sendable () async throws -> Void) async -> Bool {
        final class Once: @unchecked Sendable {
            let lock = NSLock()
            var cont: CheckedContinuation<Bool, Never>?
            func finish(_ v: Bool) {
                lock.lock(); let c = cont; cont = nil; lock.unlock()
                c?.resume(returning: v)
            }
        }
        let once = Once()
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            once.cont = c
            Task { once.finish((try? await op()) != nil) }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                once.finish(false)
            }
        }
    }
}

/// App ↔ File Provider 扩展的 XPC 接口：把 vault 目录的访问权交给扩展。
@objc public protocol FolderSafeVaultAccessXPC {
    func grantVaultAccess(_ url: URL, vaultId: String, reply: @escaping (Bool, String?) -> Void)
}
