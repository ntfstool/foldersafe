import Foundation
import CryptoKit

/// 目录 ID → 存储路径，文件名加解密，长文件名缩短（规范 §6.2–§6.4）。
struct NameCipher {
    let sivKey: Data

    init(_ key: Masterkey) { sivKey = key.sivKey }

    /// 目录存储路径 d/XX/YYYYYYYYYYYYYYYYYYYYYYYYYYYYYY（相对 vault 根）。根目录的 ID 是空字符串。
    func dirPath(_ dirId: String) -> String {
        let siv = AESSIV.encrypt(key: sivKey, plaintext: Data(dirId.utf8))
        let h = Encoding.base32(Data(Insecure.SHA1.hash(data: siv)))
        return "d/\(h.prefix(2))/\(h.dropFirst(2))"
    }

    /// 明文名 → 密文名（含 .c9r 后缀）。名字先转 NFC。
    func encrypt(_ name: String, parentDirId: String) -> String {
        let n = Data(name.precomposedStringWithCanonicalMapping.utf8)
        return Encoding.base64url(AESSIV.encrypt(key: sivKey, plaintext: n, associatedData: [Data(parentDirId.utf8)])) + ".c9r"
    }

    /// 密文名（含 .c9r）→ 明文名；不是合法密文就抛错。
    func decrypt(_ encName: String, parentDirId: String) throws -> String {
        guard encName.hasSuffix(".c9r"), let c = Encoding.base64urlDecode(encName.dropLast(4)),
              let p = try? AESSIV.decrypt(key: sivKey, ciphertext: c, associatedData: [Data(parentDirId.utf8)]),
              let s = String(data: p, encoding: .utf8)
        else { throw VaultError.corrupted("name \(encName)") }
        return s
    }

    /// 超过阈值的密文名改存成 <base64url(SHA-1(密文名))>.c9s 目录。
    static func shortened(_ encName: String) -> String {
        Encoding.base64url(Data(Insecure.SHA1.hash(data: Data(encName.utf8)))) + ".c9s"
    }
}
