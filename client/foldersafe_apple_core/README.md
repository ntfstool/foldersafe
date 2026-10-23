# FolderSafeCore（Apple 共用内核）

FolderSafe 开放加密格式 v1（[规范](../../docs/spec/vault-format-v1.md)）的 Swift 参考实现，macOS 和 iOS 客户端共用。
数据层与 Cryptomator 第 8 版（SIV_GCM）逐字节兼容；助记词找回等扩展放在 vault 的 `foldersafe/` 目录。
只依赖 Foundation / CryptoKit / CommonCrypto。挂载成文件夹（FSKit / File Provider）不在这里，在各端 App。

## 目录
```
Sources/FolderSafeCore/Primitives/   AES-SIV（RFC 5297）、scrypt（RFC 7914）、编码、随机源
Sources/FolderSafeCore/Format/       主密钥文件、vault 配置（JWT）、文件内容、文件名/目录、找回短语与扩展
Sources/FolderSafeCore/Vault.swift   上层接口：建库、三种方式解锁、按目录 ID / 路径寻址的读写、属性、目录、符号链接、移动、改密码
Sources/FolderSafeCore/VaultFile.swift   文件句柄：按块随机读写，影子文件 + 原子换上
Sources/FolderSafeCore/TestVectors.swift   公开测试向量的生成与复核
Sources/fsvault/                     命令行（互通测试、生成测试向量用）
```

## 常用命令
```bash
swift test                                        # 全部测试（RFC 向量、格式、随机读写模糊、并发、断电残留，约 1 分钟）
FS_BENCH=1 swift test -c release -Xswiftc -enable-testing --filter testBench   # 1 GiB 读写、1 万文件目录的基准
swift build -c release && .build/release/fsvault vectors --out ../../docs/spec/test-vectors/v1.json   # 重新生成向量
../../interop/run-interop.sh                      # 与 Cryptomator 官方库双向互通测试
```

## 约定
- 公开测试向量 `docs/spec/test-vectors/v1.json` 有单元测试把关：实现改动导致向量变化时测试会失败——先确认是不是破坏了格式兼容，再决定是否重新生成。
- 加密参数字符串（`FolderSafe recovery v1` 等）和 BIP-39 词表永远不能改。
- 测试里用低强度 scrypt（N=1024）省时间；真实默认值 N=32768 有单独测试。

## 给挂载层（FSKit / File Provider）的约定
- `Vault`、`VaultFile` 可以跨线程随便调：内部一把递归锁串行化所有操作（含句柄）；整文件导入 / 写入的加密、整读的解密在锁外。
- 稳定标识：目录用目录 ID（`Entry.directoryId`，改名移动不变，根目录是 `Vault.rootDirectoryId` = ""）；
  文件格式里没有稳定 ID，用 `(parentId, name)` 定位，上层自己维护映射，经本接口移动后更新。
- 句柄写入在影子文件上，`synchronize()` / `close()` 时才原子换上原文件；不调用就等于没写（断电也只丢这部分）。
  同一进程内其他读取（`readFile`、`attributes`、列目录的大小）会看到未同步的内容；别的进程 / 另一个 `Vault` 实例看不到。
- 大文件用 `importFile` / `exportFile`（流式，1 MiB 一段），不要整个读进内存。
- 错误转 POSIX：`VaultError.posixCode`。
