# FolderSafe

FolderSafe is an encrypted folder for macOS and iPhone. While a vault is locked, its files are only ciphertext on disk:
other users, administrators (including root / sudo), backup hosts, cloud sync services and AI tools that read your disk
see encrypted blobs, not your file names or contents. Unlock it with your password, a 12-word recovery phrase, or
Touch ID / Face ID, and it shows up as a normal location in Finder or the Files app.

This repository contains the source code of the FolderSafe apps, the vault-format reference implementation, the open
format specification and the interoperability tests. Official signed builds are available at
[foldersafe.app](https://foldersafe.app) and on the App Store.

## Honest limitations

- **While a vault is unlocked, every program running as you can read it.** That is how a usable folder works.
  Lock vaults when you are not using them (FolderSafe can lock automatically on sleep, screen lock, idle and quit).
- **Encryption is not a backup.** If the vault folder is deleted or damaged, FolderSafe cannot bring it back. Keep backups.
- **If you lose both your password and your recovery phrase, your files are gone.** There is no server and no reset.
- **Some metadata is visible** to anyone holding the ciphertext: number of files and folders, approximate file sizes,
  modification times (see [spec §9](docs/spec/vault-format-v1.md#9-security-considerations)).
- **Opened files are cached in plaintext while unlocked.** Finder / the Files app (File Provider) keep copies of files you
  open; they are deleted when the vault is locked. Details in the [threat model](docs/THREAT_MODEL.md).
- No independent security audit yet. Reports are welcome — see [SECURITY.md](SECURITY.md).

## Vault format

Vaults use an open, documented format: [docs/spec/vault-format-v1.md](docs/spec/vault-format-v1.md)
(CC BY 4.0, with public test vectors in `docs/spec/test-vectors/`). The data layer is compatible with
Cryptomator vault format 8 (`SIV_GCM`), so existing Cryptomator clients can open FolderSafe vaults with the password.
FolderSafe-specific additions (recovery phrase, extension declarations) live in a separate `foldersafe/` directory inside
the vault. FolderSafe is an independent implementation written from the public documentation; it is not affiliated with
Cryptomator.

## Repository layout

```
client/foldersafe_apple_core/   FolderSafeCore: Swift reference implementation of the format (macOS + iOS) and the
                                `fsvault` command-line tool. Depends only on Foundation / CryptoKit / CommonCrypto.
client/foldersafe_apple/        Apple apps (XcodeGen project): macOS app, Mac App Store variant, File Provider extension
                                (shared by macOS and iOS), FSKit extension (macOS 26+, hidden in 1.0), iPhone app, Shared/.
  FileProviderTests/            Offline tests of the File Provider extension against real vaults (SwiftPM, no signing).
client/foldersafe_windows/      Windows client (planned).
docs/spec/                      Format specification and test vectors.
docs/THREAT_MODEL.md            What is and isn't protected.
interop/                        Interop tests against Cryptomator's own libraries (test-only, see below).
```

## Building

Requirements: macOS with Xcode 26 or later. The apps run on macOS 13+ and iOS 17+.

**Core library and tests**

```sh
cd client/foldersafe_apple_core
swift test                      # RFC vectors, format tests, random read/write fuzzing, crash leftovers (~1 min)
swift build -c release --product fsvault
.build/release/fsvault create --vault /tmp/demo-vault --password 'correct horse battery' --source ~/some/folder
```

**Interop tests** (JDK 22+ and Maven): builds `fsvault` and a small harness around Cryptomator's `cryptofs`, then checks
both directions (create / read / write) and the test vectors.

```sh
interop/run-interop.sh
```

**File Provider extension tests** (no signing needed):

```sh
cd client/foldersafe_apple/FileProviderTests
swift run -c debug fp-store-tests && swift run -c debug fp-extension-tests
```

**Apps**

1. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`.
2. Edit **one file**, `client/foldersafe_apple/Config/Signing.xcconfig`: set `DEVELOPMENT_TEAM` to your Apple Developer
   Team ID and `FS_BUNDLE_PREFIX` to a bundle-ID prefix you own. Bundle IDs, App Groups and the shared keychain group are
   derived from these two values; signing is automatic.
3. Generate and open the project:

   ```sh
   cd client/foldersafe_apple
   xcodegen generate
   open FolderSafe.xcodeproj      # schemes: FolderSafeMac, FolderSafeMacAppStore, FolderSafeiOS
   ```

To check that everything compiles without any signing setup:

```sh
xcodebuild -project FolderSafe.xcodeproj -scheme FolderSafeMac -configuration Release \
  -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project FolderSafe.xcodeproj -scheme FolderSafeiOS -configuration Release \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Unsigned builds compile, but App Groups, the shared keychain and the File Provider extension only work in builds signed
with your own team. On macOS, turn the extension on in System Settings › General › Login Items & Extensions › File Providers.
See [client/foldersafe_apple/README.md](client/foldersafe_apple/README.md) for details.

This edition contains no network code: no update check, no usage statistics, no feedback upload. The apps only open
links to the website and `mailto:` addresses.

## AI-assisted development

FolderSafe is written with substantial help from AI coding tools, under the maintainer's direction and review.
We don't ask you to take the code on trust. Correctness is backed by checks anyone can re-run: the RFC test vectors for
the primitives (AES-SIV, scrypt), the public format test vectors in `docs/spec/test-vectors/`, cross-client interop tests
against Cryptomator's official libraries (`interop/run-interop.sh`), and a written [threat model](docs/THREAT_MODEL.md).
The code has not had an independent security audit yet.

## Contributing

Issues and pull requests are welcome. This repository is a periodic export of the maintainers' development tree, so
pull requests are not merged here directly: maintainers port accepted changes, which then appear in the next export
(with credit to the author). Changes to the core library must keep `swift test` and `interop/run-interop.sh` passing;
the vault format is frozen and evolves only through the extension mechanism in spec §7.

Security issues: please do not open a public issue — see [SECURITY.md](SECURITY.md).

## License

- Code: [Apache License 2.0](LICENSE).
- Format specification and test vectors (`docs/spec/`): [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) —
  anyone may implement the format.
- `interop/cryptomator/` depends on Cryptomator's libraries, which are licensed under the AGPL-3.0. That harness is a
  test tool only; it is never shipped with or linked into any FolderSafe client.
- The FolderSafe name and app icon are not licensed for use in redistributed builds; please use your own name and icon.

## 中文简介

FolderSafe（安全文件夹）是 macOS 和 iPhone 上的加密文件夹：上锁时磁盘上只有密文，其他用户、管理员（包括 sudo/root）、
网盘和读取磁盘的 AI 工具都看不到文件名和内容；用密码、12 个助记词或 Touch ID / Face ID 解锁后，像普通文件夹一样在
访达或"文件"App 里使用。

- 限制：解锁期间本机程序都能读；加密不等于备份；密码和助记词都丢了就找不回；文件数量、大致大小和修改时间对持有密文的人可见。
- 数据格式公开（[规范](docs/spec/vault-format-v1.md)，CC BY 4.0），兼容 Cryptomator 第 8 版格式；与 Cryptomator 无关联。
- 编译：内核 `swift test`；App 只需改 `client/foldersafe_apple/Config/Signing.xcconfig` 里的 Team ID 和 Bundle ID 前缀，
  再 `xcodegen generate`。
- 代码在维护者主导和审阅下大量借助 AI 编程工具完成；正确性靠 RFC 向量、公开测试向量、与 Cryptomator 官方库的双向互通测试和威胁模型把关，尚未经过独立安全审计。
- 正式签名版本请从 [foldersafe.app](https://foldersafe.app) 和 App Store 下载。代码 Apache-2.0；欢迎提 Issue / PR（由维护者移植进下一次导出）。
- 安全问题请发邮件到 security@foldersafe.app。
