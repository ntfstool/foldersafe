import Foundation

/// 呈现方式：默认 File Provider（所有 macOS 版本、App Store 版）；
/// 直装版在 macOS 26+ 可以在设置里选"挂成真正的文件夹（FSKit，测试版）"，扩展在系统设置里打开后才真正使用。
enum PresenterChoice: Equatable {
    case fskit
    case fileProvider

    @MainActor
    static func presenter(for c: PresenterChoice) -> VaultPresenter {
        #if !APPSTORE
        if c == .fskit { return FSKitPresenter() }
        #endif
        return FileProviderPresenter()
    }
}

enum FSKitStatus: Equatable { case unknown, checking, enabled, disabled, notInstalled }
