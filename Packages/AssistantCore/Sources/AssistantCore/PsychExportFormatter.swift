import Foundation

// MARK: - 心理记录导出（纯逻辑下沉 Core）
//
// 为什么要下沉到 Core：**导出内容的恰当性必须能被测试钉住**，不能只靠肉眼检查。
// 导出是把用户最敏感的心理数据送到第三方服务的动作，
// 「导出了什么」「没导出什么」「给 AI 的指令写得对不对」都要有断言守着。
//
// ## 三条设计约束
//
// 1. **用户主动、可见、可控。** App **绝不自动上传**——只生成文本，
//    由用户自己复制/分享到想用的模型。这与「端侧模型自己解读」的根本区别是：
//    数据出不出本机，由用户按那一下决定。
//
// 2. **最小必要，但安全项不最小化。**
//    - **必须导出**：量表题目原文（否则外部模型不知道 13/27 意味着什么）、
//      逐题作答（含未作答标注）、微记录序列、睡眠与压力摘要。
//    - **不导出**：逐日 HRV / 心率等原始生理数据（对解读无必要，只是多暴露一份）、
//      任何身份信息、备注之外的用户数据。
//    - **安全项例外**：第 9 题（自伤意念）**必须**导出。
//      不导出它，外部模型就看不到最需要被回应的那一条——
//      这是安全优先于数据最小化的典型场景。
//
// 3. **导出内容必须自带给模型的指令。**
//    用户复制出去的只是一段文本，外部模型并不知道它是什么。
//    如果不带指令，模型很可能给出「你患有中度抑郁症」这种诊断，
//    或者漏掉第 9 题的风险。所以指令段是导出内容的**必备部分**，不是可选装饰。

// MARK: - 导出格式

/// 导出格式。
public enum PsychExportFormat: String, CaseIterable, Sendable, Codable {
    /// Markdown —— 给对话式模型直接粘贴，结构清晰、可读性最好。
    case markdown
    /// JSON —— 给有 API 的场景（自行接入），字段稳定、可程序化处理。
    case json

    public var displayName: String {
        switch self {
        case .markdown: return "Markdown（可直接粘贴给模型）"
        case .json: return "JSON（给有 API 的场景）"
        }
    }
}

// MARK: - 导出载荷

/// 导出用的一条量表记录。
public struct PsychExportScaleRecord: Equatable, Sendable {
    /// 量表标识。
    public let scaleID: PsychScaleID
    /// 完成时间。
    public let completedAt: Date
    /// 总分。数据不足时为 nil。
    public let totalScore: Int?
    /// 分档。数据不足时为 nil。
    public let band: PsychBandLevel?
    /// 逐题作答（含未作答标注）。
    public let answers: [Int: PsychItemAnswer]
    /// 安全信号。
    public let safetySignal: PsychSafetySignal

    public init(
        scaleID: PsychScaleID,
        completedAt: Date,
        totalScore: Int?,
        band: PsychBandLevel?,
        answers: [Int: PsychItemAnswer],
        safetySignal: PsychSafetySignal
    ) {
        self.scaleID = scaleID
        self.completedAt = completedAt
        self.totalScore = totalScore
        self.band = band
        self.answers = answers
        self.safetySignal = safetySignal
    }
}

/// 导出载荷。
///
/// 生理数据以**摘要**形式进入（睡眠均值、压力指数），
/// 逐日原始生理数据不导出——对解读无必要，只是多暴露一份。
public struct PsychExportPayload: Equatable, Sendable {
    /// 量表记录（按时间倒序）。
    public let scaleRecords: [PsychExportScaleRecord]
    /// 每日微记录（按时间倒序）。
    public let moodEntries: [MoodCheckInEntry]
    /// 近 N 日平均睡眠时长（小时）。nil 表示无数据。
    public let recentAverageSleepHours: Double?
    /// 生理压力指数（0~100）。nil 表示无数据。
    public let physiologicalStressScore: Int?
    /// 导出时间。
    public let exportedAt: Date

    public init(
        scaleRecords: [PsychExportScaleRecord],
        moodEntries: [MoodCheckInEntry],
        recentAverageSleepHours: Double? = nil,
        physiologicalStressScore: Int? = nil,
        exportedAt: Date = .now
    ) {
        self.scaleRecords = scaleRecords
        self.moodEntries = moodEntries
        self.recentAverageSleepHours = recentAverageSleepHours
        self.physiologicalStressScore = physiologicalStressScore
        self.exportedAt = exportedAt
    }

    /// 是否包含安全信号（非无）。
    public var hasSafetySignal: Bool {
        scaleRecords.contains { $0.safetySignal.requiresCrisisResponse }
    }

    /// 时间线事实：量表回忆窗与微记录的时间关系。
    ///
    /// ## 为什么导出「事实」而不是「结论」
    ///
    /// App 内部已经算清了「微记录比量表新」这类关系（`PsychChannelMerger`）。
    /// 但**不把它作为结论塞进导出**——那会让外部模型直接复述 App 的判断，
    /// 锚定在别人的结论上，丧失它自己的分析价值（App 的规则是刻意保守的：
    /// 不下因果、只给一个动作）。
    ///
    /// 给出的是**事实**：哪次量表什么时候做的、回忆窗覆盖哪段、
    /// 微记录覆盖哪段、哪部分晚于回忆窗。模型据此自己完成对齐，
    /// 既不会搞错时间窗，又不被结论带偏。
    public var timelineFacts: PsychExportTimelineFacts? {
        guard let latestScale = scaleRecords.max(by: { $0.completedAt < $1.completedAt }) else {
            return nil
        }
        let calendar = Calendar.current
        let scaleDay = calendar.startOfDay(for: latestScale.completedAt)
        let windowStart = calendar.date(
            byAdding: .day,
            value: -latestScale.scaleID.recallWindowDays,
            to: scaleDay
        ) ?? scaleDay

        let moodDays = moodEntries.map { calendar.startOfDay(for: $0.day) }
        let withinCount = moodDays.filter { $0 >= windowStart && $0 <= scaleDay }.count
        let afterCount = moodDays.filter { $0 > scaleDay }.count

        return PsychExportTimelineFacts(
            latestScaleCompletedAt: latestScale.completedAt,
            recallWindowStart: windowStart,
            recallWindowEnd: scaleDay,
            recallWindowDays: latestScale.scaleID.recallWindowDays,
            moodEntryCount: moodEntries.count,
            moodEntriesWithinWindow: withinCount,
            moodEntriesAfterWindow: afterCount,
            earliestMoodDay: moodDays.min(),
            latestMoodDay: moodDays.max()
        )
    }
}

/// 时间线事实（供导出用）。
public struct PsychExportTimelineFacts: Equatable, Sendable {
    /// 最近一次量表的完成时间。
    public let latestScaleCompletedAt: Date
    /// 回忆窗起始日。
    public let recallWindowStart: Date
    /// 回忆窗结束日（即量表完成日）。
    public let recallWindowEnd: Date
    /// 回忆窗长度（天）。
    public let recallWindowDays: Int
    /// 微记录总条数。
    public let moodEntryCount: Int
    /// 落在回忆窗内的微记录条数。
    public let moodEntriesWithinWindow: Int
    /// 晚于回忆窗的微记录条数。
    public let moodEntriesAfterWindow: Int
    /// 最早的微记录日。
    public let earliestMoodDay: Date?
    /// 最新的微记录日。
    public let latestMoodDay: Date?
}

// MARK: - 格式化器

/// 导出内容格式化器。
public enum PsychExportFormatter {

    /// 生成导出文本。
    public static func format(
        _ payload: PsychExportPayload,
        as format: PsychExportFormat
    ) -> String {
        switch format {
        case .markdown: return markdown(payload)
        case .json: return json(payload)
        }
    }

    // MARK: - Markdown

    /// 生成 Markdown 导出。
    public static func markdown(_ payload: PsychExportPayload) -> String {
        var lines: [String] = []

        lines.append("# 心理健康记录")
        lines.append("")
        lines.append(contentsOf: instructionBlock(payload))
        lines.append("")

        // —— 量表 ——
        if payload.scaleRecords.isEmpty {
            lines.append("## 一、量表记录")
            lines.append("")
            lines.append("（暂无量表记录）")
            lines.append("")
        } else {
            lines.append("## 一、量表记录")
            lines.append("")
            for record in payload.scaleRecords {
                lines.append(contentsOf: scaleSection(record))
                lines.append("")
            }
        }

        // —— 微记录 ——
        lines.append("## 二、每日微记录")
        lines.append("")
        if payload.moodEntries.isEmpty {
            lines.append("（暂无微记录）")
        } else {
            lines.append("| 日期 | 心情 1-5 | 精力 1-5 | 压力 1-5 |")
            lines.append("|---|---|---|---|")
            for entry in payload.moodEntries {
                lines.append("| \(dateString(entry.day)) | \(entry.moodScore) | \(entry.energyScore) | \(entry.stressScore) |")
            }
            lines.append("")
            lines.append("量表：心情 1=很低落…5=很轻快；精力 1=很疲惫…5=精力充沛；压力 1=没有压力…5=压力极大。")
        }
        lines.append("")

        // —— 生理摘要 ——
        lines.append("## 三、生理数据摘要")
        lines.append("")
        if let hours = payload.recentAverageSleepHours {
            lines.append("- 近 7 日平均睡眠：\(formatHours(hours)) 小时")
        }
        if let stress = payload.physiologicalStressScore {
            lines.append("- 压力指数：\(stress) / 100（≥60 视为负荷偏高）")
        }
        if payload.recentAverageSleepHours == nil && payload.physiologicalStressScore == nil {
            lines.append("（无生理数据）")
        }
        lines.append("")

        // —— 时间线 ——
        if let facts = payload.timelineFacts {
            lines.append(contentsOf: timelineSection(facts))
            lines.append("")
        }

        lines.append("---")
        lines.append("")
        lines.append("导出时间：\(dateTimeString(payload.exportedAt))")

        return lines.joined(separator: "\n")
    }

    /// 时间线提示段。
    ///
    /// 给的是**事实**（什么时候做的、回忆窗覆盖哪段、哪部分微记录更晚），
    /// 不是结论——让模型自己完成时间对齐，而不是复述 App 的判断。
    private static func timelineSection(_ facts: PsychExportTimelineFacts) -> [String] {
        var lines: [String] = []
        lines.append("## 四、时间线（用于正确对齐时间窗）")
        lines.append("")
        lines.append("- 最近一次量表完成于 \(dateString(facts.latestScaleCompletedAt))，其回忆窗覆盖 \(dateString(facts.recallWindowStart)) 至 \(dateString(facts.recallWindowEnd))（过去 \(facts.recallWindowDays) 天）")

        if facts.moodEntryCount > 0 {
            var line = "- 每日微记录共 \(facts.moodEntryCount) 条"
            if let earliest = facts.earliestMoodDay, let latest = facts.latestMoodDay {
                line += "，覆盖 \(dateString(earliest)) 至 \(dateString(latest))"
            }
            line += "；其中 \(facts.moodEntriesWithinWindow) 条落在该回忆窗内"
            if facts.moodEntriesAfterWindow > 0 {
                line += "，\(facts.moodEntriesAfterWindow) 条**晚于**回忆窗（即比这次量表更近）"
            }
            lines.append(line)
        } else {
            lines.append("- 没有每日微记录")
        }

        lines.append("- 量表分数反映的是**回忆窗内**的情况；晚于回忆窗的微记录代表**更近的状态**。")
        lines.append("- 解读时请把两者分开表述，不要混为同一段时间。")
        return lines
    }

    /// 给外部模型的指令段。
    ///
    /// 这是导出内容里**最重要的一段**。用户复制出去的只是一段文本，
    /// 模型不知道它是什么、也不该做什么——不带指令，模型很可能直接下诊断。
    private static func instructionBlock(_ payload: PsychExportPayload) -> [String] {
        var lines: [String] = []
        lines.append("> **给 AI 模型的说明（请先读完这段再回应）**")
        lines.append(">")
        lines.append("> 这是一位用户自己填写的心理健康自测记录，供你参考理解其近期状态。")
        lines.append(">")
        lines.append("> 请遵守以下几点：")
        lines.append(">")
        lines.append("> 1. **不做医学诊断。** 这些是筛查量表，分数只描述近两周的症状频率，")
        lines.append(">    不能作为「患有抑郁症 / 焦虑症」的判定依据，也不要使用这类表述。")
        lines.append("> 2. **关注趋势而非单次分数。** 用户可能有多次记录，请结合时间顺序看变化方向。")
        lines.append("> 3. **区分「过去两周」与「最近」。** 量表回忆窗是过去 14 天，")
        lines.append(">    微记录是当天数据；两者时间窗不同，不要混为一谈。")
        lines.append("> 4. **给具体、小、可立刻做的动作**，而不是笼统建议。")
        lines.append(">    「先出门走 10 分钟」比「多运动有益身心」有用得多。")
        lines.append("> 5. **只描述现象，不下因果断言。** 可以说「两件事同时出现」，")
        lines.append(">    不要说「因为没睡好所以情绪低落」——观察性数据支撑不了因果，")
        lines.append(">    而错误的因果会让用户自责。")

        if payload.hasSafetySignal {
            lines.append(">")
            lines.append("> **⚠️ 特别注意：下面的记录中，安全信号不是「无」。**")
            lines.append(">    这意味着用户自述最近有过伤害自己的念头。")
            lines.append(">    请**优先**在回复的开头给出求助路径——")
            lines.append(">    全国统一心理援助热线 **12356**（24 小时 · 免费 · 保密），")
            lines.append(">    以及「建议尽快联系精神科或心理科专业人员」。")
            lines.append(">    不要淡化、不要只谈情绪管理，也不要因为分数不高就略过这一点。")
        }

        lines.append(">")
        lines.append("> 提醒用户：这是自助记录工具，不能替代专业帮助。")
        return lines
    }

    /// 单条量表记录的 Markdown 段。
    private static func scaleSection(_ record: PsychExportScaleRecord) -> [String] {
        var lines: [String] = []
        let definition = PsychScaleCatalog.definition(for: record.scaleID)

        lines.append("### \(record.scaleID.displayName)（\(record.scaleID.chineseName)）")
        lines.append("")
        lines.append("- 完成时间：\(dateTimeString(record.completedAt))")
        lines.append("- 回忆窗：过去 \(record.scaleID.recallWindowDays) 天")
        if let total = record.totalScore {
            let bandText = record.band.map { "（\($0.displayName)）" } ?? ""
            lines.append("- 总分：**\(total) / \(definition.maxTotalScore)**\(bandText)")
            // 折算必须显式标注——否则外部模型会把折算分当成直接求和的分。
            let unanswered = definition.items.filter { record.answers[$0.index]?.score == nil }.count
            if unanswered > 0 {
                lines.append("- ⚠️ 有 \(unanswered) 题未作答，总分已按量表标准做法折算，**不是**直接求和的结果")
            }
        } else {
            lines.append("- 总分：数据不足，未计分")
        }
        lines.append("- 筛查阈值：\(definition.screeningCutoff)（中文一般人群验证值，≥ 该值提示可能需要专业支持）")

        // 逐题明细 —— 必须含题目原文，否则外部模型无从理解分数的含义。
        lines.append("")
        lines.append("| 题号 | 题目 | 作答 | 得分 |")
        lines.append("|---|---|---|---|")
        for item in definition.items {
            let answer = record.answers[item.index]
            let label: String
            let scoreText: String
            switch answer {
            case .answered(let score):
                label = PsychResponseOptions.standard.first { $0.score == score }?.label ?? "\(score) 分"
                scoreText = "\(score)"
            case .unanswered:
                label = "未作答"
                scoreText = "—"
            case nil:
                label = "未作答"
                scoreText = "—"
            }
            lines.append("| \(item.index) | \(item.prompt) | \(label) | \(scoreText) |")
        }

        lines.append("")
        let safetyText = record.safetySignal == .none ? "无" : "**有（该次作答包含自伤意念题的非零回答）**"
        lines.append("- 安全信号：\(safetyText)")

        return lines
    }

    // MARK: - JSON

    /// 生成 JSON 导出。
    ///
    /// 用 `JSONEncoder` 而不是手工拼字符串——手工拼 JSON 迟早会因为转义出问题，
    /// 而这份内容是要被外部程序直接消费的，格式错误比内容问题更隐蔽。
    public static func json(_ payload: PsychExportPayload) -> String {
        let dto = ExportDTO(payload: payload)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(dto),
              let text = String(data: data, encoding: .utf8) else {
            // 编码失败时给一段可读的兜底，而不是空字符串——
            // 空字符串会被用户当成「没有数据」。
            return "{\"error\":\"导出编码失败\"}"
        }
        return text
    }

    /// JSON 导出的 DTO。
    private struct ExportDTO: Encodable {
        struct ScaleDTO: Encodable {
            let scaleID: String
            let scaleName: String
            let scaleChineseName: String
            let completedAt: Date
            let recallWindowDays: Int
            let totalScore: Int?
            let maxTotalScore: Int
            let band: String?
            let screeningCutoff: Int
            let safetySignal: String
            /// 未作答题数（>0 时总分是折算值，不是直接求和）。
            let unansweredItemCount: Int
            let items: [ItemDTO]

            struct ItemDTO: Encodable {
                let index: Int
                let prompt: String
                let answerLabel: String
                let score: Int?
                let isSafetyItem: Bool
            }
        }

        struct MoodDTO: Encodable {
            let day: Date
            let moodScore: Int
            let energyScore: Int
            let stressScore: Int
        }

        /// 时间线事实（给模型做时间窗对齐用；不是结论）。
        struct TimelineDTO: Encodable {
            let latestScaleCompletedAt: Date
            let recallWindowStart: Date
            let recallWindowEnd: Date
            let recallWindowDays: Int
            let moodEntryCount: Int
            let moodEntriesWithinWindow: Int
            let moodEntriesAfterWindow: Int
            let earliestMoodDay: Date?
            let latestMoodDay: Date?
        }

        let exportedAt: Date
        /// 给模型的指令（JSON 里同样带，方便程序化场景拼进 system prompt）。
        let instructions: [String]
        let hasSafetySignal: Bool
        let scaleRecords: [ScaleDTO]
        let moodEntries: [MoodDTO]
        let recentAverageSleepHours: Double?
        let physiologicalStressScore: Int?
        /// 时间线事实。nil 表示没有量表记录可算时间线。
        let timeline: TimelineDTO?

        init(payload: PsychExportPayload) {
            exportedAt = payload.exportedAt
            instructions = PsychExportFormatter.instructionLines(payload)
            hasSafetySignal = payload.hasSafetySignal
            recentAverageSleepHours = payload.recentAverageSleepHours
            physiologicalStressScore = payload.physiologicalStressScore

            scaleRecords = payload.scaleRecords.map { record in
                let definition = PsychScaleCatalog.definition(for: record.scaleID)
                let items = definition.items.map { item -> ScaleDTO.ItemDTO in
                    let answer = record.answers[item.index]
                    let score = answer?.score
                    let label: String
                    switch answer {
                    case .answered(let value):
                        label = PsychResponseOptions.standard.first { $0.score == value }?.label ?? "\(value) 分"
                    default:
                        label = "未作答"
                    }
                    return ScaleDTO.ItemDTO(
                        index: item.index,
                        prompt: item.prompt,
                        answerLabel: label,
                        score: score,
                        isSafetyItem: item.isSafetyItem
                    )
                }
                return ScaleDTO(
                    scaleID: record.scaleID.rawValue,
                    scaleName: record.scaleID.displayName,
                    scaleChineseName: record.scaleID.chineseName,
                    completedAt: record.completedAt,
                    recallWindowDays: record.scaleID.recallWindowDays,
                    totalScore: record.totalScore,
                    maxTotalScore: definition.maxTotalScore,
                    band: record.band?.displayName,
                    screeningCutoff: definition.screeningCutoff,
                    safetySignal: record.safetySignal.rawValue,
                    unansweredItemCount: definition.items.filter { record.answers[$0.index]?.score == nil }.count,
                    items: items
                )
            }

            moodEntries = payload.moodEntries.map {
                MoodDTO(
                    day: $0.day,
                    moodScore: $0.moodScore,
                    energyScore: $0.energyScore,
                    stressScore: $0.stressScore
                )
            }

            if let facts = payload.timelineFacts {
                timeline = TimelineDTO(
                    latestScaleCompletedAt: facts.latestScaleCompletedAt,
                    recallWindowStart: facts.recallWindowStart,
                    recallWindowEnd: facts.recallWindowEnd,
                    recallWindowDays: facts.recallWindowDays,
                    moodEntryCount: facts.moodEntryCount,
                    moodEntriesWithinWindow: facts.moodEntriesWithinWindow,
                    moodEntriesAfterWindow: facts.moodEntriesAfterWindow,
                    earliestMoodDay: facts.earliestMoodDay,
                    latestMoodDay: facts.latestMoodDay
                )
            } else {
                timeline = nil
            }
        }
    }

    /// 指令段的纯文本行（Markdown 与 JSON 共用同一份内容，避免两处漂移）。
    private static func instructionLines(_ payload: PsychExportPayload) -> [String] {
        var lines: [String] = []
        lines.append("这是一份用户自己填写的心理健康自测记录，供你参考理解其近期状态。")
        lines.append("不做医学诊断：这些是筛查量表，分数只描述近两周的症状频率，不能作为「患有抑郁症 / 焦虑症」的判定依据，也不要使用这类表述。")
        lines.append("关注趋势而非单次分数：用户可能有多次记录，请结合时间顺序看变化方向。")
        lines.append("区分「过去两周」与「最近」：量表回忆窗是过去 14 天，微记录是当天数据；两者时间窗不同，不要混为一谈。")
        lines.append("给具体、小、可立刻做的动作，而不是笼统建议。")
        lines.append("只描述现象，不下因果断言：可以说「两件事同时出现」，不要说「因为没睡好所以情绪低落」。")
        if payload.hasSafetySignal {
            lines.append("【重要】安全信号不是「无」：用户自述最近有过伤害自己的念头。请优先在回复开头给出求助路径——全国统一心理援助热线 12356（24 小时 · 免费 · 保密），以及「建议尽快联系精神科或心理科专业人员」。不要淡化、不要只谈情绪管理，也不要因为分数不高就略过这一点。")
        }
        lines.append("提醒用户：这是自助记录工具，不能替代专业帮助。")
        return lines
    }

    // MARK: - 日期格式化

    /// 日期（yyyy-MM-dd）。
    ///
    /// 用 `en_US_POSIX` + 固定时区之外不做本地化——导出内容要稳定可解析，
    /// 不受用户手机语言与地区设置影响。
    private static func dateString(_ date: Date) -> String {
        formatter("yyyy-MM-dd", timeZone: nil).string(from: date)
    }

    /// 日期时间（yyyy-MM-dd HH:mm）。
    private static func dateTimeString(_ date: Date) -> String {
        formatter("yyyy-MM-dd HH:mm", timeZone: nil).string(from: date)
    }

    private static func formatter(_ format: String, timeZone: TimeZone?) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        if let timeZone { f.timeZone = timeZone }
        return f
    }

    /// 小时数格式化（一位小数）。
    private static func formatHours(_ hours: Double) -> String {
        String(format: "%.1f", hours)
    }
}
