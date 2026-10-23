import Foundation
@_weakLinked import FSKit          // App 最低 macOS 13：FSKit 弱链接，用前先判断系统版本

/// macOS 26+ 直装版：用 FSKit 扩展（<前缀>.mac.fskit，文件系统类型 `foldersafe`）把已解锁的 vault
/// 挂成一个普通文件夹（默认 ~/FolderSafe/<名字>）。明文只在内存里，不落盘。
///
/// 前提（App 负责）：调用 present 之前已把 rawKey 放进 UnlockedKeyStore；dismiss 成功之后再删钥匙。
/// 首次使用需要用户在"系统设置 → 通用 → 登录项与扩展 → 文件系统扩展"里打开 FolderSafe
/// （系统不允许程序代开：`isModuleEnabled` 为 false 时调用 `openExtensionSettings()` 带用户过去）。
public final class FSKitPresenter: VaultPresenter {
    public static let moduleBundleID = SharedConfig.bundlePrefix + ".mac.fskit"
    public static let fileSystemType = "foldersafe"

    public enum Failure: LocalizedError, Equatable {
        case unsupportedSystem                 // macOS 26 以前
        case moduleDisabled                    // 系统设置里没打开扩展
        case vaultNotFound(String)
        case mountPointNotEmpty(String)
        case mountPointInUse(String)           // 那里已经挂着别的东西
        case mountFailed(String)
        case busy([String])                    // 有程序占用，不强制就不卸载
        case unmountFailed(String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedSystem: return "FSKit requires macOS 26 or later."
            case .moduleDisabled: return "Turn on FolderSafe in System Settings › General › Login Items & Extensions › File System Extensions."
            case .vaultNotFound(let p): return "Vault folder not found: \(p)"
            case .mountPointNotEmpty(let p): return "The folder \(p) is not empty."
            case .mountPointInUse(let p): return "Something else is already mounted at \(p)."
            case .mountFailed(let m): return "Could not open the vault as a folder: \(m)"
            case .busy(let apps): return "The vault is in use by: \(apps.joined(separator: ", "))"
            case .unmountFailed(let m): return "Could not close the vault folder: \(m)"
            }
        }
    }

    public init() {}

    public var kind: String { "fskit" }
    public var isAvailable: Bool { Self.isSupported }

    // MARK: - 能力检测 / 扩展开关

    /// 系统版本够（macOS 26+）且扩展已在系统设置里打开。
    public static var isSupported: Bool { isSystemSupported && isModuleEnabled }

    public static var isSystemSupported: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    /// 扩展在"系统设置 → 文件系统扩展"里是否已打开（以 fskitd 的状态为准；pluginkit 的 "+" 不算数）。
    public static var isModuleEnabled: Bool { moduleState() == .enabled }

    /// 扩展是否已被系统登记（App 第一次启动后由系统自动登记）。
    public static var isModuleInstalled: Bool { moduleState() != .notInstalled }

    public enum ModuleState { case enabled, disabled, notInstalled, unknown }

    /// 向 FSKit 查询本扩展的状态（最多等 5 秒）。
    public static func moduleState() -> ModuleState {
        guard #available(macOS 15.4, *) else { return .notInstalled }
        let done = DispatchSemaphore(value: 0)
        var state = ModuleState.unknown
        FSClient.shared.fetchInstalledExtensions { list, _ in
            if let list {
                if let m = list.first(where: { $0.bundleIdentifier == moduleBundleID }) {
                    state = m.isEnabled ? .enabled : .disabled
                } else {
                    state = .notInstalled
                }
            }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 5)
        return state
    }

    /// 试着启用扩展。macOS 26/27 上只有用户在系统设置里打开开关才算数（pluginkit -e use 不被 fskitd 认可），
    /// 所以这里只做无害的 pluginkit 登记，返回之后是否已启用；没启用就调用 openExtensionSettings() 引导用户。
    @discardableResult
    public static func enableModule() -> Bool {
        if isModuleEnabled { return true }
        _ = try? run("/usr/bin/pluginkit", ["-e", "use", "-i", moduleBundleID], timeout: 5)
        return isModuleEnabled
    }

    /// 打开"系统设置 → 通用 → 登录项与扩展"（文件系统扩展在这一页里）。
    public static func openExtensionSettings() {
        if #available(macOS 27.0, *), FSClient.shared.openFileSystemExtensionsSettings() { return }
        _ = try? run("/usr/bin/open", ["x-apple.systempreferences:com.apple.LoginItems-Settings.extension"], timeout: 5)
    }

    /// 默认挂载点：~/FolderSafe/<名字>。
    public static func defaultMountPoint(for record: VaultRecord) -> String {
        let safe = record.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("FolderSafe").appendingPathComponent(safe.isEmpty ? record.id : safe).path
    }

    public static func mountPoint(for record: VaultRecord) -> String {
        (record.mountPoint?.isEmpty == false ? record.mountPoint! : defaultMountPoint(for: record))
    }

    /// 某个 vault 现在是否挂着（挂载点上是 foldersafe 文件系统）。
    public static func isMounted(_ record: VaultRecord) -> Bool {
        mountedFileSystemType(at: mountPoint(for: record)) == fileSystemType
    }

    // MARK: - VaultPresenter

    public func present(_ record: VaultRecord) async throws -> URL {
        try await Task.detached(priority: .userInitiated) { try Self.mount(record) }.value
    }

    public func dismiss(_ record: VaultRecord, force: Bool) async throws {
        try await Task.detached(priority: .userInitiated) { try Self.unmount(record, force: force) }.value
    }

    public func busyProcesses(_ record: VaultRecord) -> [String] {
        Self.processes(using: Self.mountPoint(for: record))
    }

    // MARK: - 挂载 / 卸载（同步版本，供上面和命令行测试用）

    public static func mount(_ record: VaultRecord) throws -> URL {
        guard isSystemSupported else { throw Failure.unsupportedSystem }
        let mp = (mountPoint(for: record) as NSString).standardizingPath
        let mpURL = URL(fileURLWithPath: mp, isDirectory: true)
        // 已经挂着（重复调用）：直接返回
        if mountedFileSystemType(at: mp) == fileSystemType { return mpURL }
        guard isModuleEnabled || enableModule() else { throw Failure.moduleDisabled }

        guard let vaultURL = record.resolveURL() else { throw Failure.vaultNotFound(record.path) }
        let scoped = vaultURL.startAccessingSecurityScopedResource()
        defer { if scoped { vaultURL.stopAccessingSecurityScopedResource() } }
        let vaultPath = (vaultURL.path as NSString).standardizingPath
        guard FileManager.default.fileExists(atPath: (vaultPath as NSString).appendingPathComponent("vault.cryptomator")) else {
            throw Failure.vaultNotFound(vaultPath)
        }

        try prepareMountPoint(mp)
        let started = Date()
        let name = record.name.replacingOccurrences(of: ",", with: " ")
        let r: (status: Int32, out: String, err: String)
        do {
            r = try run("/sbin/mount", ["-F", "-t", fileSystemType, "-o", "nobrowse,volname=\(name)", vaultPath, mp], timeout: 60)
        } catch {
            forceUnmount(mp)
            throw Failure.mountFailed(error.localizedDescription)
        }
        guard r.status == 0, mountedFileSystemType(at: mp) == fileSystemType else {
            forceUnmount(mp)
            let msg = (r.err + r.out).trimmingCharacters(in: .whitespacesAndNewlines)
            if !isModuleEnabled { throw Failure.moduleDisabled }
            throw Failure.mountFailed(msg.isEmpty ? "mount exited with \(r.status)" : msg)
        }
        // 验证：能列出根目录
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: mp)
        } catch {
            forceUnmount(mp)
            throw Failure.mountFailed("mounted but not readable: \(error.localizedDescription)")
        }
        NSLog("FolderSafe: mounted %@ at %@ in %.2fs", vaultPath, mp, Date().timeIntervalSince(started))
        return mpURL
    }

    public static func unmount(_ record: VaultRecord, force: Bool) throws {
        try unmount(atPath: (mountPoint(for: record) as NSString).standardizingPath, force: force)
    }

    /// App 启动时调用：卸载所有还挂着的 foldersafe 卷（上次 App 崩溃 / 退出超时留下的；FSKit 扩展里钥匙还在内存，
    /// 不卸载的话界面显示上锁、文件却照样能读）。卸载时扩展会把打开着的文件全部落盘。
    /// except：这次启动后已经解锁的 vault 的挂载点（不动）。
    public static func unmountStale(except active: Set<String> = []) {
        for mp in mountedVaults() where !active.contains(mp) {
            do { try unmount(atPath: mp, force: true) } catch {
                NSLog("FolderSafe: cannot unmount stale vault at %@: %@", mp, String(describing: error))
            }
        }
    }

    /// 当前所有 foldersafe 文件系统的挂载点。
    static func mountedVaults() -> [String] {
        var list: UnsafeMutablePointer<statfs>?
        let n = getmntinfo(&list, MNT_NOWAIT)
        guard n > 0, let list else { return [] }
        return (0..<Int(n)).compactMap { i in
            var s = list[i]
            let type = withUnsafePointer(to: &s.f_fstypename) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) } }
            guard type == fileSystemType else { return nil }
            return withUnsafePointer(to: &s.f_mntonname) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
        }
    }

    static func unmount(atPath mp: String, force: Bool) throws {
        guard mountedFileSystemType(at: mp) == fileSystemType else { return }    // 没挂着
        var r = try run("/sbin/umount", [mp], timeout: 30)
        if r.status != 0 {
            guard force else {
                let busy = processes(using: mp)
                if !busy.isEmpty { throw Failure.busy(busy) }
                throw Failure.unmountFailed(r.err.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            r = try run("/sbin/umount", ["-f", mp], timeout: 30)
            if r.status != 0 {
                _ = try? run("/usr/sbin/diskutil", ["unmount", "force", mp], timeout: 30)
            }
        }
        // 等它真正消失
        let deadline = Date().addingTimeInterval(15)
        while mountedFileSystemType(at: mp) == fileSystemType {
            guard Date() < deadline else {
                throw Failure.unmountFailed(r.err.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            usleep(100_000)
        }
        // 挂载点是我们建的空文件夹：留着（下次还用），不删用户的东西
    }

    /// 正在使用挂载点上文件的进程（"名字 (pid)"），最多等 3 秒。
    public static func processes(using mountPoint: String) -> [String] {
        let mp = (mountPoint as NSString).standardizingPath
        guard mountedFileSystemType(at: mp) == fileSystemType else { return [] }
        // 参数是挂载点时 lsof 列出整个文件系统上打开的文件，不用遍历目录树
        guard let r = try? run("/usr/sbin/lsof", ["-w", "-n", "-P", "-F", "pc", "--", mp], timeout: 3) else { return [] }
        var out: [String] = []
        var pid = ""
        let me = String(getpid())
        for line in r.out.split(separator: "\n") {
            if line.hasPrefix("p") { pid = String(line.dropFirst()) }
            else if line.hasPrefix("c"), pid != me {
                let s = "\(line.dropFirst()) (\(pid))"
                if !out.contains(s) { out.append(s) }
            }
        }
        return out
    }

    // MARK: - 工具

    /// 挂载点：不存在就建；存在必须是空文件夹（只有 .DS_Store 也算空）。
    static func prepareMountPoint(_ mp: String) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: mp, isDirectory: &isDir) {
            guard isDir.boolValue else { throw Failure.mountPointNotEmpty(mp) }
            if let t = mountedFileSystemType(at: mp) { throw Failure.mountPointInUse("\(mp) (\(t))") }
            let items = (try? fm.contentsOfDirectory(atPath: mp)) ?? []
            guard items.allSatisfy({ $0 == ".DS_Store" }) else { throw Failure.mountPointNotEmpty(mp) }
        } else {
            do { try fm.createDirectory(atPath: mp, withIntermediateDirectories: true) } catch {
                throw Failure.mountFailed("cannot create \(mp): \(error.localizedDescription)")
            }
        }
    }

    /// 如果 path 本身是一个挂载点，返回它的文件系统类型；否则 nil。
    static func mountedFileSystemType(at path: String) -> String? {
        var s = statfs()
        guard statfs(path, &s) == 0 else { return nil }
        let on = withUnsafePointer(to: &s.f_mntonname) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
        let resolved = (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? path
        let real = URL(fileURLWithPath: resolved).resolvingSymlinksInPath().path
        guard on == path || on == real else { return nil }
        return withUnsafePointer(to: &s.f_fstypename) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) } }
    }

    static func forceUnmount(_ mp: String) {
        guard mountedFileSystemType(at: mp) != nil, mountedFileSystemType(at: mp) != "apfs" else { return }
        _ = try? run("/sbin/umount", ["-f", mp], timeout: 15)
    }

    struct Timeout: LocalizedError {
        let command: String
        var errorDescription: String? { "\(command) timed out" }
    }

    /// 跑一个命令，收集输出；超时就杀掉并抛错。
    @discardableResult
    static func run(_ tool: String, _ args: [String], timeout: TimeInterval) throws -> (status: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        try p.run()
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            _ = done.wait(timeout: .now() + 2)
            throw Timeout(command: ([tool] + args).joined(separator: " "))
        }
        group.wait()
        return (p.terminationStatus, String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self))
    }
}
