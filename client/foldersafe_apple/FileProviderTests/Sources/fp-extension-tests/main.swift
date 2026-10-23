// FileProviderExtension 本身（NSFileProviderReplicatedExtension 方法、枚举器、条目）的进程内测试：假域，真实 vault。
import Foundation
import FileProvider
import UniformTypeIdentifiers
import CryptoKit
@testable import FPExt
import FolderSafeCore

var failures = 0
func check(_ cond: @autoclosure () throws -> Bool, _ msg: String, line: Int = #line) {
    if (try? cond()) == true { print("  ✓ \(msg)") } else { print("  ✗ \(msg) (line \(line))"); failures += 1 }
}

final class Template: NSObject, NSFileProviderItem {
    var itemIdentifier: NSFileProviderItemIdentifier
    var parentItemIdentifier: NSFileProviderItemIdentifier
    var filename: String
    var contentType: UTType
    var contentModificationDate: Date?
    var symlinkTargetPath: String?
    init(_ id: String = UUID().uuidString, parent: NSFileProviderItemIdentifier, name: String, type: UTType, mtime: Date? = nil, target: String? = nil) {
        itemIdentifier = NSFileProviderItemIdentifier(id); parentItemIdentifier = parent; filename = name
        contentType = type; contentModificationDate = mtime; symlinkTargetPath = target
    }
    var itemVersion: NSFileProviderItemVersion { NSFileProviderItemVersion() }
}

final class EnumObs: NSObject, NSFileProviderEnumerationObserver, NSFileProviderChangeObserver {
    var items: [NSFileProviderItem] = []
    var deleted: [NSFileProviderItemIdentifier] = []
    var nextPage: NSFileProviderPage?
    var anchor: NSFileProviderSyncAnchor?
    var error: Error?
    let sem = DispatchSemaphore(value: 0)
    var suggestedPageSize: Int { 100 }
    func didEnumerate(_ updatedItems: [NSFileProviderItem]) { items += updatedItems }
    func finishEnumerating(upTo nextPage: NSFileProviderPage?) { self.nextPage = nextPage; sem.signal() }
    func finishEnumeratingWithError(_ error: Error) { self.error = error; sem.signal() }
    func didUpdate(_ updatedItems: [NSFileProviderItem]) { items += updatedItems }
    func didDeleteItems(withIdentifiers deletedItemIdentifiers: [NSFileProviderItemIdentifier]) { deleted += deletedItemIdentifiers }
    func finishEnumeratingChanges(upTo anchor: NSFileProviderSyncAnchor, moreComing: Bool) { self.anchor = anchor; sem.signal() }
}

func wait<T>(_ body: (@escaping (T) -> Void) -> Progress) -> T {
    let sem = DispatchSemaphore(value: 0)
    var out: T!
    _ = body { out = $0; sem.signal() }
    sem.wait()
    return out
}

func enumerateAll(_ ext: FileProviderExtension, _ id: NSFileProviderItemIdentifier) throws -> [NSFileProviderItem] {
    let e = try ext.enumerator(for: id, request: NSFileProviderRequest())
    var page = NSFileProviderPage(NSFileProviderPage.initialPageSortedByName as Data)
    var all: [NSFileProviderItem] = []
    var pages = 0
    while true {
        let o = EnumObs()
        e.enumerateItems(for: o, startingAt: page)
        o.sem.wait()
        if let err = o.error { throw err }
        all += o.items
        pages += 1
        guard let next = o.nextPage else { break }
        page = next
    }
    if pages > 1 { print("    (\(pages) pages)") }
    return all
}

let work = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory() + "fpext-\(UUID().uuidString)")
try? FileManager.default.removeItem(at: work)
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
let vaultURL = work.appendingPathComponent("vault")
let (vault, _) = try Vault.create(at: vaultURL, password: "testpass123", scryptN: 1024)
try vault.writeFile("/existing.txt", data: Data("existing".utf8))
try vault.createDirectory("/docs")
for i in 0..<250 { try vault.writeFile("/docs/n\(i).txt", data: Data("\(i)".utf8)) }
let raw = vault.masterkey.raw
var locked = false
let store = VaultStore(vault: try Vault.open(at: vaultURL, rawKey: raw),
                       index: ItemIndex(fileURL: work.appendingPathComponent("index.bin"), rawKey: raw, vaultId: vault.config.vaultId))
FileProviderExtension.testStoreProvider = { _ in
    if locked { throw NSFileProviderError(.notAuthenticated) }
    return store
}
let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(vault.config.vaultId), displayName: "Test")
let ext = FileProviderExtension(domain: domain)
let req = NSFileProviderRequest()

print("1. root + enumeration")
let (rootItem, rootErr): (NSFileProviderItem?, Error?) = wait { cb in ext.item(for: .rootContainer, request: req) { cb(($0, $1)) } }
check(rootErr == nil && rootItem?.itemIdentifier == .rootContainer && rootItem?.contentType == .folder, "root item")
check((rootItem?.capabilities ?? []).contains(.allowsAddingSubItems) && !(rootItem?.capabilities ?? []).contains(.allowsTrashing), "root caps (no trash)")
let rootKids = try enumerateAll(ext, .rootContainer)
check(Set(rootKids.map(\.filename)) == ["existing.txt", "docs"], "enumerate root")
let docs = rootKids.first { $0.filename == "docs" }!
check(docs.itemIdentifier.rawValue == (try vault.directoryId(of: "/docs")), "folder identifier = dirId")
let docKids = try enumerateAll(ext, docs.itemIdentifier)
check(docKids.count == 250, "paged enumeration of 250 items")
check(Set(docKids.map(\.itemIdentifier)).count == 250, "unique identifiers")
do { _ = try ext.enumerator(for: .trashContainer, request: req); check(false, "trash") } catch { check(true, "no trash enumerator") }

print("2. fetchContents")
let existing = rootKids.first { $0.filename == "existing.txt" }!
let (url, fetched, ferr): (URL?, NSFileProviderItem?, Error?) = wait { cb in
    ext.fetchContents(for: existing.itemIdentifier, version: nil, request: req) { cb(($0, $1, $2)) } }
check(try ferr == nil && String(contentsOf: url!, encoding: .utf8) == "existing", "fetch decrypts to temp file")
check(fetched?.documentSize??.intValue == 8, "fetched item size")
try? FileManager.default.removeItem(at: url!)

print("3. createItem")
let src = work.appendingPathComponent("upload.bin"); try Data("uploaded ✓".utf8).write(to: src)
let mdate = Date(timeIntervalSince1970: 1_500_000_000)
let (created, _, _, cerr): (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) = wait { cb in
    ext.createItem(basedOn: Template(parent: docs.itemIdentifier, name: "新文件 😀.txt", type: .plainText, mtime: mdate),
                   fields: [.contents, .contentModificationDate, .filename], contents: src, request: req) { cb(($0, $1, $2, $3)) } }
check(cerr == nil && created?.itemIdentifier.rawValue.hasPrefix("f.") == true, "create file")
check(created?.contentModificationDate??.timeIntervalSince1970 == 1_500_000_000, "create sets mtime")
check(String(data: try vault.readFile("/docs/新文件 😀.txt"), encoding: .utf8) == "uploaded ✓", "content in vault")
let (folder, _, _, ferr2): (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) = wait { cb in
    ext.createItem(basedOn: Template(parent: .rootContainer, name: "New Folder", type: .folder), fields: [.filename], contents: nil, request: req) { cb(($0, $1, $2, $3)) } }
check(ferr2 == nil && folder?.contentType == .folder, "create folder")
let (link, _, _, lerr): (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) = wait { cb in
    ext.createItem(basedOn: Template(parent: .rootContainer, name: "lnk", type: .symbolicLink, target: "docs/n1.txt"), fields: [.filename], contents: nil, request: req) { cb(($0, $1, $2, $3)) } }
check(try lerr == nil && link?.symlinkTargetPath == "docs/n1.txt" && vault.readSymlink("/lnk") == "docs/n1.txt", "create symlink")
let (_, _, _, dserr): (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) = wait { cb in
    ext.createItem(basedOn: Template(parent: .rootContainer, name: ".DS_Store", type: .data), fields: [.contents], contents: src, request: req) { cb(($0, $1, $2, $3)) } }
check((dserr as NSError?)?.code == NSFileProviderError.excludedFromSync.rawValue, ".DS_Store excluded from sync")
check((try vault.kind(of: "/.DS_Store")) == nil, ".DS_Store not in vault")
let (_, _, _, colErr): (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) = wait { cb in
    ext.createItem(basedOn: Template(parent: .rootContainer, name: "existing.txt", type: .plainText), fields: [.contents], contents: src, request: req) { cb(($0, $1, $2, $3)) } }
check((colErr as NSError?)?.code == NSFileProviderError.filenameCollision.rawValue, "collision error")
check(String(data: try vault.readFile("/existing.txt"), encoding: .utf8) == "existing", "collision did not overwrite")
let (re1, _, fetch1, reErr1): (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) = wait { cb in
    ext.createItem(basedOn: Template(parent: .rootContainer, name: "existing.txt", type: .plainText), fields: [.contents], contents: src,
                   options: .mayAlreadyExist, request: req) { cb(($0, $1, $2, $3)) } }
check(reErr1 == nil && fetch1 && re1?.itemIdentifier == existing.itemIdentifier, "mayAlreadyExist, different content → existing item, refetch")
check(String(data: try vault.readFile("/existing.txt"), encoding: .utf8) == "existing", "mayAlreadyExist did not overwrite")
check(try vault.contentsOfDirectory("/").contains { $0.name.hasPrefix("existing (conflict ") }, "incoming content saved as conflict copy")

print("4. modifyItem")
let moved = Template(created!.itemIdentifier.rawValue, parent: folder!.itemIdentifier, name: "renamed.txt", type: .plainText)
let (m1, _, _, merr): (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) = wait { cb in
    ext.modifyItem(moved, baseVersion: created!.itemVersion!, changedFields: [.filename, .parentItemIdentifier], contents: nil, request: req) { cb(($0, $1, $2, $3)) } }
check(merr == nil && m1?.itemIdentifier == created!.itemIdentifier && m1?.filename == "renamed.txt", "rename+move keeps identifier")
let src2 = work.appendingPathComponent("v2.bin"); try Data("version two".utf8).write(to: src2)
let (m2, _, refetch, merr2): (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) = wait { cb in
    ext.modifyItem(moved, baseVersion: m1!.itemVersion!, changedFields: [.contents], contents: src2, request: req) { cb(($0, $1, $2, $3)) } }
check(merr2 == nil && !refetch && m2?.documentSize??.intValue == 11, "replace content")
check(String(data: try vault.readFile("/New Folder/renamed.txt"), encoding: .utf8) == "version two", "new content in vault")
let ren = Template(folder!.itemIdentifier.rawValue, parent: .rootContainer, name: "改名的文件夹", type: .folder)
let (m3, _, _, merr3): (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) = wait { cb in
    ext.modifyItem(ren, baseVersion: folder!.itemVersion!, changedFields: [.filename], contents: nil, request: req) { cb(($0, $1, $2, $3)) } }
check(merr3 == nil && m3?.itemIdentifier == folder!.itemIdentifier, "rename folder keeps identifier")
let (again, _): (NSFileProviderItem?, Error?) = wait { cb in ext.item(for: created!.itemIdentifier, request: req) { cb(($0, $1)) } }
check(again?.parentItemIdentifier == folder!.itemIdentifier, "child resolvable after folder rename")

print("5. change enumeration (working set)")
let ws = try ext.enumerator(for: .workingSet, request: req)
let a0: NSFileProviderSyncAnchor? = { let s = DispatchSemaphore(value: 0); var a: NSFileProviderSyncAnchor?; ws.currentSyncAnchor! { a = $0; s.signal() }; s.wait(); return a }()
let other = try Vault.open(at: vaultURL, rawKey: raw)
try other.writeFile("/docs/from-cloud.txt", data: Data("cloud".utf8))
try other.remove("/docs/n0.txt")
Thread.sleep(forTimeInterval: 1.2)
let co = EnumObs()
ws.enumerateChanges!(for: co, from: a0!)
co.sem.wait()
check(co.error == nil && co.items.contains { $0.filename == "from-cloud.txt" }, "external add reported")
check(co.deleted.contains { $0 == docKids.first { $0.filename == "n0.txt" }!.itemIdentifier }, "external delete reported")
let co2 = EnumObs()
ws.enumerateChanges!(for: co2, from: NSFileProviderSyncAnchor(Data("bogus:0".utf8)))
co2.sem.wait()
check((co2.error as NSError?)?.code == NSFileProviderError.syncAnchorExpired.rawValue, "foreign anchor → syncAnchorExpired")
let wsAll = try enumerateAll(ext, .workingSet)
check(wsAll.count >= 250, "working set lists known items (\(wsAll.count))")

print("6. deleteItem")
let (_, delErrNR): (Void, Error?) = wait { cb in ext.deleteItem(identifier: docs.itemIdentifier, baseVersion: docs.itemVersion!, request: req) { cb(((), $0)) } }
check((delErrNR as NSError?)?.code == NSFileProviderError.directoryNotEmpty.rawValue, "non-recursive delete refused")
try other.writeFile("/docs/just-synced.txt", data: Data("new from another device".utf8))
let (_, delErrUnseen): (Void, Error?) = wait { cb in ext.deleteItem(identifier: docs.itemIdentifier, baseVersion: docs.itemVersion!, options: .recursive, request: req) { cb(((), $0)) } }
check((delErrUnseen as NSError?)?.code == NSFileProviderError.deletionRejected.rawValue, "recursive delete rejected while folder has unseen content")
check(try vault.kind(of: "/docs/just-synced.txt") == .file, "unseen file kept")
_ = store.rescan()
let (_, delErr): (Void, Error?) = wait { cb in ext.deleteItem(identifier: docs.itemIdentifier, baseVersion: docs.itemVersion!, options: .recursive, request: req) { cb(((), $0)) } }
check(try delErr == nil && vault.kind(of: "/docs") == nil, "recursive delete")

print("7. locked")
locked = true
let (li, lerr2): (NSFileProviderItem?, Error?) = wait { cb in ext.item(for: .rootContainer, request: req) { cb(($0, $1)) } }
check(li == nil && (lerr2 as NSError?)?.code == NSFileProviderError.notAuthenticated.rawValue, "locked → notAuthenticated")
let (lu, _, lferr): (URL?, NSFileProviderItem?, Error?) = wait { cb in
    ext.fetchContents(for: existing.itemIdentifier, version: nil, request: req) { cb(($0, $1, $2)) } }
check(lu == nil && (lferr as NSError?)?.code == NSFileProviderError.notAuthenticated.rawValue, "locked fetch → notAuthenticated")

print(failures == 0 ? "ALL OK — vault at \(vaultURL.path)" : "\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
