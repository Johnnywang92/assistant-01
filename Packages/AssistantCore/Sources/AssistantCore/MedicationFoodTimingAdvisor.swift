import Foundation

/// 用药计划与饮食时效自适应智能分析器（纯函数端侧计算，零网络依赖）
public enum MedicationFoodTimingAdvisor {

    /// 评估某项用药计划与今日用餐记录，计算当前时段自适应状态、最佳服药窗口与冲突警告
    public static func evaluate(
        plan: MedicationPlanSnapshot,
        todayMeals: [RecentMealSnapshot],
        now: Date = .now
    ) -> MedicationTimingEvaluation {
        guard plan.isEnabled else {
            return MedicationTimingEvaluation(
                planID: plan.id,
                medName: plan.medName,
                dosage: plan.dosage,
                status: .pendingScheduled(scheduledTime: now),
                headline: "提醒已暂停",
                actionTip: "该药物提醒当前处于停用状态",
                isUrgent: false
            )
        }

        let calendar = Calendar.current

        // 1. 解析今日计划时点列表
        let scheduledDates = parseTodayTimePoints(plan.dailyTimePoints, referenceDate: now)

        // 2. 检查今日是否已打卡服用
        if let lastTaken = plan.lastTakenAt, calendar.isDate(lastTaken, inSameDayAs: now) {
            // 如果最近一次服药是在 4 小时内，或者所有今日计划点均已完成
            let isRecentlyTaken = now.timeIntervalSince(lastTaken) < 4 * 3600
            let futurePoints = scheduledDates.filter { $0 > lastTaken }
            if isRecentlyTaken || futurePoints.isEmpty {
                return MedicationTimingEvaluation(
                    planID: plan.id,
                    medName: plan.medName,
                    dosage: plan.dosage,
                    status: .takenToday(takenAt: lastTaken),
                    headline: "今日已按时打卡",
                    actionTip: "上次服用时间：\(formatHourMinute(lastTaken))，请继续保持良好服药规律",
                    isUrgent: false
                )
            }
        }

        // 3. 饮食禁忌与相互作用碰撞检测（最高优先级保护安全）
        if let conflict = detectDietaryConflict(plan: plan, recentMeals: todayMeals, now: now) {
            return MedicationTimingEvaluation(
                planID: plan.id,
                medName: plan.medName,
                dosage: plan.dosage,
                status: conflict.status,
                headline: "⚠️ 存在饮食相互作用风险",
                actionTip: conflict.tip,
                isUrgent: true
            )
        }

        // 4. 检查是否有尚未打卡的过去时点（漏服检测）
        let pastSlots = scheduledDates.filter { $0 <= now }
        let lastPastSlot = pastSlots.last
        let isPastSlotTaken: Bool = {
            guard let past = lastPastSlot else { return true }
            guard let taken = plan.lastTakenAt else { return false }
            return taken >= past.addingTimeInterval(-60 * 60)
        }()

        if let pastSlot = lastPastSlot, !isPastSlotTaken {
            let overdueHours = now.timeIntervalSince(pastSlot) / 3600.0
            if overdueHours >= 2.0 {
                let catchUp = generateMissedDoseAdvice(plan: plan, overdueHours: overdueHours)
                return MedicationTimingEvaluation(
                    planID: plan.id,
                    medName: plan.medName,
                    dosage: plan.dosage,
                    status: .missedDoseWarning(
                        scheduledTime: pastSlot,
                        catchUpAdvice: catchUp.advice,
                        canCatchUpNow: catchUp.canCatchUp
                    ),
                    adaptiveNotificationTime: catchUp.canCatchUp ? now : nil,
                    headline: catchUp.canCatchUp ? "⚠️ 轻度超时 · 建议尽快补服" : "⚠️ 严重漏服 · 切勿加倍补服",
                    actionTip: catchUp.advice,
                    isUrgent: true
                )
            }
        }

        // 5. 定位与当前时刻最切近的时点（优先取当前正在生效的过去时点或下一个未来时点）
        let targetSlot = findActiveSlot(scheduledDates: scheduledDates, now: now)
        let scheduledTime = targetSlot.scheduledDate

        // 6. 查找最近一次进餐记录（过去 3 小时内）
        let recentMeal = todayMeals
            .filter { $0.date <= now && now.timeIntervalSince($0.date) <= 3 * 3600 }
            .sorted(by: { $0.date > $1.date })
            .first

        // 7. 根据 mealRelation 进行饮食时效自适应推导
        switch plan.mealRelation {
        case .afterMeal(let minutes):
            // 饭后服用模式
            if let meal = recentMeal {
                let bestTime = meal.date.addingTimeInterval(Double(minutes) * 60)
                let windowEnd = bestTime.addingTimeInterval(30 * 60) // 最佳服用窗口保持 30 分钟

                if now >= meal.date && now <= windowEnd {
                    // 正处于餐后最佳服药黄金窗口
                    return MedicationTimingEvaluation(
                        planID: plan.id,
                        medName: plan.medName,
                        dosage: plan.dosage,
                        status: .primeTimePostMeal(recommendedTime: bestTime, windowEnd: windowEnd, mealName: meal.foodName),
                        adaptiveNotificationTime: bestTime > now ? bestTime : now,
                        headline: "✨ 餐后黄金用药窗口（刚享用 \(meal.foodName)）",
                        actionTip: "建议在 \(formatHourMinute(windowEnd)) 前温水送服（\(plan.dosage)），有效保护胃黏膜减轻刺激！",
                        isUrgent: true
                    )
                } else if now < meal.date.addingTimeInterval(Double(minutes) * 60) {
                    // 刚吃完，建议稍等几分钟消化
                    return MedicationTimingEvaluation(
                        planID: plan.id,
                        medName: plan.medName,
                        dosage: plan.dosage,
                        status: .primeTimePostMeal(recommendedTime: bestTime, windowEnd: windowEnd, mealName: meal.foodName),
                        adaptiveNotificationTime: bestTime,
                        headline: "用餐完毕 · 等待最佳饭后时机",
                        actionTip: "刚刚用餐完毕，建议饭后 \(minutes) 分钟（约 \(formatHourMinute(bestTime))）服药，吸收平稳不伤胃",
                        isUrgent: false
                    )
                }
            }

            // 若已到或超过计划时间，但过去 3 小时完全没有进餐
            if now >= scheduledTime {
                let delayMinutes = 45
                let nextSuggestTime = now.addingTimeInterval(Double(delayMinutes) * 60)

                // 检查是否已经严重超时（例如超过计划时间 3 小时以上）
                let overdueHours = now.timeIntervalSince(scheduledTime) / 3600.0
                if overdueHours >= 3.0 {
                    let catchUp = generateMissedDoseAdvice(plan: plan, overdueHours: overdueHours)
                    return MedicationTimingEvaluation(
                        planID: plan.id,
                        medName: plan.medName,
                        dosage: plan.dosage,
                        status: .missedDoseWarning(
                            scheduledTime: scheduledTime,
                            catchUpAdvice: catchUp.advice,
                            canCatchUpNow: catchUp.canCatchUp
                        ),
                        adaptiveNotificationTime: catchUp.canCatchUp ? now : nil,
                        headline: "⚠️ 严重超时漏服提醒",
                        actionTip: catchUp.advice,
                        isUrgent: true
                    )
                }

                return MedicationTimingEvaluation(
                    planID: plan.id,
                    medName: plan.medName,
                    dosage: plan.dosage,
                    status: .waitingForMeal(
                        scheduledTime: scheduledTime,
                        reason: "已到 \(formatHourMinute(scheduledTime)) 计划时间，但暂未检测到进餐记录。空腹服药易引起胃黏膜不适，已为您顺延等餐。"
                    ),
                    adaptiveNotificationTime: nextSuggestTime,
                    headline: "等餐顺延中 · 建议先用餐再服药",
                    actionTip: "请在就餐后 15~30 分钟内温水服用；若已用餐可直接点击「已服用」打卡",
                    isUrgent: false
                )
            }

        case .beforeMeal(let minutes):
            // 饭前服用模式（提前 30 分钟，吸收好）
            let leadTime = Double(minutes) * 60
            let startWindow = scheduledTime.addingTimeInterval(-leadTime)
            let suggestMealTime = scheduledTime.addingTimeInterval(leadTime)

            if now >= startWindow && now <= scheduledTime.addingTimeInterval(30 * 60) {
                return MedicationTimingEvaluation(
                    planID: plan.id,
                    medName: plan.medName,
                    dosage: plan.dosage,
                    status: .primeTimeBeforeMeal(recommendedTime: scheduledTime, suggestMealBy: suggestMealTime),
                    adaptiveNotificationTime: scheduledTime > now ? scheduledTime : now,
                    headline: "⏰ 饭前最佳服药时间（空腹吸收）",
                    actionTip: "请空腹温水送服（\(plan.dosage)），并建议于 \(formatHourMinute(suggestMealTime)) 左右进餐，药效吸收最佳！",
                    isUrgent: true
                )
            }

        case .withMeal:
            // 随餐同服
            if let meal = recentMeal, now.timeIntervalSince(meal.date) < 20 * 60 {
                return MedicationTimingEvaluation(
                    planID: plan.id,
                    medName: plan.medName,
                    dosage: plan.dosage,
                    status: .primeTimePostMeal(recommendedTime: now, windowEnd: now.addingTimeInterval(15 * 60), mealName: meal.foodName),
                    adaptiveNotificationTime: now,
                    headline: "🍽️ 随餐服用提醒",
                    actionTip: "检测到正在用餐「\(meal.foodName)」，请随餐同服以促进脂溶性吸收并减少胃肠不适",
                    isUrgent: true
                )
            }

        case .bedtime:
            // 睡前服用
            let hour = calendar.component(.hour, from: now)
            if hour >= 21 || hour < 4 {
                return MedicationTimingEvaluation(
                    planID: plan.id,
                    medName: plan.medName,
                    dosage: plan.dosage,
                    status: .primeTimeBeforeMeal(recommendedTime: now, suggestMealBy: now),
                    adaptiveNotificationTime: now,
                    headline: "🌙 睡前服药提醒",
                    actionTip: "准备就寝，请温水送服（\(plan.dosage)），服药后不宜再大量饮水或进食",
                    isUrgent: false
                )
            }

        case .unrestricted:
            break
        }

        // 默认正常计划待服用
        return MedicationTimingEvaluation(
            planID: plan.id,
            medName: plan.medName,
            dosage: plan.dosage,
            status: .pendingScheduled(scheduledTime: scheduledTime),
            adaptiveNotificationTime: scheduledTime > now ? scheduledTime : nil,
            headline: "下次计划服药：\(formatHourMinute(scheduledTime))",
            actionTip: "单次剂量 \(plan.dosage)，服用要求：\(plan.mealRelation.displayName)",
            isUrgent: false
        )
    }

    // MARK: - 辅助计算函数

    /// 将每日时点字符串转换为当天具体 Date
    public static func parseTodayTimePoints(_ points: [String], referenceDate: Date) -> [Date] {
        let calendar = Calendar.current
        var dates: [Date] = []
        for pt in points {
            let parts = pt.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2 else { continue }
            var comps = calendar.dateComponents([.year, .month, .day], from: referenceDate)
            comps.hour = parts[0]
            comps.minute = parts[1]
            comps.second = 0
            if let d = calendar.date(from: comps) {
                dates.append(d)
            }
        }
        return dates.sorted()
    }

    /// 找出与当前时刻最切近的时点
    private static func findActiveSlot(scheduledDates: [Date], now: Date) -> (scheduledDate: Date, isPast: Bool) {
        guard !scheduledDates.isEmpty else {
            return (now, false)
        }
        // 如果有未来的时点，优先取第一个未来时点；如果全部已过，取最后一个已过的时点
        if let upcoming = scheduledDates.first(where: { $0 >= now }) {
            return (upcoming, false)
        }
        return (scheduledDates.last!, true)
    }

    /// 检测饮食与药物相互作用冲突
    private static func detectDietaryConflict(
        plan: MedicationPlanSnapshot,
        recentMeals: [RecentMealSnapshot],
        now: Date
    ) -> (status: MedicationTimingStatus, tip: String)? {
        let name = "\(plan.medName) \(plan.notes ?? "")".lowercased()

        // 1. 西柚 / 葡萄柚冲突检测（他汀类降脂、地平类降压）
        let isStatinOrHypertension = name.contains("他汀") || name.contains("statin") ||
                                     name.contains("地平") || name.contains("降压") ||
                                     name.contains("氨氯地平") || name.contains("硝苯地平")
        if isStatinOrHypertension {
            if let grapefruitMeal = recentMeals.first(where: {
                $0.hasGrapefruit || $0.foodName.contains("西柚") || $0.foodName.contains("葡萄柚")
            }) {
                let hoursAgo = now.timeIntervalSince(grapefruitMeal.date) / 3600.0
                if hoursAgo < 4.0 {
                    let safeTime = grapefruitMeal.date.addingTimeInterval(4 * 3600)
                    let tip = "检测到 \(Int(hoursAgo * 60)) 分钟前食用了西柚/葡萄柚。西柚严重抑制肝脏 CYP3A4 酶代谢，可使「\(plan.medName)」血药浓度成倍升高引发不良反应！请推迟至 \(formatHourMinute(safeTime)) 以后再服用。"
                    return (.conflictAlert(type: .grapefruit, detail: tip, safeTimeAfter: safeTime), tip)
                }
            }
        }

        // 2. 咖啡因相互作用检测（降压、催眠安神、胃酸抑制剂、铁剂）
        let isCaffeineSensitive = name.contains("安神") || name.contains("褪黑素") ||
                                  name.contains("胃") || name.contains("奥美拉唑") ||
                                  name.contains("铝碳酸镁") || name.contains("降压") ||
                                  name.contains("阿普唑仑") || name.contains("感冒")
        if isCaffeineSensitive {
            if let caffeineMeal = recentMeals.first(where: {
                $0.hasCaffeine || $0.foodName.contains("咖啡") || $0.foodName.contains("拿铁") ||
                $0.foodName.contains("奶茶") || $0.foodName.contains("红牛")
            }) {
                let hoursAgo = now.timeIntervalSince(caffeineMeal.date) / 3600.0
                if hoursAgo < 1.5 {
                    let safeTime = caffeineMeal.date.addingTimeInterval(1.5 * 3600)
                    let tip = "检测到 \(Int(hoursAgo * 60)) 分钟前进食了咖啡/高咖啡因饮品。咖啡因可刺激胃酸分泌并拮抗安神镇静效果，建议间隔至 \(formatHourMinute(safeTime)) 以后再服用「\(plan.medName)」。"
                    return (.conflictAlert(type: .caffeine, detail: tip, safeTimeAfter: safeTime), tip)
                }
            }
        }

        // 3. 高钙/牛奶络合检测（喹诺酮类、四环素类抗生素、铁剂）
        let isDairySensitive = name.contains("沙星") || name.contains("四环素") ||
                               name.contains("土霉素") || name.contains("硫酸亚铁") ||
                               name.contains("右旋糖酐铁")
        if isDairySensitive {
            if let dairyMeal = recentMeals.first(where: {
                $0.hasDairy || $0.foodName.contains("牛奶") || $0.foodName.contains("拿铁") || $0.foodName.contains("酸奶")
            }) {
                let hoursAgo = now.timeIntervalSince(dairyMeal.date) / 3600.0
                if hoursAgo < 2.0 {
                    let safeTime = dairyMeal.date.addingTimeInterval(2.0 * 3600)
                    let tip = "牛奶中的钙离子容易与「\(plan.medName)」发生络合形成难溶沉淀，阻碍药物吸收导致药效降低。请间隔至 \(formatHourMinute(safeTime)) 以后再服用。"
                    return (.conflictAlert(type: .dairyCalcium, detail: tip, safeTimeAfter: safeTime), tip)
                }
            }
        }

        // 4. 酒精严重反应检测（头孢、甲硝唑、解热镇痛药）
        let isAlcoholForbidden = name.contains("头孢") || name.contains("甲硝唑") ||
                                 name.contains("替硝唑") || name.contains("布洛芬")
        if isAlcoholForbidden {
            if let alcoholMeal = recentMeals.first(where: {
                $0.hasAlcohol || $0.foodName.contains("酒") || $0.foodName.contains("啤酒") || $0.foodName.contains("白酒")
            }) {
                let hoursAgo = now.timeIntervalSince(alcoholMeal.date) / 3600.0
                if hoursAgo < 24.0 {
                    let tip = "⚠️ 警示：检测到近期有饮酒记录！「\(plan.medName)」与酒精同服极易诱发双硫仑样严重中毒反应或急性消化道出血，服药期间请绝对忌酒！"
                    return (.conflictAlert(type: .alcohol, detail: tip, safeTimeAfter: now.addingTimeInterval(24 * 3600)), tip)
                }
            }
        }

        return nil
    }

    /// 漏服安全指引（遵循国际通行的医学“时差折半”补服原则）
    private static func generateMissedDoseAdvice(
        plan: MedicationPlanSnapshot,
        overdueHours: Double
    ) -> (advice: String, canCatchUp: Bool) {
        // 计算相邻两次服药常规间隔小时数（若每日3次则约8h，每日2次则约12h，每日1次则约24h）
        let freq = max(1, plan.dailyTimePoints.count)
        let nominalIntervalHours = 24.0 / Double(freq)
        let halfInterval = nominalIntervalHours / 2.0

        if overdueHours >= halfInterval {
            // 已超过两次服药间隔的一半，坚决不能加倍补服！
            let advice = "当前已超时 \(String(format: "%.1f", overdueHours)) 小时（超过了该药两次间隔的一半）。【切勿在下一次服药时服用双倍剂量】！建议直接跳过本次，等到下一次预设时间按正常剂量服用。"
            return (advice, false)
        } else {
            // 在安全补服窗口内
            let advice = "当前漏服时间较短（\(String(format: "%.1f", overdueHours)) 小时），请立即按常规剂量补服一次，后续服药时间顺延即可。"
            return (advice, true)
        }
    }

    private static func formatHourMinute(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
