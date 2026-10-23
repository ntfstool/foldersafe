import Foundation
import CommonCrypto

/// scrypt（RFC 7914）。系统没有现成实现，这里按 RFC 写，用 RFC 测试向量校验。
/// N=32768、r=8 时占 32 MiB 内存。
public enum Scrypt {
    public enum Failure: Error { case invalidParameters }

    public static func derive(password: Data, salt: Data, n: Int, r: Int, p: Int, length: Int) throws -> Data {
        // 参数来自 vault 文件（可能被篡改），所以和 cryptolib 2.3+ 一样限制 N ≤ 2^20、r ≤ 64、内存 ≤ 1 GiB
        guard n > 1, n <= 1 << 20, n & (n - 1) == 0, r > 0, r <= 64, p > 0, p <= 16, length > 0,
              r >= 4 || n < (1 << (16 * r)), 128 * r * n <= 1 << 30 else { throw Failure.invalidParameters }
        let blockLen = 128 * r
        var b = pbkdf2(password: password, salt: salt, length: p * blockLen)
        let words = blockLen / 4
        var x = [UInt32](repeating: 0, count: words)
        var y = [UInt32](repeating: 0, count: words)
        var v = [UInt32](repeating: 0, count: words * n)
        for i in 0..<p {
            b.withUnsafeMutableBytes { raw in
                let bytes = raw.baseAddress!.advanced(by: i * blockLen).assumingMemoryBound(to: UInt8.self)
                for k in 0..<words { x[k] = loadLE(bytes + 4 * k) }
                romix(&x, &y, &v, n: n, r: r)
                for k in 0..<words { storeLE(x[k], bytes + 4 * k) }
            }
        }
        return pbkdf2(password: password, salt: b, length: length)
    }

    static func pbkdf2(password: Data, salt: Data, length: Int) -> Data {
        var out = Data(count: length)
        let status = out.withUnsafeMutableBytes { o in
            password.withUnsafeBytes { pw in
                salt.withUnsafeBytes { s in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         pw.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                                         s.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 1,
                                         o.baseAddress!.assumingMemoryBound(to: UInt8.self), length)
                }
            }
        }
        precondition(status == kCCSuccess, "PBKDF2 failed: \(status)")
        return out
    }

    private static func romix(_ x: inout [UInt32], _ y: inout [UInt32], _ v: inout [UInt32], n: Int, r: Int) {
        let words = 32 * r
        x.withUnsafeMutableBufferPointer { xp in
            y.withUnsafeMutableBufferPointer { yp in
                v.withUnsafeMutableBufferPointer { vp in
                    let xb = xp.baseAddress!, yb = yp.baseAddress!, vb = vp.baseAddress!
                    for i in 0..<n {
                        (vb + i * words).update(from: xb, count: words)
                        blockMix(xb, yb, r: r)
                    }
                    for _ in 0..<n {
                        let j = Int(xb[(2 * r - 1) * 16]) & (n - 1)
                        let vj = vb + j * words
                        for k in 0..<words { xb[k] ^= vj[k] }
                        blockMix(xb, yb, r: r)
                    }
                }
            }
        }
    }

    /// BlockMix_salsa20/8：结果写回 b，y 是临时空间。
    private static func blockMix(_ b: UnsafeMutablePointer<UInt32>, _ y: UnsafeMutablePointer<UInt32>, r: Int) {
        var t = [UInt32](repeating: 0, count: 16)
        t.withUnsafeMutableBufferPointer { tp in
            let tb = tp.baseAddress!
            tb.update(from: b + (2 * r - 1) * 16, count: 16)
            for i in 0..<(2 * r) {
                for k in 0..<16 { tb[k] ^= b[i * 16 + k] }
                salsa208(tb)
                // 偶数块放前半，奇数块放后半
                let dst = (i % 2 == 0 ? i / 2 : r + i / 2) * 16
                (y + dst).update(from: tb, count: 16)
            }
        }
        b.update(from: y, count: 32 * r)
    }

    @inline(__always) private static func rotl(_ a: UInt32, _ n: UInt32) -> UInt32 { (a << n) | (a >> (32 - n)) }

    private static func salsa208(_ b: UnsafeMutablePointer<UInt32>) {
        var x0 = b[0], x1 = b[1], x2 = b[2], x3 = b[3], x4 = b[4], x5 = b[5], x6 = b[6], x7 = b[7]
        var x8 = b[8], x9 = b[9], x10 = b[10], x11 = b[11], x12 = b[12], x13 = b[13], x14 = b[14], x15 = b[15]
        for _ in 0..<4 {
            x4 ^= rotl(x0 &+ x12, 7);   x8 ^= rotl(x4 &+ x0, 9)
            x12 ^= rotl(x8 &+ x4, 13);  x0 ^= rotl(x12 &+ x8, 18)
            x9 ^= rotl(x5 &+ x1, 7);    x13 ^= rotl(x9 &+ x5, 9)
            x1 ^= rotl(x13 &+ x9, 13);  x5 ^= rotl(x1 &+ x13, 18)
            x14 ^= rotl(x10 &+ x6, 7);  x2 ^= rotl(x14 &+ x10, 9)
            x6 ^= rotl(x2 &+ x14, 13);  x10 ^= rotl(x6 &+ x2, 18)
            x3 ^= rotl(x15 &+ x11, 7);  x7 ^= rotl(x3 &+ x15, 9)
            x11 ^= rotl(x7 &+ x3, 13);  x15 ^= rotl(x11 &+ x7, 18)
            x1 ^= rotl(x0 &+ x3, 7);    x2 ^= rotl(x1 &+ x0, 9)
            x3 ^= rotl(x2 &+ x1, 13);   x0 ^= rotl(x3 &+ x2, 18)
            x6 ^= rotl(x5 &+ x4, 7);    x7 ^= rotl(x6 &+ x5, 9)
            x4 ^= rotl(x7 &+ x6, 13);   x5 ^= rotl(x4 &+ x7, 18)
            x11 ^= rotl(x10 &+ x9, 7);  x8 ^= rotl(x11 &+ x10, 9)
            x9 ^= rotl(x8 &+ x11, 13);  x10 ^= rotl(x9 &+ x8, 18)
            x12 ^= rotl(x15 &+ x14, 7); x13 ^= rotl(x12 &+ x15, 9)
            x14 ^= rotl(x13 &+ x12, 13); x15 ^= rotl(x14 &+ x13, 18)
        }
        b[0] &+= x0; b[1] &+= x1; b[2] &+= x2; b[3] &+= x3; b[4] &+= x4; b[5] &+= x5; b[6] &+= x6; b[7] &+= x7
        b[8] &+= x8; b[9] &+= x9; b[10] &+= x10; b[11] &+= x11; b[12] &+= x12; b[13] &+= x13; b[14] &+= x14; b[15] &+= x15
    }

    @inline(__always) private static func loadLE(_ p: UnsafePointer<UInt8>) -> UInt32 {
        UInt32(p[0]) | UInt32(p[1]) << 8 | UInt32(p[2]) << 16 | UInt32(p[3]) << 24
    }

    @inline(__always) private static func storeLE(_ v: UInt32, _ p: UnsafeMutablePointer<UInt8>) {
        p[0] = UInt8(truncatingIfNeeded: v); p[1] = UInt8(truncatingIfNeeded: v >> 8)
        p[2] = UInt8(truncatingIfNeeded: v >> 16); p[3] = UInt8(truncatingIfNeeded: v >> 24)
    }
}
