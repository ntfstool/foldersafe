import Foundation

/// 把已解锁的 vault 呈现给系统（文件夹 / "文件"App）。界面只通过这个协议打交道，不关心底层是 FSKit 还是 File Provider。
/// 约定：调用 present 之前，App 已经验证过钥匙并把 rawKey 放进 UnlockedKeyStore；dismiss 之后 App 删除钥匙。
public protocol VaultPresenter {
    /// 呈现方式的名字（日志、设置页用）。
    var kind: String { get }
    /// 当前系统能否用这种方式。
    var isAvailable: Bool { get }
    /// 呈现 vault，返回用户能打开的位置（macOS 挂载点 / File Provider 根目录 URL）。
    func present(_ record: VaultRecord) async throws -> URL
    /// 撤下 vault。force 为 true 时即使有文件被占用也要撤下（自动上锁用）。
    func dismiss(_ record: VaultRecord, force: Bool) async throws
    /// 正在使用该 vault 的进程（上锁前提示用；拿不到返回空）。
    func busyProcesses(_ record: VaultRecord) -> [String]
}
