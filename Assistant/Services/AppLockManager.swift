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
        let hasCode = UserDefaults.standard.string(forKey: keyPasscodeHash)?.isEmpty == false
        let enabled = UserDefaults.standard.bool(forKey: keyEnabled) && hasCode
        let bio = UserDefaults.standard.object(forKey: keyBiometrics) as? Bool ?? true
        let timeoutRaw = UserDefaults.standard.integer(forKey: keyTimeout)

        self.isAppLockEnabled = enabled
        self.useBiometrics = bio
        self.timeoutOption = LockTimeoutOption(rawValue: timeoutRaw) ?? .immediately
        // 只有确实设置了密码且启用了应用锁，才在启动时锁定
        self.isLocked = enabled
    }

    public var hasPasscode: Bool {
        guard let hash = UserDefaults.standard.string(forKey: keyPasscodeHash) else { return false }
        return !hash.isEmpty
    }

    /// 设置 4 位数字密码
    public func setPasscode(_ code: String) {
        let hashed = hash(code)
        UserDefaults.standard.set(hashed, forKey: keyPasscodeHash)
        isAppLockEnabled = true
        isLocked = false
    }

    /// 验证数字密码
    public func verifyPasscode(_ code: String) -> Bool {
        guard let savedHash = UserDefaults.standard.string(forKey: keyPasscodeHash) else {
            return false
        }
        return hash(code) == savedHash
    }

    /// 关闭密码并禁用 App 锁
    public func removePasscode() {
        UserDefaults.standard.removeObject(forKey: keyPasscodeHash)
        isAppLockEnabled = false
        isLocked = false
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
        let inputData = Data(text.utf8)
        let hashed = SHA256.hash(data: inputData)
        return hashed.compactMap { String(format: "%02x", $0) }.joined()
    }
}
