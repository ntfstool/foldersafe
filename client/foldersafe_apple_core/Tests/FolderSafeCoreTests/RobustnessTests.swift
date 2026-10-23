import XCTest
import CryptoKit
@testable import FolderSafeCore

/// 并发、断电残留、大数据。大数据基准默认跳过：FS_BENCH=1 swift test -c release -Xswiftc -enable-testing --filter RobustnessTests
final class RobustnessTests: XCTestCase {
    var dir: URL!
    let pw = "correct horse battery"

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("fscore-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// 自校验内容：8 字节长度 + 数据 + 前面内容的 SHA-256 前 8 字节。读到撕裂 / 混杂的内容一定校验不过。
    static func payload(_ seed: String, _ n: Int) -> Data {
        var d = Data(withUnsafeBytes(of: UInt64(n).bigEndian) { Data($0) }) + DeterministicRandom(seed: seed).bytes(n)
        d += SHA256.hash(data: d).prefix(8)
        return d
    }

    static func valid(_ d: Data) -> Bool {
        guard d.count >= 16 else { return d.isEmpty }       // 句柄先截断再写：中间允许看到空文件
        let n = d.prefix(8).reduce(0) { $0 << 8 | Int($1) }
        return n == d.count - 16 && Data(SHA256.hash(data: d.prefix(d.count - 8)).prefix(8)) == d.suffix(8)
    }

    /// 并发时允许的"正常"失败：条目刚被别的线程删掉 / 挪走 / 抢先建好。
    static func benign(_ e: Error) -> Bool {
        switch e as? VaultError {
        case .notFound?, .alreadyExists?, .notADirectory?, .invalidName?: return true
        default: return false
        }
    }

    func testConcurrentReadersAndWriters() throws {
        let (v, _) = try Vault.create(at: dir, password: pw, scryptN: 1024)
        for d in ["d0", "d1", "d2"] {
            try v.createDirectory("/" + d)
            for i in 0..<5 { try v.writeFile("/\(d)/f\(i)", data: Self.payload("\(d)\(i)", i * 20000)) }
        }
        let failures = NSMutableArray()
        let deadline = Date().addingTimeInterval(4)
        func fail(_ what: String) { failures.add(what) }
        DispatchQueue.concurrentPerform(iterations: 10) { worker in
            var rng = SeededRNG(UInt64(worker + 1))
            var ops = 0
            while Date() < deadline || ops < 20 {
                ops += 1
                let d = "/d\(Int.random(in: 0..<3, using: &rng))", name = "f\(Int.random(in: 0..<8, using: &rng))"
                do {
                    if worker < 5 {                                     // 读者：列目录、整读、句柄读
                        for e in try v.contentsOfDirectory(d) where e.kind == .file {
                            do {
                                let data = Bool.random(using: &rng) ? try v.readFile(d + "/" + e.name)
                                    : try { let f = try v.openFile(d + "/" + e.name); defer { try? f.close() }; return try f.read(at: 0, count: .max) }()
                                if !Self.valid(data) { fail("torn read \(d)/\(e.name) \(data.count)") }
                            } catch where Self.benign(error) {}
                        }
                        _ = try v.contentsOfDirectory(id: Vault.rootDirectoryId)
                        continue
                    }
                    // 句柄写是"截断 + 写入"两步，只有一个线程碰的文件才谈得上每次读到完整内容：h 文件归各自的写者所有
                    let own = "h\(worker)-\(Int.random(in: 0..<3, using: &rng))", other = "/d\(Int.random(in: 0..<3, using: &rng))"
                    switch Int.random(in: 0..<8, using: &rng) {
                    case 0: try v.writeFile(d + "/" + name, data: Self.payload("w\(worker)-\(ops)", Int.random(in: 0...100_000, using: &rng)))
                    case 1:
                        let f = try v.kind(of: d + "/" + own) == nil ? try v.createFile(d + "/" + own) : try v.openFile(d + "/" + own, writable: true)
                        try f.truncate(to: 0)
                        try f.write(Self.payload("h\(worker)-\(ops)", Int.random(in: 0...70_000, using: &rng)), at: 0)
                        if Bool.random(using: &rng) { try f.synchronize() }
                        try f.close()
                    case 2: try v.move(d + "/" + name, to: other + "/f\(Int.random(in: 0..<8, using: &rng))")
                    case 3: try v.move(d + "/" + own, to: other + "/" + own)
                    case 4: try v.remove(d + "/" + name)
                    case 5: try v.createDirectory(d + "/sub\(Int.random(in: 0..<3, using: &rng))")
                    case 6: try v.remove(d + "/sub\(Int.random(in: 0..<3, using: &rng))")
                    default:   // 目录在 d0..d2 之间挪来挪去（不会挪进自己）
                        try v.move(d + "/sub\(Int.random(in: 0..<3, using: &rng))", to: other + "/sub\(Int.random(in: 0..<3, using: &rng))")
                    }
                } catch where Self.benign(error) {
                } catch { fail("worker \(worker): \(error)") }
            }
        }
        XCTAssertEqual(failures.count, 0, "\(failures.prefix(10))")
        // 事后一致性：换一个新实例（相当于重启），每个条目都能读，存储目录数 = 能走到的目录数 + 根
        let fresh = try Vault.open(at: dir, password: pw)
        var dirs = 1
        func walk(_ p: String) throws {
            for e in try fresh.contentsOfDirectory(p) {
                let path = p == "/" ? "/" + e.name : p + "/" + e.name
                switch e.kind {
                case .file: XCTAssertTrue(Self.valid(try fresh.readFile(path)), path)
                case .directory: dirs += 1; try walk(path)
                case .symlink: break
                }
            }
        }
        try walk("/")
        let storage = try FileManager.default.subpathsOfDirectory(atPath: dir.appendingPathComponent("d").path)
            .filter { $0.split(separator: "/").count == 2 }
        XCTAssertEqual(storage.count, dirs, "没有孤儿存储目录，也没有丢目录")
        let temps = try FileManager.default.subpathsOfDirectory(atPath: dir.path).filter { $0.contains(".fstmp-") }
        XCTAssertEqual(temps, [])
    }

    func testCrashLeftoversAreHarmless() throws {
        let (v, _) = try Vault.create(at: dir, password: pw, scryptN: 1024)
        let fm = FileManager.default
        try v.writeFile("/keep.txt", data: Data("keep".utf8))
        try v.createDirectory("/sub")
        try v.writeFile("/sub/inner.txt", data: Data("inner".utf8))
        try v.writeFile("/torn.bin", data: Data(count: 100_000))
        try v.writeFile("/empty-cipher", data: Data())
        let rootDir = dir.appendingPathComponent(v.names.dirPath(""))
        // 1. 临时文件残留（写到一半断电）
        try Data(count: 1234).write(to: rootDir.appendingPathComponent(".fstmp-\(UUID().uuidString)"))
        try Data(count: 5).write(to: dir.appendingPathComponent(".fstmp-\(UUID().uuidString)"))
        // 2. 节点外壳在、里面的文件没了（建目录 / 长名写入到一半）
        try fm.createDirectory(at: v.node("half-dir", in: "").url, withIntermediateDirectories: false)
        let longName = String(repeating: "长", count: 100)
        let shell = v.node(longName, in: "")
        try fm.createDirectory(at: shell.url, withIntermediateDirectories: false)
        try Data(v.names.encrypt(longName, parentDirId: "").utf8).write(to: shell.url.appendingPathComponent("name.c9s"))
        // 3. 有存储目录、没有节点（建目录时先建存储目录）
        try fm.createDirectory(at: dir.appendingPathComponent(v.names.dirPath("11111111-1111-4111-8111-111111111111")), withIntermediateDirectories: true)
        // 4. 内容文件被截断（别的客户端原地写到一半）、长度为 0
        let torn = try FileHandle(forWritingTo: v.node("torn.bin", in: "").url)
        try torn.truncate(atOffset: 68 + 32796 + 10)
        try torn.close()
        try Data().write(to: v.node("empty-cipher", in: "").url)
        // 5. 目录节点指向不存在的存储目录；dir.c9r 是空的 / 乱码
        let ghost = v.node("ghost", in: "")
        try fm.createDirectory(at: ghost.url, withIntermediateDirectories: false)
        try Data("22222222-2222-4222-8222-222222222222".utf8).write(to: ghost.url.appendingPathComponent("dir.c9r"))
        let bad = v.node("bad", in: "")
        try fm.createDirectory(at: bad.url, withIntermediateDirectories: false)
        try Data().write(to: bad.url.appendingPathComponent("dir.c9r"))
        // 6. 句柄写了没同步就"断电"（不关闭，另开实例）
        let f = try v.openFile("/keep.txt", writable: true)
        try f.write(Data("CHANGED".utf8), at: 0)
        try f.write(Data("x".utf8), at: 50_000)

        let w = try Vault.open(at: dir, password: pw)
        let names = try w.contentsOfDirectory("/").map(\.name)
        XCTAssertEqual(names, ["empty-cipher", "ghost", "keep.txt", "sub", "torn.bin"])
        XCTAssertEqual(try w.readFile("/keep.txt"), Data("keep".utf8))
        XCTAssertEqual(try w.readFile("/sub/inner.txt"), Data("inner".utf8))
        XCTAssertThrowsError(try w.readFile("/torn.bin"))           // 坏了就报错，不崩、不返回错数据
        XCTAssertThrowsError(try w.openFile("/torn.bin"))
        XCTAssertThrowsError(try w.readFile("/empty-cipher"))
        XCTAssertThrowsError(try w.contentsOfDirectory("/ghost")) { XCTAssertEqual($0 as? VaultError, .notFound("directory 22222222-2222-4222-8222-222222222222")) }
        // 残留外壳上可以照常新建
        try w.createDirectory("/half-dir")
        try w.writeFile("/half-dir/x", data: Data("x".utf8))
        try w.writeFile("/" + longName, data: Data("long".utf8))
        XCTAssertEqual(try w.readFile("/" + longName), Data("long".utf8))
        XCTAssertEqual(try w.readFile("/half-dir/x"), Data("x".utf8))
        // 坏文件可以被覆盖修复
        try w.writeFile("/torn.bin", data: Data("fixed".utf8))
        XCTAssertEqual(try w.readFile("/torn.bin"), Data("fixed".utf8))
        // 原来那个句柄同步后，新内容才出现
        try f.close()
        var expect = Data("CHANGED".utf8) + Data(count: 50_000 - 7)
        expect.append(Data("x".utf8))
        XCTAssertEqual(try w.readFile("/keep.txt"), expect)
    }

    // MARK: - 大数据（FS_BENCH=1）

    func testBenchLargeFileAndManyFiles() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FS_BENCH"] == "1", "设 FS_BENCH=1 才跑（建议 release）")
        let (v, _) = try Vault.create(at: dir, password: pw, scryptN: 1024)
        let gib = 1 << 30, piece = 1 << 20
        let block = DeterministicRandom(seed: "bench").bytes(piece)
        func time(_ label: String, bytes: Int? = nil, _ body: () throws -> Void) rethrows {
            let t = Date()
            try body()
            let s = Date().timeIntervalSince(t)
            print(String(format: "BENCH %@: %.2f s", label, s) + (bytes.map { String(format: "  (%.0f MB/s)", Double($0) / s / 1e6) } ?? ""))
        }
        try time("1 GiB 句柄顺序写（1 MiB 一次）+ 同步", bytes: gib) {
            let f = try v.createFile("/big")
            for i in 0..<(gib / piece) { try f.write(block, at: i * piece) }
            try f.close()
        }
        try time("1 GiB 句柄顺序读", bytes: gib) {
            let f = try v.openFile("/big")
            var hash = SHA256(), off = 0
            while off < gib { let d = try f.read(at: off, count: piece); hash.update(data: d); off += d.count }
            try f.close()
        }
        try time("1 GiB 中间改 4 KiB（克隆影子）+ 同步") {
            let f = try v.openFile("/big", writable: true)
            try f.write(Data(count: 4096), at: gib / 2 + 100)
            try f.close()
        }
        try time("1 GiB 随机读 1000 次 × 4 KiB") {
            let f = try v.openFile("/big")
            var rng = SeededRNG(7)
            for _ in 0..<1000 { _ = try f.read(at: Int.random(in: 0..<gib, using: &rng), count: 4096) }
            try f.close()
        }
        let src = dir.appendingPathComponent("plain-src"), dst = dir.appendingPathComponent("plain-dst")
        try v.exportFile("/big", to: src)
        try time("1 GiB 流式导入（importFile）", bytes: gib) { try v.importFile("/big2", from: src) }
        try time("1 GiB 流式导出（exportFile）", bytes: gib) { try v.exportFile("/big2", to: dst) }
        try? FileManager.default.removeItem(at: src)
        try? FileManager.default.removeItem(at: dst)
        try v.remove("/big")
        try v.remove("/big2")
        let id = try v.createDirectory("/many")
        try time("建 10,000 个小文件") {
            for i in 0..<10_000 { try v.writeFile("f\(i).txt", inDirectory: id, data: Data("file \(i)".utf8)) }
        }
        var count = 0
        try time("列 10,000 个文件的目录（含属性）") { count = try v.contentsOfDirectory(id: id).count }
        XCTAssertEqual(count, 10_000)
        try time("再列一次") { count = try v.contentsOfDirectory(id: id).count }
        try time("lookup 10,000 次") { for i in 0..<10_000 { _ = try v.lookup("f\(i).txt", inDirectory: id) } }
    }
}
