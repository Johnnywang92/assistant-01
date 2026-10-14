import EventKit
import Foundation

/// 系统日历错误类型
public enum CalendarError: LocalizedError {
    case permissionDenied
    case noDefaultCalendar

    public var errorDescription: String? {
        switch self {
        case .permissionDenied: return "未获得系统日历读写权限"
        case .noDefaultCalendar: return "系统未找到可用默认日历"
        }
    }
}

/// 系统日历双向接入：支持读取未来日程，以及将待办/日程事项写入或同步至系统日历。
@MainActor
final class CalendarAgendaService: ObservableObject {
    static let shared = CalendarAgendaService()

    struct AgendaEvent: Identifiable, Equatable {
        let id: String
        let title: String
        let startDate: Date
        let endDate: Date
        let isAllDay: Bool
        let location: String?
        let calendarTitle: String?
    }

    enum LoadResult: Equatable {
        case loaded
        case unavailable
        case denied
    }

    @Published private(set) var events: [AgendaEvent] = []
    @Published private(set) var result: LoadResult?
    @Published private(set) var isLoading = false

    private let store = EKEventStore()

    private init() {}

    /// 请求系统日历完整访问权限
    func requestAccessIfNeeded() async throws -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .notDetermined {
            return try await store.requestFullAccessToEvents()
        }
        return status == .fullAccess
    }

    /// 加载未来日程（默认 7 天窗口：今天 0 点起算至未来 7 天）
    func loadEvents(daysAhead: Int = 7) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let granted = try await requestAccessIfNeeded()
            guard granted else {
                result = .denied
                events = []
                return
            }
        } catch {
            result = .unavailable
            events = []
            return
        }

        let calendar = Calendar.current
        let start = calendar.startOfDay(for: .now)
        guard let end = calendar.date(byAdding: .day, value: max(1, daysAhead), to: start) else {
            result = .unavailable
            return
        }

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        events = store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .map {
                AgendaEvent(
                    id: $0.eventIdentifier ?? UUID().uuidString,
                    title: $0.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? $0.title : "未命名日程",
                    startDate: $0.startDate,
                    endDate: $0.endDate,
                    isAllDay: $0.isAllDay,
                    location: $0.location?.trimmingCharacters(in: .whitespacesAndNewlines),
                    calendarTitle: $0.calendar.title
                )
            }
        result = .loaded
    }

    /// 兼容旧调用点（今天日程）
    func loadTodayEvents() async {
        await loadEvents(daysAhead: 7)
    }

    /// 将待办事项保存或更新到系统日历
    /// - Parameters:
    ///   - title: 日程标题
    ///   - startDate: 开始时间
    ///   - endDate: 结束时间（如无指定，默认开始时间后 1 小时）
    ///   - notes: 备注/详情
    ///   - location: 地点
    ///   - existingIdentifier: 若此前已写入过日历，传入原有 eventIdentifier 以进行就地更新
    /// - Returns: 保存成功后的 EKEvent.eventIdentifier
    @discardableResult
    func saveEvent(
        title: String,
        startDate: Date,
        endDate: Date? = nil,
        notes: String? = nil,
        location: String? = nil,
        existingIdentifier: String? = nil
    ) async throws -> String {
        let granted = try await requestAccessIfNeeded()
        guard granted else {
            throw CalendarError.permissionDenied
        }

        let event: EKEvent
        if let id = existingIdentifier, let existing = store.event(withIdentifier: id) {
            event = existing
        } else {
            event = EKEvent(eventStore: store)
            guard let defaultCal = store.defaultCalendarForNewEvents else {
                throw CalendarError.noDefaultCalendar
            }
            event.calendar = defaultCal
        }

        event.title = title
        event.startDate = startDate
        event.endDate = endDate ?? startDate.addingTimeInterval(3600)
        event.notes = notes
        event.location = location

        try store.save(event, span: .thisEvent)
        return event.eventIdentifier
    }

    /// 从系统日历中删除日程（例如待办被删除时，清理对应日历日程，防止孤儿日程）
    func deleteEvent(identifier: String) async throws {
        let granted = try await requestAccessIfNeeded()
        guard granted else {
            throw CalendarError.permissionDenied
        }

        if let event = store.event(withIdentifier: identifier) {
            try store.remove(event, span: .thisEvent)
        }
    }
}
