import Foundation
#if os(macOS)
import CoreServices
#endif

/// 盯着 vault 目录（密文）有没有被别处改（网盘同步、别的客户端），有就回调（去抖 1 秒）。
/// macOS 用 FSEvents（任何写入都能看到）；iPhone 用 NSFilePresenter（"文件"App / iCloud 云盘等协调写入能看到）。
/// 只在扩展进程活着时有效；进程被系统回收后，下次枚举 / 工作集查询时会重扫补上。
final class VaultWatcher: NSObject {
    private let root: URL
    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "app.foldersafe.fileprovider.watcher", qos: .utility)
    private var pending = false
    private var stopped = false
    #if os(macOS)
    private var stream: FSEventStreamRef?
    #else
    private let operationQueue = OperationQueue()
    #endif

    init(root: URL, onChange: @escaping () -> Void) {
        self.root = root
        self.onChange = onChange
        super.init()
        start()
    }

    private func fire() {
        queue.async { [self] in
            guard !pending, !stopped else { return }
            pending = true
            queue.asyncAfter(deadline: .now() + 1) { [self] in
                pending = false
                guard !stopped else { return }
                DispatchQueue.global(qos: .utility).async(execute: onChange)   // 不在 queue 上回调：回调里可能 stop()
            }
        }
    }

    #if os(macOS)
    private func start() {
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<VaultWatcher>.fromOpaque(info).takeUnretainedValue().fire()
        }
        guard let s = FSEventStreamCreate(nil, cb, &ctx, [root.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
                                          FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    func stop() {
        queue.sync {
            stopped = true
            if let s = stream {
                FSEventStreamStop(s)
                FSEventStreamInvalidate(s)
                FSEventStreamRelease(s)
                stream = nil
            }
        }
    }
    #else
    private func start() {
        operationQueue.maxConcurrentOperationCount = 1
        NSFileCoordinator.addFilePresenter(self)
    }

    func stop() {
        NSFileCoordinator.removeFilePresenter(self)
        queue.sync { stopped = true }
    }
    #endif
}

#if !os(macOS)
extension VaultWatcher: NSFilePresenter {
    var presentedItemURL: URL? { root }
    var presentedItemOperationQueue: OperationQueue { operationQueue }
    func presentedSubitemDidChange(at url: URL) { fire() }
    func presentedItemDidChange() { fire() }
    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) { fire() }
}
#endif
