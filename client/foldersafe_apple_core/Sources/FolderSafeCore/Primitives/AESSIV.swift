import Foundation
import CommonCrypto

/// 单个 AES 分组加密（ECB，无填充）。CMAC 和 CTR 都建立在它上面；只用于文件名和目录 ID 这类短数据。
final class AESBlock {
    private var ref: CCCryptorRef?

    init(key: Data) {
        precondition([16, 24, 32].contains(key.count), "AES key must be 128/192/256 bits")
        let status = key.withUnsafeBytes {
            CCCryptorCreate(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                            $0.baseAddress, key.count, nil, &ref)
        }
        precondition(status == kCCSuccess, "CCCryptorCreate failed: \(status)")
    }

    deinit { CCCryptorRelease(ref) }

    func encrypt(_ block: [UInt8]) -> [UInt8] {
        precondition(block.count == 16)
        var out = [UInt8](repeating: 0, count: 16)
        var moved = 0
        let status = CCCryptorUpdate(ref, block, 16, &out, 16, &moved)
        precondition(status == kCCSuccess && moved == 16, "AES block failed: \(status)")
        return out
    }
}

/// AES-CMAC（RFC 4493）。
struct CMAC {
    private let aes: AESBlock
    private let k1: [UInt8], k2: [UInt8]

    init(key: Data) {
        aes = AESBlock(key: key)
        let l = aes.encrypt([UInt8](repeating: 0, count: 16))
        k1 = CMAC.dbl(l)
        k2 = CMAC.dbl(k1)
    }

    /// GF(2^128) 上乘以 x（左移一位，溢出时异或 0x87）。
    static func dbl(_ b: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 16)
        var carry: UInt8 = 0
        for i in stride(from: 15, through: 0, by: -1) {
            out[i] = (b[i] << 1) | carry
            carry = b[i] >> 7
        }
        if carry == 1 { out[15] ^= 0x87 }
        return out
    }

    func mac(_ m: [UInt8]) -> [UInt8] {
        let n = max(1, (m.count + 15) / 16)
        let complete = !m.isEmpty && m.count % 16 == 0
        var x = [UInt8](repeating: 0, count: 16)
        for i in 0..<n - 1 {
            for j in 0..<16 { x[j] ^= m[i * 16 + j] }
            x = aes.encrypt(x)
        }
        var last = [UInt8](repeating: 0, count: 16)
        let tail = m[((n - 1) * 16)...]
        for (j, byte) in tail.enumerated() { last[j] = byte }
        if complete {
            for j in 0..<16 { last[j] ^= k1[j] }
        } else {
            last[tail.count] = 0x80
            for j in 0..<16 { last[j] ^= k2[j] }
        }
        for j in 0..<16 { x[j] ^= last[j] }
        return aes.encrypt(x)
    }
}

/// AES-SIV（RFC 5297），确定性认证加密：同样的密钥、关联数据和明文永远得到同样的密文。
/// 密钥是 K1(CMAC) || K2(CTR) 两半；v1 格式里 K1 = macKey、K2 = encKey（规范 §3、§11）。
public enum AESSIV {
    public enum Failure: Error { case authenticationFailed, tooShort }

    public static func encrypt(key: Data, plaintext: Data, associatedData: [Data] = []) -> Data {
        let (macKey, ctrKey) = split(key)
        let v = s2v(CMAC(key: macKey), associatedData.map { [UInt8]($0) } + [[UInt8](plaintext)])
        return Data(v + ctr(key: ctrKey, iv: v, [UInt8](plaintext)))
    }

    public static func decrypt(key: Data, ciphertext: Data, associatedData: [Data] = []) throws -> Data {
        guard ciphertext.count >= 16 else { throw Failure.tooShort }
        let (macKey, ctrKey) = split(key)
        let bytes = [UInt8](ciphertext)
        let v = Array(bytes[0..<16])
        let p = ctr(key: ctrKey, iv: v, Array(bytes[16...]))
        let expected = s2v(CMAC(key: macKey), associatedData.map { [UInt8]($0) } + [p])
        // 常量时间比较
        guard zip(expected, v).reduce(0, { $0 | ($1.0 ^ $1.1) }) == 0 else { throw Failure.authenticationFailed }
        return Data(p)
    }

    private static func split(_ key: Data) -> (Data, Data) {
        precondition([32, 48, 64].contains(key.count), "AES-SIV key must be 256/384/512 bits")
        let half = key.count / 2
        return (key.prefix(half), key.suffix(half))
    }

    /// S2V：最后一个分量是明文，前面是关联数据。
    private static func s2v(_ cmac: CMAC, _ strings: [[UInt8]]) -> [UInt8] {
        var d = cmac.mac([UInt8](repeating: 0, count: 16))
        for s in strings.dropLast() {
            let m = cmac.mac(s)
            d = CMAC.dbl(d)
            for j in 0..<16 { d[j] ^= m[j] }
        }
        let last = strings.last!
        var t: [UInt8]
        if last.count >= 16 {
            t = last
            let off = last.count - 16
            for j in 0..<16 { t[off + j] ^= d[j] }
        } else {
            t = CMAC.dbl(d)
            for (j, byte) in last.enumerated() { t[j] ^= byte }
            t[last.count] ^= 0x80
        }
        return cmac.mac(t)
    }

    private static func ctr(key: Data, iv: [UInt8], _ input: [UInt8]) -> [UInt8] {
        var counter = iv
        counter[8] &= 0x7f
        counter[12] &= 0x7f
        let aes = AESBlock(key: key)
        var out = [UInt8](repeating: 0, count: input.count)
        var i = 0
        while i < input.count {
            let ks = aes.encrypt(counter)
            for j in 0..<min(16, input.count - i) { out[i + j] = input[i + j] ^ ks[j] }
            i += 16
            for k in stride(from: 15, through: 0, by: -1) {  // 128 位大端计数器 +1
                counter[k] &+= 1
                if counter[k] != 0 { break }
            }
        }
        return out
    }
}
