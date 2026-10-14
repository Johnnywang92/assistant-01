import XCTest
@testable import AssistantCore

/// 重复待办「完成后生成下一期」的回归测试。
/// 核心风险：markAsCompleted 复制母记录字段的历史清单曾漏掉技能路径四项
/// （打卡后新待办脱离学习路径），未来新增字段也可能再次静默漏复制。
final class RecurrencePlanTests: XCTestCase {

    private let day: TimeInterval = 86_400

    /// 固定 UTC 公历：date(byAdding: .day) 在此日历下精确等于 +86400 秒，断言可写绝对时刻。
    private var utcCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    /// 2026-06-01 12:00:00 UTC（固定参考时刻）
    private let reference = Date(timeIntervalSince1970: 1_780_315_200)

    private func makeRecord(
        statusRaw: String = "active",
        title: String = "晨跑",
        detail: String? = "公园",
        pickupCode: String? = nil,
        courier: String? = nil,
        station: String? = nil,
        location: String? = nil,
        dueAt: Date?,
        sourceText: String? = nil,
        sortOrder: Int = 0,
        recurrenceRuleRaw: String?,
        recurrenceIntervalDays: Int = 0,
        remindBeforeMinutes: Int = 0,
        skillPathID: UUID? = nil,
        skillStageIndex: Int = 0,
        isSkillPractice: Bool = false,
        skillPracticeMinutes: Int = 0
    ) -> RecurringTodoRecord {
        RecurringTodoRecord(
            typeRaw: "general",
            statusRaw: statusRaw,
            title: title,
            detail: detail,
            pickupCode: pickupCode,
            courier: courier,
            station: station,
            location: location,
            dueAt: dueAt,
            sourceText: sourceText,
            sortOrder: sortOrder,
            recurrenceRuleRaw: recurrenceRuleRaw,
            recurrenceIntervalDays: recurrenceIntervalDays,
            remindBeforeMinutes: remindBeforeMinutes,
            skillPathID: skillPathID,
            skillStageIndex: skillStageIndex,
            isSkillPractice: isSkillPractice,
            skillPracticeMinutes: skillPracticeMinutes
        )
    }

    private func nextFields(from parent: RecurringTodoRecord) -> NextOccurrenceFields? {
        RecurrencePlan.nextFields(from: parent, referenceDate: reference, calendar: utcCalendar)
    }

    // MARK: - 周期滚动

    /// 普通周期滚动：母记录截止时间在过去若干周期时，逐周期追赶到参考时刻之后。
    func testDailyCatchesUpWhenParentDueLongPast() throws {
        let due = reference - 5 * day
        let fields = try XCTUnwrap(nextFields(from: makeRecord(
            dueAt: due, recurrenceRuleRaw: TodoRecurrenceRule.daily.rawValue)))
        // due+5 天恰好等于参考时刻（不「晚于」），须再前进一个周期
        XCTAssertEqual(fields.dueAt, due + 6 * day)
    }

    func testDailyRollsFromFutureParentDueDate() throws {
        let due = reference + 3 * 3600
        let fields = try XCTUnwrap(nextFields(from: makeRecord(
            dueAt: due, recurrenceRuleRaw: TodoRecurrenceRule.daily.rawValue)))
        XCTAssertEqual(fields.dueAt, due + day)
    }

    func testWeeklyIntervalIsSevenDays() throws {
        let due = reference - day
        let fields = try XCTUnwrap(nextFields(from: makeRecord(
            dueAt: due, recurrenceRuleRaw: TodoRecurrenceRule.weekly.rawValue)))
        XCTAssertEqual(fields.dueAt, due + 7 * day)
    }

    func testCustomIntervalUsesIntervalDays() throws {
        let due = reference - 3 * day
        let fields = try XCTUnwrap(nextFields(from: makeRecord(
            dueAt: due,
            recurrenceRuleRaw: TodoRecurrenceRule.custom.rawValue,
            recurrenceIntervalDays: 10)))
        XCTAssertEqual(fields.dueAt, due + 10 * day)
    }

    /// 自定义间隔漏填天数（0 或负数）时按 1 天滚动，不能停摆。
    func testCustomIntervalClampsNonPositiveDaysToOne() throws {
        let due = reference - 2 * day
        for badDays in [0, -7] {
            let fields = try XCTUnwrap(nextFields(from: makeRecord(
                dueAt: due,
                recurrenceRuleRaw: TodoRecurrenceRule.custom.rawValue,
                recurrenceIntervalDays: badDays)))
            XCTAssertEqual(fields.dueAt, reference + day)
        }
    }

    /// 母记录无 dueAt：从参考时刻起加一个周期。
    func testParentWithoutDueAtRollsFromReference() throws {
        let fields = try XCTUnwrap(nextFields(from: makeRecord(
            dueAt: nil, recurrenceRuleRaw: TodoRecurrenceRule.weekly.rawValue)))
        XCTAssertEqual(fields.dueAt, reference + 7 * day)
    }

    func testNoneRuleProducesNoNextOccurrence() {
        for raw in [nil, TodoRecurrenceRule.none.rawValue, "不存在的规则"] {
            XCTAssertNil(nextFields(from: makeRecord(dueAt: reference + day, recurrenceRuleRaw: raw)),
                         "规则原始值 \(String(describing: raw)) 不应生成下一期")
        }
    }

    func testRuleParsingMatchesItemGetter() {
        XCTAssertEqual(RecurrencePlan.rule(fromRaw: nil), .none)
        XCTAssertEqual(RecurrencePlan.rule(fromRaw: "每天"), .daily)
        XCTAssertEqual(RecurrencePlan.rule(fromRaw: "乱写"), .none)
    }

    func testNextDueDateForNonRecurringReturnsReference() {
        XCTAssertEqual(
            RecurrencePlan.nextDueDate(dueAt: reference + 100 * day, rule: .none,
                                       customDays: 0, referenceDate: reference, calendar: utcCalendar),
            reference)
    }

    // MARK: - 字段复制

    /// 已完成（甚至带 done 状态）的母记录，下一期必须回到活跃状态。
    func testCompletedParentProducesActiveNext() throws {
        let fields = try XCTUnwrap(nextFields(from: makeRecord(
            statusRaw: "done",
            dueAt: reference + 3600,
            recurrenceRuleRaw: TodoRecurrenceRule.daily.rawValue)))
        XCTAssertEqual(fields.statusRaw, "active")
        XCTAssertEqual(fields.statusRaw, RecurrencePlan.activeStatusRaw)
    }

    func testDescriptiveFieldsCarriedOver() throws {
        let fields = try XCTUnwrap(nextFields(from: makeRecord(
            title: "取快递",
            detail: "驿站",
            pickupCode: "8-3-2046",
            courier: "顺丰",
            station: "菜鸟驿站",
            location: "小区北门",
            dueAt: reference + 2 * day,
            sourceText: "原文短信",
            sortOrder: -3,
            recurrenceRuleRaw: TodoRecurrenceRule.biweekly.rawValue,
            remindBeforeMinutes: 15)))
        XCTAssertEqual(fields.typeRaw, "general")
        XCTAssertEqual(fields.title, "取快递")
        XCTAssertEqual(fields.detail, "驿站")
        XCTAssertEqual(fields.pickupCode, "8-3-2046")
        XCTAssertEqual(fields.courier, "顺丰")
        XCTAssertEqual(fields.station, "菜鸟驿站")
        XCTAssertEqual(fields.location, "小区北门")
        XCTAssertEqual(fields.sourceText, "原文短信")
        XCTAssertEqual(fields.sortOrder, -3)
        XCTAssertEqual(fields.recurrenceRuleRaw, TodoRecurrenceRule.biweekly.rawValue)
        XCTAssertEqual(fields.remindBeforeMinutes, 15)
    }

    /// 事故回归：技能路径关联必须随下一期复制，否则打卡一次后脱离学习路径。
    func testSkillPathAssociationCarriedToNextOccurrence() throws {
        let pathID = UUID()
        let fields = try XCTUnwrap(nextFields(from: makeRecord(
            dueAt: reference + 3600,
            recurrenceRuleRaw: TodoRecurrenceRule.daily.rawValue,
            skillPathID: pathID,
            skillStageIndex: 2,
            isSkillPractice: true,
            skillPracticeMinutes: 45)))
        XCTAssertEqual(fields.skillPathID, pathID)
        XCTAssertEqual(fields.skillStageIndex, 2)
        XCTAssertEqual(fields.isSkillPractice, true)
        XCTAssertEqual(fields.skillPracticeMinutes, 45)
    }

    // MARK: - 字段完整性纪律

    /// 纪律测试（同 SettingsSnapshot 白名单先例）：
    /// 1) 待复制字段集合必须非空且逐项落在显式清单内；
    /// 2) 技能路径四项永远在清单里（历史事故点）；
    /// 3) 母记录快照（RecurringTodoRecord）的每个属性都必须出现在输出
    ///    （NextOccurrenceFields）里——给快照加了字段却忘了往下传，这条测试立即失败。
    func testNextFieldsCopyWholeParentRecordManifest() throws {
        let record = makeRecord(dueAt: reference + day, recurrenceRuleRaw: TodoRecurrenceRule.daily.rawValue)
        let fields = try XCTUnwrap(RecurrencePlan.nextFields(from: record, referenceDate: reference, calendar: utcCalendar))
        let recordNames = Set(Swift.Mirror(reflecting: record).children.compactMap { $0.label })
        let outputNames = Set(Swift.Mirror(reflecting: fields).children.compactMap { $0.label })

        XCTAssertFalse(recordNames.isEmpty, "待复制字段集合不应为空")
        XCTAssertEqual(recordNames.count, 18, "母记录快照应有 18 个字段；新增字段请同时更新显式清单与本断言")

        let skillManifest: Set<String> = ["skillPathID", "skillStageIndex", "isSkillPractice", "skillPracticeMinutes"]
        XCTAssertTrue(skillManifest.isSubset(of: recordNames), "母记录必须携带技能路径四项: \(recordNames)")
        XCTAssertTrue(skillManifest.isSubset(of: outputNames), "下一期输出必须携带技能路径四项: \(outputNames)")

        let explicitManifest: Set<String> = [
            "typeRaw", "statusRaw", "title", "detail", "pickupCode", "courier", "station", "location",
            "dueAt", "sourceText", "sortOrder", "recurrenceRuleRaw", "recurrenceIntervalDays",
            "remindBeforeMinutes", "skillPathID", "skillStageIndex", "isSkillPractice", "skillPracticeMinutes"
        ]
        XCTAssertEqual(recordNames, explicitManifest, "待复制字段清单发生变化，请确认 app 侧 TodoItem 与输出结构同步更新")
        XCTAssertTrue(recordNames.isSubset(of: outputNames),
                      "输出缺少母记录携带的字段: \(recordNames.subtracting(outputNames))")
    }
}
