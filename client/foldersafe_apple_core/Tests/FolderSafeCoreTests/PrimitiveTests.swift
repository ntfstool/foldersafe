import XCTest
import CryptoKit
@testable import FolderSafeCore

/// 加密原语对 RFC 官方测试向量。
final class PrimitiveTests: XCTestCase {
    private func h(_ s: String) -> Data { Encoding.unhex(s.replacingOccurrences(of: " ", with: ""))! }

    func testCMACRFC4493() {
        let cmac = CMAC(key: h("2b7e1516 28aed2a6 abf71588 09cf4f3c"))
        XCTAssertEqual(Encoding.hex(cmac.mac([])), "bb1d6929e95937287fa37d129b756746")
        XCTAssertEqual(Encoding.hex(cmac.mac([UInt8](h("6bc1bee2 2e409f96 e93d7e11 7393172a")))),
                       "070a16b46b4d4144f79bdd9dd04a287c")
        XCTAssertEqual(Encoding.hex(cmac.mac([UInt8](h("6bc1bee22e409f96e93d7e117393172a ae2d8a571e03ac9c9eb76fac45af8e51 30c81c46a35ce411")))),
                       "dfa66747de9ae63030ca32611497c827")
    }

    func testAESSIVRFC5297() throws {
        // A.1 确定性模式
        let k1 = h("fffefdfc fbfaf9f8 f7f6f5f4 f3f2f1f0 f0f1f2f3 f4f5f6f7 f8f9fafb fcfdfeff")
        let ad1 = h("10111213 14151617 18191a1b 1c1d1e1f 20212223 24252627")
        let p1 = h("11223344 55667788 99aabbcc ddee")
        let c1 = AESSIV.encrypt(key: k1, plaintext: p1, associatedData: [ad1])
        XCTAssertEqual(Encoding.hex(c1), "85632d07c6e8f37f950acd320a2ecc9340c02b9690c4dc04daef7f6afe5c")
        XCTAssertEqual(try AESSIV.decrypt(key: k1, ciphertext: c1, associatedData: [ad1]), p1)

        // A.2 多个关联数据（最后一个是 nonce）
        let k2 = h("7f7e7d7c 7b7a7978 77767574 73727170 40414243 44454647 48494a4b 4c4d4e4f")
        let ads = [h("00112233 44556677 8899aabb ccddeeff deaddada deaddada ffeeddcc bbaa9988 77665544 33221100"),
                   h("10203040 50607080 90a0"),
                   h("09f91102 9d74e35b d84156c5 635688c0")]
        let p2 = h("74686973 20697320 736f6d65 20706c61 696e7465 78742074 6f20656e 63727970 74207573 696e6720 5349562d 414553")
        let c2 = AESSIV.encrypt(key: k2, plaintext: p2, associatedData: ads)
        XCTAssertEqual(Encoding.hex(c2), "7bdb6e3b432667eb06f4d14bff2fbd0fcb900f2fddbe404326601965c889bf17dba77ceb094fa663b7a3f748ba8af829ea64ad544a272e9c485b62a3fd5c0d")
        XCTAssertEqual(try AESSIV.decrypt(key: k2, ciphertext: c2, associatedData: ads), p2)

        // 篡改任何一位都必须失败
        var bad = c1; bad[20] ^= 1
        XCTAssertThrowsError(try AESSIV.decrypt(key: k1, ciphertext: bad, associatedData: [ad1]))
        XCTAssertThrowsError(try AESSIV.decrypt(key: k1, ciphertext: c1, associatedData: [h("00")]))
    }

    func testAESSIV512RoundTripAndEmpty() throws {
        let key = DeterministicRandom(seed: "siv").bytes(64)
        for len in [0, 1, 15, 16, 17, 31, 32, 33, 100] {
            let p = DeterministicRandom(seed: "p\(len)").bytes(len)
            let c = AESSIV.encrypt(key: key, plaintext: p, associatedData: [Data("dir".utf8)])
            XCTAssertEqual(c.count, len + 16)
            XCTAssertEqual(try AESSIV.decrypt(key: key, ciphertext: c, associatedData: [Data("dir".utf8)]), p)
        }
    }

    func testScryptRFC7914() throws {
        XCTAssertEqual(Encoding.hex(try Scrypt.derive(password: Data(), salt: Data(), n: 16, r: 1, p: 1, length: 64)),
                       "77d6576238657b203b19ca42c18a0497f16b4844e3074ae8dfdffa3fede21442fcd0069ded0948f8326a753a0fc81f17e8d3e0fb2e0d3628cf35e20c38d18906")
        XCTAssertEqual(Encoding.hex(try Scrypt.derive(password: Data("password".utf8), salt: Data("NaCl".utf8), n: 1024, r: 8, p: 16, length: 64)),
                       "fdbabe1c9d3472007856e7190d01e9fe7c6ad7cbc8237830e77376634b3731622eaf30d92e22a3886ff109279d9830dac727afb94a83ee6d8360cbdfa2cc0640")
        XCTAssertEqual(Encoding.hex(try Scrypt.derive(password: Data("pleaseletmein".utf8), salt: Data("SodiumChloride".utf8), n: 16384, r: 8, p: 1, length: 64)),
                       "7023bdcb3afd7348461c06cd81fd38ebfda8fbba904f8e3ea9b543f6545da1f2d5432955613f0fcf62d49705242a9af9e61e85dc0d651e40dfcf017b45575887")
    }

    func testScryptRejectsHostileParameters() {
        XCTAssertThrowsError(try Scrypt.derive(password: Data(), salt: Data(), n: 1000, r: 8, p: 1, length: 32))    // 不是 2 的幂
        XCTAssertThrowsError(try Scrypt.derive(password: Data(), salt: Data(), n: 1 << 24, r: 8, p: 1, length: 32))  // 2 GiB
    }

    func testAESKeyWrapRFC3394() throws {
        let kek = SymmetricKey(data: h("000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F"))
        let key = SymmetricKey(data: h("00112233445566778899AABBCCDDEEFF000102030405060708090A0B0C0D0E0F"))
        XCTAssertEqual(Encoding.hex(try AES.KeyWrap.wrap(key, using: kek)),
                       "28c9f404c4b810f4cbccb35cfb87f8263f5786e2d80ed326cbc7f0e71a99f43bfb988b9b7a02dd21")
    }

    func testEncodings() {
        XCTAssertEqual(Encoding.base32(Data("foobar".utf8)), "MZXW6YTBOI======")
        XCTAssertEqual(Encoding.base32(Data(repeating: 0xff, count: 20)).count, 32)
        XCTAssertEqual(Encoding.base64url(Data([0xfb, 0xff])), "-_8=")
        XCTAssertEqual(Encoding.base64urlDecode("-_8"), Data([0xfb, 0xff]))
        XCTAssertEqual(Encoding.base64urlDecode("-_8="), Data([0xfb, 0xff]))
        XCTAssertNil(Encoding.base64urlDecode("+/8="))
    }
}
