import Foundation
import Security

/// 解锁期间把 vault 的 rawKey 交给扩展（FSKit / File Provider）用的共享钥匙串。
/// 只在"已解锁"时存在：上锁时 App 删除它，扩展也随之丢掉内存里的钥匙。
/// 属性：本机专用、设备解锁时才可读、不随 iCloud 同步、只有本开发者的 App 和扩展能读。
public enum UnlockedKeyStore {
    public enum Failure: Error { case keychain(OSStatus) }

    private static func query(_ vaultId: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: SharedConfig.keychainService,
         kSecAttrAccount as String: vaultId,
         kSecAttrAccessGroup as String: SharedConfig.keychainGroup,
         kSecUseDataProtectionKeychain as String: true]
    }

    public static func put(_ rawKey: Data, vaultId: String) throws {
        SecItemDelete(query(vaultId) as CFDictionary)
        var q = query(vaultId)
        q[kSecValueData as String] = rawKey
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        q[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }

    public static func get(vaultId: String) -> Data? {
        var q = query(vaultId)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    public static func remove(vaultId: String) {
        SecItemDelete(query(vaultId) as CFDictionary)
    }
}
