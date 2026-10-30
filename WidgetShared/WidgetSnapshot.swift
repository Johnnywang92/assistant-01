import Darwin
import Foundation

/// 主应用与小组件/实时活动扩展共享的数据层。
/// 出于数据安全考虑（P0：密码库、证件等敏感数据绝不进扩展），
/// 这里只承载用户主动展示的待办/快递/今日支出轻量快照，
/// 以及扩展产生的"待同步指令队列"，由主应用在启动/回前台时对账落库。
public enum WidgetBridgeConstants {
    /// App Group 标识（免费 Personal Team 可用）
    public static let appGroupID = "group.com.yifanwang.assistant01"
    static let snapshotKey = "widget_shared_snapshot_v1"
    static let commandsKey = "widget_pending_commands_v1"
}

/// 快照中的单条待办/快递条目（Codable 轻量结构，避免扩展直接查询 SwiftData）
public struct WidgetTodoEntry: Codable, Hashable, Identifiable {
    public var id: UUID
    public var title: String
    public var typeRaw: String
    public var pickupCode: String?
    public var stationName: String?
    public var dueAt: Date?
    public var isRecurring: Bool

    public init(id: UUID, title: String, typeRaw: String,
                pickupCode: String? = nil, stationName: String? = nil,
                dueAt: Date? = nil, isRecurring: Bool = false) {
        self.id = id
        self.title = title
        self.typeRaw = typeRaw
        self.pickupCode = pickupCode
        self.stationName = stationName
        self.dueAt = dueAt
        self.isRecurring = isRecurring
    }
}

/// 今日练习快照条目：来自最近活跃的一条技能学习路径
public struct WidgetPracticeEntry: Codable, Hashable {
    public var pathID: UUID
    /// 技能名（如「学吉他」）
    public var title: String
    /// 当前阶段名
    public var stageName: String
    /// 连续打卡天数
    public var streakDays: Int
    /// 本周已练习分钟数
    public var minutesThisWeek: Int
    /// 每周目标分钟数
    public var weeklyTargetMinutes: Int
    /// 今天是否已打卡
    public var isPracticedToday: Bool

    public init(pathID: UUID, title: String, stageName: String, streakDays: Int,
                minutesThisWeek: Int, weeklyTargetMinutes: Int, isPracticedToday: Bool) {
        self.pathID = pathID
        self.title = title
        self.stageName = stageName
        self.streakDays = streakDays
        self.minutesThisWeek = minutesThisWeek
        self.weeklyTargetMinutes = weeklyTargetMinutes
        self.isPracticedToday = isPracticedToday
    }
}

/// 桌面小组件使用的共享快照
public struct WidgetSnapshot: Codable, Hashable {
    /// 今日高优待办（紧急性+重要性排序，最多 6 条）
    public var topTodos: [WidgetTodoEntry]
    /// 待取快递（含取件码的活跃快递/退货待办）
    public var parcels: [WidgetTodoEntry]
    /// 今日支出合计（用于小号组件"今日支出"速览）
    public var todayExpense: Double
    /// 今日练习（最近活跃的学习路径；无进行中路径时为 nil）
    public var todayPractice: WidgetPracticeEntry?
    public var generatedAt: Date

    public static let empty = WidgetSnapshot(
        topTodos: [], parcels: [], todayExpense: 0, todayPractice: nil, generatedAt: .distantPast
    )

    public init(topTodos: [WidgetTodoEntry], parcels: [WidgetTodoEntry], todayExpense: Double,
                todayPractice: WidgetPracticeEntry? = nil, generatedAt: Date) {
        self.topTodos = topTodos
        self.parcels = parcels
        self.todayExpense = todayExpense
        self.todayPractice = todayPractice
        self.generatedAt = generatedAt
    }
}

/// 扩展产生的待同步指令，主应用回前台后按序执行并入快照
public enum WidgetCommand: Codable, Hashable {
    case completeTodo(UUID)
    /// minutes: 10 / 60 / 1440(明早9点单独编码为 snoozeTomorrow)
    case snoozeTodo(UUID, Int)
    case snoozeTomorrow(UUID)
    case toggleDeparture(UUID, Bool)
    case quickAddExpense(String)
    case quickAddTodo(String)
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
}

/// 进程判断：主应用进程 vs 扩展进程
public enum WidgetProcess {
    public static var isAppProcess: Bool {
        !Bundle.main.bundlePath.hasSuffix(".appex")
    }
}
