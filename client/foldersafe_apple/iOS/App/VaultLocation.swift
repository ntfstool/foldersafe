import Foundation
import FolderSafeCore

/// 位置相关的小工具：新 vault 的文件夹名、位置提示、iCloud 文件预取。
enum VaultLocation {
    /// 文件夹名里不能有的字符换掉；空名用 "Vault"。
    static func folderName(for name: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\\0").union(.newlines).union(.controlCharacters)
        var s = name.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        while s.hasPrefix(".") { s.removeFirst() }               // 不要建成隐藏文件夹
        if s.isEmpty { s = "Vault" }
        return String(s.prefix(120))
    }

    /// parent 里还没被占用的 `<name>`、`<name> 2`、`<name> 3`……
    static func uniqueChild(of parent: URL, named name: String) -> URL {
        let base = folderName(for: name)
        let fm = FileManager.default
        var candidate = parent.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: candidate.path) || fm.fileExists(atPath: parent.appendingPathComponent(".\(candidate.lastPathComponent).icloud").path) {
            candidate = parent.appendingPathComponent("\(base) \(n)", isDirectory: true)
            n += 1
        }
        return candidate
    }

    /// 给人看的位置："iCloud Drive › Documents"、"On My iPhone › Vaults"，认不出来就只给上级文件夹名。
    static func hint(forPath path: String, includeLast: Bool = false) -> String {
        var comps = path.split(separator: "/").map(String.init)
        if !includeLast, !comps.isEmpty { comps.removeLast() }
        // iCloud 云盘里的系统文件夹按系统语言显示
        if let i = comps.firstIndex(of: "com~apple~CloudDocs"), i + 1 < comps.count {
            switch comps[i + 1] {
            case "Documents": comps[i + 1] = String(localized: "Documents")
            case "Desktop": comps[i + 1] = String(localized: "Desktop")
            default: break
            }
        }
        if let i = comps.firstIndex(of: "com~apple~CloudDocs") {
            return ([String(localized: "iCloud Drive")] + comps[(i + 1)...]).joined(separator: " › ")
        }
        if let i = comps.firstIndex(of: "Mobile Documents") {
            // 别的 App 的 iCloud 容器：iCloud Drive › <App 文件夹> …
            let rest = comps[(i + 1)...].dropFirst()
            return ([String(localized: "iCloud Drive")] + rest).joined(separator: " › ")
        }
        if let i = comps.firstIndex(of: "File Provider Storage") {
            // "我的 iPhone"和部分第三方存储服务都放在 File Provider Storage 下，分不清就不写服务名
            let rest = Array(comps[(i + 1)...])
            return rest.isEmpty ? String(localized: "Files app location") : rest.joined(separator: " › ")
        }
        if let i = comps.firstIndex(of: "Documents"), comps.contains("Application") || comps.contains("Data") {
            return ([String(localized: "On My iPhone"), "FolderSafe"] + comps[(i + 1)...]).joined(separator: " › ")
        }
        return comps.suffix(2).joined(separator: " › ")
    }

    /// 协调读取几个小文件：iCloud 云盘里没下载的会被系统下载下来。最多等 20 秒，失败不报错（后面真正打开时会报）。
    static func prefetch(_ relativePaths: [String], in dir: URL) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let once = Once()
            DispatchQueue.global(qos: .userInitiated).async {
                let fm = FileManager.default
                for rel in relativePaths {
                    let url = dir.appendingPathComponent(rel)
                    let placeholder = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
                    let hasPlaceholder = fm.fileExists(atPath: placeholder.path)
                    guard fm.fileExists(atPath: url.path) || hasPlaceholder else { continue }
                    if hasPlaceholder { try? fm.startDownloadingUbiquitousItem(at: url) }
                    var err: NSError?
                    NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &err) { u in
                        _ = try? Data(contentsOf: u, options: .mappedIfSafe)
                    }
                }
                once.run { cont.resume() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 20) { once.run { cont.resume() } }
        }
    }
}

/// 只执行一次（超时与完成谁先到算谁）。
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}

extension VaultRecord {
    var locationHint: String { VaultLocation.hint(forPath: path) }
}
