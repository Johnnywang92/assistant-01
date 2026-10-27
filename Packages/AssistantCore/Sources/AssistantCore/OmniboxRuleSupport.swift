import Foundation

// MARK: - 组合输入子句切分

/// 「完成晨跑打卡，顺便喝了500ml水」这类组合输入的子句切分。
///
/// 规则兜底路径的提取器是按「一句一个意图」设计的（命中即返回），
/// 组合输入直接喂进去会把后半句吞掉。这里按**强分隔符**切成子句后
/// 逐句独立拆解，互不抢占。
///
/// 只切分号与「顺便/然后/另外」引导的递进子句；**逗号与句号不切**——
/// 短信/订单文本里句末句号常见（「消费99.00元。余额1250元」），
/// 切开后「余额1250元」会被宽松金额兜底误判成一笔新账。
public enum OmniboxClauseSplitter {

    public static func split(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let pattern = "[；;]|(?:，|,)?\\s*(?:顺便|然后|另外)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [trimmed]
        }
        let ns = trimmed as NSString
        let matches = regex.matches(in: trimmed, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return [trimmed] }

        let trailingPunctuation = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "。．.;；,，"))
        var parts: [String] = []
        var cursor = 0
        for match in matches {
            let range = NSRange(location: cursor, length: match.range.location - cursor)
            let part = ns.substring(with: range).trimmingCharacters(in: trailingPunctuation)
            if !part.isEmpty { parts.append(part) }
            cursor = match.range.location + match.range.length
        }
        let tail = ns.substring(from: cursor).trimmingCharacters(in: trailingPunctuation)
        if !tail.isEmpty { parts.append(tail) }
        return parts.isEmpty ? [trimmed] : parts
    }
}

// MARK: - 修改类规则提取器

/// 「把那笔账改成30」「待办改到后天」这类**修改既有记录**的规则兜底。
/// LLM 不可用时其它 14 类能力都有规则提取器，修改类此前缺失会静默落收集箱，这里补齐。
///
/// 提取结果的参数键与执行器严格一致：
/// - expense.update：`target` + `newAmount`（新值）/ `newTitle`（改名）。
///   执行器里 `amount` 是「匹配提示」（改前原值），规则路径无从得知，不提供。
/// - todo.update：`target` + `newTitle` / `dueAtDays` + `dueAtTime`，与 resolveDueAt 对齐。
public enum OmniboxUpdateExtractor {

    public struct ExpenseUpdate: Equatable, Sendable {
        /// 匹配既有账目的关键词（原事项名/商品名）
        public let target: String
        /// 修改后金额（"30" / "30.5"），参数键 newAmount；改名场景为空串
        public let newAmount: String
        /// 修改后标题（改名场景），参数键 newTitle
        public let newTitle: String?

        public init(target: String, newAmount: String, newTitle: String? = nil) {
            self.target = target
            self.newAmount = newAmount
            self.newTitle = newTitle
        }
    }

    public struct TodoUpdate: Equatable, Sendable {
        public let target: String
        public let newTitle: String?
        /// 相对今天的天数
        public let dueAtDays: Int?
        /// HH:mm
        public let dueAtTime: String?

        public init(target: String, newTitle: String? = nil, dueAtDays: Int? = nil, dueAtTime: String? = nil) {
            self.target = target
            self.newTitle = newTitle
            self.dueAtDays = dueAtDays
            self.dueAtTime = dueAtTime
        }
    }

    // MARK: 修改账目

    public static func extractExpenseUpdate(from text: String) -> ExpenseUpdate? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 1. 改金额：「把X改成/改为/调整为 30」。数字边界断言防回溯截断
        //    （"把打车改成1234.56元" 必须得到 1234.56，而不是被 [0-9]+ 截成 56）。
        //    目标段不设可选名词组——「账/费用」留给 cleanTarget 剥，避免从目标里被抢走。
        if let match = firstMatch(
            pattern: "(?:把|将)?\\s*(.+?)\\s*(?:改成|改为|改到|调整为|调成)\\s*[¥￥]?\\s*(?<![0-9.．])([0-9]+(?:[.][0-9]+)?)(?![0-9])",
            in: trimmed
        ) {
            let target = cleanTarget(captured(match, 1, in: trimmed) ?? "", generic: expenseFillers)
            let newAmount = captured(match, 2, in: trimmed) ?? ""
            guard !target.isEmpty, !newAmount.isEmpty else { return nil }
            return ExpenseUpdate(target: target, newAmount: newAmount)
        }

        // 2. 改标题：仅明确的账目语境才归 expense，避免和 todo.update 抢；
        //    纯数字「新标题」不认（那是改金额的漏网写法，交给上面处理）
        if isExpenseContext(trimmed), !isTodoContext(trimmed),
           let match = firstMatch(
            pattern: "(?:把|将)?\\s*(.+?)\\s*(?:的)?\\s*(?:标题|名称|名字|名)?\\s*(?:改成|改为|改名为|改叫|改名成)\\s*[「\"“']?(.+?)[」\"”']?\\s*$",
            in: trimmed
           ) {
            let target = cleanTarget(captured(match, 1, in: trimmed) ?? "", generic: expenseFillers)
            let newTitle = captured(match, 2, in: trimmed)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !target.isEmpty, let newTitle, !newTitle.isEmpty, !isNumeric(newTitle) else { return nil }
            return ExpenseUpdate(target: target, newAmount: "", newTitle: newTitle)
        }
        return nil
    }

    // MARK: 修改待办

    public static func extractTodoUpdate(from text: String) -> TodoUpdate? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 1. 改时间：「把X改成/改到/推迟到 明天上午9点」。
        //    「改成」也在此尝试，但片段必须能解析成时间（parseDue 才放行）；
        //    解析不出（如「改成双周会」）落到下方改标题分支。
        if let match = firstMatch(
            pattern: "(?:把|将)?\\s*(.+?)\\s*(?:的)?\\s*(?:时间|截止|日期)?\\s*(?:改成|改为|改到|调到|挪到|延到|改在|推迟到|顺延到|延后到)\\s*(.+)$",
            in: trimmed
        ) {
            let target = cleanTarget(captured(match, 1, in: trimmed) ?? "", generic: todoFillers)
            let dateFragment = captured(match, 2, in: trimmed) ?? ""
            if !target.isEmpty, let due = parseDue(from: dateFragment) {
                return TodoUpdate(target: target, dueAtDays: due.days, dueAtTime: due.time)
            }
        }

        // 2. 改标题：「把X改成/改名为 Y」
        if let match = firstMatch(
            pattern: "(?:把|将)?\\s*(.+?)\\s*(?:的)?\\s*(?:标题|名称|名字|名)?\\s*(?:改成|改为|改名为|改叫|改名成|标题改成|标题改为)\\s*[「\"“']?(.+?)[」\"”']?\\s*$",
            in: trimmed
        ) {
            // 明显是账目语境的改名归 expense.update；纯数字「新标题」不认（改金额的漏网写法）
            if isExpenseContext(trimmed), !isTodoContext(trimmed) { return nil }
            let target = cleanTarget(captured(match, 1, in: trimmed) ?? "", generic: todoFillers)
            let newTitle = captured(match, 2, in: trimmed)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !target.isEmpty, let newTitle, !newTitle.isEmpty, !isNumeric(newTitle) else { return nil }
            return TodoUpdate(target: target, newTitle: newTitle)
        }
        return nil
    }

    // MARK: 时间片段解析

    /// 把「明天上午9点」「后天」「3天后」「周五」「20:00」解析为相对天数 + HH:mm。
    /// 不是时间表达（如「改成周会」）返回 nil，交给改标题分支。
    public static func parseDue(from fragment: String) -> (days: Int, time: String?)? {
        let t = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }

        var days: Int? = nil
        if let match = firstMatch(pattern: "(?<![0-9])([0-9]+)\\s*天后", in: t),
           let value = Int(captured(match, 1, in: t) ?? "") {
            days = value
        } else if t.contains("大后天") {
            days = 3
        } else if t.contains("后天") {
            days = 2
        } else if t.contains("明天") || t.contains("明早") || t.contains("明晚") || t.contains("明日") {
            days = 1
        } else if t.contains("今天") || t.contains("今晚") || t.contains("今日") {
            days = 0
        } else if let match = firstMatch(pattern: "周([一二三四五六日天])", in: t) {
            let map: [Character: Int] = ["一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "日": 7, "天": 7]
            if let ch = captured(match, 1, in: t)?.first, let target = map[ch] {
                // Calendar.weekday：周日=1。换算到周一=1...周日=7 再取差
                let today = Calendar.current.component(.weekday, from: .now)
                let normalizedToday = today == 1 ? 7 : today
                days = (target - normalizedToday + 7) % 7
            }
        }

        // 显式 HH:mm 优先于时段词
        var time: String? = nil
        if let match = firstMatch(pattern: "([01]?[0-9]|2[0-3]):[0-5][0-9]", in: t) {
            time = captured(match, 0, in: t)
        } else if t.contains("早上") || t.contains("上午") || t.contains("明早") {
            time = "09:00"
        } else if t.contains("中午") {
            time = "12:00"
        } else if t.contains("下午") {
            time = "15:00"
        } else if t.contains("晚上") || t.contains("今晚") || t.contains("明晚") {
            time = "20:00"
        }

        // 纯时间点（「改到3点」）按今天处理；连时间信号都没有就不是改期
        if days == nil {
            guard time != nil else { return nil }
            days = 0
        }
        return (days!, time)
    }

    // MARK: 私有工具

    private static let expenseFillers = [
        "那笔", "这笔", "那条", "那", "这", "一笔", "笔", "条", "个", "次", "项",
        "的账单", "账单", "的账", "账", "的费用", "费用", "的费", "费",
        "的支出", "支出", "的消费", "消费"
    ]

    private static let todoFillers = [
        "那个", "这个", "那", "这", "个", "项",
        "待办", "事项", "任务", "提醒", "日程", "行程", "安排", "的"
    ]

    private static func cleanTarget(_ raw: String, generic: [String]) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 反复剥填充词直到稳定（「那笔账」→「账」→「」）
        var changed = true
        while changed {
            changed = false
            for filler in generic where t.hasPrefix(filler) && t.count > filler.count {
                t = String(t.dropFirst(filler.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                changed = true
            }
            for filler in generic where t.hasSuffix(filler) && t.count > filler.count {
                t = String(t.dropLast(filler.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                changed = true
            }
        }
        // 剥空或只剩单字（纯填充词如「那笔账」）→ 保留原文，交给目标解析器模糊匹配
        return t.count <= 1 ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : t
    }

    private static func isNumeric(_ text: String) -> Bool {
        !text.isEmpty && text.range(of: "^[0-9.．]+$", options: .regularExpression) != nil
    }

    private static func isExpenseContext(_ text: String) -> Bool {
        containsAny(text, ["账", "费", "消费", "支出", "金额", "订单", "买", "花了", "花", "元", "块", "¥", "￥"])
    }

    private static func isTodoContext(_ text: String) -> Bool {
        containsAny(text, ["待办", "提醒", "日程", "会议", "约", "任务", "截止", "待", "行程", "安排", "事项"])
    }

    private static func containsAny(_ text: String, _ keywords: [String]) -> Bool {
        keywords.contains { text.contains($0) }
    }

    private static func firstMatch(pattern: String, in text: String) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        return regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count))
    }

    private static func captured(_ match: NSTextCheckingResult, _ index: Int, in text: String) -> String? {
        guard index < match.numberOfRanges,
              match.range(at: index).location != NSNotFound,
              let range = Range(match.range(at: index), in: text) else { return nil }
        return String(text[range])
    }
}
