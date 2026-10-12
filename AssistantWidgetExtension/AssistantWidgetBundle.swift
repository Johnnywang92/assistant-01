import WidgetKit
import SwiftUI

/// 小助小组件扩展入口：桌面/锁屏交互组件 + 灵动岛实时活动
@main
struct AssistantWidgetBundle: WidgetBundle {
    var body: some Widget {
        TodayTodosWidget()
        ParcelGlanceWidget()
        PickupLiveActivity()
        TravelLiveActivity()
        DepartureChecklistLiveActivity()
    }
}

// MARK: - 共享时间线数据

struct WidgetTimelineEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct SnapshotTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> WidgetTimelineEntry {
        WidgetTimelineEntry(date: .now, snapshot: .empty)
    }

    func getSnapshot(in context: Context, completion: @escaping (WidgetTimelineEntry) -> Void) {
        completion(WidgetTimelineEntry(date: .now, snapshot: WidgetSnapshotStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WidgetTimelineEntry>) -> Void) {
        let entry = WidgetTimelineEntry(date: .now, snapshot: WidgetSnapshotStore.load())
        // 15 分钟后自动刷新；若有临近截止的待办，则提前到截止时刻刷新
        var next = Date().addingTimeInterval(15 * 60)
        if let earliestDue = entry.snapshot.topTodos.compactMap(\.dueAt).filter({ $0 > Date() }).min() {
            next = min(next, earliestDue)
        }
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

// MARK: - 通用小元素

extension View {
    /// iOS 17+ 小组件必须使用 containerBackground
    @ViewBuilder
    func widgetContainerBackground() -> some View {
        containerBackground(for: .widget) {
            Color(.systemBackground)
        }
    }
}

/// 待办行右侧的取件码小胶囊
struct PickupCodeChip: View {
    let code: String

    var body: some View {
        Text(code)
            .font(.caption.monospaced().bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.orange.opacity(0.18)))
            .foregroundStyle(.orange)
    }
}
