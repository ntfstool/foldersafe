import XCTest
@testable import FolderSafeCore

/// 可复现的伪随机数（splitmix64），模糊测试失败时能按种子重放。
struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// 句柄随机读写、属性、按目录 ID 寻址。
final class VaultFileTests: XCTestCase {
    var dir: URL!
    let cs = FileCipher.chunkPlainSize

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("fscore-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func makeVault() throws -> Vault { try Vault.create(at: dir, password: "correct horse battery", scryptN: 1024).0 }

    func cipherSize(_ n: Int) -> Int { 68 + n / cs * 32796 + (n % cs > 0 ? n % cs + 28 : 0) }

    /// 盘上的密文（不经过打开的句柄）。
    func raw(_ v: Vault, _ name: String, in id: String = "") throws -> Data { try Data(contentsOf: v.node(name, in: id).contentURL) }

    func nonces(_ c: Data) -> [Data] {
        stride(from: 68, to: c.count, by: 32796).map { Data(c[$0..<$0 + 12]) }
    }

    func testRandomAccessFuzzAgainstModel() throws {
        let v = try makeVault()
        for (k, initial) in [0, 1, 32767, 32768, 32769, 3 * 32768 + 5].enumerated() {
            var rng = SeededRNG(UInt64(1000 + k))
            var model = DeterministicRandom(seed: "init\(initial)").bytes(initial)
            let name = "f\(initial)"
            try v.writeFile("/" + name, data: model)
            var f = try v.openFile("/" + name, writable: true)
            func point() -> Int {          // 一半落在块边界附近
                if Bool.random(using: &rng) { return max(0, Int.random(in: 0...4, using: &rng) * cs + Int.random(in: -3...3, using: &rng)) }
                return Int.random(in: 0...(model.count + 70000), using: &rng)
            }
            for step in 0..<150 {
                let ctx = "size \(initial) step \(step)"
                switch Int.random(in: 0..<10, using: &rng) {
                case 0..<4:
                    let off = point()
                    let len = [1, 2, cs - 1, cs, cs + 1, Int.random(in: 1...70000, using: &rng)].randomElement(using: &rng)!
                    let data = Data((0..<len).map { _ in UInt8.random(in: 0...255, using: &rng) })
                    try f.write(data, at: off)
                    if off > model.count { model.append(Data(count: off - model.count)) }
                    model.replaceSubrange(off..<min(model.count, off + len), with: data)
                case 4..<6:
                    let n = point()
                    try f.truncate(to: n)
                    if n < model.count { model = Data(model.prefix(n)) } else { model.append(Data(count: n - model.count)) }
                case 6..<9:
                    let off = point(), len = Int.random(in: 0...80000, using: &rng)
                    let want = off >= model.count ? Data() : Data(model[off..<min(model.count, off + len)])
                    XCTAssertEqual(try f.read(at: off, count: len), want, ctx)
                default:
                    if Bool.random(using: &rng) {
                        try f.synchronize()
                    } else {
                        try f.close()
                        f = try v.openFile("/" + name, writable: true)
                    }
                }
                XCTAssertEqual(f.size, model.count, ctx)
            }
            XCTAssertEqual(try v.readFile("/" + name), model, "size \(initial): 通过打开的句柄整读")
            try f.close()
            let c = try raw(v, name)
            XCTAssertEqual(c.count, cipherSize(model.count), "size \(initial)")
            XCTAssertEqual(try FileCipher.decrypt(c, encKey: v.masterkey.encKey), model, "size \(initial)")
            XCTAssertEqual(Set(nonces(c)).count, nonces(c).count, "块 nonce 不能重复")
            XCTAssertEqual(try Vault.open(at: dir, password: "correct horse battery").readFile("/" + name), model)
            XCTAssertEqual(try v.attributes(of: "/" + name).size, model.count)
        }
        XCTAssertEqual(try leftovers(), [], "关闭后不应留下临时文件")
    }

    func leftovers() throws -> [String] {
        try FileManager.default.subpathsOfDirectory(atPath: dir.path).filter { ($0 as NSString).lastPathComponent.hasPrefix(".fstmp-") }
    }

    func testOnlyTouchedChunksAreRewrittenWithFreshNonces() throws {
        let v = try makeVault()
        let data = DeterministicRandom(seed: "x").bytes(3 * cs + 5)
        try v.writeFile("/x", data: data)
        let before = nonces(try raw(v, "x"))
        let f = try v.openFile("/x", writable: true)
        try f.write(Data([1, 2]), at: cs + 7)
        try f.close()
        let after = nonces(try raw(v, "x"))
        XCTAssertEqual(after.count, 4)
        XCTAssertEqual(after[0], before[0])
        XCTAssertNotEqual(after[1], before[1])
        XCTAssertEqual(after[2], before[2])
        XCTAssertEqual(after[3], before[3])
        XCTAssertEqual(Data(try raw(v, "x").prefix(68)), Data(try raw(v, "x").prefix(68)))   // 文件头不变
        // 截断：新的最后一块重新加密（新 nonce），长度正确
        let g = try v.openFile("/x", writable: true)
        try g.truncate(to: cs + 5)
        try g.close()
        let c = try raw(v, "x")
        XCTAssertEqual(c.count, 68 + 32796 + 5 + 28)
        XCTAssertNotEqual(nonces(c)[1], after[1])
        var expect = data
        expect[cs + 7] = 1; expect[cs + 8] = 2
        XCTAssertEqual(try v.readFile("/x"), Data(expect.prefix(cs + 5)))
        // 写到末尾之后补零
        let h = try v.openFile("/x", writable: true)
        try h.write(Data([9]), at: 3 * cs + 10)
        try h.close()
        let r = try v.readFile("/x")
        XCTAssertEqual(r.count, 3 * cs + 11)
        XCTAssertEqual(r[(cs + 5)..<(3 * cs + 10)], Data(count: 2 * cs + 5))
        XCTAssertEqual(r.last, 9)
    }

    func testCreateWritesHeaderFirstAndShadowIsAtomic() throws {
        let v = try makeVault()
        let f = try v.createFile("/new.bin")
        XCTAssertThrowsError(try v.createFile("/new.bin")) { XCTAssertEqual($0 as? VaultError, .alreadyExists("new.bin")) }
        XCTAssertEqual(try raw(v, "new.bin").count, 68)                      // 还没写，盘上已是完整的空文件
        XCTAssertEqual(try FileCipher.decrypt(try raw(v, "new.bin"), encKey: v.masterkey.encKey), Data())
        XCTAssertEqual(try v.contentsOfDirectory("/").first?.size, 0)
        try f.write(Data("hello".utf8), at: 0)
        // 未同步：本 vault 里（经共享状态）看得到，盘上的正式文件还是旧的
        XCTAssertEqual(try v.readFile("/new.bin"), Data("hello".utf8))
        XCTAssertEqual(try v.attributes(of: "/new.bin").size, 5)
        XCTAssertEqual(try raw(v, "new.bin").count, 68)
        // "断电重启"：另开一个实例只看盘上内容 → 原文件完好，影子文件被忽略
        let other = try Vault.open(at: dir, password: "correct horse battery")
        XCTAssertEqual(try other.readFile("/new.bin"), Data())
        XCTAssertEqual(try other.contentsOfDirectory("/").map(\.name), ["new.bin"])
        try f.synchronize()
        XCTAssertEqual(try other.readFile("/new.bin"), Data("hello".utf8))
        try f.close()
        XCTAssertThrowsError(try f.read(at: 0, count: 1)) { XCTAssertEqual($0 as? VaultError, .closed) }
        XCTAssertNoThrow(try f.close())
        // 只读句柄不能写
        let ro = try v.openFile("/new.bin")
        XCTAssertThrowsError(try ro.write(Data([1]), at: 0)) { XCTAssertEqual($0 as? VaultError, .readOnly) }
        try ro.close()
        XCTAssertEqual(try leftovers(), [])
    }

    func testHandlesFollowMovesAndSurviveRemoval() throws {
        let v = try makeVault()
        let docs = try v.createDirectory("docs", inDirectory: Vault.rootDirectoryId)
        let f = try v.createFile("a.txt", inDirectory: docs)
        let g = try v.openFile("a.txt", inDirectory: docs)                    // 共享状态：另一个句柄马上看到写入
        try f.write(Data("one".utf8), at: 0)
        XCTAssertEqual(try g.read(at: 0, count: 10), Data("one".utf8))
        try v.move("docs", inDirectory: "", to: "renamed", inDirectory: "")    // 父目录改名：文件位置不变
        try f.write(Data("two".utf8), at: 3)
        let long = String(repeating: "长", count: 100)                          // 改成长名（.c9s），句柄跟着走
        try v.move("a.txt", inDirectory: docs, to: long, inDirectory: "")
        try f.write(Data("!".utf8), at: 6)
        try f.synchronize()
        XCTAssertEqual(try v.readFile("/" + long), Data("onetwo!".utf8))
        try v.move(long, inDirectory: "", to: "b.txt", inDirectory: docs)
        try f.write(Data("?".utf8), at: 7)
        try f.close()
        try g.close()
        XCTAssertEqual(try v.readFile("/renamed/b.txt"), Data("onetwo!?".utf8))
        XCTAssertEqual(try v.contentsOfDirectory("/").map(\.name), ["renamed"])
        // 删除打开着的文件：句柄还能用，关闭后什么都不留下
        let h = try v.openFile("/renamed/b.txt", writable: true)
        try v.remove("/renamed/b.txt")
        try h.write(Data("gone".utf8), at: 100)
        XCTAssertEqual(try h.read(at: 0, count: 3), Data("one".utf8))
        try h.close()
        XCTAssertNil(try v.kind(of: "/renamed/b.txt"))
        // 删掉后同名新建，不会串到旧句柄的状态
        try v.writeFile("/renamed/b.txt", data: Data("new".utf8))
        XCTAssertEqual(try v.readFile("/renamed/b.txt"), Data("new".utf8))
        // 整文件写入替换打开着的文件：句柄改读新内容
        let k = try v.openFile("/renamed/b.txt", writable: true)
        try k.write(Data("xx".utf8), at: 0)
        try v.writeFile("/renamed/b.txt", data: Data("replaced".utf8))
        XCTAssertEqual(try k.read(at: 0, count: 100), Data("replaced".utf8))
        try k.close()
        XCTAssertEqual(try v.readFile("/renamed/b.txt"), Data("replaced".utf8))
        // 删除整个目录时里面打开的文件
        let m = try v.createFile("/renamed/m")
        try m.write(Data("m".utf8), at: 0)
        try v.remove("/renamed")
        try m.write(Data("n".utf8), at: 1)
        try m.close()
        XCTAssertEqual(try v.contentsOfDirectory("/"), [])
        XCTAssertEqual(try leftovers(), [])
    }

    func testAttributesAndModificationDates() throws {
        let v = try makeVault()
        let past = Date(timeIntervalSince1970: 1_600_000_000)
        try v.writeFile("/f", data: Data(count: 40000))
        try v.setModificationDate(past, of: "/f")
        var a = try v.attributes(of: "/f")
        let created = a.creationDate
        XCTAssertEqual(a.kind, .file)
        XCTAssertEqual(a.size, 40000)
        XCTAssertEqual(a.modificationDate.timeIntervalSince1970, past.timeIntervalSince1970, accuracy: 0.001)
        Thread.sleep(forTimeInterval: 1.1)
        // 整文件覆盖、句柄写入都保留创建时间
        try v.writeFile("/f", data: Data(count: 10))
        let f = try v.openFile("/f", writable: true)
        try f.write(Data([1]), at: 50000)
        let later = Date(timeIntervalSinceNow: 3600)       // 比创建时间晚（早于创建时间的 mtime 会被系统连带改掉创建时间）
        try f.setModificationDate(later)                   // 像 cp -p：写完再设时间，关闭后要保持
        try f.close()
        a = try v.attributes(of: "/f")
        XCTAssertEqual(a.size, 50001)
        XCTAssertEqual(a.creationDate.timeIntervalSince1970, created.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(a.modificationDate.timeIntervalSince1970, later.timeIntervalSince1970, accuracy: 0.001)
        // 目录：日期取存储目录；带目录 ID
        let id = try v.createDirectory("/d")
        let d = try v.attributes(of: "/d")
        XCTAssertEqual(d.kind, .directory)
        XCTAssertEqual(d.directoryId, id)
        try v.setModificationDate(past, of: "/d")
        XCTAssertEqual(try v.attributes(of: "/d").modificationDate.timeIntervalSince1970, past.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(try v.attributes(of: "/").directoryId, "")
        // 符号链接：大小是目标的字节数
        try v.createSymlink("/l", target: "目标/x")
        XCTAssertEqual(try v.attributes(of: "/l").size, "目标/x".utf8.count)
        XCTAssertEqual(try v.contentsOfDirectory("/").map(\.kind), [.directory, .file, .symlink])
        XCTAssertThrowsError(try v.attributes(of: "/nope")) { XCTAssertEqual($0 as? VaultError, .notFound("nope")) }
    }

    func testDirectoryIdAddressing() throws {
        let v = try makeVault()
        let root = Vault.rootDirectoryId
        let a = try v.createDirectory("a", inDirectory: root)
        let b = try v.createDirectory("b", inDirectory: a)
        try v.writeFile("x", inDirectory: b, data: Data("x".utf8))
        XCTAssertEqual(try v.contentsOfDirectory(id: root).map(\.directoryId), [a])
        XCTAssertEqual(try v.lookup("b", inDirectory: a)?.directoryId, b)
        XCTAssertEqual(try v.lookup("x", inDirectory: b)?.parentId, b)
        XCTAssertNil(try v.lookup("nope", inDirectory: b))
        // 改名、移动：目录 ID 不变
        try v.move("a", inDirectory: root, to: "A", inDirectory: root)
        try v.move("b", inDirectory: a, to: "B", inDirectory: root)
        XCTAssertEqual(try v.directoryId(of: "/B"), b)
        XCTAssertEqual(try v.readFile("x", inDirectory: b), Data("x".utf8))
        XCTAssertEqual(try v.contentsOfDirectory(id: b).map(\.name), ["x"])
        // 不能挪进自己或子孙目录
        let c = try v.createDirectory("c", inDirectory: b)
        XCTAssertThrowsError(try v.move("B", inDirectory: root, to: "B", inDirectory: c))
        XCTAssertThrowsError(try v.move("B", inDirectory: root, to: "self", inDirectory: b))
        XCTAssertThrowsError(try v.move("/B", to: "/B/c/deeper"))
        // 名字非法、目录不存在
        XCTAssertThrowsError(try v.writeFile("a/b", inDirectory: root, data: Data())) { XCTAssertEqual($0 as? VaultError, .invalidName("a/b")) }
        XCTAssertThrowsError(try v.createDirectory("..", inDirectory: root))
        XCTAssertThrowsError(try v.contentsOfDirectory(id: "00000000-0000-4000-8000-000000000000"))
        // 替换移动
        try v.writeFile("y", inDirectory: b, data: Data("y".utf8))
        XCTAssertThrowsError(try v.move("x", inDirectory: b, to: "y", inDirectory: b)) { XCTAssertEqual($0 as? VaultError, .alreadyExists("y")) }
        try v.move("x", inDirectory: b, to: "y", inDirectory: b, replacing: true)
        XCTAssertEqual(try v.contentsOfDirectory(id: b).map(\.name), ["c", "y"])
        XCTAssertEqual(try v.readFile("y", inDirectory: b), Data("x".utf8))
        XCTAssertThrowsError(try v.move("y", inDirectory: b, to: "c", inDirectory: b, replacing: true))   // 文件不能替换目录
        let e = try v.createDirectory("e", inDirectory: root)
        try v.move("e", inDirectory: root, to: "c", inDirectory: b, replacing: true)                    // 空目录可以被替换
        XCTAssertEqual(try v.lookup("c", inDirectory: b)?.directoryId, e)
        XCTAssertFalse(v.directoryExists(id: c))
        try v.writeFile("z", inDirectory: e, data: Data())
        try v.createDirectory("f", inDirectory: root)
        XCTAssertThrowsError(try v.move("f", inDirectory: root, to: "c", inDirectory: b, replacing: true))  // 非空目录不行
        // 删除：整棵子树的存储目录都不在了
        try v.remove("B", inDirectory: root)
        XCTAssertFalse(v.directoryExists(id: b))
        XCTAssertFalse(v.directoryExists(id: e))
        XCTAssertEqual(try v.contentsOfDirectory(id: root).map(\.name), ["A", "f"])
    }

    func testStreamingImportExport() throws {
        let v = try makeVault()
        for size in [0, 1, cs, 3 * cs + 5, Vault.streamPiece + 1] {
            let data = DeterministicRandom(seed: "s\(size)").bytes(size)
            let src = dir.appendingPathComponent("src-\(size)"), dst = dir.appendingPathComponent("dst-\(size)")
            try data.write(to: src)
            try v.importFile("/i\(size)", from: src)
            XCTAssertEqual(try FileCipher.decrypt(try raw(v, "i\(size)"), encKey: v.masterkey.encKey), data)
            XCTAssertEqual(try raw(v, "i\(size)").count, cipherSize(size))
            try v.exportFile("/i\(size)", to: dst)
            XCTAssertEqual(try Data(contentsOf: dst), data)
        }
        XCTAssertThrowsError(try v.importFile("/missing", from: dir.appendingPathComponent("no-such-file")))
        XCTAssertNil(try v.kind(of: "/missing"))
    }
}
