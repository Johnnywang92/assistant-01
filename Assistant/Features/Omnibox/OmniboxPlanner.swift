import AssistantCore
import Foundation
import UIKit

// MARK: - Omnibox Planner：Capture → PlannedAction[]

/// 理解层。两种引擎：
/// 1. LLM 路径：一次多模态归一（图片先 OCR）后让端侧模型直接产出 schema 化 JSON 动作数组
/// 2. 规则兜底：正则/关键词拆解（LLM 不可用或输出解析失败时）
/// Planner 不执行动作，只负责产出 DAG 并保证拓扑可执行。
struct OmniboxPlanner {

    struct PlanResult {
        var actions: [PlannedAction]
        var engine: String // "llm" / "rules"
        var normalizedText: String
    }

    func plan(capture: OmniboxCapture) async -> PlanResult {
        // 1. 归一输入：文字直接收集；图片并发 OCR（多图时比串行快数倍），最终拼接为一段完整文本
        var parts: [String] = []
        var imageDatas: [Data] = []
        for payload in capture.payloads {
            switch payload {
            case .text(let t), .audioTranscript(let t):
                let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { parts.append(trimmed) }
            case .image(let data):
                imageDatas.append(data)
            }
        }
        let imageCount = imageDatas.count

        if !imageDatas.isEmpty {
            // 并发 OCR，按提交顺序回填保持图文对应
            let ocrTexts: [String?] = await withTaskGroup(
                of: (Int, String?).self,
                returning: [String?].self
            ) { group in
                for (index, data) in imageDatas.enumerated() {
                    group.addTask {
                        guard let image = UIImage(data: data) else { return (index, nil) }
                        let text = try? await OCRService.shared.recognizeText(from: image)
                        return (index, text)
                    }
                }
                var results = [String?](repeating: nil, count: imageDatas.count)
                for await (index, text) in group {
                    results[index] = text
                }
                return results
            }
            for text in ocrTexts.compactMap({ $0 }) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    parts.append("【图片识别内容】\n\(trimmed)")
                }
            }
        }
        let normalizedText = parts.joined(separator: "\n\n")

        guard !normalizedText.isEmpty || imageCount > 0 else {
            return PlanResult(actions: [], engine: "rules", normalizedText: "")
        }

        // 2. LLM 优先，失败降级规则
        if !normalizedText.isEmpty,
           let actions = await Self.llmPlan(normalizedText), !actions.isEmpty {
            return PlanResult(actions: actions, engine: "llm", normalizedText: normalizedText)
        }
        return PlanResult(actions: Self.rulePlan(normalizedText), engine: "rules", normalizedText: normalizedText)
    }

    // MARK: - LLM 路径

    private static func llmPlan(_ text: String) async -> [PlannedAction]? {
        let systemInstruction = """
        你是个人助手的万能投喂口与智能助理理解引擎。把用户输入拆解为可执行动作，只输出一个 JSON 数组，不要输出任何解释、markdown 或多余文字。
        可用动作：
        1) 记账：{"capability":"expense.create","amount":"数字","isIncome":"false","category":"餐饮美食|交通出行|居家日用|购物消费|休闲娱乐|医疗健康|宠物萌宠|数码家电|人情社交|职业收入|其它收入|其它支出","title":"简短事项名","dateISO":"yyyy-MM-dd HH:mm 可省"}
        2) 修改账目：{"capability":"expense.update","target":"原账单事项名或关键词","newAmount":"修改后金额"}
        3) 待办新建：{"capability":"todo.create","title":"待办标题","detail":"补充说明，可省","dueAtDays":"相对今天的天数，可省","dueAtTime":"HH:mm，可省"}
        4) 修改待办：{"capability":"todo.update","target":"原待办匹配关键词","newTitle":"新标题（可省）","dueAtDays":"新截止相对天数（可省）"}
        5) 完成待办：{"capability":"todo.complete","target":"待完成事项匹配词"}
        6) 取消待办：{"capability":"todo.cancel","target":"待取消事项匹配词"}
        7) 推迟提醒：{"capability":"reminder.snooze","target":"提醒事项匹配词","duration":"10分钟|1小时|明早"}
        8) 查询事项：{"capability":"query.lookup","target":"查询关键词"}
        9) 收集箱：{"capability":"memo.inbox","memo":"原文摘录"}
        规则：
        - 提到“完成”、“搞定”、“做好了”某个待办时，必须输出 todo.complete 动作，target 为事项名。
        - 提到“取消”、“删掉”、“不要提醒”某个事项时，输出 todo.cancel 动作。
        - 提到“推迟”、“稍后提醒”、“延后”时，输出 reminder.snooze 动作。
        - 识别到消费/支出金额且非修改时，输出 expense.create 动作。
        - 识别到针对已有记录改金额、改标题时，输出对应的 expense.update 或 todo.update。
        - 输入是扣款短信或订单截图时，提取商户名作为 title 并记账。
        - 提到收货、保修、还款、到期、预约等未来事项时输出 todo.create 动作。
        - 完全无法归类时输出一个收集箱 memo.inbox 动作。
        """
        let now = Date()
        let dateText = Self.yyyyMMdd.string(from: now)
        let weekdayText = Self.weekdayFormatter.string(from: now)
        let userContent = "今天是\(dateText) \(weekdayText)。\n输入：\n\(text)"

        guard let raw = await LLMInferenceService.shared.generateCustomTask(
            systemInstruction: systemInstruction,
            userContent: userContent,
            maxNewTokens: 400
        ), !raw.isEmpty else {
            return nil
        }
        return Self.parseActionJSON(raw)
    }

    /// 宽容解析模型输出：剥掉 markdown 围栏、截取最外层 JSON 数组（委托 AssistantCore.ActionParser）
    static func parseActionJSON(_ raw: String) -> [PlannedAction]? {
        ActionParser.parseActionJSON(raw)
    }

    // MARK: - 规则兜底路径

    static func rulePlan(_ text: String) -> [PlannedAction] {
        var actions: [PlannedAction] = []

        // 0. 操作类指令优先：完成/取消/推迟等动作明确，避免被误判成新建或普通备忘
        if let complete = Self.extractTodoComplete(from: text) {
            actions.append(complete)
            return actions
        }
        if let cancel = Self.extractTodoCancel(from: text) {
            actions.append(cancel)
            return actions
        }
        if let snooze = Self.extractReminderSnooze(from: text) {
            actions.append(snooze)
            return actions
        }

        // 1. 记账：优先按短信/订单截图结构化模板提取（最高置信），再复用既有自然语言解析器，最后宽松正则兜底
        if let structured = Self.extractStructuredExpense(from: text) {
            actions.append(structured)
        } else if let parsed = ExpenseNaturalLanguageParser.parse(text) {
            actions.append(PlannedAction(
                capability: .expenseCreate,
                params: [
                    "amount": String(format: "%.2f", parsed.amount),
                    "isIncome": parsed.isIncome ? "true" : "false",
                    "category": parsed.category.rawValue,
                    "title": parsed.title
                ],
                confidence: 0.8,
                summary: Self.summary(for: .expenseCreate, params: [
                    "amount": String(format: "%.2f", parsed.amount),
                    "isIncome": parsed.isIncome ? "true" : "false",
                    "category": parsed.category.rawValue,
                    "title": parsed.title
                ])
            ))
        } else if let amount = Self.extractLooseAmount(from: text) {
            let isIncome = Self.containsAny(text, ["收到", "入账", "工资", "报销", "退款", "红包", "收入"])
            let category = Self.guessCategory(from: text)
            let title = Self.guessExpenseTitle(from: text)
            var params = [
                "amount": String(format: "%.2f", amount),
                "isIncome": isIncome ? "true" : "false",
                "category": category.rawValue,
                "title": title
            ]
            if let date = Self.extractTransactionDate(from: text) {
                params["dateISO"] = Self.dateTimeFormatter.string(from: date)
            }
            actions.append(PlannedAction(
                capability: .expenseCreate,
                params: params,
                confidence: 0.55,
                confidenceReason: "松散匹配到金额，建议核对分类与金额",
                summary: Self.summary(for: .expenseCreate, params: params)
            ))
        }

        // 2. 待办：取件码 / 相对时间关键词 / 保修与收货意图
        if let parcel = Self.extractParcelTodo(from: text) {
            actions.append(parcel)
        }
        if let due = Self.extractRelativeDue(from: text) {
            var params: [String: String] = [
                "title": due.title,
                "dueAtDays": String(due.days)
            ]
            if let time = due.time { params["dueAtTime"] = time }
            if !due.detail.isEmpty { params["detail"] = due.detail }
            actions.append(PlannedAction(
                capability: .todoCreate,
                params: params,
                confidence: 0.65,
                confidenceReason: "根据相对时间词推测，建议核对截止日期",
                dependsOn: actions.filter { $0.capability == .expenseCreate }.map(\.id),
                summary: Self.summary(for: .todoCreate, params: params)
            ))
        }
        if text.contains("保修") {
            let product = Self.guessExpenseTitle(from: text)
            let params: [String: String] = [
                "title": "\(product)保修期到期检查",
                "detail": "来源：投喂口识别到保修信息，默认 1 年保修期",
                "dueAtDays": "365"
            ]
            actions.append(PlannedAction(
                capability: .todoCreate,
                params: params,
                confidence: 0.58,
                confidenceReason: "根据保修关键词推测，默认1年期",
                dependsOn: actions.filter { $0.capability == .expenseCreate }.map(\.id),
                summary: Self.summary(for: .todoCreate, params: params)
            ))
        }

        // 3. 收集箱兜底：无法归类时永不报错，全部落收集箱（Flomo 原则）
        if actions.isEmpty {
            let memo = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !memo.isEmpty {
                actions.append(PlannedAction(
                    capability: .memoInbox,
                    params: ["memo": String(memo.prefix(500))],
                    confidence: 0.9,
                    summary: L10n.tr("收入收集箱：") + String(memo.prefix(40))
                ))
            }
        }
        return actions
    }

    // MARK: - 参数补全工具（确认卡编辑时也调用）

    static func summary(for capability: OmniboxCapability, params: [String: String]) -> String {
        switch capability {
        case .expenseCreate:
            guard let amount = Double(params["amount"] ?? ""), amount > 0 else { return "" }
            let income = params["isIncome"] == "true"
            let category = params["category"] ?? L10n.tr("其它支出")
            let title = params["title"]?.isEmpty == false ? params["title"]! : L10n.tr("未命名事项")
            return "\(income ? "+" : "-")¥\(Self.trimAmount(amount)) · \(category) · \(title)"
        case .todoCreate:
            guard let title = params["title"]?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return "" }
            var parts = [title]
            if let iso = params["dueAtISO"], let date = parseParamDate(iso) {
                parts.append(date.formatted(date: .abbreviated, time: .shortened))
            } else if let days = Int(params["dueAtDays"] ?? ""), days > 0 {
                parts.append("\(days) 天后")
            }
            if let time = params["dueAtTime"], !time.isEmpty {
                parts.append(time)
            }
            return parts.joined(separator: " · ")
        case .memoInbox:
            guard let memo = params["memo"]?.trimmingCharacters(in: .whitespacesAndNewlines), !memo.isEmpty else { return "" }
            return L10n.tr("收入收集箱：") + String(memo.prefix(40))
        default:
            return ActionParser.generateSummary(for: capability, params: params)
        }
    }

    static func trimAmount(_ amount: Double) -> String {
        amount.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(amount))
            : String(format: "%.2f", amount)
    }

    // MARK: - 规则提取器

    /// 匹配完成待办动作：把[X]完成 / 完成[X] / 标记完成[X]
    static func extractTodoComplete(from text: String) -> PlannedAction? {
        let patterns = [
            "(?:把|将)?\\s*(.+?)\\s*(?:标记为?已?完成|搞定了?|做好了?|已完成)$",
            "^(?:完成|办结|做完|搞定)\\s*(.+)"
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            if let first = matches.first, first.numberOfRanges > 1 {
                let target = ns.substring(with: first.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !target.isEmpty && target.count < 40 {
                    let params = ["target": target]
                    return PlannedAction(
                        capability: .todoComplete,
                        params: params,
                        confidence: 0.9,
                        summary: Self.summary(for: .todoComplete, params: params)
                    )
                }
            }
        }
        return nil
    }

    /// 匹配取消/删除待办动作：取消[X] / 删掉[X] / 不要提醒[X]
    static func extractTodoCancel(from text: String) -> PlannedAction? {
        let patterns = [
            "^(?:取消|删除|删掉|去掉|撤销)\\s*(?:待办|事项|提醒)?\\s*(.+)",
            "^(?:不要|别)\\s*提醒我?\\s*(.+)"
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            if let first = matches.first, first.numberOfRanges > 1 {
                let target = ns.substring(with: first.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !target.isEmpty && target.count < 40 {
                    let params = ["target": target]
                    return PlannedAction(
                        capability: .todoCancel,
                        params: params,
                        confidence: 0.85,
                        summary: Self.summary(for: .todoCancel, params: params)
                    )
                }
            }
        }
        return nil
    }

    /// 匹配推迟提醒动作：推迟[X] / 顺延[X] / 稍后提醒[X]
    static func extractReminderSnooze(from text: String) -> PlannedAction? {
        let patterns = [
            "^(?:推迟|顺延|延后|稍后提醒)\\s*(.+?)(?:(\\d+\\s*(?:分钟|小时|天))|到明早)?$",
            "^(?:把|将)?\\s*(.+?)\\s*(?:推迟|顺延|延后)(?:(\\d+\\s*(?:分钟|小时|天))|到明早)?$"
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            if let first = matches.first, first.numberOfRanges > 1 {
                let target = ns.substring(with: first.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                var duration = "1小时"
                if first.numberOfRanges > 2 && first.range(at: 2).location != NSNotFound {
                    let dur = ns.substring(with: first.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !dur.isEmpty { duration = dur }
                }
                if !target.isEmpty && target.count < 40 {
                    let params = ["target": target, "duration": duration]
                    return PlannedAction(
                        capability: .reminderSnooze,
                        params: params,
                        confidence: 0.85,
                        summary: Self.summary(for: .reminderSnooze, params: params)
                    )
                }
            }
        }
        return nil
    }

    /// 短信账单 / 订单截图的结构化提取：模板化金额关键词 + 商户名 + 交易时间
    /// 覆盖：银行/支付宝/微信扣款短信（消费/支出/向XX支付）、电商订单页（实付款/支付金额/合计）
    static func extractStructuredExpense(from text: String) -> PlannedAction? {
        guard let amount = Self.extractExplicitPayAmount(from: text) else { return nil }

        let isIncome = Self.containsAny(text, ["退款", "到账", "入账", "收入", "工资", "红包", "报销"])
        let merchant = Self.extractMerchant(from: text)
        let category: ExpenseCategory = isIncome
            ? (text.contains("工资") ? .income : .otherIncome)
            : Self.guessCategory(from: text)
        let title = merchant ?? Self.guessExpenseTitle(from: text)

        var params: [String: String] = [
            "amount": String(format: "%.2f", amount),
            "isIncome": isIncome ? "true" : "false",
            "category": category.rawValue,
            "title": title
        ]
        if let date = Self.extractTransactionDate(from: text) {
            params["dateISO"] = Self.dateTimeFormatter.string(from: date)
        }
        // 短信/订单模板命中，结构化程度高，默认勾选执行
        return PlannedAction(
            capability: .expenseCreate,
            params: params,
            confidence: 0.88,
            summary: Self.summary(for: .expenseCreate, params: params)
        )
    }

    /// 按可信度从高到低匹配「明确的支付金额」表述
    private static func extractExplicitPayAmount(from text: String) -> Double? {
        let patterns: [String] = [
            // 订单截图：实付款 ¥59.90 / 支付金额：59.9元 / 合计 ¥xx
            "(?:实付款?|支付金额|付款金额|订单金额|应付金额|合计|总计|交易金额|扣款金额)[^0-9¥￥]{0,6}[¥￥]?\\s*([0-9]+(?:\\.[0-9]+)?)",
            // 银行/支付宝短信：消费99.00元（美团） / 支出100元 / 扣款xx元
            "(?:消费|支出|扣款|付款|缴纳|缴费)[^0-9]{0,12}([0-9]+(?:\\.[0-9]+)?)\\s*元?",
            // 向XX支付99元 / 转账给XX 99元
            "(?:向|给)\\s*[^，。,\\s]{2,15}\\s*(?:支付|转账|付款)\\s*[¥￥]?\\s*([0-9]+(?:\\.[0-9]+)?)",
            // 支付宝通知：您有一笔99.00元的交易
            "一笔\\s*[¥￥]?\\s*([0-9]+(?:\\.[0-9]+)?)\\s*元",
            // 退款/到账短信：退款99.00元 / 到账100元
            "(?:退款|到账|入账|收入)[^0-9]{0,8}([0-9]+(?:\\.[0-9]+)?)\\s*元"
        ]
        for pattern in patterns {
            if let value = Self.firstCapturedNumber(pattern, in: text), value > 0 {
                return value
            }
        }
        return nil
    }

    /// 从短信模板或订单页里提取商户名
    private static func extractMerchant(from text: String) -> String? {
        let patterns: [String] = [
            "在「([^」]{2,12})」",                 // 在「美团」消费
            "「([^」]{2,12})」",
            "（([^）]{2,12})）\\s*$",              // 银行短信尾部：消费99.00元（美团）
            "消费[0-9.]+元（([^）]{2,12})）",
            "(?:向|给)\\s*([^，。,\\s]{2,15}?)\\s*(?:支付|转账|付款)",
            "在([^，。,\\s]{2,10}?)(?:消费|支付|购物|下单|购买)"
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)),
               match.range(at: 1).location != NSNotFound,
               let range = Range(match.range(at: 1), in: text) {
                let candidate = String(text[range]).trimmingCharacters(in: .whitespaces)
                // 排除明显不是商户的捕获（纯数字、银行短信签名残留）
                if candidate.range(of: "^[0-9.]+$", options: .regularExpression) == nil,
                   !candidate.contains("银行"), candidate.count >= 2 {
                    return candidate
                }
            }
        }
        return nil
    }

    /// 提取交易时间（短信/截图里的 MM月dd日 HH:mm、yyyy-MM-dd HH:mm 等）
    static func extractTransactionDate(from text: String) -> Date? {
        // 完整日期 + 时间
        if let regex = try? NSRegularExpression(pattern: "(\\d{4})[-/年](\\d{1,2})[-/月](\\d{1,2})日?\\s*(\\d{1,2}):(\\d{2})"),
           let comps = Self.dateComponents(regex, in: text, hasYear: true) {
            return Calendar.current.date(from: comps)
        }
        // 完整日期无时间
        if let regex = try? NSRegularExpression(pattern: "(\\d{4})[-/年](\\d{1,2})[-/月](\\d{1,2})日?"),
           let comps = Self.dateComponents(regex, in: text, hasYear: true) {
            return Calendar.current.date(from: comps)
        }
        // 月日 + 时间（默认今年）
        if let regex = try? NSRegularExpression(pattern: "(\\d{1,2})月(\\d{1,2})日\\s*(\\d{1,2}):(\\d{2})"),
           let comps = Self.dateComponents(regex, in: text, hasYear: false) {
            return Calendar.current.date(from: comps)
        }
        // 仅日期
        if let regex = try? NSRegularExpression(pattern: "(\\d{1,2})月(\\d{1,2})日"),
           let comps = Self.dateComponents(regex, in: text, hasYear: false) {
            return Calendar.current.date(from: comps)
        }
        return nil
    }

    private static func dateComponents(_ regex: NSRegularExpression, in text: String, hasYear: Bool) -> DateComponents? {
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)) else {
            return nil
        }
        func captured(_ index: Int) -> Int? {
            guard match.range(at: index).location != NSNotFound,
                  let range = Range(match.range(at: index), in: text),
                  let value = Int(text[range]) else { return nil }
            return value
        }
        var comps = DateComponents()
        var offset = 0
        if hasYear {
            guard let year = captured(1) else { return nil }
            comps.year = year
            offset = 1
        }
        guard let month = captured(offset + 1), let day = captured(offset + 2) else { return nil }
        comps.month = month
        comps.day = day
        if let hour = captured(offset + 3) { comps.hour = hour }
        if let minute = captured(offset + 4) { comps.minute = minute }
        if comps.year == nil { comps.year = Calendar.current.component(.year, from: .now) }
        if comps.hour == nil { comps.hour = 12 }
        return comps
    }

    private static func firstCapturedNumber(_ pattern: String, in text: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)),
              match.range(at: 1).location != NSNotFound,
              let range = Range(match.range(at: 1), in: text),
              let value = Double(text[range]) else {
            return nil
        }
        return value
    }

    static func extractLooseAmount(from text: String) -> Double? {
        let patterns = [
            "[¥￥]\\s*([0-9]+(?:\\.[0-9]+)?)",
            "([0-9]+(?:\\.[0-9]+)?)\\s*(?:元|块钱|块)"
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)),
               match.range(at: 1).location != NSNotFound,
               let range = Range(match.range(at: 1), in: text),
               let value = Double(text[range]), value > 0 {
                return value
            }
        }
        return nil
    }

    private static func guessCategory(from text: String) -> ExpenseCategory {
        // 先按常见商户/平台名匹配（短信与订单截图的商家名是最强分类信号）
        let merchantMapping: [(ExpenseCategory, [String])] = [
            (.food, ["美团", "饿了么", "麦当劳", "肯德基", "星巴克", "瑞幸", "必胜客", "海底捞", "喜茶", "蜜雪", "外卖"]),
            (.transport, ["滴滴", "高德", "花小猪", "中石油", "中石化", "12306", "铁路", "航空", "地铁", "ETC", "停车"]),
            (.shopping, ["京东", "淘宝", "天猫", "拼多多", "唯品会", "苏宁", "抖音商城", "闲鱼"]),
            (.medical, ["医院", "药房", "药店", "诊所", "体检"]),
            (.entertainment, ["爱奇艺", "腾讯视频", "优酷", "网易云音乐", "QQ音乐", "电影院", "猫眼", "大麦"]),
            (.digital, ["苹果", "Apple", "小米", "华为", "荣耀", "OPPO", "vivo", "大疆"]),
            (.living, ["话费", "流量", "宽带", "水电", "燃气", "物业", "中国移动", "中国联通", "中国电信"])
        ]
        for (category, keywords) in merchantMapping where containsAny(text, keywords) {
            return category
        }
        let mapping: [(ExpenseCategory, [String])] = [
            (.food, ["餐", "外卖", "吃", "奶茶", "咖啡", "饭"]),
            (.transport, ["打车", "地铁", "公交", "加油", "火车", "机票", "高铁"]),
            (.digital, ["电饭煲", "手机", "电脑", "耳机", "平板", "家电", "数码", "相机"]),
            (.shopping, ["买", "购物", "订单", "下单"]),
            (.medical, ["药", "医院", "体检", "挂号"]),
            (.entertainment, ["电影", "游戏", "演出", "门票"]),
            (.pets, ["猫", "狗", "宠物", "猫粮", "狗粮"]),
            (.living, ["水电", "燃气", "物业", "日用品"])
        ]
        for (category, keywords) in mapping where containsAny(text, keywords) {
            return category
        }
        return .other
    }

    private static func guessExpenseTitle(from text: String) -> String {
        // 取第一个 2~12 字的商品/事项词（简单启发：截取金额之后的短片段）
        if let regex = try? NSRegularExpression(pattern: "(?:买了?|购入|下单|订单[：:]?)\\s*([^，。,\\.\\n\\s¥￥0-9]{2,12})"),
           let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)),
           match.range(at: 1).location != NSNotFound,
           let range = Range(match.range(at: 1), in: text) {
            return String(text[range])
        }
        let cleaned = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "¥", with: " ")
            .replacingOccurrences(of: "￥", with: " ")
        let tokens = cleaned.split(whereSeparator: { " ，。,.".contains($0) })
        return tokens.first.map { String($0.prefix(12)) } ?? L10n.tr("投喂记录")
    }

    private static func extractParcelTodo(from text: String) -> PlannedAction? {
        guard let regex = try? NSRegularExpression(pattern: "取件码[^0-9]{0,6}([0-9]{4,8})"),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)),
              match.range(at: 1).location != NSNotFound,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        let code = String(text[range])
        let params: [String: String] = [
            "title": "取快递（取件码 \(code)）",
            "detail": text.trimmingCharacters(in: .whitespacesAndNewlines)
        ]
        return PlannedAction(
            capability: .todoCreate,
            params: params,
            confidence: 0.85,
            summary: Self.summary(for: .todoCreate, params: params)
        )
    }

    private static func extractRelativeDue(from text: String) -> (title: String, days: Int, time: String?, detail: String)? {
        guard containsAny(text, ["提醒", "待办", "记得", "收货", "到期", "还款", "预约", "别忘", "保修", "发货"]) else { return nil }

        var days = 1
        if let regex = try? NSRegularExpression(pattern: "([0-9]+)\\s*天(之|以)?后"),
           let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)),
           match.range(at: 1).location != NSNotFound,
           let range = Range(match.range(at: 1), in: text),
           let value = Int(text[range]) {
            days = value
        } else if text.contains("后天") {
            days = 2
        } else if text.contains("明天") {
            days = 1
        }

        var time: String? = nil
        if let regex = try? NSRegularExpression(pattern: "([01]?[0-9]|2[0-3]):[0-5][0-9]"),
           let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)),
           let range = Range(match.range, in: text) {
            time = String(text[range])
        }

        let title = Self.guessExpenseTitle(from: text)
        let detail = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (title, days, time, String(detail.prefix(200)))
    }

    private static func containsAny(_ text: String, _ keywords: [String]) -> Bool {
        keywords.contains { text.contains($0) }
    }

    private static let yyyyMMdd: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// 动作参数里交易时间的标准格式（yyyy-MM-dd HH:mm）
    static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    /// 解析动作参数中的 dateISO（确认卡展示与执行器落库共用）
    static func parseParamDate(_ iso: String?) -> Date? {
        guard let iso = iso?.trimmingCharacters(in: .whitespacesAndNewlines), !iso.isEmpty else { return nil }
        return dateTimeFormatter.date(from: iso)
    }

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "EEEE"
        return f
    }()
}
