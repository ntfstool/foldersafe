import Foundation
import CryptoKit

/// 规范 §3 用到的编码。
enum Encoding {
    /// RFC 4648 §6 Base32，大写；v1 只用来编码 20 字节的 SHA-1（正好 32 个字符，没有填充）。
    static func base32(_ data: Data) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var out = "", buffer = 0, bits = 0
        for byte in data {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[(buffer >> (bits - 5)) & 31])
                bits -= 5
            }
        }
        if bits > 0 { out.append(alphabet[(buffer << (5 - bits)) & 31]) }
        while out.count % 8 != 0 { out.append("=") }
        return out
    }

    /// RFC 4648 §5 base64url，带 `=` 填充（与 Cryptomator 一致，规范 §11 第 2 条）。
    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }

    /// 解码时有无填充都接受。
    static func base64urlDecode(_ s: Substring) -> Data? {
        guard !s.contains("+"), !s.contains("/") else { return nil }
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t.append("=") }
        return Data(base64Encoded: t)
    }

    static func hex(_ data: some Sequence<UInt8>) -> String { data.map { String(format: "%02x", $0) }.joined() }

    static func unhex(_ s: String) -> Data? {
        guard s.count % 2 == 0 else { return nil }
        var out = Data(capacity: s.count / 2)
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            guard let b = UInt8(s[i..<j], radix: 16) else { return nil }
            out.append(b)
            i = j
        }
        return out
    }

    static func uint64BE(_ v: UInt64) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }
    static func uint32BE(_ v: UInt32) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }
}

/// 所有随机数的来源。正常用系统 CSPRNG；生成公开测试向量时换成可复现的确定性来源。
public protocol RandomSource: AnyObject {
    func bytes(_ count: Int) -> Data
}

public final class SystemRandom: RandomSource {
    public static let shared = SystemRandom()
    public func bytes(_ count: Int) -> Data {
        var d = Data(count: count)
        let status = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return d
    }
}

/// 确定性"随机"：SHA-256(seed || 计数器) 拼接。只用于测试向量，绝不能用于真实 vault。
public final class DeterministicRandom: RandomSource {
    private let seed: Data
    private var counter: UInt64 = 0
    private let lock = NSLock()
    public init(seed: String) { self.seed = Data(seed.utf8) }
    public func bytes(_ count: Int) -> Data {
        lock.lock(); defer { lock.unlock() }
        var out = Data()
        while out.count < count {
            out += SHA256.hash(data: seed + Encoding.uint64BE(counter))
            counter += 1
        }
        return out.prefix(count)
    }
}
