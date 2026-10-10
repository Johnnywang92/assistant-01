import CryptoKit
import CommonCrypto
import Foundation
import SwiftData
import UIKit

/// 备份与迁移数据包协议版本
public struct BackupPackage: Codable {
    public struct Metadata: Codable {
        public var schemaVersion: Int
        public var appVersion: String
        public var exportedAt: Date
        public var deviceModel: String
    }

    public var metadata: Metadata
    public var todos: [TodoDTO]
    public var subscriptions: [SubscriptionDTO]
    public var itemExpiries: [ItemExpiryDTO]
    public var anniversaries: [AnniversaryDTO]
    public var habits: [PeriodicHabitDTO]
    public var medications: [MedicationDTO]
    public var learnedPlaces: [LearnedPlaceDTO]
    public var passwords: [PasswordVaultDTO]
    public var dataUsageRecords: [DataUsageRecordDTO]
    public var expenses: [ExpenseDTO]?
    public var documents: [IDDocumentDTO]?
    public var departureItems: [DepartureCheckItemDTO]?
    public var voiceMemos: [VoiceMemoDTO]?
    public var vehicles: [VehicleDTO]?
    public var storedItems: [StoredItemDTO]?
    public var dialogueRecords: [DialogueRecordDTO]?
    public var rawMessages: [RawMessageDTO]?
    public var locationSamples: [LocationSampleDTO]?
}

// MARK: - DTO 模型定义

public struct TodoDTO: Codable {
    public var id: UUID
    public var typeRaw: String
    public var statusRaw: String
    public var title: String
    public var detail: String?
    public var pickupCode: String?
    public var courier: String?
    public var station: String?
    public var location: String?
    public var dueAt: Date?
    public var createdAt: Date
    public var completedAt: Date?
    public var sourceText: String?
    public var sortOrder: Int?
    public var recurrenceRuleRaw: String?
    public var recurrenceIntervalDays: Int?
    public var remindBeforeMinutes: Int?
    public var reminderOverrideAt: Date?
}

public struct SubscriptionDTO: Codable {
    public var id: UUID
    public var name: String
    public var priceString: String
    public var nextBillingDate: Date
    public var remindDaysBefore: Int
    public var isAutoRenew: Bool
    public var notes: String?
}

public struct ItemExpiryDTO: Codable {
    public var id: UUID
    public var title: String
    public var category: String
    public var expireDate: Date
    public var remindDaysBefore: Int
    public var isResolved: Bool
}

public struct AnniversaryDTO: Codable {
    public var id: UUID
    public var title: String
    public var category: String
    public var targetDate: Date
    public var isLunar: Bool
    public var remindDaysBefore: [Int]
    public var notes: String?
}

public struct PeriodicHabitDTO: Codable {
    public var id: UUID
    public var title: String
    public var detail: String?
    public var recurrenceRaw: String
    public var preferredHour: Int
    public var preferredMinute: Int
    public var lastCompletedAt: Date?
    public var nextDueAt: Date
    public var isEnabled: Bool
    public var triggerHomeKitScene: String?
}

public struct MedicationDTO: Codable {
    public var id: UUID
    public var medName: String
    public var dosage: String
    public var dailyTimePoints: [String]
    public var isEnabled: Bool
    public var notes: String?
}

public struct LearnedPlaceDTO: Codable {
    public var id: UUID
    public var name: String
    public var categoryRaw: String
    public var latitude: Double
    public var longitude: Double
    public var radiusMeters: Double
    public var associatedWiFiSSIDs: [String]
    public var visitCount: Int
    public var nightStayProbability: Double
    public var workdayDayStayProbability: Double
    public var isUserConfirmed: Bool
    public var lastVisitedAt: Date
}

public struct PasswordVaultDTO: Codable {
    public var id: UUID
    public var title: String
    public var account: String
    public var passwordEncrypted: String // 明文仅存在于整个备份的 AES-GCM 加密负载内
    public var category: String
    public var notes: String?
    public var lastRotatedAt: Date
    public var rotateCycleDays: Int
}

public struct DataUsageRecordDTO: Codable {
    public var id: UUID
    public var operatorName: String?
    public var remainingMB: Double?
    public var usedMB: Double?
    public var usedPercent: Double?
    public var recordedAt: Date
}

public struct ExpenseDTO: Codable {
    public var id: UUID
    public var amount: Double
    public var isIncome: Bool
    public var categoryRaw: String
    public var title: String
    public var rawText: String
    public var date: Date
    public var createdAt: Date
}

public struct IDDocumentDTO: Codable {
    public var id: UUID
    public var title: String
    public var typeRaw: String
    public var holderName: String?
    public var documentNumber: String?
    public var expiryDate: Date?
    public var isPermanent: Bool
    public var notes: String?
    public var frontImageData: Data?
    public var backImageData: Data?
    public var createdAt: Date
    public var updatedAt: Date
}

public struct DepartureCheckItemDTO: Codable {
    public var id: UUID
    public var title: String
    public var sceneRaw: String
    public var isChecked: Bool
    public var isEssential: Bool
    public var storageLocationNote: String?
    public var createdAt: Date
}

public struct VoiceMemoDTO: Codable {
    public var id: UUID
    public var title: String
    public var duration: Double
    public var audioFileName: String
    public var audioData: Data?
    public var transcription: String?
    public var summary: String?
    public var tagRaw: String
    public var isBookmarked: Bool
    public var createdAt: Date
}

public struct VehicleDTO: Codable {
    public var id: UUID
    public var name: String
    public var plateNumber: String
    public var powerTypeRaw: String
    public var energyCycleDays: Int
    public var lastEnergyRefillDate: Date?
    public var preferredEnergyHour: Int
    public var preferredEnergyMinute: Int
    public var maintenanceIntervalMonths: Int
    public var lastMaintenanceDate: Date?
    public var nextMaintenanceDate: Date
    public var insuranceExpiryDate: Date?
    public var annualInspectionDate: Date?
    public var currentMileage: Double?
    public var isReminderEnabled: Bool
    public var notes: String?
    public var createdAt: Date
}

public struct StoredItemDTO: Codable {
    public var id: UUID
    public var name: String
    public var location: String
    public var roomArea: String
    public var notes: String?
    public var imageData: Data?
    public var createdAt: Date
    public var updatedAt: Date
}

public struct DialogueRecordDTO: Codable {
    public var id: UUID
    public var roleRaw: String
    public var text: String
    public var timestamp: Date
    public var sessionID: UUID?
}

public struct RawMessageDTO: Codable {
    public var id: UUID
    public var source: String
    public var sender: String?
    public var content: String
    public var receivedAt: Date
    public var parseSummary: String?
}

public struct LocationSampleDTO: Codable {
    public var id: UUID
    public var latitude: Double
    public var longitude: Double
    public var wifiSSID: String?
    public var timestamp: Date
    public var hourOfDay: Int
    public var isWeekend: Bool
}

// MARK: - 备份解析报告

public struct BackupInspectionSummary: Identifiable {
    public var id = UUID()
    public var schemaVersion: Int
    public var exportedAt: Date
    public var deviceModel: String
    public var todoCount: Int
    public var subscriptionCount: Int
    public var itemExpiryCount: Int
    public var anniversaryCount: Int
    public var habitCount: Int
    public var medicationCount: Int
    public var placeCount: Int
    public var passwordCount: Int
    public var usageRecordCount: Int
    public var expenseCount: Int
    public var documentCount: Int
    public var departureItemCount: Int
    public var voiceMemoCount: Int = 0
    public var vehicleCount: Int = 0
    public var storedItemCount: Int = 0
    public var dialogueCount: Int = 0
    public var rawMessageCount: Int = 0
    public var locationSampleCount: Int = 0
    public var isEncryptedWithPIN: Bool = false

    public var totalItems: Int {
        todoCount + subscriptionCount + itemExpiryCount + anniversaryCount +
        habitCount + medicationCount + placeCount + passwordCount + usageRecordCount +
        expenseCount + documentCount + departureItemCount + voiceMemoCount +
        vehicleCount + storedItemCount + dialogueCount + rawMessageCount + locationSampleCount
    }
}

// MARK: - PIN 码加密迁移与封套定义

public enum MigrationCryptoError: LocalizedError {
    case pinTooShort
    case plaintextExportDisabled
    case incompleteLegacyBackup
    case missingAttachment(String)
    case persistenceFailure
    case pinMismatch
    case invalidPin
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
        case .corruptedData:
            return "备份数据文件损坏或已被篡改。"
        case .missingPin:
            return "请输入用于解锁该备份的 PIN 码。"
        }
    }
}

/// 端到端 AES-256-GCM 加密迁移数据包封套
public struct EncryptedBackupEnvelope: Codable {
    public static let magicTag = "ASSISTANT_ENCRYPTED_MIGRATION"
    public static let currentVersion = 2
    public static let defaultIterations = 310_000

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

public enum RestoreStrategy: String, CaseIterable, Identifiable {
    case merge = "智能合并 (保留现有并补充/更新)"
    case overwrite = "完全覆盖 (清空现有并还原备份)"

    public var id: String { rawValue }
}

public struct RestoreResultSummary {
    public var restoredCount: Int
    public var details: [String]
}

// MARK: - 数据迁移与管理服务

@MainActor
final class DataMigrationService {
    private let context: ModelContext

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
        let dataUsage = (try? context.fetchCount(FetchDescriptor<DataUsageRecord>())) ?? 0
        let expenses = (try? context.fetchCount(FetchDescriptor<ExpenseRecord>())) ?? 0
        let documents = (try? context.fetchCount(FetchDescriptor<IDDocumentItem>())) ?? 0
        let departures = (try? context.fetchCount(FetchDescriptor<DepartureCheckItem>())) ?? 0
        let voiceMemos = (try? context.fetchCount(FetchDescriptor<VoiceMemo>())) ?? 0
        let vehicles = (try? context.fetchCount(FetchDescriptor<VehicleProfile>())) ?? 0
        let storedItems = (try? context.fetchCount(FetchDescriptor<StoredItem>())) ?? 0
        let dialogueRecords = (try? context.fetchCount(FetchDescriptor<DialogueMessageRecord>())) ?? 0
        let rawMessages = (try? context.fetchCount(FetchDescriptor<RawMessage>())) ?? 0
        let locationSamples = (try? context.fetchCount(FetchDescriptor<LocationStaySample>())) ?? 0

        return [
            "待办事项": todos,
            "自动续费管理": subs,
            "临期预警": expiries,
            "纪念日与生日": anniversaries,
            "周期家务习惯": habits,
            "健康服药计划": meds,
            "空间感知地点": places,
            "离线安全密码": passwords,
            "流量历史记录": dataUsage,
            "日常记账明细": expenses,
            "重要证件卡包": documents,
            "随身防丢清单": departures,
            "语音备忘速记": voiceMemos,
            "爱车档案": vehicles,
            "物品收纳": storedItems,
            "对话历史": dialogueRecords,
            "原始消息": rawMessages,
            "位置采样": locationSamples
        ]
    }

    /// 构建全量数据包模型
    public func buildBackupPackage() throws -> BackupPackage {
        let todos = try context.fetch(FetchDescriptor<TodoItem>())
        let subs = try context.fetch(FetchDescriptor<SubscriptionItem>())
        let expiries = try context.fetch(FetchDescriptor<ItemExpiryItem>())
        let anniversaries = try context.fetch(FetchDescriptor<AnniversaryItem>())
        let habits = try context.fetch(FetchDescriptor<PeriodicHabit>())
        let meds = try context.fetch(FetchDescriptor<MedicationPlan>())
        let places = try context.fetch(FetchDescriptor<LearnedPlace>())
        let passwords = try context.fetch(FetchDescriptor<PasswordVaultItem>())
        let usages = try context.fetch(FetchDescriptor<DataUsageRecord>())
        let expenses = try context.fetch(FetchDescriptor<ExpenseRecord>())
        let documents = try context.fetch(FetchDescriptor<IDDocumentItem>())
        let departures = try context.fetch(FetchDescriptor<DepartureCheckItem>())
        let voiceMemos = try context.fetch(FetchDescriptor<VoiceMemo>())
        let vehicles = try context.fetch(FetchDescriptor<VehicleProfile>())
        let storedItems = try context.fetch(FetchDescriptor<StoredItem>())
        let dialogueRecords = try context.fetch(FetchDescriptor<DialogueMessageRecord>())
        let rawMessages = try context.fetch(FetchDescriptor<RawMessage>())
        let locationSamples = try context.fetch(FetchDescriptor<LocationStaySample>())

        let todoDTOs = todos.map {
            TodoDTO(
                id: $0.id, typeRaw: $0.typeRaw, statusRaw: $0.statusRaw,
                title: $0.title, detail: $0.detail, pickupCode: $0.pickupCode,
                courier: $0.courier, station: $0.station, location: $0.location,
                dueAt: $0.dueAt, createdAt: $0.createdAt, completedAt: $0.completedAt,
                sourceText: $0.sourceText,
                sortOrder: $0.sortOrder,
                recurrenceRuleRaw: $0.recurrenceRuleRaw,
                recurrenceIntervalDays: $0.recurrenceIntervalDays,
                remindBeforeMinutes: $0.remindBeforeMinutes,
                reminderOverrideAt: $0.reminderOverrideAt
            )
        }

        let subDTOs = subs.map {
            SubscriptionDTO(
                id: $0.id, name: $0.name, priceString: $0.priceString,
                nextBillingDate: $0.nextBillingDate, remindDaysBefore: $0.remindDaysBefore,
                isAutoRenew: $0.isAutoRenew, notes: $0.notes
            )
        }

        let expiryDTOs = expiries.map {
            ItemExpiryDTO(
                id: $0.id, title: $0.title, category: $0.category,
                expireDate: $0.expireDate, remindDaysBefore: $0.remindDaysBefore,
                isResolved: $0.isResolved
            )
        }

        let anniversaryDTOs = anniversaries.map {
            AnniversaryDTO(
                id: $0.id, title: $0.title, category: $0.category,
                targetDate: $0.targetDate, isLunar: $0.isLunar,
                remindDaysBefore: $0.remindDaysBefore, notes: $0.notes
            )
        }

        let habitDTOs = habits.map {
            PeriodicHabitDTO(
                id: $0.id, title: $0.title, detail: $0.detail,
                recurrenceRaw: $0.recurrenceRaw, preferredHour: $0.preferredHour,
                preferredMinute: $0.preferredMinute, lastCompletedAt: $0.lastCompletedAt,
                nextDueAt: $0.nextDueAt, isEnabled: $0.isEnabled,
                triggerHomeKitScene: $0.triggerHomeKitScene
            )
        }

        let medDTOs = meds.map {
            MedicationDTO(
                id: $0.id, medName: $0.medName, dosage: $0.dosage,
                dailyTimePoints: $0.dailyTimePoints, isEnabled: $0.isEnabled,
                notes: $0.notes
            )
        }

        let placeDTOs = places.map {
            LearnedPlaceDTO(
                id: $0.id, name: $0.name, categoryRaw: $0.categoryRaw,
                latitude: $0.latitude, longitude: $0.longitude,
                radiusMeters: $0.radiusMeters, associatedWiFiSSIDs: $0.associatedWiFiSSIDs,
                visitCount: $0.visitCount, nightStayProbability: $0.nightStayProbability,
                workdayDayStayProbability: $0.workdayDayStayProbability,
                isUserConfirmed: $0.isUserConfirmed, lastVisitedAt: $0.lastVisitedAt
            )
        }

        let pwdDTOs = try passwords.map {
            PasswordVaultDTO(
                id: $0.id, title: $0.title, account: $0.account,
                passwordEncrypted: try PasswordVaultCrypto.decrypt($0.passwordEncrypted), category: $0.category,
                notes: $0.notes, lastRotatedAt: $0.lastRotatedAt,
                rotateCycleDays: $0.rotateCycleDays
            )
        }

        let usageDTOs = usages.map {
            DataUsageRecordDTO(
                id: $0.id, operatorName: $0.operatorName,
                remainingMB: $0.remainingMB, usedMB: $0.usedMB,
                usedPercent: $0.usedPercent, recordedAt: $0.recordedAt
            )
        }

        let expenseDTOs = expenses.map {
            ExpenseDTO(
                id: $0.id, amount: $0.amount, isIncome: $0.isIncome,
                categoryRaw: $0.categoryRaw, title: $0.title,
                rawText: $0.rawText, date: $0.date, createdAt: $0.createdAt
            )
        }

        let documentDTOs = try documents.map { doc in
            let frontImg = IDPhotoStorage.loadImage(fileName: doc.frontImageFileName)
            let backImg = IDPhotoStorage.loadImage(fileName: doc.backImageFileName)
            if doc.frontImageFileName != nil && frontImg == nil { throw MigrationCryptoError.missingAttachment(doc.title) }
            if doc.backImageFileName != nil && backImg == nil { throw MigrationCryptoError.missingAttachment(doc.title) }
            return IDDocumentDTO(
                id: doc.id,
                title: doc.title,
                typeRaw: doc.typeRaw,
                holderName: doc.holderName,
                documentNumber: doc.documentNumber,
                expiryDate: doc.expiryDate,
                isPermanent: doc.isPermanent,
                notes: doc.notes,
                frontImageData: frontImg?.jpegData(compressionQuality: 0.88),
                backImageData: backImg?.jpegData(compressionQuality: 0.88),
                createdAt: doc.createdAt,
                updatedAt: doc.updatedAt
            )
        }

        let departureDTOs = departures.map {
            DepartureCheckItemDTO(
                id: $0.id,
                title: $0.title,
                sceneRaw: $0.sceneRaw,
                isChecked: $0.isChecked,
                isEssential: $0.isEssential,
                storageLocationNote: $0.storageLocationNote,
                createdAt: $0.createdAt
            )
        }

        let voiceMemoDTOs = try voiceMemos.map { memo in
            let audioData = VoiceMemoStorage.loadData(memo.audioFileName)
            guard audioData != nil else { throw MigrationCryptoError.missingAttachment(memo.title) }
            return VoiceMemoDTO(
                id: memo.id,
                title: memo.title,
                duration: memo.duration,
                audioFileName: memo.audioFileName,
                audioData: audioData,
                transcription: memo.transcription,
                summary: memo.summary,
                tagRaw: memo.tagRaw,
                isBookmarked: memo.isBookmarked,
                createdAt: memo.createdAt
            )
        }

        let vehicleDTOs = vehicles.map { v in
            VehicleDTO(id: v.id, name: v.name, plateNumber: v.plateNumber, powerTypeRaw: v.powerTypeRaw,
                       energyCycleDays: v.energyCycleDays, lastEnergyRefillDate: v.lastEnergyRefillDate,
                       preferredEnergyHour: v.preferredEnergyHour, preferredEnergyMinute: v.preferredEnergyMinute,
                       maintenanceIntervalMonths: v.maintenanceIntervalMonths, lastMaintenanceDate: v.lastMaintenanceDate,
                       nextMaintenanceDate: v.nextMaintenanceDate, insuranceExpiryDate: v.insuranceExpiryDate,
                       annualInspectionDate: v.annualInspectionDate, currentMileage: v.currentMileage,
                       isReminderEnabled: v.isReminderEnabled, notes: v.notes, createdAt: v.createdAt)
        }
        let storedItemDTOs = storedItems.map { item in
            StoredItemDTO(id: item.id, name: item.name, location: item.location, roomArea: item.roomArea,
                          notes: item.notes, imageData: item.imageData, createdAt: item.createdAt, updatedAt: item.updatedAt)
        }
        let dialogueDTOs = dialogueRecords.map { record in
            DialogueRecordDTO(id: record.id, roleRaw: record.roleRaw, text: record.text,
                              timestamp: record.timestamp, sessionID: record.sessionID)
        }
        let rawMessageDTOs = rawMessages.map { message in
            RawMessageDTO(id: message.id, source: message.source, sender: message.sender,
                          content: message.content, receivedAt: message.receivedAt, parseSummary: message.parseSummary)
        }
        let locationDTOs = locationSamples.map { sample in
            LocationSampleDTO(id: sample.id, latitude: sample.latitude, longitude: sample.longitude,
                              wifiSSID: sample.wifiSSID, timestamp: sample.timestamp,
                              hourOfDay: sample.hourOfDay, isWeekend: sample.isWeekend)
        }

        let metadata = BackupPackage.Metadata(
            schemaVersion: 2,
            appVersion: "0.1.0",
            exportedAt: Date.now,
            deviceModel: UIDevice.current.model
        )

        return BackupPackage(
            metadata: metadata,
            todos: todoDTOs,
            subscriptions: subDTOs,
            itemExpiries: expiryDTOs,
            anniversaries: anniversaryDTOs,
            habits: habitDTOs,
            medications: medDTOs,
            learnedPlaces: placeDTOs,
            passwords: pwdDTOs,
            dataUsageRecords: usageDTOs,
            expenses: expenseDTOs,
            documents: documentDTOs,
            departureItems: departureDTOs,
            voiceMemos: voiceMemoDTOs,
            vehicles: vehicleDTOs,
            storedItems: storedItemDTOs,
            dialogueRecords: dialogueDTOs,
            rawMessages: rawMessageDTOs,
            locationSamples: locationDTOs
        )
    }

    /// 从 PIN 码与盐值派生 AES-256 密钥
    private static func deriveLegacyKey(pin: String, salt: Data) -> SymmetricKey {
        let pinData = Data(pin.utf8)
        let inputKey = SymmetricKey(data: pinData)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: salt,
            info: Data("assistant.data.migration.aes256".utf8),
            outputByteCount: 32
        )
    }

    private static func deriveKey(pin: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        guard (100_000...2_000_000).contains(iterations) else { throw MigrationCryptoError.corruptedData }
        var derived = Data(count: 32)
        let status = pin.withCString { password in
            salt.withUnsafeBytes { saltBytes in
                derived.withUnsafeMutableBytes { keyBytes in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, pin.utf8.count,
                                       saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                       CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                       keyBytes.bindMemory(to: UInt8.self).baseAddress, 32)
                }
            }
        }
        guard status == kCCSuccess else { throw MigrationCryptoError.corruptedData }
        return SymmetricKey(data: derived)
    }

    /// 必须使用 PIN 码加密导出全量备份数据包
    public func exportEncryptedArchive(pin: String, hint: String? = nil) throws -> (data: Data, filename: String) {
        let cleanPin = pin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanPin.count >= 8 && cleanPin.count <= 64 else {
            throw MigrationCryptoError.pinTooShort
        }

        let package = try buildBackupPackage()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let packageData = try encoder.encode(package)

        // 生成 32 字节高熵随机盐
        let salt = SymmetricKey(size: .bits256)
        let saltData = salt.withUnsafeBytes { Data($0) }

        let symmetricKey = try Self.deriveKey(pin: cleanPin, salt: saltData, iterations: EncryptedBackupEnvelope.defaultIterations)
        let sealedBox = try AES.GCM.seal(packageData, using: symmetricKey)
        guard let combined = sealedBox.combined else {
            throw MigrationCryptoError.corruptedData
        }

        let envelope = EncryptedBackupEnvelope(
            saltBase64: saltData.base64EncodedString(),
            payloadBase64: combined.base64EncodedString(),
            exportedAt: package.metadata.exportedAt,
            deviceModel: package.metadata.deviceModel,
            appVersion: package.metadata.appVersion,
            hint: (hint?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? hint : nil
        )

        let envelopeEncoder = JSONEncoder()
        envelopeEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        envelopeEncoder.dateEncodingStrategy = .iso8601
        let envelopeData = try envelopeEncoder.encode(envelope)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: Date.now)
        let filename = "Assistant_Migration_\(timestamp).json"

        return (envelopeData, filename)
    }

    /// 兼容旧调用方，但拒绝生成含敏感数据的明文备份。
    public func exportArchive() throws -> (data: Data, filename: String) {
        throw MigrationCryptoError.plaintextExportDisabled
    }

    /// 构建摘要对象
    public func buildSummary(package: BackupPackage, isEncryptedWithPIN: Bool = false) -> BackupInspectionSummary {
        BackupInspectionSummary(
            schemaVersion: package.metadata.schemaVersion,
            exportedAt: package.metadata.exportedAt,
            deviceModel: package.metadata.deviceModel,
            todoCount: package.todos.count,
            subscriptionCount: package.subscriptions.count,
            itemExpiryCount: package.itemExpiries.count,
            anniversaryCount: package.anniversaries.count,
            habitCount: package.habits.count,
            medicationCount: package.medications.count,
            placeCount: package.learnedPlaces.count,
            passwordCount: package.passwords.count,
            usageRecordCount: package.dataUsageRecords.count,
            expenseCount: package.expenses?.count ?? 0,
            documentCount: package.documents?.count ?? 0,
            departureItemCount: package.departureItems?.count ?? 0,
            voiceMemoCount: package.voiceMemos?.count ?? 0,
            vehicleCount: package.vehicles?.count ?? 0,
            storedItemCount: package.storedItems?.count ?? 0,
            dialogueCount: package.dialogueRecords?.count ?? 0,
            rawMessageCount: package.rawMessages?.count ?? 0,
            locationSampleCount: package.locationSamples?.count ?? 0,
            isEncryptedWithPIN: isEncryptedWithPIN
        )
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

        let symmetricKey: SymmetricKey
        if envelope.version == 1 {
            symmetricKey = Self.deriveLegacyKey(pin: cleanPin, salt: saltData)
        } else if envelope.version == EncryptedBackupEnvelope.currentVersion {
            symmetricKey = try Self.deriveKey(pin: cleanPin, salt: saltData, iterations: envelope.iterations ?? EncryptedBackupEnvelope.defaultIterations)
        } else {
            throw MigrationCryptoError.corruptedData
        }

        do {
            let sealedBox = try AES.GCM.SealedBox(combined: combinedData)
            let decryptedData = try AES.GCM.open(sealedBox, using: symmetricKey)

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let package = try decoder.decode(BackupPackage.self, from: decryptedData)
            let summary = buildSummary(package: package, isEncryptedWithPIN: true)
            return (package, summary)
        } catch {
            throw MigrationCryptoError.invalidPin
        }
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

    /// 在覆盖本地数据库前验证备份结构，避免重复 ID 或损坏附件进入还原流程。
    private func validate(package: BackupPackage) throws {
        guard (1...2).contains(package.metadata.schemaVersion) else {
            throw MigrationCryptoError.corruptedData
        }
        if package.metadata.schemaVersion >= 2 {
            guard package.expenses != nil, package.documents != nil, package.departureItems != nil,
                  package.voiceMemos != nil, package.vehicles != nil, package.storedItems != nil,
                  package.dialogueRecords != nil, package.rawMessages != nil, package.locationSamples != nil else {
                throw MigrationCryptoError.corruptedData
            }
        }

        func requireUniqueIDs(_ ids: [UUID]) throws {
            guard Set(ids).count == ids.count else { throw MigrationCryptoError.corruptedData }
        }

        try requireUniqueIDs(package.todos.map(\.id))
        try requireUniqueIDs(package.subscriptions.map(\.id))
        try requireUniqueIDs(package.itemExpiries.map(\.id))
        try requireUniqueIDs(package.anniversaries.map(\.id))
        try requireUniqueIDs(package.habits.map(\.id))
        try requireUniqueIDs(package.medications.map(\.id))
        try requireUniqueIDs(package.learnedPlaces.map(\.id))
        try requireUniqueIDs(package.passwords.map(\.id))
        try requireUniqueIDs(package.dataUsageRecords.map(\.id))
        try requireUniqueIDs(package.expenses?.map(\.id) ?? [])
        try requireUniqueIDs(package.documents?.map(\.id) ?? [])
        try requireUniqueIDs(package.departureItems?.map(\.id) ?? [])
        try requireUniqueIDs(package.voiceMemos?.map(\.id) ?? [])
        try requireUniqueIDs(package.vehicles?.map(\.id) ?? [])
        try requireUniqueIDs(package.storedItems?.map(\.id) ?? [])
        try requireUniqueIDs(package.dialogueRecords?.map(\.id) ?? [])
        try requireUniqueIDs(package.rawMessages?.map(\.id) ?? [])
        try requireUniqueIDs(package.locationSamples?.map(\.id) ?? [])

        for document in package.documents ?? [] {
            if let data = document.frontImageData, UIImage(data: data) == nil {
                throw MigrationCryptoError.missingAttachment(document.title)
            }
            if let data = document.backImageData, UIImage(data: data) == nil {
                throw MigrationCryptoError.missingAttachment(document.title)
            }
        }
        for memo in package.voiceMemos ?? [] where memo.audioData == nil {
            throw MigrationCryptoError.missingAttachment(memo.title)
        }
    }

    /// 执行还原或合并数据
    public func restore(from package: BackupPackage, strategy: RestoreStrategy) throws -> RestoreResultSummary {
        try validate(package: package)
        guard strategy != .overwrite || package.metadata.schemaVersion >= 2 else {
            throw MigrationCryptoError.incompleteLegacyBackup
        }
        // 覆盖数据库前先验证备份负载与设备密钥，避免可预见的错误在删除后才暴露。
        var encryptedPasswords: [UUID: String] = [:]
        for password in package.passwords {
            guard encryptedPasswords[password.id] == nil else { throw MigrationCryptoError.corruptedData }
            encryptedPasswords[password.id] = try PasswordVaultCrypto.encrypt(password.passwordEncrypted)
        }
        do {
        if strategy == .overwrite {
            // 清理所有现有库中实体
            try context.delete(model: TodoItem.self)
            try context.delete(model: SubscriptionItem.self)
            try context.delete(model: ItemExpiryItem.self)
            try context.delete(model: AnniversaryItem.self)
            try context.delete(model: PeriodicHabit.self)
            try context.delete(model: MedicationPlan.self)
            try context.delete(model: LearnedPlace.self)
            try context.delete(model: PasswordVaultItem.self)
            try context.delete(model: DataUsageRecord.self)
            try context.delete(model: ExpenseRecord.self)
            try context.delete(model: IDDocumentItem.self)
            try context.delete(model: DepartureCheckItem.self)
            try context.delete(model: VoiceMemo.self)
            try context.delete(model: VehicleProfile.self)
            try context.delete(model: StoredItem.self)
            try context.delete(model: DialogueMessageRecord.self)
            try context.delete(model: RawMessage.self)
            try context.delete(model: LocationStaySample.self)
        }

        var details: [String] = []
        var totalRestored = 0

        // 1. 待办事项
        var restoredTodos = 0
        let existingTodoIDs = Set(try context.fetch(FetchDescriptor<TodoItem>()).map(\.id))
        for t in package.todos {
            if strategy == .merge && existingTodoIDs.contains(t.id) { continue }
            let item = TodoItem(
                type: TodoType(rawValue: t.typeRaw) ?? .general,
                status: TodoStatus(rawValue: t.statusRaw) ?? .active,
                title: t.title,
                detail: t.detail,
                pickupCode: t.pickupCode,
                courier: t.courier,
                station: t.station,
                location: t.location,
                dueAt: t.dueAt,
                sourceText: t.sourceText,
                sortOrder: t.sortOrder ?? 0,
                recurrenceRuleRaw: t.recurrenceRuleRaw,
                recurrenceIntervalDays: t.recurrenceIntervalDays ?? 0,
                remindBeforeMinutes: t.remindBeforeMinutes ?? 0
            )
            item.id = t.id
            item.createdAt = t.createdAt
            item.completedAt = t.completedAt
            item.reminderOverrideAt = t.reminderOverrideAt
            context.insert(item)
            restoredTodos += 1
        }
        details.append("待办事项: \(restoredTodos) 项")
        totalRestored += restoredTodos

        // 2. 订阅
        var restoredSubs = 0
        let existingSubIDs = Set(try context.fetch(FetchDescriptor<SubscriptionItem>()).map(\.id))
        for s in package.subscriptions {
            if strategy == .merge && existingSubIDs.contains(s.id) { continue }
            let item = SubscriptionItem(
                name: s.name, priceString: s.priceString,
                nextBillingDate: s.nextBillingDate, remindDaysBefore: s.remindDaysBefore,
                isAutoRenew: s.isAutoRenew, notes: s.notes
            )
            item.id = s.id
            context.insert(item)
            restoredSubs += 1
        }
        details.append("自动续费: \(restoredSubs) 项")
        totalRestored += restoredSubs

        // 3. 临期预警
        var restoredExpiries = 0
        let existingExpIDs = Set(try context.fetch(FetchDescriptor<ItemExpiryItem>()).map(\.id))
        for e in package.itemExpiries {
            if strategy == .merge && existingExpIDs.contains(e.id) { continue }
            let item = ItemExpiryItem(
                title: e.title, category: e.category,
                expireDate: e.expireDate, remindDaysBefore: e.remindDaysBefore
            )
            item.id = e.id
            item.isResolved = e.isResolved
            context.insert(item)
            restoredExpiries += 1
        }
        details.append("临期预警: \(restoredExpiries) 项")
        totalRestored += restoredExpiries

        // 4. 纪念日
        var restoredAnnis = 0
        let existingAnniIDs = Set(try context.fetch(FetchDescriptor<AnniversaryItem>()).map(\.id))
        for a in package.anniversaries {
            if strategy == .merge && existingAnniIDs.contains(a.id) { continue }
            let item = AnniversaryItem(
                title: a.title, category: a.category,
                targetDate: a.targetDate, isLunar: a.isLunar,
                remindDaysBefore: a.remindDaysBefore, notes: a.notes
            )
            item.id = a.id
            context.insert(item)
            restoredAnnis += 1
        }
        details.append("纪念日: \(restoredAnnis) 项")
        totalRestored += restoredAnnis

        // 5. 习惯与家务
        var restoredHabits = 0
        let existingHabitIDs = Set(try context.fetch(FetchDescriptor<PeriodicHabit>()).map(\.id))
        for h in package.habits {
            if strategy == .merge && existingHabitIDs.contains(h.id) { continue }
            let item = PeriodicHabit(
                title: h.title, detail: h.detail,
                recurrence: RecurrenceInterval(rawValue: h.recurrenceRaw) ?? .weekly,
                preferredHour: h.preferredHour, preferredMinute: h.preferredMinute,
                triggerHomeKitScene: h.triggerHomeKitScene
            )
            item.id = h.id
            item.lastCompletedAt = h.lastCompletedAt
            item.nextDueAt = h.nextDueAt
            item.isEnabled = h.isEnabled
            context.insert(item)
            restoredHabits += 1
        }
        details.append("习惯与家务: \(restoredHabits) 项")
        totalRestored += restoredHabits

        // 6. 服药计划
        var restoredMeds = 0
        let existingMedIDs = Set(try context.fetch(FetchDescriptor<MedicationPlan>()).map(\.id))
        for m in package.medications {
            if strategy == .merge && existingMedIDs.contains(m.id) { continue }
            let item = MedicationPlan(
                medName: m.medName, dosage: m.dosage,
                dailyTimePoints: m.dailyTimePoints, notes: m.notes
            )
            item.id = m.id
            item.isEnabled = m.isEnabled
            context.insert(item)
            restoredMeds += 1
        }
        details.append("服药计划: \(restoredMeds) 项")
        totalRestored += restoredMeds

        // 7. 密码
        var restoredPwds = 0
        let existingPwdIDs = Set(try context.fetch(FetchDescriptor<PasswordVaultItem>()).map(\.id))
        for p in package.passwords {
            if strategy == .merge && existingPwdIDs.contains(p.id) { continue }
            guard let encryptedPassword = encryptedPasswords[p.id] else { throw MigrationCryptoError.corruptedData }
            let item = PasswordVaultItem(
                title: p.title, account: p.account,
                passwordEncrypted: encryptedPassword, category: p.category,
                notes: p.notes, lastRotatedAt: p.lastRotatedAt,
                rotateCycleDays: p.rotateCycleDays
            )
            item.id = p.id
            context.insert(item)
            restoredPwds += 1
        }
        details.append("离线密码: \(restoredPwds) 项")
        totalRestored += restoredPwds

        // 8. 地点档案
        var restoredPlaces = 0
        let existingPlaceIDs = Set(try context.fetch(FetchDescriptor<LearnedPlace>()).map(\.id))
        for pl in package.learnedPlaces {
            if strategy == .merge && existingPlaceIDs.contains(pl.id) { continue }
            let item = LearnedPlace(
                name: pl.name,
                category: PlaceCategory(rawValue: pl.categoryRaw) ?? .other,
                latitude: pl.latitude,
                longitude: pl.longitude,
                radiusMeters: pl.radiusMeters,
                associatedWiFiSSIDs: pl.associatedWiFiSSIDs,
                visitCount: pl.visitCount,
                nightStayProbability: pl.nightStayProbability,
                workdayDayStayProbability: pl.workdayDayStayProbability,
                isUserConfirmed: pl.isUserConfirmed
            )
            item.id = pl.id
            item.lastVisitedAt = pl.lastVisitedAt
            context.insert(item)
            restoredPlaces += 1
        }
        details.append("常驻地点: \(restoredPlaces) 项")
        totalRestored += restoredPlaces

        // 9. 流量历史
        var restoredUsage = 0
        let existingUsageIDs = Set(try context.fetch(FetchDescriptor<DataUsageRecord>()).map(\.id))
        for u in package.dataUsageRecords {
            if strategy == .merge && existingUsageIDs.contains(u.id) { continue }
            let item = DataUsageRecord(
                operatorName: u.operatorName,
                remainingMB: u.remainingMB,
                usedMB: u.usedMB,
                usedPercent: u.usedPercent,
                recordedAt: u.recordedAt
            )
            item.id = u.id
            context.insert(item)
            restoredUsage += 1
        }
        details.append("流量记录: \(restoredUsage) 项")
        totalRestored += restoredUsage

        // 10. 收支记账
        var restoredExpenses = 0
        let existingExpenseIDs = Set(try context.fetch(FetchDescriptor<ExpenseRecord>()).map(\.id))
        for ex in package.expenses ?? [] {
            if strategy == .merge && existingExpenseIDs.contains(ex.id) { continue }
            let item = ExpenseRecord(
                amount: ex.amount,
                isIncome: ex.isIncome,
                category: ExpenseCategory(rawValue: ex.categoryRaw) ?? (ex.isIncome ? .otherIncome : .other),
                title: ex.title,
                rawText: ex.rawText,
                date: ex.date
            )
            item.id = ex.id
            item.createdAt = ex.createdAt
            context.insert(item)
            restoredExpenses += 1
        }
        details.append("日常记账: \(restoredExpenses) 项")
        totalRestored += restoredExpenses

        // 11. 重要证件
        var restoredDocs = 0
        let existingDocIDs = Set(try context.fetch(FetchDescriptor<IDDocumentItem>()).map(\.id))
        for d in package.documents ?? [] {
            if strategy == .merge && existingDocIDs.contains(d.id) { continue }
            var frontFileName: String? = nil
            if let frontData = d.frontImageData {
                guard let image = UIImage(data: frontData) else { throw MigrationCryptoError.missingAttachment(d.title) }
                frontFileName = IDPhotoStorage.saveImage(image)
                guard frontFileName != nil else { throw MigrationCryptoError.missingAttachment(d.title) }
            }
            var backFileName: String? = nil
            if let backData = d.backImageData {
                guard let image = UIImage(data: backData) else { throw MigrationCryptoError.missingAttachment(d.title) }
                backFileName = IDPhotoStorage.saveImage(image)
                guard backFileName != nil else { throw MigrationCryptoError.missingAttachment(d.title) }
            }
            let item = IDDocumentItem(
                title: d.title,
                type: IDDocumentType(rawValue: d.typeRaw) ?? .other,
                holderName: d.holderName,
                documentNumber: d.documentNumber,
                expiryDate: d.expiryDate,
                isPermanent: d.isPermanent,
                frontImageFileName: frontFileName,
                backImageFileName: backFileName,
                notes: d.notes
            )
            item.id = d.id
            item.createdAt = d.createdAt
            item.updatedAt = d.updatedAt
            context.insert(item)
            restoredDocs += 1
        }
        details.append("重要证件: \(restoredDocs) 项")
        totalRestored += restoredDocs

        // 12. 出门防丢装备清单
        var restoredDepartures = 0
        let existingDepartureIDs = Set(try context.fetch(FetchDescriptor<DepartureCheckItem>()).map(\.id))
        for dep in package.departureItems ?? [] {
            if strategy == .merge && existingDepartureIDs.contains(dep.id) { continue }
            let item = DepartureCheckItem(
                title: dep.title,
                scene: DepartureScene(rawValue: dep.sceneRaw) ?? .commute,
                isEssential: dep.isEssential,
                storageLocationNote: dep.storageLocationNote,
                isChecked: dep.isChecked
            )
            item.id = dep.id
            item.createdAt = dep.createdAt
            context.insert(item)
            restoredDepartures += 1
        }
        details.append("随身防丢: \(restoredDepartures) 项")
        totalRestored += restoredDepartures

        // 13. 语音备忘录
        var restoredVoiceMemos = 0
        let existingVoiceMemoIDs = Set(try context.fetch(FetchDescriptor<VoiceMemo>()).map(\.id))
        for vm in package.voiceMemos ?? [] {
            if strategy == .merge && existingVoiceMemoIDs.contains(vm.id) { continue }

            var actualAudioFileName = vm.audioFileName
            if let audioData = vm.audioData {
                if let savedName = VoiceMemoStorage.save(data: audioData, preferredName: vm.audioFileName) {
                    actualAudioFileName = savedName
                } else {
                    throw MigrationCryptoError.missingAttachment(vm.title)
                }
            } else if package.metadata.schemaVersion >= 2 {
                throw MigrationCryptoError.missingAttachment(vm.title)
            }

            let item = VoiceMemo(
                title: vm.title,
                duration: vm.duration,
                audioFileName: actualAudioFileName,
                tag: VoiceMemoTag(rawValue: vm.tagRaw) ?? .other,
                createdAt: vm.createdAt
            )
            item.id = vm.id
            item.transcription = vm.transcription
            item.summary = vm.summary
            item.isBookmarked = vm.isBookmarked
            context.insert(item)
            restoredVoiceMemos += 1
        }
        details.append("语音备忘: \(restoredVoiceMemos) 项")
        totalRestored += restoredVoiceMemos

        let existingVehicleIDs = Set(try context.fetch(FetchDescriptor<VehicleProfile>()).map(\.id))
        var restoredVehicles = 0
        for v in package.vehicles ?? [] {
            if strategy == .merge && existingVehicleIDs.contains(v.id) { continue }
            let item = VehicleProfile(name: v.name, plateNumber: v.plateNumber,
                                      powerType: VehiclePowerType(rawValue: v.powerTypeRaw) ?? .gasoline,
                                      energyCycleDays: v.energyCycleDays, preferredEnergyHour: v.preferredEnergyHour,
                                      preferredEnergyMinute: v.preferredEnergyMinute,
                                      maintenanceIntervalMonths: v.maintenanceIntervalMonths,
                                      insuranceExpiryDate: v.insuranceExpiryDate,
                                      annualInspectionDate: v.annualInspectionDate,
                                      currentMileage: v.currentMileage, notes: v.notes)
            item.id = v.id
            item.lastEnergyRefillDate = v.lastEnergyRefillDate
            item.lastMaintenanceDate = v.lastMaintenanceDate
            item.nextMaintenanceDate = v.nextMaintenanceDate
            item.isReminderEnabled = v.isReminderEnabled
            item.createdAt = v.createdAt
            context.insert(item)
            restoredVehicles += 1
        }
        details.append("爱车档案: \(restoredVehicles) 项")
        totalRestored += restoredVehicles

        let existingStoredIDs = Set(try context.fetch(FetchDescriptor<StoredItem>()).map(\.id))
        var restoredStoredItems = 0
        for s in package.storedItems ?? [] {
            if strategy == .merge && existingStoredIDs.contains(s.id) { continue }
            let item = StoredItem(name: s.name, location: s.location, roomArea: s.roomArea,
                                  notes: s.notes, imageData: s.imageData)
            item.id = s.id
            item.createdAt = s.createdAt
            item.updatedAt = s.updatedAt
            context.insert(item)
            restoredStoredItems += 1
        }
        details.append("物品收纳: \(restoredStoredItems) 项")
        totalRestored += restoredStoredItems

        let existingDialogueIDs = Set(try context.fetch(FetchDescriptor<DialogueMessageRecord>()).map(\.id))
        var restoredDialogues = 0
        for d in package.dialogueRecords ?? [] {
            if strategy == .merge && existingDialogueIDs.contains(d.id) { continue }
            context.insert(DialogueMessageRecord(id: d.id, role: d.roleRaw, text: d.text,
                                                 timestamp: d.timestamp, sessionID: d.sessionID))
            restoredDialogues += 1
        }
        details.append("对话历史: \(restoredDialogues) 项")
        totalRestored += restoredDialogues

        let existingMessageIDs = Set(try context.fetch(FetchDescriptor<RawMessage>()).map(\.id))
        var restoredMessages = 0
        for m in package.rawMessages ?? [] {
            if strategy == .merge && existingMessageIDs.contains(m.id) { continue }
            let item = RawMessage(source: m.source, sender: m.sender, content: m.content)
            item.id = m.id
            item.receivedAt = m.receivedAt
            item.parseSummary = m.parseSummary
            context.insert(item)
            restoredMessages += 1
        }
        details.append("原始消息: \(restoredMessages) 项")
        totalRestored += restoredMessages

        let existingSampleIDs = Set(try context.fetch(FetchDescriptor<LocationStaySample>()).map(\.id))
        var restoredSamples = 0
        for s in package.locationSamples ?? [] {
            if strategy == .merge && existingSampleIDs.contains(s.id) { continue }
            let item = LocationStaySample(latitude: s.latitude, longitude: s.longitude,
                                          wifiSSID: s.wifiSSID, timestamp: s.timestamp)
            item.id = s.id
            item.hourOfDay = s.hourOfDay
            item.isWeekend = s.isWeekend
            context.insert(item)
            restoredSamples += 1
        }
        details.append("位置采样: \(restoredSamples) 项")
        totalRestored += restoredSamples

        try context.save()
        return RestoreResultSummary(restoredCount: totalRestored, details: details)
        } catch {
            context.rollback()
            throw error
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
