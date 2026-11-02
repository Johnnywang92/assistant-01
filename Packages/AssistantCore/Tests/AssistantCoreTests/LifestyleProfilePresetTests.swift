import XCTest
@testable import AssistantCore

/// 人群建议值表的契约测试。
/// 这里不测「值好不好」（那是产品判断），只钉住四类会静默出事的事实：
/// 键名拼错、类型标签错、值落在设置页 Picker 的档位之外、以及把不该动的键动了。
final class LifestyleProfilePresetTests: XCTestCase {

    // MARK: - 三档的键集与取值（黄金表）

    func testOfficeWorkerPresetIsEmptyBecauseDefaultsAlreadyMatchIt() {
        XCTAssertEqual(LifestyleProfilePreset.entries(for: .officeWorker), [:],
                       "上班族档应当是空集：现有默认值本就按上班族设计，写任何键都是冗余覆盖")
    }

    func testStudentEntriesMatchApprovedTable() {
        XCTAssertEqual(LifestyleProfilePreset.entries(for: .student), [
            "day_timeline_wake_minutes": .int(390),
            "day_timeline_off_minutes": .int(1320),
            "weather_morning_push_time": .string("06:45"),
            "sleepReminder.windDownMinutes": .int(15),
            "sleepReminder.sleepGoalMinutes": .int(480)
        ])
    }

    func testFlexibleEntriesMatchApprovedTable() {
        XCTAssertEqual(LifestyleProfilePreset.entries(for: .flexible), [
            "day_timeline_wake_minutes": .int(510),
            "day_timeline_off_minutes": .int(1200),
            "weather_morning_push_time": .string("09:00"),
            "sleepReminder.windDownMinutes": .int(45),
            "safe_to_spend_rhythm_mode": .string(SpendingRhythmMode.flat.rawValue)
        ])
    }

    func testEveryProfileCaseHasAnEntryPath() {
        // 三档都要有结论（上班族是显式空集），且 allCases 与本表覆盖的身份一致
        XCTAssertEqual(Set(UserLifestyleProfile.allCases), [.officeWorker, .flexible, .student])
        for profile in UserLifestyleProfile.allCases {
            XCTAssertNoThrow(LifestyleProfilePreset.fields(for: profile))
        }
    }

    // MARK: - 键名纪律

    func testEveryPresetKeyIsRegisteredInBackupWhitelist() {
        let whitelisted = Set(AssistantSettingsKeys.allKeys)
        for field in LifestylePresetField.allCases {
            XCTAssertTrue(whitelisted.contains(field.rawValue),
                          "预设键 \(field.rawValue) 未登记进备份白名单，换机还原会丢这一项")
        }
    }

    func testEveryFieldIsActuallyUsedByAtLeastOneProfile() {
        let used = Set(UserLifestyleProfile.allCases.flatMap { LifestyleProfilePreset.fields(for: $0) })
        for field in LifestylePresetField.allCases {
            XCTAssertTrue(used.contains(field),
                          "\(field.rawValue) 没有任何一档会写它——要么接进表，要么删掉这个 case")
        }
    }

    /// 负向清单：这些键明确不进预设，理由见 `LifestyleProfilePreset` 的文档注释。
    /// 谁把它们加进表，这条测试会红，逼着提交人重新回答「用户能关回去吗」。
    func testForbiddenKeysNeverAppearInAnyProfile() {
        let forbidden: Set<String> = [
            "sleepReminder.desiredBedtime",        // 写死会永久取消 HealthKit 的 pseudo-desired 学习
            "sleepReminder.pseudoDesiredBedtime",  // 学习结果，不是偏好
            "sleepReminder.enabled",               // 总开关：预设无权替用户关掉一整个功能
            "user_off_work_minutes",               // 非上班族档在 UI 上看不到这个键
            "expense_monthly_budget",              // 金额是用户事实
            "expense_budget_start_day",            // 到账/结算日是用户事实
            "context_adaptive_sorting_enabled",    // 三档都该开着，写它没有信息量
            "weather_alerts_enabled",
            "periodic_report_daily_enabled",
            "periodic_report_weekly_enabled",
            "periodic_report_monthly_enabled",
            "periodic_report_quarterly_enabled",
            "periodic_report_yearly_enabled",
            "periodic_report_weekly_weekday",
            "periodic_report_daily_time_interval",
            "periodic_report_weekly_time_interval",
            "periodic_report_monthly_time_interval",
            "periodic_report_quarterly_time_interval",
            "periodic_report_yearly_time_interval"
        ]
        for profile in UserLifestyleProfile.allCases {
            let keys = Set(LifestyleProfilePreset.entries(for: profile).keys)
            XCTAssertTrue(keys.isDisjoint(with: forbidden),
                          "\(profile) 档动了不该动的键：\(keys.intersection(forbidden))")
        }
    }

    // MARK: - 类型标签纪律

    func testMinuteKeysCarryIntAndTimeKeysCarryString() {
        for profile in UserLifestyleProfile.allCases {
            let entries = LifestyleProfilePreset.entries(for: profile)
            for (key, value) in entries {
                switch key {
                case "day_timeline_wake_minutes", "day_timeline_off_minutes",
                     "sleepReminder.windDownMinutes", "sleepReminder.sleepGoalMinutes":
                    guard case .int = value else {
                        return XCTFail("\(key) 在代码里按 Int 分钟数读，预设却写了 \(value)——写进去会读不出来")
                    }
                case "weather_morning_push_time", "safe_to_spend_rhythm_mode":
                    guard case .string = value else {
                        return XCTFail("\(key) 是字符串键，预设写成了 \(value)")
                    }
                default:
                    continue
                }
            }
        }
    }

    // MARK: - 值域纪律

    func testSleepValuesFallInsideTheSettingsPickerDetents() {
        // 设置页的 Picker 只列这几档；预设值落在档位之外会让 Picker 显示不出当前值
        let windDownDetents: Set<Int> = [15, 30, 45]
        let goalDetents: Set<Int> = [360, 390, 420, 450, 480]
        for profile in UserLifestyleProfile.allCases {
            let entries = LifestyleProfilePreset.entries(for: profile)
            if case .int(let minutes)? = entries["sleepReminder.windDownMinutes"] {
                XCTAssertTrue(windDownDetents.contains(minutes), "睡前缓冲 \(minutes) 不在 Picker 档位里")
            }
            if case .int(let minutes)? = entries["sleepReminder.sleepGoalMinutes"] {
                XCTAssertTrue(goalDetents.contains(minutes), "睡眠目标 \(minutes) 不在 Picker 档位里")
            }
        }
    }

    func testTimelineAnchorsAreMinutesWithinOneDay() {
        for profile in UserLifestyleProfile.allCases {
            for key in ["day_timeline_wake_minutes", "day_timeline_off_minutes"] {
                guard case .int(let minutes)? = LifestyleProfilePreset.entries(for: profile)[key] else { continue }
                XCTAssertTrue((0..<1440).contains(minutes), "\(key) 的 \(minutes) 超出当天分钟数值域")
            }
        }
    }

    func testMorningPushTimeIsParseableHHmm() {
        for profile in UserLifestyleProfile.allCases {
            guard case .string(let text)? = LifestyleProfilePreset.entries(for: profile)["weather_morning_push_time"] else { continue }
            let parts = text.split(separator: ":").compactMap { Int($0) }
            XCTAssertEqual(parts.count, 2, "\(text) 不是 HH:mm")
            XCTAssertEqual(text.split(separator: ":").first?.count, 2, "\(text) 小时段没有补零，设置页回显会错位")
            XCTAssertTrue((0...23).contains(parts.first ?? -1))
            XCTAssertTrue((0...59).contains(parts.last ?? -1))
        }
    }

    func testSpendingRhythmValueIsARealModeCase() {
        for profile in UserLifestyleProfile.allCases {
            guard case .string(let raw)? = LifestyleProfilePreset.entries(for: profile)["safe_to_spend_rhythm_mode"] else { continue }
            let mode = SpendingRhythmMode(rawValue: raw)
            XCTAssertNotNil(mode, "安心花节奏写了注册表外的值 \(raw)")
            XCTAssertEqual(mode, .flat, "只有「作息不规律到不该把消费攒到周末」的档才该改这一项")
        }
        XCTAssertEqual(LifestyleProfilePreset.fields(for: .flexible).contains(.spendingRhythmMode), true)
        XCTAssertEqual(LifestyleProfilePreset.fields(for: .student).contains(.spendingRhythmMode), false)
    }

    // MARK: - 已持久化形态钉住

    /// rawValue 直接存在 UserDefaults 里，且 UI 文案与备份还原都读它。
    func testPersistedRawValuesArePinnedByteForByte() {
        XCTAssertEqual(UserLifestyleProfile.officeWorker.rawValue, "上班族 (周一至周五通勤)")
        XCTAssertEqual(UserLifestyleProfile.flexible.rawValue, "自由职业 / 弹性作息")
        XCTAssertEqual(UserLifestyleProfile.student.rawValue, "学生 (周中上课/周末假期)")
    }

    /// 语音向导用 `wizard_set:lifestyle:student` 这类 payload 回收选项，
    /// 匹配靠的是「枚举插值等于 case 名」；改成带关联值的枚举会静默失配。
    func testCaseNameInterpolationIsStableForWizardPayloads() {
        XCTAssertEqual("\(UserLifestyleProfile.officeWorker)", "officeWorker")
        XCTAssertEqual("\(UserLifestyleProfile.flexible)", "flexible")
        XCTAssertEqual("\(UserLifestyleProfile.student)", "student")
    }

    // MARK: - 展示顺序

    func testFieldsAreOrderedByAllCasesNotByDictionaryOrder() {
        XCTAssertEqual(LifestyleProfilePreset.fields(for: .student),
                       [.dayTimelineWake, .dayTimelineOff, .weatherMorningPushTime,
                        .sleepWindDownMinutes, .sleepGoalMinutes])
        XCTAssertEqual(LifestyleProfilePreset.fields(for: .flexible),
                       [.dayTimelineWake, .dayTimelineOff, .weatherMorningPushTime,
                        .sleepWindDownMinutes, .spendingRhythmMode])
    }
}
