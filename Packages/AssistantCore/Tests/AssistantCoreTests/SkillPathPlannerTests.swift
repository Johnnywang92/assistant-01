import XCTest
@testable import AssistantCore

final class SkillPathPlannerTests: XCTestCase {

    // MARK: - 类别识别

    func testDetectsProgrammingCategory() {
        XCTAssertEqual(SkillPathPlanner.detectCategory(in: "我想学 Python"), .programming)
        XCTAssertEqual(SkillPathPlanner.detectCategory(in: "怎么入门 Swift 开发"), .programming)
        XCTAssertEqual(SkillPathPlanner.detectCategory(in: "想学算法和数据结构"), .programming)
    }

    func testDetectsLanguageCategory() {
        XCTAssertEqual(SkillPathPlanner.detectCategory(in: "我想学英语口语"), .language)
        XCTAssertEqual(SkillPathPlanner.detectCategory(in: "零基础学日语"), .language)
        XCTAssertEqual(SkillPathPlanner.detectCategory(in: "准备雅思"), .language)
    }

    func testDetectsFitnessCategory() {
        XCTAssertEqual(SkillPathPlanner.detectCategory(in: "我想练马拉松"), .fitness)
        XCTAssertEqual(SkillPathPlanner.detectCategory(in: "零基础健身增肌"), .fitness)
        XCTAssertEqual(SkillPathPlanner.detectCategory(in: "学会游泳"), .fitness)
    }

    func testNonSkillQueryIsNotLearning() {
        XCTAssertNil(SkillPathPlanner.detectCategory(in: "帮我规划一下周末露营"))
        XCTAssertFalse(SkillPathPlanner.isLearningQuery("帮我规划一下周末露营"))
        XCTAssertFalse(SkillPathPlanner.isLearningQuery(""))
    }

    func testLearningIntentRequiresCategory() {
        XCTAssertTrue(SkillPathPlanner.isLearningQuery("我想学 Python"))
        XCTAssertFalse(SkillPathPlanner.isLearningQuery("我想学怎么把家里收拾干净"))
    }

    // MARK: - 技能名提取

    func testExtractsSkillName() {
        XCTAssertEqual(
            SkillPathPlanner.extractSkillName(from: "我想学Python", category: .programming),
            "Python"
        )
        XCTAssertEqual(
            SkillPathPlanner.extractSkillName(from: "学会英语", category: .language),
            "英语"
        )
        XCTAssertEqual(
            SkillPathPlanner.extractSkillName(from: "我想练会引体向上", category: .fitness),
            "引体向上"
        )
    }

    func testSkillNameDropsCommitmentPhrase() {
        let name = SkillPathPlanner.extractSkillName(from: "我想学Python，每天半小时", category: .programming)
        XCTAssertEqual(name, "Python")
    }

    func testFallsBackToDefaultName() {
        XCTAssertEqual(
            SkillPathPlanner.extractSkillName(from: "学", category: .programming),
            "编程"
        )
    }

    // MARK: - 投入与周期解析

    func testParsesDailyMinutes() {
        let result = SkillPathPlanner.parseCommitment(in: "我想学英语，每天半小时")
        XCTAssertEqual(result.weeklyMinutes, 210)
    }

    func testParsesDailyNumericMinutes() {
        let result = SkillPathPlanner.parseCommitment(in: "学吉他，每天20分钟")
        XCTAssertEqual(result.weeklyMinutes, 140)
    }

    func testParsesWeeklyHours() {
        let result = SkillPathPlanner.parseCommitment(in: "学编程，每周5小时")
        XCTAssertEqual(result.weeklyMinutes, 300)
    }

    func testParsesPeriodInMonths() {
        let result = SkillPathPlanner.parseCommitment(in: "3个月学会Python")
        XCTAssertEqual(result.totalWeeks, 13)
    }

    func testParsesPeriodInWeeks() {
        let result = SkillPathPlanner.parseCommitment(in: "12周内学会英语")
        XCTAssertEqual(result.totalWeeks, 12)
    }

    func testDefaultsWhenNothingSpecified() {
        let result = SkillPathPlanner.parseCommitment(in: "我想学Python")
        XCTAssertEqual(result.weeklyMinutes, SkillPathPlanner.defaultWeeklyMinutes)
        XCTAssertEqual(result.totalWeeks, SkillPathPlanner.defaultWeeks)
    }

    // MARK: - 拆解结果

    func testBuildsFourStages() {
        let draft = SkillPathPlanner.build(
            skillName: "Python",
            category: .programming,
            weeklyMinutes: 210,
            weeks: 12
        )
        XCTAssertEqual(draft.stages.count, 4)
        XCTAssertEqual(draft.stages.map(\.index), [0, 1, 2, 3])
        XCTAssertEqual(draft.title, "学Python")
        XCTAssertFalse(draft.goal.isEmpty)
    }

    func testStageDaysSumToTotal() {
        let draft = SkillPathPlanner.build(skillName: "英语", category: .language, weeklyMinutes: 150, weeks: 12)
        let sum = draft.stages.reduce(0) { $0 + $1.plannedDays }
        XCTAssertEqual(sum, draft.totalDays)
    }

    func testEachStageHasOnePracticeAndSeveralMilestones() {
        let draft = SkillPathPlanner.build(skillName: "健身", category: .fitness, weeklyMinutes: 150, weeks: 8)
        for stage in draft.stages {
            XCTAssertEqual(stage.practices.count, 1, "\(stage.name) 应只有一条练习打卡")
            XCTAssertGreaterThanOrEqual(stage.milestones.count, 3)
            XCTAssertFalse(stage.acceptance.isEmpty)
        }
    }

    func testPracticeFrequencyDependsOnWeeklyLoad() {
        let light = SkillPathPlanner.build(skillName: "Python", category: .programming, weeklyMinutes: 140, weeks: 12)
        XCTAssertEqual(light.stages[0].practices.first?.recurrenceDays, 1)

        let heavy = SkillPathPlanner.build(skillName: "Python", category: .programming, weeklyMinutes: 420, weeks: 12)
        XCTAssertEqual(heavy.stages[0].practices.first?.recurrenceDays, 2)
        XCTAssertGreaterThanOrEqual(heavy.stages[0].practices.first?.minutes ?? 0, 20)
    }

    func testMilestoneDeadlinesIncreaseAcrossStages() {
        let draft = SkillPathPlanner.build(skillName: "日语", category: .language, weeklyMinutes: 150, weeks: 12)
        var previous = -1
        for stage in draft.stages {
            let maxOffset = stage.milestones.map(\.dayOffset).max() ?? 0
            XCTAssertGreaterThan(maxOffset, previous)
            previous = maxOffset
        }
        XCTAssertLessThanOrEqual(previous, draft.totalDays)
    }

    func testShortPathStillValid() {
        let draft = SkillPathPlanner.build(skillName: "英语", category: .language, weeklyMinutes: 30, weeks: 2)
        XCTAssertEqual(draft.stages.count, 4)
        XCTAssertTrue(draft.stages.allSatisfy { $0.plannedDays >= 3 })
        XCTAssertTrue(draft.stages.allSatisfy { !$0.tasks.isEmpty })
    }

    func testExtremeInputIsClamped() {
        let draft = SkillPathPlanner.build(skillName: "Python", category: .programming, weeklyMinutes: 99999, weeks: 999)
        XCTAssertLessThanOrEqual(draft.weeklyMinutes, 1200)
        XCTAssertLessThanOrEqual(draft.totalWeeks, 104)
    }

    func testBuildFromQuery() {
        let draft = SkillPathPlanner.build(query: "我想学英语口语，每天半小时，3个月")
        XCTAssertNotNil(draft)
        XCTAssertEqual(draft?.category, .language)
        XCTAssertEqual(draft?.weeklyMinutes, 210)
        XCTAssertEqual(draft?.totalWeeks, 13)
        XCTAssertFalse(draft?.summaryText.isEmpty ?? true)
    }

    func testGoalIsObservableNotVague() {
        let draft = SkillPathPlanner.build(skillName: "Python", category: .programming, weeklyMinutes: 150, weeks: 12)
        XCTAssertTrue(draft.goal.contains("独立"))
        XCTAssertFalse(draft.goal.contains("学会Python"))
    }
}
