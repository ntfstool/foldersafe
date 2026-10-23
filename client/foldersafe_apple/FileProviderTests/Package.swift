// swift-tools-version:5.9
// File Provider 扩展的离线测试（不需要系统的 File Provider 运行时、不需要签名）：真实 vault、假域。
//   swift run -c debug fp-store-tests        VaultStore / ItemIndex：ID 映射、改名移动、冲突、外部变化、持久化、1000 文件 / 100 MB
//   swift run -c debug fp-extension-tests    FileProviderExtension 本身：item / 分页枚举 / fetch / create / modify / delete / 变化枚举 / 上锁
// Sources/FPExt 里是指向 ../FileProvider 和 ../Shared 的符号链接（与 App 扩展同一份代码）。
import PackageDescription

let package = Package(
    name: "FileProviderTests",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "FolderSafeCore"),
        .target(name: "FPExt", dependencies: ["FolderSafeCore"], linkerSettings: [.linkedFramework("FileProvider")]),
        .executableTarget(name: "fp-store-tests", dependencies: ["FPExt", "FolderSafeCore"]),
        .executableTarget(name: "fp-extension-tests", dependencies: ["FPExt", "FolderSafeCore"]),
    ]
)
