import XCTest
import CryptoKit
@testable import FolderSafeCore

final class VaultTests: XCTestCase {
    var dir: URL!
    let pw = "correct horse battery"

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("fscore-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// 测试用低强度 scrypt，省时间；真实默认值另有测试。
    func makeVault() throws -> (Vault, RecoveryPhrase) { try Vault.create(at: dir, password: pw, scryptN: 1024) }

    func testCreateLayoutAndDefaults() throws {
        let (v, phrase) = try Vault.create(at: dir, password: pw)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(files, ["d", "foldersafe", "masterkey.cryptomator", "vault.cryptomator"])
        let mk = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("masterkey.cryptomator"))) as! [String: Any]
        XCTAssertEqual(mk["scryptCostParam"] as? Int, 32768)
        XCTAssertEqual(mk["scryptBlockSize"] as? Int, 8)
        XCTAssertEqual(mk["version"] as? Int, 999)
        XCTAssertEqual(phrase.words.count, 12)
        XCTAssertEqual(v.config.shorteningThreshold, 220)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(v.names.dirPath("")).path))
    }

    func testOpenWithPasswordPhraseAndRawKey() throws {
        let (v, phrase) = try makeVault()
        try v.writeFile("/a.txt", data: Data("hello".utf8))
        XCTAssertEqual(try Vault.open(at: dir, password: pw).readFile("a.txt"), Data("hello".utf8))
        XCTAssertEqual(try Vault.open(at: dir, recoveryPhrase: phrase.phrase.uppercased()).readFile("a.txt"), Data("hello".utf8))
        XCTAssertEqual(try Vault.open(at: dir, rawKey: v.masterkey.raw).readFile("a.txt"), Data("hello".utf8))
        XCTAssertThrowsError(try Vault.open(at: dir, password: "wrong password")) { XCTAssertEqual($0 as? VaultError, .wrongPassword) }
        let other = RecoveryPhrase.generate(SystemRandom.shared)
        XCTAssertThrowsError(try Vault.open(at: dir, recoveryPhrase: other.phrase)) { XCTAssertEqual($0 as? VaultError, .wrongRecoveryPhrase) }
        XCTAssertThrowsError(try Vault.open(at: dir, rawKey: Data(repeating: 1, count: 64)))
    }

    func testFileSizesAroundChunkBoundaries() throws {
        let (v, _) = try makeVault()
        for size in [0, 1, 32767, 32768, 32769, 65536, 100_000] {
            let data = DeterministicRandom(seed: "f\(size)").bytes(size)
            try v.writeFile("/f\(size)", data: data)
            XCTAssertEqual(try v.readFile("/f\(size)"), data, "size \(size)")
            XCTAssertEqual(try v.contentsOfDirectory("/").first { $0.name == "f\(size)" }?.size, size)
        }
        XCTAssertNil(FileCipher.cleartextSize(ciphertextSize: 68 + 27))      // 不可能的大小
        XCTAssertEqual(FileCipher.cleartextSize(ciphertextSize: 68 + 28), 0) // Cryptomator 写空明文时带一个空块
        XCTAssertEqual(FileCipher.cleartextSize(ciphertextSize: 68 + 29), 1)
        // 手工造一个"头 + 空块"的空文件，必须能读
        let h = FileCipher.newHeader(SystemRandom.shared)
        let nonce = SystemRandom.shared.bytes(12)
        let box = try AES.GCM.seal(Data(), using: SymmetricKey(data: h.contentKey), nonce: AES.GCM.Nonce(data: nonce),
                                   authenticating: FileCipher.chunkAAD(0, h))
        let emptyWithChunk = try FileCipher.encryptHeader(h, encKey: v.masterkey.encKey) + box.combined!
        XCTAssertEqual(emptyWithChunk.count, 96)
        XCTAssertEqual(try FileCipher.decrypt(emptyWithChunk, encKey: v.masterkey.encKey), Data())
    }

    func testDirectoriesLongNamesUnicodeAndSymlinks() throws {
        let (v, _) = try makeVault()
        let long = String(repeating: "长", count: 120) + ".txt"
        try v.createDirectory("/文档")
        try v.createDirectory("/文档/子目录")
        try v.writeFile("/文档/子目录/" + long, data: Data("long".utf8))
        try v.writeFile("/文档/e\u{301}.txt", data: Data("nfd".utf8))   // NFD 写入，NFC 读出
        try v.createSymlink("/link", target: "../outside/路径")
        try v.createDirectory("/" + String(repeating: "d", count: 200))
        XCTAssertEqual(try v.contentsOfDirectory("/文档").map(\.name), ["\u{e9}.txt", "子目录"])
        XCTAssertEqual(try v.readFile("/文档/\u{e9}.txt"), Data("nfd".utf8))
        let entries = try v.contentsOfDirectory("/文档/子目录")
        XCTAssertEqual(entries.map(\.name), [long])
        XCTAssertEqual(entries.first?.kind, .file)
        XCTAssertEqual(entries.first?.size, 4)
        XCTAssertEqual(try v.readSymlink("/link"), "../outside/路径")
        XCTAssertEqual(try v.kind(of: "/link"), .symlink)
        XCTAssertEqual(try v.kind(of: "/" + String(repeating: "d", count: 200)), .directory)
        // 长名确实走了 .c9s
        let sub = try v.dirId(of: ["文档", "子目录"])
        let stored = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent(v.names.dirPath(sub)).path)
        XCTAssertTrue(stored.contains { $0.hasSuffix(".c9s") })
        XCTAssertTrue(stored.contains("dirid.c9r"))
        XCTAssertThrowsError(try v.writeFile("/文档", data: Data()))
        XCTAssertThrowsError(try v.createDirectory("/没有/x"))
        XCTAssertThrowsError(try v.readFile("/../etc/passwd"))
    }

    func testMoveBetweenShortAndLongNames() throws {
        let (v, _) = try makeVault()
        let long = String(repeating: "x", count: 250)
        try v.createDirectory("/d")
        try v.writeFile("/d/a", data: Data("A".utf8))
        try v.move("/d/a", to: "/" + long)
        try v.move("/" + long, to: "/b")
        XCTAssertEqual(try v.readFile("/b"), Data("A".utf8))
        try v.writeFile("/d/inner", data: Data("I".utf8))
        try v.move("/d", to: "/" + long)
        XCTAssertEqual(try v.readFile("/" + long + "/inner"), Data("I".utf8))
        try v.move("/" + long, to: "/e")
        XCTAssertEqual(try v.readFile("/e/inner"), Data("I".utf8))
        XCTAssertThrowsError(try v.move("/e", to: "/e/sub"))
        XCTAssertEqual(try v.contentsOfDirectory("/").map(\.name), ["b", "e"])
    }

    func testRemoveIsRecursiveAndLeavesNoStorageDirs() throws {
        let (v, _) = try makeVault()
        try v.createDirectory("/x")
        try v.createDirectory("/x/y")
        try v.writeFile("/x/y/z", data: Data("z".utf8))
        try v.remove("/x")
        XCTAssertEqual(try v.contentsOfDirectory("/"), [])
        // 只剩根目录的存储目录
        let d = dir.appendingPathComponent("d")
        let leaves = try FileManager.default.subpathsOfDirectory(atPath: d.path).filter { $0.split(separator: "/").count == 2 }
        XCTAssertEqual(leaves, [String(v.names.dirPath("").dropFirst(2))])
    }

    func testChangePasswordAndRegeneratePhrase() throws {
        let (v, oldPhrase) = try makeVault()
        try v.writeFile("/a", data: Data("a".utf8))
        try v.changePassword(to: "a brand new password")
        XCTAssertThrowsError(try Vault.open(at: dir, password: pw))
        XCTAssertEqual(try Vault.open(at: dir, password: "a brand new password").readFile("/a"), Data("a".utf8))
        XCTAssertNoThrow(try Vault.open(at: dir, recoveryPhrase: oldPhrase.phrase))      // 改密码不动短语
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.hasSuffix(".bkup") })
        let newPhrase = try v.enableRecovery()
        XCTAssertThrowsError(try Vault.open(at: dir, recoveryPhrase: oldPhrase.phrase))
        XCTAssertNoThrow(try Vault.open(at: dir, recoveryPhrase: newPhrase.phrase))
        XCTAssertThrowsError(try v.changePassword(to: "short"))
    }

    func testUnknownRequiredExtensionMeansReadOnly() throws {
        let (v, _) = try makeVault()
        try v.writeFile("/a", data: Data("a".utf8))
        try Data(#"{"foldersafe": 1, "extensions": {"recovery": 1, "future": 3}, "requires": ["future"]}"#.utf8)
            .write(to: dir.appendingPathComponent("foldersafe/extensions.json"))
        let ro = try Vault.open(at: dir, password: pw)
        XCTAssertTrue(ro.isReadOnly)
        XCTAssertEqual(try ro.readFile("/a"), Data("a".utf8))
        XCTAssertThrowsError(try ro.writeFile("/b", data: Data())) { XCTAssertEqual($0 as? VaultError, .readOnly) }
    }

    func testTamperingIsDetected() throws {
        let (v, _) = try makeVault()
        try v.writeFile("/a", data: Data(repeating: 7, count: 40_000))
        let node = v.node("a", in: "")
        var c = try Data(contentsOf: node.url)
        c[c.count - 5] ^= 1
        try c.write(to: node.url)
        XCTAssertThrowsError(try v.readFile("/a"))
        // 交换两个块的顺序也必须失败（AAD 绑定块序号）
        try v.writeFile("/b", data: DeterministicRandom(seed: "b").bytes(65536))
        let bn = v.node("b", in: "")
        let bc = try Data(contentsOf: bn.url)
        let h = bc.prefix(68), c0 = bc[68..<68 + 32796], c1 = bc[(68 + 32796)...]
        try (h + c1 + c0).write(to: bn.url)
        XCTAssertThrowsError(try v.readFile("/b"))
        // vault.cryptomator 签名被改
        let cfg = dir.appendingPathComponent("vault.cryptomator")
        let token = try String(contentsOf: cfg, encoding: .utf8)
        try (token.dropLast(2) + "AA").write(to: cfg, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try Vault.open(at: dir, password: pw))
    }

    func testRecoveryPhraseParsing() throws {
        XCTAssertEqual(RecoveryPhrase(entropy: Data(repeating: 0, count: 16)).phrase,
                       "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about")
        XCTAssertEqual(RecoveryPhrase(entropy: Data(repeating: 0xff, count: 16)).phrase,
                       "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong")
        let p = RecoveryPhrase.generate(SystemRandom.shared)
        XCTAssertEqual(try RecoveryPhrase(phrase: p.words.map { String($0.prefix(4)) }.joined(separator: "  ")), p)
        XCTAssertThrowsError(try RecoveryPhrase(phrase: Array(repeating: "abandon", count: 12).joined(separator: " ")))
        let text = BIP39.words.joined(separator: "\n") + "\n"
        XCTAssertEqual(Encoding.hex(SHA256.hash(data: Data(text.utf8))), "2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda")
    }

    func testRootHasDirIdBackupAndUnknownEntriesAreIgnored() throws {
        let (v, _) = try makeVault()
        let rootDir = dir.appendingPathComponent(v.names.dirPath(""))
        let backup = try Data(contentsOf: rootDir.appendingPathComponent("dirid.c9r"))
        XCTAssertEqual(try FileCipher.decrypt(backup, encKey: v.masterkey.encKey), Data())
        try v.writeFile("/a", data: Data("a".utf8))
        // Cryptomator 2.10+ 的"使用中"标记、其他软件的杂项文件：忽略且保留
        try Data("x".utf8).write(to: rootDir.appendingPathComponent("QUJDREVGR0hJSktMTU5PUA==.c9u"))
        try Data("x".utf8).write(to: rootDir.appendingPathComponent("notes.txt"))
        XCTAssertEqual(try v.contentsOfDirectory("/").map(\.name), ["a"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootDir.appendingPathComponent("QUJDREVGR0hJSktMTU5PUA==.c9u").path))
    }

    func testSyncConflictCopies() throws {
        let (v, _) = try makeVault()
        let rootDir = dir.appendingPathComponent(v.names.dirPath(""))
        func enc(_ n: String) -> String { String(v.names.encrypt(n, parentDirId: "").dropLast(4)) }
        try v.writeFile("/hello.txt", data: Data("original".utf8))
        // 1. 文件冲突副本 → 改名为"基名 + 后缀 + 扩展名"
        try FileManager.default.copyItem(at: rootDir.appendingPathComponent(enc("hello.txt") + ".c9r"),
                                         to: rootDir.appendingPathComponent(enc("hello.txt") + " (conflicted copy 2026-10-22).c9r"))
        // 2. 正本已经不在的副本 → 改回正本
        try v.writeFile("/gone.md", data: Data("g".utf8))
        try FileManager.default.moveItem(at: rootDir.appendingPathComponent(enc("gone.md") + ".c9r"),
                                         to: rootDir.appendingPathComponent(enc("gone.md") + " (1).c9r"))
        // 3. 内容相同的目录副本 → 删除（否则两个节点共用一个目录 ID）
        try v.createDirectory("/docs")
        try FileManager.default.copyItem(at: rootDir.appendingPathComponent(enc("docs") + ".c9r"),
                                         to: rootDir.appendingPathComponent(enc("docs") + " (1).c9r"))
        // 4. 前缀形式、没有后缀 → (1)
        try FileManager.default.copyItem(at: rootDir.appendingPathComponent(enc("hello.txt") + ".c9r"),
                                         to: rootDir.appendingPathComponent("conflict-" + enc("hello.txt") + ".c9r"))
        let names = try v.contentsOfDirectory("/").map(\.name)
        XCTAssertEqual(Set(names), ["docs", "gone.md", "hello.txt", "hello (conflicted copy 2026-10-22).txt", "hello (1).txt"])
        XCTAssertEqual(try v.readFile("/hello (conflicted copy 2026-10-22).txt"), Data("original".utf8))
        XCTAssertEqual(try v.readFile("/gone.md"), Data("g".utf8))
        // 整理是落盘的：再列一次结果不变，且盘上没有残留的冲突名
        XCTAssertEqual(try v.contentsOfDirectory("/").map(\.name).sorted(), names.sorted())
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: rootDir.path).contains { $0.contains(" (") || $0.hasPrefix("conflict-") })
    }
}
