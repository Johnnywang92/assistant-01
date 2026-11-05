import Foundation
import SwiftData

/// 生活提醒的统一实例状态。原始档案保存规则，本模型只保存某一次提醒的完成/推迟结果。
enum LifeReminderKind: String, Codable {
    case medication
    case subscription
    case expiry
    case vehicle
    case habit
    case anniversary
}

@Model
final class LifeReminderAction {
    var id: UUID
    var sourceKindRaw: String
    var sourceID: UUID
    var occurrenceDate: Date
    var statusRaw: String
    var snoozedUntil: Date?
    var completedAt: Date?

    init(kind: LifeReminderKind, sourceID: UUID, occurrenceDate: Date) {
        self.id = UUID()
        self.sourceKindRaw = kind.rawValue
        self.sourceID = sourceID
        self.occurrenceDate = occurrenceDate
        self.statusRaw = "active"
    }

    var kind: LifeReminderKind { LifeReminderKind(rawValue: sourceKindRaw) ?? .habit }
    var isCompleted: Bool { statusRaw == "done" }
}

enum LifeReminderActionStore {
    static func action(kind: LifeReminderKind, sourceID: UUID, occurrenceDate: Date, in context: ModelContext) -> LifeReminderAction? {
        let actions = (try? context.fetch(FetchDescriptor<LifeReminderAction>())) ?? []
        return actions.first { $0.sourceKindRaw == kind.rawValue && $0.sourceID == sourceID && abs($0.occurrenceDate.timeIntervalSince(occurrenceDate)) < 30 }
    }

    /// 标记完成；返回是否落库成功（调用方据此决定播不播成功震动）。
    @discardableResult
    static func complete(kind: LifeReminderKind, sourceID: UUID, occurrenceDate: Date, in context: ModelContext) -> Bool {
        let item = action(kind: kind, sourceID: sourceID, occurrenceDate: occurrenceDate, in: context) ?? {
            let created = LifeReminderAction(kind: kind, sourceID: sourceID, occurrenceDate: occurrenceDate)
            context.insert(created)
            return created
        }()
        item.statusRaw = "done"
        item.completedAt = .now
        item.snoozedUntil = nil
        // 提醒实例的状态是「生活提醒」卡片的派生数据：失败不阻断主流程，但必须
        // 回滚 + 留日志 + 顶部横幅，不能 `try?` 假装成功（审计 SVC-04）。
        return context.saveReportingFailure { error in
            print("⚠️ [LifeReminder] 完成状态落库失败: \(error.localizedDescription)")
            Task { @MainActor in
                SaveFailureCenter.shared.report(error, action: "完成提醒")
            }
        }
    }

    /// 推迟提醒；返回是否落库成功（调用方据此决定播不播成功震动）。
    @discardableResult
    static func snooze(kind: LifeReminderKind, sourceID: UUID, occurrenceDate: Date, in context: ModelContext) -> Bool {
        let item = action(kind: kind, sourceID: sourceID, occurrenceDate: occurrenceDate, in: context) ?? {
            let created = LifeReminderAction(kind: kind, sourceID: sourceID, occurrenceDate: occurrenceDate)
            context.insert(created)
            return created
        }()
        item.snoozedUntil = Calendar.current.date(byAdding: .hour, value: 1, to: .now)
        // 同上：允许失败的派生状态，回滚 + 日志 + 顶部横幅。
        return context.saveReportingFailure { error in
            print("⚠️ [LifeReminder] 推迟状态落库失败: \(error.localizedDescription)")
            Task { @MainActor in
                SaveFailureCenter.shared.report(error, action: "推迟提醒")
            }
        }
    }
}
