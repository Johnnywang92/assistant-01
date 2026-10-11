import Foundation
import SwiftData

enum LifeEventTemplate: String, Codable, CaseIterable, Identifiable {
    case engagementWedding = "订婚与结婚典礼"
    case houseMove = "乔迁新居 / 买房装修"
    case newborn = "添丁之喜 / 满月百日周岁宴"
    case graduation = "金榜题名 / 升学宴"
    case birthdayBanquet = "长辈寿宴"
    case custom = "自定义人生大事"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .engagementWedding: return "heart.fill"
        case .houseMove: return "house.fill"
        case .newborn: return "figure.and.child.holdinghands"
        case .graduation: return "graduationcap.fill"
        case .birthdayBanquet: return "gift.fill"
        case .custom: return "sparkles"
        }
    }

    var defaultStages: [String] {
        switch self {
        case .engagementWedding: return ["确定婚期与预算", "场地与供应商", "宾客与物资", "婚礼前冲刺", "婚礼当天", "婚后收尾"]
        case .houseMove: return ["确定房屋与预算", "设计与施工", "家电家具进场", "搬家与整理", "温居筹备"]
        case .newborn: return ["孕期与待产", "生产准备", "月子安排", "宴席筹备", "宴席当天"]
        case .graduation: return ["确认升学结果", "场地与宾客", "流程与物资", "宴席当天"]
        case .birthdayBanquet: return ["确定日期与场地", "宾客与菜单", "流程与礼物", "宴席当天"]
        case .custom: return ["准备阶段", "执行阶段", "收尾阶段"]
        }
    }

    var starterTasks: [String] {
        switch self {
        case .engagementWedding: return ["确认双方家庭意见", "确定预算上限", "整理宾客名单", "确认场地与供应商", "制定当天流程"]
        case .houseMove: return ["确认预算与入住日期", "整理装修需求", "列出家电家具清单", "预约搬家公司", "准备温居物资"]
        case .newborn: return ["整理待产包", "确认陪产与月子安排", "准备宝宝用品", "确定宴席日期", "整理宾客名单"]
        case .graduation: return ["确认录取与出席名单", "预订宴席场地", "确定菜单与流程", "准备邀请通知"]
        case .birthdayBanquet: return ["确认长辈意愿", "预订场地", "整理亲友名单", "准备纪念礼物", "确定宴席流程"]
        case .custom: return ["明确目标与日期", "列出需要协调的人和事", "确定预算与重点节点"]
        }
    }
}

@Model
final class LifeEventProject {
    var id: UUID
    var title: String
    var templateRaw: String
    var targetDate: Date
    var location: String?
    var budgetLimit: Double
    var statusRaw: String
    var createdAt: Date

    init(title: String, template: LifeEventTemplate, targetDate: Date, location: String? = nil, budgetLimit: Double = 0) {
        self.id = UUID()
        self.title = title
        self.templateRaw = template.rawValue
        self.targetDate = targetDate
        self.location = location
        self.budgetLimit = budgetLimit
        self.statusRaw = "active"
        self.createdAt = .now
    }

    var template: LifeEventTemplate { LifeEventTemplate(rawValue: templateRaw) ?? .custom }
    var daysRemaining: Int {
        Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: .now), to: Calendar.current.startOfDay(for: targetDate)).day ?? 0
    }
}

@Model
final class LifeEventStage {
    var id: UUID
    var projectID: UUID
    var title: String
    var sortOrder: Int
    var statusRaw: String

    init(projectID: UUID, title: String, sortOrder: Int) {
        self.id = UUID()
        self.projectID = projectID
        self.title = title
        self.sortOrder = sortOrder
        self.statusRaw = "active"
    }
}

@Model
final class LifeEventTask {
    var id: UUID
    var projectID: UUID
    var stageID: UUID
    var title: String
    var detail: String?
    var dueDate: Date?
    var statusRaw: String
    var ownerName: String?
    var createdAt: Date

    init(projectID: UUID, stageID: UUID, title: String, dueDate: Date? = nil) {
        self.id = UUID()
        self.projectID = projectID
        self.stageID = stageID
        self.title = title
        self.detail = nil
        self.dueDate = dueDate
        self.statusRaw = "active"
        self.ownerName = nil
        self.createdAt = .now
    }

    var isDone: Bool { statusRaw == "done" }
}

@Model
final class LifeEventPerson {
    var id: UUID
    var projectID: UUID
    var name: String
    var role: String
    var relationship: String
    var phone: String
    var responsibility: String
    var side: String

    init(projectID: UUID, name: String, role: String, relationship: String = "", phone: String = "", responsibility: String = "", side: String = "") {
        self.id = UUID()
        self.projectID = projectID
        self.name = name
        self.role = role
        self.relationship = relationship
        self.phone = phone
        self.responsibility = responsibility
        self.side = side
    }
}

@Model
final class LifeEventExpense {
    var id: UUID
    var projectID: UUID
    var title: String
    var category: String
    var amount: Double
    var paidAmount: Double
    var payee: String
    var dueDate: Date?
    var note: String

    init(projectID: UUID, title: String, category: String = "其他", amount: Double, paidAmount: Double = 0, payee: String = "", dueDate: Date? = nil, note: String = "") {
        self.id = UUID()
        self.projectID = projectID
        self.title = title
        self.category = category
        self.amount = amount
        self.paidAmount = paidAmount
        self.payee = payee
        self.dueDate = dueDate
        self.note = note
    }
}

@Model
final class LifeEventGuest {
    var id: UUID
    var projectID: UUID
    var name: String
    var relationship: String
    var side: String
    var phone: String
    var tableNumber: String
    var attendanceRaw: String

    init(projectID: UUID, name: String, relationship: String = "", side: String = "", phone: String = "", tableNumber: String = "", attendanceRaw: String = "pending") {
        self.id = UUID()
        self.projectID = projectID
        self.name = name
        self.relationship = relationship
        self.side = side
        self.phone = phone
        self.tableNumber = tableNumber
        self.attendanceRaw = attendanceRaw
    }

    var attendanceTitle: String {
        switch attendanceRaw {
        case "yes": return "已确认"
        case "no": return "不出席"
        default: return "待确认"
        }
    }
}

enum LifeEventTemplateFactory {
    @MainActor
    static func createProject(title: String, template: LifeEventTemplate, targetDate: Date, location: String?, budgetLimit: Double, in context: ModelContext) -> LifeEventProject {
        let project = LifeEventProject(title: title, template: template, targetDate: targetDate, location: location, budgetLimit: budgetLimit)
        context.insert(project)
        let stages = template.defaultStages.enumerated().map { index, name in
            let stage = LifeEventStage(projectID: project.id, title: name, sortOrder: index)
            context.insert(stage)
            return stage
        }
        for (index, taskTitle) in template.starterTasks.enumerated() {
            let stage = stages[min(index, stages.count - 1)]
            context.insert(LifeEventTask(projectID: project.id, stageID: stage.id, title: taskTitle))
        }
        try? context.save()
        return project
    }
}
