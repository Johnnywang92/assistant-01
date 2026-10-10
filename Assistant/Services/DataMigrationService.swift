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
    public var passwordEncrypted: String
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

    public var totalItems: Int {
        todoCount + subscriptionCount + itemExpiryCount + anniversaryCount +
        habitCount + medicationCount + placeCount + passwordCount + usageRecordCount +
        expenseCount + documentCount + departureItemCount
    }
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
            "随身防丢清单": departures
        ]
    }

    /// 导出为 JSON 格式数据
    public func exportArchive() throws -> (data: Data, filename: String) {
        let todos = (try? context.fetch(FetchDescriptor<TodoItem>())) ?? []
        let subs = (try? context.fetch(FetchDescriptor<SubscriptionItem>())) ?? []
        let expiries = (try? context.fetch(FetchDescriptor<ItemExpiryItem>())) ?? []
        let anniversaries = (try? context.fetch(FetchDescriptor<AnniversaryItem>())) ?? []
        let habits = (try? context.fetch(FetchDescriptor<PeriodicHabit>())) ?? []
        let meds = (try? context.fetch(FetchDescriptor<MedicationPlan>())) ?? []
        let places = (try? context.fetch(FetchDescriptor<LearnedPlace>())) ?? []
        let passwords = (try? context.fetch(FetchDescriptor<PasswordVaultItem>())) ?? []
        let usages = (try? context.fetch(FetchDescriptor<DataUsageRecord>())) ?? []
        let expenses = (try? context.fetch(FetchDescriptor<ExpenseRecord>())) ?? []
        let documents = (try? context.fetch(FetchDescriptor<IDDocumentItem>())) ?? []
        let departures = (try? context.fetch(FetchDescriptor<DepartureCheckItem>())) ?? []

        let todoDTOs = todos.map {
            TodoDTO(
                id: $0.id, typeRaw: $0.typeRaw, statusRaw: $0.statusRaw,
                title: $0.title, detail: $0.detail, pickupCode: $0.pickupCode,
                courier: $0.courier, station: $0.station, location: $0.location,
                dueAt: $0.dueAt, createdAt: $0.createdAt, completedAt: $0.completedAt,
                sourceText: $0.sourceText
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

        let pwdDTOs = passwords.map {
            PasswordVaultDTO(
                id: $0.id, title: $0.title, account: $0.account,
                passwordEncrypted: $0.passwordEncrypted, category: $0.category,
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

        let documentDTOs = documents.map { doc in
            let frontImg = IDPhotoStorage.loadImage(fileName: doc.frontImageFileName)
            let backImg = IDPhotoStorage.loadImage(fileName: doc.backImageFileName)
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

        let metadata = BackupPackage.Metadata(
            schemaVersion: 1,
            appVersion: "0.1.0",
            exportedAt: Date.now,
            deviceModel: UIDevice.current.model
        )

        let package = BackupPackage(
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
            departureItems: departureDTOs
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(package)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: Date.now)
        let filename = "Assistant_Backup_\(timestamp).json"

        return (data, filename)
    }

    /// 校验并预览备份文件内容
    public func inspectArchive(from data: Data) throws -> (package: BackupPackage, summary: BackupInspectionSummary) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let package = try decoder.decode(BackupPackage.self, from: data)

        let summary = BackupInspectionSummary(
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
            departureItemCount: package.departureItems?.count ?? 0
        )

        return (package, summary)
    }

    /// 执行还原或合并数据
    public func restore(from package: BackupPackage, strategy: RestoreStrategy) throws -> RestoreResultSummary {
        if strategy == .overwrite {
            // 清理所有现有库中实体
            try? context.delete(model: TodoItem.self)
            try? context.delete(model: SubscriptionItem.self)
            try? context.delete(model: ItemExpiryItem.self)
            try? context.delete(model: AnniversaryItem.self)
            try? context.delete(model: PeriodicHabit.self)
            try? context.delete(model: MedicationPlan.self)
            try? context.delete(model: LearnedPlace.self)
            try? context.delete(model: PasswordVaultItem.self)
            try? context.delete(model: DataUsageRecord.self)
            try? context.delete(model: ExpenseRecord.self)
            try? context.delete(model: IDDocumentItem.self)
            try? context.delete(model: DepartureCheckItem.self)
        }

        var details: [String] = []
        var totalRestored = 0

        // 1. 待办事项
        var restoredTodos = 0
        let existingTodoIDs = Set(((try? context.fetch(FetchDescriptor<TodoItem>())) ?? []).map { $0.id })
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
                sourceText: t.sourceText
            )
            item.id = t.id
            item.createdAt = t.createdAt
            item.completedAt = t.completedAt
            context.insert(item)
            restoredTodos += 1
        }
        details.append("待办事项: \(restoredTodos) 项")
        totalRestored += restoredTodos

        // 2. 订阅
        var restoredSubs = 0
        let existingSubIDs = Set(((try? context.fetch(FetchDescriptor<SubscriptionItem>())) ?? []).map { $0.id })
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
        let existingExpIDs = Set(((try? context.fetch(FetchDescriptor<ItemExpiryItem>())) ?? []).map { $0.id })
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
        let existingAnniIDs = Set(((try? context.fetch(FetchDescriptor<AnniversaryItem>())) ?? []).map { $0.id })
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
        let existingHabitIDs = Set(((try? context.fetch(FetchDescriptor<PeriodicHabit>())) ?? []).map { $0.id })
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
        let existingMedIDs = Set(((try? context.fetch(FetchDescriptor<MedicationPlan>())) ?? []).map { $0.id })
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
        let existingPwdIDs = Set(((try? context.fetch(FetchDescriptor<PasswordVaultItem>())) ?? []).map { $0.id })
        for p in package.passwords {
            if strategy == .merge && existingPwdIDs.contains(p.id) { continue }
            let item = PasswordVaultItem(
                title: p.title, account: p.account,
                passwordEncrypted: p.passwordEncrypted, category: p.category,
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
        let existingPlaceIDs = Set(((try? context.fetch(FetchDescriptor<LearnedPlace>())) ?? []).map { $0.id })
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
        let existingUsageIDs = Set(((try? context.fetch(FetchDescriptor<DataUsageRecord>())) ?? []).map { $0.id })
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
        let existingExpenseIDs = Set(((try? context.fetch(FetchDescriptor<ExpenseRecord>())) ?? []).map { $0.id })
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
        let existingDocIDs = Set(((try? context.fetch(FetchDescriptor<IDDocumentItem>())) ?? []).map { $0.id })
        for d in package.documents ?? [] {
            if strategy == .merge && existingDocIDs.contains(d.id) { continue }
            var frontFileName: String? = nil
            if let frontData = d.frontImageData, let image = UIImage(data: frontData) {
                frontFileName = IDPhotoStorage.saveImage(image)
            }
            var backFileName: String? = nil
            if let backData = d.backImageData, let image = UIImage(data: backData) {
                backFileName = IDPhotoStorage.saveImage(image)
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
        let existingDepartureIDs = Set(((try? context.fetch(FetchDescriptor<DepartureCheckItem>())) ?? []).map { $0.id })
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

        try context.save()
        return RestoreResultSummary(restoredCount: totalRestored, details: details)
    }

    // MARK: - 外部纯文本 / CSV 批量导入

    /// 批量导入纪念日（格式：名称, 日期(yyyy-MM-dd), 分类(可选), 备注(可选)）
    public func batchImportAnniversaries(text: String) -> Int {
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

        try? context.save()
        return count
    }

    /// 批量导入密码 CSV（兼容通用 CSV 格式：标题, 账号, 密码, 分类, 备注）
    public func batchImportPasswords(text: String) -> Int {
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

            let item = PasswordVaultItem(
                title: title,
                account: account,
                passwordEncrypted: password,
                category: category,
                notes: notes
            )
            context.insert(item)
            count += 1
        }

        try? context.save()
        return count
    }

    /// 批量导入待办事项（每行一条）
    public func batchImportTodos(text: String) -> Int {
        let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var count = 0

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let item = TodoItem(type: .general, status: .active, title: trimmed)
            context.insert(item)
            count += 1
        }

        try? context.save()
        return count
    }
}
