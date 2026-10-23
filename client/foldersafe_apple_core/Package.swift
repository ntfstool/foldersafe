// swift-tools-version:5.9
// FolderSafeCore：FolderSafe 开放加密格式 v1（docs/spec/vault-format-v1.md）的 Swift 参考实现，macOS / iOS 共用。
// 数据层与 Cryptomator 第 8 版（SIV_GCM）逐字节兼容；扩展（助记词找回）放在 vault 的 foldersafe/ 目录。
// 只依赖 Foundation / CryptoKit / CommonCrypto。挂载（FSKit / File Provider）不在这里，在各端 App。
import PackageDescription

let package = Package(
    name: "FolderSafeCore",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "FolderSafeCore", targets: ["FolderSafeCore"]),
        .executable(name: "fsvault", targets: ["fsvault"]),
    ],
    targets: [
        .target(name: "FolderSafeCore"),
        .executableTarget(name: "fsvault", dependencies: ["FolderSafeCore"]),
        .testTarget(name: "FolderSafeCoreTests", dependencies: ["FolderSafeCore"]),
    ]
)
