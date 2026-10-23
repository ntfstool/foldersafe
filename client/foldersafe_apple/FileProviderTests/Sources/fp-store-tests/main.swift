// File Provider 后端（VaultStore + ItemIndex）的单元级测试：真实 vault，无 File Provider 运行时。
import Foundation
import CryptoKit
@testable import FPExt
import FolderSafeCore

var failures = 0
func check(_ cond: @autoclosure () throws -> Bool, _ msg: String, line: Int = #line) {
    if (try? cond()) == true { print("  ✓ \(msg)") } else { print("  ✗ \(msg) (line \(line))"); failures += 1 }
}
func time<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
    let t = Date(); let r = try body(); print(String(format: "  ⏱ %@: %.2fs", label, Date().timeIntervalSince(t))); return r
}

let args = CommandLine.arguments
let work = URL(fileURLWithPath: args.count > 1 ? args[1] : NSTemporaryDirectory() + "fpunit-\(UUID().uuidString)")
try? FileManager.default.removeItem(at: work)
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
let vaultURL = work.appendingPathComponent("vault")
let (vault, _) = try Vault.create(at: vaultURL, password: "testpass123", scryptN: 1024)
let raw = vault.masterkey.raw
let indexURL = work.appendingPathComponent("index.bin")
func makeStore() throws -> VaultStore {
    VaultStore(vault: try Vault.open(at: vaultURL, rawKey: raw), index: ItemIndex(fileURL: indexURL, rawKey: raw, vaultId: vault.config.vaultId))
}
var store = try makeStore()
func tmpFile(_ data: Data) -> URL {
    let u = work.appendingPathComponent("in-\(UUID().uuidString)"); try! data.write(to: u); return u
}

print("1. create / list")
let root = try store.item("")
check(root.isRoot && root.kind == .directory, "root item")
let a = try store.create(parent: "", name: "a.txt", kind: .file, contents: tmpFile(Data("hello".utf8)), symlinkTarget: nil,
                         modified: Date(timeIntervalSince1970: 1_600_000_000), mayAlreadyExist: false)
check(a.id.hasPrefix("f.") && a.size == 5, "file created with random id")
check(abs(a.modified.timeIntervalSince1970 - 1_600_000_000) < 0.01, "mtime set from template")
let dir = try store.create(parent: "", name: "文件夹 📁", kind: .directory, contents: nil, symlinkTarget: nil, modified: nil, mayAlreadyExist: false)
check(try !dir.id.hasPrefix("f.") && vault.directoryId(of: "/文件夹 📁") == dir.id, "directory id == vault dirId")
let ln = try store.create(parent: dir.id, name: "link", kind: .symlink, contents: nil, symlinkTarget: "../a.txt", modified: nil, mayAlreadyExist: false)
check(ln.symlinkTarget == "../a.txt", "symlink target")
let long = String(repeating: "长", count: 120) + ".txt"
let lf = try store.create(parent: dir.id, name: long, kind: .file, contents: nil, symlinkTarget: nil, modified: nil, mayAlreadyExist: false)
check(lf.size == 0, "empty file with long (shortened) name")
do { _ = try store.create(parent: "", name: "a.txt", kind: .file, contents: nil, symlinkTarget: nil, modified: nil, mayAlreadyExist: false); check(false, "collision") }
catch StoreError.collision(let ex) { check(ex == a.id, "collision reports existing id") }
let rootList = try store.list("")
check(Set(rootList.map(\.name)) == ["a.txt", "文件夹 📁"], "list root")
check(rootList.first { $0.name == "a.txt" }?.id == a.id, "listing keeps file id")
let dirList = try store.list(dir.id)
check(dirList.count == 2, "list subdir")

print("2. rename / move keep ids")
let a2 = try store.modify(a.id, newParent: dir.id, newName: "b.txt", contents: nil, replaceContents: false, modified: nil, baseContentVersion: nil).info
check(a2.id == a.id && a2.parent == dir.id && a2.name == "b.txt", "file move+rename keeps id")
check(a2.contentVersion == a.contentVersion, "move does not change content version")
check(String(data: try vault.readFile("/文件夹 📁/b.txt"), encoding: .utf8) == "hello", "content intact after move")
let sub = try store.create(parent: "", name: "sub", kind: .directory, contents: nil, symlinkTarget: nil, modified: nil, mayAlreadyExist: false)
let d2 = try store.modify(dir.id, newParent: sub.id, newName: "moved", contents: nil, replaceContents: false, modified: nil, baseContentVersion: nil).info
check(d2.id == dir.id && d2.parent == sub.id, "dir move keeps dirId")
check(try store.item(a.id).parent == dir.id, "child still resolvable after parent move")
do { _ = try store.modify(sub.id, newParent: dir.id, newName: nil, contents: nil, replaceContents: false, modified: nil, baseContentVersion: nil); check(false, "move into own subtree") }
catch { check(true, "move into own subtree refused") }
let caseOnly = try store.modify(a.id, newParent: nil, newName: "B.txt", contents: nil, replaceContents: false, modified: nil, baseContentVersion: nil).info
check(caseOnly.name == "B.txt" && caseOnly.id == a.id, "case-only rename")

print("3. replace contents / conflict")
let before = try store.item(a.id)
let r1 = try store.modify(a.id, newParent: nil, newName: nil, contents: tmpFile(Data("version 2".utf8)), replaceContents: true,
                          modified: nil, baseContentVersion: before.contentVersion)
check(!r1.conflictCopySaved && r1.info.size == 9 && r1.info.contentVersion != before.contentVersion, "content replaced, version bumped")
// 外部改动（另一个 Vault 实例，模拟网盘同步来的新版本）
let other = try Vault.open(at: vaultURL, rawKey: raw)
Thread.sleep(forTimeInterval: 0.01)
try other.writeFile("/sub/moved/B.txt", data: Data("remote edit".utf8))
let r2 = try store.modify(a.id, newParent: nil, newName: nil, contents: tmpFile(Data("local edit".utf8)), replaceContents: true,
                          modified: nil, baseContentVersion: r1.info.contentVersion)
check(r2.conflictCopySaved, "stale base version → conflict copy")
check(String(data: try vault.readFile("/sub/moved/B.txt"), encoding: .utf8) == "remote edit", "remote version kept")
let names = try vault.contentsOfDirectory("/sub/moved").map(\.name)
check(names.contains { $0.hasPrefix("B (conflict ") && $0.hasSuffix(".txt") }, "local version saved as conflict copy: \(names)")

print("3b. no silent overwrite / truncation")
let mx = try store.create(parent: "", name: "mx.txt", kind: .file, contents: tmpFile(Data("vault version".utf8)), symlinkTarget: nil, modified: nil, mayAlreadyExist: false)
let same = try store.createItem(parent: "", name: "mx.txt", kind: .file, contents: tmpFile(Data("vault version".utf8)), symlinkTarget: nil, modified: nil, mayAlreadyExist: true)
check(!same.conflictCopySaved && same.info.id == mx.id, "mayAlreadyExist + same content → reuse, no conflict copy")
let diff = try store.createItem(parent: "", name: "mx.txt", kind: .file, contents: tmpFile(Data("other device".utf8)), symlinkTarget: nil, modified: nil, mayAlreadyExist: true)
check(diff.conflictCopySaved && diff.info.id == mx.id, "mayAlreadyExist + different content → conflict copy")
check(String(data: try vault.readFile("/mx.txt"), encoding: .utf8) == "vault version", "existing vault content not overwritten")
let mxNames = try vault.contentsOfDirectory("/").map(\.name).filter { $0.hasPrefix("mx (conflict ") }
check(try mxNames.count == 1 && String(data: vault.readFile("/" + mxNames[0]), encoding: .utf8) == "other device", "incoming content kept as conflict copy")
let mx2 = try store.modify(mx.id, newParent: nil, newName: nil, contents: nil, replaceContents: true, modified: nil, baseContentVersion: nil).info
check(try mx2.size == 13 && String(data: vault.readFile("/mx.txt"), encoding: .utf8) == "vault version", "replaceContents without contents does not truncate")

print("4. external changes → change log")
let anchor0 = store.anchor
_ = try store.list(sub.id)
_ = try store.list(dir.id)
let anchor1 = store.anchor
try other.writeFile("/new-remote.txt", data: Data("x".utf8))
try other.remove("/sub/moved/link")
try other.move("/sub/moved", to: "/moved-out")
check(store.rescan(), "rescan detects changes")
let ch = try store.changes(after: anchor1.generation, epoch: anchor1.epoch)
check(ch.updated.contains { $0.name == "new-remote.txt" }, "new remote file reported")
check(ch.deleted.contains(ln.id), "deleted symlink reported")
check(ch.updated.contains { $0.id == dir.id && $0.parent == "" && $0.name == "moved-out" }, "external dir move reported with same id")
check(!store.rescan(), "second rescan: no changes")
do { _ = try store.changes(after: 0, epoch: "other-epoch"); check(false, "epoch") } catch StoreError.syncAnchorExpired { check(true, "foreign epoch → anchor expired") }
_ = anchor0

print("5. delete")
do { try store.delete(dir.id, recursive: false, baseContentVersion: nil); check(false, "non-recursive") }
catch StoreError.directoryNotEmpty { check(true, "non-recursive delete of non-empty dir refused") }
let cur = try store.item(a.id)
try other.writeFile("/moved-out/B.txt", data: Data("changed again".utf8))
do { try store.delete(a.id, recursive: false, baseContentVersion: cur.contentVersion); check(false, "deletionRejected") }
catch StoreError.deletionRejected { check(true, "delete of externally-changed file rejected") }
do { try store.delete(dir.id, recursive: true, baseContentVersion: nil); check(false, "recursive delete with unseen change") }
catch StoreError.deletionRejected { check(true, "recursive delete refused: folder holds an externally-changed file the system hasn't seen") }
check(String(data: try vault.readFile("/moved-out/B.txt"), encoding: .utf8) == "changed again", "refused recursive delete kept the file")
_ = store.rescan()                                   // 系统拿到了新版本
try other.writeFile("/moved-out/late.txt", data: Data("synced in late".utf8))
do { try store.delete(dir.id, recursive: true, baseContentVersion: nil); check(false, "recursive delete with unseen new file") }
catch StoreError.deletionRejected { check(true, "recursive delete refused: unseen new file in folder") }
check(try vault.kind(of: "/moved-out/late.txt") == .file, "unseen new file kept")
_ = store.rescan()
try store.delete(dir.id, recursive: true, baseContentVersion: nil)
check(try vault.kind(of: "/moved-out") == nil, "recursive delete")
try store.delete(dir.id, recursive: true, baseContentVersion: nil)
check(true, "deleting a missing item succeeds")

print("6. index persistence / rebuild")
let n1 = try store.create(parent: sub.id, name: "persist.txt", kind: .file, contents: nil, symlinkTarget: nil, modified: nil, mayAlreadyExist: false)
store = try makeStore()
check((try? store.item(n1.id))?.name == "persist.txt", "file id survives reopen (encrypted index)")
let blob = try Data(contentsOf: indexURL)
check(blob.range(of: Data("persist".utf8)) == nil, "index file has no cleartext names")
let wrong = ItemIndex(fileURL: indexURL, rawKey: Data(repeating: 1, count: 64), vaultId: vault.config.vaultId)
check(wrong.allIDs.isEmpty, "wrong key → empty index")
try FileManager.default.removeItem(at: indexURL)
store = try makeStore()
check((try? store.item(sub.id))?.name == "sub", "dir found again by dirId after index loss")
check((try? store.item(n1.id)) == nil, "file id unknown after index loss (expected)")

print("7. scale")
let many = try store.create(parent: "", name: "many", kind: .directory, contents: nil, symlinkTarget: nil, modified: nil, mayAlreadyExist: false)
let small = tmpFile(Data(repeating: 7, count: 1000))
try time("create 1000 files via store") {
    for i in 0..<1000 { _ = try store.create(parent: many.id, name: "file \(i) 文件.bin", kind: .file, contents: small, symlinkTarget: nil, modified: nil, mayAlreadyExist: false) }
}
let l = try time("list 1000") { try store.list(many.id) }
check(l.count == 1000, "1000 listed")
try time("rescan with 1000 known") { _ = store.rescan() }
var big = Data(count: 100 * 1024 * 1024)
big.withUnsafeMutableBytes { p in for i in stride(from: 0, to: p.count, by: 4096) { p[i] = UInt8(i / 4096 & 0xff) } }
let bigIn = tmpFile(big)
big = Data()
let bi = try time("import 100 MB") { try store.create(parent: "", name: "big.bin", kind: .file, contents: bigIn, symlinkTarget: nil, modified: nil, mayAlreadyExist: false) }
let bigOut = work.appendingPathComponent("out.bin")
_ = try time("export 100 MB") { try store.export(bi.id, to: bigOut) }
check(SHA256.hash(data: try Data(contentsOf: bigOut, options: .mappedIfSafe)) == SHA256.hash(data: try Data(contentsOf: bigIn, options: .mappedIfSafe)), "100 MB roundtrip identical")
try? FileManager.default.removeItem(at: bigOut)
try? FileManager.default.removeItem(at: bigIn)

print(failures == 0 ? "ALL OK — vault at \(vaultURL.path)" : "\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
