import CryptoKit
import CommonCrypto
import Combine
import Foundation
import SwiftData
import UIKit
import AssistantCore

// MARK: - PIN 码加密迁移与封套定义

public enum MigrationCryptoError: LocalizedError {
    case pinTooShort
    case plaintextExportDisabled
    case incompleteLegacyBackup
    case missingAttachment(String)
    case persistenceFailure
    case pinMismatch
    case invalidPin
    case currentPinIncorrect
    case corruptedData
    case missingPin

    public var errorDescription: String? {
        switch self {
        case .pinTooShort:
            return "备份口令长度必须在 8 到 64 位之间。"
        case .plaintextExportDisabled:
            return "含敏感数据的明文备份已停用，请使用加密导出。"
        case .incompleteLegacyBackup:
            return "旧版备份缺少新数据类型，只能选择智能合并；请先从原设备生成新版备份。"
        case .missingAttachment(let name):
            return "无法读取附件「\(name)」，备份已取消以避免数据缺失。"
        case .persistenceFailure:
            return "数据写入失败，已撤销本次导入。"
        case .pinMismatch:
            return "两次输入的 PIN 码不一致，请核对后重新输入。"
        case .invalidPin:
            return "PIN 码不正确，无法解密该备份文件。"
        case .currentPinIncorrect:
            return "当前 PIN 码不正确，无法修改门禁。"
        case .corruptedData:
            return "备份数据文件损坏或已被篡改。"
        case .missingPin:
            return "请输入用于解锁该备份的 PIN 码。"
        }
    }
}

/// 端到端 AES-256-GCM 加密迁移数据包封套
/// 密钥派生与加密封装在 `AssistantCore.BackupEnvelopeCrypto`（纯函数、有单测覆盖），
/// 这里只保留封套的数据结构与版本号。
public struct EncryptedBackupEnvelope: Codable {
    public static let magicTag = "ASSISTANT_ENCRYPTED_MIGRATION"
    public static let currentVersion = BackupEnvelopeCrypto.currentVersion
    public static let defaultIterations = BackupEnvelopeCrypto.defaultIterations

    public var magic: String
    public var version: Int
    public var exportedAt: Date
    public var deviceModel: String
    public var appVersion: String
    public var saltBase64: String
    public var iterations: Int?
    public var payloadBase64: String
    public var hint: String?

    public init(
        saltBase64: String,
        payloadBase64: String,
        exportedAt: Date = .now,
        deviceModel: String = UIDevice.current.model,
        appVersion: String = "0.1.0",
        hint: String? = nil
    ) {
        self.magic = Self.magicTag
        self.version = Self.currentVersion
        self.exportedAt = exportedAt
        self.deviceModel = deviceModel
        self.appVersion = appVersion
        self.saltBase64 = saltBase64
        self.iterations = Self.defaultIterations
        self.payloadBase64 = payloadBase64
        self.hint = hint
    }
}

public enum BackupFileInspection {
    case encrypted(envelope: EncryptedBackupEnvelope)
    case legacyPlaintext(package: BackupPackage, summary: BackupInspectionSummary)
}

/// 备份与迁移功能的本地解锁 PIN 门禁（首次冷启动强制设置）。
///
/// 设计要点：
/// - 只保存 PBKDF2 派生的校验值（盐 + 派生密钥 + 迭代次数），绝不保存 PIN 明文；
/// - 与备份文件自身的加密 PIN 解耦——本 PIN 仅是进入“备份生成/数据迁移”的本地门禁，
///   忘记它只会挡住功能入口，可安全重置，不会影响任何已导出备份的可解密性
///   （那些备份由其导出时输入的文件 PIN 加密）。
@MainActor
final class MigrationPinManager: ObservableObject {
    static let shared = MigrationPinManager()

    private let saltKey = "migration_pin_salt_v1"
    private let verifierKey = "migration_pin_verifier_v1"
    private let iterationsKey = "migration_pin_iterations_v1"
    private let hintKey = "migration_pin_hint_v1"

    @Published private(set) var isConfigured: Bool = false

    /// 用户自设的 PIN 提示（仅自己看得懂，不含明文口令）。
    var hint: String? { UserDefaults.standard.string(forKey: hintKey) }

    private init() {
        refresh()
    }

    func refresh() {
        isConfigured = UserDefaults.standard.string(forKey: verifierKey) != nil
            && UserDefaults.standard.string(forKey: saltKey) != nil
    }

    /// 首次设置（或重置后重新设置）门禁 PIN。
    func setPin(_ pin: String, hint: String? = nil) throws {
        let clean = pin.trimmingCharacters(in: .whitespacesAndNewlines)
        try BackupEnvelopeCrypto.validatePin(clean)
        let salt = BackupEnvelopeCrypto.makeSalt()
        let iterations = BackupEnvelopeCrypto.defaultIterations
        let key = try BackupEnvelopeCrypto.deriveKey(pin: clean, salt: salt, iterations: iterations)
        let saltBase64 = salt.base64EncodedString()
        let verifierBase64 = key.withUnsafeBytes { Data($0).base64EncodedString() }
        UserDefaults.standard.set(saltBase64, forKey: saltKey)
        UserDefaults.standard.set(verifierBase64, forKey: verifierKey)
        UserDefaults.standard.set(iterations, forKey: iterationsKey)
        let trimmedHint = hint?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedHint, !trimmedHint.isEmpty {
            UserDefaults.standard.set(trimmedHint, forKey: hintKey)
        } else {
            UserDefaults.standard.removeObject(forKey: hintKey)
        }
        refresh()
    }

    /// 校验输入的 PIN 是否与已设置门禁一致。
    func verify(_ pin: String) -> Bool {
        guard let saltStr = UserDefaults.standard.string(forKey: saltKey),
              let storedStr = UserDefaults.standard.string(forKey: verifierKey),
              let salt = Data(base64Encoded: saltStr),
              let stored = Data(base64Encoded: storedStr) else { return false }
        let iterations = UserDefaults.standard.object(forKey: iterationsKey) as? Int ?? BackupEnvelopeCrypto.defaultIterations
        let clean = pin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count >= BackupEnvelopeCrypto.pinMinLength,
              let key = try? BackupEnvelopeCrypto.deriveKey(pin: clean, salt: salt, iterations: iterations) else { return false }
        return key.withUnsafeBytes { constantTimeEqual(Data($0), stored) }
    }

    /// 修改门禁 PIN：先校验旧 PIN 再重新派生写入，可同时更新提示。
    /// 与「重置门禁」不同：校验失败时旧 PIN 始终有效，不会把门禁清空。
    func changePin(current: String, to newPin: String, hint: String? = nil) throws {
        guard verify(current) else { throw MigrationCryptoError.currentPinIncorrect }
        try setPin(newPin, hint: hint)
    }

    /// 重置门禁（忘记 PIN 时可安全执行：仅解锁功能入口，不会解密任何既有备份）。
    func reset() {
        UserDefaults.standard.removeObject(forKey: saltKey)
        UserDefaults.standard.removeObject(forKey: verifierKey)
        UserDefaults.standard.removeObject(forKey: iterationsKey)
        UserDefaults.standard.removeObject(forKey: hintKey)
        refresh()
    }

    /// 恒时比较，避免通过响应时间逐字节猜解校验值。
    private func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[a.index(a.startIndex, offsetBy: i)] ^ b[b.index(b.startIndex, offsetBy: i)] }
        return diff == 0
    }
}

// MARK: - 数据迁移与管理服务

@MainActor
final class DataMigrationService {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    init() {
        self.context = Persistence.shared.mainContext
    }

    /// 当前本地数据汇总统计
    public func getLocalDataStats() -> [String: Int] {
        let todos = (try? context.fetchCount(FetchDescriptor<TodoItem>())) ?? 0
        let subs = (try? context.fetchCount(FetchDescriptor<SubscriptionItem>())) ?? 0
        let expiries = (try? context.fetchCount(FetchDescriptor<ItemExpiryItem>())) ?? 0
        let anniversaries = (try? context.fetchCount(FetchDescriptor<AnniversaryItem>())) ?? 0
        let habits = (try? context.fetchCount(FetchDescriptor<PeriodicHabit>())) ?? 0
        let meds = (try? context.fetchCount(FetchDescriptor<MedicationPlan>())) ?? 0
        let places = (try? context.fetchCount(FetchDescriptor<LearnedPlace>())) ?? 0
        let passwords = (try? context.fetchCount(FetchDescriptor<PasswordVaultItem>())) ?? 0
        let expenses = (try? context.fetchCount(FetchDescriptor<ExpenseRecord>())) ?? 0
        let documents = (try? context.fetchCount(FetchDescriptor<IDDocumentItem>())) ?? 0
        let departures = (try? context.fetchCount(FetchDescriptor<DepartureCheckItem>())) ?? 0
        let voiceMemos = (try? context.fetchCount(FetchDescriptor<VoiceMemo>())) ?? 0
        let vehicles = (try? context.fetchCount(FetchDescriptor<VehicleProfile>())) ?? 0
        let storedItems = (try? context.fetchCount(FetchDescriptor<StoredItem>())) ?? 0
        let medicineStocks = (try? context.fetchCount(FetchDescriptor<MedicineItem>())) ?? 0
        let dialogueRecords = (try? context.fetchCount(FetchDescriptor<DialogueMessageRecord>())) ?? 0
        let rawMessages = (try? context.fetchCount(FetchDescriptor<RawMessage>())) ?? 0
        let locationSamples = (try? context.fetchCount(FetchDescriptor<LocationStaySample>())) ?? 0
        let foodRecords = (try? context.fetchCount(FetchDescriptor<FoodIntakeRecord>())) ?? 0
        let waterRecords = (try? context.fetchCount(FetchDescriptor<WaterIntakeRecord>())) ?? 0

        return [
            "待办事项": todos,
            "自动续费管理": subs,
            "临期预警": expiries,
            "纪念日与生日": anniversaries,
            "周期家务习惯": habits,
            "健康服药计划": meds,
            "空间感知地点": places,
            "离线安全密码": passwords,
            "日常记账明细": expenses,
            "重要证件卡包": documents,
            "随身防丢清单": departures,
            "语音备忘速记": voiceMemos,
            "爱车档案": vehicles,
            "物品收纳": storedItems,
            "家庭常备药": medicineStocks,
            "对话历史": dialogueRecords,
            "原始消息": rawMessages,
            "位置采样": locationSamples,
            "饮食热量记录": foodRecords,
            "饮水记录": waterRecords
        ]
    }

    /// 探测备份文件类型（加密封套还是旧版未加密）
    public func inspectBackupFile(from data: Data) throws -> BackupFileInspection {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let envelope = try? decoder.decode(EncryptedBackupEnvelope.self, from: data),
           envelope.magic == EncryptedBackupEnvelope.magicTag {
            return .encrypted(envelope: envelope)
        }

        if let package = try? decoder.decode(BackupPackage.self, from: data) {
            let summary = buildSummary(package: package, isEncryptedWithPIN: false)
            return .legacyPlaintext(package: package, summary: summary)
        }

        throw MigrationCryptoError.corruptedData
    }

    /// 使用输入的 PIN 码解锁并解析加密备份
    public func unlockEncryptedArchive(envelope: EncryptedBackupEnvelope, pin: String) throws -> (package: BackupPackage, summary: BackupInspectionSummary) {
        let cleanPin = pin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPin.isEmpty else {
            throw MigrationCryptoError.missingPin
        }

        guard let saltData = Data(base64Encoded: envelope.saltBase64),
              let combinedData = Data(base64Encoded: envelope.payloadBase64) else {
            throw MigrationCryptoError.corruptedData
        }

        let decryptedData: Data
        do {
            // 版本分发在 Core：v1 走旧版 HKDF 兼容路径，v2+ 走 PBKDF2（含迭代边界校验）
            decryptedData = try BackupEnvelopeCrypto.openPayload(
                version: envelope.version,
                payload: combinedData,
                pin: cleanPin,
                salt: saltData,
                iterations: envelope.iterations
            )
        } catch let error as BackupEnvelopeCrypto.BackupCryptoError {
            // 映射到迁移层错误码：口令错/被篡改/版本不支持/参数非法各有明确提示
            switch error {
            case .pinOutOfRange: throw MigrationCryptoError.pinTooShort
            case .invalidIterations, .unsupportedVersion, .derivationFailed: throw MigrationCryptoError.corruptedData
            case .authenticationFailed: throw MigrationCryptoError.invalidPin
            }
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let package = try decoder.decode(BackupPackage.self, from: decryptedData)
        let summary = buildSummary(package: package, isEncryptedWithPIN: true)
        return (package, summary)
    }

    /// 校验并预览备份文件内容
    public func inspectArchive(from data: Data) throws -> (package: BackupPackage, summary: BackupInspectionSummary) {
        let inspection = try inspectBackupFile(from: data)
        switch inspection {
        case .encrypted:
            throw MigrationCryptoError.missingPin
        case .legacyPlaintext(let package, let summary):
            return (package, summary)
        }
    }

    // MARK: - 外部纯文本 / CSV 批量导入

    /// 批量导入纪念日（格式：名称, 日期(yyyy-MM-dd), 分类(可选), 备注(可选)）
    public func batchImportAnniversaries(text: String) throws -> Int {
        let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var count = 0
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        for line in lines {
            let parts = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 2 else { continue }
            let title = String(parts[0])
            guard let date = formatter.date(from: String(parts[1])) else { continue }
            let category = parts.count >= 3 && !parts[2].isEmpty ? String(parts[2]) : "纪念日"
            let notes = parts.count >= 4 ? String(parts[3]) : nil

            let item = AnniversaryItem(title: title, category: category, targetDate: date, notes: notes)
            context.insert(item)
            count += 1
        }

        do {
            try context.save()
        } catch {
            context.rollback()
            throw MigrationCryptoError.persistenceFailure
        }
        return count
    }

    /// 批量导入密码 CSV（兼容通用 CSV 格式：标题, 账号, 密码, 分类, 备注）
    public func batchImportPasswords(text: String) throws -> Int {
        let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var count = 0

        for line in lines {
            let parts = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 3 else { continue }
            let title = String(parts[0])
            let account = String(parts[1])
            let password = String(parts[2])
            let category = parts.count >= 4 && !parts[3].isEmpty ? String(parts[3]) : "日常账号"
            let notes = parts.count >= 5 ? String(parts[4]) : nil

            guard let encrypted = try? PasswordVaultCrypto.encrypt(password) else { continue }
            let item = PasswordVaultItem(
                title: title,
                account: account,
                passwordEncrypted: encrypted,
                category: category,
                notes: notes
            )
            context.insert(item)
            count += 1
        }

        do {
            try context.save()
        } catch {
            context.rollback()
            throw MigrationCryptoError.persistenceFailure
        }
        return count
    }

    /// 批量导入待办事项（每行一条）
    public func batchImportTodos(text: String) throws -> Int {
        let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var count = 0

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let item = TodoItem(type: .general, status: .active, title: trimmed)
            context.insert(item)
            count += 1
        }

        do {
            try context.save()
        } catch {
            context.rollback()
            throw MigrationCryptoError.persistenceFailure
        }
        return count
    }
}
