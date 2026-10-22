import XCTest
@testable import AssistantCore

final class DietaryPreferenceTests: XCTestCase {

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        return cal
    }

    private func makeDate(hour: Int, dayOffset: Int = 0) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 10
        components.day = 20 + dayOffset
        components.hour = hour
        components.minute = 15
        return calendar.date(from: components)!
    }

    func testEmptyRecordsProducesSafeProfile() {
        let (profile, recommendations) = DietaryPreferenceAnalyzer.analyze(records: [])
        XCTAssertEqual(profile.sampleCount, 0)
        XCTAssertEqual(profile.beverage.style, .balanced)
        XCTAssertEqual(profile.staple.style, .balanced)
        XCTAssertFalse(recommendations.isEmpty)
    }

    func testCoffeeLoverPreferenceRecognition() {
        let records: [FoodIntakeItemSummary] = [
            FoodIntakeItemSummary(date: makeDate(hour: 9, dayOffset: 1), foodID: "coffee", foodName: "黑咖啡/美式", category: .drink, calories: 5),
            FoodIntakeItemSummary(date: makeDate(hour: 14, dayOffset: 1), foodID: "latte", foodName: "拿铁/卡布奇诺", category: .drink, calories: 140),
            FoodIntakeItemSummary(date: makeDate(hour: 9, dayOffset: 2), foodID: "coffee", foodName: "黑咖啡/美式", category: .drink, calories: 5),
            FoodIntakeItemSummary(date: makeDate(hour: 12, dayOffset: 1), foodID: "rice", foodName: "米饭", category: .staple, calories: 230)
        ]

        let (profile, _) = DietaryPreferenceAnalyzer.analyze(records: records, calendar: calendar)
        XCTAssertEqual(profile.beverage.style, .coffeeLover)
        XCTAssertEqual(profile.beverage.coffeeCount, 3)
        XCTAssertTrue(profile.tags.contains(where: { $0.contains("咖啡") }))
        XCTAssertTrue(profile.beverage.topBeverages.contains("黑咖啡/美式"))
    }

    func testMilkTeaFanPreferenceRecognition() {
        let records: [FoodIntakeItemSummary] = [
            FoodIntakeItemSummary(date: makeDate(hour: 15, dayOffset: 1), foodID: "milk_tea", foodName: "珍珠奶茶", category: .drink, calories: 350),
            FoodIntakeItemSummary(date: makeDate(hour: 16, dayOffset: 2), foodID: "milk_tea", foodName: "霸王茶姬伯牙绝弦", category: .drink, calories: 240),
            FoodIntakeItemSummary(date: makeDate(hour: 15, dayOffset: 3), foodID: "milk_tea", foodName: "喜茶多肉葡萄", category: .drink, calories: 280),
            FoodIntakeItemSummary(date: makeDate(hour: 12, dayOffset: 1), foodID: "rice", foodName: "米饭", category: .staple, calories: 230)
        ]

        let (profile, _) = DietaryPreferenceAnalyzer.analyze(records: records, calendar: calendar)
        XCTAssertEqual(profile.beverage.style, .milkTeaFan)
        XCTAssertTrue(profile.tags.contains(where: { $0.contains("奶茶") }))
        XCTAssertTrue(profile.snack.hasAfternoonTeaHabit)
    }

    func testNoodleLoverPreferenceRecognition() {
        let records: [FoodIntakeItemSummary] = [
            FoodIntakeItemSummary(date: makeDate(hour: 12, dayOffset: 1), foodID: "noodles", foodName: "兰州拉面", category: .staple, calories: 330),
            FoodIntakeItemSummary(date: makeDate(hour: 18, dayOffset: 1), foodID: "rice_noodles", foodName: "柳州螺蛳粉", category: .staple, calories: 420),
            FoodIntakeItemSummary(date: makeDate(hour: 12, dayOffset: 2), foodID: "zhajiangmian", foodName: "老北京炸酱面", category: .staple, calories: 400),
            FoodIntakeItemSummary(date: makeDate(hour: 18, dayOffset: 2), foodID: "rice", foodName: "米饭", category: .staple, calories: 230)
        ]

        let (profile, _) = DietaryPreferenceAnalyzer.analyze(records: records, calendar: calendar)
        XCTAssertEqual(profile.staple.style, .noodleLover)
        XCTAssertEqual(profile.staple.noodleCount, 3)
        XCTAssertEqual(profile.staple.riceCount, 1)
        XCTAssertTrue(profile.tags.contains(where: { $0.contains("面条") || $0.contains("面食") }))
    }

    func testRiceLoverPreferenceRecognition() {
        let records: [FoodIntakeItemSummary] = [
            FoodIntakeItemSummary(date: makeDate(hour: 12, dayOffset: 1), foodID: "rice", foodName: "米饭", category: .staple, calories: 230),
            FoodIntakeItemSummary(date: makeDate(hour: 18, dayOffset: 1), foodID: "rice", foodName: "米饭", category: .staple, calories: 230),
            FoodIntakeItemSummary(date: makeDate(hour: 12, dayOffset: 2), foodID: "fried_rice", foodName: "扬州炒饭", category: .staple, calories: 450),
            FoodIntakeItemSummary(date: makeDate(hour: 18, dayOffset: 2), foodID: "noodles", foodName: "牛肉面", category: .staple, calories: 330)
        ]

        let (profile, _) = DietaryPreferenceAnalyzer.analyze(records: records, calendar: calendar)
        XCTAssertEqual(profile.staple.style, .riceLover)
        XCTAssertGreaterThan(profile.staple.riceRatio, 0.6)
    }

    func testSnackAndLateNightDetection() {
        let records: [FoodIntakeItemSummary] = [
            FoodIntakeItemSummary(date: makeDate(hour: 22, dayOffset: 1), foodID: "barbecue", foodName: "烤串", category: .snack, calories: 400),
            FoodIntakeItemSummary(date: makeDate(hour: 23, dayOffset: 2), foodID: "chips", foodName: "薯片", category: .dessert, calories: 250),
            FoodIntakeItemSummary(date: makeDate(hour: 15, dayOffset: 1), foodID: "cake", foodName: "蛋糕", category: .dessert, calories: 350),
            FoodIntakeItemSummary(date: makeDate(hour: 15, dayOffset: 2), foodID: "cookie", foodName: "饼干", category: .dessert, calories: 150)
        ]

        let (profile, _) = DietaryPreferenceAnalyzer.analyze(records: records, calendar: calendar)
        XCTAssertTrue(profile.snack.hasLateNightHabit)
        XCTAssertTrue(profile.snack.hasAfternoonTeaHabit)
        XCTAssertTrue(profile.tags.contains(where: { $0.contains("夜猫子") || $0.contains("下午茶") }))
    }

    func testAfternoonTeaRecommendsHealthyAlternativeWhenCoffeeHadAlready() {
        let coffeeHistory = [
            FoodIntakeItemSummary(date: makeDate(hour: 9, dayOffset: -1), foodID: "coffee", foodName: "黑咖啡", category: .drink, calories: 5),
            FoodIntakeItemSummary(date: makeDate(hour: 9, dayOffset: -2), foodID: "latte", foodName: "拿铁", category: .drink, calories: 140)
        ]
        // Today user already drank coffee in morning
        let todayRecords = [
            FoodIntakeItemSummary(date: makeDate(hour: 9, dayOffset: 0), foodID: "coffee", foodName: "美式咖啡", category: .drink, calories: 5)
        ]

        let nowAfternoon = makeDate(hour: 15, dayOffset: 0)
        let (_, recommendations) = DietaryPreferenceAnalyzer.analyze(
            records: coffeeHistory,
            now: nowAfternoon,
            todayRecords: todayRecords,
            calendar: calendar
        )

        XCTAssertFalse(recommendations.isEmpty)
        let afternoonRec = recommendations.first { $0.slot == .afternoonTea }
        XCTAssertNotNil(afternoonRec)
        XCTAssertTrue(afternoonRec?.isHealthierAlternative ?? false)
        XCTAssertTrue(afternoonRec?.suggestedFoods.contains(where: { $0.contains("茶") || $0.contains("水") }) ?? false)
    }

    func testLunchRecommendationReflectsNoodlePreference() {
        let noodleHistory = [
            FoodIntakeItemSummary(date: makeDate(hour: 12, dayOffset: -1), foodID: "noodles", foodName: "刀削面", category: .staple, calories: 350),
            FoodIntakeItemSummary(date: makeDate(hour: 12, dayOffset: -2), foodID: "noodles", foodName: "牛肉面", category: .staple, calories: 350)
        ]

        let nowLunch = makeDate(hour: 12, dayOffset: 0)
        let (_, recommendations) = DietaryPreferenceAnalyzer.analyze(
            records: noodleHistory,
            now: nowLunch,
            todayRecords: [],
            calendar: calendar
        )

        let lunchRec = recommendations.first { $0.slot == .lunch }
        XCTAssertNotNil(lunchRec)
        XCTAssertTrue(lunchRec?.suggestedFoods.contains(where: { $0.contains("面") }) ?? false)
    }

    func testSleepDebtTriggersCaffeineAvoidanceInAfternoon() {
        let history = [
            FoodIntakeItemSummary(date: makeDate(hour: 9, dayOffset: -1), foodID: "coffee", foodName: "黑咖啡", category: .drink, calories: 5)
        ]
        let health = DietaryHealthContext(sleepHours: 5.2, isSleepDeprived: true)
        let nowAfternoon = makeDate(hour: 15, dayOffset: 0)

        let (_, recommendations) = DietaryPreferenceAnalyzer.analyze(
            records: history,
            now: nowAfternoon,
            todayRecords: [],
            healthContext: health,
            calendar: calendar
        )

        let afternoonRec = recommendations.first { $0.slot == .afternoonTea }
        XCTAssertNotNil(afternoonRec)
        XCTAssertTrue(afternoonRec?.title.contains("睡眠负债") ?? false)
        XCTAssertTrue(afternoonRec?.suggestionText.contains("避免重度咖啡因") ?? false)
        XCTAssertTrue(afternoonRec?.isHealthierAlternative ?? false)
    }

    func testSleepDebtTriggersGentleWakeupBreakfast() {
        let history = [
            FoodIntakeItemSummary(date: makeDate(hour: 9, dayOffset: -1), foodID: "coffee", foodName: "美式咖啡", category: .drink, calories: 5)
        ]
        let health = DietaryHealthContext(sleepHours: 5.5, isSleepDeprived: true)
        let nowMorning = makeDate(hour: 8, dayOffset: 0)

        let (_, recommendations) = DietaryPreferenceAnalyzer.analyze(
            records: history,
            now: nowMorning,
            todayRecords: [],
            healthContext: health,
            calendar: calendar
        )

        let breakfastRec = recommendations.first { $0.slot == .breakfast }
        XCTAssertNotNil(breakfastRec)
        XCTAssertTrue(breakfastRec?.title.contains("睡眠负债") ?? false)
        XCTAssertTrue(breakfastRec?.suggestionText.contains("优质蛋白") ?? false)
    }

    func testHighWorkoutGeneratesRecoveryDinnerAdvice() {
        let history = [
            FoodIntakeItemSummary(date: makeDate(hour: 12, dayOffset: -1), foodID: "rice", foodName: "米饭", category: .staple, calories: 230)
        ]
        let health = DietaryHealthContext(sleepHours: 7.5, isSleepDeprived: false, activeCalories: 620, stepCount: 13000)
        let nowDinner = makeDate(hour: 19, dayOffset: 0)

        let (_, recommendations) = DietaryPreferenceAnalyzer.analyze(
            records: history,
            now: nowDinner,
            todayRecords: [],
            healthContext: health,
            calendar: calendar
        )

        let dinnerRec = recommendations.first { $0.slot == .dinner }
        XCTAssertNotNil(dinnerRec)
        XCTAssertTrue(dinnerRec?.title.contains("运动") ?? false)
        XCTAssertTrue(dinnerRec?.suggestionText.contains("肌肉糖原") ?? false)
    }
}
