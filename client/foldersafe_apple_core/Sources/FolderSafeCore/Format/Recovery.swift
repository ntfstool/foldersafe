import Foundation
import CryptoKit

/// 12 个词的找回短语（规范 §7.2）：BIP-39 英文词表编码的 128 位熵 + 4 位校验，不做 BIP-39 种子推导。
public struct RecoveryPhrase: Equatable {
    public let entropy: Data            // 16 字节

    public static func generate(_ random: RandomSource) -> RecoveryPhrase {
        RecoveryPhrase(entropy: random.bytes(16))
    }

    init(entropy: Data) {
        precondition(entropy.count == 16)
        self.entropy = entropy
    }

    public var words: [String] {
        var bits = entropy.flatMap { byte in (0..<8).reversed().map { (byte >> $0) & 1 } }
        let check = Array(SHA256.hash(data: entropy))[0]
        bits += (0..<4).reversed().map { (check >> ($0 + 4)) & 1 }
        return stride(from: 0, to: bits.count, by: 11).map { i in
            BIP39.words[bits[i..<i + 11].reduce(0) { $0 << 1 | Int($1) }]
        }
    }

    public var phrase: String { words.joined(separator: " ") }

    /// 解析用户输入：忽略大小写和多余空白；每个词可只输前 4 个字母（BIP-39 词表前 4 字母唯一）。
    public init(phrase: String) throws {
        let input = phrase.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "，" }).map(String.init)
        guard input.count == 12 else { throw VaultError.invalidRecoveryPhrase }
        var bits: [UInt8] = []
        for w in input {
            guard let idx = RecoveryPhrase.index(of: w) else { throw VaultError.invalidRecoveryPhrase }
            bits += (0..<11).reversed().map { UInt8((idx >> $0) & 1) }
        }
        let ent = stride(from: 0, to: 128, by: 8).map { i in bits[i..<i + 8].reduce(0) { $0 << 1 | $1 } }
        let p = RecoveryPhrase(entropy: Data(ent))
        guard p.words == input.map({ RecoveryPhrase.index(of: $0).map { BIP39.words[$0] } ?? "" }) else {
            throw VaultError.invalidRecoveryPhrase       // 校验位不对
        }
        self = p
    }

    static func index(of word: String) -> Int? {
        if let i = BIP39.words.firstIndex(of: word) { return i }
        guard word.count >= 4 else { return nil }
        let hits = BIP39.words.indices.filter { BIP39.words[$0].hasPrefix(word) }
        return hits.count == 1 ? hits[0] : nil
    }
}

/// foldersafe/recovery.json（规范 §7.3）：用找回短语派生的密钥包装 rawKey。
struct RecoveryFile {
    static let path = "foldersafe/recovery.json"
    static let info = "FolderSafe recovery v1"     // 永远不能改，否则旧短语失效

    var salt: Data
    var nonce: Data
    var wrappedKey: Data            // AES-GCM 密文 || tag

    static func key(_ phrase: RecoveryPhrase, salt: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: phrase.entropy), salt: salt,
                               info: Data(info.utf8), outputByteCount: 32)
    }

    static func make(_ key: Masterkey, phrase: RecoveryPhrase, vaultId: String, random: RandomSource) throws -> RecoveryFile {
        let salt = random.bytes(32), nonce = random.bytes(12)
        let box = try AES.GCM.seal(key.raw, using: self.key(phrase, salt: salt), nonce: AES.GCM.Nonce(data: nonce),
                                   authenticating: Data(vaultId.utf8))
        return RecoveryFile(salt: salt, nonce: nonce, wrappedKey: box.ciphertext + box.tag)
    }

    func unlock(_ phrase: RecoveryPhrase, vaultId: String) throws -> Masterkey {
        guard wrappedKey.count == 64 + 16 else { throw VaultError.corrupted(RecoveryFile.path) }
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: wrappedKey.prefix(64), tag: wrappedKey.suffix(16))
            return try Masterkey(raw: try AES.GCM.open(box, using: RecoveryFile.key(phrase, salt: salt), authenticating: Data(vaultId.utf8)))
        } catch { throw VaultError.wrongRecoveryPhrase }
    }

    func serialized() -> Data {
        Data("""
        {
          "version": 1,
          "salt": "\(salt.base64EncodedString())",
          "nonce": "\(nonce.base64EncodedString())",
          "wrappedKey": "\(wrappedKey.base64EncodedString())"
        }
        """.utf8)
    }

    init(salt: Data, nonce: Data, wrappedKey: Data) {
        self.salt = salt
        self.nonce = nonce
        self.wrappedKey = wrappedKey
    }

    init(data: Data) throws {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let salt = (o["salt"] as? String).flatMap({ Data(base64Encoded: $0) }),
              let nonce = (o["nonce"] as? String).flatMap({ Data(base64Encoded: $0) }), nonce.count == 12,
              let wk = (o["wrappedKey"] as? String).flatMap({ Data(base64Encoded: $0) })
        else { throw VaultError.corrupted(RecoveryFile.path) }
        guard (o["version"] as? Int) == 1 else { throw VaultError.unsupported("recovery.json version") }
        self.init(salt: salt, nonce: nonce, wrappedKey: wk)
    }
}

/// foldersafe/extensions.json（规范 §7.1）。
struct ExtensionsFile {
    static let path = "foldersafe/extensions.json"
    /// 本客户端认识的扩展及版本。
    static let supported: [String: Int] = ["recovery": 1]

    var extensions: [String: Int]
    var requires: [String]

    static let current = ExtensionsFile(extensions: ["recovery": 1], requires: [])

    func serialized() -> Data {
        let ext = extensions.keys.sorted().map { "\"\($0)\": \(extensions[$0]!)" }.joined(separator: ", ")
        let req = requires.map { "\"\($0)\"" }.joined(separator: ", ")
        return Data(#"{"foldersafe": 1, "extensions": {\#(ext)}, "requires": [\#(req)]}"#.utf8 + [0x0a])
    }

    init(extensions: [String: Int], requires: [String]) {
        self.extensions = extensions
        self.requires = requires
    }

    init(data: Data) throws {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VaultError.corrupted(ExtensionsFile.path)
        }
        extensions = o["extensions"] as? [String: Int] ?? [:]
        requires = o["requires"] as? [String] ?? []
    }

    /// requires 里有本客户端不认识的扩展 → 只能只读打开。
    var allowsWriting: Bool { requires.allSatisfy { ExtensionsFile.supported[$0] != nil } }
}
