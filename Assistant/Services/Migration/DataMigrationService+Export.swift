import Foundation
import SwiftData
import UIKit
import AssistantCore

extension DataMigrationService {
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
        let medicineStocks = try context.fetch(FetchDescriptor<MedicineItem>())
        let dialogueRecords = try context.fetch(FetchDescriptor<DialogueMessageRecord>())
        let rawMessages = try context.fetch(FetchDescriptor<RawMessage>())
        let locationSamples = try context.fetch(FetchDescriptor<LocationStaySample>())
        let skillPaths = try context.fetch(FetchDescriptor<SkillPath>())
        let skillStages = try context.fetch(FetchDescriptor<SkillStage>())
        let practiceLogs = try context.fetch(FetchDescriptor<SkillPracticeLog>())
        let pets = try context.fetch(FetchDescriptor<PetProfile>())
        let children = try context.fetch(FetchDescriptor<ChildProfile>())
        let childGrowthRecords = try context.fetch(FetchDescriptor<ChildGrowthRecord>())
        let childMilestones = try context.fetch(FetchDescriptor<ChildMilestoneRecord>())
        let childHealthVisits = try context.fetch(FetchDescriptor<ChildHealthVisitRecord>())
        let childVaccinations = try context.fetch(FetchDescriptor<ChildVaccinationRecord>())
        let reminderActions = try context.fetch(FetchDescriptor<LifeReminderAction>())
        let lifeEventProjects = try context.fetch(FetchDescriptor<LifeEventProject>())
        let lifeEventStages = try context.fetch(FetchDescriptor<LifeEventStage>())
        let lifeEventTasks = try context.fetch(FetchDescriptor<LifeEventTask>())
        let lifeEventPeople = try context.fetch(FetchDescriptor<LifeEventPerson>())
        let lifeEventExpenses = try context.fetch(FetchDescriptor<LifeEventExpense>())
        let lifeEventGuests = try context.fetch(FetchDescriptor<LifeEventGuest>())
        let omniboxTransactions = try context.fetch(FetchDescriptor<OmniboxTransaction>())
        let foodIntakeRecords = try context.fetch(FetchDescriptor<FoodIntakeRecord>())
        let waterIntakeRecords = try context.fetch(FetchDescriptor<WaterIntakeRecord>())
        let judgmentFeedbacks = try context.fetch(FetchDescriptor<OmniboxJudgmentFeedback>())
        let healthSnapshots = try context.fetch(FetchDescriptor<HealthDaySnapshotRecord>())

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
                reminderOverrideAt: $0.reminderOverrideAt,
                qrCodePayload: $0.qrCodePayload,
                qrCodeImageData: $0.qrCodeImageData,
                attachmentImageData: $0.attachmentImageData,
                skillPathID: $0.skillPathID,
                skillStageIndex: $0.skillStageIndex,
                isSkillPractice: $0.isSkillPractice,
                skillPracticeMinutes: $0.skillPracticeMinutes,
                lifeEventTaskID: $0.lifeEventTaskID,
                calendarItemIdentifier: $0.calendarItemIdentifier,
                arrivalReminderAt: $0.arrivalReminderAt,
                arrivalTransportRaw: $0.arrivalTransportRaw,
                arrivalCheckFiredAt: $0.arrivalCheckFiredAt
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
                rawText: $0.rawText, date: $0.date, createdAt: $0.createdAt,
                linkedItemID: $0.linkedItemID,
                currencyCode: $0.currencyCode,
                foreignAmount: $0.foreignAmount,
                exchangeRateToCNY: $0.exchangeRateToCNY
            )
        }

        let documentDTOs = documents.map { doc in
            let frontData = IDPhotoStorage.loadData(fileName: doc.frontImageFileName)
                ?? IDPhotoStorage.loadImage(fileName: doc.frontImageFileName)?.jpegData(compressionQuality: 0.88)
            let backData = IDPhotoStorage.loadData(fileName: doc.backImageFileName)
                ?? IDPhotoStorage.loadImage(fileName: doc.backImageFileName)?.jpegData(compressionQuality: 0.88)
            return IDDocumentDTO(
                id: doc.id,
                title: doc.title,
                typeRaw: doc.typeRaw,
                holderName: doc.holderName,
                documentNumber: doc.documentNumber,
                expiryDate: doc.expiryDate,
                isPermanent: doc.isPermanent,
                notes: doc.notes,
                frontImageData: frontData,
                backImageData: backData,
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

        let voiceMemoDTOs = voiceMemos.map { memo in
            let audioData = VoiceMemoStorage.loadData(memo.audioFileName)
            // 笔记内嵌图片：把块里引用的图片一并带进备份包
            let imageFileNames = memo.document.blocks.compactMap { block -> String? in
                guard block.kind == .image, let name = block.imageFileName else { return nil }
                return name
            }
            let imageDTOs = imageFileNames.map { name in
                VoiceMemoImageDTO(fileName: name, data: VoiceMemoImageStorage.loadData(name))
            }
            return VoiceMemoDTO(
                id: memo.id,
                title: memo.title,
                duration: memo.duration,
                audioFileName: memo.audioFileName,
                audioData: audioData,
                transcription: memo.transcription,
                blocksData: memo.blocksData,
                images: imageDTOs.isEmpty ? nil : imageDTOs,
                summary: memo.summary,
                tagRaw: memo.tagRaw,
                isBookmarked: memo.isBookmarked,
                createdAt: memo.createdAt
            )
        }

        // 附件完整性核对（导出侧第一道关卡）。
        // 证件照片与语音音频存在沙盒文件里，读不到就会静默变成 nil——
        // 旧实现照常写进备份包并报告成功，用户拿到一份「成功」的备份，
        // 还原后才发现证件没有照片、语音点不开。这里改成**读不到就取消备份**：
        // 宁可不备份，也不产出一份会骗人的备份。
        var attachmentExpectations: [BackupRestoreGuard.AttachmentExpectation] = []
        for (doc, dto) in zip(documents, documentDTOs) {
            attachmentExpectations.append(.init(
                ownerTitle: doc.title, kind: .idPhotoFront,
                fileName: doc.frontImageFileName, hasData: dto.frontImageData != nil
            ))
            attachmentExpectations.append(.init(
                ownerTitle: doc.title, kind: .idPhotoBack,
                fileName: doc.backImageFileName, hasData: dto.backImageData != nil
            ))
        }
        for (memo, dto) in zip(voiceMemos, voiceMemoDTOs) {
            attachmentExpectations.append(.init(
                ownerTitle: memo.title, kind: .voiceMemoAudio,
                fileName: memo.audioFileName.isEmpty ? nil : memo.audioFileName,
                hasData: dto.audioData?.isEmpty == false
            ))
            // 笔记内嵌图片同样必须真的带上——
            // 「有文字没图」的备份和「记录在、音频没了」一样是残缺数据。
            for image in dto.images ?? [] {
                attachmentExpectations.append(.init(
                    ownerTitle: memo.title, kind: .voiceMemoImage,
                    fileName: image.fileName.isEmpty ? nil : image.fileName,
                    hasData: image.data?.isEmpty == false
                ))
            }
        }
        if case .incomplete(let missing) = BackupRestoreGuard.auditAttachments(attachmentExpectations) {
            throw MigrationCryptoError.missingAttachment(
                BackupRestoreGuard.describeMissingAttachments(missing).joined(separator: "、")
            )
        }

        let vehicleDTOs = vehicles.map { v in            VehicleDTO(id: v.id, name: v.name, plateNumber: v.plateNumber, powerTypeRaw: v.powerTypeRaw,
                       energyCycleDays: v.energyCycleDays, lastEnergyRefillDate: v.lastEnergyRefillDate,
                       preferredEnergyHour: v.preferredEnergyHour, preferredEnergyMinute: v.preferredEnergyMinute,
                       maintenanceIntervalMonths: v.maintenanceIntervalMonths, lastMaintenanceDate: v.lastMaintenanceDate,
                       nextMaintenanceDate: v.nextMaintenanceDate, insuranceExpiryDate: v.insuranceExpiryDate,
                       annualInspectionDate: v.annualInspectionDate, currentMileage: v.currentMileage,
                       isReminderEnabled: v.isReminderEnabled, notes: v.notes, createdAt: v.createdAt)
        }
        let storedItemDTOs = storedItems.map { item in
            StoredItemDTO(id: item.id, name: item.name, location: item.location, roomArea: item.roomArea,
                          notes: item.notes, imageData: item.imageData,
                          purchasePrice: item.purchasePrice, purchaseDate: item.purchaseDate,
                          isSecondHand: item.isSecondHand, resalePrice: item.resalePrice, resoldDate: item.resoldDate,
                          createdAt: item.createdAt, updatedAt: item.updatedAt)
        }
        let medicineItemDTOs = medicineStocks.map { m in
            MedicineItemDTO(id: m.id, name: m.name, categoryRaw: m.categoryRaw,
                            indications: m.indications, usageMethod: m.usageMethod,
                            storageLocation: m.storageLocation, roomArea: m.roomArea,
                            purchaseDate: m.purchaseDate,
                            expiryDate: m.expiryDate, isOpened: m.isOpened, openedDate: m.openedDate,
                            afterOpenValidDays: m.afterOpenValidDays, remainingQuantity: m.remainingQuantity,
                            precautions: m.precautions, imageData: m.imageData, isDisposed: m.isDisposed,
                            createdAt: m.createdAt, updatedAt: m.updatedAt)
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

        let skillPathDTOs = skillPaths.map { p in
            SkillPathDTO(
                id: p.id, title: p.title, categoryRaw: p.categoryRaw,
                goal: p.goal, weeklyMinutes: p.weeklyMinutes, totalWeeks: p.totalWeeks,
                startedAt: p.startedAt, statusRaw: p.statusRaw,
                currentStageIndex: p.currentStageIndex, lastPracticedAt: p.lastPracticedAt,
                practiceStreakDays: p.practiceStreakDays, practiceCount: p.practiceCount
            )
        }

        let skillStageDTOs = skillStages.map { s in
            SkillStageDTO(
                id: s.id, pathID: s.pathID, index: s.index,
                name: s.name, acceptance: s.acceptance,
                plannedDays: s.plannedDays, isUnlocked: s.isUnlocked,
                isCompleted: s.isCompleted, completedAt: s.completedAt,
                tasksJSON: s.tasksJSON
            )
        }

        let practiceLogDTOs = practiceLogs.map { log in
            SkillPracticeLogDTO(
                id: log.id, pathID: log.pathID, stageIndex: log.stageIndex,
                practicedAt: log.practicedAt, minutes: log.minutes
            )
        }

        // 新增各类均按「时间/名称 + ID」排序保证导出顺序稳定，便于两份备份做文本比对
        let petDTOs = pets.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }.map { p in
            PetProfileDTO(
                id: p.id, name: p.name, typeRaw: p.typeRaw, breed: p.breed, gender: p.gender,
                birthday: p.birthday, adoptionDate: p.adoptionDate, weightKg: p.weightKg,
                microchipId: p.microchipId,
                lastExternalDewormDate: p.lastExternalDewormDate, externalDewormCycleDays: p.externalDewormCycleDays,
                lastInternalDewormDate: p.lastInternalDewormDate, internalDewormCycleDays: p.internalDewormCycleDays,
                lastVaccineDate: p.lastVaccineDate, vaccineCycleDays: p.vaccineCycleDays,
                lastBathDate: p.lastBathDate, bathCycleDays: p.bathCycleDays,
                isReminderEnabled: p.isReminderEnabled, notes: p.notes, createdAt: p.createdAt
            )
        }

        let childDTOs = children.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }.map { c in
            ChildProfileDTO(
                id: c.id, name: c.name, realName: c.realName, genderRaw: c.genderRaw,
                birthday: c.birthday, bloodType: c.bloodType, idCardNumber: c.idCardNumber,
                allergyInfo: c.allergyInfo, completedVaccineIds: c.completedVaccineIds,
                heightCm: c.heightCm, weightKg: c.weightKg, notes: c.notes, createdAt: c.createdAt
            )
        }

        let childGrowthDTOs = childGrowthRecords.sorted { ($0.date, $0.id.uuidString) < ($1.date, $1.id.uuidString) }.map { r in
            ChildGrowthRecordDTO(
                id: r.id, childID: r.child?.id, date: r.date, monthAge: r.monthAge,
                heightCm: r.heightCm, weightKg: r.weightKg, headCircumferenceCm: r.headCircumferenceCm,
                notes: r.notes, createdAt: r.createdAt
            )
        }

        let childMilestoneDTOs = childMilestones.sorted { ($0.date, $0.id.uuidString) < ($1.date, $1.id.uuidString) }.map { r in
            ChildMilestoneRecordDTO(
                id: r.id, childID: r.child?.id, date: r.date, monthAge: r.monthAge,
                categoryRaw: r.categoryRaw, title: r.title, notes: r.notes, createdAt: r.createdAt
            )
        }

        let childHealthVisitDTOs = childHealthVisits.sorted { ($0.date, $0.id.uuidString) < ($1.date, $1.id.uuidString) }.map { r in
            ChildHealthVisitRecordDTO(
                id: r.id, childID: r.child?.id, date: r.date, hospitalOrClinic: r.hospitalOrClinic,
                diagnosis: r.diagnosis, doctorAdvice: r.doctorAdvice, followUpDate: r.followUpDate,
                notes: r.notes, createdAt: r.createdAt
            )
        }

        let childVaccinationDTOs = childVaccinations.sorted { ($0.dateAdministered, $0.id.uuidString) < ($1.dateAdministered, $1.id.uuidString) }.map { r in
            ChildVaccinationRecordDTO(
                id: r.id, childID: r.child?.id, vaccineId: r.vaccineId, vaccineName: r.vaccineName,
                dateAdministered: r.dateAdministered, clinicName: r.clinicName,
                batchNumber: r.batchNumber, reaction: r.reaction, createdAt: r.createdAt
            )
        }

        let reminderActionDTOs = reminderActions.sorted { ($0.occurrenceDate, $0.id.uuidString) < ($1.occurrenceDate, $1.id.uuidString) }.map { a in
            LifeReminderActionDTO(
                id: a.id, sourceKindRaw: a.sourceKindRaw, sourceID: a.sourceID,
                occurrenceDate: a.occurrenceDate, statusRaw: a.statusRaw,
                snoozedUntil: a.snoozedUntil, completedAt: a.completedAt
            )
        }

        let lifeEventProjectDTOs = lifeEventProjects.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }.map { p in
            LifeEventProjectDTO(
                id: p.id, title: p.title, templateRaw: p.templateRaw, targetDate: p.targetDate,
                location: p.location, budgetLimit: p.budgetLimit, statusRaw: p.statusRaw, createdAt: p.createdAt,
                aiDecisionSummary: p.aiDecisionSummary, aiDecisionAt: p.aiDecisionAt
            )
        }

        let lifeEventStageDTOs = lifeEventStages.sorted { ($0.sortOrder, $0.id.uuidString) < ($1.sortOrder, $1.id.uuidString) }.map { s in
            LifeEventStageDTO(
                id: s.id, projectID: s.projectID, title: s.title,
                sortOrder: s.sortOrder, statusRaw: s.statusRaw
            )
        }

        let lifeEventTaskDTOs = lifeEventTasks.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }.map { t in
            LifeEventTaskDTO(
                id: t.id, projectID: t.projectID, stageID: t.stageID, title: t.title,
                detail: t.detail, dueDate: t.dueDate, statusRaw: t.statusRaw,
                ownerName: t.ownerName, createdAt: t.createdAt,
                answersJSON: t.answersJSON, aiDecisionSummary: t.aiDecisionSummary,
                aiActionItemsJSON: t.aiActionItemsJSON, aiConsultedAt: t.aiConsultedAt
            )
        }

        let lifeEventPersonDTOs = lifeEventPeople.sorted { ($0.name, $0.id.uuidString) < ($1.name, $1.id.uuidString) }.map { p in
            LifeEventPersonDTO(
                id: p.id, projectID: p.projectID, name: p.name, role: p.role,
                relationship: p.relationship, phone: p.phone, responsibility: p.responsibility, side: p.side
            )
        }

        let lifeEventExpenseDTOs = lifeEventExpenses.sorted { ($0.title, $0.id.uuidString) < ($1.title, $1.id.uuidString) }.map { e in
            LifeEventExpenseDTO(
                id: e.id, projectID: e.projectID, title: e.title, category: e.category,
                amount: e.amount, paidAmount: e.paidAmount, payee: e.payee,
                dueDate: e.dueDate, note: e.note
            )
        }

        let lifeEventGuestDTOs = lifeEventGuests.sorted { ($0.name, $0.id.uuidString) < ($1.name, $1.id.uuidString) }.map { g in
            LifeEventGuestDTO(
                id: g.id, projectID: g.projectID, name: g.name, relationship: g.relationship,
                side: g.side, phone: g.phone, tableNumber: g.tableNumber, attendanceRaw: g.attendanceRaw
            )
        }

        let omniboxTransactionDTOs = omniboxTransactions.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }.map { t in
            OmniboxTransactionDTO(
                id: t.id, createdAt: t.createdAt, sourceRaw: t.sourceRaw, inputText: t.inputText,
                imageCount: t.imageCount, actionsJSON: t.actionsJSON, statusRaw: t.statusRaw,
                executedAt: t.executedAt, engineRaw: t.engineRaw, undoJSON: t.undoJSON
            )
        }

        let foodIntakeDTOs = foodIntakeRecords.sorted { ($0.date, $0.id.uuidString) < ($1.date, $1.id.uuidString) }.map { r in
            FoodIntakeRecordDTO(
                id: r.id, date: r.date, foodName: r.foodName, foodID: r.foodID,
                portionRaw: r.portionRaw, fullPortionCalories: r.fullPortionCalories,
                consumedRatio: r.consumedRatio, consumedCalories: r.consumedCalories,
                confidence: r.confidence, isManuallyAdjusted: r.isManuallyAdjusted,
                sourceRaw: r.sourceRaw, createdAt: r.createdAt,
                linkedExpenseID: r.linkedExpenseID, imageData: r.imageData
            )
        }

        let waterIntakeDTOs = waterIntakeRecords.sorted { ($0.date, $0.id.uuidString) < ($1.date, $1.id.uuidString) }.map { w in
            WaterIntakeRecordDTO(
                id: w.id, date: w.date, beverageTypeRaw: w.beverageTypeRaw,
                volumeML: w.volumeML, hydrationFactor: w.hydrationFactor,
                effectiveHydrationML: w.effectiveHydrationML, caffeineMG: w.caffeineMG,
                calories: w.calories, customName: w.customName, note: w.note,
                syncedToHealthKit: w.syncedToHealthKit, createdAt: w.createdAt,
                linkedExpenseID: w.linkedExpenseID
            )
        }

        let judgmentFeedbackDTOs = judgmentFeedbacks
            .sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
            .map { f in
                JudgmentFeedbackDTO(
                    id: f.id, createdAt: f.createdAt, inputText: f.inputText,
                    labelRaw: f.labelRaw, verdictRaw: f.verdictRaw,
                    topProbability: f.topProbability, margin: f.margin,
                    runnerUpLabelRaw: f.runnerUpLabelRaw, correctedLabelRaw: f.correctedLabelRaw
                )
            }

        let healthSnapshotDTOs = healthSnapshots
            .sorted { ($0.day, $0.id.uuidString) < ($1.day, $1.id.uuidString) }
            .map { h in
                HealthDaySnapshotRecordDTO(
                    id: h.id, day: h.day,
                    stepCount: h.stepCount, activeEnergy: h.activeEnergy,
                    restingEnergy: h.restingEnergy, dietaryWater: h.dietaryWater,
                    sleepHours: h.sleepHours, sleepREM: h.sleepREM, sleepDeep: h.sleepDeep,
                    heartRate: h.heartRate, restingHeartRate: h.restingHeartRate,
                    heartRateVariability: h.heartRateVariability, bloodOxygen: h.bloodOxygen,
                    bodyTemperature: h.bodyTemperature, walkingSpeed: h.walkingSpeed,
                    respiratoryRate: h.respiratoryRate, workoutMinutes: h.workoutMinutes,
                    workoutCount: h.workoutCount, updatedAt: h.updatedAt
                )
            }

        let metadata = BackupPackage.Metadata(
            schemaVersion: 4,
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
            medicines: medicineItemDTOs,
            dialogueRecords: dialogueDTOs,
            rawMessages: rawMessageDTOs,
            locationSamples: locationDTOs,
            skillPaths: skillPathDTOs,
            skillStages: skillStageDTOs,
            practiceLogs: practiceLogDTOs,
            pets: petDTOs,
            children: childDTOs,
            childGrowthRecords: childGrowthDTOs,
            childMilestones: childMilestoneDTOs,
            childHealthVisits: childHealthVisitDTOs,
            childVaccinations: childVaccinationDTOs,
            reminderActions: reminderActionDTOs,
            lifeEventProjects: lifeEventProjectDTOs,
            lifeEventStages: lifeEventStageDTOs,
            lifeEventTasks: lifeEventTaskDTOs,
            lifeEventPeople: lifeEventPersonDTOs,
            lifeEventExpenses: lifeEventExpenseDTOs,
            lifeEventGuests: lifeEventGuestDTOs,
            omniboxTransactions: omniboxTransactionDTOs,
            foodIntakeRecords: foodIntakeDTOs,
            waterIntakeRecords: waterIntakeDTOs,
            judgmentFeedbacks: judgmentFeedbackDTOs,
            healthSnapshots: healthSnapshotDTOs,
            settings: collectSettingsSnapshot()
        )
    }

    // MARK: - 偏好设置快照

    /// 按白名单收集用户偏好。只读 `object(forKey:) != nil` 的键，
    /// 避免把「用户从未设置、用默认值兜底」的键也写进备份（否则还原会覆盖新设备的合理默认）。
    private func collectSettingsSnapshot() -> SettingsSnapshotDTO {
        let defaults = UserDefaults.standard
        var entries: [String: SettingsValue] = [:]

        for key in AssistantSettingsKeys.stringKeys where defaults.object(forKey: key) != nil {
            entries[key] = .string(defaults.string(forKey: key) ?? "")
        }
        for key in AssistantSettingsKeys.boolKeys where defaults.object(forKey: key) != nil {
            entries[key] = .bool(defaults.bool(forKey: key))
        }
        for key in AssistantSettingsKeys.intKeys where defaults.object(forKey: key) != nil {
            entries[key] = .int(defaults.integer(forKey: key))
        }
        for key in AssistantSettingsKeys.doubleKeys where defaults.object(forKey: key) != nil {
            entries[key] = .double(defaults.double(forKey: key))
        }
        for key in AssistantSettingsKeys.dataKeys where defaults.object(forKey: key) != nil {
            if let data = defaults.data(forKey: key) {
                entries[key] = .data(data)
            }
        }

        return SettingsSnapshotDTO(
            entries: entries,
            wallpaperImageData: AppBackgroundManager.shared.customImageFileData
        )
    }

    /// 必须使用 PIN 码加密导出全量备份数据包
    public func exportEncryptedArchive(pin: String, hint: String? = nil) throws -> (data: Data, filename: String) {
        let cleanPin = pin.trimmingCharacters(in: .whitespacesAndNewlines)
        // 口令长度与 KDF 参数由 Core 校验（8–64 位、迭代 10 万–200 万）
        try BackupEnvelopeCrypto.validatePin(cleanPin)

        let package = try buildBackupPackage()
        // 导出后校验：与还原前校验同一套规则（ID 唯一、外键不悬挂、附件可解码）。
        // 导出侧也要拦——否则「坏备份 + 好加密」只会产出一个到还原时才发现的雷。
        try validate(package: package)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let packageData = try encoder.encode(package)

        // 每份备份独立 32 字节高熵随机盐（同一口令的两份备份密文也不同）
        let saltData = BackupEnvelopeCrypto.makeSalt()
        let combined = try BackupEnvelopeCrypto.seal(
            packageData, pin: cleanPin, salt: saltData,
            iterations: EncryptedBackupEnvelope.defaultIterations
        )

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
}
