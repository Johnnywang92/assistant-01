import Foundation
import SwiftData

/// 人生大事模板的分组，用于创建页分区展示。
enum LifeEventCategory: String, CaseIterable, Identifiable {
    case wedding = "婚恋与家庭"
    case home = "置业与安家"
    case baby = "育儿与成长"
    case car = "出行与座驾"
    case banquet = "宴席与升学"
    case other = "自定义"

    var id: String { rawValue }
    var displayName: String { L10n.tr(rawValue) }
}

/// 分组后的模板集合，供 Form 分区渲染。
struct LifeEventTemplateGroup: Identifiable {
    let category: LifeEventCategory
    let templates: [LifeEventTemplate]
    var id: String { category.rawValue }
}

enum LifeEventTemplate: String, Codable, CaseIterable, Identifiable {
    // 婚恋
    case engagementWedding = "订婚与结婚典礼"
    // 置业（v2 细分：购房 / 装修 / 搬迁各自独立）
    case buyHouse = "买房"
    case homeRenovation = "装修"
    case movingHome = "搬家乔迁"
    case houseMove = "乔迁新居 / 买房装修" // 旧模板，仅用于兼容历史项目
    // 育儿
    case childbirth = "生娃待产"
    case secondChild = "二胎"
    case babyCelebration = "满月百日 / 周岁宴"
    case newborn = "添丁之喜 / 满月百日周岁宴" // 旧模板，仅用于兼容历史项目
    // 出行
    case buyCar = "买车"
    // 宴席与升学
    case graduation = "金榜题名 / 升学宴"
    case birthdayBanquet = "长辈寿宴"
    case custom = "自定义人生大事"

    var id: String { rawValue }
    var displayName: String { L10n.tr(rawValue) }

    /// 历史项目仍会持有旧的合并模板，创建页不再展示。
    var isLegacy: Bool {
        switch self {
        case .houseMove, .newborn: return true
        default: return false
        }
    }

    /// 创建页可选模板（不含历史兼容项）。
    static var selectableCases: [LifeEventTemplate] { allCases.filter { !$0.isLegacy } }

/// 按声明顺序把可选模板分组，供 Form 分区渲染。
static var groupedSelectableCases: [LifeEventTemplateGroup] {
    LifeEventCategory.allCases.compactMap { category in
        let items = selectableCases.filter { $0.category == category }
        return items.isEmpty ? nil : LifeEventTemplateGroup(category: category, templates: items)
    }
}

    var category: LifeEventCategory {
        switch self {
        case .engagementWedding: return .wedding
        case .buyHouse, .homeRenovation, .movingHome, .houseMove: return .home
        case .childbirth, .secondChild, .babyCelebration, .newborn: return .baby
        case .buyCar: return .car
        case .graduation, .birthdayBanquet: return .banquet
        case .custom: return .other
        }
    }

    var icon: String {
        switch self {
        case .engagementWedding: return "heart.fill"
        case .buyHouse: return "building.columns.fill"
        case .homeRenovation: return "paintbrush.pointed"
        case .movingHome, .houseMove: return "shippingbox.fill"
        case .childbirth, .newborn: return "figure.and.child.holdinghands"
        case .secondChild: return "figure.2.and.child.holdinghands"
        case .babyCelebration: return "birthday.cake.fill"
        case .buyCar: return "car.fill"
        case .graduation: return "graduationcap.fill"
        case .birthdayBanquet: return "gift.fill"
        case .custom: return "sparkles"
        }
    }

    /// 该模板是否需要「宾客与邀请」板块（买车、装修等事务型项目不需要）。
    var supportsGuests: Bool {
        switch self {
        case .buyHouse, .homeRenovation, .childbirth, .secondChild, .buyCar: return false
        default: return true
        }
    }

    /// 模板默认推荐的项目名称。
    var defaultTitle: String {
        let raw: String = switch self {
        case .engagementWedding: "我们的婚礼"
        case .buyHouse: "置业购房计划"
        case .homeRenovation: "新家装修"
        case .movingHome, .houseMove: "乔迁新居"
        case .childbirth: "宝宝待产与新生"
        case .secondChild: "二宝降生筹备"
        case .babyCelebration, .newborn: "宝宝百日/周岁宴"
        case .buyCar: "提车计划"
        case .graduation: "升学宴"
        case .birthdayBanquet: "长辈寿宴"
        case .custom: "人生大事筹备"
        }
        return L10n.tr(raw)
    }

    /// 「人物与分工」板块的空态提示，按模板给出对应的角色示例。
    var peopleHint: String {
        let raw: String = switch self {
        case .engagementWedding: "添加双方父母、亲友或供应商，明确每个人负责的事情。"
        case .buyHouse: "添加中介、贷款专员、验房师等角色，明确谁对接首付、过户与验房。"
        case .homeRenovation: "添加设计师、装修公司、监理与主材供应商，明确各自的交付范围。"
        case .movingHome, .houseMove: "添加搬家公司、保洁与安装师傅，明确每个人的到场时间。"
        case .childbirth: "添加月嫂、医院陪护与双方长辈，明确谁负责哪一段照护。"
        case .secondChild: "添加月嫂、老人与幼儿园老师，明确大宝过渡与二宝照护的分工。"
        case .babyCelebration, .newborn: "添加双方亲友与摄像、主持等供应商，明确当天分工。"
        case .buyCar: "添加销售顾问、保险与上牌代办，明确购车流程中的对接人。"
        case .graduation: "添加学校老师、亲友与摄像，明确到场与流程分工。"
        case .birthdayBanquet: "添加亲戚代表、司仪与摄像，明确寿宴当天谁操办。"
        case .custom: "添加需要协调的人或供应商，明确每个人负责的事情。"
        }
        return L10n.tr(raw)
    }

    /// 按模板适配的开销分类，避免把「摄影摄像」填到买房账本里。
    var expenseCategories: [String] {
        let raw: [String] = switch self {
        case .engagementWedding: ["场地", "餐饮", "服装礼服", "摄影摄像", "交通住宿", "珠宝聘礼", "其他"]
        case .buyHouse: ["房款首付", "税费", "中介服务", "贷款费用", "验房加固", "搬迁安置", "其他"]
        case .homeRenovation: ["水电改造", "主材", "人工", "家电家具", "软装饰品", "保洁通风", "其他"]
        case .movingHome, .houseMove: ["搬家公司", "打包耗材", "保洁通风", "家电家具", "宴请温居", "其他"]
        case .childbirth: ["产检与分娩", "月子中心", "待产用品", "婴儿用品", "婴儿医疗", "满月宴席", "其他"]
        case .secondChild: ["产检与分娩", "月子中心", "待产用品", "婴儿用品", "大宝过渡", "宴席礼金", "其他"]
        case .babyCelebration, .newborn: ["场地", "餐饮", "服装礼服", "摄影摄像", "伴手礼", "交通住宿", "其他"]
        case .buyCar: ["车款", "保险", "上牌", "装饰美容", "保养维修", "停车车位", "其他"]
        case .graduation: ["场地", "餐饮", "伴手礼", "服装造型", "摄影摄像", "交通住宿", "其他"]
        case .birthdayBanquet: ["场地", "餐饮", "寿桃寿礼", "服装造型", "摄影摄像", "红包礼金", "其他"]
        case .custom: ["场地", "采购", "服务费", "交通住宿", "物资", "其他"]
        }
        return raw.map { L10n.tr($0) }
    }

    var defaultStages: [String] {
        let raw: [String] = switch self {
        case .engagementWedding: ["确定婚期与预算", "场地与供应商", "宾客与物资", "婚礼前冲刺", "婚礼当天", "婚后收尾"]
        case .buyHouse: ["确定购房资格与预算", "看房与选筹", "首付与贷款准备", "定金与网签", "过户与税费", "验房与交付", "搬家入住"]
        case .homeRenovation: ["明确需求与风格", "量房与设计", "预算与报价对比", "拆改与施工", "主材与安装", "软装与入住", "验收与保修"]
        case .movingHome: ["制定搬家计划", "整理与打包", "预约搬运", "搬迁当天", "新居安顿"]
        case .houseMove: ["确定房屋与预算", "设计与施工", "家电家具进场", "搬家与整理", "温居筹备"]
        case .childbirth: ["备孕与孕期", "待产准备", "生产与住院", "月子与康复", "回家与育婴", "疫苗与体检"]
        case .secondChild: ["家庭共识与准备", "孕期与产检", "大宝过渡", "生产与住院", "月子与家庭分工", "手足适应"]
        case .babyCelebration: ["确定日期与形式", "场地与菜单", "宾客与邀请", "流程与物资", "宴席当天"]
        case .newborn: ["孕期与待产", "生产准备", "月子安排", "宴席筹备", "宴席当天"]
        case .buyCar: ["确定需求与预算", "选车与试驾", "谈价与金融方案", "上牌与保险", "提车与装饰", "用车与保养"]
        case .graduation: ["确认升学结果", "场地与宾客", "流程与物资", "宴席当天"]
        case .birthdayBanquet: ["确定日期与场地", "宾客与菜单", "流程与礼物", "宴席当天"]
        case .custom: ["准备阶段", "执行阶段", "收尾阶段"]
        }
        return raw.map { L10n.tr($0) }
    }

    var starterTasks: [String] {
        let raw: [String] = switch self {
        case .engagementWedding: ["确认双方家庭意见", "确定预算上限", "整理宾客名单", "确认场地与供应商", "制定当天流程"]
        case .buyHouse: ["核对购房资格与征信", "确定总价上限与首付比例", "整理收入证明与贷款材料", "安排看房并记录对比", "选定目标房源", "准备网签与过户资料", "预约验房与房屋验收"]
        case .homeRenovation: ["梳理功能需求与预算", "确定装修风格", "预约量房与设计沟通", "对比装修公司方案与报价", "确认施工合同与工期", "跟进水电改造验收", "安排开荒保洁与通风"]
        case .movingHome: ["确定搬家日期与预算", "筛选搬家公司并询价", "清理闲置与断舍离", "准备纸箱与打包材料", "预约新居保洁与换锁", "办理水电燃气与网络过户", "更新快递与证件地址"]
        case .houseMove: ["确认预算与入住日期", "整理装修需求", "列出家电家具清单", "预约搬家公司", "准备温居物资"]
        case .childbirth: ["确认孕检与分娩医院", "整理待产包与证件", "确认陪产与家属陪护", "预约月嫂或月子中心", "准备新生儿衣物与用品", "办理出生医学证明", "安排满月与百日宴"]
        case .secondChild: ["与伴侣及大宝沟通计划", "评估居住空间与预算", "确认产检与分娩安排", "为大宝调整作息与入学", "准备二宝专属用品", "安排老人或月嫂支援", "制定大宝陪伴规则"]
        case .babyCelebration: ["确定宴席日期与规模", "选择场地与餐饮形式", "整理宾客名单与伴手礼", "设计当天流程与环节", "准备宝宝服装与道具", "安排摄影摄像与主持"]
        case .newborn: ["整理待产包", "确认陪产与月子安排", "准备宝宝用品", "确定宴席日期", "整理宾客名单"]
        case .buyCar: ["明确购车预算与用途", "对比车型配置与口碑", "预约试驾体验", "与销售确认价格与赠品", "准备上牌材料与保险", "确认交车与验车流程", "安排首保与停车位"]
        case .graduation: ["确认录取与出席名单", "预订宴席场地", "确定菜单与流程", "准备邀请通知"]
        case .birthdayBanquet: ["确认长辈意愿", "预订场地", "整理亲友名单", "准备纪念礼物", "确定宴席流程"]
        case .custom: ["明确目标与日期", "列出需要协调的人和事", "确定预算与重点节点"]
        }
        return raw.map { L10n.tr($0) }
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
    /// 项目级 AI 全局决策摘要（粘贴大模型全局规划回复后保存）。
    var aiDecisionSummary: String?
    var aiDecisionAt: Date?

    init(title: String, template: LifeEventTemplate, targetDate: Date, location: String? = nil, budgetLimit: Double = 0) {
        self.id = UUID()
        self.title = title
        self.templateRaw = template.rawValue
        self.targetDate = targetDate
        self.location = location
        self.budgetLimit = budgetLimit
        self.statusRaw = "active"
        self.createdAt = .now
        self.aiDecisionSummary = nil
        self.aiDecisionAt = nil
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
    /// 需求问答的结构化答案（JSON：questionId → {presets, note}），由
    /// `LifeEventTaskPlanningEngine.encodeAnswers/decodeAnswers` 存取。
    var answersJSON: String?
    /// 大模型决策回复的完整摘要（粘贴回填后保存）。
    var aiDecisionSummary: String?
    /// 从大模型输出解析并导入的行动项清单（JSON 字符串数组，仅作记录展示）。
    var aiActionItemsJSON: String?
    var aiConsultedAt: Date?

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
        self.answersJSON = nil
        self.aiDecisionSummary = nil
        self.aiActionItemsJSON = nil
        self.aiConsultedAt = nil
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
        case "yes": return L10n.tr("已确认")
        case "no": return L10n.tr("不出席")
        default: return L10n.tr("待确认")
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
