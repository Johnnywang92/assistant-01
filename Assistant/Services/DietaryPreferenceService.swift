import AssistantCore
import Foundation
import SwiftData
import SwiftUI

/// 饮食偏好与智能建议编排服务。
///
/// 职责：
/// 1. 从 SwiftData 中聚合历史 `FoodIntakeRecord`，调用 Core 的 `DietaryPreferenceAnalyzer` 提炼偏好画像。
/// 2. 结合当前时间时段、今日已摄入与消耗能量，实时生成「懂你的」场景化饮食建议。
/// 3. 为生活档案卡片与端侧 LLM 系统提示词提供结构化偏好摘要。
@MainActor
final class DietaryPreferenceService: ObservableObject {

    static let shared = DietaryPreferenceService()

    /// 用户综合饮食画像
    @Published private(set) var profile: DietaryPreferenceProfile
    /// 当前时段专属建议
    @Published private(set) var currentRecommendations: [DietaryRecommendation] = []
    /// 是否正在计算
    @Published private(set) var isAnalyzing = false

    private init() {
        self.profile = DietaryPreferenceAnalyzer.buildProfile(from: [])
    }

    /// 刷新用户的饮食偏好画像与时段建议
    func refresh(with context: ModelContext, now: Date = .now) {
        isAnalyzing = true
        defer { isAnalyzing = false }

        let allRecords = (try? context.fetch(FetchDescriptor<FoodIntakeRecord>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        ))) ?? []

        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: now)

        let summaries: [FoodIntakeItemSummary] = allRecords.compactMap { rec in
            // 根据 foodID 或菜名推断对应分类（优先识别组合餐中的荤素搭配）
            let matchedCategory: FoodCategory
            if let ids = rec.foodID?.components(separatedBy: "+"), !ids.isEmpty {
                let items = ids.compactMap { FoodCatalog.item(id: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                if let meat = items.first(where: { $0.category == .meat }) {
                    matchedCategory = meat.category
                } else if let nonStaple = items.first(where: { $0.category != .staple }) {
                    matchedCategory = nonStaple.category
                } else if let first = items.first {
                    matchedCategory = first.category
                } else {
                    matchedCategory = FoodItem.inferCategory(from: rec.foodName)
                }
            } else {
                matchedCategory = FoodItem.inferCategory(from: rec.foodName)
            }

            return FoodIntakeItemSummary(
                id: rec.id.uuidString,
                date: rec.date,
                foodID: rec.foodID ?? "custom",
                foodName: rec.foodName,
                category: matchedCategory,
                calories: rec.consumedCalories,
                portion: rec.portion,
                consumedRatio: rec.consumedRatio
            )
        }

        let todaySummaries = summaries.filter { $0.date >= startOfToday }

        // 提取健康与活力生理指标（睡眠负债与运动消耗闭环联动）
        let healthSnap = HealthKitService.shared.snapshot
        let sleepHours = healthSnap?.sleepHours
        let isSleepDeprived = (sleepHours != nil) && (sleepHours! < 6.0)
        let activeCal = healthSnap?.activeEnergy
        let steps = healthSnap?.stepCount.map { Int($0) }
        let healthContext = DietaryHealthContext(
            sleepHours: sleepHours,
            isSleepDeprived: isSleepDeprived,
            activeCalories: activeCal,
            stepCount: steps
        )

        let result = DietaryPreferenceAnalyzer.analyze(
            records: summaries,
            now: now,
            todayRecords: todaySummaries,
            healthContext: healthContext,
            calendar: cal
        )

        self.profile = result.profile
        self.currentRecommendations = result.recommendations
    }

    /// 生成供 LLM 系统提示词使用的紧凑饮食偏好摘要文本。
    func promptSummary(with context: ModelContext) -> String? {
        refresh(with: context)
        guard profile.sampleCount >= 2 else { return nil }

        var parts: [String] = []
        parts.append("饮品偏好：\(profile.beverage.style.rawValue)（\(profile.beverage.topBeverages.prefix(2).joined(separator: "、"))，\(profile.beverage.typicalTimeDescription)）")
        parts.append("主食偏好：\(profile.staple.style.rawValue)（常吃 \(profile.staple.topStaples.prefix(2).joined(separator: "、"))）")
        if !profile.snack.topSnacks.isEmpty || profile.snack.hasAfternoonTeaHabit || profile.snack.hasLateNightHabit {
            parts.append("加餐零食：\(profile.snack.summary)")
        }
        if !profile.tags.isEmpty {
            parts.append("标签：\(profile.tags.joined(separator: " "))")
        }
        return parts.joined(separator: "；")
    }
}
