import AssistantCore
import Foundation
import SwiftData

/// 习惯打卡、每日服药计划与今日饮食块。
struct HabitPromptBlock: PromptBlockProvider {
    let id: PromptBlockID = .habit

    func makeBlock(context: ModelContext, query: String) -> PromptBlock {
        let habits = ((try? context.fetch(FetchDescriptor<PeriodicHabit>())) ?? []).filter { $0.isEnabled }
        let meds = ((try? context.fetch(FetchDescriptor<MedicationPlan>())) ?? []).filter { $0.isEnabled }
        let startOfToday = Calendar.current.startOfDay(for: .now)
        let todayFoodRecords = (try? context.fetch(FetchDescriptor<FoodIntakeRecord>(
            predicate: #Predicate { $0.date >= startOfToday },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        ))) ?? []
        var habitMedParts: [String] = []
        if !meds.isEmpty {
            habitMedParts.append("用药：" + meds.prefix(4).map { "\($0.medName) \($0.dosage)（\($0.dailyTimePoints.joined(separator: "/"))）" }.joined(separator: "、"))
        }
        if !habits.isEmpty {
            habitMedParts.append("习惯：" + habits.prefix(4).map { "\($0.title)（\($0.recurrenceRaw)）" }.joined(separator: "、"))
        }
        if !todayFoodRecords.isEmpty {
            let totalCalories = Int(todayFoodRecords.reduce(0.0) { $0 + $1.consumedCalories }.rounded())
            let itemsDesc = todayFoodRecords.prefix(4).map { rec in
                let ratioText = rec.consumedRatio < 0.999 ? "（吃了\(Int((rec.consumedRatio * 100).rounded()))%）" : ""
                return "\(rec.foodName)\(ratioText)\(Int(rec.consumedCalories.rounded()))千卡"
            }.joined(separator: "、")
            habitMedParts.append("今日饮食摄入：共 \(totalCalories) 千卡（\(itemsDesc)）")
        }
        if let dietSummary = DietaryPreferenceService.shared.promptSummary(with: context) {
            habitMedParts.append("饮食偏好画像：\(dietSummary)")
        }
        let habitMedText = habitMedParts.isEmpty ? "无" : habitMedParts.joined(separator: "；")
        return PromptBlock(id: id, text: "• 用药、习惯与今日饮食：\(habitMedText)")
    }
}
