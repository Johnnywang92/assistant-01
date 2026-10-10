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
        // 向下兼容：如果旧版本存储在 UserDefaults，自动无缝迁移至系统 Keychain
        if let legacyHash = UserDefaults.standard.string(forKey: keyPasscodeHash), !legacyHash.isEmpty {
            saveToKeychain(key: keyPasscodeHash, value: legacyHash)
            UserDefaults.standard.removeObject(forKey: keyPasscodeHash)
            return true
        }
        return false
    }

    /// 设置 4 位数字密码（存入 iOS 硬件受保护的 Keychain）
    public func setPasscode(_ code: String) {
        let hashed = hash(code)
        saveToKeychain(key: keyPasscodeHash, value: hashed)
        UserDefaults.standard.removeObject(forKey: keyPasscodeHash)
        isAppLockEnabled = true
        isLocked = false
    }

    /// 验证数字密码
    public func verifyPasscode(_ code: String) -> Bool {
        let targetHash = hash(code)
        let legacyRawHash = hashLegacy(code)

        if let kcHash = readFromKeychain(key: keyPasscodeHash) {
            if kcHash == targetHash || kcHash == legacyRawHash {
                // 如果是旧无盐哈希，升级为带盐哈希
                if kcHash == legacyRawHash {
                    saveToKeychain(key: keyPasscodeHash, value: targetHash)
                }
                return true
            }
        }
        if let legacyHash = UserDefaults.standard.string(forKey: keyPasscodeHash) {
            if legacyHash == targetHash || legacyHash == legacyRawHash {
                saveToKeychain(key: keyPasscodeHash, value: targetHash)
                UserDefaults.standard.removeObject(forKey: keyPasscodeHash)
                return true
            }
        }
        return false
    }

    /// 关闭密码并禁用 App 锁
    public func removePasscode() {
        deleteFromKeychain(key: keyPasscodeHash)
        UserDefaults.standard.removeObject(forKey: keyPasscodeHash)
        isAppLockEnabled = false
        isLocked = false
    }

    // MARK: - Keychain 底层安全存取

    private func saveToKeychain(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
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

    private func hash(_ text: String) -> String {
        let salted = "assistant_secure_salt_\(text)"
        let inputData = Data(salted.utf8)
        let hashed = SHA256.hash(data: inputData)
        return hashed.compactMap { String(format: "%02x", $0) }.joined()
    }

    private func hashLegacy(_ text: String) -> String {
        let inputData = Data(text.utf8)
        let hashed = SHA256.hash(data: inputData)
        return hashed.compactMap { String(format: "%02x", $0) }.joined()
    }
}
