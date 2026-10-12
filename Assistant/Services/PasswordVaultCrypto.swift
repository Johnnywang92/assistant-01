import AssistantCore
import CryptoKit
import Foundation
import Security
import SwiftData

/// 密码库 Keychain 主密钥保管 + 迁移入口。
///
/// 加密格式与迁移逻辑在 `AssistantCore.PasswordVaultCipher`（纯函数、有单测覆盖，
/// 包括「持久化文件搜不到明文」的取证测试）；这里只负责主密钥的存取。
/// 主密钥：设备 Keychain 中的 256-bit 随机数，`ThisDeviceOnly`——
/// 备份封套另按用户口令加密，还原时用新设备密钥重新加密，见 DataMigrationService.validate。
enum PasswordVaultCrypto {
    private static let account = "password_vault_master_key_v1"

    static func encrypt(_ plaintext: String) throws -> String {
        try PasswordVaultCipher.encrypt(plaintext, using: masterKey())
    }

    static func decrypt(_ stored: String) throws -> String {
        try PasswordVaultCipher.decrypt(stored, using: masterKey())
    }

    /// 把旧版明文记录就地升级为密文。启动与打开保险箱时调用；幂等，重复调用零成本。
    @MainActor
    static func migrateLegacyRecords(context: ModelContext) throws {
        let items = try context.fetch(FetchDescriptor<PasswordVaultItem>())
        let migrated = try PasswordVaultCipher.migrate(items, using: masterKey())
        if migrated > 0 { try context.save() }
        purgeResidualPlaintextIfNeeded(migrated: migrated)
    }

    /// 待清理标记：迁移后清磁盘残留失败（库忙）时置位，下次启动重试。
    private static let purgePendingKey = "password_vault_purge_pending_v1"

    /// 迁移后必须做文件层清理：**SQLite 的 UPDATE 不擦旧字节**——明文改成密文后，
    /// 旧行仍留在空闲页与 WAL 里，磁盘取证照样能搜到原始密码
    /// （AssistantCore 的取证测试可复现该问题并验证清理有效）。
    /// 清理是最佳努力：失败只记标记，不影响迁移结果；下次启动带标记重试。
    private static func purgeResidualPlaintextIfNeeded(migrated: Int) {
        let pending = UserDefaults.standard.bool(forKey: purgePendingKey)
        guard migrated > 0 || pending else { return }
        guard let storeURL = Persistence.storeURL else { return }
        let cleaned = SQLiteMaintenance.purgeResidualPlaintext(storeURL: storeURL)
        UserDefaults.standard.set(!cleaned, forKey: purgePendingKey)
    }

    private static func masterKey() throws -> SymmetricKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Bundle.main.bundleIdentifier ?? "com.yifanwang.assistant01",
            kSecAttrAccount as String: account
        ]
        var readQuery = query
        readQuery[kSecReturnData as String] = true
        readQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(readQuery as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 {
            return SymmetricKey(data: data)
        }
        guard status == errSecItemNotFound else { throw CryptoError.keychain(status) }

        let newKey = SymmetricKey(size: .bits256)
        let data = newKey.withUnsafeBytes { Data($0) }
        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess { return newKey }
        if addStatus == errSecDuplicateItem { return try masterKey() }
        throw CryptoError.keychain(addStatus)
    }

    enum CryptoError: LocalizedError {
        case invalidCiphertext
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .invalidCiphertext: "密码数据已损坏，无法解密。"
            case .keychain(let status): "无法访问设备安全密钥（\(status)），密码未保存。"
            }
        }
    }
}
