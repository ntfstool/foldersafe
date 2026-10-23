import Foundation
import AppKit
import CoreGraphics

/// 自动上锁：睡眠、锁屏（含切换用户）、闲置 N 分钟。退出时上锁由 AppDelegate 负责（一直开着，不能关）。
@MainActor
final class AutoLockMonitor {
    private weak var model: AppModel?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var timer: Timer?

    init(model: AppModel) { self.model = model }

    func start() {
        let ws = NSWorkspace.shared.notificationCenter
        observe(ws, NSWorkspace.willSleepNotification) { $0.trigger(Pref.lockOnSleep) }
        observe(ws, NSWorkspace.sessionDidResignActiveNotification) { $0.trigger(Pref.lockOnScreenLock) }
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked")) { $0.trigger(Pref.lockOnScreenLock) }
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screensaver.didstart")) { $0.trigger(Pref.lockOnScreenLock) }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIdle() }
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping @MainActor (AutoLockMonitor) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in if let self { action(self) } }
        }
        observers.append((center, token))
    }

    private func trigger(_ pref: String) {
        guard UserDefaults.standard.bool(forKey: pref), let model, model.anyUnlocked else { return }
        Task { await model.autoLockAll() }
    }

    /// 系统级闲置秒数（键盘、鼠标、触控板任意输入）。
    static var idleSeconds: TimeInterval {
        guard let any = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }

    private func checkIdle() {
        guard UserDefaults.standard.bool(forKey: Pref.lockWhenIdle), let model, model.anyUnlocked else { return }
        let minutes = max(1, UserDefaults.standard.integer(forKey: Pref.idleMinutes))
        if Self.idleSeconds >= TimeInterval(minutes * 60) {
            Task { await model.autoLockAll() }
        }
    }
}
