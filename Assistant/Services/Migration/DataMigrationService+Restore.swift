import Foundation
import SwiftData
import UIKit
import AssistantCore

public enum RestoreStrategy: String, CaseIterable, Identifiable {
    case merge = "智能合并 (保留现有并补充/更新)"
    case overwrite = "完全覆盖 (清空现有并还原备份)"

    public var id: String { rawValue }
}

public struct RestoreResultSummary {
    public var restoredCount: Int
    public var details: [String]
}

extension DataMigrationService {
    /// 还原偏好设置（仅覆盖策略调用：合并策略保留本机设置，只搬数据不改行为）。
    /// 写盘后必须让各单例重载，否则内存里还是旧值。
    private func applySettingsSnapshot(_ snapshot: SettingsSnapshotDTO) {
        snapshot.apply(to: UserDefaults.standard)

        if let imageData = snapshot.wallpaperImageData {
            AppBackgroundManager.shared.restoreCustomImage(data: imageData)
        } else {
            AppBackgroundManager.shared.reloadFromDefaults()
            // 备份里没有壁纸字节却标记了自定义图片：样式回落系统，
            // 避免设置页显示「自定义照片」而实际渲染的是系统底色
            if AppBackgroundManager.shared.currentStyle == .customImage,
               AppBackgroundManager.shared.customImage == nil {
                AppBackgroundManager.shared.currentStyle = .system
            }
        }
        TabBarManager.shared.reloadFromDefaults()

        // 语言走 setter：同步 AppleLanguages 与本地化缓存，并刷新桌面快捷菜单
        if case .string(let raw)? = snapshot.entries[AssistantSettingsKeys.languagePreference],
           let language = AppLanguage(rawValue: raw) {
            LanguageManager.shared.selectedLanguage = language
        }
    }

    /// 执行还原或合并数据
    public func restore(from package: BackupPackage, strategy: RestoreStrategy) throws -> RestoreResultSummary {
        try validate(package: package)
        guard strategy != .overwrite || package.metadata.schemaVersion >= 2 else {
            throw MigrationCryptoError.incompleteLegacyBackup
        }
        // 附件预检：必须在清库之前完成。
        // 旧版导出可能静默丢过语音音频，带着这种缺口进还原流程，
        // 结果是「记录在、音频没了」的残缺数据——用户却以为还原成功了。
        let packageAttachmentExpectations = (package.voiceMemos ?? []).map { memo in
            BackupRestoreGuard.AttachmentExpectation(
                ownerTitle: memo.title,
                kind: .voiceMemoAudio,
                fileName: memo.audioFileName.isEmpty ? nil : memo.audioFileName,
                hasData: memo.audioData?.isEmpty == false
            )
        }
        var missingAttachmentLabels: [String] = []
        if case .incomplete(let missing) = BackupRestoreGuard.auditAttachments(packageAttachmentExpectations) {
            missingAttachmentLabels = BackupRestoreGuard.describeMissingAttachments(missing)
            // 覆盖还原会清空现有数据：包里已知有缺口时不做破坏性操作，
            // 否则用户会先丢掉现有数据、再发现备份本身不完整。
            if strategy == .overwrite {
                throw MigrationCryptoError.missingAttachment(missingAttachmentLabels.joined(separator: "、"))
            }
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
            try context.delete(model: MedicineItem.self)
            try context.delete(model: DialogueMessageRecord.self)
            try context.delete(model: RawMessage.self)
            try context.delete(model: LocationStaySample.self)
            try context.delete(model: SkillPath.self)
            try context.delete(model: SkillStage.self)
            try context.delete(model: SkillPracticeLog.self)
            try context.delete(model: PetProfile.self)
            try context.delete(model: ChildProfile.self)
            try context.delete(model: ChildGrowthRecord.self)
            try context.delete(model: ChildMilestoneRecord.self)
            try context.delete(model: ChildHealthVisitRecord.self)
            try context.delete(model: ChildVaccinationRecord.self)
            try context.delete(model: LifeReminderAction.self)
            try context.delete(model: LifeEventProject.self)
            try context.delete(model: LifeEventStage.self)
            try context.delete(model: LifeEventTask.self)
            try context.delete(model: LifeEventPerson.self)
            try context.delete(model: LifeEventExpense.self)
            try context.delete(model: LifeEventGuest.self)
            try context.delete(model: OmniboxTransaction.self)
            try context.delete(model: FoodIntakeRecord.self)
            try context.delete(model: WaterIntakeRecord.self)
            try context.delete(model: OmniboxJudgmentFeedback.self)
            try context.delete(model: HealthDaySnapshotRecord.self)
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
                remindBeforeMinutes: t.remindBeforeMinutes ?? 0,
                qrCodePayload: t.qrCodePayload,
                qrCodeImageData: t.qrCodeImageData,
                attachmentImageData: t.attachmentImageData,
                skillPathID: t.skillPathID,
                skillStageIndex: t.skillStageIndex ?? 0,
                isSkillPractice: t.isSkillPractice ?? false,
                skillPracticeMinutes: t.skillPracticeMinutes ?? 0,
                lifeEventTaskID: t.lifeEventTaskID,
                calendarItemIdentifier: t.calendarItemIdentifier,
                arrivalReminderAt: t.arrivalReminderAt,
                arrivalTransportRaw: t.arrivalTransportRaw
            )
            item.id = t.id
            item.createdAt = t.createdAt
            item.completedAt = t.completedAt
            item.reminderOverrideAt = t.reminderOverrideAt
            item.arrivalCheckFiredAt = t.arrivalCheckFiredAt
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
                date: ex.date,
                currencyCode: ex.currencyCode,
                foreignAmount: ex.foreignAmount,
                exchangeRateToCNY: ex.exchangeRateToCNY
            )
            item.id = ex.id
            item.linkedItemID = ex.linkedItemID
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
                frontFileName = IDPhotoStorage.saveData(frontData)
                guard frontFileName != nil else { throw MigrationCryptoError.missingAttachment(d.title) }
            }
            var backFileName: String? = nil
            if let backData = d.backImageData {
                backFileName = IDPhotoStorage.saveData(backData)
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
            if let audioData = vm.audioData, !audioData.isEmpty {
                if let savedName = VoiceMemoStorage.save(data: audioData, preferredName: vm.audioFileName) {
                    actualAudioFileName = savedName
                } else {
                    throw MigrationCryptoError.missingAttachment(vm.title)
                }
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
                                  notes: s.notes, imageData: s.imageData,
                                  purchasePrice: s.purchasePrice, purchaseDate: s.purchaseDate,
                                  isSecondHand: s.isSecondHand ?? false,
                                  resalePrice: s.resalePrice, resoldDate: s.resoldDate)
            item.id = s.id
            item.createdAt = s.createdAt
            item.updatedAt = s.updatedAt
            context.insert(item)
            restoredStoredItems += 1
        }
        details.append("物品收纳: \(restoredStoredItems) 项")
        totalRestored += restoredStoredItems

        let existingMedicineIDs = Set(try context.fetch(FetchDescriptor<MedicineItem>()).map(\.id))
        var restoredMedicines = 0
        for m in package.medicines ?? [] {
            if strategy == .merge && existingMedicineIDs.contains(m.id) { continue }
            let item = MedicineItem(name: m.name, category: MedicineCategory(rawValue: m.categoryRaw) ?? .other,
                                    indications: m.indications, usageMethod: m.usageMethod,
                                    storageLocation: m.storageLocation, roomArea: m.roomArea,
                                    purchaseDate: m.purchaseDate,
                                    expiryDate: m.expiryDate, isOpened: m.isOpened ?? false,
                                    openedDate: m.openedDate, afterOpenValidDays: m.afterOpenValidDays,
                                    remainingQuantity: m.remainingQuantity, precautions: m.precautions,
                                    imageData: m.imageData, isDisposed: m.isDisposed ?? false)
            item.id = m.id
            item.createdAt = m.createdAt
            item.updatedAt = m.updatedAt
            context.insert(item)
            restoredMedicines += 1
        }
        details.append("家庭常备药: \(restoredMedicines) 项")
        totalRestored += restoredMedicines

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

        // 17. 技能学习路径（先路径 → 再阶段 → 最后打卡流水，保证软关联完整）
        let existingPathIDs = Set(try context.fetch(FetchDescriptor<SkillPath>()).map(\.id))
        var restoredPaths = 0
        for p in package.skillPaths ?? [] {
            if strategy == .merge && existingPathIDs.contains(p.id) { continue }
            let item = SkillPath(
                title: p.title,
                category: SkillCategory(rawValue: p.categoryRaw) ?? .generic,
                goal: p.goal,
                weeklyMinutes: p.weeklyMinutes,
                totalWeeks: p.totalWeeks,
                startedAt: p.startedAt
            )
            item.id = p.id
            item.statusRaw = p.statusRaw
            item.currentStageIndex = p.currentStageIndex
            item.lastPracticedAt = p.lastPracticedAt
            item.practiceStreakDays = p.practiceStreakDays
            item.practiceCount = p.practiceCount
            context.insert(item)
            restoredPaths += 1
        }
        details.append("学习路径: \(restoredPaths) 条")
        totalRestored += restoredPaths

        let existingStageIDs = Set(try context.fetch(FetchDescriptor<SkillStage>()).map(\.id))
        var restoredStages = 0
        for s in package.skillStages ?? [] {
            if strategy == .merge && existingStageIDs.contains(s.id) { continue }
            let item = SkillStage(
                pathID: s.pathID,
                index: s.index,
                name: s.name,
                acceptance: s.acceptance,
                plannedDays: s.plannedDays,
                isUnlocked: s.isUnlocked
            )
            item.id = s.id
            item.isCompleted = s.isCompleted
            item.completedAt = s.completedAt
            // 直接保留原始 base64 模板，避免解码再编码造成表示漂移
            item.tasksJSON = s.tasksJSON
            context.insert(item)
            restoredStages += 1
        }
        details.append("学习阶段: \(restoredStages) 个")
        totalRestored += restoredStages

        let existingLogIDs = Set(try context.fetch(FetchDescriptor<SkillPracticeLog>()).map(\.id))
        var restoredLogs = 0
        for l in package.practiceLogs ?? [] {
            if strategy == .merge && existingLogIDs.contains(l.id) { continue }
            let item = SkillPracticeLog(
                pathID: l.pathID,
                stageIndex: l.stageIndex,
                practicedAt: l.practicedAt,
                minutes: l.minutes
            )
            item.id = l.id
            context.insert(item)
            restoredLogs += 1
        }
        details.append("练习打卡: \(restoredLogs) 次")
        totalRestored += restoredLogs

        // 宠物档案
        let existingPetIDs = Set(try context.fetch(FetchDescriptor<PetProfile>()).map(\.id))
        var restoredPets = 0
        for p in package.pets ?? [] {
            if strategy == .merge && existingPetIDs.contains(p.id) { continue }
            let item = PetProfile(
                name: p.name, type: PetType(rawValue: p.typeRaw) ?? .cat,
                breed: p.breed, gender: p.gender, birthday: p.birthday,
                adoptionDate: p.adoptionDate, weightKg: p.weightKg, microchipId: p.microchipId,
                lastExternalDewormDate: p.lastExternalDewormDate, externalDewormCycleDays: p.externalDewormCycleDays,
                lastInternalDewormDate: p.lastInternalDewormDate, internalDewormCycleDays: p.internalDewormCycleDays,
                lastVaccineDate: p.lastVaccineDate, vaccineCycleDays: p.vaccineCycleDays,
                lastBathDate: p.lastBathDate, bathCycleDays: p.bathCycleDays,
                isReminderEnabled: p.isReminderEnabled, notes: p.notes
            )
            item.id = p.id
            item.createdAt = p.createdAt
            context.insert(item)
            restoredPets += 1
        }
        details.append("宠物档案: \(restoredPets) 位")
        totalRestored += restoredPets

        // 宝贝档案（先宝贝再四类记录：记录通过 ChildProfile.child 真关系挂载，父必须在先）
        let existingChildIDs = Set(try context.fetch(FetchDescriptor<ChildProfile>()).map(\.id))
        var restoredChildren = 0
        for c in package.children ?? [] {
            if strategy == .merge && existingChildIDs.contains(c.id) { continue }
            let item = ChildProfile(
                name: c.name, realName: c.realName,
                gender: ChildGender(rawValue: c.genderRaw) ?? .boy,
                birthday: c.birthday, bloodType: c.bloodType, idCardNumber: c.idCardNumber,
                allergyInfo: c.allergyInfo, completedVaccineIds: c.completedVaccineIds,
                heightCm: c.heightCm, weightKg: c.weightKg, notes: c.notes
            )
            item.id = c.id
            item.createdAt = c.createdAt
            context.insert(item)
            restoredChildren += 1
        }
        details.append("宝贝档案: \(restoredChildren) 位")
        totalRestored += restoredChildren

        // fetch 可见本上下文尚未 save 的插入，父对象（含合并时已存在的旧父）均在此映射中
        let childByID = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<ChildProfile>()).map { ($0.id, $0) })

        let existingGrowthIDs = Set(try context.fetch(FetchDescriptor<ChildGrowthRecord>()).map(\.id))
        var restoredGrowth = 0
        for r in package.childGrowthRecords ?? [] {
            if strategy == .merge && existingGrowthIDs.contains(r.id) { continue }
            let item = ChildGrowthRecord(
                id: r.id, date: r.date, monthAge: r.monthAge,
                heightCm: r.heightCm, weightKg: r.weightKg,
                headCircumferenceCm: r.headCircumferenceCm, notes: r.notes,
                child: r.childID.flatMap { childByID[$0] }
            )
            item.createdAt = r.createdAt
            context.insert(item)
            restoredGrowth += 1
        }
        details.append("成长测量: \(restoredGrowth) 条")
        totalRestored += restoredGrowth

        let existingMilestoneIDs = Set(try context.fetch(FetchDescriptor<ChildMilestoneRecord>()).map(\.id))
        var restoredMilestones = 0
        for r in package.childMilestones ?? [] {
            if strategy == .merge && existingMilestoneIDs.contains(r.id) { continue }
            let item = ChildMilestoneRecord(
                id: r.id, date: r.date, monthAge: r.monthAge,
                category: MilestoneCategory(rawValue: r.categoryRaw) ?? .motor,
                title: r.title, notes: r.notes,
                child: r.childID.flatMap { childByID[$0] }
            )
            item.createdAt = r.createdAt
            context.insert(item)
            restoredMilestones += 1
        }
        details.append("成长里程碑: \(restoredMilestones) 条")
        totalRestored += restoredMilestones

        let existingVisitIDs = Set(try context.fetch(FetchDescriptor<ChildHealthVisitRecord>()).map(\.id))
        var restoredVisits = 0
        for r in package.childHealthVisits ?? [] {
            if strategy == .merge && existingVisitIDs.contains(r.id) { continue }
            let item = ChildHealthVisitRecord(
                id: r.id, date: r.date, hospitalOrClinic: r.hospitalOrClinic,
                diagnosis: r.diagnosis, doctorAdvice: r.doctorAdvice,
                followUpDate: r.followUpDate, notes: r.notes,
                child: r.childID.flatMap { childByID[$0] }
            )
            item.createdAt = r.createdAt
            context.insert(item)
            restoredVisits += 1
        }
        details.append("就医随访: \(restoredVisits) 条")
        totalRestored += restoredVisits

        let existingVaccinationIDs = Set(try context.fetch(FetchDescriptor<ChildVaccinationRecord>()).map(\.id))
        var restoredVaccinations = 0
        for r in package.childVaccinations ?? [] {
            if strategy == .merge && existingVaccinationIDs.contains(r.id) { continue }
            let item = ChildVaccinationRecord(
                id: r.id, vaccineId: r.vaccineId, vaccineName: r.vaccineName,
                dateAdministered: r.dateAdministered, clinicName: r.clinicName,
                batchNumber: r.batchNumber, reaction: r.reaction,
                child: r.childID.flatMap { childByID[$0] }
            )
            item.createdAt = r.createdAt
            context.insert(item)
            restoredVaccinations += 1
        }
        details.append("疫苗接种: \(restoredVaccinations) 条")
        totalRestored += restoredVaccinations

        // 生活提醒动作（完成/推迟实例状态，软引用来源档案）
        let existingReminderActionIDs = Set(try context.fetch(FetchDescriptor<LifeReminderAction>()).map(\.id))
        var restoredReminderActions = 0
        for a in package.reminderActions ?? [] {
            if strategy == .merge && existingReminderActionIDs.contains(a.id) { continue }
            let item = LifeReminderAction(
                kind: LifeReminderKind(rawValue: a.sourceKindRaw) ?? .habit,
                sourceID: a.sourceID,
                occurrenceDate: a.occurrenceDate
            )
            item.id = a.id
            item.statusRaw = a.statusRaw
            item.snoozedUntil = a.snoozedUntil
            item.completedAt = a.completedAt
            context.insert(item)
            restoredReminderActions += 1
        }
        details.append("提醒动作: \(restoredReminderActions) 条")
        totalRestored += restoredReminderActions

        // 人生大事（先项目 → 阶段 → 任务 → 人员/支出/宾客，任务挂阶段故阶段必须在先）
        let existingEventProjectIDs = Set(try context.fetch(FetchDescriptor<LifeEventProject>()).map(\.id))
        var restoredEventProjects = 0
        for p in package.lifeEventProjects ?? [] {
            if strategy == .merge && existingEventProjectIDs.contains(p.id) { continue }
            let item = LifeEventProject(
                title: p.title,
                template: LifeEventTemplate(rawValue: p.templateRaw) ?? .custom,
                targetDate: p.targetDate, location: p.location, budgetLimit: p.budgetLimit
            )
            item.id = p.id
            item.statusRaw = p.statusRaw
            item.createdAt = p.createdAt
            item.aiDecisionSummary = p.aiDecisionSummary
            item.aiDecisionAt = p.aiDecisionAt
            context.insert(item)
            restoredEventProjects += 1
        }
        details.append("人生大事: \(restoredEventProjects) 个项目")
        totalRestored += restoredEventProjects

        let existingEventStageIDs = Set(try context.fetch(FetchDescriptor<LifeEventStage>()).map(\.id))
        var restoredEventStages = 0
        for s in package.lifeEventStages ?? [] {
            if strategy == .merge && existingEventStageIDs.contains(s.id) { continue }
            let item = LifeEventStage(projectID: s.projectID, title: s.title, sortOrder: s.sortOrder)
            item.id = s.id
            item.statusRaw = s.statusRaw
            context.insert(item)
            restoredEventStages += 1
        }
        details.append("大事阶段: \(restoredEventStages) 个")
        totalRestored += restoredEventStages

        let existingEventTaskIDs = Set(try context.fetch(FetchDescriptor<LifeEventTask>()).map(\.id))
        var restoredEventTasks = 0
        for t in package.lifeEventTasks ?? [] {
            if strategy == .merge && existingEventTaskIDs.contains(t.id) { continue }
            let item = LifeEventTask(projectID: t.projectID, stageID: t.stageID, title: t.title, dueDate: t.dueDate)
            item.id = t.id
            item.detail = t.detail
            item.statusRaw = t.statusRaw
            item.ownerName = t.ownerName
            item.createdAt = t.createdAt
            item.answersJSON = t.answersJSON
            item.aiDecisionSummary = t.aiDecisionSummary
            item.aiActionItemsJSON = t.aiActionItemsJSON
            item.aiConsultedAt = t.aiConsultedAt
            context.insert(item)
            restoredEventTasks += 1
        }
        details.append("大事任务: \(restoredEventTasks) 项")
        totalRestored += restoredEventTasks

        let existingEventPersonIDs = Set(try context.fetch(FetchDescriptor<LifeEventPerson>()).map(\.id))
        var restoredEventPeople = 0
        for p in package.lifeEventPeople ?? [] {
            if strategy == .merge && existingEventPersonIDs.contains(p.id) { continue }
            let item = LifeEventPerson(
                projectID: p.projectID, name: p.name, role: p.role,
                relationship: p.relationship, phone: p.phone,
                responsibility: p.responsibility, side: p.side
            )
            item.id = p.id
            context.insert(item)
            restoredEventPeople += 1
        }
        details.append("大事人员: \(restoredEventPeople) 位")
        totalRestored += restoredEventPeople

        let existingEventExpenseIDs = Set(try context.fetch(FetchDescriptor<LifeEventExpense>()).map(\.id))
        var restoredEventExpenses = 0
        for e in package.lifeEventExpenses ?? [] {
            if strategy == .merge && existingEventExpenseIDs.contains(e.id) { continue }
            let item = LifeEventExpense(
                projectID: e.projectID, title: e.title, category: e.category,
                amount: e.amount, paidAmount: e.paidAmount, payee: e.payee,
                dueDate: e.dueDate, note: e.note
            )
            item.id = e.id
            context.insert(item)
            restoredEventExpenses += 1
        }
        details.append("大事支出: \(restoredEventExpenses) 笔")
        totalRestored += restoredEventExpenses

        let existingEventGuestIDs = Set(try context.fetch(FetchDescriptor<LifeEventGuest>()).map(\.id))
        var restoredEventGuests = 0
        for g in package.lifeEventGuests ?? [] {
            if strategy == .merge && existingEventGuestIDs.contains(g.id) { continue }
            let item = LifeEventGuest(
                projectID: g.projectID, name: g.name, relationship: g.relationship,
                side: g.side, phone: g.phone, tableNumber: g.tableNumber,
                attendanceRaw: g.attendanceRaw
            )
            item.id = g.id
            context.insert(item)
            restoredEventGuests += 1
        }
        details.append("大事宾客: \(restoredEventGuests) 位")
        totalRestored += restoredEventGuests

        // 投喂事务审计：动作快照 JSON 原样搬运，避免解码再编码造成表示漂移（同学习阶段模板的处理）
        let existingTxIDs = Set(try context.fetch(FetchDescriptor<OmniboxTransaction>()).map(\.id))
        var restoredTx = 0
        for t in package.omniboxTransactions ?? [] {
            if strategy == .merge && existingTxIDs.contains(t.id) { continue }
            // 全字段稍后逐个覆盖，构造仅取默认空动作列表
            let item = OmniboxTransaction(capture: OmniboxCapture(), actions: [], engine: t.engineRaw)
            item.id = t.id
            item.createdAt = t.createdAt
            item.sourceRaw = t.sourceRaw
            item.inputText = t.inputText
            item.imageCount = t.imageCount
            item.actionsJSON = t.actionsJSON
            item.statusRaw = t.statusRaw
            item.executedAt = t.executedAt
            item.undoJSON = t.undoJSON
            context.insert(item)
            restoredTx += 1
        }
        details.append("投喂事务: \(restoredTx) 笔")
        totalRestored += restoredTx

        // 18. 饮食热量记录（Schema V4）
        let existingFoodIDs = Set(try context.fetch(FetchDescriptor<FoodIntakeRecord>()).map(\.id))
        var restoredFood = 0
        for f in package.foodIntakeRecords ?? [] {
            if strategy == .merge && existingFoodIDs.contains(f.id) { continue }
            let item = FoodIntakeRecord(
                date: f.date,
                foodName: f.foodName,
                foodID: f.foodID,
                portion: FoodPortion(rawValue: f.portionRaw) ?? .regular,
                fullPortionCalories: f.fullPortionCalories,
                consumedRatio: f.consumedRatio,
                confidence: f.confidence,
                isManuallyAdjusted: f.isManuallyAdjusted,
                source: FoodIntakeSource(rawValue: f.sourceRaw) ?? .vision,
                imageData: f.imageData,
                linkedExpenseID: f.linkedExpenseID
            )
            item.id = f.id
            item.consumedCalories = f.consumedCalories
            item.createdAt = f.createdAt
            context.insert(item)
            restoredFood += 1
        }
        if restoredFood > 0 || package.foodIntakeRecords != nil {
            details.append("饮食热量: \(restoredFood) 项")
            totalRestored += restoredFood
        }

        // 19. 饮水摄入记录（Schema V5）
        let existingWaterIDs = Set(try context.fetch(FetchDescriptor<WaterIntakeRecord>()).map(\.id))
        var restoredWater = 0
        for w in package.waterIntakeRecords ?? [] {
            if strategy == .merge && existingWaterIDs.contains(w.id) { continue }
            let item = WaterIntakeRecord(
                date: w.date,
                beverageType: HydrationBeverageType(rawValue: w.beverageTypeRaw) ?? .plainWater,
                volumeML: w.volumeML,
                hydrationFactor: w.hydrationFactor,
                customName: w.customName,
                note: w.note,
                syncedToHealthKit: w.syncedToHealthKit,
                linkedExpenseID: w.linkedExpenseID
            )
            item.id = w.id
            item.effectiveHydrationML = w.effectiveHydrationML
            item.caffeineMG = w.caffeineMG
            item.calories = w.calories
            item.createdAt = w.createdAt
            context.insert(item)
            restoredWater += 1
        }
        if restoredWater > 0 || package.waterIntakeRecords != nil {
            details.append("饮水记录: \(restoredWater) 项")
            totalRestored += restoredWater
        }

        // 20. 判别反馈语料（备份格式 V3 新增）。丢了阈值校准就得从零攒——优先级等同用户数据。
        let existingFeedbackIDs = Set(try context.fetch(FetchDescriptor<OmniboxJudgmentFeedback>()).map(\.id))
        var restoredFeedback = 0
        for f in package.judgmentFeedbacks ?? [] {
            if strategy == .merge && existingFeedbackIDs.contains(f.id) { continue }
            let record = JudgmentFeedback(
                id: f.id,
                inputText: f.inputText,
                labelRaw: f.labelRaw,
                verdict: JudgmentFeedback.Verdict(rawValue: f.verdictRaw) ?? .up,
                topProbability: f.topProbability,
                margin: f.margin,
                runnerUpLabelRaw: f.runnerUpLabelRaw,
                correctedLabelRaw: f.correctedLabelRaw,
                createdAt: f.createdAt
            )
            context.insert(OmniboxJudgmentFeedback(record))
            restoredFeedback += 1
        }
        if restoredFeedback > 0 || package.judgmentFeedbacks != nil {
            details.append("判别反馈: \(restoredFeedback) 条")
            totalRestored += restoredFeedback
        }

        // 21. 每日健康快照（备份格式 V4 新增）。HealthKit 不可回溯，趋势数据丢了补不回来。
        let existingHealthIDs = Set(try context.fetch(FetchDescriptor<HealthDaySnapshotRecord>()).map(\.id))
        var restoredHealth = 0
        for h in package.healthSnapshots ?? [] {
            if strategy == .merge && existingHealthIDs.contains(h.id) { continue }
            let record = HealthDaySnapshotRecord(day: h.day)
            record.id = h.id
            record.stepCount = h.stepCount
            record.activeEnergy = h.activeEnergy
            record.restingEnergy = h.restingEnergy
            record.dietaryWater = h.dietaryWater
            record.sleepHours = h.sleepHours
            record.sleepREM = h.sleepREM
            record.sleepDeep = h.sleepDeep
            record.heartRate = h.heartRate
            record.restingHeartRate = h.restingHeartRate
            record.heartRateVariability = h.heartRateVariability
            record.bloodOxygen = h.bloodOxygen
            record.bodyTemperature = h.bodyTemperature
            record.walkingSpeed = h.walkingSpeed
            record.respiratoryRate = h.respiratoryRate
            record.workoutMinutes = h.workoutMinutes
            record.workoutCount = h.workoutCount
            record.updatedAt = h.updatedAt
            context.insert(record)
            restoredHealth += 1
        }
        if restoredHealth > 0 || package.healthSnapshots != nil {
            details.append("健康快照: \(restoredHealth) 天")
            totalRestored += restoredHealth
        }

        // 22. 偏好设置（仅覆盖策略：合并策略只搬数据，不改本机行为）。
        // 放在 context.save() 之后：UserDefaults 无法随 context.rollback() 回滚，
        // 必须等数据库落库成功再动设置，避免「库回滚了、偏好却已写盘」的不一致。
        try context.save()

        // 事务成功落库后，清理未被引用的沙盒孤儿证件照与语音文件（避免先删文件导致回滚丢失）
        if strategy == .overwrite {
            // 引用集查询失败时**绝不清理**：旧实现用 `try?` 读引用集，
            // 读失败会得到空集合，再拿空集合去「保留」，等于删光用户所有证件照与语音。
            let fetchedDocs = try? context.fetch(FetchDescriptor<IDDocumentItem>())
            let validPhotoNames = Set(
                (fetchedDocs ?? []).flatMap { [$0.frontImageFileName, $0.backImageFileName].compactMap { $0 } }
            )
            switch BackupRestoreGuard.pruneDecision(
                referenceLookupSucceeded: fetchedDocs != nil,
                referencedFileNames: validPhotoNames
            ) {
            case .prune(let keeping):
                IDPhotoStorage.pruneUnreferenced(keeping: keeping)
            case .skipped:
                break
            }

            let fetchedMemos = try? context.fetch(FetchDescriptor<VoiceMemo>())
            let validAudioNames = Set((fetchedMemos ?? []).map(\.audioFileName))
            switch BackupRestoreGuard.pruneDecision(
                referenceLookupSucceeded: fetchedMemos != nil,
                referencedFileNames: validAudioNames
            ) {
            case .prune(let keeping):
                VoiceMemoStorage.pruneUnreferenced(keeping: keeping)
            case .skipped:
                break
            }
        }

        if !missingAttachmentLabels.isEmpty {
            details.append("附件缺失（备份内本就没有这部分文件）: \(missingAttachmentLabels.joined(separator: "、"))")
        }

        if strategy == .overwrite, let settings = package.settings {
            applySettingsSnapshot(settings)
            details.append("偏好设置: \(settings.itemCount) 项")
            totalRestored += settings.itemCount
        }
        return RestoreResultSummary(restoredCount: totalRestored, details: details)
        } catch {
            context.rollback()
            throw error
        }
    }
}
