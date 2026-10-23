import Foundation
import FolderSafeCore

/// App Store 截图用的演示模式：启动参数 `-FS_SNAPSHOT_VIEW list|wizard-location|wizard-phrase|unlock|unlocked|settings`
/// （或同名环境变量）。只显示演示数据，不读写任何真实 vault、不弹 Face ID。
enum Snapshot {
    enum Screen: String {
        case list, wizardLocation = "wizard-location", wizardPhrase = "wizard-phrase", unlock, unlocked, settings, empty
    }

    static let current: Screen? = {
        let raw = UserDefaults.standard.string(forKey: "FS_SNAPSHOT_VIEW")
            ?? ProcessInfo.processInfo.environment["FS_SNAPSHOT_VIEW"]
        return raw.flatMap(Screen.init(rawValue:))
    }()

    /// 演示用的找回短语（固定，截完即弃，不对应任何真实 vault）。
    static let demoWords = ["harbor", "velvet", "orbit", "candle", "meadow", "pilot",
                            "silver", "anchor", "tunnel", "wisdom", "garden", "ripple"]

    static let demoParentHint = String(localized: "iCloud Drive › Documents")
}

struct DemoState {
    var records: [VaultRecord]
    var unlocked: Set<String>
    var biometrics: Set<String>

    static func make(for screen: Snapshot.Screen) -> DemoState {
        let icloud = "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Documents"
        let local = "/private/var/mobile/Containers/Shared/AppGroup/DEMO/File Provider Storage/Private"
        let recs = [
            VaultRecord(id: "demo-tax", name: String(localized: "Tax 2025"), path: "\(icloud)/Tax 2025"),
            VaultRecord(id: "demo-contracts", name: String(localized: "Contracts"), path: "\(icloud)/Contracts"),
            VaultRecord(id: "demo-health", name: String(localized: "Health Records"), path: "\(local)/Health Records"),
            VaultRecord(id: "demo-photos", name: String(localized: "Passport Scans"), path: "\(icloud)/Passport Scans"),
        ]
        if screen == .empty { return DemoState(records: [], unlocked: [], biometrics: []) }
        return DemoState(records: recs,
                         unlocked: screen == .unlocked ? ["demo-tax"] : [],
                         biometrics: ["demo-tax", "demo-health"])
    }
}

/// 演示模式的呈现层：什么都不做。
struct DemoPresenter: VaultPresenter {
    var kind: String { "demo" }
    var isAvailable: Bool { true }
    func present(_ record: VaultRecord) async throws -> URL { URL(fileURLWithPath: "/") }
    func dismiss(_ record: VaultRecord, force: Bool) async throws {}
    func busyProcesses(_ record: VaultRecord) -> [String] { [] }
}
