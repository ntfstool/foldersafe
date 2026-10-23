import Foundation

/// App 与各扩展共用的标识。改了会让已登记的库和钥匙找不到，发布后不要动。
/// 值来自 Info.plist 的 FSBundlePrefix / FSAppGroup / FSKeychainGroup，由 Config/Signing.xcconfig 填入
/// （macOS App Group = <Team ID>.<前缀>，iOS = group.<前缀>；钥匙串共享组 = <Team ID>.<前缀>.shared，
/// entitlements 里写的是 $(AppIdentifierPrefix)$(FS_BUNDLE_PREFIX).shared）。
public enum SharedConfig {
    public static let bundlePrefix = value("FSBundlePrefix", fallback: "foldersafe.local")
    public static let appGroup = value("FSAppGroup", fallback: "foldersafe.local")
    public static let keychainGroup = value("FSKeychainGroup", fallback: "foldersafe.local.shared")
    public static let keychainService = "app.foldersafe.vault-key"

    public static var defaults: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }

    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    public static let supportEmail = "support@foldersafe.app"
    public static let website = URL(string: "https://foldersafe.app")!

    /// App / 扩展里一定有这些键；只有不带 Info.plist 的命令行测试（FileProviderTests）才会用到 fallback。
    private static func value(_ key: String, fallback: String) -> String {
        if let v = Bundle.main.object(forInfoDictionaryKey: key) as? String, !v.isEmpty, !v.contains("$(") { return v }
        let ext = Bundle.main.bundleURL.pathExtension
        assert(ext != "app" && ext != "appex", "Info.plist key \(key) is missing: check Config/Signing.xcconfig and the target's Info.plist")
        return fallback
    }
}
