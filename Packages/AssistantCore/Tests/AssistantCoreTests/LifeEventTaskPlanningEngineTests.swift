import AssistantCore
import XCTest

final class LifeEventTaskPlanningEngineTests: XCTestCase {

    func testCarBuyingQuestionsGeneratedForBudgetAndPurposeTask() {
        let questions = LifeEventTaskPlanningEngine.questions(for: "明确购车预算与用途", templateRaw: "买车")
        XCTAssertFalse(questions.isEmpty)
        let ids = questions.map(\.id)
        XCTAssertTrue(ids.contains("budget"))
        XCTAssertTrue(ids.contains("purpose"))
        XCTAssertTrue(ids.contains("powertrain"))
        XCTAssertTrue(ids.contains("charging"))
        XCTAssertTrue(ids.contains("space"))

        let budgetQ = questions.first(where: { $0.id == "budget" })
        XCTAssertNotNil(budgetQ)
        XCTAssertTrue(budgetQ?.presetOptions.contains("20-25万") ?? false)
    }

    func testHouseBuyingQuestionsGenerated() {
        let questions = LifeEventTaskPlanningEngine.questions(for: "确定总价上限与首付比例", templateRaw: "买房")
        let ids = questions.map(\.id)
        XCTAssertTrue(ids.contains("budget"))
        XCTAssertTrue(ids.contains("qualification"))
        XCTAssertTrue(ids.contains("location"))
    }

    func testRenovationQuestionsGenerated() {
        let questions = LifeEventTaskPlanningEngine.questions(for: "明确需求与风格", templateRaw: "装修")
        let ids = questions.map(\.id)
        XCTAssertTrue(ids.contains("budget"))
        XCTAssertTrue(ids.contains("style"))
        XCTAssertTrue(ids.contains("systems"))
    }

    func testGenericQuestionsGeneratedForUnknownTask() {
        let questions = LifeEventTaskPlanningEngine.questions(for: "办理某某特定手续", templateRaw: "自定义人生大事")
        XCTAssertEqual(questions.count, 4)
        let ids = questions.map(\.id)
        XCTAssertTrue(ids.contains("goal"))
        XCTAssertTrue(ids.contains("constraints"))
    }

    func testGenerateConsultationPromptIncludesContextAndAnswers() {
        let answers = [
            "购车预算与支付形式": "落地 22 万，首付 10 万",
            "主要用途与出行场景": "工作日单程 20km 通勤，周末带娃"
        ]
        let prompt = LifeEventTaskPlanningEngine.generateConsultationPrompt(
            projectTitle: "提车计划",
            templateName: "买车",
            targetDateText: "2027年4月26日",
            locationText: "杭州",
            taskTitle: "明确购车预算与用途",
            stageTitle: "确定需求与预算",
            answers: answers
        )

        XCTAssertTrue(prompt.contains("提车计划"))
        XCTAssertTrue(prompt.contains("明确购车预算与用途"))
        XCTAssertTrue(prompt.contains("落地 22 万，首付 10 万"))
        XCTAssertTrue(prompt.contains("工作日单程 20km 通勤，周末带娃"))
        XCTAssertTrue(prompt.contains("汽车消费顾问"))
        XCTAssertTrue(prompt.contains("下一步具体行动待办"))
    }

    func testParseAIDecisionOutputExtractsActionItems() {
        let rawAI = """
        针对您的 20-25 万预算与家庭通勤需求，给出以下方案与建议：

        一、【决策建议与方案推荐】
        1. 理想 L6 Pro（落地约 24.5 万）：大五座空间宽敞，底盘舒适滤震极佳。
        2. 问界 M7 Plus（落地约 24 万）：智驾与鸿蒙车机领先，适合智能化追求。

        二、【避坑指南与关键提醒】
        - 谨防销售将上牌费加收 1000 元以上；
        - 免息分期需核对有无金融服务费与解押手续费。

        三、【下一步具体行动待办】
        - 预约理想 L6 与问界 M7 门店试驾并重点体验后排
        - 确认小区物业安装 7kW 家用交流充电桩申请流程
        - 向两家 4S 店分别索要底价报价单与赠品明细
        - 测算 5 年低息与免息分期落地真实总成本
        """

        let (summary, items) = LifeEventTaskPlanningEngine.parseAIDecisionOutput(rawOutput: rawAI)
        XCTAssertFalse(summary.isEmpty)
        XCTAssertEqual(items.count, 4)
        XCTAssertTrue(items.contains("预约理想 L6 与问界 M7 门店试驾并重点体验后排"))
        XCTAssertTrue(items.contains("确认小区物业安装 7kW 家用交流充电桩申请流程"))
        XCTAssertTrue(items.contains("测算 5 年低息与免息分期落地真实总成本"))
    }

    // MARK: - AI 决策输出检测（投喂口分流用）

    private let sampleAIDecision = """
    针对您的 20-25 万预算与家庭通勤需求，给出以下方案与建议：

    一、【决策建议与方案推荐】
    1. 理想 L6 Pro（落地约 24.5 万）：大五座空间宽敞，底盘舒适滤震极佳，适合家庭出行。
    2. 问界 M7 Plus（落地约 24 万）：智驾与鸿蒙车机领先，适合智能化追求的用户群体。

    二、【避坑指南与关键提醒】
    - 谨防销售将上牌费加收 1000 元以上；
    - 免息分期需核对有无金融服务费与解押手续费。

    三、【下一步具体行动待办】
    - 预约理想 L6 与问界 M7 门店试驾并重点体验后排
    - 确认小区物业安装 7kW 家用交流充电桩申请流程
    - 向两家 4S 店分别索要底价报价单与赠品明细
    - 测算 5 年低息与免息分期落地真实总成本
    """

    func testLooksLikeAIDecisionOutputDetectsStructuredDecision() {
        XCTAssertTrue(LifeEventTaskPlanningEngine.looksLikeAIDecisionOutput(sampleAIDecision))
    }

    func testLooksLikeAIDecisionOutputRejectsShortInput() {
        XCTAssertFalse(LifeEventTaskPlanningEngine.looksLikeAIDecisionOutput("明天开会"))
        XCTAssertFalse(LifeEventTaskPlanningEngine.looksLikeAIDecisionOutput(
            "- 预约试驾\n- 确认报价\n下一步：等回复"
        ))
    }

    func testLooksLikeAIDecisionOutputRejectsLongMemoWithoutActionSection() {
        // 长备忘/日记：没有「行动待办」分区标记，即便有列表也不劫持
        let journal = """
        今天把这周的工作都过了一遍，感觉节奏还是偏快。
        上午开了两个会，讨论了下季度的目标拆解和人力安排问题。
        下午把需求文档写完了，顺便把测试用例也补充了一部分。
        - 上午会议纪要整理发群里
        - 下午文档评审需要注意口径一致性
        - 明天把遗留的 bug 清一清
        - 后天准备周会材料
        晚上去健身房练了一小时，感觉状态还不错。
        """
        XCTAssertFalse(LifeEventTaskPlanningEngine.looksLikeAIDecisionOutput(journal))
    }

    func testLooksLikeAIDecisionOutputRejectsSectionMarkerWithoutActionItems() {
        // 有分区标记但解不出行动项（全是长段落没有清单行）→ 不是决策输出
        let prose = """
        【下一步具体行动待办】

        接下来建议您综合考虑家庭实际用车场景与长期持有成本，理性对比不同车型的
        优劣势后再做决定。购车是大额支出，务必留足预算弹性空间，不要被销售话术
        带着节奏走。保险、上牌、装潢等落地费用都要提前算清楚，避免超预算。
        """
        XCTAssertFalse(LifeEventTaskPlanningEngine.looksLikeAIDecisionOutput(prose))
    }

    // MARK: - 谈价 / 上牌 / 交车执行分支

    func testCarNegotiationTaskGetsExecutionQuestions() {
        let questions = LifeEventTaskPlanningEngine.questions(for: "与销售确认价格与赠品", templateRaw: "买车")
        let ids = questions.map(\.id)
        XCTAssertTrue(ids.contains("price_target"))
        XCTAssertTrue(ids.contains("freebies"))
        XCTAssertTrue(ids.contains("registration_insurance"))
        XCTAssertTrue(ids.contains("delivery_check"))
    }

    func testCarRegistrationTaskGetsExecutionQuestions() {
        let questions = LifeEventTaskPlanningEngine.questions(for: "准备上牌材料与保险", templateRaw: "买车")
        let ids = questions.map(\.id)
        XCTAssertTrue(ids.contains("registration_insurance"))
    }

    // MARK: - 答案编解码

    func testAnswerEncodeDecodeRoundTrip() {
        let answers: [String: LifeEventTaskAnswer] = [
            "budget": LifeEventTaskAnswer(presets: ["20-25万"], note: "落地 22 万以内"),
            "purpose": LifeEventTaskAnswer(presets: [], note: "通勤带娃"),
            "empty": LifeEventTaskAnswer(presets: [], note: "   ")
        ]
        let json = LifeEventTaskPlanningEngine.encodeAnswers(answers)
        XCTAssertNotNil(json)
        let decoded = LifeEventTaskPlanningEngine.decodeAnswers(json)
        XCTAssertEqual(decoded["budget"], LifeEventTaskAnswer(presets: ["20-25万"], note: "落地 22 万以内"))
        XCTAssertEqual(decoded["purpose"]?.combined, "通勤带娃")
        // 空答案不落库
        XCTAssertNil(decoded["empty"])
    }

    func testEncodeEmptyAnswersReturnsNil() {
        XCTAssertNil(LifeEventTaskPlanningEngine.encodeAnswers([:]))
        XCTAssertNil(LifeEventTaskPlanningEngine.encodeAnswers(["a": LifeEventTaskAnswer()]))
    }

    func testDecodeCorruptedJSONReturnsEmpty() {
        XCTAssertTrue(LifeEventTaskPlanningEngine.decodeAnswers("not json").isEmpty)
        XCTAssertTrue(LifeEventTaskPlanningEngine.decodeAnswers(nil).isEmpty)
    }

    func testFilledCountCountsOnlyAnswered() {
        let questions = LifeEventTaskPlanningEngine.questions(for: "办理某某特定手续", templateRaw: "自定义人生大事")
        let answers = [
            "goal": LifeEventTaskAnswer(note: "明确目标"),
            "constraints": LifeEventTaskAnswer()
        ]
        XCTAssertEqual(LifeEventTaskPlanningEngine.filledCount(questions: questions, answers: answers), 1)
    }

    func testPromptAnswerMapUsesQuestionTitles() {
        let questions = LifeEventTaskPlanningEngine.questions(for: "明确购车预算与用途", templateRaw: "买车")
        let answers = ["budget": LifeEventTaskAnswer(presets: ["20-25万"], note: "首付 10 万")]
        let map = LifeEventTaskPlanningEngine.promptAnswerMap(questions: questions, answers: answers)
        XCTAssertEqual(map.count, 1)
        XCTAssertEqual(map["购车预算与支付形式"], "20-25万；首付 10 万")
    }

    // MARK: - 项目完整档案

    func testGenerateProjectArchiveContainsTasksAnswersAndFollowups() {
        let input = LifeEventProjectArchiveInput(
            projectTitle: "提车计划",
            templateName: "买车",
            targetDateText: "2027年4月26日",
            locationText: "杭州",
            budgetText: "25 万",
            tasks: [
                LifeEventArchiveTaskItem(
                    stageTitle: "确定需求与预算",
                    title: "明确购车预算与用途",
                    isDone: false,
                    ownerName: "我",
                    dueText: "3月1日",
                    answerLines: ["· 购车预算与支付形式：落地 22 万；首付 10 万"],
                    aiSummary: "优先增程 SUV"
                ),
                LifeEventArchiveTaskItem(stageTitle: "选车与试驾", title: "预约试驾体验", isDone: true)
            ],
            peopleLines: ["- 销售顾问小王：谈价对接"],
            expenseLines: ["- 车款：预算 220000"]
        )
        let text = LifeEventTaskPlanningEngine.generateProjectArchive(input)

        XCTAssertTrue(text.contains("提车计划"))
        XCTAssertTrue(text.contains("确定需求与预算"))
        XCTAssertTrue(text.contains("明确购车预算与用途"))
        XCTAssertTrue(text.contains("落地 22 万；首付 10 万"))
        XCTAssertTrue(text.contains("已有 AI 决策摘要：优先增程 SUV"))
        XCTAssertTrue(text.contains("- [x] 预约试驾体验"))
        XCTAssertTrue(text.contains("销售顾问小王"))
        XCTAssertTrue(text.contains("车款：预算 220000"))
        XCTAssertTrue(text.contains("3~6 条待办"))
    }

    func testGenerateProjectArchiveEmptyTasks() {
        let input = LifeEventProjectArchiveInput(
            projectTitle: "空项目",
            templateName: "自定义人生大事",
            targetDateText: "2027年1月1日"
        )
        let text = LifeEventTaskPlanningEngine.generateProjectArchive(input)
        XCTAssertTrue(text.contains("暂无任务记录"))
    }

    func testAnswerLinesSkipEmptyAnswers() {
        let questions = [
            LifeEventTaskQuestion(id: "a", title: "问题A", placeholder: ""),
            LifeEventTaskQuestion(id: "b", title: "问题B", placeholder: "")
        ]
        let answers = ["a": LifeEventTaskAnswer(note: "答了")]
        let lines = LifeEventTaskPlanningEngine.answerLines(questions: questions, answers: answers)
        XCTAssertEqual(lines, ["· 问题A：答了"])
    }
}
