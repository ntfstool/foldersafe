import Foundation
import AppKit
import SwiftUI

/// 版本、渠道、固定链接。App Store 版（APPSTORE 编译条件）不带任何网络代码。
enum AppInfo {
    #if APPSTORE
    static let isAppStore = true
    static let channel = "appstore"
    #else
    static let isAppStore = false
    static let channel = "direct"
    #endif

    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0" }
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1" }
    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    static let website = URL(string: "https://foldersafe.app")!
    static let privacyURL = URL(string: "https://foldersafe.app/privacy")!
    static let termsURL = URL(string: "https://foldersafe.app/terms")!
    static let supportEmail = "support@foldersafe.app"

    static func mailtoURL(subject: String, body: String = "") -> URL {
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = supportEmail
        c.queryItems = [URLQueryItem(name: "subject", value: subject)]
        if !body.isEmpty { c.queryItems?.append(URLQueryItem(name: "body", value: body)) }
        return c.url ?? URL(string: "mailto:\(supportEmail)")!
    }
}

/// 用户偏好（UserDefaults.standard，只属于 App 本身）。
enum Pref {
    static let keepInMenuBar = "keepInMenuBar"
    static let openAfterUnlock = "openAfterUnlock"
    static let lockOnSleep = "autoLock.sleep"
    static let lockOnScreenLock = "autoLock.screenLock"
    static let lockWhenIdle = "autoLock.idle"
    static let idleMinutes = "autoLock.idleMinutes"
    static let useFSKit = "mount.fskit"          // 直装版 macOS 26+：挂成真正的文件夹（测试版）

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            keepInMenuBar: true,
            openAfterUnlock: true,
            lockOnSleep: true,
            lockOnScreenLock: true,
            lockWhenIdle: true,
            idleMinutes: 30,
            useFSKit: false,
        ])
    }
}

extension Color {
    static let fsAccent = Color("AccentColor")
}

extension String {
    /// 把主目录缩写成 ~，界面显示路径用。
    var abbreviatingHome: String { (self as NSString).abbreviatingWithTildeInPath }
}
