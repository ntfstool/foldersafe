# FolderSafe Vault Format v1 — DRAFT

Status: **draft** — design decisions confirmed 2026-10-22; the L1 layer has been verified byte-for-byte against Cryptomator's
own libraries (cryptofs 2.9.0 / cryptolib 2.2.1, §10) and the former open questions are resolved (§11). The format is frozen once
the remaining app-level tests in §10 pass. License of this document: CC BY 4.0 — anyone may implement it.
Reference implementation: `client/foldersafe_apple_core` (Swift). Test vectors: `docs/spec/test-vectors/v1.json`.

---

## 审阅摘要（中文）

以下设计决定已于 2026-10-22 由用户逐条确认；正文是给第三方开发者的英文规范。规范在 §10 测试通过、§11 待定点解决之前仍是草案。

1. **数据层直接兼容 Cryptomator 第 8 版格式（SIV_GCM）**，逐字节一致。好处：现有的 Cryptomator 客户端（Windows / Linux / 安卓 / iOS）
   第一天就能用密码打开 FolderSafe 的文件夹——"不被我们绑死"不用靠承诺，靠现成的第三方软件证明。我们按公开文档独立实现，不抄它的代码（它是 GPL）。
2. **我们自己加的东西都放在 `foldersafe/` 子目录里**，不改动任何 Cryptomator 文件。Cryptomator 客户端忽略它；我们的客户端多出：
   - 12 个助记词找回（包装的是主密钥本身，所以改密码不用动助记词，比现在的设计更简单）；
   - 扩展声明文件（以后加功能时，老客户端能知道"这个文件夹有我不认识的必需功能，不要写入"）。
   注意：`recovery.json` 随文件夹同步，所以"网盘密文 + 助记词"就能打开——助记词等同第二把主钥匙，要像密码一样保管。
3. **Touch ID / Windows Hello 不进文件夹**：设备钥匙只存在本机，不随云同步，换设备重新开启。
4. **密码推导用 scrypt，参数与 Cryptomator 默认一致（N=32768, r=8）**。曾考虑提高到 N=131072，但只多约 2 位强度，
   每次解锁要 128MB 内存，手机端客户端可能打不开，破坏第 1 条的兼容性；安全主要靠密码强度。不用 Argon2id——那样 Cryptomator 就打不开了。
5. **两种云端用法，格式都公开**：
   - 直接同步：文件夹本身放进任意网盘同步目录，按文件增量（和 Cryptomator 一样）；
   - 版本备份仓库（规划中，格式同样公开，任何人都能写恢复工具）：密文按 4MB 切片、按哈希去重，快照清单用主密钥加密，可按时间点恢复。
     已知不足：小文件很多时对象数量多，可能撞网盘频率限制；以后用"小文件打包"改进，通过清单版本号扩展，不改 L1。
6. **付费功能永远不改数据格式**：免费版、付费版、第三方客户端读写的是同一份数据；备份仓库也附带免费开源的恢复工具。
7. **不做 0.1.x（sparsebundle）迁移**：0.1.x 是测验版，没有真实用户数据，v1 不兼容它。
8. **诚实写明泄漏面**：云端/管理员能看到文件数量、大致大小、修改时间；解锁期间本机程序能读明文。
9. **各平台原生实现**：每个客户端用本平台最合适的语言独立实现本规范（Apple 用 Swift），一致性靠公开测试向量和跨客户端互通测试保证（§10）。

2026-10-22 实测：Swift 参考实现与 Cryptomator 官方库双向互通全部通过（互建、互读、互写、加 `foldersafe/` 不影响 Cryptomator），
64 项测试向量经官方库独立复核。原 §11 的 6 个待定点都已按官方库源码和实测定下（见 §11）。还差用 Cryptomator 桌面 App 和手机 App 实际打开一次（§10 第 1 条）。

---

## 1. Goals and non-goals

Goals
- **No lock-in.** Every byte a FolderSafe client writes is specified here. The core layer is byte-compatible with
  Cryptomator vault format 8 (cipher combo `SIV_GCM`), so independent clients already exist on all major platforms.
- **Zero knowledge.** Storage providers, administrators (including root/sudo on the machine holding the files) and
  the FolderSafe project cannot read file names or contents without the user's password, recovery phrase or a device key.
- **Cloud friendly.** The ciphertext is a tree of ordinary files; changing one cleartext file changes only the
  corresponding ciphertext file(s), so any file-level sync service is naturally incremental.
- **Recoverable.** A 12-word recovery phrase can always restore access, independently of the password.

Non-goals (v1)
- Hiding the number of files, their approximate sizes or modification times (see §9).
- Plausible deniability, hidden volumes.
- Multi-user sharing with per-user keys (possible later, in the style of Cryptomator Hub's `kid` mechanism).
- Post-quantum cryptography.

## 2. Conformance levels

| Level | Name | What a client must support |
|---|---|---|
| L1 | Core | §3–§6: read/write vaults with the password. Any Cryptomator vault-format-8 `SIV_GCM` client is L1. |
| L2 | FolderSafe extensions | §7: `foldersafe/` directory, recovery phrase, extension rules. |
| L3 | Backup repository | §8: versioned, content-addressed backup format. |

Device keys (Touch ID, Windows Hello, …) are implementation-specific and never stored in the vault (§7.4).

Key words MUST, SHOULD, MAY are used as in RFC 2119.

## 3. Primitives and encodings

- `AES-GCM`: AES-256-GCM, 12-byte nonce, 16-byte tag.
- `AES-SIV`: RFC 5297 with AES-256. The 512-bit RFC key is `K1 (CMAC/S2V) || K2 (CTR)` = `macKey || encKey` (§11 item 1).
- `AES-KW`: RFC 3394 AES key wrap with a 256-bit KEK.
- `scrypt`: RFC 7914, parallelization `p = 1`.
- `HKDF`: RFC 5869 with SHA-256.
- `HMAC`: HMAC-SHA-256.
- `base64url`: RFC 4648 §5 **with `=` padding**. Writers MUST pad: Cryptomator silently hides names whose padding is missing.
  (The JWT in §5.1 uses unpadded base64url, as JWS requires.) `base64`: RFC 4648 §4 with padding. `Base32`: RFC 4648 §6, upper case.
- All random values come from the operating system CSPRNG.
- Integers in binary structures are unsigned big-endian.
- File names are converted to Unicode NFC before encryption and compared in NFC.

## 4. Vault layout

```
<vault>/
  vault.cryptomator                      vault configuration (JWT, §5.1)
  masterkey.cryptomator                  password-wrapped masterkey (§5.2)
  masterkey.cryptomator.<hex>.bkup       optional backups of the masterkey file
  d/XX/YYYYYYYYYYYYYYYYYYYYYYYYYYYYYY/   one flat directory per cleartext directory (§6.2)
     <encrypted name>.c9r                files, directories, symlinks (§6.3)
     <shortened name>.c9s/               long names (§6.4)
     dirid.c9r                           backup of this directory's own ID (§6.2)
  foldersafe/                            FolderSafe extensions (L2, §7) — ignored by L1-only clients
```

Clients MUST ignore and preserve files and directories they do not understand, in the vault root and in every `d/` directory.
Known examples: `vault.cryptomator.<X>.bkup` (cryptofs writes one on every open), Cryptomator 2.10+ in-use markers `<name>.c9u`,
and temporary files of other clients. Content directories only contain nodes ending in `.c9r` / `.c9s` plus `dirid.c9r`; anything else is
not a node.

## 5. Keys

A vault has two 256-bit keys generated once at creation and **never changed** for the vault's lifetime:
`encKey` (encryption masterkey) and `macKey` (MAC masterkey). `rawKey = encKey || macKey` (64 bytes).
Changing the password, the recovery phrase or device keys only re-wraps these keys; vault contents are never re-encrypted.

### 5.1 `vault.cryptomator`

A JWS compact serialization signed with HMAC over `rawKey`.

- Header: `{"kid":"masterkeyfile:masterkey.cryptomator","typ":"JWT","alg":"HS256"}`. Readers MUST accept `HS256`, `HS384`, `HS512`; writers SHOULD use `HS256`.
- Payload:
  ```json
  {"format":8,"shorteningThreshold":220,"jti":"<random UUID>","cipherCombo":"SIV_GCM"}
  ```
- `jti` is the **vault ID**. FolderSafe uses it to bind recovery data, device keys and backup repositories to a vault.

To open: decode without verification → resolve `kid` → obtain `rawKey` (§5.2, §7.3 or §7.4) → verify the signature →
require `format == 8` and `cipherCombo == "SIV_GCM"`. FolderSafe writers MUST NOT create `SIV_CTRMAC` vaults; readers MAY support them.

### 5.2 `masterkey.cryptomator` (password)

```json
{
  "version": 999,
  "scryptSalt": "<base64>",
  "scryptCostParam": 32768,
  "scryptBlockSize": 8,
  "primaryMasterKey": "<base64 AES-KW(KEK, encKey)>",
  "hmacMasterKey": "<base64 AES-KW(KEK, macKey)>",
  "versionMac": "<base64 HMAC(macKey, uint32(version))>"
}
```

- `KEK = scrypt(password_utf8_nfc, scryptSalt, N = scryptCostParam, r = scryptBlockSize, p = 1, dkLen = 32)`.
- Readers MUST take N and r from the file. FolderSafe writers use `N = 32768, r = 8` (same as Cryptomator's default), so that
  memory-constrained clients such as mobile file-provider extensions can open the vault.
- `scryptSalt`: FolderSafe writers use 32 random bytes; Cryptomator writes 8. Readers MUST accept any non-empty length.
- `version`: writers use 999. Readers MUST accept any non-zero value and compute `versionMac` over the value found in the file.
  FolderSafe readers verify `versionMac` (Cryptomator does not check it, but always writes it correctly).
- `password_utf8_nfc`: the password MUST be normalised to Unicode NFC before UTF-8 encoding. cryptolib itself does not normalise;
  the Cryptomator apps normalise in their password fields, so a client that skips this cannot open vaults with non-ASCII passwords.
- No pepper: Cryptomator's apps use an empty pepper, so `KEK` uses the salt alone.
- A wrong password is detected by the AES-KW integrity check failing.
- Changing the password rewrites this file only. Writers MUST write to a temporary file and atomically rename it,
  and SHOULD keep the previous file as `masterkey.cryptomator.<X>.bkup`, where `<X>` is the first 4 bytes of the SHA-256 of the old
  file in **upper-case** hex (the same scheme Cryptomator uses), until the new file has been verified by re-reading it.
  Clients MUST NOT create other files named `masterkey.cryptomator*.bkup`: Cryptomator's recovery flow restores the newest such file.
- Passwords MUST be at least 8 characters and MUST NOT contain NUL or line breaks (FolderSafe policy, not an L1 requirement).

## 6. Content

### 6.1 Files

Ciphertext file = `header (68 bytes) || chunk_0 || chunk_1 || …`

Header:
- `headerNonce` (12) `||` AES-GCM(`encKey`, `headerNonce`, payload, no AAD) (40) `||` tag (16)
- payload = `0xFF × 8` (reserved; writers write all ones, readers do not check it) `||` `contentKey` (32 random bytes, new per file)

Chunks:
- Cleartext is split into chunks of 32768 bytes; the last chunk may be shorter. An empty file has no chunks.
- `chunk_i = nonce_i (12) || AES-GCM(contentKey, nonce_i, cleartext_i, aad = uint64(i) || headerNonce) || tag (16)`.
- A full ciphertext chunk is 32796 bytes. Cleartext size = `Σ(len(chunk_i) − 28)`.
- Readers MUST accept a final chunk of exactly 28 bytes (empty cleartext): Cryptomator writes one when it encrypts an empty
  stream through its channel API (e.g. the root directory's `dirid.c9r` is 96 bytes). Writers SHOULD NOT produce it
  (an empty file is the 68-byte header alone).
- When a chunk is rewritten it MUST get a fresh random nonce. Other chunks MAY be left untouched (this keeps cloud uploads small).

### 6.2 Directory IDs and the flat `d/` tree

- The root directory's ID is the empty string. Every other directory gets a random ID, which MUST be a 36-character lower-case
  UUID string (Cryptomator rejects directory IDs longer than 36 bytes).
- Storage path of a directory: `h = Base32(SHA-1(AES-SIV(dirId_utf8, no AD)))` (32 characters);
  path = `d/` + `h[0..2]` + `/` + `h[2..32]`.
- Every directory, **including the root**, contains `dirid.c9r`: the directory's **own** ID (empty for the root) encrypted like a
  regular file (§6.1). It lets a damaged tree be reconstructed. Writers MUST write it; readers MUST NOT require it and MUST NOT
  list it as a node.

### 6.3 Names

- `encName = base64url(AES-SIV(name_utf8_nfc, AD = parentDirId_utf8)) + ".c9r"`.
- A regular file is a file named `encName` (§6.1).
- A directory is a directory named `encName` containing `dir.c9r` = the child directory's ID in plain UTF-8, exactly 36 bytes,
  no line break (not encrypted; it is only meaningful together with the keys).
- A symlink is a directory named `encName` containing `symlink.c9r` = the link target encrypted as a file (§6.1).

### 6.4 Long names

If `encName` (including the `.c9r` suffix) is longer than `shorteningThreshold` characters, the node is stored as a directory
`base64url(SHA-1(encName_utf8)) + ".c9s"` (padded, 28 characters + suffix) containing `name.c9s` (the full `encName` including
`.c9r`, UTF-8, no line break) and one of `contents.c9r` (file), `dir.c9r` (directory) or `symlink.c9r` (symlink).
Readers MUST use the threshold from `vault.cryptomator`, not a hard-coded 220.

### 6.5 Sync conflicts

Sync services create copies such as `<base64> (1).c9r`, `<base64> (conflicted copy 2026-10-22).c9r` or `conflict-<base64>.c9r`.
FolderSafe resolves them like Cryptomator's `C9rConflictResolver`, on disk, when listing a writable vault:

1. Strip `.c9r`. Find the longest run of base64url characters (with up to two `=`) that decrypts as a name in this directory;
   if none does, also try the pieces of each run split at `-` / `_`. If nothing decrypts, leave the entry alone.
2. If the canonical node (`<that run>.c9r`) does not exist, rename the copy to it.
3. If the copy and the canonical node are both directories with identical `dir.c9r`, or both symlinks with the same target,
   delete the copy (two directory nodes sharing one ID are dangerous: deleting one empties the other).
4. Otherwise rename the copy to the encryption of `basename + conflictSuffix + extension`, where `conflictSuffix` is the text
   after the run (e.g. ` (conflicted copy 2026-10-22)`), truncated to half of the cleartext length that still avoids shortening,
   `(threshold − 4) / 4 · 3 − 16` bytes. If the suffix is empty (prefix form) or that name exists, use ` (1)` … ` (9)`.
   If all are taken, leave the copy as it is.

Read-only clients MUST NOT rename and MAY hide unresolved copies. Shortened (`.c9s`) conflicts are not resolved by Cryptomator
either; clients list both entries. Clients MUST NOT delete conflict copies except in case 3.

## 7. FolderSafe extensions (L2)

```
foldersafe/
  extensions.json          which extensions this vault uses
  recovery.json            recovery-phrase-wrapped masterkey (§7.3)
```

### 7.1 `extensions.json`

```json
{"foldersafe": 1, "extensions": {"recovery": 1}, "requires": []}
```
- `extensions`: name → version of each extension present.
- `requires`: extensions a client MUST understand before **writing** to the vault. A client that does not understand
  an entry in `requires` MUST open the vault read-only. (Reading is always allowed: L1 data never depends on extensions.)

### 7.2 Recovery phrase

- 12 English words from the BIP-39 word list = 128 bits of entropy + 4-bit checksum (BIP-39 encoding only; no BIP-39 seed derivation).
- Input is case-insensitive; words are separated by whitespace; a word MAY be given by its first 4 letters (unique in the list).
- The phrase is shown once at creation. It can be regenerated only by a client that holds `rawKey` (vault unlocked).

### 7.3 `recovery.json`

```json
{
  "version": 1,
  "salt": "<base64, 32 random bytes>",
  "nonce": "<base64, 12 bytes>",
  "wrappedKey": "<base64 AES-GCM ciphertext || tag of rawKey (64 bytes)>"
}
```
- `RK = HKDF(ikm = entropy (16 bytes), salt = salt, info = "FolderSafe recovery v1", L = 32)`.
- `wrappedKey = AES-GCM(RK, nonce, rawKey, aad = vaultId_utf8)`.
- No slow KDF is needed: the input has 128 bits of entropy.
- Recovery = decrypt `rawKey` → verify `vault.cryptomator` → let the user set a new password (§5.2).
- Regenerating the phrase replaces this file (temporary file + atomic rename).

### 7.4 Device keys (non-normative)

Touch ID, Windows Hello and similar MUST be stored **outside** the vault (they are bound to one device and must not
be synced). FolderSafe on macOS and iOS stores `rawKey` as a data-protection keychain item (service
`app.foldersafe.device-key`, account = vault ID) whose access control is `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly` +
`biometryCurrentSet`: the item never leaves the device, is not synchronised, and becomes unusable when the enrolled
fingerprints / faces change (the user re-enables it with the password). Reading it requires Touch ID / Face ID.

## 8. Backup repository (L3)

Optional, versioned backups to any object store. The format is open; FolderSafe ships a free open-source restore tool.

### 8.1 Store interface

A repository is a key → blob store with four operations: `put`, `get`, `list(prefix)`, `delete`.
`put` MUST be atomic (a key is either absent or complete). Local folders, WebDAV, S3 and similar all qualify.

### 8.2 Layout

```
<vaultId>/keys/masterkey.cryptomator     copy of §5.2 (needed to restore; already safe to publish)
<vaultId>/keys/recovery.json             copy of §7.3
<vaultId>/keys/vault.cryptomator         copy of §5.1
<vaultId>/objects/<hh>/<sha256>          content-addressed pieces of ciphertext files
<vaultId>/snapshots/<snapshotId>.fsm     encrypted snapshot manifests
```

- Every vault file (everything under `<vault>/`, including `d/`, `masterkey.cryptomator`, `vault.cryptomator` and
  `foldersafe/`) is split into **pieces of 4 MiB (4194304 bytes)** from offset 0; the last piece may be shorter.
  Each piece is stored as-is (it is already ciphertext) under `objects/<first 2 hex>/<SHA-256 hex>`.
  Because chunk rewrites (§6.1) touch at most two pieces, editing part of a large file uploads ≤ 8 MiB.
- `snapshotId` = `yyyyMMdd-HHmmss-SSS` (UTC) + `-` + 6 random lower-case hex characters. Lexical order = time order.

### 8.3 Snapshot manifest (`.fsm`)

File = `"FSM1"` (4 bytes) `||` nonce (12) `||` AES-GCM(`MK`, nonce, gzip(manifest JSON), aad = `"FSM1" || vaultId_utf8`) `||` tag.
`MK = HKDF(ikm = rawKey, salt = empty, info = "FolderSafe backup manifest v1", L = 32)`.

```json
{
  "version": 1,
  "vaultId": "…",
  "snapshotId": "…",
  "createdAt": "2026-10-22T09:30:00Z",
  "client": "FolderSafe/1.0 macOS",
  "pieceSize": 4194304,
  "dirs":  ["d", "d/AB", "…"],
  "files": {"d/AB/CDE…/xyz.c9r": {"size": 123, "mtime": "…", "pieces": ["<sha256>", "…"]}}
}
```

### 8.4 Rules

- **Push:** read each file, recording size and mtime before and after; if they differ, re-read (max 3 times) or abort.
  Hash each piece from the bytes actually read. Upload missing objects first; write the manifest **last**.
  Snapshots SHOULD be taken while the vault is locked; otherwise each file is individually consistent but the
  snapshot as a whole is not guaranteed to be.
- **Restore:** fetch `keys/`, unlock with password or recovery phrase, decrypt the chosen manifest, download every
  piece, verify each SHA-256, and assemble into a **new** directory (never overwrite an existing vault).
  Partial results MUST be removed on failure.
- **Prune:** delete chosen manifests first, then delete objects referenced by no remaining manifest.
  Prune MUST NOT run concurrently with a push to the same repository.
- **Check:** shallow = every referenced object exists; deep = every object's SHA-256 matches its key.

## 9. Security considerations

Protected: file and directory names, file contents, symlink targets, the directory hierarchy (all directories are siblings under `d/`).

Visible to anyone holding the ciphertext (cloud provider, admin, backup host):
number of files and directories, each file's size (±28 bytes per 32 KiB), modification times, which files change and when,
the vault ID, and the scrypt parameters. Backup repositories additionally reveal piece sizes and how many pieces change per snapshot.

While a vault is **unlocked**, its cleartext is available to any process running as the user, by design.
Clients SHOULD offer automatic locking (sleep, screen lock, idle timeout, app quit) and SHOULD show which processes
are using the unlocked vault.

Not protected against: malware running as the user while the vault is unlocked; a weak password combined with offline
attacks on `masterkey.cryptomator` (scrypt slows this down but cannot prevent it); loss of both password and recovery phrase.

## 10. Compatibility tests (required before this draft is frozen)

Run `interop/run-interop.sh` (Swift reference implementation ⇄ Cryptomator's cryptofs/cryptolib, the libraries the Cryptomator
desktop app is built on). Status on 2026-10-22, cryptofs 2.9.0 / cryptolib 2.2.1:

1. ✅ A vault created by FolderSafe (with `foldersafe/` present) is listed and read correctly by cryptofs, and cryptofs can write
   into it; FolderSafe then reads the result, also via the recovery phrase.
   ⬜ Still to do by hand: open the same vault in the Cryptomator desktop app and in Cryptomator for iOS / Android.
2. ✅ A vault created by cryptofs opens in FolderSafe; FolderSafe writes into it and adds `foldersafe/`; cryptofs still reads it.
3. ✅ Published test vectors `docs/spec/test-vectors/v1.json` (keys, AES-SIV, scrypt, masterkey file, vault config, directory paths,
   short and long names, file content with 0 / 5 / 32768 / 32769 bytes, recovery phrase and `recovery.json`) are generated by the
   reference implementation and the L1 part is independently re-computed with cryptolib (`run.sh verify-vectors`: 64 checks pass).
   ⬜ `.fsm` manifest vectors are added together with the L3 implementation.
4. Every FolderSafe client (each platform implements this format natively) MUST reproduce all test vectors, and must open,
   read and write vaults created by every other FolderSafe client and by Cryptomator (cross-client interop suite).

The test tree covers: empty, 1-byte, 32768-byte and 100000-byte files; nested and empty directories; 230-character file and
directory names (shortened to `.c9s`); Chinese / emoji names; an NFD name; relative and absolute symlinks.

## 11. Resolved questions (2026-10-22, from cryptofs/cryptolib sources and on-disk experiments)

1. **AES-SIV key order**: cryptolib calls `SivMode.encrypt(ctrKey = encKey, macKey = macKey, …)`, so the RFC 5297 key is
   `macKey || encKey`. Confirmed by recomputing the root directory hash and by the test vectors. The vault config JWT is signed
   with `rawKey = encKey || macKey`.
2. **Padding**: names use padded base64url (Guava `base64Url()`); unpadded names are silently hidden by cryptofs (§3).
3. **Extra `foldersafe/` directory**: cryptofs only reads `vault.cryptomator`, `masterkey.cryptomator` and `d/`; it never lists the
   vault root, so `foldersafe/` is ignored without warnings and left untouched.
4. **`dirid.c9r`**: written for every directory including the root; content is the directory's own ID (empty for the root),
   encrypted as a regular file. Written through cryptofs' channel API, an empty cleartext gets one empty chunk (§6.1, §6.2).
5. **Backups**: `<name>.<first 4 bytes of SHA-256 of the old content, upper-case hex>.bkup`. cryptofs writes
   `vault.cryptomator.<X>.bkup` on every open; the desktop app backs up `masterkey.cryptomator` on unlock and on password
   change, and its recovery flow restores the newest `masterkey.cryptomator*.bkup` (§5.2).
6. **Sync conflicts**: Cryptomator's `C9rConflictResolver` rules, adopted in §6.5.

Further findings: directory IDs longer than 36 bytes are rejected (§6.2); the shortening threshold counts the `.c9r` suffix and
must be read from the vault config (§6.4); cryptolib does not normalise passwords, the apps do (§5.2); Cryptomator's apps use an
empty pepper; cryptolib 2.3+ caps scrypt at N ≤ 2^20, r ≤ 64 and 1 GiB of memory, which FolderSafe readers also enforce;
cryptofs 2.10+ may write `<name>.c9u` in-use markers next to open files, which other clients must ignore and keep (§4).

## 12. Versioning

- Breaking changes to L1 follow Cryptomator's `format` number; FolderSafe will not change L1 on its own.
- L2/L3 changes increment the relevant extension or manifest `version`. Readers MUST reject versions they do not know
  for writing and SHOULD still read what they can.
