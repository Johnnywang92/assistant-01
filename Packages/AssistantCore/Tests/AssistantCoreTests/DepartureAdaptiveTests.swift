import XCTest
@testable import AssistantCore

final class DepartureAdaptiveTests: XCTestCase {

    func testRainyWeatherAdaptsChecklistAndRitual() {
        let weather = DepartureWeatherContext(
            isRainyOrSnowy: true,
            temperatureCelsius: 16.0,
            tempDropDegrees: 2.0,
            isSevereAlert: false,
            weatherDescription: "中雨"
        )

        let advice = DepartureAdaptiveAdvisor.evaluate(weather: weather, todayEvents: [])

        XCTAssertTrue(advice.isRainWarningActive)
        XCTAssertEqual(advice.ritualFourthWord, "伞")
        XCTAssertEqual(advice.ritualFourthSubtitle, "雨伞防湿")
        XCTAssertEqual(advice.recommendedScene, .rainy)
        XCTAssertTrue(advice.priorityItemKeywords.contains("伞"))
        XCTAssertTrue(advice.suggestedItemsToAdd.contains { $0.title == "折叠雨伞" })
        XCTAssertNotNil(advice.bannerTitle)
        XCTAssertTrue(advice.bannerTitle?.contains("雨雪") == true)
    }

    func testTempDropSuggestsWarmCoat() {
        let weather = DepartureWeatherContext(
            isRainyOrSnowy: false,
            temperatureCelsius: 8.0,
            tempDropDegrees: 7.0,
            isSevereAlert: false,
            weatherDescription: "多云骤降"
        )

        let advice = DepartureAdaptiveAdvisor.evaluate(weather: weather, todayEvents: [])

        XCTAssertFalse(advice.isRainWarningActive)
        XCTAssertEqual(advice.ritualFourthWord, "耳/伞")
        XCTAssertTrue(advice.priorityItemKeywords.contains("外套"))
        XCTAssertTrue(advice.suggestedItemsToAdd.contains { $0.title.contains("外套") })
        XCTAssertEqual(advice.bannerIcon, "thermometer.snowflake")
    }

    func testWorkoutScheduleAdaptsToWorkoutScene() {
        let weather = DepartureWeatherContext(isRainyOrSnowy: false)
        let events = [
            DepartureScheduleEvent(title: "晚 7 点健身房练腿与有氧跑步", isCompleted: false)
        ]

        let advice = DepartureAdaptiveAdvisor.evaluate(weather: weather, todayEvents: events)

        XCTAssertEqual(advice.recommendedScene, .workout)
        XCTAssertTrue(advice.priorityItemKeywords.contains("水杯"))
        XCTAssertTrue(advice.priorityItemKeywords.contains("毛巾"))
        XCTAssertTrue(advice.suggestedItemsToAdd.contains { $0.title.contains("水杯") })
        XCTAssertTrue(advice.bannerTitle?.contains("健身房") == true)
    }

    func testTravelScheduleWithRain() {
        let weather = DepartureWeatherContext(isRainyOrSnowy: true)
        let events = [
            DepartureScheduleEvent(title: "出差乘坐虹桥高铁前往南京", isCompleted: false)
        ]

        let advice = DepartureAdaptiveAdvisor.evaluate(weather: weather, todayEvents: events)

        // 差旅优先级高，但同时保持雨天强防呆
        XCTAssertEqual(advice.recommendedScene, .travel)
        XCTAssertTrue(advice.isRainWarningActive)
        XCTAssertEqual(advice.ritualFourthWord, "伞")
        XCTAssertTrue(advice.priorityItemKeywords.contains("身份证"))
        XCTAssertTrue(advice.priorityItemKeywords.contains("充电宝"))
        XCTAssertTrue(advice.priorityItemKeywords.contains("伞"))
        XCTAssertTrue(advice.bannerTitle?.contains("出差") == true)
        XCTAssertTrue(advice.bannerTitle?.contains("雨") == true)
    }

    func testMedicalSchedulePrioritizesHealthInsuranceCard() {
        let weather = DepartureWeatherContext(isRainyOrSnowy: false)
        let events = [
            DepartureScheduleEvent(title: "上午协和医院皮肤科门诊复诊", isCompleted: false)
        ]

        let advice = DepartureAdaptiveAdvisor.evaluate(weather: weather, todayEvents: events)

        XCTAssertTrue(advice.priorityItemKeywords.contains("医保卡"))
        XCTAssertTrue(advice.priorityItemKeywords.contains("口罩"))
        XCTAssertTrue(advice.suggestedItemsToAdd.contains { $0.title.contains("医保卡") })
        XCTAssertTrue(advice.bannerTitle?.contains("就医") == true)
    }

    func testStorageLocationMatcher() {
        let stored = [
            DepartureStoredItemSnapshot(
                name: "天堂折叠晴雨伞",
                location: "玄关鞋柜上方第二层伞架",
                roomArea: "玄关"
            ),
            DepartureStoredItemSnapshot(
                name: "家门钥匙与小黄鸭钥匙扣",
                location: "玄关木质置物托盘",
                roomArea: "玄关"
            ),
            DepartureStoredItemSnapshot(
                name: "AirPods Pro 2",
                location: "主卧床头柜无线充底座",
                roomArea: "主卧"
            ),
            DepartureStoredItemSnapshot(
                name: "布洛芬缓释胶囊",
                location: "客厅电视柜白色小药箱",
                roomArea: "客厅"
            ),
            DepartureStoredItemSnapshot(
                name: "罗马仕移动电源充电宝",
                location: "抽屉黑色数码包",
                roomArea: "次卧"
            )
        ]

        // 1. "折叠雨伞" 匹配 "天堂折叠晴雨伞"
        let umbrellaMatch = DepartureStorageMatcher.findMatch(itemTitle: "折叠雨伞", storedItems: stored)
        XCTAssertNotNil(umbrellaMatch)
        XCTAssertEqual(umbrellaMatch?.name, "天堂折叠晴雨伞")
        XCTAssertEqual(umbrellaMatch?.formattedStorageDescription, "玄关鞋柜上方第二层伞架")

        // 2. "家门钥匙 / 门禁卡" 匹配 "家门钥匙与小黄鸭钥匙扣"
        let keyMatch = DepartureStorageMatcher.findMatch(itemTitle: "家门钥匙 / 门禁卡", storedItems: stored)
        XCTAssertNotNil(keyMatch)
        XCTAssertEqual(keyMatch?.name, "家门钥匙与小黄鸭钥匙扣")

        // 3. 别名匹配: "降噪耳机 (AirPods)" 匹配 "AirPods Pro 2"
        let earphoneMatch = DepartureStorageMatcher.findMatch(itemTitle: "降噪耳机 (AirPods)", storedItems: stored)
        XCTAssertNotNil(earphoneMatch)
        XCTAssertEqual(earphoneMatch?.name, "AirPods Pro 2")
        XCTAssertEqual(earphoneMatch?.formattedStorageDescription, "主卧床头柜无线充底座")

        // 4. 跨区域前缀格式化: "次卧 · 抽屉黑色数码包"
        let powerBankMatch = DepartureStorageMatcher.findMatch(itemTitle: "大容量充电宝", storedItems: stored)
        XCTAssertNotNil(powerBankMatch)
        XCTAssertEqual(powerBankMatch?.formattedStorageDescription, "次卧 · 抽屉黑色数码包")

        // 4. 药品匹配: "个人常备药品" 匹配 "布洛芬缓释胶囊"
        let medMatch = DepartureStorageMatcher.findMatch(itemTitle: "个人常备药品", storedItems: stored)
        XCTAssertNotNil(medMatch)
        XCTAssertEqual(medMatch?.name, "布洛芬缓释胶囊")

        // 5. 不存在物品匹配返回 nil
        let notFound = DepartureStorageMatcher.findMatch(itemTitle: "不存在的火星飞船", storedItems: stored)
        XCTAssertNil(notFound)
    }
}
