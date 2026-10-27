import Foundation

// MARK: - 动作能力类型（扩充至 16 类全域生活动作空间）

/// 助理可理解与派发的动作能力类型（纯数据模型，下沉 AssistantCore）
public enum ActionCapability: String, Codable, CaseIterable, Sendable {
    // 既有创建类
    /// 记一笔收支
    case expenseCreate = "expense.create"
    /// 建一条待办
    case todoCreate = "todo.create"
    /// 收集箱速记备忘
    case memoInbox = "memo.inbox"

    // 新增写/改类
    /// 修改待办事项（标题/时间/地点/备注）
    case todoUpdate = "todo.update"
    /// 完成待办事项
    case todoComplete = "todo.complete"
    /// 取消/删除待办事项（破坏性动作，强制确认）
    case todoCancel = "todo.cancel"
    /// 顺延提醒时间（10分钟 / 1小时 / 明早9点 / 自定义）
    case reminderSnooze = "reminder.snooze"
    /// 修改账目记录（破坏性动作，强制确认）
    case expenseUpdate = "expense.update"

    // 新增只读类
    /// 实体详情只读查询与高亮回显
    case queryLookup = "query.lookup"

    // 全域生活记录新增类
    /// 记录一顿用餐或食物热量
    case foodRecord = "food.record"
    /// 记录饮水或饮品摄入（含黑咖啡/茶/奶茶科学折算）
    case waterRecord = "water.record"
    /// 记录物品收纳存放位置或家庭常备药
    case storageRecord = "storage.record"
    /// 记录习惯完成打卡或服药打卡
    case habitLog = "habit.log"
    /// 新建纪念日/生日/倒数日/订阅续费/保质期预警
    case anniversaryCreate = "anniversary.create"
    /// 添加随身防丢与出门检查清单项
    case departureAdd = "departure.add"
    /// 记录垂类生活档案（宠物养护/爱车补能保养/育儿成长/技能练习/重要证件/人生大事）
    case lifeRecord = "life.record"

    /// 是否为破坏性动作（无论置信度多高，必须过确认卡，不能由模型直接自动执行）
    public var isDestructive: Bool {
        switch self {
        case .todoCancel, .expenseUpdate:
            return true
        default:
            return false
        }
    }

    /// 动作是否强制要求人工确认
    public var requiresConfirmation: Bool {
        isDestructive
    }
}

// MARK: - 计划动作模型

/// 理解层产出的计划动作节点
public struct ActionItem: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var capability: ActionCapability
    /// 能力所需参数字典（键值均为字符串，以宽容适配模型输出）
    public var params: [String: String]
    /// 置信度 0~1
    public var confidence: Double
    /// 置信度评估原因
    public var confidenceReason: String?
    /// 依赖的前序动作 id 列表（拓扑序执行）
    public var dependsOn: [UUID]
    /// 用户在确认卡中是否勾选执行
    public var isSelected: Bool
    /// 一句话预览文案
    public var summary: String

    public static let lowConfidenceThreshold: Double = 0.6

    public init(
        id: UUID = UUID(),
        capability: ActionCapability,
        params: [String: String] = [:],
        confidence: Double = 0.85,
        confidenceReason: String? = nil,
        dependsOn: [UUID] = [],
        isSelected: Bool = true,
        summary: String = ""
    ) {
        self.id = id
        self.capability = capability
        self.params = params
        self.confidence = confidence
        self.confidenceReason = confidenceReason
        self.dependsOn = dependsOn
        self.isSelected = isSelected
        self.summary = summary
    }

    /// 无论模型给出的置信度多高，破坏性动作强制进入确认卡；
    /// 普通动作低于阈值时进入确认卡。
    public var needsConfirmation: Bool {
        if capability.requiresConfirmation {
            return true
        }
        return confidence < Self.lowConfidenceThreshold
    }
}

// MARK: - 撤销令牌（升级支持修改式回滚）

/// 事务回滚令牌：支持「删除回滚」与「快照式原值还原」
public struct ActionUndoToken: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case todo
        case expense
        case memoLine
        case foodRecord
        case waterRecord
        case storageRecord
        case medicineRecord
        case habitLog
        case medicationLog
        case anniversary
        case subscription
        case itemExpiry
        case departureItem
        case petRecord
        case vehicleRecord
        case childRecord
        case skillRecord
        case idDocument
        case lifeEvent
    }

    public var kind: Kind
    public var recordID: UUID?
    /// memo 行内容（按行删除用）
    public var memoLine: String?
    /// 修改前字段字典的 JSON 快照（修改式动作撤销时用于还原字段原值）
    public var snapshotJSON: Data?

    public init(
        kind: Kind,
        recordID: UUID? = nil,
        memoLine: String? = nil,
        snapshotJSON: Data? = nil
    ) {
        self.kind = kind
        self.recordID = recordID
        self.memoLine = memoLine
        self.snapshotJSON = snapshotJSON
    }

    /// 便捷方法：将改动前字段字典序列化为快照
    public static func makeSnapshotData(_ dict: [String: String]) -> Data? {
        try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
    }

    /// 便捷方法：解析改动前字段快照
    public func decodeSnapshot() -> [String: String]? {
        guard let data = snapshotJSON else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: String]
    }
}

// MARK: - 动作解析引擎（纯逻辑、宽容解析小模型畸形输出）

public enum ActionParser: Sendable {

    /// 宽容解析模型或投喂口的 JSON 输出：
    /// 1. 剥掉 markdown 代码围栏（```json / ```）
    /// 2. 截取最外层 JSON 数组（[ ... ]）
    /// 3. 修复小模型常见的尾逗号（, } / , ]）
    /// 4. 字符串与数字类型宽容解出
    /// 5. 拓扑依赖注入（待办依赖记账）
    ///
    /// 分类细节（截断/非法 capability/空数组）见 `ActionOutputParser.classify`，此处保持旧契约：
    /// 合法数组 → 动作数组（可为空），彻底畸形 → nil。
    public static func parseActionJSON(_ raw: String) -> [ActionItem]? {
        switch ActionOutputParser.classify(raw) {
        case .ok(let actions):
            return actions
        case .emptyArray:
            return []
        case .failed:
            return nil
        }
    }

    /// 生成默认的预览文案
    public static func generateSummary(for capability: ActionCapability, params: [String: String]) -> String {
        switch capability {
        case .expenseCreate:
            let amount = params["amount"] ?? ""
            let income = params["isIncome"] == "true"
            let cat = params["category"] ?? "支出"
            let title = params["title"] ?? "日常消费"
            return "\(income ? "+" : "-")¥\(amount) · \(cat) · \(title)"

        case .expenseUpdate:
            let target = params["target"] ?? "既有支出"
            // 新金额在 newAmount（执行器键）；amount 只作匹配提示，展示也认它以免旧数据丢文案
            let amount = (params["newAmount"].flatMap { $0.isEmpty ? nil : $0 } ?? params["amount"]).map { " 改为 ¥\($0)" } ?? ""
            return "修改账目：\(target)\(amount)"

        case .todoCreate:
            let title = params["title"] ?? "未命名事项"
            var parts = [title]
            if let days = params["dueAtDays"] {
                parts.append("\(days)天后")
            } else if let iso = params["dueAtISO"] {
                parts.append(iso)
            }
            return parts.joined(separator: " · ")

        case .todoUpdate:
            let target = params["target"] ?? params["title"] ?? "指定待办"
            return "修改待办：\(target)"

        case .todoComplete:
            let target = params["target"] ?? params["title"] ?? "指定事项"
            return "完成待办：\(target)"

        case .todoCancel:
            let target = params["target"] ?? params["title"] ?? "指定事项"
            return "取消待办：\(target)"

        case .reminderSnooze:
            let target = params["target"] ?? "提醒事项"
            let duration = params["duration"] ?? "稍后"
            return "推迟提醒：\(target)（\(duration)）"

        case .memoInbox:
            let memo = params["memo"] ?? ""
            return "收入收集箱：" + String(memo.prefix(30))

        case .queryLookup:
            let target = params["target"] ?? params["query"] ?? "查询事项"
            return "查找并高亮：\(target)"

        case .foodRecord:
            let foodName = params["foodName"] ?? "餐食"
            let slot = params["mealSlot"] ?? "餐饮"
            let cal = params["calories"] != nil ? " · 约 \(params["calories"]!)千卡" : ""
            return "记录饮食：\(foodName)（\(slot)\(cal)）"

        case .waterRecord:
            let bevLabel = params["customName"] ?? params["beverageType"] ?? "白开水"
            let vol = Double(params["volumeML"] ?? "") ?? 250
            let bevType = HydrationBeverageType.fromLabel(params["beverageType"] ?? bevLabel)
            let eff = Int((vol * bevType.defaultHydrationFactor).rounded())
            return "记录饮水：\(bevLabel) \(Int(vol))ml（折算补水 \(eff)ml）"

        case .storageRecord:
            let name = params["name"] ?? "物品"
            let loc = params["location"] ?? "默认位置"
            let room = params["roomArea"].map { "\($0) · " } ?? ""
            let isMed = params["isMedicine"] == "true"
            return "\(isMed ? "常备药入库" : "物品收纳")：\(name) → \(room)\(loc)"

        case .habitLog:
            let target = params["target"] ?? "打卡项"
            let isMed = params["kind"] == "medication"
            let dosage = params["dosage"].flatMap { $0.isEmpty ? nil : "（\($0)）" } ?? ""
            return "\(isMed ? "服药打卡" : "习惯打卡")：\(target)\(dosage)"

        case .anniversaryCreate:
            let title = params["title"] ?? "重要日子"
            let cat = params["category"] ?? "纪念日"
            let dateStr = params["targetDate"].map { " · \($0)" } ?? ""
            return "新建\(cat)：\(title)\(dateStr)"

        case .departureAdd:
            let title = params["title"] ?? "随身物品"
            let scene = params["scene"] ?? "工作通勤"
            return "出门清单：\(title)（\(scene)）"

        case .lifeRecord:
            let domain = params["domain"] ?? "pet"
            let title = params["title"] ?? "生活记录"
            let detail = params["detail"].flatMap { $0.isEmpty ? nil : " · \($0)" } ?? ""
            let domainLabel: String = switch domain {
            case "pet": "宠物养护"
            case "vehicle": "爱车管家"
            case "child": "育儿成长"
            case "skill": "技能练习"
            case "document": "重要证件"
            case "event": "人生大事"
            default: "生活档案"
            }
            return "\(domainLabel)：\(title)\(detail)"
        }
    }
}
