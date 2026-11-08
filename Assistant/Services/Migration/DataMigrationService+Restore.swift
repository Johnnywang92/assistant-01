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
    /// 执行还原或合并数据。
    ///
    /// 并发约定（SVC-01）：`ModelContext` 不是 `Sendable`，还原的删除/插入/保存必须
    /// 留在主 actor；但每个实体域、以及大表每 N 条记录之间 `await Task.yield()`，
    /// 把「一次同步跑完几十个域」拆成可被 UI 事件插入的片段。真正的单次大停顿只剩
    /// 最终 `context.save()`（SwiftData 主上下文落盘不能跨线程，属已知残留）。
    /// 失败语义不变：异常向外抛，catch 里 `context.rollback()`，磁盘原库不受影响。
    public func restore(from package: BackupPackage, strategy: RestoreStrategy) async throws -> RestoreResultSummary {
        try validate(package: package)
        guard strategy != .overwrite || package.metadata.schemaVersion >= 2 else {
            throw MigrationCryptoError.incompleteLegacyBackup
        }
        // 附件预检：必须在清库之前完成。
        // 旧版导出可能静默丢过语音音频，带着这种缺口进还原流程，
        // 结果是「记录在、音频没了」的残缺数据——用户却以为还原成功了。
        let packageAttachmentExpectations = (package.voiceMemos ?? []).flatMap { memo -> [BackupRestoreGuard.AttachmentExpectation] in
            var expectations: [BackupRestoreGuard.AttachmentExpectation] = []
            // 纯文字备忘没有音频，不参与附件预检。
            if !memo.audioFileName.isEmpty {
                expectations.append(.init(
                    ownerTitle: memo.title,
                    kind: .voiceMemoAudio,
                    fileName: memo.audioFileName,
                    hasData: memo.audioData?.isEmpty == false
                ))
            }
            // 多段录音每段都要预检，不能只看第一段。
            for segment in memo.segments ?? [] {
                expectations.append(.init(
                    ownerTitle: memo.title,
                    kind: .voiceMemoAudio,
                    fileName: segment.fileName.isEmpty ? nil : segment.fileName,
                    hasData: segment.audioData?.isEmpty == false
                ))
            }
            return expectations
        }
        // 笔记内嵌图片也要预检：包里说了有图，实际没带上，同样是残缺备份。
        let packageImageExpectations = (package.voiceMemos ?? []).flatMap { memo in
            (memo.images ?? []).map { image in
                BackupRestoreGuard.AttachmentExpectation(
                    ownerTitle: memo.title,
                    kind: .voiceMemoImage,
                    fileName: image.fileName.isEmpty ? nil : image.fileName,
                    hasData: image.data?.isEmpty == false
                )
            }
        }
        var allAttachmentExpectations = packageAttachmentExpectations
        allAttachmentExpectations.append(contentsOf: packageImageExpectations)
        var missingAttachmentLabels: [String] = []
        if case .incomplete(let missing) = BackupRestoreGuard.auditAttachments(allAttachmentExpectations) {
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

        // SVC-01 副作用防护：还原现在会在每个实体域之间 `await Task.yield()` 让出主线程，
        // 而 SwiftUI 的主 `ModelContext` 默认开启 autosave。若中途让出时触发自动落盘，
        // 「还原到一半」的状态就会被写进磁盘，之后任何失败调用 `rollback()` 也回不到原库，
        // 「还原失败不动库」的既有承诺会被打破。因此整个还原事务期间关闭 autosave，
        // 成功/失败/取消都由 defer 恢复原值。
        let previousAutosave = context.autosaveEnabled
        if previousAutosave { context.autosaveEnabled = false }
        defer {
            context.autosaveEnabled = previousAutosave
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
            // 清库的 41 条 delete 也是同步 I/O；每 10 张表让出一次，
            // 避免「覆盖还原」在真正插入数据前就整段冻住。
            await Task.yield()
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
            // 清库的 41 条 delete 也是同步 I/O；每 10 张表让出一次，
            // 避免「覆盖还原」在真正插入数据前就整段冻住。
            await Task.yield()
            try context.delete(model: SkillStage.self)
            try context.delete(model: SkillPracticeLog.self)
            try context.delete(model: PetProfile.self)
            try context.delete(model: PetRecord.self)
            try context.delete(model: ChildProfile.self)
            try context.delete(model: ChildGrowthRecord.self)
            try context.delete(model: ChildMilestoneRecord.self)
            try context.delete(model: ChildHealthVisitRecord.self)
            try context.delete(model: ChildVaccinationRecord.self)
            try context.delete(model: LifeReminderAction.self)
            // 清库的 41 条 delete 也是同步 I/O；每 10 张表让出一次，
            // 避免「覆盖还原」在真正插入数据前就整段冻住。
            await Task.yield()
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
            // 清库的 41 条 delete 也是同步 I/O；每 10 张表让出一次，
            // 避免「覆盖还原」在真正插入数据前就整段冻住。
            await Task.yield()
            try context.delete(model: HealthDaySnapshotRecord.self)
        }

        var details: [String] = []
        var totalRestored = 0

        // 1. 待办事项
        var restoredTodos = 0
        await Task.yield()
        let existingTodoIDs = Set(try context.fetch(FetchDescriptor<TodoItem>()).map(\.id))
        for (index, t) in package.todos.enumerated() {
            // 大表分片：待办每 200 条让出主线程一次。
            if index > 0, index % 200 == 0 { await Task.yield() }
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
            item.tags = t.tags ?? []
            // 日程快照直接还原，不经过 schedule setter：dueAt/规则散字段已由上面的
            // init 从 DTO 逐项恢复，再走 setter 会用快照里的值二次覆盖，导致旧备份
            // 与新备份对同一条记录解释不一致。
            item.scheduleRaw = t.scheduleRaw
            context.insert(item)
            restoredTodos += 1
        }
        details.append("待办事项: \(restoredTodos) 项")
        totalRestored += restoredTodos

        // 2. 订阅
        var restoredSubs = 0
        await Task.yield()
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
        await Task.yield()
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
        await Task.yield()
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
        await Task.yield()
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
        await Task.yield()
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
        await Task.yield()
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
        await Task.yield()
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
        await Task.yield()
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
        await Task.yield()
        let existingExpenseIDs = Set(try context.fetch(FetchDescriptor<ExpenseRecord>()).map(\.id))
        for (index, ex) in (package.expenses ?? []).enumerated() {
            // 大表分片：记账每 200 条让出主线程一次。
            if index > 0, index % 200 == 0 { await Task.yield() }
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
            item.isPending = ex.isPending ?? false
            item.pendingDueDate = ex.pendingDueDate
            item.projectTag = ex.projectTag
            // V10 起单据与 AA 分摊是持久化字段；旧备份没有这些键，
            // 回落 nil / 默认值即可（不要因为旧备份而丢掉新版本的还原能力）。
            item.receiptImageData = ex.receiptImageData
            if let count = ex.splitCount { item.splitCountStored = max(count, 1) }
            if let participants = ex.splitParticipants { item.splitParticipantsStored = participants }
            context.insert(item)
            restoredExpenses += 1
        }
        details.append("日常记账: \(restoredExpenses) 项")
        totalRestored += restoredExpenses

        // 11. 重要证件
        var restoredDocs = 0
        await Task.yield()
        let existingDocIDs = Set(try context.fetch(FetchDescriptor<IDDocumentItem>()).map(\.id))
        for (index, d) in (package.documents ?? []).enumerated() {
            // 大表分片：证件（逐张写盘）每 50 条让出主线程一次。
            if index > 0, index % 50 == 0 { await Task.yield() }
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
        await Task.yield()
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
        await Task.yield()
        let existingVoiceMemoIDs = Set(try context.fetch(FetchDescriptor<VoiceMemo>()).map(\.id))
        for (index, vm) in (package.voiceMemos ?? []).enumerated() {
            // 大表分片：语音备忘（逐条写盘）每 50 条让出主线程一次。
            if index > 0, index % 50 == 0 { await Task.yield() }
            if strategy == .merge && existingVoiceMemoIDs.contains(vm.id) { continue }

            var actualAudioFileName = vm.audioFileName
            if let audioData = vm.audioData, !audioData.isEmpty {
                if let savedName = VoiceMemoStorage.save(data: audioData, preferredName: vm.audioFileName) {
                    actualAudioFileName = savedName
                } else {
                    throw MigrationCryptoError.missingAttachment(vm.title)
                }
            }

            // 还原多段录音：每段独立写盘，文件名冲突时 save 会另起名字，
            // 同步更新片段里的 fileName，避免留下指向旧文件名的断链。
            var restoredSegments: [MemoSegment] = []
            for (index, segment) in (vm.segments ?? []).enumerated() {
                var actualName = segment.fileName
                if index == 0, vm.audioData?.isEmpty == false {
                    // 第一段已由兼容字段 audioData 写盘，复用它；
                    // 若再写一次会另起文件名，旧文件就变成没人引用的孤儿。
                    actualName = actualAudioFileName
                } else if let data = segment.audioData, !data.isEmpty {
                    guard let saved = VoiceMemoStorage.save(data: data, preferredName: segment.fileName) else {
                        throw MigrationCryptoError.missingAttachment(vm.title)
                    }
                    actualName = saved
                }
                restoredSegments.append(MemoSegment(
                    id: segment.id,
                    fileName: actualName,
                    duration: segment.duration,
                    createdAt: segment.createdAt,
                    interruptionReasonRaw: segment.interruptionReasonRaw,
                    transcriptBlockIDs: segment.transcriptBlockIDs
                ))
            }

            // 还原笔记内嵌图片。图片写盘失败要**取消还原**，
            // 不能留下「块里引用着图片、但文件不在」的断链状态——
            // 那样卡片渲染时会显示「图片已丢失」，而用户以为还原成功了。
            for image in vm.images ?? [] {
                guard let data = image.data, !data.isEmpty else {
                    throw MigrationCryptoError.missingAttachment(vm.title)
                }
                if VoiceMemoImageStorage.save(data: data, preferredName: image.fileName) == nil {
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
            // 旧备份包没有 blocksData，用转写全文重建结构化块——
            // 宁可粗糙，也不能让老用户的笔记打开后是空的。
            if let blocksData = vm.blocksData, !blocksData.isEmpty {
                item.blocksData = blocksData
            } else if let text = vm.transcription, !text.isEmpty {
                item.blocksData = MemoBlockCodec.encode(
                    MemoBlockBuilder.build(from: text, title: vm.title)
                )
            }
            item.summary = vm.summary
            item.isBookmarked = vm.isBookmarked
            // V12：直接写字段，不再过 setter，保持 duration = 第一段时长的兼容语义。
            if !restoredSegments.isEmpty {
                item.segmentsData = MemoSegmentCodec.encode(restoredSegments)
                if let first = restoredSegments.first {
                    item.audioFileName = first.fileName
                    item.duration = first.duration
                }
            }
            item.shareTitle = vm.shareTitle
            item.shareTitleSourceRaw = vm.shareTitleSourceRaw
            item.titleIsUserEditedRaw = vm.titleIsUserEditedRaw
            item.isTextOnlyRaw = vm.isTextOnlyRaw
            // 旧备份包没有这个字段：确实没有音频时也要标成纯文字，别让它假装能播放。
            if vm.isTextOnlyRaw == nil, vm.audioFileName.isEmpty, restoredSegments.isEmpty {
                item.isTextOnly = true
            }
            context.insert(item)
            restoredVoiceMemos += 1
        }
        details.append("语音备忘: \(restoredVoiceMemos) 项")
        totalRestored += restoredVoiceMemos

        await Task.yield()
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

        await Task.yield()
        let existingStoredIDs = Set(try context.fetch(FetchDescriptor<StoredItem>()).map(\.id))
        var restoredStoredItems = 0
        for (index, s) in (package.storedItems ?? []).enumerated() {
            // 大表分片：物品收纳每 200 条让出主线程一次。
            if index > 0, index % 200 == 0 { await Task.yield() }
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

        await Task.yield()
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

        await Task.yield()
        let existingDialogueIDs = Set(try context.fetch(FetchDescriptor<DialogueMessageRecord>()).map(\.id))
        var restoredDialogues = 0
        for (index, d) in (package.dialogueRecords ?? []).enumerated() {
            // 大表分片：对话历史每 300 条让出主线程一次。
            if index > 0, index % 300 == 0 { await Task.yield() }
            if strategy == .merge && existingDialogueIDs.contains(d.id) { continue }
            context.insert(DialogueMessageRecord(id: d.id, role: d.roleRaw, text: d.text,
                                                 timestamp: d.timestamp, sessionID: d.sessionID))
            restoredDialogues += 1
        }
        details.append("对话历史: \(restoredDialogues) 项")
        totalRestored += restoredDialogues

        await Task.yield()
        let existingMessageIDs = Set(try context.fetch(FetchDescriptor<RawMessage>()).map(\.id))
        var restoredMessages = 0
        for (index, m) in (package.rawMessages ?? []).enumerated() {
            // 大表分片：原始消息每 300 条让出主线程一次。
            if index > 0, index % 300 == 0 { await Task.yield() }
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

        await Task.yield()
        let existingSampleIDs = Set(try context.fetch(FetchDescriptor<LocationStaySample>()).map(\.id))
        var restoredSamples = 0
        for (index, s) in (package.locationSamples ?? []).enumerated() {
            // 大表分片：位置采样每 300 条让出主线程一次。
            if index > 0, index % 300 == 0 { await Task.yield() }
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
        await Task.yield()
        let existingPathIDs = Set(try context.fetch(FetchDescriptor<SkillPath>()).map(\.id))
        var restoredPaths = 0
        for (index, p) in (package.skillPaths ?? []).enumerated() {
            // 大表分片：学习路径每 200 条让出主线程一次。
            if index > 0, index % 200 == 0 { await Task.yield() }
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

        await Task.yield()
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

        await Task.yield()
        let existingLogIDs = Set(try context.fetch(FetchDescriptor<SkillPracticeLog>()).map(\.id))
        var restoredLogs = 0
        for (index, l) in (package.practiceLogs ?? []).enumerated() {
            // 大表分片：练习打卡每 300 条让出主线程一次。
            if index > 0, index % 300 == 0 { await Task.yield() }
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
        await Task.yield()
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

        // 宠物成长与健康记录
        await Task.yield()
        let existingPetRecordIDs = Set(try context.fetch(FetchDescriptor<PetRecord>()).map(\.id))
        var restoredPetRecords = 0
        for (index, r) in (package.petRecords ?? []).enumerated() {
            // 大表分片：宠物记录每 200 条让出主线程一次。
            if index > 0, index % 200 == 0 { await Task.yield() }
            if strategy == .merge && existingPetRecordIDs.contains(r.id) { continue }
            let item = PetRecord(
                id: r.id,
                petID: r.petID,
                date: r.date,
                type: PetRecordType(rawValue: r.typeRaw) ?? .growth,
                title: r.title,
                weightKg: r.weightKg,
                clinicOrPlace: r.clinicOrPlace,
                notes: r.notes,
                createdAt: r.createdAt
            )
            context.insert(item)
            restoredPetRecords += 1
        }
        details.append("宠物成长记录: \(restoredPetRecords) 条")
        totalRestored += restoredPetRecords

        // 宝贝档案（先宝贝再四类记录：记录通过 ChildProfile.child 真关系挂载，父必须在先）
        await Task.yield()
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

        await Task.yield()
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

        await Task.yield()
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

        await Task.yield()
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

        await Task.yield()
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
        await Task.yield()
        let existingReminderActionIDs = Set(try context.fetch(FetchDescriptor<LifeReminderAction>()).map(\.id))
        var restoredReminderActions = 0
        for (index, a) in (package.reminderActions ?? []).enumerated() {
            // 大表分片：提醒动作每 200 条让出主线程一次。
            if index > 0, index % 200 == 0 { await Task.yield() }
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
        await Task.yield()
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

        await Task.yield()
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

        await Task.yield()
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

        await Task.yield()
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

        await Task.yield()
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

        await Task.yield()
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
        await Task.yield()
        let existingTxIDs = Set(try context.fetch(FetchDescriptor<OmniboxTransaction>()).map(\.id))
        var restoredTx = 0
        for (index, t) in (package.omniboxTransactions ?? []).enumerated() {
            // 大表分片：投喂事务每 200 条让出主线程一次。
            if index > 0, index % 200 == 0 { await Task.yield() }
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
        await Task.yield()
        let existingFoodIDs = Set(try context.fetch(FetchDescriptor<FoodIntakeRecord>()).map(\.id))
        var restoredFood = 0
        for (index, f) in (package.foodIntakeRecords ?? []).enumerated() {
            // 大表分片：饮食记录每 200 条让出主线程一次。
            if index > 0, index % 200 == 0 { await Task.yield() }
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
        await Task.yield()
        let existingWaterIDs = Set(try context.fetch(FetchDescriptor<WaterIntakeRecord>()).map(\.id))
        var restoredWater = 0
        for (index, w) in (package.waterIntakeRecords ?? []).enumerated() {
            // 大表分片：饮水记录每 200 条让出主线程一次。
            if index > 0, index % 200 == 0 { await Task.yield() }
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
        await Task.yield()
        let existingFeedbackIDs = Set(try context.fetch(FetchDescriptor<OmniboxJudgmentFeedback>()).map(\.id))
        var restoredFeedback = 0
        for (index, f) in (package.judgmentFeedbacks ?? []).enumerated() {
            // 大表分片：判别反馈每 200 条让出主线程一次。
            if index > 0, index % 200 == 0 { await Task.yield() }
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
        await Task.yield()
        let existingHealthIDs = Set(try context.fetch(FetchDescriptor<HealthDaySnapshotRecord>()).map(\.id))
        var restoredHealth = 0
        for (index, h) in (package.healthSnapshots ?? []).enumerated() {
            // 大表分片：健康快照每 200 条让出主线程一次。
            if index > 0, index % 200 == 0 { await Task.yield() }
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

        // 21.5 心理量表与情绪微记录（备份格式 V8 新增）。
        // 心理追踪的价值在**纵向历史**——趋势断了就没意义了，所以必须还原。
        await Task.yield()
        let existingPsychIDs = Set(try context.fetch(FetchDescriptor<PsychScaleRecord>()).map(\.id))
        var restoredPsych = 0
        for (index, r) in (package.psychScaleRecords ?? []).enumerated() {
            // 大表分片：心理量表每 200 条让出主线程一次。
            if index > 0, index % 200 == 0 { await Task.yield() }
            if strategy == .merge && existingPsychIDs.contains(r.id) { continue }
            let record = PsychScaleRecord(
                scaleID: PsychScaleID(rawValue: r.scaleIDRaw) ?? .phq9,
                completedAt: r.completedAt,
                itemScores: r.itemScores,
                hasAcknowledgedCrisis: r.hasAcknowledgedCrisis
            )
            record.id = r.id
            record.answeredCount = r.answeredCount
            record.createdAt = r.createdAt
            context.insert(record)
            restoredPsych += 1
        }

        await Task.yield()
        let existingMoodIDs = Set(try context.fetch(FetchDescriptor<MoodCheckInRecord>()).map(\.id))
        var restoredMood = 0
        for (index, r) in (package.moodCheckIns ?? []).enumerated() {
            // 大表分片：情绪记录每 200 条让出主线程一次。
            if index > 0, index % 200 == 0 { await Task.yield() }
            if strategy == .merge && existingMoodIDs.contains(r.id) { continue }
            let record = MoodCheckInRecord(
                day: r.day,
                moodScore: r.moodScore,
                energyScore: r.energyScore,
                stressScore: r.stressScore,
                note: r.note
            )
            record.id = r.id
            record.createdAt = r.createdAt
            record.updatedAt = r.updatedAt
            context.insert(record)
            restoredMood += 1
        }
        if restoredPsych > 0 || package.psychScaleRecords != nil {
            details.append("心理量表: \(restoredPsych) 次")
            totalRestored += restoredPsych
        }
        if restoredMood > 0 || package.moodCheckIns != nil {
            details.append("情绪记录: \(restoredMood) 天")
            totalRestored += restoredMood
        }

        // 22. 偏好设置（仅覆盖策略：合并策略只搬数据，不改本机行为）。
        // 放在 context.save() 之后：UserDefaults 无法随 context.rollback() 回滚，
        // 必须等数据库落库成功再动设置，避免「库回滚了、偏好却已写盘」的不一致。
        // 单次 `context.save()` 是 SwiftData 主上下文唯一无法搬去后台的落盘点；
        // 落盘前让出一次，保证「还原中」状态先渲染出来，而不是先冻住再变。
        await Task.yield()
        try context.save()
        await Task.yield()

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
            // 一条备忘可能有多个片段：全部算进保留名单，
            // 否则清理孤儿文件时会把第 2 段之后的录音全删掉。
            let validAudioNames = Set((fetchedMemos ?? []).flatMap { Array($0.segmentFileNames) })
            switch BackupRestoreGuard.pruneDecision(
                referenceLookupSucceeded: fetchedMemos != nil,
                referencedFileNames: validAudioNames
            ) {
            case .prune(let keeping):
                VoiceMemoStorage.pruneUnreferenced(keeping: keeping)
            case .skipped:
                break
            }

            // 笔记内嵌图片的孤儿清理。
            // 同样走 `pruneDecision`：查询失败时**不清**，
            // 否则空引用集会把所有笔记图片删光（与证件照片同一个坑）。
            let validImageNames: Set<String> = Set((fetchedMemos ?? []).flatMap { memo in
                memo.document.blocks.compactMap { block -> String? in
                    guard block.kind == .image else { return nil }
                    return block.imageFileName
                }
            })
            switch BackupRestoreGuard.pruneDecision(
                referenceLookupSucceeded: fetchedMemos != nil,
                referencedFileNames: validImageNames
            ) {
            case .prune(let keeping):
                VoiceMemoImageStorage.pruneUnreferenced(referencing: keeping)
            case .skipped:
                break
            }
        }

        if !missingAttachmentLabels.isEmpty {
            details.append("附件缺失（备份内本就没有这部分文件）: \(missingAttachmentLabels.joined(separator: "、"))")
        }

        await Task.yield()
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
