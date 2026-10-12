import CryptoKit
import Foundation

/// 密码库加解密核心（纯函数、无平台依赖，可在 macOS 上直接单测）。
///
/// 分工：本文件只负责「密文格式 + AES-GCM 加解密 + 迁移决策」；
/// 主密钥的保管（Keychain）在 app 侧的 `PasswordVaultCrypto`，通过 `using:` 注入。
/// 这样安排是为了让「持久化文件里搜不到明文」这类安全属性能被自动化测试覆盖——
/// Keychain 在测试环境不可用，但加密格式本身可以。
///
/// 存储格式：`aesgcm:v1:` + base64(AES.GCM.SealedBox.combined)
/// combined = nonce(12) + ciphertext + tag(16)，自带完整性校验，篡改会在 open 时抛出。
public enum PasswordVaultCipher {
    /// 密文前缀。没有此前缀的一律视为旧版明文（仅供迁移读取）。
    public static let prefix = "aesgcm:v1:"

    /// 该存储值是否已是密文
    public static func isCiphertext(_ stored: String) -> Bool {
        stored.hasPrefix(prefix)
    }

    /// 该存储值是否需要迁移（明文 → 密文）。空串视为无需迁移，避免给脏数据白造一条密文。
    public static func needsMigration(_ stored: String) -> Bool {
        !stored.isEmpty && !isCiphertext(stored)
    }

    /// 加密为密文（含前缀）
    public static func encrypt(_ plaintext: String, using key: SymmetricKey) throws -> String {
        let box = try AES.GCM.seal(Data(plaintext.utf8), using: key)
        guard let data = box.combined else { throw PasswordVaultCipherError.invalidCiphertext }
        return prefix + data.base64EncodedString()
    }

    /// 解密。**旧版明文原样返回**——只为迁移读取存在，
    /// UI 展示/复制必须经过此处；发现无前缀值应提示用户完成迁移。
    public static func decrypt(_ stored: String, using key: SymmetricKey) throws -> String {
        guard isCiphertext(stored) else { return stored }
        let encoded = String(stored.dropFirst(prefix.count))
        guard let data = Data(base64Encoded: encoded) else {
            throw PasswordVaultCipherError.invalidCiphertext
        }
        let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key)
        guard let result = String(data: plaintext, encoding: .utf8) else {
            throw PasswordVaultCipherError.invalidCiphertext
        }
        return result
    }

    /// 批量迁移：把明文记录就地改为密文，返回迁移条数。
    /// 已是密文的记录不动（幂等——重复调用返回 0，不会二次加密）。
    public static func migrate(_ records: [any PasswordVaultRecord], using key: SymmetricKey) throws -> Int {
        var migrated = 0
        for record in records where needsMigration(record.passwordEncrypted) {
            record.passwordEncrypted = try encrypt(record.passwordEncrypted, using: key)
            migrated += 1
        }
        return migrated
    }
}

/// 可迁移的密码记录。app 侧 `PasswordVaultItem` 与测试用镜像模型都遵循它。
/// 限定 class：迁移是「就地改写」，值类型传入不会回写到调用方。
public protocol PasswordVaultRecord: AnyObject {
    var passwordEncrypted: String { get set }
}

public enum PasswordVaultCipherError: Error, Equatable {
    /// 密文损坏、被篡改或 base64 非法
    case invalidCiphertext
}
