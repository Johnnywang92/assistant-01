import Foundation
import SwiftData
import SwiftUI

/// 智能拆解出的单条待办子任务
struct PlannedSubtask: Identifiable, Hashable, Equatable, Sendable {
    let id: UUID
    var title: String
    var detail: String?
    var type: TodoType
    var isSelected: Bool

    init(
        id: UUID = UUID(),
        title: String,
        detail: String? = nil,
        type: TodoType = .general,
        isSelected: Bool = true
    ) {
        self.id = id
        self.title = L10n.tr(title)
        self.detail = detail.map { L10n.tr($0) }
        self.type = type
        self.isSelected = isSelected
    }
}

/// 任务规划方案数据包
struct TaskPlanningPlan: Identifiable, Hashable, Equatable, Sendable {
    let id: UUID
    let topic: String
    let icon: String
    let summary: String
    var subtasks: [PlannedSubtask]
    var isSaved: Bool

    init(
        id: UUID = UUID(),
        topic: String,
        icon: String = "checklist",
        summary: String,
        subtasks: [PlannedSubtask],
        isSaved: Bool = false
    ) {
        self.id = id
        self.topic = L10n.tr(topic)
        self.icon = icon
        self.summary = L10n.tr(summary)
        self.subtasks = subtasks
        self.isSaved = isSaved
    }
}

/// 智能任务规划与待办拆解中枢引擎（离线高精模板 + 端侧语义推算）
@MainActor
final class TaskPlanningEngine {
    static let shared = TaskPlanningEngine()

    private init() {}

    /// 判断输入是否命中规划或任务拆解意图
    func isPlanningQuery(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lower = trimmed.lowercased()

        let triggerKeywords = [
            "规划", "拆解", "理一下", "理理", "准备去", "清单", "计划", "怎么准备",
            "要做什么", "安排一下", "怎么搞", "步骤", "筹备",
            "plan ", "break down", "prepare for", "checklist for", "steps for"
        ]

        let scenarioKeywords = [
            "露营", "搬家", "出差", "旅行", "旅游", "度假", "回老家", "返乡", "购票", "买票", "机票", "火车票", "大扫除", "清洁", "分享会", "演讲",
            "派对", "聚会", "生日", "考研", "复习", "考试", "自驾游", "体检", "看病", "装修",
            "camping", "moving", "trip", "travel", "cleaning", "presentation", "party", "exam", "checkup"
        ]

        // 包含显式规划动词，或同时提及场景与行动
        let hasTrigger = triggerKeywords.contains { lower.contains($0) }
        let hasScenario = scenarioKeywords.contains { lower.contains($0) }

        return hasTrigger || (hasScenario && (trimmed.contains("怎么") || trimmed.contains("要") || trimmed.contains("想") || lower.contains("how to")))
    }

    /// 分析用户输入，生成结构化规划方案与子任务清单
    func decomposeTask(query: String) -> TaskPlanningPlan? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // 1. 露营出行场景
        if text.contains("露营") || text.contains("野营") {
            return TaskPlanningPlan(
                topic: "周末户外露营筹备",
                icon: "tent.fill",
                summary: "为你整理了露营四大核心维度的准备步骤，涵盖装备、餐食、营地及安全防护：",
                subtasks: [
                    PlannedSubtask(title: "清点露营装备：帐篷、防潮垫、睡袋与折叠桌椅", detail: "提前检查帐篷地钉与防风绳是否齐全", type: .general),
                    PlannedSubtask(title: "采购露营餐饮：卡式炉、气罐、烧烤食材与饮用水", detail: "备齐保冷箱与大桶纯净水", type: .general),
                    PlannedSubtask(title: "准备照明与应急电源：露营灯、大容量充电宝", detail: "确保护眼营地灯电量充满", type: .charging),
                    PlannedSubtask(title: "准备安全防护包：户外驱蚊液、防晒霜与急救创可贴", detail: "携带必备肠胃药及常用药品", type: .general),
                    PlannedSubtask(title: "核对营地信息：确认是否需用火报备及天气预报", detail: "下雨天提前准备防雨天幕", type: .event)
                ]
            )
        }

        // 2. 搬家场景
        if text.contains("搬家") || text.contains("搬迁") {
            return TaskPlanningPlan(
                topic: "全流程安心搬家拆解",
                icon: "truck.box.fill",
                summary: "搬家琐事较多，按搬前断舍离、打包清点到入住前置步骤为你做了条理拆分：",
                subtasks: [
                    PlannedSubtask(title: "杂物断舍离：清理闲置旧物与非当季衣物", detail: "轻装上阵，减少无效搬运体积", type: .housework),
                    PlannedSubtask(title: "采购打包物资：准备纸箱、气泡膜、封箱胶带与记号笔", detail: "在箱体四周标注房间名与易碎标志", type: .general),
                    PlannedSubtask(title: "预约搬家货车及师傅，确认出入小区放行条", detail: "提前与物业沟通电梯使用与车辆停靠", type: .event),
                    PlannedSubtask(title: "整理随身百宝箱：身份证件、贵重财物与首晚洗漱包", detail: "随身随车携带，严禁混入货车纸箱", type: .general),
                    PlannedSubtask(title: "办理生活缴费结算与宽带移机", detail: "结清旧址水电燃气，提前预约新家宽带上门安装", type: .bill)
                ]
            )
        }

        // 3. 出差、长途旅行与出行购票及文博景区预约
        if text.contains("出差") || text.contains("旅行") || text.contains("旅游") || text.contains("度假") || text.contains("回老家") || text.contains("返乡") || text.contains("购票") || text.contains("买票") || text.contains("火车票") || text.contains("机票") || text.contains("博物馆") || text.contains("展览") || text.contains("特展") || text.contains("景区") || text.contains("门票") || text.contains("故宫") || text.contains("国博") {
            return TaskPlanningPlan(
                topic: "出差旅行与购票出行清单",
                icon: "airplane.departure",
                summary: "为你梳理了远行前火车票/机票开售窗口期、热门文博景区预约、随身行李及安全确认步骤：",
                subtasks: [
                    PlannedSubtask(title: "提前 15~30 天：比对预订往返机票与特惠酒店", detail: "机票黄金预订期特惠多，尽早锁定紧俏房源与折扣航班", type: .travelBooking),
                    PlannedSubtask(title: "提前 15 天：12306 抢购/候补往返火车票", detail: "火车票开售首日定好闹钟准时抢票，未出票及时提交候补", type: .travelBooking),
                    PlannedSubtask(title: "提前 7 天：抢约热门博物馆、特展与 5A 景区门票", detail: "故宫/国博/陕历博等通常提前7天放票（留意整点放票抢约），提前分时段实名锁定入场名额", type: .travelBooking),
                    PlannedSubtask(title: "整理洗漱衣物、充电器、随身充电宝及备用数据线", detail: "充电宝额定能量不超过 100Wh 便于登机与安检", type: .charging),
                    PlannedSubtask(title: "备齐出行便携药盒（肠胃药、晕车药、创可贴）", detail: "随身小包携带，以备不时之需", type: .medication),
                    PlannedSubtask(title: "出门前全屋安全确认：关窗、关燃气总阀、拔下闲置插头", detail: "检查门锁与冰箱门是否密闭", type: .housework)
                ]
            )
        }

        // 4. 全屋大扫除与断舍离
        if text.contains("大扫除") || text.contains("扫除") || text.contains("深度清洁") || text.contains("断舍离") {
            return TaskPlanningPlan(
                topic: "全屋深度大扫除计划",
                icon: "sparkles",
                summary: "遵循“由上至下、由内而外”的高效清洁动线，帮你拆分为以下清单：",
                subtasks: [
                    PlannedSubtask(title: "玄关与客厅杂物归位，开展初步断舍离清空台面", detail: "先收纳归位，再进行擦拭拖地", type: .housework),
                    PlannedSubtask(title: "厨房重油污攻坚：清洁抽油烟机滤网与灶台油渍", detail: "清理冰箱冷藏过期食材与调味品", type: .housework),
                    PlannedSubtask(title: "卫浴除垢消毒：清洗浴室玻璃水垢、马桶与地漏毛发", detail: "保持开窗通风，晾晒替换地垫", type: .housework),
                    PlannedSubtask(title: "布艺除螨洗晒：清洗更换床单被套与枕套", detail: "选晴好天气晾晒，空调滤网顺带拆洗", type: .housework)
                ]
            )
        }

        // 5. 技术分享会 / 演讲汇报
        if text.contains("分享") || text.contains("演讲") || text.contains("汇报") || text.contains("开会") {
            return TaskPlanningPlan(
                topic: "高质感演讲与汇报备战",
                icon: "person.wave.2.fill",
                summary: "为你制定了从立项、结构梳理到现场演练的专业步骤：",
                subtasks: [
                    PlannedSubtask(title: "梳理演讲核心主旨与受众痛点，搭建框架大纲", detail: "明确 3 个核心论点与预期交付价值", type: .general),
                    PlannedSubtask(title: "制作演讲 PPT 幻灯片，精简文字并增加案例图表", detail: "每页幻灯片传达一个清晰信息", type: .general),
                    PlannedSubtask(title: "进行至少 2 次掐表全真模拟试讲，调整语速节奏", detail: "严格控制在规定时长内，预留 Q&A 互动时间", type: .event),
                    PlannedSubtask(title: "演练现场设备联调：测试投屏转接头、翻页笔与演示环境", detail: "将演讲文稿与演示 Demo 备份一份至手机/U盘", type: .charging)
                ]
            )
        }

        // 6. 生日聚会 / 朋友派对
        if text.contains("派对") || text.contains("聚会") || text.contains("生日") || text.contains("聚餐") {
            return TaskPlanningPlan(
                topic: "生日派对与聚会筹备",
                icon: "gift.fill",
                summary: "为你梳理了从人员邀约、场地餐饮到派对高潮环节的跟进步骤：",
                subtasks: [
                    PlannedSubtask(title: "敲定聚会人数与时间，预订餐厅包厢或活动场地", detail: "提前发消息告知受邀朋友集合时段", type: .event),
                    PlannedSubtask(title: "提前预订生日蛋糕、定制鲜花与装饰道具", detail: "约定当天准时配送至聚会现场", type: .anniversary),
                    PlannedSubtask(title: "采购聚会零食、饮料、水果与桌游互动玩具", detail: "照顾不同朋友的饮食偏好与忌口", type: .general),
                    PlannedSubtask(title: "活动前一天发送集合时间、交通停车与定位提醒", detail: "温馨提醒大家轻装出行或聚餐守时", type: .general)
                ]
            )
        }

        // 7. 自驾游出行
        if text.contains("自驾") || text.contains("开车出游") {
            return TaskPlanningPlan(
                topic: "自驾远行车辆与行车准备",
                icon: "car.fill",
                summary: "自驾安全第一，为你梳理了爱车保养核对与行车随车必备清单：",
                subtasks: [
                    PlannedSubtask(title: "全车安全检查：测胎压、检查机油、刹车与加满玻璃水", detail: "长途高速前重点检查轮胎磨损有无裂痕", type: .vehicleCare),
                    PlannedSubtask(title: "下载高德/腾讯离线地图包，规划沿途补能服务区", detail: "避开高峰堵车路段，预估每 3 小时休息一次", type: .general),
                    PlannedSubtask(title: "准备车内必备物资：车载快充线、湿纸巾与垃圾袋", detail: "备齐薄荷糖、无糖茶与足量矿泉水", type: .charging),
                    PlannedSubtask(title: "检查应急随车工具：反光背心、三角警示牌与随车充", detail: "确认车险电子保单在有效期内", type: .vehicleCare)
                ]
            )
        }

        // 8. 健康体检 / 医院就医
        if text.contains("体检") || text.contains("看病") || text.contains("就医") || text.contains("医院") {
            return TaskPlanningPlan(
                topic: "就医挂号与体检前置清单",
                icon: "cross.case.fill",
                summary: "避免就医跑冤枉路，为你整理了关键的前置准备与空腹注意事项：",
                subtasks: [
                    PlannedSubtask(title: "确认医院预约挂号短信与就诊科室时段", detail: "提前 20 分钟到达候诊区签到取号", type: .event),
                    PlannedSubtask(title: "准备医保卡、实体身份证及既往病历化验单据", detail: "把既往用药盒拍好照存在手机相册", type: .general),
                    PlannedSubtask(title: "体检/抽血前一晚 22:00 起保持空腹，严禁进食与剧烈运动", detail: "次日早晨晨尿样本采集中段尿", type: .medication),
                    PlannedSubtask(title: "列出准备咨询医生的不适症状清单与发作诱因", detail: "用简洁要点与医生高效沟通", type: .general)
                ]
            )
        }

        // 9. 考试复习 / 备考冲刺
        if text.contains("考试") || text.contains("复习") || text.contains("考研") || text.contains("考证") {
            return TaskPlanningPlan(
                topic: "高效备考冲刺规划",
                icon: "graduationcap.fill",
                summary: "将备考拆解为明确的高频动作，助你稳扎稳打提升复习效能：",
                subtasks: [
                    PlannedSubtask(title: "梳理科目核心考点清单，标记薄弱章节知识盲区", detail: "优先主攻高分值且提分空间大的核心章节", type: .general),
                    PlannedSubtask(title: "制定每日真题演练计划，定量掐表完成一套试卷", detail: "重在分析错题原因并归纳解题套路", type: .event),
                    PlannedSubtask(title: "整理高频背诵笔记与速记手册，利用碎片时间默背", detail: "早起或睡前 20 分钟巩固记忆效果最佳", type: .general),
                    PlannedSubtask(title: "提前打印准考证并核对考场路线、文具与身份证件", detail: "备齐 2B 铅笔、黑色签字笔与橡皮", type: .general)
                ]
            )
        }

        // 10. 自定义/自由任务拆解（根据用户输入的目标词智能提取）
        let cleanTopic = extractCustomTopic(from: text)
        return TaskPlanningPlan(
            topic: "\(cleanTopic)实施方案",
            icon: "list.bullet.clipboard.fill",
            summary: "针对「\(cleanTopic)」，已为你结构化拆解出以下清晰落地步骤：",
            subtasks: [
                PlannedSubtask(title: "明确核心目标与验收标准：理清「\(cleanTopic)」的关键指标", detail: "确立清晰的完成界限与时间节点", type: .general),
                PlannedSubtask(title: "准备前期所需物资、工具与必要协作人员", detail: "前置排查潜在卡点，备齐关键物料", type: .general),
                PlannedSubtask(title: "分段执行核心主体工作，推进阶段性产出落地", detail: "直奔核心重点，先完成再完美", type: .general),
                PlannedSubtask(title: "收尾检查、查漏补缺与成果复盘", detail: "逐项对照要求验收，确保平稳交付", type: .general)
            ]
        )
    }

    /// 结合端侧大模型动态拆解任务与子待办清单（若端侧模型可用则优先生成针对性步骤，否则回退模板）
    func decomposeTaskWithAI(query: String) async -> TaskPlanningPlan? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let basePlan = decomposeTask(query: text)
        let cleanTopic = extractCustomTopic(from: text)

        let systemInstruction = """
        你是资深生活规划专家，擅长把用户的具体目标拆解成可直接执行的待办清单。
        【拆解要求】
        1. 先抓住目标中的关键信息（地点、事项、时间、目的），所有步骤必须围绕这些具体信息展开，禁止写成放之四海而皆准的通用套话；
        2. 每条步骤 = 具体动作 + 具体对象，尽量包含数字、时间窗口或专有名词（如「提前 30 天递交新西兰签证」「按 2 人 10 天备蜜月衣物」）；
        3. 严禁输出「确定预算」「选择目的地」「做好准备」「第一步」这类无信息量的标题，标题必须让人一眼知道要做什么；
        4. 步骤按时间先后排列，覆盖「提前办理 → 预订采购 → 行前准备 → 临行确认」完整周期；
        5. 输出 5 条，每条占一行，格式固定为：标题｜要点（标题不超过 15 字，要点不超过 25 字）；
        6. 只输出清单本身：不要编号、不要解释、不要输出任何格式说明或示例内容。
        【输出格式演示，仅示意写法，严禁照抄其中文字】
        例：提前 30 天办理签证｜备齐材料递交并预留体检时间
        """
        let userContent = "用户目标：\(text)\n请按格式输出拆解清单："

        if let aiOutput = await LLMInferenceService.shared.generateCustomTask(
            systemInstruction: systemInstruction,
            userContent: userContent,
            maxNewTokens: 320
        ) {
            let lines = aiOutput
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            var parsedSubtasks: [PlannedSubtask] = []
            for rawLine in lines {
                // 过滤小模型回显的格式说明行（如「步骤标题｜一句话执行要点」「例：…」）
                if rawLine.contains("一句话执行要点") || rawLine.contains("格式") || rawLine.hasPrefix("例：") || rawLine.hasPrefix("例:") {
                    continue
                }
                let cleanedLine = rawLine.replacingOccurrences(
                    of: #"^(?:[\d一二三四五六七八九十]+[\.、\s\)\）\-•]+|第[\d一二三四五六七八九十]+步[：:、\.\s\)\）\-•]*)"#,
                    with: "",
                    options: .regularExpression
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                guard cleanedLine.count >= 4 else { continue }

                let parts = cleanedLine.components(separatedBy: CharacterSet(charactersIn: "｜|:："))
                let title = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? cleanedLine
                let detail = parts.count > 1 ? parts.dropFirst().joined(separator: "：").trimmingCharacters(in: .whitespacesAndNewlines) : nil
                guard !title.isEmpty else { continue }
                parsedSubtasks.append(PlannedSubtask(title: title, detail: detail, type: .general))
            }

            if parsedSubtasks.count >= 2 {
                return TaskPlanningPlan(
                    topic: basePlan?.icon == "list.bullet.clipboard.fill" ? "\(cleanTopic) AI 规划方案" : (basePlan?.topic ?? "\(cleanTopic) AI 规划方案"),
                    icon: basePlan?.icon ?? "sparkles",
                    summary: "✨ 已通过端侧 AI 模型为你定制「\(cleanTopic)」的 \(parsedSubtasks.count) 步执行清单：",
                    subtasks: Array(parsedSubtasks.prefix(6))
                )
            }
        }

        return basePlan
    }

    /// 批量保存勾选的子任务至 SwiftData 模型
    func savePlanToTodos(plan: TaskPlanningPlan, context: ModelContext) -> Int {
        let selected = plan.subtasks.filter { $0.isSelected }
        guard !selected.isEmpty else { return 0 }

        for (idx, subtask) in selected.enumerated() {
            let item = TodoItem(
                type: subtask.type,
                status: .active,
                title: subtask.title,
                detail: subtask.detail,
                sourceText: "来自任务规划：\(plan.topic)",
                sortOrder: idx
            )
            context.insert(item)
        }

        try? context.save()
        Haptic.success()
        return selected.count
    }

    private func extractCustomTopic(from text: String) -> String {
        var clean = text
        // 1. 剥离尾部请求语（如「，帮我做一个规划」「帮我拆解一下」），保留真正的目标主体
        clean = clean.replacingOccurrences(
            of: #"[，,、\s]*(?:请|麻烦|帮我|给我)[做整]?(?:[一二三四五六七八九十\d]+)?[个套份]?\s*(?:规划|计划|安排|拆解|理一?下|清单|攻略)[的了吧啊~～\s]*(?:一下)?[的了吧啊~～？?\s]*$"#,
            with: "",
            options: .regularExpression
        )
        // 2. 剥离尾部疑问式（如「露营怎么准备？」「生日派对如何安排」）
        clean = clean.replacingOccurrences(
            of: #"(?:怎么|怎样|如何|咋)(?:准备|安排|规划|计划|搞|做|办)(?:呢|吗)?[？?\s]*$"#,
            with: "",
            options: .regularExpression
        )
        // 3. 剥离头部请求语（如「帮我规划一下搬家」「请帮我安排一下生日派对」）
        clean = clean.replacingOccurrences(
            of: #"^(?:请|麻烦)?(?:你|我)?(?:帮我|给我)?(?:想|要|打算|准备|计划)?(?:去)?\s*(?:规划|计划|安排|拆解|梳理|理一?下|做|搞|整)(?:一下|一次|一个|个|[一二三四五六七八九十\d]+[个次趟])?[：:，,\s]*"#,
            with: "",
            options: .regularExpression
        )
        // 4. 剥离头部疑问式（如「怎么准备露营」）
        clean = clean.replacingOccurrences(
            of: #"^(?:怎么|怎样|如何|咋)(?:准备|安排|规划|计划|搞|做)[，,：:\s]*"#,
            with: "",
            options: .regularExpression
        )
        for p in ["我想去", "我要去", "我打算去", "我准备", "我计划", "我要准备", "我想", "我要", "准备去", "想去"] {
            if clean.hasPrefix(p) {
                clean = String(clean.dropFirst(p.count))
                break
            }
        }
        clean = clean
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "？", with: "")
            .replacingOccurrences(of: "?", with: "")
            .replacingOccurrences(of: "，", with: "")
            .replacingOccurrences(of: "。", with: "")

        if clean.isEmpty || clean.count > 20 {
            return "目标事项"
        }
        return clean
    }
}
