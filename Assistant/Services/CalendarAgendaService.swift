import EventKit
import Foundation

/// 系统日历只读接入。仅在用户主动展开“今日安排”时调用，避免启动时弹出权限请求。
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

    func loadTodayEvents() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .notDetermined {
            do {
                let granted = try await store.requestFullAccessToEvents()
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
        } else if status != .fullAccess {
            result = status == .denied || status == .restricted ? .denied : .unavailable
            events = []
            return
        }

        let calendar = Calendar.current
        let start = calendar.startOfDay(for: .now)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else {
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
}
