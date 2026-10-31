import AssistantCore
import Foundation
import SwiftData

struct LifeCapabilityProvider: CapabilityProvider {
    let moduleID = "life"
    let capabilities: [ActionCapability] = [.lifeRecord]
    let undoKinds: [ActionUndoToken.Kind] = [
        .petRecord, .vehicleRecord, .childRecord, .skillRecord, .idDocument, .lifeEvent
    ]

    func execute(_ action: PlannedAction, prior: [UUID: String], context: ModelContext) throws -> ActionExecutionOutcome {
        guard action.capability == .lifeRecord else {
            throw OmniboxError.invalidParams("life 模块不认识该动作")
        }
        return try executeLifeRecord(action, context: context)
    }

    // MARK: life.record

    /// 生活记录回执：首次建档时补一句说明，避免用户不知道凭空多出一个档案。
    private func lifeRecordSummary(_ action: PlannedAction, createdProfile: String?) -> String {
        let base = OmniboxPlanner.summary(for: .lifeRecord, params: action.params)
        guard let createdProfile else { return base }
        return base + "（已新建档案「\(createdProfile)」）"
    }

    private func executeLifeRecord(_ action: PlannedAction, context: ModelContext) throws -> ActionExecutionOutcome {
        let domain = action.params["domain"] ?? "pet"
        let title = action.params["title"] ?? "生活档案"
        let detail = action.params["detail"] ?? ""

        switch domain {
        case "pet":
            let desc = FetchDescriptor<PetProfile>()
            let pets: [PetProfile]
            do {
                pets = try context.fetch(desc)
            } catch {
                throw OmniboxError.dataUnavailable("暂时读不到宠物档案，本次没有写入，稍后再试一次。")
            }
            // 只有确认库中没有档案时才首次建档；读失败不能落到这条路径
            let createdProfile = pets.isEmpty ? "毛孩子" : nil
            let pet: PetProfile
            if let existing = pets.first {
                pet = existing
            } else {
                let p = PetProfile(name: "毛孩子", type: .cat)
                context.insert(p)
                pet = p
            }
            let snapshot: [String: String] = [
                "lastExternalDewormDate": pet.lastExternalDewormDate?.ISO8601Format() ?? "",
                "lastInternalDewormDate": pet.lastInternalDewormDate?.ISO8601Format() ?? "",
                "lastVaccineDate": pet.lastVaccineDate?.ISO8601Format() ?? "",
                "lastBathDate": pet.lastBathDate?.ISO8601Format() ?? ""
            ]
            if detail.contains("体外驱虫") { pet.lastExternalDewormDate = .now }
            else if detail.contains("体内驱虫") { pet.lastInternalDewormDate = .now }
            else if detail.contains("疫苗") { pet.lastVaccineDate = .now }
            else if detail.contains("洗澡") { pet.lastBathDate = .now }
            else if let val = Double(action.params["value"] ?? "") { pet.weightKg = val }
            try context.save()
            return ActionExecutionOutcome(
                id: action.id, action: action,
                summary: lifeRecordSummary(action, createdProfile: createdProfile),
                undo: OmniboxUndoToken(kind: .petRecord, recordID: pet.id, snapshotJSON: ActionUndoToken.makeSnapshotData(snapshot))
            )

        case "vehicle":
            let desc = FetchDescriptor<VehicleProfile>()
            let vehicles: [VehicleProfile]
            do {
                vehicles = try context.fetch(desc)
            } catch {
                throw OmniboxError.dataUnavailable("暂时读不到车辆档案，本次没有写入，稍后再试一次。")
            }
            let createdProfile = vehicles.isEmpty ? "爱车" : nil
            let vehicle: VehicleProfile
            if let existing = vehicles.first {
                vehicle = existing
            } else {
                let v = VehicleProfile(name: "爱车", plateNumber: "待完善")
                context.insert(v)
                vehicle = v
            }
            let snapshot: [String: String] = [
                "lastEnergyRefillDate": vehicle.lastEnergyRefillDate?.ISO8601Format() ?? "",
                "lastMaintenanceDate": vehicle.lastMaintenanceDate?.ISO8601Format() ?? ""
            ]
            if detail.contains("补能") || detail.contains("加油") || detail.contains("充电") {
                vehicle.completeEnergyRefill()
            } else if detail.contains("保养") {
                vehicle.completeMaintenance()
            } else if let val = Double(action.params["value"] ?? "") {
                vehicle.currentMileage = val
            }
            try context.save()
            return ActionExecutionOutcome(
                id: action.id, action: action,
                summary: lifeRecordSummary(action, createdProfile: createdProfile),
                undo: OmniboxUndoToken(kind: .vehicleRecord, recordID: vehicle.id, snapshotJSON: ActionUndoToken.makeSnapshotData(snapshot))
            )

        case "child":
            let desc = FetchDescriptor<ChildProfile>()
            let children: [ChildProfile]
            do {
                children = try context.fetch(desc)
            } catch {
                throw OmniboxError.dataUnavailable("暂时读不到宝宝档案，本次没有写入，稍后再试一次。")
            }
            let createdProfile = children.isEmpty ? "宝宝" : nil
            let child: ChildProfile
            if let existing = children.first {
                child = existing
            } else {
                let c = ChildProfile(name: "宝宝")
                context.insert(c)
                child = c
            }
            let record = ChildMilestoneRecord(title: detail.isEmpty ? title : detail, child: child)
            context.insert(record)
            try context.save()
            return ActionExecutionOutcome(
                id: action.id, action: action,
                summary: lifeRecordSummary(action, createdProfile: createdProfile),
                undo: OmniboxUndoToken(kind: .childRecord, recordID: record.id)
            )

        case "skill":
            let desc = FetchDescriptor<SkillPath>()
            let skills: [SkillPath]
            do {
                skills = try context.fetch(desc)
            } catch {
                throw OmniboxError.dataUnavailable("暂时读不到技能路径，本次没有写入，稍后再试一次。")
            }
            let createdProfile = skills.isEmpty ? title : nil
            let skill: SkillPath
            if let existing = skills.first {
                skill = existing
            } else {
                let s = SkillPath(title: title, category: .generic, goal: "持续练习与提升", weeklyMinutes: 120, totalWeeks: 12)
                context.insert(s)
                skill = s
            }
            let log = SkillPracticeLog(
                pathID: skill.id,
                stageIndex: skill.currentStageIndex,
                practicedAt: .now,
                minutes: Int(action.params["value"] ?? "") ?? 30
            )
            skill.lastPracticedAt = .now
            skill.practiceCount += 1
            context.insert(log)
            try context.save()
            return ActionExecutionOutcome(
                id: action.id, action: action,
                summary: lifeRecordSummary(action, createdProfile: createdProfile),
                undo: OmniboxUndoToken(kind: .skillRecord, recordID: log.id)
            )

        case "document":
            let doc = IDDocumentItem(title: title, notes: detail)
            context.insert(doc)
            try context.save()
            return ActionExecutionOutcome(
                id: action.id, action: action,
                summary: OmniboxPlanner.summary(for: .lifeRecord, params: action.params),
                undo: OmniboxUndoToken(kind: .idDocument, recordID: doc.id)
            )

        default:
            let defaultTargetDate = Calendar.current.date(byAdding: .day, value: 30, to: .now) ?? .now
            let project = LifeEventProject(title: title, template: .custom, targetDate: defaultTargetDate)
            context.insert(project)
            try context.save()
            return ActionExecutionOutcome(
                id: action.id, action: action,
                summary: OmniboxPlanner.summary(for: .lifeRecord, params: action.params),
                undo: OmniboxUndoToken(kind: .lifeEvent, recordID: project.id)
            )
        }
    }

    func undo(_ token: OmniboxUndoToken, context: ModelContext) throws {
        switch token.kind {
        case .petRecord:
            if let id = token.recordID {
                let descriptor = FetchDescriptor<PetProfile>(predicate: #Predicate { $0.id == id })
                if let pet = try? context.fetch(descriptor).first, let snap = token.decodeSnapshot() {
                    let f = ISO8601DateFormatter()
                    if let iso = snap["lastExternalDewormDate"] { pet.lastExternalDewormDate = f.date(from: iso) }
                    if let iso = snap["lastInternalDewormDate"] { pet.lastInternalDewormDate = f.date(from: iso) }
                    if let iso = snap["lastVaccineDate"] { pet.lastVaccineDate = f.date(from: iso) }
                    if let iso = snap["lastBathDate"] { pet.lastBathDate = f.date(from: iso) }
                }
            }
        case .vehicleRecord:
            if let id = token.recordID {
                let descriptor = FetchDescriptor<VehicleProfile>(predicate: #Predicate { $0.id == id })
                if let v = try? context.fetch(descriptor).first, let snap = token.decodeSnapshot() {
                    let f = ISO8601DateFormatter()
                    if let iso = snap["lastEnergyRefillDate"] { v.lastEnergyRefillDate = f.date(from: iso) }
                    if let iso = snap["lastMaintenanceDate"] { v.lastMaintenanceDate = f.date(from: iso) }
                }
            }
        case .childRecord:
            if let id = token.recordID {
                let descGrowth = FetchDescriptor<ChildGrowthRecord>(predicate: #Predicate { $0.id == id })
                if let g = try? context.fetch(descGrowth).first { context.delete(g) }
                let descMilestone = FetchDescriptor<ChildMilestoneRecord>(predicate: #Predicate { $0.id == id })
                if let m = try? context.fetch(descMilestone).first { context.delete(m) }
            }
        case .skillRecord:
            if let id = token.recordID {
                let desc = FetchDescriptor<SkillPracticeLog>(predicate: #Predicate { $0.id == id })
                if let log = try? context.fetch(desc).first { context.delete(log) }
            }
        case .idDocument:
            if let id = token.recordID {
                let desc = FetchDescriptor<IDDocumentItem>(predicate: #Predicate { $0.id == id })
                if let doc = try? context.fetch(desc).first { context.delete(doc) }
            }
        case .lifeEvent:
            if let id = token.recordID {
                let desc = FetchDescriptor<LifeEventProject>(predicate: #Predicate { $0.id == id })
                if let p = try? context.fetch(desc).first { context.delete(p) }
            }
        default:
            return
        }
        try context.save()
    }
}
