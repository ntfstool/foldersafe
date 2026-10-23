// fsvault：FolderSafeCore 的命令行，主要给互通测试（interop/）和测试向量用。
// 用法：
//   fsvault create  --vault DIR --password PW --source SRC [--phrase-out FILE] [--scrypt-n N]
//   fsvault dump    --vault DIR (--password PW | --phrase "12 words")      明文目录树 JSON（路径 NFC，按路径排序）
//   fsvault write   --vault DIR --password PW --source SRC                 把 SRC 拷进已有 vault（覆盖同名文件）
//   fsvault srcdump --source SRC                                           普通目录的同格式 JSON，用来对照
//   fsvault enable-recovery --vault DIR --password PW                      给 vault 加 foldersafe/ 找回短语，打印短语
//   fsvault vectors [--out FILE]                                           生成测试向量
//   fsvault check-vectors FILE                                             用本实现复核测试向量
//   fsvault edit    --vault DIR --password PW --path P --mirror FILE [--seed N] [--ops K]
//                   用文件句柄对 P 做一串随机写入 / 截断，同样的操作作用在明文 FILE 上（手工验证随机读写的互通）
// 密码走命令行参数只适合测试。
import Foundation
import CryptoKit
import FolderSafeCore

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("fsvault: \(msg)\n".utf8))
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
guard !args.isEmpty else { fail("missing command") }
let command = args.removeFirst()
var opts: [String: String] = [:], positional: [String] = []
while !args.isEmpty {
    let a = args.removeFirst()
    if a.hasPrefix("--") {
        guard !args.isEmpty else { fail("missing value for \(a)") }
        opts[String(a.dropFirst(2))] = args.removeFirst()
    } else { positional.append(a) }
}
func opt(_ k: String) -> String {
    guard let v = opts[k] else { fail("missing --\(k)") }
    return v
}
func url(_ k: String) -> URL { URL(fileURLWithPath: opt(k)) }

let fm = FileManager.default

/// 不跟随符号链接地遍历普通目录：(相对路径, 类型)。
func walk(_ root: URL, _ rel: String = "") throws -> [(String, FileAttributeType)] {
    var out: [(String, FileAttributeType)] = []
    for name in try fm.contentsOfDirectory(atPath: root.appendingPathComponent(rel).path).sorted() where name != ".DS_Store" {
        let r = rel.isEmpty ? name : rel + "/" + name
        let type = try fm.attributesOfItem(atPath: root.appendingPathComponent(r).path)[.type] as! FileAttributeType
        out.append((r, type))
        if type == .typeDirectory { out += try walk(root, r) }
    }
    return out
}

func entry(_ path: String, _ type: String, _ extra: [String: Any] = [:]) -> [String: Any] {
    ["path": "/" + path.precomposedStringWithCanonicalMapping, "type": type].merging(extra) { a, _ in a }
}

func fileEntry(_ path: String, _ data: Data) -> [String: Any] {
    entry(path, "file", ["size": data.count, "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()])
}

func printEntries(_ entries: [[String: Any]]) throws {
    let sorted = entries.sorted { ($0["path"] as! String) < ($1["path"] as! String) }
    let d = try JSONSerialization.data(withJSONObject: ["entries": sorted], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    FileHandle.standardOutput.write(d + Data([0x0a]))
}

func copy(_ src: URL, into vault: Vault) throws {
    for (rel, type) in try walk(src) {
        let p = "/" + rel, u = src.appendingPathComponent(rel)
        switch type {
        case .typeDirectory: if try vault.kind(of: p) == nil { try vault.createDirectory(p) }
        case .typeSymbolicLink:
            if try vault.kind(of: p) == .symlink { try vault.remove(p) }      // 与 cp 一致：覆盖同名链接
            try vault.createSymlink(p, target: try fm.destinationOfSymbolicLink(atPath: u.path))
        case .typeRegular: try vault.importFile(p, from: u)
        default: break
        }
    }
}

func dump(_ vault: Vault, _ dir: String = "/") throws -> [[String: Any]] {
    var out: [[String: Any]] = []
    for e in try vault.contentsOfDirectory(dir) {
        let p = (dir == "/" ? "" : dir) + "/" + e.name
        switch e.kind {
        case .directory: out.append(entry(String(p.dropFirst()), "dir")); out += try dump(vault, p)
        case .file:   // 用句柄分段读，顺带验证随机读路径
            let f = try vault.openFile(p)
            defer { try? f.close() }
            var hash = SHA256(), size = 0
            while true {
                let piece = try f.read(at: size, count: 1 << 20)
                if piece.isEmpty { break }
                hash.update(data: piece)
                size += piece.count
            }
            out.append(entry(String(p.dropFirst()), "file", ["size": size, "sha256": hash.finalize().map { String(format: "%02x", $0) }.joined()]))
        case .symlink: out.append(entry(String(p.dropFirst()), "symlink", ["target": try vault.readSymlink(p)]))
        }
    }
    return out
}

do {
    switch command {
    case "create":
        let (vault, phrase) = try Vault.create(at: url("vault"), password: opt("password"),
                                               scryptN: Int(opts["scrypt-n"] ?? "32768") ?? 32768)
        try copy(url("source"), into: vault)
        if let f = opts["phrase-out"] { try Data((phrase.phrase + "\n").utf8).write(to: URL(fileURLWithPath: f)) }
    case "dump":
        let vault = try opts["phrase"].map { try Vault.open(at: url("vault"), recoveryPhrase: $0) }
            ?? Vault.open(at: url("vault"), password: opt("password"))
        try printEntries(try dump(vault))
    case "write":
        try copy(url("source"), into: try Vault.open(at: url("vault"), password: opt("password")))
    case "srcdump":
        let src = url("source")
        try printEntries(try walk(src).compactMap { rel, type in
            switch type {
            case .typeDirectory: return entry(rel, "dir")
            case .typeSymbolicLink: return entry(rel, "symlink", ["target": try fm.destinationOfSymbolicLink(atPath: src.appendingPathComponent(rel).path)])
            case .typeRegular: return fileEntry(rel, try Data(contentsOf: src.appendingPathComponent(rel)))
            default: return nil
            }
        })
    case "enable-recovery":
        print(try Vault.open(at: url("vault"), password: opt("password")).enableRecovery().phrase)
    case "vectors":
        let d = try TestVectors.generate()
        try TestVectors.verify(d)
        if let out = opts["out"] { try d.write(to: URL(fileURLWithPath: out)) } else { FileHandle.standardOutput.write(d) }
    case "edit":
        let vault = try Vault.open(at: url("vault"), password: opt("password"))
        var mirror = (try? Data(contentsOf: url("mirror"))) ?? Data()
        let f = try vault.kind(of: opt("path")) == nil ? try vault.createFile(opt("path")) : try vault.openFile(opt("path"), writable: true)
        var state = UInt64(opts["seed"] ?? "1") ?? 1
        func next(_ n: Int) -> Int {                       // splitmix64
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return Int((z ^ (z >> 31)) % UInt64(n))
        }
        for _ in 0..<(Int(opts["ops"] ?? "40") ?? 40) {
            if next(4) == 0 {
                let n = next(mirror.count + 70000)
                try f.truncate(to: n)
                if n < mirror.count { mirror = mirror.prefix(n) } else { mirror.append(Data(count: n - mirror.count)) }
            } else {
                let off = next(mirror.count + 40000), data = Data((0..<(1 + next(70000))).map { _ in UInt8(next(256)) })
                try f.write(data, at: off)
                if off > mirror.count { mirror.append(Data(count: off - mirror.count)) }
                let end = min(mirror.count, off + data.count)
                mirror.replaceSubrange(off..<end, with: data)
            }
        }
        try f.close()
        try mirror.write(to: url("mirror"))
        print(mirror.count)
    case "check-vectors":
        guard let f = positional.first else { fail("missing file") }
        try TestVectors.verify(try Data(contentsOf: URL(fileURLWithPath: f)))
        print("OK")
    default:
        fail("unknown command \(command)")
    }
} catch {
    fail("\(error)")
}
