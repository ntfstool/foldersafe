import Foundation
import CryptoKit

/// vault.cryptomator（规范 §5.1）：用 rawKey 做 HMAC 签名的 JWT。jti 就是 vault ID。
public struct VaultConfig: Equatable {
    static let fileName = "vault.cryptomator"
    static let masterkeyKid = "masterkeyfile:masterkey.cryptomator"

    public var vaultId: String
    public var shorteningThreshold: Int
    public var format: Int = 8
    public var cipherCombo: String = "SIV_GCM"
    var kid: String = masterkeyKid

    public init(vaultId: String, shorteningThreshold: Int = 220) {
        self.vaultId = vaultId
        self.shorteningThreshold = shorteningThreshold
    }

    /// 生成 JWT（HS256）。键顺序固定，方便测试向量逐字节复现。
    func token(signedWith key: Masterkey) -> String {
        let header = #"{"kid":"\#(kid)","typ":"JWT","alg":"HS256"}"#
        let payload = #"{"format":\#(format),"shorteningThreshold":\#(shorteningThreshold),"jti":"\#(vaultId)","cipherCombo":"\#(cipherCombo)"}"#
        let signingInput = VaultConfig.b64(Data(header.utf8)) + "." + VaultConfig.b64(Data(payload.utf8))
        let sig = HMAC<SHA256>.authenticationCode(for: Data(signingInput.utf8), using: SymmetricKey(data: key.raw))
        return signingInput + "." + VaultConfig.b64(Data(sig))
    }

    /// 第一步：不验签先解出 kid 和 vault ID（要靠它们找到钥匙）。
    struct Unverified {
        let kid: String
        let alg: String
        let config: VaultConfig
        let signingInput: Data
        let signature: Data
    }

    static func decodeUnverified(_ token: String) throws -> Unverified {
        let parts = token.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let h = Encoding.base64urlDecode(parts[0]), let p = Encoding.base64urlDecode(parts[1]),
              let sig = Encoding.base64urlDecode(parts[2]),
              let header = try? JSONSerialization.jsonObject(with: h) as? [String: Any],
              let payload = try? JSONSerialization.jsonObject(with: p) as? [String: Any],
              let kid = header["kid"] as? String, let alg = header["alg"] as? String,
              let jti = payload["jti"] as? String, let format = payload["format"] as? Int
        else { throw VaultError.corrupted(fileName) }
        var c = VaultConfig(vaultId: jti, shorteningThreshold: payload["shorteningThreshold"] as? Int ?? 220)
        c.format = format
        c.cipherCombo = payload["cipherCombo"] as? String ?? ""
        c.kid = kid
        return Unverified(kid: kid, alg: alg, config: c, signingInput: Data("\(parts[0]).\(parts[1])".utf8), signature: sig)
    }

    /// 第二步：拿到 rawKey 后验签，并确认是本规范支持的格式。
    static func verify(_ u: Unverified, with key: Masterkey) throws -> VaultConfig {
        let k = SymmetricKey(data: key.raw)
        let ok: Bool
        switch u.alg {
        case "HS256": ok = HMAC<SHA256>.isValidAuthenticationCode(u.signature, authenticating: u.signingInput, using: k)
        case "HS384": ok = HMAC<SHA384>.isValidAuthenticationCode(u.signature, authenticating: u.signingInput, using: k)
        case "HS512": ok = HMAC<SHA512>.isValidAuthenticationCode(u.signature, authenticating: u.signingInput, using: k)
        default: throw VaultError.unsupported("vault config alg \(u.alg)")
        }
        guard ok else { throw VaultError.corrupted("vault config signature") }
        guard u.config.format == 8 else { throw VaultError.unsupported("vault format \(u.config.format)") }
        guard u.config.cipherCombo == "SIV_GCM" else { throw VaultError.unsupported("cipher combo \(u.config.cipherCombo)") }
        guard u.config.shorteningThreshold >= 36 else { throw VaultError.corrupted("shorteningThreshold") }
        return u.config
    }

    /// JWT 用不带填充的 base64url。
    private static func b64(_ d: Data) -> String {
        Encoding.base64url(d).replacingOccurrences(of: "=", with: "")
    }
}
