import Foundation

/// 人生大事要点任务的需求引导问题定义
public struct LifeEventTaskQuestion: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let placeholder: String
    public let presetOptions: [String]
    public let helpText: String?

    public init(id: String, title: String, placeholder: String, presetOptions: [String] = [], helpText: String? = nil) {
        self.id = id
        self.title = title
        self.placeholder = placeholder
        self.presetOptions = presetOptions
        self.helpText = helpText
    }
}

/// 单条引导问题的作答：预设选项（多选）+ 自由补充。
/// 持久化时整表序列化为 JSON 存进 `LifeEventTask.answersJSON`。
public struct LifeEventTaskAnswer: Codable, Sendable, Equatable {
    public var presets: [String]
    public var note: String

    public init(presets: [String] = [], note: String = "") {
        self.presets = presets
        self.note = note
    }

    public var isEmpty: Bool {
        presets.isEmpty && note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 投喂给大模型 / 档案导出时的合并文本。
    public var combined: String {
        var parts = presets.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let cleanNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanNote.isEmpty { parts.append(cleanNote) }
        return parts.joined(separator: "；")
    }
}

/// 项目级完整档案的单条任务快照（纯值，便于 Core 测试）。
public struct LifeEventArchiveTaskItem: Sendable, Equatable {
    public let stageTitle: String
    public let title: String
    public let isDone: Bool
    public let ownerName: String?
    public let dueText: String?
    public let answerLines: [String]
    public let aiSummary: String?

    public init(stageTitle: String, title: String, isDone: Bool, ownerName: String? = nil, dueText: String? = nil, answerLines: [String] = [], aiSummary: String? = nil) {
        self.stageTitle = stageTitle
        self.title = title
        self.isDone = isDone
        self.ownerName = ownerName
        self.dueText = dueText
        self.answerLines = answerLines
        self.aiSummary = aiSummary
    }
}

/// 项目级完整档案导出输入。
public struct LifeEventProjectArchiveInput: Sendable, Equatable {
    public let projectTitle: String
    public let templateName: String
    public let targetDateText: String
    public let locationText: String?
    public let budgetText: String?
    public let tasks: [LifeEventArchiveTaskItem]
    public let peopleLines: [String]
    public let expenseLines: [String]

    public init(projectTitle: String, templateName: String, targetDateText: String, locationText: String? = nil, budgetText: String? = nil, tasks: [LifeEventArchiveTaskItem] = [], peopleLines: [String] = [], expenseLines: [String] = []) {
        self.projectTitle = projectTitle
        self.templateName = templateName
        self.targetDateText = targetDateText
        self.locationText = locationText
        self.budgetText = budgetText
        self.tasks = tasks
        self.peopleLines = peopleLines
        self.expenseLines = expenseLines
    }
}

/// 人生大事任务的需求规划、大模型咨询 Prompt 生成与决策输出解析引擎
public enum LifeEventTaskPlanningEngine {

    /// 根据任务标题和大事模板，获取结构化的引导问题列表
    public static func questions(for taskTitle: String, templateRaw: String = "") -> [LifeEventTaskQuestion] {
        let title = taskTitle.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. 购车 / 选车 / 预算与用途相关
        if title.contains("车") || templateRaw == "买车" {
            if title.contains("预算") || title.contains("用途") || title.contains("需求") {
                return [
                    LifeEventTaskQuestion(
                        id: "budget",
                        title: "购车预算与支付形式",
                        placeholder: "例如：落地总价 20-25 万以内，首付 10 万，月供 3000 元内，优先考虑分期免息",
                        presetOptions: ["15-20万", "20-25万", "25-30万", "30-40万", "40万以上", "全款支付", "低息/免息分期"]
                    ),
                    LifeEventTaskQuestion(
                        id: "purpose",
                        title: "主要用途与出行场景",
                        placeholder: "例如：工作日单程 25km 通勤，周末带娃周边游，节假日自驾回老家",
                        presetOptions: ["工作日通勤代步", "家庭接送带娃", "周末自驾游", "长途省际出行", "商务接待", "偶尔露营装载"]
                    ),
                    LifeEventTaskQuestion(
                        id: "powertrain",
                        title: "能源与动力偏好",
                        placeholder: "例如：能充电，优先考虑增程或插混，无续航焦虑",
                        presetOptions: ["纯电 EV", "增程式 EREV", "插电混动 PHEV", "燃油车", "轻混/油电混动"]
                    ),
                    LifeEventTaskQuestion(
                        id: "charging",
                        title: "车位与充电条件",
                        placeholder: "例如：小区已买私家车位，可安装 7kW 家用交流充电桩",
                        presetOptions: ["有产权车位可装私桩", "租用车位有充电桩", "依赖附近公共快充站", "暂无固定车位"]
                    ),
                    LifeEventTaskQuestion(
                        id: "space",
                        title: "空间与车型偏好",
                        placeholder: "例如：大五座或六座 SUV，后排需常装儿童安全座椅，后备箱要能装折叠婴儿车",
                        presetOptions: ["大5座SUV", "6/7座中大型SUV", "家用中大型轿车", "舒适MPV", "紧凑两厢/小车", "硬派/轻越野"]
                    ),
                    LifeEventTaskQuestion(
                        id: "priorities",
                        title: "核心诉求与关注点",
                        placeholder: "例如：高阶智能驾驶、底盘滤震静音、安全性与气囊、车机流畅度",
                        presetOptions: ["高阶智能驾驶", "底盘滤震舒适", "车厢隔音静谧", "安全性与车身强度", "车机智舱体验", "极致省油/电", "品牌与保值率"]
                    ),
                    LifeEventTaskQuestion(
                        id: "candidates",
                        title: "备选车型与初步心动款",
                        placeholder: "例如：理想 L6、问界 M7、特斯拉 Model Y、极氪 7X、比亚迪唐",
                        presetOptions: []
                    ),
                    LifeEventTaskQuestion(
                        id: "notes",
                        title: "特别顾虑与补充说明",
                        placeholder: "例如：是否有指标限制、旧车置换残值、家庭成员对气味和晕车的顾虑等",
                        presetOptions: []
                    )
                ]
            } else if title.contains("对比") || title.contains("配置") || title.contains("试驾") {
                return [
                    LifeEventTaskQuestion(
                        id: "target_models",
                        title: "对比车型与版本配置",
                        placeholder: "例如：理想 L6 Pro vs 问界 M7 后驱智驾版",
                        presetOptions: []
                    ),
                    LifeEventTaskQuestion(
                        id: "focus_points",
                        title: "试驾与体验重点",
                        placeholder: "例如：高速领航辅助感受、后排乘坐颠簸感、倒车泊车便利性、音响效果",
                        presetOptions: ["智能泊车能力", "高速导航辅助驾驶", "后排防晕车滤震", "车机语音响应", "加速推背感", "座椅按摩通风"]
                    ),
                    LifeEventTaskQuestion(
                        id: "dealer_offers",
                        title: "销售政策与赠品诉求",
                        placeholder: "例如：置换补贴、免费选装基金、赠送家充桩、终身免费保养券",
                        presetOptions: ["置换补贴最大化", "赠送家用充电桩", "免费选装轮毂/车漆", "赠送保养券/工时券", "送太阳膜与脚垫"]
                    )
                ]
            } else if title.contains("谈价") || title.contains("价格") || title.contains("赠品") ||
                        title.contains("上牌") || title.contains("保险") || title.contains("交车") ||
                        title.contains("验车") || title.contains("保养") || title.contains("首保") ||
                        title.contains("停车") {
                return [
                    LifeEventTaskQuestion(
                        id: "price_target",
                        title: "价格目标与谈判底线",
                        placeholder: "例如：落地总价谈到 23 万以内，超出 23.5 万就换店再谈",
                        presetOptions: ["比指导价优惠3个点以上", "争取免息分期", "置换补贴计入落地价", "拒绝加价提车"]
                    ),
                    LifeEventTaskQuestion(
                        id: "freebies",
                        title: "赠品与加装诉求清单",
                        placeholder: "例如：必须送原厂充电桩、脚垫行车记录仪、3 次基础保养，贴膜要品牌膜",
                        presetOptions: ["家用充电桩", "基础保养券", "脚垫与行车记录仪", "品牌太阳膜", "原厂脚踏/行李架"]
                    ),
                    LifeEventTaskQuestion(
                        id: "registration_insurance",
                        title: "上牌与保险方案",
                        placeholder: "例如：自己去车管所上牌（约 120 元），保险首年在店里买交强+三者 200 万+车损",
                        presetOptions: ["4S代办上牌", "自行上牌更省钱", "首年店内投保", "三者险200万起", "加购医保外用药责任险"]
                    ),
                    LifeEventTaskQuestion(
                        id: "delivery_check",
                        title: "交车验车检查重点",
                        placeholder: "例如：核对生产日期 3 个月内、漆面无划痕、轮胎生产周期一致、随车工具与发票齐全",
                        presetOptions: ["生产日期3个月内", "漆面与缝隙检查", "轮胎/玻璃日期一致", "随车发票与合格证", "仪表里程低于50km"]
                    ),
                    LifeEventTaskQuestion(
                        id: "ownership",
                        title: "用车、保养与停车安排",
                        placeholder: "例如：车位已就位，首保 5000km 或半年，平时主要停地库",
                        presetOptions: ["已有固定车位", "首保按手册周期", "计划安装家充桩", "常停地库防暴晒"]
                    )
                ]
            }
        }

        // 2. 买房 / 选筹 / 购房资格与预算相关
        if title.contains("房") || templateRaw == "买房" || templateRaw == "乔迁新居 / 买房装修" {
            if title.contains("预算") || title.contains("首付") || title.contains("资格") || title.contains("选筹") || title.contains("看房") {
                return [
                    LifeEventTaskQuestion(
                        id: "budget",
                        title: "总价预算与首付储备",
                        placeholder: "例如：房屋总价 300-350 万以内，首付 100 万，公积金贷款+商业贷款组合",
                        presetOptions: ["200万以内", "200-300万", "300-500万", "500-800万", "纯公积金贷款", "组合贷款", "商业贷款"]
                    ),
                    LifeEventTaskQuestion(
                        id: "qualification",
                        title: "购房资格与名额",
                        placeholder: "例如：本地户籍首套刚需、社保已满5年、征信良好已打印流水",
                        presetOptions: ["首套刚需资格", "二套改善资格", "公积金额度充足", "社保年限达标"]
                    ),
                    LifeEventTaskQuestion(
                        id: "location",
                        title: "目标区域与板块偏好",
                        placeholder: "例如：城西未来科技城或申花板块，地铁 5 号线沿线，通勤单程 35 分钟内",
                        presetOptions: ["地铁站500米内", "通勤30分钟内", "核心主城区", "新兴产业板块", "近工作单位"]
                    ),
                    LifeEventTaskQuestion(
                        id: "layout",
                        title: "户型面积与房源形态",
                        placeholder: "例如：建面 89-110 平米三房两卫，南向双阳台，次新电梯房或优质期房",
                        presetOptions: ["紧凑小三房", "舒适三房两卫", "四房大平层", "次新房品质小区", "全新纯洋房", "得房率高于80%"]
                    ),
                    LifeEventTaskQuestion(
                        id: "school_amenities",
                        title: "学区与配套诉求",
                        placeholder: "例如：对口公办第一梯队小学或初中，周边有三甲医院与大型商业综合体",
                        presetOptions: ["双优质学区", "近三甲医院", "大型商业综合体", "紧邻城市公园绿道"]
                    ),
                    LifeEventTaskQuestion(
                        id: "concerns",
                        title: "核心顾虑与底线红线",
                        placeholder: "例如：坚决不要老破小、避开高架与垃圾中转站噪音、注重物业口碑与梯户比",
                        presetOptions: ["远离高架铁路噪音", "不选底楼顶楼", "避开期房烂尾风险", "注重万科/龙湖等优质物业"]
                    )
                ]
            }
        }

        // 3. 装修 / 风格与需求相关
        if title.contains("装") || templateRaw == "装修" {
            return [
                LifeEventTaskQuestion(
                    id: "budget",
                    title: "装修总预算与分配划分",
                    placeholder: "例如：硬装 15 万、全屋定制 6 万、软装与大件家电 8 万，总计控制在 30 万内",
                    presetOptions: ["10-15万", "15-25万", "25-40万", "半包自购主材", "品牌整装全包", "预留10%备用金"]
                ),
                LifeEventTaskQuestion(
                    id: "house_info",
                    title: "房屋户型与常住人口",
                    placeholder: "例如：建面 105 平米三房两卫，常住夫妻两人加一个两岁宝宝，父母偶尔小住",
                    presetOptions: ["三口之家", "二胎家庭", "三代同堂", "家有猫狗宠物", "常住两人"]
                ),
                LifeEventTaskQuestion(
                    id: "style",
                    title: "期望装修风格与氛围",
                    placeholder: "例如：法式现代奶油风、微水泥、无主灯设计、通铺木纹砖或木地板",
                    presetOptions: ["现代极简", "法式奶油风", "原木风/日式侘寂", "意式轻奢", "新中式", "无主灯设计"]
                ),
                LifeEventTaskQuestion(
                    id: "systems",
                    title: "舒适大件设备规划",
                    placeholder: "例如：必须装中央空调与燃气水地暖，主卫装智能马桶，厨房装洗碗机和净水器",
                    presetOptions: ["中央空调", "地暖系统", "新风系统", "全屋净水软水", "嵌入式洗碗机", "全屋智能家居"]
                ),
                LifeEventTaskQuestion(
                    id: "storage_painpoints",
                    title: "收纳与生活痛点",
                    placeholder: "例如：玄关需放婴儿车与行李箱，主卧衣帽间收纳要大，需要一间独立办公书房",
                    presetOptions: ["开放式大厨房", "超大玄关家政柜", "独立办公书房", "双台盆卫生间", "客餐厅一体大通厅"]
                )
            ]
        }

        // 4. 婚礼 / 婚期与预算相关
        if title.contains("婚礼") || title.contains("婚期") || templateRaw.contains("婚礼") {
            return [
                LifeEventTaskQuestion(
                    id: "budget",
                    title: "婚礼总预算与承担方式",
                    placeholder: "例如：总预算 18 万，酒店餐饮 10 万，四大金刚与婚庆布置 5 万，服饰婚戒 3 万",
                    presetOptions: ["10-15万", "15-25万", "25-40万", "双方父母各担一半", "新人独立自主承担"]
                ),
                LifeEventTaskQuestion(
                    id: "scale",
                    title: "预估桌数与宾客规模",
                    placeholder: "例如：预计 18-20 桌，宾客约 180-200 人，以直系亲属、密友和核心同事为主",
                    presetOptions: ["10桌以内小型微婚礼", "15-20桌中型", "25-35桌大型宴席"]
                ),
                LifeEventTaskQuestion(
                    id: "style",
                    title: "婚礼形式与布置喜好",
                    placeholder: "例如：户外草坪仪式加室内晚宴，森系自然风，不喜繁琐煽情环节，追求轻松温馨",
                    presetOptions: ["高端星级酒店宴会厅", "户外草坪自然风", "轻量微婚礼/派对", "新中式国风汉服礼"]
                ),
                LifeEventTaskQuestion(
                    id: "priorities",
                    title: "重点把控环节与偏好",
                    placeholder: "例如：摄影摄像一定要电影感、主持司仪轻松风趣不尴尬、菜品分量和口味要硬",
                    presetOptions: ["摄影摄像高级感出片", "司仪幽默控场不俗套", "菜品口碑硬硬实实", "伴手礼精致实用"]
                )
            ]
        }

        // 5. 育儿 / 生产 / 待产相关
        if title.contains("产") || title.contains("娃") || title.contains("月子") || templateRaw.contains("生娃") || templateRaw.contains("二胎") {
            return [
                LifeEventTaskQuestion(
                    id: "medical_budget",
                    title: "分娩医院与月子预算",
                    placeholder: "例如：公立三甲妇产医院特需病房，出院后入住 28 天月子中心，预算 4-6 万元",
                    presetOptions: ["公立三甲特需/VIP", "高端私立妇产医院", "28天月子中心", "住家金牌月嫂", "双方长辈协助照料"]
                ),
                LifeEventTaskQuestion(
                    id: "caregiver",
                    title: "月子期与产后人力分工",
                    placeholder: "例如：月嫂负责新生儿与宝妈，宝爸请陪产假负责采买跑腿，外婆负责一日三餐营养",
                    presetOptions: ["月嫂全权负责主力", "月子中心专业护理", "宝爸主力+育儿嫂", "双方老人轮班支援"]
                ),
                LifeEventTaskQuestion(
                    id: "items",
                    title: "关键母婴大件与物资规划",
                    placeholder: "例如：婴儿床、安全座椅提篮、吸奶器、消毒烘干机、纸尿裤与新生儿衣物清单",
                    presetOptions: ["婴儿床及棕榈垫", "新生儿提篮安全座椅", "双边电动吸奶器", "紫外线消毒烘干柜"]
                )
            ]
        }

        // 6. 通用默认引导问题（适用于任何其他要点任务）
        return [
            LifeEventTaskQuestion(
                id: "goal",
                title: "核心目标与期望结果",
                placeholder: "例如：梳理清楚该事项的具体要求、期望达成的理想状态与验收标准",
                presetOptions: ["明确核心指标", "确定最终交付物", "形成可执行决策", "避免遗漏重大风险"]
            ),
            LifeEventTaskQuestion(
                id: "budget_scope",
                title: "预算范围与资源投入",
                placeholder: "例如：预期资金上限、时间周期限制、需要协调的人员与各方分工",
                presetOptions: ["严格控制在预算内", "预留机动费用", "1-2周内完成决策", "需与家人共同商定"]
            ),
            LifeEventTaskQuestion(
                id: "constraints",
                title: "关键约束与核心顾虑",
                placeholder: "例如：不可妥协的硬性限制、潜在踩坑点、顾虑与风险考量",
                presetOptions: ["安全性第一", "性价比优先", "操作省心便捷", "合规合法无隐患"]
            ),
            LifeEventTaskQuestion(
                id: "options",
                title: "当前考虑中的备选方案",
                placeholder: "例如：方案 A 的优缺点，方案 B 的考量，目前最犹豫不决的要点",
                presetOptions: []
            )
        ]
    }

    /// 把答案表序列化为 JSON（空表返回 nil，保持库里字段为空）。
    public static func encodeAnswers(_ answers: [String: LifeEventTaskAnswer]) -> String? {
        let nonEmpty = answers.filter { !$0.value.isEmpty }
        guard !nonEmpty.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(nonEmpty) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 解码答案表；损坏或缺失一律回落空表，不让历史数据炸界面。
    public static func decodeAnswers(_ json: String?) -> [String: LifeEventTaskAnswer] {
        guard let json, let data = json.data(using: .utf8) else { return [:] }
        return (try? JSONDecoder().decode([String: LifeEventTaskAnswer].self, from: data)) ?? [:]
    }

    /// 已作答的问题数量（用于「已填写 N/M」进度）。
    public static func filledCount(questions: [LifeEventTaskQuestion], answers: [String: LifeEventTaskAnswer]) -> Int {
        questions.filter { answers[$0.id]?.isEmpty == false }.count
    }

    /// 答案按问题标题展开，供 `generateConsultationPrompt` 消费。
    /// 标题串比 id 更抗引擎迭代（id 变了标题仍可读）。
    public static func promptAnswerMap(questions: [LifeEventTaskQuestion], answers: [String: LifeEventTaskAnswer]) -> [String: String] {
        var map: [String: String] = [:]
        for question in questions {
            guard let answer = answers[question.id], !answer.isEmpty else { continue }
            map[question.title] = answer.combined
        }
        return map
    }

    /// 每条已作答问题渲染成「标题：内容」一行，供档案导出。
    public static func answerLines(questions: [LifeEventTaskQuestion], answers: [String: LifeEventTaskAnswer]) -> [String] {
        questions.compactMap { question in
            guard let answer = answers[question.id], !answer.isEmpty else { return nil }
            return "· \(question.title)：\(answer.combined)"
        }
    }

    /// 生成项目完整筹备档案文本，用于一次性 copy 给外部大模型做全局决策。
    public static func generateProjectArchive(_ input: LifeEventProjectArchiveInput) -> String {
        var text = """
        人生大事筹备完整档案

        【项目信息】
        • 项目名称：\(input.projectTitle)
        • 事项类型：\(input.templateName)
        • 目标日期：\(input.targetDateText)
        """
        if let location = input.locationText?.trimmingCharacters(in: .whitespacesAndNewlines), !location.isEmpty {
            text += "\n• 地点：\(location)"
        }
        if let budget = input.budgetText?.trimmingCharacters(in: .whitespacesAndNewlines), !budget.isEmpty {
            text += "\n• 预算上限：\(budget)"
        }

        text += "\n\n【要点任务与需求梳理】"
        if input.tasks.isEmpty {
            text += "\n（暂无任务记录）"
        } else {
            var currentStage = ""
            for task in input.tasks {
                if task.stageTitle != currentStage {
                    currentStage = task.stageTitle
                    text += "\n\n阶段：\(currentStage)"
                }
                let mark = task.isDone ? "x" : " "
                text += "\n- [\(mark)] \(task.title)"
                var meta: [String] = []
                if let owner = task.ownerName?.trimmingCharacters(in: .whitespacesAndNewlines), !owner.isEmpty {
                    meta.append("负责人 \(owner)")
                }
                if let due = task.dueText?.trimmingCharacters(in: .whitespacesAndNewlines), !due.isEmpty {
                    meta.append("截止 \(due)")
                }
                if !meta.isEmpty {
                    text += "\n  （\(meta.joined(separator: "，"))）"
                }
                for line in task.answerLines {
                    text += "\n  \(line)"
                }
                if let summary = task.aiSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
                    text += "\n  · 已有 AI 决策摘要：\(summary)"
                }
            }
        }

        if !input.peopleLines.isEmpty {
            text += "\n\n【人物与分工】"
            for line in input.peopleLines {
                text += "\n\(line)"
            }
        }

        if !input.expenseLines.isEmpty {
            text += "\n\n【预算与账本】"
            for line in input.expenseLines {
                text += "\n\(line)"
            }
        }

        text += """


        请你作为资深的人生规划与决策分析专家，通读上面的完整档案后：
        1. 指出当前规划中缺失的关键信息与潜在风险；
        2. 给出全局层面的优先级建议（先做什么、后做什么）；
        3. 把接下来 2 周最该落地的动作拆成 3~6 条待办，每条单独一行，以「- 待办内容」格式列出，便于我直接导入系统执行。
        """
        return text
    }

    /// 生成一键发给大模型的结构化咨询 Prompt
    public static func generateConsultationPrompt(
        projectTitle: String,
        templateName: String,
        targetDateText: String,
        locationText: String?,
        taskTitle: String,
        stageTitle: String?,
        answers: [String: String]
    ) -> String {
        let cleanProject = projectTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTask = taskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanStage = stageTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let locationDesc = (locationText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? "，坐标地点：\(locationText!)" : ""

        var prompt = """
        我正在推进人生大事【\(cleanProject)】（类型：\(templateName)，目标日期：\(targetDateText)\(locationDesc)）。
        当前正处于\(cleanStage.isEmpty ? "" : "【\(cleanStage)】阶段的")重点要点待办：【\(cleanTask)】。

        以下是我梳理出的详细需求、预算参数与个人偏好：
        """

        var answeredCount = 0
        for (keyTitle, value) in answers {
            let cleanVal = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanVal.isEmpty else { continue }
            prompt += "\n• \(keyTitle)：\(cleanVal)"
            answeredCount += 1
        }

        if answeredCount == 0 {
            prompt += "\n• （用户尚未填写具体问答细节，请根据该事项的一般专业决策流程展开）"
        }

        // 专业顾问引导
        let roleName: String
        if templateName.contains("车") || cleanTask.contains("车") {
            roleName = "资深汽车消费顾问与选车专家"
        } else if templateName.contains("房") || cleanTask.contains("房") {
            roleName = "资深不动产选筹与置业财务专家"
        } else if templateName.contains("装") || cleanTask.contains("装") {
            roleName = "资深家装空间设计师与工程监理专家"
        } else if templateName.contains("婚") || cleanTask.contains("婚") {
            roleName = "高级婚礼统筹策划专家"
        } else if templateName.contains("娃") || cleanTask.contains("生") || cleanTask.contains("产") {
            roleName = "专业母婴健康与家庭成长规划师"
        } else {
            roleName = "严谨的生活规划与决策分析专家"
        }

        prompt += """


        请你作为【\(roleName)】，针对我的实际情况为我进行深度决策分析，请务必结构化输出以下三个部分：

        一、【决策建议与方案推荐】
        深入分析我的核心需求与预算，给出 2~3 个最契合的推荐方案或选项对比（包含优缺点、大致花费/落地成本测算与匹配理由）。

        二、【避坑指南与关键提醒】
        在这个环节中最容易被忽略的隐性成本、商家的套路话术、避坑检查要点与合同注意事项。

        三、【下一步具体行动待办】
        请帮我把接下来的落地动作拆解成 3~6 条清晰具体、可立即执行的待办清单。
        每条待办请单独占一行，并以「- 待办内容」或数字序号格式列出，便于我直接导入系统日程中执行。
        """

        return prompt
    }

    /// 解析大模型输出的文本，分离核心决策方案摘要与可执行的行动待办清单
    public static func parseAIDecisionOutput(rawOutput: String) -> (summary: String, actionItems: [String]) {
        let text = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return ("", [])
        }

        var lines = text.components(separatedBy: .newlines)
        var actionItems: [String] = []
        var isInActionSection = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            // 检测行动待办小标题
            if trimmed.contains("行动待办") || trimmed.contains("行动清单") || trimmed.contains("待办事项") ||
                trimmed.contains("下一步") || trimmed.contains("落地动作") || trimmed.contains("执行清单") {
                isInActionSection = true
                continue
            }

            // 如果遇到下一个主标题（如“总结”或“结语”），离开待办区
            if isInActionSection && (trimmed.hasPrefix("四、") || trimmed.hasPrefix("五、") || trimmed.contains("总结") || trimmed.contains("结语") || trimmed.contains("温馨提示")) {
                isInActionSection = false
            }

            // 提取符合列表格式的待办项
            let isBullet = trimmed.hasPrefix("- ") || trimmed.hasPrefix("• ") || trimmed.hasPrefix("* ") ||
                           trimmed.hasPrefix("- [ ]") || trimmed.hasPrefix("- [x]") ||
                           trimmed.range(of: #"^\d+[\.、]\s*"#, options: .regularExpression) != nil

            if isBullet {
                var cleanItem = trimmed
                // 去除常见前缀符号
                if cleanItem.hasPrefix("- [ ] ") || cleanItem.hasPrefix("- [x] ") {
                    cleanItem = String(cleanItem.dropFirst(6))
                } else if cleanItem.hasPrefix("- ") || cleanItem.hasPrefix("• ") || cleanItem.hasPrefix("* ") {
                    cleanItem = String(cleanItem.dropFirst(2))
                } else if let numRange = cleanItem.range(of: #"^\d+[\.、]\s*"#, options: .regularExpression) {
                    cleanItem = String(cleanItem[numRange.upperBound...])
                }

                cleanItem = cleanItem.trimmingCharacters(in: .whitespacesAndNewlines)
                // 剔除 markdown 加粗
                cleanItem = cleanItem.replacingOccurrences(of: "**", with: "")

                // 长度过滤：5~80 字之间通常是具体的待办
                if cleanItem.count >= 4 && cleanItem.count <= 100 {
                    if isInActionSection || cleanItem.contains("预约") || cleanItem.contains("试驾") || cleanItem.contains("确认") ||
                        cleanItem.contains("对比") || cleanItem.contains("准备") || cleanItem.contains("查验") || cleanItem.contains("计算") ||
                        cleanItem.contains("办理") || cleanItem.contains("联系") || cleanItem.contains("核实") || cleanItem.contains("制定") {
                        if !actionItems.contains(cleanItem) {
                            actionItems.append(cleanItem)
                        }
                    }
                }
            }
        }

        // 如果在待办区没提取到足够待办，尝试全文本扫描高意图行动行
        if actionItems.isEmpty {
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("- ") || trimmed.hasPrefix("• ") || trimmed.range(of: #"^\d+[\.、]"#, options: .regularExpression) != nil {
                    var clean = trimmed
                    if let range = clean.range(of: #"^[-•\d\.、\*\s]+"#, options: .regularExpression) {
                        clean = String(clean[range.upperBound...])
                    }
                    clean = clean.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if clean.count >= 6 && clean.count <= 80 && (clean.contains("预约") || clean.contains("试驾") || clean.contains("对比") || clean.contains("准备") || clean.contains("办理") || clean.contains("联系")) {
                        if !actionItems.contains(clean) {
                            actionItems.append(clean)
                        }
                    }
                }
            }
        }

        return (text, actionItems)
    }

    /// 保守判据：这段文本像不像「大模型决策输出」？
    ///
    /// 投喂口入口用它做分流——命中则整段交给 `parseAIDecisionOutput` 拆行动项，
    /// 不再走 16 类意图判别（长文决策输出会被误判成收集箱备忘）。
    /// 三道门槛缺一不可，防止长备忘/日记被劫持：
    /// 1. 长文本（≥180 字）且多行（≥5 个非空行）——决策输出是结构化长文；
    /// 2. 必须出现「行动待办/下一步/落地动作」等分区标记——普通长文不会带这些小标题；
    /// 3. `parseAIDecisionOutput` 真解出 ≥2 条行动项——解不出就不是决策输出。
    public static func looksLikeAIDecisionOutput(_ rawOutput: String) -> Bool {
        let text = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 180 else { return false }

        let nonEmptyLines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard nonEmptyLines.count >= 5 else { return false }

        let sectionMarkers = ["行动待办", "行动清单", "待办事项", "下一步", "落地动作", "执行清单"]
        guard sectionMarkers.contains(where: { text.contains($0) }) else { return false }

        let parsed = parseAIDecisionOutput(rawOutput: text)
        return parsed.actionItems.count >= 2
    }
}
