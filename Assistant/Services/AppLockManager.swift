import CommonCrypto
import CryptoKit
import Foundation
import LocalAuthentication
import SwiftUI

public enum LockTimeoutOption: Int, CaseIterable, Identifiable {
    case immediately = 0
    case oneMinute = 60
    case fiveMinutes = 300

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .immediately: return "立即锁定"
        case .oneMinute: return "离开 1 分钟后"
        case .fiveMinutes: return "离开 5 分钟后"
        }
    }
}

/// 全局 App 安全锁管理器
@MainActor
public final class AppLockManager: ObservableObject {
    public static let shared = AppLockManager()

    private let keyEnabled = "app_lock_enabled"
    private let keyBiometrics = "app_lock_use_biometrics"
    private let keyPasscodeHash = "app_lock_passcode_hash"
    private let keyTimeout = "app_lock_timeout_seconds"

    @Published public var isLocked: Bool = false
    @Published public var isAppLockEnabled: Bool {
        didSet { UserDefaults.standard.set(isAppLockEnabled, forKey: keyEnabled) }
    }
    @Published public var useBiometrics: Bool {
        didSet { UserDefaults.standard.set(useBiometrics, forKey: keyBiometrics) }
    }
    @Published public var timeoutOption: LockTimeoutOption {
        didSet { UserDefaults.standard.set(timeoutOption.rawValue, forKey: keyTimeout) }
    }

    private var backgroundTimestamp: Date?

    public init() {
        let bio = UserDefaults.standard.object(forKey: keyBiometrics) as? Bool ?? true
        let timeoutRaw = UserDefaults.standard.integer(forKey: keyTimeout)

        self.useBiometrics = bio
        self.timeoutOption = LockTimeoutOption(rawValue: timeoutRaw) ?? .immediately

        let enabled = UserDefaults.standard.bool(forKey: keyEnabled)
        // 从 Keychain 安全读取密码标记
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keyPasscodeHash,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let hasCode: Bool
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data {
            hasCode = !data.isEmpty
        } else {
            hasCode = UserDefaults.standard.string(forKey: keyPasscodeHash)?.isEmpty == false
        }

        let valid = enabled && hasCode
        self.isAppLockEnabled = valid
        self.isLocked = valid
    }

    public var hasPasscode: Bool {
        if let kcHash = readFromKeychain(key: keyPasscodeHash), !kcHash.isEmpty {
            return true
        }
        migrateLegacyPasscodeIfNeeded()
        return readFromKeychain(key: keyPasscodeHash)?.isEmpty == false
    }

    /// 旧版本把哈希存在 UserDefaults：迁移到 Keychain。仅在 Keychain 无记录时触发，写入成功才删除旧值。
    private func migrateLegacyPasscodeIfNeeded() {
        guard let legacyHash = UserDefaults.standard.string(forKey: keyPasscodeHash), !legacyHash.isEmpty else { return }
        if saveToKeychain(key: keyPasscodeHash, value: legacyHash) {
            UserDefaults.standard.removeObject(forKey: keyPasscodeHash)
        }
    }

    /// 设置 4 位数字密码（随机盐 + PBKDF2，存入 Keychain）。写入失败返回 false，不会启用锁。
    @discardableResult
    public func setPasscode(_ code: String) -> Bool {
        guard saveToKeychain(key: keyPasscodeHash, value: Self.makeHash(code)) else { return false }
        UserDefaults.standard.removeObject(forKey: keyPasscodeHash)
        resetFailures()
        isAppLockEnabled = true
        isLocked = false
        return true
    }

    // MARK: - 失败次数限制

    private let keyFailCount = "app_lock_fail_count"
    private let keyLockoutUntil = "app_lock_lockout_until"

    /// 距离下次允许尝试的剩余秒数（0 = 可尝试）。
    public var lockoutRemaining: TimeInterval {
        let until = UserDefaults.standard.double(forKey: keyLockoutUntil)
        return max(0, until - Date.now.timeIntervalSince1970)
    }

    private func resetFailures() {
        UserDefaults.standard.removeObject(forKey: keyFailCount)
        UserDefaults.standard.removeObject(forKey: keyLockoutUntil)
    }

    /// 连续错误 5 次起递增冷却：30s、1m、5m、15m、1h（封顶）。
    private func recordFailure() {
        let count = UserDefaults.standard.integer(forKey: keyFailCount) + 1
        UserDefaults.standard.set(count, forKey: keyFailCount)
        guard count >= 5 else { return }
        let delays: [TimeInterval] = [30, 60, 300, 900, 3600]
        let delay = delays[min(count - 5, delays.count - 1)]
        UserDefaults.standard.set(Date.now.timeIntervalSince1970 + delay, forKey: keyLockoutUntil)
    }

    /// 验证数字密码（冷却期内直接拒绝）
    public func verifyPasscode(_ code: String) -> Bool {
        guard lockoutRemaining == 0 else { return false }
        migrateLegacyPasscodeIfNeeded()
        guard let stored = readFromKeychain(key: keyPasscodeHash) else {
            recordFailure()
            return false
        }
        if Self.verify(code, against: stored) {
            // 旧的固定盐/无盐 SHA256 → 升级为随机盐 PBKDF2
            if !stored.hasPrefix(Self.hashPrefix) {
                saveToKeychain(key: keyPasscodeHash, value: Self.makeHash(code))
            }
            resetFailures()
            return true
        }
        recordFailure()
        return false
    }

    /// 关闭密码并禁用 App 锁
    public func removePasscode() {
        deleteFromKeychain(key: keyPasscodeHash)
        UserDefaults.standard.removeObject(forKey: keyPasscodeHash)
        resetFailures()
        isAppLockEnabled = false
        isLocked = false
    }

    // MARK: - Keychain 底层安全存取

    @discardableResult
    private func saveToKeychain(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        // 先清掉可能存在的旧条目（含早期未带 service 的），再带 service 写入；检查结果。
        SecItemDelete(match as CFDictionary)
        var add = match
        add[kSecAttrService as String] = Bundle.main.bundleIdentifier ?? "com.yifanwang.assistant01.applock"
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    private func readFromKeychain(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deleteFromKeychain(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// App 进入后台
    public func appDidEnterBackground() {
        guard isAppLockEnabled && hasPasscode else { return }
        backgroundTimestamp = .now
        if timeoutOption == .immediately {
            isLocked = true
        }
    }

    /// App 返回前台
    public func appWillEnterForeground() {
        guard isAppLockEnabled && hasPasscode else {
            isLocked = false
            return
        }
        if let bgTime = backgroundTimestamp {
            let elapsed = Date.now.timeIntervalSince(bgTime)
            if elapsed >= Double(timeoutOption.rawValue) {
                isLocked = true
            }
        }
        backgroundTimestamp = nil

        // 如果处于锁定中，且开启了人脸识别，自动唤起 Face ID
        if isLocked && useBiometrics {
            authenticateWithBiometrics()
        }
    }

    /// 唤起系统 Face ID / Touch ID 解锁
    public func authenticateWithBiometrics(reason: String = "使用人脸识别解锁应用") {
        let context = LAContext()
        context.localizedCancelTitle = "输入数字密码"
        var error: NSError?

        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, _ in
                Task { @MainActor in
                    if success {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            self.isLocked = false
                        }
                    }
                }
            }
        }
    }

    public func unlockDirectly() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            self.isLocked = false
        }
    }

    public func lockNow() {
        guard isAppLockEnabled && hasPasscode else { return }
        withAnimation {
            self.isLocked = true
        }
    }

    // MARK: - 口令哈希

    private static let hashPrefix = "v2$"
    private static let pbkdf2Rounds: UInt32 = 120_000

    private static func pbkdf2(_ code: String, salt: Data) -> Data {
        var derived = Data(count: 32)
        let pwd = Array(code.utf8)
        _ = derived.withUnsafeMutableBytes { out in
            salt.withUnsafeBytes { saltPtr in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2), pwd, pwd.count,
                    saltPtr.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), pbkdf2Rounds,
                    out.bindMemory(to: UInt8.self).baseAddress, 32)
            }
        }
        return derived
    }

    private static func makeHash(_ code: String) -> String {
        let salt = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        return hashPrefix + salt.base64EncodedString() + "$" + pbkdf2(code, salt: salt).base64EncodedString()
    }

    private static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static func verify(_ code: String, against stored: String) -> Bool {
        if stored.hasPrefix(hashPrefix) {
            let parts = stored.dropFirst(hashPrefix.count).split(separator: "$", omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let salt = Data(base64Encoded: String(parts[0])),
                  let expected = Data(base64Encoded: String(parts[1])) else { return false }
            return constantTimeEqual(pbkdf2(code, salt: salt), expected)
        }
        // 旧版（固定盐 / 无盐 SHA256）仅用于一次性升级
        let storedData = Data(stored.utf8)
        return constantTimeEqual(Data(legacyHash("assistant_secure_salt_\(code)").utf8), storedData)
            || constantTimeEqual(Data(legacyHash(code).utf8), storedData)
    }

    private static func legacyHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).compactMap { String(format: "%02x", $0) }.joined()
    }
}
