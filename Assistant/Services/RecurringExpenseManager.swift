import Foundation
import SwiftData
import SwiftUI

/// 固定周期支出周期类型
public enum RecurringExpenseCycle: String, Codable, CaseIterable, Identifiable {
    case monthly = "按月固定"
    case yearly = "按年排期"
    case weekly = "按周循环"
    case customDays = "每N天"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .monthly: return "calendar"
        case .yearly: return "calendar.badge.clock"
        case .weekly: return "repeat"
        case .customDays: return "repeat.1"
        }
    }

    public var displayUnit: String {
        switch self {
        case .monthly: return "/月"
        case .yearly: return "/年"
        case .weekly: return "/周"
        case .customDays: return "天"
        }
    }
}

/// 固定周期支出条目模型
public struct RecurringExpenseItem: Identifiable, Codable, Equatable {
    public var id: UUID
    public var title: String                // 如 "月租房租", "iCloud+ 自动续费", "汽车商业险"
    public var amount: Double               // 每次扣费金额
    public var category: ExpenseCategory    // 消费类别
    public var cycle: RecurringExpenseCycle // 周期模式
    public var customDaysInterval: Int      // 自定义天数（如每 15 天）
    public var nextDueDate: Date            // 下次入账/扣费排期日期
    public var isAutoRecord: Bool           // 到期是否自动记入日常账本
    public var isReminderEnabled: Bool      // 是否提前提醒
    public var reminderDaysBefore: Int      // 提前几天提醒（如提前 2 天）
    public var isPaused: Bool               // 是否暂停
    public var lastRecordedDate: Date?      // 最近一次自动记账时间
    public var notes: String?               // 备注
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        amount: Double,
        category: ExpenseCategory = .living,
        cycle: RecurringExpenseCycle = .monthly,
        customDaysInterval: Int = 30,
        nextDueDate: Date,
        isAutoRecord: Bool = true,
        isReminderEnabled: Bool = true,
        reminderDaysBefore: Int = 2,
        isPaused: Bool = false,
        lastRecordedDate: Date? = nil,
        notes: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.amount = abs(amount)
        self.category = category
        self.cycle = cycle
        self.customDaysInterval = max(1, customDaysInterval)
        self.nextDueDate = nextDueDate
        self.isAutoRecord = isAutoRecord
        self.isReminderEnabled = isReminderEnabled
        self.reminderDaysBefore = reminderDaysBefore
        self.isPaused = isPaused
        self.lastRecordedDate = lastRecordedDate
        self.notes = notes
        self.createdAt = createdAt
    }

    /// 计算下次周期的到期时间
    public func advanceToNextCycleDate(from date: Date) -> Date {
        let calendar = Calendar.current
        switch cycle {
        case .monthly:
            return calendar.date(byAdding: .month, value: 1, to: date) ?? date
        case .yearly:
            return calendar.date(byAdding: .year, value: 1, to: date) ?? date
        case .weekly:
            return calendar.date(byAdding: .day, value: 7, to: date) ?? date
        case .customDays:
            return calendar.date(byAdding: .day, value: max(1, customDaysInterval), to: date) ?? date
        }
    }

    /// 折算为每月预估支出金额（用于统计月度固定刚性支出总额）
    public var monthlyEquivalentAmount: Double {
        switch cycle {
        case .monthly:
            return amount
        case .yearly:
            return amount / 12.0
        case .weekly:
            return amount * (52.0 / 12.0)
        case .customDays:
            return (amount / Double(max(1, customDaysInterval))) * 30.0
        }
    }
}

/// 固定周期支出管理中心（持久化在 UserDefaults，前台自动巡检查验并入账）
@MainActor
public final class RecurringExpenseManager: ObservableObject {
    public static let shared = RecurringExpenseManager()

    private let storageKey = "recurring_expenses_data_v1"

    @Published public private(set) var items: [RecurringExpenseItem] = []

    /// 最近一次落库失败的原因（成功时清空）。视图可据此提示「保存失败」而不是播成功反馈。
    @Published public private(set) var lastSaveFailureMessage: String?

    private init() {
        loadItems()
        if items.isEmpty {
            seedDefaultPresets()
        }
    }

    /// 加载持久化数据
    private func loadItems() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return }
        if let decoded = try? JSONDecoder().decode([RecurringExpenseItem].self, from: data) {
            self.items = decoded
        }
    }

    /// 保存持久化数据
    private func saveItems() {
        if let encoded = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(encoded, forKey: storageKey)
        }
    }

    /// 首次无数据时预设高频模板示范
    private func seedDefaultPresets() {
        let calendar = Calendar.current
        let nextMonthFirst = calendar.date(byAdding: .month, value: 1, to: calendar.date(bySetting: .day, value: 1, of: .now) ?? .now) ?? .now

        let defaultItems = [
            RecurringExpenseItem(
                title: "房屋租金/物业费",
                amount: 3200.0,
                category: .living,
                cycle: .monthly,
                nextDueDate: nextMonthFirst,
                isAutoRecord: false,
                isReminderEnabled: true,
                reminderDaysBefore: 3,
                notes: "按月固定刚性支出，到期前3天提醒"
            ),
            RecurringExpenseItem(
                title: "iCloud+ 自动续费",
                amount: 21.0,
                category: .digital,
                cycle: .monthly,
                nextDueDate: calendar.date(byAdding: .day, value: 15, to: .now) ?? .now,
                isAutoRecord: true,
                isReminderEnabled: true,
                reminderDaysBefore: 1,
                notes: "Apple 服务按月连续扣款"
            )
        ]
        self.items = defaultItems
        saveItems()
    }

    // MARK: - 业务操作

    /// 新增周期固定支出
    public func add(item: RecurringExpenseItem) {
        items.append(item)
        saveItems()
    }

    /// 更新周期固定支出
    public func update(item: RecurringExpenseItem) {
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx] = item
            saveItems()
        }
    }

    /// 删除
    public func delete(id: UUID) {
        items.removeAll(where: { $0.id == id })
        saveItems()
    }

    /// 切换暂停/激活状态
    public func togglePause(for item: RecurringExpenseItem) {
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx].isPaused.toggle()
            saveItems()
        }
    }

    /// 每月预估固定支出总额
    public var monthlyEstimatedTotal: Double {
        items.filter { !$0.isPaused }.reduce(0.0) { $0 + $1.monthlyEquivalentAmount }
    }

    /// 立即记入一笔（手动触发）
    ///
    /// 顺序约束（审计 SVC-04）：先落库、再推进 UserDefaults 里的排期、最后播成功震动。
    /// 旧实现先 `saveItems()` 再 `try? context.save()`，落库失败时周期排期已被推进到下期、
    /// 账本里却没有这笔记录，用户还收到了成功震动。
    public func recordNow(item: RecurringExpenseItem, in context: ModelContext) {
        let record = ExpenseRecord(
            amount: item.amount,
            isIncome: false,
            category: item.category,
            title: item.title,
            rawText: "周期固定支出: \(item.title) (\(item.cycle.rawValue))",
            date: .now
        )
        context.insert(record)

        let saved = context.saveReportingFailure { error in
            print("⚠️ [RecurringExpense] 手动记入落库失败: \(error.localizedDescription)")
            Task { @MainActor in
                SaveFailureCenter.shared.report(error, action: "记入固定支出")
            }
        }
        guard saved else {
            lastSaveFailureMessage = L10n.choose("记账保存失败，请重试。", "Saving the expense failed. Please try again.")
            return
        }

        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx].lastRecordedDate = .now
            items[idx].nextDueDate = item.advanceToNextCycleDate(from: item.nextDueDate)
            saveItems()
        }
        lastSaveFailureMessage = nil
        Haptic.success()
    }

    /// 巡检查验并自动记账或排期提醒（在前台激活或每日定时巡检时执行）
    ///
    /// 顺序约束（审计 SVC-04）：一次 save 落库成功后，才推进 UserDefaults 排期并发「已自动记账」
    /// 通知；失败则把内存里的排期回滚到本轮之前，避免出现「账本没记、排期却已跳期」的错位。
    public func processDueRecurringExpenses(in context: ModelContext) {
        let now = Date.now
        var didModify = false
        let before = items
        var recordedTitles: [String] = []

        for i in 0..<items.count {
            guard !items[i].isPaused else { continue }

            let due = items[i].nextDueDate
            // 如果到期时间已到或已过去
            if due <= now {
                if items[i].isAutoRecord {
                    // 自动生成一笔账本支出记录
                    let record = ExpenseRecord(
                        amount: items[i].amount,
                        isIncome: false,
                        category: items[i].category,
                        title: items[i].title,
                        rawText: "周期自动记账: \(items[i].title) (\(items[i].cycle.rawValue))",
                        date: due
                    )
                    context.insert(record)
                    recordedTitles.append(items[i].title)
                }

                items[i].lastRecordedDate = due
                // 推进到下个周期
                var next = items[i].advanceToNextCycleDate(from: due)
                while next <= now {
                    next = items[i].advanceToNextCycleDate(from: next)
                }
                items[i].nextDueDate = next
                didModify = true
            }
        }

        guard didModify else { return }
        let saved = context.saveReportingFailure { error in
            print("⚠️ [RecurringExpense] 周期支出巡检落库失败，本轮排期不推进: \(error.localizedDescription)")
            Task { @MainActor in
                SaveFailureCenter.shared.report(error, action: "周期支出自动记账")
            }
        }
        guard saved else {
            // 落库失败：内存排期恢复到本轮之前，UserDefaults 不动（下次巡检会重试）。
            items = before
            return
        }
        saveItems()
        for title in recordedTitles {
            // 落库成功后才发「已自动记账」通知（审计 SVC-04）。
            NotificationService.post(
                title: "固定支出已自动记账",
                body: "「\(title)」已自动记入账本。"
            )
        }
    }
}
