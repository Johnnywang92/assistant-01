import CryptoKit
import Foundation
import Security
import SwiftData

/// 使用设备 Keychain 保存随机主密钥；数据库中只保存 AES-GCM 密文。
enum PasswordVaultCrypto {
    private static let account = "password_vault_master_key_v1"
    private static let prefix = "aesgcm:v1:"

    static func encrypt(_ plaintext: String) throws -> String {
        let box = try AES.GCM.seal(Data(plaintext.utf8), using: masterKey())
        guard let data = box.combined else { throw CryptoError.invalidCiphertext }
        return prefix + data.base64EncodedString()
    }

    static func decrypt(_ stored: String) throws -> String {
        guard stored.hasPrefix(prefix) else { return stored } // 旧版明文，仅供迁移读取
        guard let data = Data(base64Encoded: String(stored.dropFirst(prefix.count))) else {
            throw CryptoError.invalidCiphertext
        }
        let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: masterKey())
        guard let result = String(data: plaintext, encoding: .utf8) else { throw CryptoError.invalidCiphertext }
        return result
    }

    @MainActor
    static func migrateLegacyRecords(context: ModelContext) throws {
        let items = try context.fetch(FetchDescriptor<PasswordVaultItem>())
        var changed = false
        for item in items where !item.passwordEncrypted.hasPrefix(prefix) {
            item.passwordEncrypted = try encrypt(item.passwordEncrypted)
            changed = true
        }
        if changed { try context.save() }
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
