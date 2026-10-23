import Foundation
import CryptoKit

public enum VaultError: Error, Equatable {
    case wrongPassword
    case wrongRecoveryPhrase
    case invalidRecoveryPhrase
    case corrupted(String)          // 文件结构不对、认证失败
    case unsupported(String)        // 不支持的格式版本 / 加密组合 / 密钥来源
    case readOnly                   // extensions.json 要求了本客户端不认识的扩展，只能读
    case notFound(String)
    case alreadyExists(String)
    case notADirectory(String)
    case invalidName(String)
    case invalidPassword(String)
    case invalidArgument(String)    // 负的偏移 / 大小之类
    case closed                     // 句柄已关闭
    case io(String)                 // 底层文件系统出错（磁盘满、权限等）

    /// 对应的 POSIX 错误码，给 FSKit / File Provider 层转换用。
    public var posixCode: Int32 {
        switch self {
        case .notFound: return ENOENT
        case .alreadyExists: return EEXIST
        case .notADirectory: return ENOTDIR
        case .invalidName, .invalidArgument, .invalidPassword: return EINVAL
        case .readOnly: return EROFS
        case .closed: return EBADF
        case .wrongPassword, .wrongRecoveryPhrase, .invalidRecoveryPhrase: return EACCES
        case .unsupported: return ENOTSUP
        case .corrupted, .io: return EIO
        }
    }
}

/// vault 的两把主密钥（规范 §5）：建库时随机生成，终生不变。改密码、换助记词只是重新包装它们。
public struct Masterkey: Equatable, Sendable {
    public let encKey: Data   // 32 字节，文件内容（GCM）与 AES-SIV 的 CTR 半
    public let macKey: Data   // 32 字节，AES-SIV 的 CMAC 半、vault.cryptomator 签名

    public init(encKey: Data, macKey: Data) {
        precondition(encKey.count == 32 && macKey.count == 32)
        self.encKey = encKey
        self.macKey = macKey
    }

    public init(raw: Data) throws {
        guard raw.count == 64 else { throw VaultError.corrupted("masterkey length") }
        self.init(encKey: raw.prefix(32), macKey: raw.suffix(32))
    }

    public static func generate(_ random: RandomSource) -> Masterkey {
        Masterkey(encKey: random.bytes(32), macKey: random.bytes(32))
    }

    /// rawKey = encKey || macKey（64 字节）：签 vault.cryptomator、助记词和设备钥匙包装的都是它。
    public var raw: Data { encKey + macKey }

    /// AES-SIV 的 512 位密钥：K1(CMAC) = macKey，K2(CTR) = encKey（规范 §3、§11 第 1 条）。
    var sivKey: Data { macKey + encKey }
}

/// masterkey.cryptomator（规范 §5.2）：用密码派生的 KEK 包装两把主密钥。
struct MasterkeyFile {
    static let name = "masterkey.cryptomator"
    static let version = 999
    static let defaultScryptN = 32768
    static let defaultScryptR = 8

    var scryptSalt: Data
    var scryptCostParam: Int
    var scryptBlockSize: Int
    var primaryMasterKey: Data
    var hmacMasterKey: Data
    var versionMac: Data
    var fileVersion = MasterkeyFile.version     // Cryptomator 不限定具体值；versionMac 按文件里的值算

    static func kek(password: String, salt: Data, n: Int, r: Int) throws -> SymmetricKey {
        let pw = Data(password.precomposedStringWithCanonicalMapping.utf8)
        return SymmetricKey(data: try Scrypt.derive(password: pw, salt: salt, n: n, r: r, p: 1, length: 32))
    }

    static func versionMac(_ key: Masterkey, version: Int = version) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Encoding.uint32BE(UInt32(truncatingIfNeeded: version)), using: SymmetricKey(data: key.macKey)))
    }

    static func make(_ key: Masterkey, password: String, random: RandomSource,
                     n: Int = defaultScryptN, r: Int = defaultScryptR) throws -> MasterkeyFile {
        let salt = random.bytes(32)
        let kek = try kek(password: password, salt: salt, n: n, r: r)
        return MasterkeyFile(scryptSalt: salt, scryptCostParam: n, scryptBlockSize: r,
                             primaryMasterKey: try AES.KeyWrap.wrap(SymmetricKey(data: key.encKey), using: kek),
                             hmacMasterKey: try AES.KeyWrap.wrap(SymmetricKey(data: key.macKey), using: kek),
                             versionMac: versionMac(key))
    }

    func unlock(password: String) throws -> Masterkey {
        let kek = try MasterkeyFile.kek(password: password, salt: scryptSalt, n: scryptCostParam, r: scryptBlockSize)
        let enc: SymmetricKey, mac: SymmetricKey
        do {
            enc = try AES.KeyWrap.unwrap(primaryMasterKey, using: kek)
            mac = try AES.KeyWrap.unwrap(hmacMasterKey, using: kek)
        } catch { throw VaultError.wrongPassword }
        let key = Masterkey(encKey: enc.withUnsafeBytes { Data($0) }, macKey: mac.withUnsafeBytes { Data($0) })
        guard MasterkeyFile.versionMac(key, version: fileVersion) == versionMac else { throw VaultError.corrupted("masterkey versionMac") }
        return key
    }

    /// 固定键顺序的 JSON，测试向量依赖它逐字节稳定。
    func serialized() -> Data {
        let s = """
        {
          "version": \(MasterkeyFile.version),
          "scryptSalt": "\(scryptSalt.base64EncodedString())",
          "scryptCostParam": \(scryptCostParam),
          "scryptBlockSize": \(scryptBlockSize),
          "primaryMasterKey": "\(primaryMasterKey.base64EncodedString())",
          "hmacMasterKey": "\(hmacMasterKey.base64EncodedString())",
          "versionMac": "\(versionMac.base64EncodedString())"
        }
        """
        return Data(s.utf8)
    }

    init(scryptSalt: Data, scryptCostParam: Int, scryptBlockSize: Int, primaryMasterKey: Data, hmacMasterKey: Data, versionMac: Data) {
        self.scryptSalt = scryptSalt
        self.scryptCostParam = scryptCostParam
        self.scryptBlockSize = scryptBlockSize
        self.primaryMasterKey = primaryMasterKey
        self.hmacMasterKey = hmacMasterKey
        self.versionMac = versionMac
    }

    init(data: Data) throws {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let salt = (o["scryptSalt"] as? String).flatMap({ Data(base64Encoded: $0) }),
              let n = o["scryptCostParam"] as? Int, let r = o["scryptBlockSize"] as? Int,
              let pmk = (o["primaryMasterKey"] as? String).flatMap({ Data(base64Encoded: $0) }),
              let hmk = (o["hmacMasterKey"] as? String).flatMap({ Data(base64Encoded: $0) }),
              let vmac = (o["versionMac"] as? String).flatMap({ Data(base64Encoded: $0) })
        else { throw VaultError.corrupted("masterkey.cryptomator") }
        guard let version = o["version"] as? Int, version != 0 else { throw VaultError.unsupported("masterkey version") }
        self.init(scryptSalt: salt, scryptCostParam: n, scryptBlockSize: r, primaryMasterKey: pmk, hmacMasterKey: hmk, versionMac: vmac)
        fileVersion = version
    }
}
