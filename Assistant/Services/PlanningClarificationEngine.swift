import Foundation

/// 规划背景追问的回合结果
enum PlanningClarificationOutcome {
    case question(prompt: String, options: [DialogueActionOption])
    case ready(background: String)
    case cancelled
}

/// 待办规划前的「设身处地」背景追问协调器：
/// 先确认同行人、时间、预算、成行方式、证件语言等关键信息（用户已说明的不再重复问），
/// 再把确认结果注入端侧 AI 的拆解提示词，生成真正贴合用户处境的规划。
@MainActor
final class PlanningClarificationEngine {
    static let shared = PlanningClarificationEngine()

    private struct Question {
        let slot: String
        let prompt: String
        let chips: [String]
    }

    private enum Scenario {
        case travel, camping, moving, party, exam, medical, generic
    }

    /// 特殊指令 payload（走 DialogueActionOption.payload 传递）
    static let skipPayload = "planq:skip"
    static let generatePayload = "planq:generate"
    static let exitPayload = "planq:exit"

    private(set) var originalQuery: String = ""
    private var questionQueue: [Question] = []
    private var currentQuestion: Question?
    private var collected: [(slot: String, answer: String)] = []
    private var askedCount = 0
    private let maxQuestions = 2

    var isActive: Bool { currentQuestion != nil }

    private init() {}

    // MARK: - 会话入口

    /// 规划意图命中后开启追问会话；关键信息已齐全时直接返回 .ready。
    /// 已知场景用规则题库零延迟出题；陌生领域交由端侧模型就地出题，不可用时回退通用题库。
    func begin(query: String) async -> PlanningClarificationOutcome {
        reset()
        originalQuery = query
        let scenario = Self.detectScenario(query)
        let bank: [Question]
        if scenario == .generic, let dynamic = await Self.dynamicQuestions(for: query), !dynamic.isEmpty {
            bank = dynamic
        } else {
            bank = Self.questionBank(for: scenario)
        }

        // 用户已在原始表述中说明的维度不再追问，直接记为背景答案
        var known: [(slot: String, answer: String)] = []
        for question in bank {
            if let answer = Self.explicitAnswer(forSlot: question.slot, in: query) {
                known.append((question.slot, answer))
            } else {
                questionQueue.append(question)
            }
        }
        collected = known
        return advance()
    }

    /// 提交一条回答（芯片点选文本、特殊指令或语音/打字自由文本）
    func submit(answer rawAnswer: String) -> PlanningClarificationOutcome {
        let answer = rawAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch answer {
        case "", Self.skipPayload:
            break // 空回答视同跳过，本维度留白继续下一问
        case Self.generatePayload:
            currentQuestion = nil
            return finalize()
        case Self.exitPayload:
            reset()
            return .cancelled
        default:
            if let question = currentQuestion {
                collected.append((question.slot, answer))
            }
            // 智能多槽位提取：若用户一句话同时回答了后续待问维度的信息，自动抽取并移出队列，避免机械重复追问
            questionQueue.removeAll { pending in
                if let matched = Self.explicitAnswer(forSlot: pending.slot, in: answer) {
                    collected.append((pending.slot, matched))
                    return true
                }
                return false
            }
        }
        currentQuestion = nil
        return advance()
    }

    func cancelSession() {
        reset()
    }

    // MARK: - 内部流程

    private func advance() -> PlanningClarificationOutcome {
        guard askedCount < maxQuestions, let question = questionQueue.first else {
            return finalize()
        }
        questionQueue.removeFirst()
        askedCount += 1
        currentQuestion = question

        let topic = TaskPlanningEngine.shared.extractCustomTopic(from: originalQuery)
        let prompt = """
        🧭 好的！为了给你一份真正贴合情况的「\(topic)」规划，先跟你确认几个背景信息（第 \(askedCount)/\(maxQuestions) 问，可随时点「直接生成」，也可以打字或语音直接回答）：
        \(question.prompt)
        """
        return .question(prompt: prompt, options: options(for: question))
    }

    private func finalize() -> PlanningClarificationOutcome {
        let background = collected.map { "\($0.slot)：\($0.answer)" }.joined(separator: "；")
        let query = originalQuery
        reset()
        _ = query
        return .ready(background: background)
    }

    private func reset() {
        questionQueue = []
        currentQuestion = nil
        collected = []
        askedCount = 0
    }

    private func options(for question: Question) -> [DialogueActionOption] {
        var opts = question.chips.map {
            DialogueActionOption(label: $0, payload: $0, actionType: .planningAnswer)
        }
        opts.append(DialogueActionOption(label: "⏭️ 跳过这题", payload: Self.skipPayload, actionType: .planningAnswer))
        opts.append(DialogueActionOption(label: "🚀 直接生成规划", payload: Self.generatePayload, actionType: .planningAnswer, isPrimary: true))
        opts.append(DialogueActionOption(label: "✕ 退出追问", payload: Self.exitPayload, actionType: .planningAnswer))
        return opts
    }

    // MARK: - 陌生领域动态出题（端侧模型就地生成追问，失败则由调用方回退通用题库）

    private static func dynamicQuestions(for query: String) async -> [Question]? {
        let instruction = """
        你是规划助理。用户即将开展一件事，你可能不熟悉该领域，请提出制定规划前最需要向用户当面确认的 3 个关键背景问题。
        要求：
        1. 问题必须针对用户目标的具体情境，想清楚「做成这件事还缺哪些只有用户本人知道的信息」；
        2. 用户目标里已提到的信息（如时间、预算、人数）不得重复提问；
        3. 每行一条，格式固定：维度名｜问题一句话｜选项1、选项2、选项3（2到4个短选项，用、分隔）；
        4. 只输出 3 行，不要编号、解释或格式示例本身。
        """
        guard let output = await LLMInferenceService.shared.generateCustomTask(
            systemInstruction: instruction,
            userContent: "用户目标：\(query)\n请输出 3 条追问：",
            maxNewTokens: 180
        ) else { return nil }

        var questions: [Question] = []
        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine
                .replacingOccurrences(of: #"^[\d一二三四五六七八九十]+[\.、\s\)\）\-•]+"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // 过滤回显格式说明的行
            guard !line.isEmpty, !line.contains("维度名"), !line.contains("格式") else { continue }
            let parts = line.components(separatedBy: CharacterSet(charactersIn: "｜|"))
            guard parts.count >= 2 else { continue }
            let slot = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let prompt = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let chips = parts.count > 2
                ? parts[2].components(separatedBy: "、")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { $0.count >= 2 && $0.count <= 14 }
                : []
            guard slot.count >= 2, slot.count <= 10, prompt.count >= 6 else { continue }
            questions.append(Question(slot: slot, prompt: prompt, chips: Array(chips.prefix(4))))
        }
        return questions.count >= 2 ? Array(questions.prefix(3)) : nil
    }

    // MARK: - 场景与槽位识别（纯规则、零延迟离线）

    private static func detectScenario(_ text: String) -> Scenario {
        if text.contains("露营") || text.contains("野营") { return .camping }
        if text.contains("搬家") || text.contains("搬迁") { return .moving }
        if text.contains("派对") || text.contains("聚会") || text.contains("生日") || text.contains("聚餐") { return .party }
        if text.contains("考试") || text.contains("复习") || text.contains("考研") || text.contains("考证") || text.contains("备考") { return .exam }
        if text.contains("体检") || text.contains("看病") || text.contains("就医") || text.contains("医院") { return .medical }
        let travelWords = ["旅行", "旅游", "度假", "蜜月", "出游", "自驾", "出差", "回老家", "返乡", "机票", "火车票", "签证", "出境", "周边游"]
        if travelWords.contains(where: { text.contains($0) }) { return .travel }
        return .generic
    }

    private static func questionBank(for scenario: Scenario) -> [Question] {
        switch scenario {
        case .travel:
            return [
                Question(slot: "同行人", prompt: "这次出行是几个人？有没有老人或小朋友同行？", chips: ["就我们俩/夫妻同行", "带上父母或孩子", "和几个朋友一起", "一个人出发"]),
                Question(slot: "时间与天数", prompt: "大概什么时候出发？计划玩几天？", chips: ["一周内出发·玩5天左右", "下个月·7到10天", "节假日·长假深度游", "时间还没完全定"]),
                Question(slot: "预算", prompt: "这趟行程的心理预算大概多少（总价）？", chips: ["经济型·总计1万以内", "舒适型·总计1-3万", "品质型·预算充足", "先不设预算·看方案"]),
                Question(slot: "证件与语言", prompt: "护照签证都办好了吗？外语沟通情况如何？", chips: ["护照在手·签证没问题", "还没办护照", "签证政策不太了解", "外语沟通没问题", "外语不太敢说"]),
                Question(slot: "成行方式", prompt: "想全程自由行自己安排，还是跟团省心一点？", chips: ["全程自由行", "半自助·当地报团", "跟旅行团到底", "自驾前往"]),
            ]
        case .camping:
            return [
                Question(slot: "同行人员", prompt: "这次露营几个人？有老人小孩吗？", chips: ["两三个成年人", "情侣/夫妻两人", "带孩子的家庭局", "一大群朋友"]),
                Question(slot: "过夜安排", prompt: "打算日归还是过夜？大概几天？", chips: ["日归·不过夜", "住一晚体验一下", "连住两三晚", "还没定"]),
                Question(slot: "装备情况", prompt: "帐篷睡袋这些装备你现在有吗？", chips: ["全套装备齐全", "有部分·缺大件", "什么都没有·需置办或租", "想在营地租借"]),
            ]
        case .moving:
            return [
                Question(slot: "搬家时间", prompt: "计划哪天搬？时间宽裕吗？", chips: ["这周就得搬", "下周左右", "半个月内", "还没定日子"]),
                Question(slot: "房屋条件", prompt: "新旧家有没有电梯？大件家具多吗？", chips: ["两边都有电梯", "有步梯楼层", "大件家具家电多", "行李为主·没大件"]),
                Question(slot: "人手方案", prompt: "打算请搬家公司全包，还是自己加朋友帮忙？", chips: ["请搬家公司全包", "只搬大件+自己整理", "朋友帮忙省钱", "还没想好"]),
            ]
        case .party:
            return [
                Question(slot: "人数规模", prompt: "这次聚会大概请几个人？", chips: ["10人以内小局", "10-20人", "20人以上大局", "还在统计"]),
                Question(slot: "场地安排", prompt: "想安排在家里、餐厅还是户外场地？", chips: ["家里或民宿", "餐厅包厢", "户外草坪/露营", "听你推荐"]),
                Question(slot: "预算与惊喜", prompt: "人均预算大概多少？需要惊喜环节吗？", chips: ["人均100内·温馨为主", "人均200-500·要有仪式感", "预算充足·尽量惊喜", "不需要惊喜·大家聚聚"]),
            ]
        case .exam:
            return [
                Question(slot: "考试节点", prompt: "考试定在什么时候？还剩多少时间？", chips: ["一个月内冲刺", "还有两三个月", "半年以上长线", "还没报名·先规划"]),
                Question(slot: "每日时间投入", prompt: "每天大概能挤出多少学习时间？", chips: ["工作日1-2小时", "全天备考", "碎片时间为主", "只有周末能学"]),
                Question(slot: "基础与目标", prompt: "现在的底子如何？目标是过线还是拿高分？", chips: ["零基础·求过线", "有基础·冲高分", "二战·补短板", "拿到证书就行"]),
            ]
        case .medical:
            return [
                Question(slot: "就诊安排", prompt: "约的是哪天？知道要做哪些项目吗？", chips: ["明天一早", "这周内", "还没预约", "项目不太清楚"]),
                Question(slot: "陪同与空腹", prompt: "需要人陪同吗？有抽血等空腹项目吗？", chips: ["家人陪同", "自己去就行", "有空腹项目", "不清楚注意事项"]),
                Question(slot: "资料准备", prompt: "既往病历、医保卡这些资料都在手边吗？", chips: ["都齐全", "找不到既往病历", "医保需要异地备案", "需要先整理资料"]),
            ]
        case .generic:
            return [
                Question(slot: "完成期限", prompt: "这件事希望什么时候完成？", chips: ["一周内搞定", "一个月内", "分阶段·三个月左右", "没有硬性期限"]),
                Question(slot: "预算资源", prompt: "在这件事上大概能投入多少预算或资源？", chips: ["尽量省钱·零预算", "小额预算以内", "预算充足", "按方案需要来"]),
                Question(slot: "期望产出", prompt: "做成什么样你就算满意了？", chips: ["先完成第一版就行", "要有可量化的结果", "重在参与体验", "还没想好·帮我定"]),
            ]
        }
    }

    /// 判断某维度是否已在用户原始表述中说明（说明过的不再追问）
    private static func explicitAnswer(forSlot slot: String, in text: String) -> String? {
        switch slot {
        case "同行人", "同行人员":
            if text.contains("蜜月") { return "夫妻/情侣两人蜜月出行" }
            for pair in [
                ("一个人", "一个人出发"), ("独自", "一个人出发"), ("独行", "一个人出发"),
                ("全家", "全家同行"), ("一家人", "全家同行"),
                ("带父母", "带父母同行"), ("带爸妈", "带父母同行"),
                ("带孩子", "带孩子同行"), ("带娃", "带孩子同行"),
                ("两口子", "夫妻两人同行"), ("两夫妻", "夫妻两人同行"), ("夫妻俩", "夫妻两人同行"),
                ("情侣俩", "情侣两人同行"), ("情侣两人", "情侣两人同行"),
                ("我们俩", "两人同行"), ("咱俩", "两人同行"), ("两个人", "两人同行"), ("两人", "两人同行"),
                ("夫妻", "夫妻同行"), ("情侣", "情侣两人同行"),
                ("和朋友", "和朋友结伴"), ("跟朋友", "和朋友结伴"), ("几个朋友", "和朋友结伴")
            ] {
                if text.contains(pair.0) { return pair.1 }
            }
            if let countMatch = firstMatch(#"[0-9一二两三四五六七八九十]+\s*(?:个人|人同行|人结伴|人出游|人起)"#, in: text) {
                return countMatch
            }
            return nil
        case "时间与天数", "搬家时间", "考试节点", "就诊安排", "完成期限", "过夜安排":
            return firstMatch(#"[0-9一二两三四五六七八九十半]+\s*(?:天(?:左右|整)?|日内?|周|个月|月份?)|下周|下个月|这周|周末|国庆|五一|春节|暑假|寒假|[0-9]+月(?:份)?[0-9]*日?"#, in: text)
        case "预算", "预算与惊喜", "预算资源":
            return firstMatch(#"[0-9.]+\s*[万千]元?|预算[^，。？?]*|[0-9]+\s*块"#, in: text)
        case "成行方式":
            return firstMatch(#"跟团|自由行|半自助|自驾|自助"#, in: text)
        case "证件与语言":
            return firstMatch(#"护照|签证|英语|外语"#, in: text)
        case "装备情况":
            return firstMatch(#"装备|帐篷|天幕|租借"#, in: text)
        case "场地安排":
            return firstMatch(#"家里|民宿|餐厅|包厢|草坪|户外"#, in: text)
        case "人手方案":
            return firstMatch(#"搬家公司|自己动手|朋友帮忙"#, in: text)
        case "人数规模":
            return firstMatch(#"[0-9]+\s*人|几个人"#, in: text)
        default:
            return nil
        }
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        return String(text[range])
    }
}
