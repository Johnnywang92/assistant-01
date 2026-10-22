import Foundation

/// 出门随身清单与天气/日程自适应智能分析器（纯函数端侧计算，毫秒级响应）
public enum DepartureAdaptiveAdvisor {

    /// 评估天气与今日日程待办，生成场景切换建议、高亮置顶物品与指差确认自适应文字
    public static func evaluate(
        weather: DepartureWeatherContext,
        todayEvents: [DepartureScheduleEvent],
        currentScene: DepartureScene? = nil
    ) -> DepartureAdaptiveAdvice {
        var priorityKeywords: [String] = []
        var suggestedItems: [DepartureSuggestedItem] = []

        let isRainy = weather.isRainyOrSnowy || weather.isSevereAlert
        let isColdOrDropping = (weather.tempDropDegrees ?? 0) >= 6.0 ||
                               (weather.temperatureCelsius != nil && weather.temperatureCelsius! <= 12.0)

        // 1. 天气物品感知
        if isRainy {
            priorityKeywords.append(contentsOf: ["伞", "雨伞", "雨衣", "雨具", "防水"])
            suggestedItems.append(
                DepartureSuggestedItem(
                    title: "折叠雨伞",
                    scene: .rainy,
                    isEssential: true,
                    reason: "今日外部预报降雨/恶劣天气，随身备伞防淋湿",
                    defaultLocation: "玄关伞架"
                )
            )
        }

        if isColdOrDropping {
            priorityKeywords.append(contentsOf: ["外套", "围巾", "保暖", "防风"])
            suggestedItems.append(
                DepartureSuggestedItem(
                    title: "便携保暖外套",
                    scene: .casual,
                    isEssential: false,
                    reason: "今日气温偏低或骤降，备一件外套防感冒",
                    defaultLocation: "玄关衣帽架"
                )
            )
        }

        // 2. 日程待办匹配（只分析未完成的今日日程）
        let activeEvents = todayEvents.filter { !$0.isCompleted }

        let travelEvent = activeEvents.first { matchesKeywords($0, keywords: [
            "出差", "高铁", "飞机", "航班", "动车", "火车", "酒店", "登机", "候机", "行程", "trip", "flight", "机场"
        ]) }

        let workoutEvent = activeEvents.first { matchesKeywords($0, keywords: [
            "健身", "跑步", "羽毛球", "网球", "篮球", "游泳", "瑜伽", "踢球", "普拉提", "攀岩", "workout", "gym", "运动"
        ]) }

        let medicalEvent = activeEvents.first { matchesKeywords($0, keywords: [
            "医院", "体检", "门诊", "挂号", "复诊", "就医", "抽血", "牙科", "看病", "化验", "拍片"
        ]) }

        let parentingEvent = activeEvents.first { matchesKeywords($0, keywords: [
            "幼儿园", "疫苗", "打针", "带娃", "游乐场", "儿保", "亲子", "宝宝"
        ]) }

        let petEvent = activeEvents.first { matchesKeywords($0, keywords: [
            "遛狗", "宠物", "猫咖", "牵狗", "小狗"
        ]) }

        // 3. 根据日程注入装备置顶词与建议项
        if let event = travelEvent {
            priorityKeywords.append(contentsOf: ["身份证", "护照", "充电宝", "移动电源", "常备药", "洗漱包", "快充"])
            suggestedItems.append(
                DepartureSuggestedItem(
                    title: "身份证件 / 护照",
                    scene: .travel,
                    isEssential: true,
                    reason: "因日程「\(event.title)」，乘车乘机需随身核验",
                    defaultLocation: "贴身胸包"
                )
            )
            suggestedItems.append(
                DepartureSuggestedItem(
                    title: "大容量充电宝与快充线",
                    scene: .travel,
                    isEssential: true,
                    reason: "差旅路途较长，保障手机随时有电",
                    defaultLocation: "数码收纳包"
                )
            )
        }

        if let event = workoutEvent {
            priorityKeywords.append(contentsOf: ["水杯", "毛巾", "运动鞋", "换洗衣物", "运动手环", "摇摇杯", "锁"])
            suggestedItems.append(
                DepartureSuggestedItem(
                    title: "运动水杯 / 摇摇杯",
                    scene: .workout,
                    isEssential: true,
                    reason: "因日程「\(event.title)」，运动过程及时补水",
                    defaultLocation: "厨房水槽晾干架"
                )
            )
            suggestedItems.append(
                DepartureSuggestedItem(
                    title: "速干毛巾与换洗衣物",
                    scene: .workout,
                    isEssential: false,
                    reason: "运动流汗后更换防着凉",
                    defaultLocation: "衣柜运动区"
                )
            )
        }

        if let event = medicalEvent {
            priorityKeywords.append(contentsOf: ["医保卡", "身份证", "就诊卡", "病历", "口罩", "检查单"])
            suggestedItems.append(
                DepartureSuggestedItem(
                    title: "医保卡 / 身份证件",
                    scene: .casual,
                    isEssential: true,
                    reason: "因日程「\(event.title)」，挂号缴费与身份核验必备",
                    defaultLocation: "钱包卡夹"
                )
            )
            suggestedItems.append(
                DepartureSuggestedItem(
                    title: "随身防护口罩",
                    scene: .casual,
                    isEssential: true,
                    reason: "医院就医公共场所防护",
                    defaultLocation: "玄关置物抽屉"
                )
            )
        }

        if let event = parentingEvent {
            priorityKeywords.append(contentsOf: ["奶瓶", "水杯", "纸尿裤", "湿巾", "辅食", "温水"])
            suggestedItems.append(
                DepartureSuggestedItem(
                    title: "奶瓶与温水保温杯",
                    scene: .parenting,
                    isEssential: true,
                    reason: "因日程「\(event.title)」，随身备温水",
                    defaultLocation: "妈妈包"
                )
            )
        }

        if let event = petEvent {
            priorityKeywords.append(contentsOf: ["拾便袋", "牵引绳", "拾便夹", "水碗"])
            suggestedItems.append(
                DepartureSuggestedItem(
                    title: "拾便袋 / 拾便夹",
                    scene: .petWalk,
                    isEssential: true,
                    reason: "因日程「\(event.title)」，文明遛宠随身卫生必备",
                    defaultLocation: "玄关挂钩"
                )
            )
        }

        // 4. 指差确认四字诀联动
        let ritualFourthWord = isRainy ? "伞" : "耳/伞"
        let ritualFourthSubtitle = isRainy ? "雨伞防湿" : "耳机/雨具"

        // 5. 组合横幅展示逻辑与推荐场景
        var recommendedScene: DepartureScene? = nil
        var bannerTitle: String? = nil
        var bannerDetail: String? = nil
        var bannerIcon: String? = nil
        var bannerColorName: String? = nil

        if let event = travelEvent {
            recommendedScene = .travel
            bannerTitle = isRainy ? "差旅远行 · \(event.title) (雨雪预警)" : "今日差旅 · \(event.title)"
            bannerDetail = isRainy
                ? "检测到远行日程且外部有降水，已为您置顶差旅装备并切换「伞」防呆确认"
                : "已为您智能聚焦出差旅行清单，请核验证件、车票与快充充电宝"
            bannerIcon = "airplane"
            bannerColorName = "purple"
        } else if let event = workoutEvent {
            recommendedScene = .workout
            bannerTitle = isRainy ? "运动健身 · \(event.title) (降雨天气)" : "今日运动 · \(event.title)"
            bannerDetail = isRainy
                ? "今日有运动安排且外部有雨，已为您置顶运动水杯，出门注意防雨防滑"
                : "检测到运动健身待办，已为您置顶水杯、速干毛巾与储物柜锁"
            bannerIcon = "figure.run"
            bannerColorName = "orange"
        } else if let event = medicalEvent {
            recommendedScene = nil // 保持用户当前场景或日常，不强转
            bannerTitle = isRainy ? "就医体检 · \(event.title) (降雨天气)" : "今日就医 · \(event.title)"
            bannerDetail = isRainy
                ? "今日就诊请备好医保卡与既往病历，雨天路滑出行提前出发"
                : "检测到就医日程，已为您置顶医保卡、就诊卡与随身口罩"
            bannerIcon = "cross.case.fill"
            bannerColorName = "red"
        } else if let event = parentingEvent {
            recommendedScene = .parenting
            bannerTitle = "亲子出行 · \(event.title)"
            bannerDetail = "已为您聚焦带娃出行清单，随身温水与纸尿裤已置顶"
            bannerIcon = "figure.and.child.holdinghands"
            bannerColorName = "pink"
        } else if let event = petEvent {
            recommendedScene = .petWalk
            bannerTitle = "宠物随行 · \(event.title)"
            bannerDetail = "已为您聚焦遛狗随行清单，牵引绳与拾便袋已置顶"
            bannerIcon = "pawprint.fill"
            bannerColorName = "teal"
        } else if isRainy {
            recommendedScene = .rainy
            bannerTitle = "天气自适应 · 今日预报有雨雪"
            bannerDetail = "指差确认已自适应为「伞」，请务必携带雨具出门防淋湿"
            bannerIcon = "cloud.rain.fill"
            bannerColorName = "teal"
        } else if isColdOrDropping {
            bannerTitle = "气温自适应 · 今日气温较低/骤降"
            bannerDetail = "今日气温偏低，建议随身备一件便携外套或围巾防着凉"
            bannerIcon = "thermometer.snowflake"
            bannerColorName = "indigo"
        }

        return DepartureAdaptiveAdvice(
            recommendedScene: recommendedScene,
            bannerTitle: bannerTitle,
            bannerDetail: bannerDetail,
            bannerIcon: bannerIcon,
            bannerColorName: bannerColorName,
            priorityItemKeywords: priorityKeywords,
            suggestedItemsToAdd: suggestedItems,
            ritualFourthWord: ritualFourthWord,
            ritualFourthSubtitle: ritualFourthSubtitle,
            isRainWarningActive: isRainy
        )
    }

    private static func matchesKeywords(_ event: DepartureScheduleEvent, keywords: [String]) -> Bool {
        let content = "\(event.title) \(event.notes ?? "")".lowercased()
        return keywords.contains { content.contains($0.lowercased()) }
    }
}
