import Foundation

/// iPhone 上的呈现层：每个已解锁的 vault 一个 File Provider 域，出现在"文件"App 的"位置"里。
enum PresenterFactory {
    static func make() -> VaultPresenter {
        return FileProviderPresenter()
    }
}

