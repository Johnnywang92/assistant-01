@_exported import AssistantCore
import Darwin
import Foundation

/// 主应用与小组件/实时活动扩展共享的数据层。
/// 出于数据安全考虑（P0：密码库、证件等敏感数据绝不进扩展），
/// 这里只承载用户主动展示的待办/快递/今日支出轻量快照，
/// 以及扩展产生的"待同步指令队列"，由主应用在启动/回前台时对账落库。
/// （数据结构定义与跨端对账纯函数见 `AssistantCore/WatchSyncModels.swift`）
public enum WidgetBridgeConstants {
    /// App Group 标识（免费 Personal Team 可用）
    public static let appGroupID = "group.com.yifanwang.assistant01"
    static let snapshotKey = "widget_shared_snapshot_v1"
    static let commandsKey = "widget_pending_commands_v1"
}

public enum WidgetSnapshotStore {
    static var defaults: UserDefaults? {
        UserDefaults(suiteName: WidgetBridgeConstants.appGroupID)
    }

    // MARK: - 快照读写

    public static func load() -> WidgetSnapshot {
        guard let defaults,
              let data = defaults.data(forKey: WidgetBridgeConstants.snapshotKey),
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else {
            return .empty
        }
        return snapshot
    }

    public static func save(_ snapshot: WidgetSnapshot) {
        guard let defaults,
              let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: WidgetBridgeConstants.snapshotKey)
    }

    // MARK: - 指令队列（扩展 → 主应用）

    /// 入队一条指令。返回是否真的写进了队列——扩展侧回执要用它决定说「待入账」还是「没能入队」。
    @discardableResult
    public static func enqueue(_ command: WidgetCommand) -> Bool {
        guard defaults != nil else { return false }
        return withQueueLock {
            var pending = drainCommands()
            pending.append(command)
            guard let data = try? JSONEncoder().encode(pending) else { return false }
            defaults?.set(data, forKey: WidgetBridgeConstants.commandsKey)
            return true
        }
    }

    public static func drainCommands() -> [WidgetCommand] {
        guard let defaults,
              let data = defaults.data(forKey: WidgetBridgeConstants.commandsKey),
              let commands = try? JSONDecoder().decode([WidgetCommand].self, from: data) else {
            return []
        }
        return commands
    }

    public static func clearCommands() {
        defaults?.removeObject(forKey: WidgetBridgeConstants.commandsKey)
    }

    /// 只在对应指令真正落库（save 成功）后调用：摘掉队首 count 条。
    /// 队列只由扩展侧 append，处理期间新入队的指令留在队尾等下轮对账。
    public static func removeFirst(_ count: Int) {
        guard count > 0, defaults != nil else { return }
        withQueueLock {
            let remaining = Array(drainCommands().dropFirst(count))
            guard !remaining.isEmpty else {
                defaults?.removeObject(forKey: WidgetBridgeConstants.commandsKey)
                return
            }
            if let data = try? JSONEncoder().encode(remaining) {
                defaults?.set(data, forKey: WidgetBridgeConstants.commandsKey)
            }
        }
    }

    /// 跨进程互斥：扩展的 `enqueue` 与主应用的 `removeFirst` 都是 read-modify-write，
    /// 不加锁时两侧交错会互相覆盖、丢掉刚入队的指令。
    /// 临界区只有一次小 plist 读写，最多等 50ms；拿不到锁就退回无锁执行，绝不卡住扩展进程。
    private static func withQueueLock<T>(_ body: () -> T) -> T {
        guard let base = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: WidgetBridgeConstants.appGroupID) else {
            return body()
        }
        let fd = open(base.appendingPathComponent("widget-queue.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return body() }
        defer { close(fd) }

        var acquired = false
        for _ in 0..<10 {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                acquired = true
                break
            }
            usleep(5_000)
        }
        defer { if acquired { flock(fd, LOCK_UN) } }
        return body()
    }

    // MARK: - 扩展侧本地快照突变（让桌面组件即时反映操作，主应用稍后对账）

    public static func applyCompletionLocally(id: UUID) {
        var snapshot = load()
        snapshot.topTodos.removeAll { $0.id == id }
        snapshot.parcels.removeAll { $0.id == id }
        save(snapshot)
    }

    public static func applyExpenseLocally(amount: Double) {
        var snapshot = load()
        snapshot.todayExpense += amount
        save(snapshot)
    }

    public static func applyWaterLocally(effectiveML: Double) {
        var snapshot = load()
        snapshot.todayWaterML += effectiveML
        save(snapshot)
    }

    public static func applyMoodLocally(mood: Int, energy: Int, stress: Int) {
        var snapshot = load()
        snapshot.todayMood = MoodCheckInSummary(mood: mood, energy: energy, stress: stress)
        save(snapshot)
    }

    /// 服药打卡的乐观更新。
    ///
    /// **必须同步更新汇总数字**，否则用户点完「服药」桌面仍显示「待服 2 项」，
    /// 直到打开 App 才对上——用户会以为没点上而重复点击。
    ///
    /// 计数口径与 Core 的 `MedicationDoseProgress` 一致：
    /// 待服数逐条减 1（不越界），已服数加 1（不超应服数）。
    public static func applyMedicationTakenLocally(planID: UUID) {
        var snapshot = load()
        guard let idx = snapshot.medications.firstIndex(where: { $0.id == planID }) else { return }
        snapshot.medications[idx].isTakenToday = true
        snapshot.medications[idx].activeTodoID = nil
        snapshot.medications[idx].takenCount = min(
            snapshot.medications[idx].scheduledCount,
            snapshot.medications[idx].takenCount + 1
        )

        if var summary = snapshot.medicationSummary {
            summary.takenDoseLowerBound = min(
                summary.scheduledDoseCount,
                summary.takenDoseLowerBound + 1
            )
            // 待服数逐条减，**不用差值推**：差值会把已服完的计划算成还有 2 剂待服
            // → 虚报 → 用户重复服药。
            summary.pendingDoseCount = max(0, summary.pendingDoseCount - 1)
            if summary.pendingPlanCount > 0 {
                summary.pendingPlanCount -= 1
            }
            summary.isAllSatisfied = summary.pendingPlanCount == 0
            snapshot.medicationSummary = summary
        }
        save(snapshot)
    }

    /// 周期打卡完成的乐观更新（同步汇总里的待打卡数）。
    public static func applyHabitCompletedLocally(habitID: UUID) {
        var snapshot = load()
        guard let idx = snapshot.habits.firstIndex(where: { $0.id == habitID }) else { return }
        snapshot.habits[idx].isDueToday = false

        if var summary = snapshot.habitSummary {
            if summary.dueCount > 0 {
                summary.dueCount -= 1
            }
            snapshot.habitSummary = summary
        }
        save(snapshot)
    }
}

/// 进程判断：主应用进程 vs 扩展进程
public enum WidgetProcess {
    public static var isAppProcess: Bool {
        !Bundle.main.bundlePath.hasSuffix(".appex")
    }
}
