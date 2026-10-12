import CommonCrypto
import CryptoKit
import Foundation

/// 备份封套的密钥派生与加密封装（纯函数、无平台依赖，可单测）。
///
/// 威胁模型：备份文件会离开本机（AirDrop/文件 App/网盘），离线持有者可以对弱口令
/// 高速暴力破解。因此：
/// - 口令长度 8–64（app 层提示用户用强口令）；
/// - **慢速 KDF**：PBKDF2-HMAC-SHA256，默认 310,000 轮 + 32 字节高熵随机盐；
/// - 每份备份独立随机盐——同一口令的两份备份密文不同，且无法预计算彩虹表；
/// - AES-256-GCM 自带完整性：口令错一位或密文被改一位，都在 open 时失败。
///
/// v1 兼容：最早的备份用 HKDF 直接派生（快、可被暴力破解），保留只读路径——
/// 老备份必须还能导入，但新备份一律走 PBKDF2。
public enum BackupEnvelopeCrypto {
    /// 当前封套版本。v1 = HKDF（遗留，只读）；v2 = PBKDF2。
    public static let currentVersion = 2

    public static let pinMinLength = 8
    public static let pinMaxLength = 64

    /// 默认迭代次数。OWASP 对 PBKDF2-HMAC-SHA256 的建议量级（2023 起 60 万；
    /// 310k 在旧设备上约 0.2–0.5s，兼顾体验）。
    public static let defaultIterations = 310_000

    /// 迭代次数合法区间。导入方必须校验——否则「迭代 1 次」的伪造封套可被瞬间解开。
    public static let minIterations = 100_000
    public static let maxIterations = 2_000_000

    public enum BackupCryptoError: Error, Equatable {
        case pinOutOfRange
        case invalidIterations
        case derivationFailed
        /// 口令错误或密文被篡改（GCM 认证失败统一归到这里）
        case authenticationFailed
        case unsupportedVersion
    }

    /// 校验口令长度。导出前调用；太短直接拒绝，不要生成一个“自以为安全”的备份。
    public static func validatePin(_ pin: String) throws {
        guard (pinMinLength...pinMaxLength).contains(pin.count) else {
            throw BackupCryptoError.pinOutOfRange
        }
    }

    /// 32 字节高熵随机盐。每份备份都用新盐。
    public static func makeSalt() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    /// PBKDF2-HMAC-SHA256 派生 256-bit 密钥。
    public static func deriveKey(pin: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        guard (minIterations...maxIterations).contains(iterations) else {
            throw BackupCryptoError.invalidIterations
        }
        var derived = Data(count: 32)
        let status: Int32 = pin.withCString { password in
            salt.withUnsafeBytes { saltBytes in
                derived.withUnsafeMutableBytes { keyBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        password, pin.utf8.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                        keyBytes.bindMemory(to: UInt8.self).baseAddress, 32
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw BackupCryptoError.derivationFailed }
        return SymmetricKey(data: derived)
    }

    /// v1 遗留路径：HKDF 直接派生。**不要用于新备份**（可被高速暴力破解）。
    public static func deriveLegacyKey(pin: String, salt: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(pin.utf8)),
            salt: salt,
            info: Data("assistant.data.migration.aes256".utf8),
            outputByteCount: 32
        )
    }

    /// 加密载荷，返回 AES-GCM combined（nonce + ciphertext + tag）。口令长度非法直接拒绝。
    public static func seal(_ payload: Data, pin: String, salt: Data, iterations: Int) throws -> Data {
        try validatePin(pin)
        let key = try deriveKey(pin: pin, salt: salt, iterations: iterations)
        let box = try AES.GCM.seal(payload, using: key)
        guard let combined = box.combined else { throw BackupCryptoError.derivationFailed }
        return combined
    }

    /// 解密载荷。口令错误 / 密文篡改都抛 `authenticationFailed`——
    /// 调用方不应向用户区分这两种情况（避免把“篡改检测”变成口令预言机）。
    public static func open(_ combined: Data, pin: String, salt: Data, iterations: Int) throws -> Data {
        let key = try deriveKey(pin: pin, salt: salt, iterations: iterations)
        return try open(combined, using: key)
    }

    /// 按封套版本解密。v1 走 HKDF 兼容路径；v2+ 走 PBKDF2（iterations 为 nil 时用默认值）。
    public static func openPayload(version: Int, payload: Data, pin: String, salt: Data, iterations: Int?) throws -> Data {
        switch version {
        case 1:
            return try open(payload, using: deriveLegacyKey(pin: pin, salt: salt))
        case currentVersion:
            let effective = iterations ?? defaultIterations
            return try open(payload, pin: pin, salt: salt, iterations: effective)
        default:
            throw BackupCryptoError.unsupportedVersion
        }
    }

    private static func open(_ combined: Data, using key: SymmetricKey) throws -> Data {
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: key)
        } catch {
            throw BackupCryptoError.authenticationFailed
        }
    }
}
