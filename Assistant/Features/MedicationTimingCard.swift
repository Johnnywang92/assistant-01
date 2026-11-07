import AssistantCore
import SwiftData
import SwiftUI

/// 饮食时效自适应看板：把「今天吃了什么」与「该什么时候吃药」交叉比对，
/// 给出冲突警示 / 漏服提醒 / 餐后黄金窗口 / 等餐顺延等一条最值得看的提示。
///
/// 判定规则全在 Core 的 `MedicationFoodTimingAdvisor`，本视图只负责取数与呈现，
/// 不复制第二份规则。
///
/// 归属（2026-11-07）：药品功能收敛到「物品收纳 → 药品与健康储备」这**唯一入口**后，
/// 本看板从原「运动与药物保健品」页迁到此处。运动页不再承载任何药品内容。
///
/// 性能：`medPlans` 复用父视图已有的 `@Query`（避免每行重建观察，见 UI-08）；
/// 饮食 / 饮水快照在 body 里只算一次，评估字典与提示共用同一份结果。
struct MedicationTimingCard: View {
    /// 父视图 `ItemStorageVaultView` 已经 `@Query` 过同一张表，这里必须复用。
    let medPlans: [MedicationPlan]

    @Query(sort: \FoodIntakeRecord.date, order: .reverse) private var foodRecords: [FoodIntakeRecord]
    @Query(sort: \WaterIntakeRecord.date, order: .reverse) private var waterRecords: [WaterIntakeRecord]

    var body: some View {
        let meals = todayMeals
        let evaluations = medEvaluations(meals: meals)
        if let evaluation = topTimingEvaluation(from: evaluations) {
            card(for: evaluation)
        }
    }

    // MARK: - 数据准备

    /// 今日用餐与饮品快照（用于用药时效自适应计算，同步包含「喝水记录」中的咖啡/茶/奶茶）。
    private var todayMeals: [RecentMealSnapshot] {
        let calendar = Calendar.current
        let foodSnapshots = foodRecords
            .filter { calendar.isDateInToday($0.date) }
            .map { record in
                let name = record.foodName.lowercased()
                let hasCaffeine = name.contains("咖啡") || name.contains("拿铁") || name.contains("美式") ||
                                  name.contains("摩卡") || name.contains("卡布") || name.contains("奶茶") ||
                                  name.contains("红茶") || name.contains("绿茶") || name.contains("乌龙") ||
                                  name.contains("红牛") || name.contains("可乐")
                let hasGrapefruit = name.contains("西柚") || name.contains("葡萄柚")
                let hasDairy = name.contains("牛奶") || name.contains("拿铁") || name.contains("酸奶") ||
                               name.contains("奶酪") || name.contains("芝士") || name.contains("乳")
                let hasAlcohol = name.contains("酒") || name.contains("啤酒") || name.contains("白酒") ||
                                 name.contains("红酒") || name.contains("鸡尾酒")
                return RecentMealSnapshot(
                    id: record.id.uuidString,
                    date: record.date,
                    foodName: record.foodName,
                    calories: record.consumedCalories,
                    hasCaffeine: hasCaffeine,
                    hasGrapefruit: hasGrapefruit,
                    hasDairy: hasDairy,
                    hasAlcohol: hasAlcohol
                )
            }
        let waterSnapshots = waterRecords
            .filter { calendar.isDateInToday($0.date) }
            .compactMap { record -> RecentMealSnapshot? in
                let name = (record.customName ?? record.beverageType.displayName).lowercased()
                let hasCaffeine = record.caffeineMG > 0 || record.beverageType == .blackCoffee || record.beverageType == .latte || record.beverageType == .pureTea || record.beverageType == .milkTea
                let hasDairy = record.beverageType == .milk || record.beverageType == .latte || record.beverageType == .milkTea || name.contains("拿铁") || name.contains("牛奶") || name.contains("奶")
                let hasGrapefruit = name.contains("西柚") || name.contains("葡萄柚")
                guard hasCaffeine || hasDairy || hasGrapefruit || record.calories > 0 else { return nil }
                return RecentMealSnapshot(
                    id: record.id.uuidString,
                    date: record.date,
                    foodName: record.customName ?? record.beverageType.displayName,
                    calories: record.calories,
                    hasCaffeine: hasCaffeine,
                    hasGrapefruit: hasGrapefruit,
                    hasDairy: hasDairy,
                    hasAlcohol: false
                )
            }
        return (foodSnapshots + waterSnapshots).sorted { $0.date > $1.date }
    }

    /// 每帧只算一次：所有启用中的用药计划各出一条评估。
    private func medEvaluations(meals: [RecentMealSnapshot]) -> [UUID: MedicationTimingEvaluation] {
        var result: [UUID: MedicationTimingEvaluation] = [:]
        result.reserveCapacity(medPlans.count)
        for med in medPlans {
            result[med.id] = MedicationFoodTimingAdvisor.evaluate(
                plan: med.toSnapshot(),
                todayMeals: meals,
                now: .now
            )
        }
        return result
    }

    /// 当前最紧急或具有行动价值的一条评估。
    private func topTimingEvaluation(from evaluations: [UUID: MedicationTimingEvaluation]) -> MedicationTimingEvaluation? {
        // 保持原顺序语义：只看启用中的计划，按 medPlans 顺序取
        let evals = medPlans.filter { $0.isEnabled }.compactMap { evaluations[$0.id] }
        // 冲突警示 > 漏服提醒 > 餐后黄金窗口 > 等餐顺延
        if let conflict = evals.first(where: {
            if case .conflictAlert = $0.status { return true }
            return false
        }) {
            return conflict
        }
        if let missed = evals.first(where: {
            if case .missedDoseWarning = $0.status { return true }
            return false
        }) {
            return missed
        }
        if let prime = evals.first(where: {
            if case .primeTimePostMeal = $0.status { return true }
            return false
        }) {
            return prime
        }
        if let waiting = evals.first(where: {
            if case .waitingForMeal = $0.status { return true }
            return false
        }) {
            return waiting
        }
        return nil
    }

    // MARK: - 呈现

    @ViewBuilder
    private func card(for eval: MedicationTimingEvaluation) -> some View {
        let color: Color = {
            switch eval.status {
            case .conflictAlert: return .red
            case .primeTimePostMeal, .primeTimeBeforeMeal: return .green
            case .waitingForMeal, .missedDoseWarning: return .orange
            case .takenToday, .pendingScheduled: return .blue
            }
        }()

        let icon: String = {
            switch eval.status {
            case .conflictAlert: return "exclamationmark.triangle.fill"
            case .primeTimePostMeal: return "sparkles"
            case .primeTimeBeforeMeal: return "fork.knife.circle.fill"
            case .waitingForMeal: return "clock.arrow.circlepath"
            case .missedDoseWarning: return "exclamationmark.circle.fill"
            case .takenToday: return "checkmark.seal.fill"
            case .pendingScheduled: return "clock.fill"
            }
        }()

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .font(.subheadline.bold())
                Text(eval.headline)
                    .font(.caption.bold())
                    .foregroundStyle(color)
                Spacer()
                Text(eval.medName)
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(color.opacity(0.15)))
                    .foregroundStyle(color)
            }

            Text(eval.actionTip)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                .fill(color.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                        .stroke(color.opacity(0.25), lineWidth: 1)
                )
        )
        .padding(.vertical, 2)
    }
}
