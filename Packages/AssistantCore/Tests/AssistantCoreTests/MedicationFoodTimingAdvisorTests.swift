import XCTest
@testable import AssistantCore

final class MedicationFoodTimingAdvisorTests: XCTestCase {

    func testPostMealPrimeTimeWindow() {
        // 场景：布洛芬（饭后30分钟），12:15 午餐 → 最佳 12:45，现在 12:50（已进入黄金窗口）
        let calendar = Calendar.current
        let today = Date()
        let mealTime = calendar.date(bySettingHour: 12, minute: 15, second: 0, of: today)!
        let now = calendar.date(bySettingHour: 12, minute: 50, second: 0, of: today)!

        let plan = MedicationPlanSnapshot(
            medName: "布洛芬缓释胶囊",
            dosage: "1粒",
            mealRelation: .afterMeal(minutes: 30),
            dailyTimePoints: ["13:00"]
        )

        let meals = [
            RecentMealSnapshot(date: mealTime, foodName: "红烧牛肉面", calories: 650)
        ]

        let eval = MedicationFoodTimingAdvisor.evaluate(plan: plan, todayMeals: meals, now: now)

        if case .primeTimePostMeal(let recTime, let windowEnd, let mealName) = eval.status {
            XCTAssertEqual(mealName, "红烧牛肉面")
            XCTAssertTrue(windowEnd > recTime)
            XCTAssertTrue(eval.headline.contains("餐后黄金用药窗口"))
            XCTAssertTrue(eval.actionTip.contains("保护胃黏膜"))
        } else {
            XCTFail("应当命中餐后黄金用药窗口，实际状态为：\(eval.status)")
        }
    }

    /// 回归（CORE-04）：刚吃完还没到「饭后 N 分钟」时，必须先提示等待，
    /// 不能直接说「黄金窗口、建议现在服用」。
    func testPostMealWaitsUntilBestTime() {
        let calendar = Calendar.current
        let today = Date()
        let mealTime = calendar.date(bySettingHour: 12, minute: 15, second: 0, of: today)!
        let now = calendar.date(bySettingHour: 12, minute: 35, second: 0, of: today)!
        let plan = MedicationPlanSnapshot(
            medName: "布洛芬缓释胶囊",
            dosage: "1粒",
            mealRelation: .afterMeal(minutes: 30),
            dailyTimePoints: ["13:00"]
        )
        let meals = [RecentMealSnapshot(date: mealTime, foodName: "红烧牛肉面", calories: 650)]

        let eval = MedicationFoodTimingAdvisor.evaluate(plan: plan, todayMeals: meals, now: now)

        if case .primeTimePostMeal(let recTime, _, _) = eval.status {
            // 最佳时点 = 餐后 30 分钟 = 12:45
            XCTAssertEqual(recTime, calendar.date(bySettingHour: 12, minute: 45, second: 0, of: today)!)
            XCTAssertTrue(eval.headline.contains("等待最佳饭后时机"), "实际文案：\(eval.headline)")
            XCTAssertFalse(eval.isUrgent)
            // 调度时间必须与文案一致（旧实现调度 12:25、文案却说「现在服用」）
            XCTAssertEqual(eval.adaptiveNotificationTime, recTime)
        } else {
            XCTFail("刚吃完饭应先提示等待，实际状态：\(eval.status)")
        }
    }

    /// 回归（CORE-04）：饭前服药计划遇到「刚进食」要提示冲突，不能让人空腹服药。
    func testBeforeMealConflictsWithRecentMeal() {
        let calendar = Calendar.current
        let today = Date()
        let mealTime = calendar.date(bySettingHour: 11, minute: 55, second: 0, of: today)!
        // 计划 12:30 饭前服、提前 30 分钟 → 12:00 进入窗口
        let now = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: today)!
        let plan = MedicationPlanSnapshot(
            medName: "奥美拉唑肠溶胶囊",
            dosage: "20mg",
            mealRelation: .beforeMeal(minutes: 30),
            dailyTimePoints: ["12:30"]
        )
        let meals = [RecentMealSnapshot(date: mealTime, foodName: "牛肉面", calories: 600)]

        let eval = MedicationFoodTimingAdvisor.evaluate(plan: plan, todayMeals: meals, now: now)

        if case .waitingForMeal(_, let reason) = eval.status {
            XCTAssertTrue(reason.contains("进餐"), "实际原因：\(reason)")
            XCTAssertTrue(eval.headline.contains("冲突"), "实际文案：\(eval.headline)")
            XCTAssertFalse(eval.actionTip.contains("请空腹温水送服"), "刚进食不应建议空腹服药")
        } else {
            XCTFail("饭前计划遇到刚进食应提示冲突，实际状态：\(eval.status)")
        }
    }

    func testWaitingForMealWhenFasting() {
        // 场景：饭后服用药，计划时间是 12:30，现在 12:40，但过去3小时没有任何用餐记录
        let calendar = Calendar.current
        let today = Date()
        let now = calendar.date(bySettingHour: 12, minute: 40, second: 0, of: today)!

        let plan = MedicationPlanSnapshot(
            medName: "阿司匹林肠溶片",
            dosage: "100mg",
            mealRelation: .afterMeal(minutes: 30),
            dailyTimePoints: ["12:30"]
        )

        let eval = MedicationFoodTimingAdvisor.evaluate(plan: plan, todayMeals: [], now: now)

        if case .waitingForMeal(_, let reason) = eval.status {
            XCTAssertTrue(reason.contains("未检测到进餐"))
            XCTAssertTrue(eval.headline.contains("等餐顺延"))
        } else {
            XCTFail("空腹时应顺延等餐，实际状态为：\(eval.status)")
        }
    }

    func testBeforeMealWindow() {
        // 场景：奥美拉唑肠溶胶囊（饭前半小时），计划 07:30 服用，现在 07:15
        let calendar = Calendar.current
        let today = Date()
        let now = calendar.date(bySettingHour: 7, minute: 15, second: 0, of: today)!

        let plan = MedicationPlanSnapshot(
            medName: "奥美拉唑肠溶胶囊",
            dosage: "20mg",
            mealRelation: .beforeMeal(minutes: 30),
            dailyTimePoints: ["07:30"]
        )

        let eval = MedicationFoodTimingAdvisor.evaluate(plan: plan, todayMeals: [], now: now)

        if case .primeTimeBeforeMeal = eval.status {
            XCTAssertTrue(eval.headline.contains("饭前最佳"))
            XCTAssertTrue(eval.actionTip.contains("空腹温水送服"))
        } else {
            XCTFail("应为饭前最佳窗口，实际为：\(eval.status)")
        }
    }

    func testGrapefruitConflictWithStatin() {
        // 场景：阿托伐他汀钙片，用户 30 分钟前喝了西柚汁
        let now = Date()
        let grapefruitTime = now.addingTimeInterval(-30 * 60)

        let plan = MedicationPlanSnapshot(
            medName: "阿托伐他汀钙片",
            dosage: "20mg",
            mealRelation: .bedtime,
            dailyTimePoints: ["21:30"]
        )

        let meals = [
            RecentMealSnapshot(date: grapefruitTime, foodName: "西柚暴柠茶", hasGrapefruit: true)
        ]

        let eval = MedicationFoodTimingAdvisor.evaluate(plan: plan, todayMeals: meals, now: now)

        XCTAssertTrue(eval.isUrgent)
        if case .conflictAlert(let type, let detail, _) = eval.status {
            XCTAssertEqual(type, .grapefruit)
            XCTAssertTrue(detail.contains("CYP3A4"))
        } else {
            XCTFail("应当触发西柚冲突警告，实际为：\(eval.status)")
        }
    }

    func testCaffeineConflictWithSedative() {
        // 场景：安神补脑液，用户 20 分钟前喝了大杯冰美式咖啡
        let now = Date()
        let coffeeTime = now.addingTimeInterval(-20 * 60)

        let plan = MedicationPlanSnapshot(
            medName: "安神补脑液",
            dosage: "1支",
            mealRelation: .bedtime,
            dailyTimePoints: ["22:00"]
        )

        let meals = [
            RecentMealSnapshot(date: coffeeTime, foodName: "美式咖啡", hasCaffeine: true)
        ]

        let eval = MedicationFoodTimingAdvisor.evaluate(plan: plan, todayMeals: meals, now: now)

        if case .conflictAlert(let type, _, _) = eval.status {
            XCTAssertEqual(type, .caffeine)
            XCTAssertTrue(eval.actionTip.contains("咖啡因"))
        } else {
            XCTFail("应当触发咖啡因冲突警告，实际为：\(eval.status)")
        }
    }

    func testMissedDoseRuleEnforcesNoDoubling() {
        // 场景：每日2次（间隔约12小时，半间隔6小时），原定08:00，现在15:30（超时 7.5 小时）
        let calendar = Calendar.current
        let today = Date()
        let now = calendar.date(bySettingHour: 15, minute: 30, second: 0, of: today)!

        let plan = MedicationPlanSnapshot(
            medName: "二甲双胍片",
            dosage: "0.5g",
            mealRelation: .afterMeal(minutes: 15),
            dailyTimePoints: ["08:00", "20:00"]
        )

        let eval = MedicationFoodTimingAdvisor.evaluate(plan: plan, todayMeals: [], now: now)

        if case .missedDoseWarning(_, let advice, let canCatchUp) = eval.status {
            XCTAssertFalse(canCatchUp)
            XCTAssertTrue(advice.contains("切勿在下一次服药时服用双倍剂量"))
            XCTAssertTrue(advice.contains("跳过本次"))
        } else {
            XCTFail("超时超过半间隔应当严禁加倍服用并提示跳过，实际为：\(eval.status)")
        }
    }

    func testTakenTodayStatus() {
        let now = Date()
        let plan = MedicationPlanSnapshot(
            medName: "多维元素片",
            dosage: "1片",
            mealRelation: .afterMeal(minutes: 30),
            dailyTimePoints: ["08:00"],
            lastTakenAt: now.addingTimeInterval(-30 * 60) // 半小时前打卡
        )

        let eval = MedicationFoodTimingAdvisor.evaluate(plan: plan, todayMeals: [], now: now)

        if case .takenToday = eval.status {
            XCTAssertTrue(eval.headline.contains("已按时打卡"))
        } else {
            XCTFail("已打卡应当显示 takenToday，实际为：\(eval.status)")
        }
    }
}
