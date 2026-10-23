import Foundation
import Security
import LocalAuthentication

/// 设备钥匙（规范 §7.4）：把 rawKey 存进本机钥匙串，读取时必须过 Touch ID / Face ID。
/// 只在这台设备上有效、不随 iCloud 同步；换了指纹/面容（biometryCurrentSet）就自动失效，需要用密码重新开启。
public enum DeviceKeyStore {
    public enum Failure: Error { case unavailable, keychain(OSStatus), cancelled }
    static let service = "app.foldersafe.device-key"

    public static var biometryName: String {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch ctx.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        default: return ""
        }
    }

    public static var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    private static func base(_ vaultId: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: vaultId,
         kSecUseDataProtectionKeychain as String: true]
    }

    public static func enable(_ rawKey: Data, vaultId: String) throws {
        guard isAvailable else { throw Failure.unavailable }
        var err: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                                                           .biometryCurrentSet, &err) else { throw Failure.unavailable }
        SecItemDelete(base(vaultId) as CFDictionary)
        var q = base(vaultId)
        q[kSecValueData as String] = rawKey
        q[kSecAttrAccessControl as String] = access
        q[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }

    public static func isEnabled(vaultId: String) -> Bool {
        var q = base(vaultId)
        let ctx = LAContext()
        ctx.interactionNotAllowed = true                        // 只查有没有，不弹指纹
        q[kSecUseAuthenticationContext as String] = ctx
        q[kSecReturnAttributes as String] = true
        let status = SecItemCopyMatching(q as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    /// 弹出 Touch ID / Face ID，成功返回 rawKey。
    public static func read(vaultId: String, reason: String) throws -> Data {
        var q = base(vaultId)
        let ctx = LAContext()
        ctx.localizedReason = reason
        q[kSecUseAuthenticationContext as String] = ctx
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecUserCanceled || status == errSecAuthFailed { throw Failure.cancelled }
        guard status == errSecSuccess, let d = out as? Data else { throw Failure.keychain(status) }
        return d
    }

    public static func disable(vaultId: String) { SecItemDelete(base(vaultId) as CFDictionary) }
}
