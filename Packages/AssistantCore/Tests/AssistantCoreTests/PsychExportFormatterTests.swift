import AssistantCore
import XCTest

/// 心理记录导出的回归测试。
///
/// 核心风险（按危害排序）：
/// 1. **导出内容让外部模型下诊断**——不带指令段，模型很可能说「你患有中度抑郁症」。
/// 2. **第 9 题被漏掉**——不导出它，外部模型看不到最需要被回应的那一条。
/// 3. **题目原文缺失**——只给「13/27」，模型无从理解分数的含义。
/// 4. **数据最小化没做到**——把逐日 HRV 等无关原始数据也导出去。
/// 5. **两种格式内容漂移**——JSON 与 Markdown 说法不一致。
final class PsychExportFormatterTests: XCTestCase {

    // MARK: - 测试辅助

    private var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return cal
    }()

    private let now = Date(timeIntervalSince1970: 1_792_819_200)

    private func day(_ daysAgo: Int) -> Date {
        let raw = calendar.date(byAdding: .day, value: -daysAgo, to: now) ?? now
        return calendar.startOfDay(for: raw)
    }

    /// 构造一条量表记录。
    private func scaleRecord(
        total: Int,
        daysAgo: Int = 0,
        scaleID: PsychScaleID = .phq9,
        safetyScore: Int = 0
    ) -> PsychExportScaleRecord {
        let definition = PsychScaleCatalog.definition(for: scaleID)
        var answers: [Int: PsychItemAnswer] = [:]
        var remaining = total
        for item in definition.items {
            if item.isSafetyItem {
                answers[item.index] = .answered(score: safetyScore)
                continue
            }
            let v = min(3, max(0, remaining))
            answers[item.index] = .answered(score: v)
            remaining -= v
        }
        let score = PsychScaleScorer.score(answers: answers, definition: definition)
        return PsychExportScaleRecord(
            scaleID: scaleID,
            completedAt: day(daysAgo),
            totalScore: score.totalScore,
            band: score.band,
            answers: answers,
            safetySignal: PsychSafetyRouter.detectSignal(answers: answers, definition: definition)
        )
    }

    private func mood(daysAgo: Int, mood: Int = 3, energy: Int = 3, stress: Int = 2) -> MoodCheckInEntry {
        MoodCheckInEntry(day: day(daysAgo), moodScore: mood, energyScore: energy, stressScore: stress)
    }

    private func payload(
        scales: [PsychExportScaleRecord],
        moods: [MoodCheckInEntry] = [],
        sleep: Double? = nil,
        stress: Int? = nil
    ) -> PsychExportPayload {
        PsychExportPayload(
            scaleRecords: scales,
            moodEntries: moods,
            recentAverageSleepHours: sleep,
            physiologicalStressScore: stress,
            exportedAt: now
        )
    }

    // MARK: - 指令段（核心风险 1）

    /// 核心风险 1：导出内容必须自带「不要下诊断」的指令。
    func testExportContainsExplicitNoDiagnosisInstruction() {
        let text = PsychExportFormatter.markdown(payload(scales: [scaleRecord(total: 13)]))
        XCTAssertTrue(text.contains("不做医学诊断"), "导出必须自带「不做医学诊断」的指令")
        XCTAssertTrue(text.contains("给 AI 模型的说明"),
                      "导出必须自带给模型的说明段——用户复制出去的只是一段文本")
    }

    /// 核心风险 1：指令必须要求具体动作而非笼统建议。
    func testExportAsksForConcreteSmallActions() {
        let text = PsychExportFormatter.markdown(payload(scales: [scaleRecord(total: 13)]))
        XCTAssertTrue(text.contains("具体、小、可立刻做的动作"))
    }

    /// 核心风险 1：指令必须禁止因果断言。
    func testExportForbidsCausalWording() {
        let text = PsychExportFormatter.markdown(payload(scales: [scaleRecord(total: 13)]))
        XCTAssertTrue(text.contains("只描述现象，不下因果断言"))
    }

    // MARK: - 安全信号（核心风险 2）

    /// 核心风险 2：第 9 题非零时，导出必须带安全信号与求助路径。
    func testExportIncludesSafetySignalAndHotlineWhenPresent() {
        let record = scaleRecord(total: 1, safetyScore: 1)
        XCTAssertEqual(record.safetySignal, .selfHarmIdeation)

        let text = PsychExportFormatter.markdown(payload(scales: [record]))
        XCTAssertTrue(text.contains("安全信号不是「无」"),
                      "有安全信号时，指令必须显著提示外部模型")
        XCTAssertTrue(text.contains("12356"), "必须给出官方求助热线号码")
        XCTAssertTrue(text.contains("优先"), "必须要求模型优先给求助路径")
    }

    /// 无安全信号时不得渲染危机段落。
    func testExportOmitsCrisisInstructionWhenNoSignal() {
        let text = PsychExportFormatter.markdown(payload(scales: [scaleRecord(total: 13)]))
        XCTAssertFalse(text.contains("安全信号不是「无」"))
        XCTAssertTrue(text.contains("安全信号：无"), "仍要如实标注安全信号为无")
    }

    /// 核心风险 2：第 9 题的作答本身必须出现在导出里。
    func testExportIncludesSafetyItemAnswer() {
        let record = scaleRecord(total: 1, safetyScore: 1)
        let text = PsychExportFormatter.markdown(payload(scales: [record]))
        XCTAssertTrue(text.contains("有不如死掉或用某种方式伤害自己的念头"),
                      "安全题的题面必须导出——否则模型看不到它")
        XCTAssertTrue(text.contains("安全信号：**有"),
                      "安全信号必须被显著标注")
    }

    // MARK: - 题目原文（核心风险 3）

    /// 核心风险 3：必须含题目原文，否则外部模型无从理解分数。
    func testExportIncludesItemPromptsVerbatim() {
        let text = PsychExportFormatter.markdown(payload(scales: [scaleRecord(total: 13)]))
        XCTAssertTrue(text.contains("做事时提不起劲或没有兴趣"))
        XCTAssertTrue(text.contains("入睡困难、睡不安稳或睡眠过多"))
        XCTAssertTrue(text.contains("觉得自己很糟或觉得自己很失败，或让自己或家人失望"))
    }

    /// 未作答的题目必须显式标注，不能静默消失。
    func testExportMarksUnansweredItems() {
        var answers: [Int: PsychItemAnswer] = [:]
        for item in PsychScaleCatalog.phq9.items {
            answers[item.index] = item.index == 3 ? .unanswered : .answered(score: 0)
        }
        let record = PsychExportScaleRecord(
            scaleID: .phq9,
            completedAt: day(0),
            totalScore: nil,
            band: nil,
            answers: answers,
            safetySignal: .none
        )
        let text = PsychExportFormatter.markdown(payload(scales: [record]))
        XCTAssertTrue(text.contains("未作答"), "未作答必须显式标注，不能静默省略")
        XCTAssertTrue(text.contains("数据不足，未计分"))
    }

    /// 筛查阈值必须导出——外部模型需要知道「多少分算需要关注」。
    func testExportIncludesScreeningCutoff() {
        let text = PsychExportFormatter.markdown(payload(scales: [scaleRecord(total: 13)]))
        XCTAssertTrue(text.contains("筛查阈值：7"),
                      "必须导出中文人群验证的筛查阈值，否则模型会用西方通用值 10 误判")
    }

    /// 折算分必须显式标注——否则外部模型会把折算值当成直接求和的分。
    func testExportMarksProratedTotal() {
        var answers: [Int: PsychItemAnswer] = [:]
        for item in PsychScaleCatalog.phq9.items {
            answers[item.index] = item.index == 5 ? .unanswered : .answered(score: 0)
        }
        let record = PsychExportScaleRecord(
            scaleID: .phq9,
            completedAt: day(0),
            totalScore: 1,
            band: .none,
            answers: answers,
            safetySignal: .none
        )
        let text = PsychExportFormatter.markdown(payload(scales: [record]))
        XCTAssertTrue(text.contains("总分已按量表标准做法折算"),
                      "折算事实必须显式标注，否则外部模型会把折算分当成直接求和")
    }

    /// JSON 侧也要带折算标记——两种格式不得漂移。
    func testJSONExportAlsoMarksProratedTotal() {
        var answers: [Int: PsychItemAnswer] = [:]
        for item in PsychScaleCatalog.phq9.items {
            answers[item.index] = item.index == 5 ? .unanswered : .answered(score: 0)
        }
        let record = PsychExportScaleRecord(
            scaleID: .phq9,
            completedAt: day(0),
            totalScore: 1,
            band: .none,
            answers: answers,
            safetySignal: .none
        )
        let json = PsychExportFormatter.json(payload(scales: [record]))
        XCTAssertTrue(json.contains("unansweredItemCount"))
    }

    // MARK: - 数据最小化（核心风险 4）

    /// 核心风险 4：导出的载荷结构里**没有**逐日原始生理数据的位置。
    ///
    /// 这条测试锁的是类型层面的约束：即使将来有人想加，也得显式改这个类型。
    func testPayloadHasNoRawPhysiologicalSeries() {
        let p = payload(scales: [scaleRecord(total: 13)], sleep: 5.8, stress: 72)
        let text = PsychExportFormatter.markdown(p)

        // 摘要必须在。
        XCTAssertTrue(text.contains("近 7 日平均睡眠：5.8 小时"))
        XCTAssertTrue(text.contains("压力指数：72 / 100"))

        // 但不得出现逐项原始生理指标名。
        for raw in ["心率变异性", "HRV", "静息心率", "血氧", "体温", "呼吸频率"] {
            XCTAssertFalse(text.contains(raw),
                           "不应导出逐项原始生理数据「\(raw)」——对解读无必要，只是多暴露一份")
        }
    }

    /// 导出内容不得包含任何身份信息。
    func testExportContainsNoIdentityInformation() {
        let text = PsychExportFormatter.markdown(payload(scales: [scaleRecord(total: 13)]))
        for identity in ["小助", "用户昵称", "身份证", "手机号"] {
            XCTAssertFalse(text.contains(identity))
        }
    }

    // MARK: - JSON（核心风险 5）

    /// 核心风险 5：JSON 必须是**合法 JSON**。
    func testJSONExportIsValidJSON() {
        let text = PsychExportFormatter.json(
            payload(scales: [scaleRecord(total: 13)], moods: [mood(daysAgo: 0)], sleep: 5.8, stress: 72)
        )
        guard let data = text.data(using: .utf8) else {
            return XCTFail("导出不是合法 UTF-8")
        }
        let object = try? JSONSerialization.jsonObject(with: data)
        XCTAssertNotNil(object, "JSON 导出必须是合法 JSON")
        XCTAssertTrue(object is [String: Any])
    }

    /// 核心风险 5：JSON 里必须带指令与安全信号。
    func testJSONExportIncludesInstructionsAndSafetyFlag() {
        let safe = PsychExportFormatter.json(payload(scales: [scaleRecord(total: 13)]))
        XCTAssertTrue(safe.contains("不做医学诊断"))
        XCTAssertTrue(safe.contains("\"hasSafetySignal\" : false"))

        let risky = PsychExportFormatter.json(payload(scales: [scaleRecord(total: 1, safetyScore: 1)]))
        XCTAssertTrue(risky.contains("\"hasSafetySignal\" : true"))
        XCTAssertTrue(risky.contains("12356"))
    }

    /// 核心风险 5：两种格式的安全指令内容必须一致（防止改了一处忘了另一处）。
    func testBothFormatsCarrySameSafetyInstruction() {
        let p = payload(scales: [scaleRecord(total: 1, safetyScore: 1)])
        let md = PsychExportFormatter.markdown(p)
        let json = PsychExportFormatter.json(p)
        XCTAssertTrue(md.contains("12356"))
        XCTAssertTrue(json.contains("12356"))
        XCTAssertTrue(md.contains("不做医学诊断"))
        XCTAssertTrue(json.contains("不做医学诊断"))
    }

    // MARK: - 空数据

    /// 没有量表记录时导出仍应可用，且明确说明「暂无」。
    func testExportHandlesEmptyPayloadGracefully() {
        let text = PsychExportFormatter.markdown(payload(scales: []))
        XCTAssertTrue(text.contains("暂无量表记录"))
        XCTAssertTrue(text.contains("暂无微记录"))
        XCTAssertTrue(text.contains("不做医学诊断"), "即使没有数据也要带指令段")
    }

    // MARK: - 时间线事实（不给结论，给事实）

    /// 时间线段必须给出**事实**：量表什么时候做的、回忆窗覆盖哪段、
    /// 哪部分微记录晚于回忆窗。外部模型据此自己完成时间对齐。
    func testExportIncludesTimelineFacts() {
        // 量表 14 天前完成 → 回忆窗 [28 天前, 14 天前]
        // 微记录在最近 5 天 → 全部晚于回忆窗
        let record = scaleRecord(total: 13, daysAgo: 14)
        let moods = (0..<5).map { mood(daysAgo: $0, mood: 2, energy: 2, stress: 4) }

        let text = PsychExportFormatter.markdown(payload(scales: [record], moods: moods))
        XCTAssertTrue(text.contains("时间线"), "必须有时间线段")
        XCTAssertTrue(text.contains("回忆窗覆盖"), "必须说明回忆窗覆盖哪段时间")
        XCTAssertTrue(text.contains("晚于"), "必须标出哪些微记录比量表更新")
        XCTAssertTrue(text.contains("更近的状态"),
                      "必须提示「晚于回忆窗的微记录代表更近的状态」——这是模型最容易搞错的一处")
    }

    /// 时间线段给的是**事实**，不是 App 的结论——
    /// 塞结论会让外部模型锚定在别人的判断上，丧失它自己的分析价值。
    func testTimelineSectionGivesFactsNotConclusions() {
        let record = scaleRecord(total: 13, daysAgo: 14)
        let moods = (0..<5).map { mood(daysAgo: $0, mood: 2, energy: 2, stress: 4) }

        let text = PsychExportFormatter.markdown(payload(scales: [record], moods: moods))
        // App 内部的结论措辞不得出现在导出里。
        for conclusion in ["指向同一件事", "问卷滞后", "在往下走", "连续", "上升", "恶化"] {
            XCTAssertFalse(text.contains(conclusion),
                           "导出不得包含 App 的结论「\(conclusion)」——只给事实，让模型自己判断")
        }
    }

    /// JSON 侧也要带时间线事实——两种格式不得漂移。
    func testJSONExportIncludesTimeline() {
        let record = scaleRecord(total: 13, daysAgo: 14)
        let moods = (0..<5).map { mood(daysAgo: $0) }
        let json = PsychExportFormatter.json(payload(scales: [record], moods: moods))
        XCTAssertTrue(json.contains("recallWindowStart"))
        XCTAssertTrue(json.contains("moodEntriesAfterWindow"))
    }

    /// 没有量表记录时没有时间线可算（nil），不得编造。
    func testNoTimelineWhenNoScaleRecords() {
        let p = payload(scales: [], moods: [mood(daysAgo: 0)])
        XCTAssertNil(p.timelineFacts)
    }
}
