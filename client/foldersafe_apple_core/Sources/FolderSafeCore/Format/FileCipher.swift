import Foundation
import CryptoKit

/// 文件内容加密（规范 §6.1）：68 字节文件头 + 若干 32 KiB 明文块，每块独立 AES-GCM。
/// 块级接口留给以后的挂载层做随机读写；这里也提供整文件的便捷方法。
public enum FileCipher {
    public static let headerSize = 68
    public static let chunkPlainSize = 32768
    public static let chunkOverhead = 28                       // 12 字节 nonce + 16 字节 tag
    public static let chunkCipherSize = chunkPlainSize + chunkOverhead

    public struct Header {
        public let nonce: Data          // 12 字节
        public let contentKey: Data     // 32 字节，每个文件随机一把
    }

    public static func newHeader(_ random: RandomSource) -> Header {
        Header(nonce: random.bytes(12), contentKey: random.bytes(32))
    }

    public static func encryptHeader(_ h: Header, encKey: Data) throws -> Data {
        let payload = Data(repeating: 0xFF, count: 8) + h.contentKey   // 8 字节保留位（全 1）+ 内容密钥
        let box = try AES.GCM.seal(payload, using: SymmetricKey(data: encKey), nonce: AES.GCM.Nonce(data: h.nonce))
        return box.combined!
    }

    public static func decryptHeader(_ data: Data, encKey: Data) throws -> Header {
        guard data.count >= headerSize else { throw VaultError.corrupted("file header too short") }
        let bytes = data.prefix(headerSize)
        let payload: Data
        do {
            payload = try AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: SymmetricKey(data: encKey))
        } catch { throw VaultError.corrupted("file header authentication") }
        guard payload.count == 40 else { throw VaultError.corrupted("file header payload") }
        return Header(nonce: Data(bytes.prefix(12)), contentKey: Data(payload.suffix(32)))
    }

    static func chunkAAD(_ index: UInt64, _ h: Header) -> Data { Encoding.uint64BE(index) + h.nonce }

    public static func encryptChunk(_ plain: Data, index: UInt64, header h: Header, nonce: Data) throws -> Data {
        precondition(plain.count <= chunkPlainSize && !plain.isEmpty)
        let box = try AES.GCM.seal(plain, using: SymmetricKey(data: h.contentKey), nonce: AES.GCM.Nonce(data: nonce),
                                   authenticating: chunkAAD(index, h))
        return box.combined!
    }

    /// 读取端要接受只有 nonce + tag 的空块：Cryptomator 写空明文（如根目录的 dirid.c9r）时会带一个。
    public static func decryptChunk(_ cipher: Data, index: UInt64, header h: Header) throws -> Data {
        guard cipher.count >= chunkOverhead, cipher.count <= chunkCipherSize else { throw VaultError.corrupted("chunk size") }
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: cipher), using: SymmetricKey(data: h.contentKey),
                                    authenticating: chunkAAD(index, h))
        } catch { throw VaultError.corrupted("chunk \(index) authentication") }
    }

    public static func encrypt(_ plaintext: Data, encKey: Data, random: RandomSource) throws -> Data {
        let h = newHeader(random)
        var out = try encryptHeader(h, encKey: encKey)
        var index: UInt64 = 0
        var offset = plaintext.startIndex
        while offset < plaintext.endIndex {
            let end = min(offset + chunkPlainSize, plaintext.endIndex)
            out += try encryptChunk(plaintext[offset..<end], index: index, header: h, nonce: random.bytes(12))
            offset = end
            index += 1
        }
        return out
    }

    public static func decrypt(_ ciphertext: Data, encKey: Data) throws -> Data {
        guard cleartextSize(ciphertextSize: ciphertext.count) != nil else { throw VaultError.corrupted("ciphertext size") }
        let h = try decryptHeader(ciphertext, encKey: encKey)
        var out = Data()
        var index: UInt64 = 0
        var offset = ciphertext.startIndex + headerSize
        while offset < ciphertext.endIndex {
            let end = min(offset + chunkCipherSize, ciphertext.endIndex)
            out += try decryptChunk(ciphertext[offset..<end], index: index, header: h)
            offset = end
            index += 1
        }
        return out
    }

    /// 由密文大小算明文大小；不可能出现的大小（不到 nonce + tag 的尾巴）返回 nil。
    public static func cleartextSize(ciphertextSize c: Int) -> Int? {
        guard c >= headerSize else { return nil }
        let body = c - headerSize
        let full = body / chunkCipherSize, rest = body % chunkCipherSize
        if rest == 0 { return full * chunkPlainSize }
        guard rest >= chunkOverhead else { return nil }
        return full * chunkPlainSize + rest - chunkOverhead
    }
}
