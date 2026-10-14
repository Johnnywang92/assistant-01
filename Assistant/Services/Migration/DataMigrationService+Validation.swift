import Foundation
import UIKit

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
    public var skillPathCount: Int = 0
    public var skillStageCount: Int = 0
    public var practiceLogCount: Int = 0
    public var petCount: Int = 0
    public var childCount: Int = 0
    public var childGrowthCount: Int = 0
    public var childMilestoneCount: Int = 0
    public var childHealthVisitCount: Int = 0
    public var childVaccinationCount: Int = 0
    public var reminderActionCount: Int = 0
    public var lifeEventProjectCount: Int = 0
    public var lifeEventStageCount: Int = 0
    public var lifeEventTaskCount: Int = 0
    public var lifeEventPersonCount: Int = 0
    public var lifeEventExpenseCount: Int = 0
    public var lifeEventGuestCount: Int = 0
    public var omniboxTransactionCount: Int = 0
    public var settingsKeyCount: Int = 0
    public var isEncryptedWithPIN: Bool = false

    public var totalItems: Int {
        todoCount + subscriptionCount + itemExpiryCount + anniversaryCount +
        habitCount + medicationCount + placeCount + passwordCount + usageRecordCount +
        expenseCount + documentCount + departureItemCount + voiceMemoCount +
        vehicleCount + storedItemCount + dialogueCount + rawMessageCount + locationSampleCount +
        skillPathCount + skillStageCount + practiceLogCount +
        petCount + childCount + childGrowthCount + childMilestoneCount +
        childHealthVisitCount + childVaccinationCount + reminderActionCount +
        lifeEventProjectCount + lifeEventStageCount + lifeEventTaskCount +
        lifeEventPersonCount + lifeEventExpenseCount + lifeEventGuestCount +
        omniboxTransactionCount + settingsKeyCount
    }
}

extension DataMigrationService {
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
            skillPathCount: package.skillPaths?.count ?? 0,
            skillStageCount: package.skillStages?.count ?? 0,
            practiceLogCount: package.practiceLogs?.count ?? 0,
            petCount: package.pets?.count ?? 0,
            childCount: package.children?.count ?? 0,
            childGrowthCount: package.childGrowthRecords?.count ?? 0,
            childMilestoneCount: package.childMilestones?.count ?? 0,
            childHealthVisitCount: package.childHealthVisits?.count ?? 0,
            childVaccinationCount: package.childVaccinations?.count ?? 0,
            reminderActionCount: package.reminderActions?.count ?? 0,
            lifeEventProjectCount: package.lifeEventProjects?.count ?? 0,
            lifeEventStageCount: package.lifeEventStages?.count ?? 0,
            lifeEventTaskCount: package.lifeEventTasks?.count ?? 0,
            lifeEventPersonCount: package.lifeEventPeople?.count ?? 0,
            lifeEventExpenseCount: package.lifeEventExpenses?.count ?? 0,
            lifeEventGuestCount: package.lifeEventGuests?.count ?? 0,
            omniboxTransactionCount: package.omniboxTransactions?.count ?? 0,
            settingsKeyCount: package.settings?.itemCount ?? 0,
            isEncryptedWithPIN: isEncryptedWithPIN
        )
    }

    /// 在覆盖本地数据库前验证备份结构，避免重复 ID 或损坏附件进入还原流程。
    func validate(package: BackupPackage) throws {
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
        try requireUniqueIDs(package.skillPaths?.map(\.id) ?? [])
        try requireUniqueIDs(package.skillStages?.map(\.id) ?? [])
        try requireUniqueIDs(package.practiceLogs?.map(\.id) ?? [])
        try requireUniqueIDs(package.pets?.map(\.id) ?? [])
        try requireUniqueIDs(package.children?.map(\.id) ?? [])
        try requireUniqueIDs(package.childGrowthRecords?.map(\.id) ?? [])
        try requireUniqueIDs(package.childMilestones?.map(\.id) ?? [])
        try requireUniqueIDs(package.childHealthVisits?.map(\.id) ?? [])
        try requireUniqueIDs(package.childVaccinations?.map(\.id) ?? [])
        try requireUniqueIDs(package.reminderActions?.map(\.id) ?? [])
        try requireUniqueIDs(package.lifeEventProjects?.map(\.id) ?? [])
        try requireUniqueIDs(package.lifeEventStages?.map(\.id) ?? [])
        try requireUniqueIDs(package.lifeEventTasks?.map(\.id) ?? [])
        try requireUniqueIDs(package.lifeEventPeople?.map(\.id) ?? [])
        try requireUniqueIDs(package.lifeEventExpenses?.map(\.id) ?? [])
        try requireUniqueIDs(package.lifeEventGuests?.map(\.id) ?? [])
        try requireUniqueIDs(package.omniboxTransactions?.map(\.id) ?? [])

        // 阶段与打卡流水必须挂到已备份的路径上，否则还原后成孤儿数据
        if let stages = package.skillStages {
            let pathIDs = Set(package.skillPaths?.map(\.id) ?? [])
            guard stages.allSatisfy({ pathIDs.contains($0.pathID) }) else {
                throw MigrationCryptoError.corruptedData
            }
        }
        if let logs = package.practiceLogs {
            let pathIDs = Set(package.skillPaths?.map(\.id) ?? [])
            guard logs.allSatisfy({ pathIDs.contains($0.pathID) }) else {
                throw MigrationCryptoError.corruptedData
            }
        }

        // 子表外键同理：宝贝记录指向已备份的宝贝、大事子表指向已备份的项目/阶段，防损坏包还原出孤儿数据
        // childID 为 nil 表示库中本就游离的记录，忠实保留，不算悬挂
        let childIDs = Set(package.children?.map(\.id) ?? [])
        let referencedChildIDs = (package.childGrowthRecords ?? []).compactMap(\.childID)
            + (package.childMilestones ?? []).compactMap(\.childID)
            + (package.childHealthVisits ?? []).compactMap(\.childID)
            + (package.childVaccinations ?? []).compactMap(\.childID)
        guard referencedChildIDs.allSatisfy(childIDs.contains) else {
            throw MigrationCryptoError.corruptedData
        }

        let eventProjectIDs = Set(package.lifeEventProjects?.map(\.id) ?? [])
        if let stages = package.lifeEventStages {
            guard stages.allSatisfy({ eventProjectIDs.contains($0.projectID) }) else {
                throw MigrationCryptoError.corruptedData
            }
        }
        if let tasks = package.lifeEventTasks {
            let stageIDs = Set(package.lifeEventStages?.map(\.id) ?? [])
            guard tasks.allSatisfy({ eventProjectIDs.contains($0.projectID) && stageIDs.contains($0.stageID) }) else {
                throw MigrationCryptoError.corruptedData
            }
        }
        if let people = package.lifeEventPeople {
            guard people.allSatisfy({ eventProjectIDs.contains($0.projectID) }) else {
                throw MigrationCryptoError.corruptedData
            }
        }
        if let expenses = package.lifeEventExpenses {
            guard expenses.allSatisfy({ eventProjectIDs.contains($0.projectID) }) else {
                throw MigrationCryptoError.corruptedData
            }
        }
        if let guests = package.lifeEventGuests {
            guard guests.allSatisfy({ eventProjectIDs.contains($0.projectID) }) else {
                throw MigrationCryptoError.corruptedData
            }
        }

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
}
