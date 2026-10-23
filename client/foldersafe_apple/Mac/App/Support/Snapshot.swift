import SwiftUI
import AppKit

/// 截图钩子（App Store / 官网用）：
///   FS_SNAPSHOT=<png 路径>  FS_SNAPSHOT_VIEW=list|empty|wizard-phrase|unlock|settings|about
///   FS_SNAPSHOT_LANG=en|zh-Hans  FS_SNAPSHOT_APPEARANCE=dark
/// 用演示数据把界面画成 2880×1800 的 PNG（1440×900 的 Retina）后退出。不读写任何真实 vault、清单或钥匙串。
enum Snapshot {
    struct Request {
        let path: String
        let view: String
        let lang: String?
        let dark: Bool
    }

    static let request: Request? = {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["FS_SNAPSHOT"], !path.isEmpty else { return nil }
        return Request(path: path,
                       view: env["FS_SNAPSHOT_VIEW"] ?? "list",
                       lang: env["FS_SNAPSHOT_LANG"],
                       dark: env["FS_SNAPSHOT_APPEARANCE"]?.lowercased() == "dark")
    }()

    static let canvas = CGSize(width: 1440, height: 900)

    /// 在任何本地化字符串被读取之前调用。
    static func prepare() {
        guard let r = request else { return }
        // 截图统一用蓝色强调色（不受本机系统强调色影响）
        var domain: [String: Any] = ["AppleAccentColor": 4, "AppleHighlightColor": "0.698039 0.843137 1.000000 Blue"]
        if let lang = r.lang {
            domain["AppleLanguages"] = [lang]
            domain["AppleLocale"] = lang
        }
        UserDefaults.standard.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
    }

    static var locale: Locale { request?.lang.map(Locale.init(identifier:)) ?? .current }

    static let demoWords = ["orbit", "canvas", "timber", "lunar", "pepper", "shield",
                            "harvest", "violin", "anchor", "meadow", "copper", "gentle"]

    @MainActor
    static func demoModel() -> AppModel {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let icloud = home + "/Library/Mobile Documents/com~apple~CloudDocs/Vaults"
        let zh = request?.lang?.hasPrefix("zh") == true
        let names = zh ? ["2025 报税", "合同", "体检报告", "家庭照片"] : ["Tax 2025", "Contracts", "Health", "Family Photos"]
        var records = [
            VaultRecord(id: "demo-1", name: names[0], path: home + "/Documents/Vaults/" + names[0]),
            VaultRecord(id: "demo-2", name: names[1], path: icloud + "/" + names[1]),
            VaultRecord(id: "demo-3", name: names[2], path: icloud + "/" + names[2]),
            VaultRecord(id: "demo-4", name: names[3], path: "/Volumes/Backup/Vaults/" + names[3]),
        ]
        for i in records.indices { records[i].mountPoint = home + "/FolderSafe/" + records[i].name }
        if request?.view == "empty" { records = [] }
        return AppModel(demoRecords: records, unlocked: [:], touchID: ["demo-1", "demo-2"], choice: .fileProvider)
    }

    @MainActor
    static func run() {
        guard let r = request, let model = AppDelegate.model else { exit(2) }
        if r.dark { NSApp.appearance = NSAppearance(named: .darkAqua) }
        for w in NSApp.windows { w.orderOut(nil) }

        let content = AnyView(composed(r.view, model: model)
            .environmentObject(model)
            .environment(\.locale, locale)
            )

        let window = SnapshotWindow(contentRect: NSRect(origin: .zero, size: canvas),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "FolderSafe"
        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .unified
        let host = NSHostingView(rootView: content)
        if #available(macOS 14.0, *) { host.sceneBridgingOptions = [.toolbars, .title] }
        window.contentView = host
        window.setContentSize(canvas)
        window.appearance = NSApp.appearance
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        // 截图要"前台窗口"的样子（彩色红绿灯、强调色）：短暂激活本 App（窗口在屏幕外，不挡用户）。
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let frameView = window.contentView?.superview ?? host
            frameView.layoutSubtreeIfNeeded()
            frameView.displayIfNeeded()
            // 首选窗口服务器截图（能截到侧栏的玻璃材质）；没有屏幕录制权限时退回 cacheDisplay（侧栏可能是空的）。
            let rep = windowServerCapture(window) ?? cacheCapture(frameView)
            guard let rep else { exit(3) }
            let flat = NSImage(size: canvas)
            flat.lockFocus()
            (r.dark ? NSColor(white: 0.12, alpha: 1) : NSColor.white).setFill()
            NSRect(origin: .zero, size: canvas).fill()
            rep.draw(in: NSRect(origin: .zero, size: canvas))
            flat.unlockFocus()
            guard let cg = flat.cgImage(forProposedRect: nil, context: nil, hints: nil) else { exit(4) }
            let finalRep = resample(NSBitmapImageRep(cgImage: cg), width: Int(canvas.width * 2), height: Int(canvas.height * 2))
            guard let data = finalRep.representation(using: .png, properties: [:]) else { exit(5) }
            do {
                try data.write(to: URL(fileURLWithPath: r.path))
                print("snapshot written: \(r.path) \(finalRep.pixelsWide)x\(finalRep.pixelsHigh)")
                exit(0)
            } catch {
                print("snapshot failed: \(error)")
                exit(6)
            }
        }
    }

    private static func windowServerCapture(_ window: NSWindow) -> NSBitmapImageRep? {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("fs-snapshot-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l\(window.windowNumber)", tmp.path]
        do { try p.run(); p.waitUntilExit() } catch { return nil }
        guard p.terminationStatus == 0, let data = try? Data(contentsOf: tmp),
              let rep = NSBitmapImageRep(data: data), rep.pixelsWide >= Int(canvas.width) else { return nil }
        print("captured via window server: \(rep.pixelsWide)x\(rep.pixelsHigh)")
        return rep
    }

    private static func cacheCapture(_ view: NSView) -> NSBitmapImageRep? {
        let bounds = view.bounds
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        return rep
    }

    private static func resample(_ rep: NSBitmapImageRep, width: Int, height: Int) -> NSBitmapImageRep {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let src = rep.cgImage else { return rep }
        ctx.interpolationQuality = .high
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let img = ctx.makeImage() else { return rep }
        return NSBitmapImageRep(cgImage: img)
    }

    @MainActor @ViewBuilder
    private static func composed(_ view: String, model: AppModel) -> some View {
        let zh = request?.lang?.hasPrefix("zh") == true
        switch view {
        case "unlock":
            SheetOverMain { UnlockSheet(id: "demo-1", demoPassword: "demo-password") }
        case "wizard-phrase":
            SheetOverMain {
                CreateVaultWizard(demoName: zh ? "体检报告" : "Health",
                                  demoParent: FileManager.default.homeDirectoryForCurrentUser
                                    .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Vaults"),
                                  demoWords: demoWords)
            }
        case "settings":
            SheetOverMain(dim: false) { SettingsSnapshotWindow(tab: .autoLock) }
        case "about":
            SheetOverMain(dim: false) { SettingsSnapshotWindow(tab: .about) }
        default:
            MainView()
        }
    }
}

/// 截图：主窗口在后面，弹窗浮在上面（和真实的 sheet 一样的内容）。
private struct SheetOverMain<Sheet: View>: View {
    var dim = true
    @ViewBuilder var sheet: Sheet

    var body: some View {
        ZStack(alignment: .top) {
            MainView()
            if dim { Color.black.opacity(0.12).ignoresSafeArea() }
            sheet
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
                .shadow(color: .black.opacity(0.28), radius: 30, y: 12)
                .padding(.top, dim ? 70 : 110)
        }
    }
}

/// 截图用的"设置窗口"：标签栏 + 对应页面。
private struct SettingsSnapshotWindow: View {
    let tab: SettingsTab

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                item("General", "gearshape", .general)
                item("Auto-Lock", "lock.rotation", .autoLock)
                item("Privacy", "hand.raised", .privacy)
                item("About", "info.circle", .about)
            }
            .padding(.top, 14).padding(.bottom, 8)
            Divider()
            Group {
                switch tab {
                case .general: GeneralSettings()
                case .autoLock: AutoLockSettings()
                case .privacy: PrivacySettings()
                case .about: AboutView()
                }
            }
            .frame(height: 430)
        }
        .frame(width: 560)
    }

    private func item(_ title: LocalizedStringKey, _ icon: String, _ t: SettingsTab) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 18)).frame(height: 22)
            Text(title).font(.caption)
        }
        .foregroundStyle(t == tab ? Color.fsAccent : Color.secondary)
        .frame(width: 78, height: 50)
        .background(RoundedRectangle(cornerRadius: 7).fill(t == tab ? Color.primary.opacity(0.07) : .clear))
    }
}

/// 截图窗口：始终按"前台窗口"的样子绘制（彩色红绿灯、强调色按钮），但不抢焦点。
private final class SnapshotWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override var canBecomeKey: Bool { true }
}
