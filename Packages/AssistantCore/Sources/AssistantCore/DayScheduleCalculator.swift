import Foundation

// MARK: - 当日节奏：唯一一份窗口 / 占用 / 空闲计算
//
// 首页节奏条（`HomeSnapshotBuilder`）与今日时间轴（`DayTimelineView.buildFreeSlots`）
// 必须共用这里的计算结果。此前两边各写一套，会出现「同一天首页说剩余 4h、
// 时间轴说 3h30m」这种最难发现的静默偏差。
//
// 规则（与原 DayTimelineView 保持一致）：
// - 窗口 = 起床 → 下班，终点不含；全天日程不占时间。
// - 占用区间先裁剪进窗口再合并重叠，避免同一小时被扣两次。
// - 空闲段起点对齐到 now，且只保留 >= minFreeSlotMinutes 的整段。
// - 时间带色块按**整个窗口**的比例切分，视图不得硬编码像素宽度。

public struct DayFreeSlot: Hashable, Sendable {
    public let start: Date
    public let end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    public var durationMinutes: Int {
        max(0, Int(end.timeIntervalSince(start) / 60))
    }
}

public struct DaySchedulePlan: Hashable, Sendable {
    public let freeSlots: [DayFreeSlot]
    public let freeMinutes: Int
    public let segments: [HomeTimelineSlice]

    public init(
        freeSlots: [DayFreeSlot],
        freeMinutes: Int,
        segments: [HomeTimelineSlice]
    ) {
        self.freeSlots = freeSlots
        self.freeMinutes = freeMinutes
        self.segments = segments
    }

    public static let empty = DaySchedulePlan(
        freeSlots: [],
        freeMinutes: 0,
        segments: [HomeTimelineSlice(segment: .free, weight: 1)]
    )
}

public enum DayScheduleCalculator {

    /// - Parameters:
    ///   - schedule: 当日窗口与占用事实（由 App 层从 EventKit / 待办 / 服药 / 习惯组装）
    ///   - now: 参照时刻；空闲段起点对齐到这里
    ///   - minFreeSlotMinutes: 小于该长度的空档不计入空闲（与今日时间轴一致）
    public static func make(
        schedule: HomeScheduleFact,
        now: Date = .now,
        minFreeSlotMinutes: Int = 30
    ) -> DaySchedulePlan {
        guard schedule.hasSchedule, schedule.windowEnd > schedule.windowStart else {
            return .empty
        }
        let span = schedule.windowEnd.timeIntervalSince(schedule.windowStart)
        let busy = mergedBusy(schedule: schedule)

        var freeSlots: [DayFreeSlot] = []
        var cursor = schedule.windowStart
        for interval in busy {
            if interval.start > cursor {
                appendFreeSlot(
                    from: cursor,
                    to: interval.start,
                    now: now,
                    minimum: minFreeSlotMinutes,
                    into: &freeSlots
                )
            }
            cursor = max(cursor, interval.end)
        }
        if cursor < schedule.windowEnd {
            appendFreeSlot(
                from: cursor,
                to: schedule.windowEnd,
                now: now,
                minimum: minFreeSlotMinutes,
                into: &freeSlots
            )
        }

        return DaySchedulePlan(
            freeSlots: freeSlots,
            freeMinutes: freeSlots.reduce(0) { $0 + $1.durationMinutes },
            segments: slices(
                schedule: schedule,
                busy: busy,
                span: span
            )
        )
    }

    // MARK: - 占用合并

    private static func mergedBusy(schedule: HomeScheduleFact) -> [HomeBusyInterval] {
        let clipped: [HomeBusyInterval] = schedule.busy.compactMap { interval in
            let start = max(interval.start, schedule.windowStart)
            let end = min(interval.end, schedule.windowEnd)
            guard end > start else { return nil }
            return HomeBusyInterval(start: start, end: end)
        }
        .sorted { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            return lhs.end < rhs.end
        }

        var merged: [HomeBusyInterval] = []
        for interval in clipped {
            if let last = merged.last, interval.start <= last.end {
                merged[merged.count - 1] = HomeBusyInterval(
                    start: last.start,
                    end: max(last.end, interval.end)
                )
            } else {
                merged.append(interval)
            }
        }
        return merged
    }

    private static func appendFreeSlot(
        from start: Date,
        to end: Date,
        now: Date,
        minimum: Int,
        into slots: inout [DayFreeSlot]
    ) {
        let clampedStart = max(start, now)
        guard end.timeIntervalSince(clampedStart) / 60 >= Double(minimum) else { return }
        slots.append(DayFreeSlot(start: clampedStart, end: end))
    }

    // MARK: - 时间带（比例，不是像素）

    private struct MarkedInterval {
        let start: Date
        let end: Date
        let segment: HomeTimelineSegment
    }

    private static func slices(
        schedule: HomeScheduleFact,
        busy: [HomeBusyInterval],
        span: TimeInterval
    ) -> [HomeTimelineSlice] {
        guard span > 0 else { return [HomeTimelineSlice(segment: .free, weight: 1)] }

        var marks: [MarkedInterval] = busy.map {
            MarkedInterval(start: $0.start, end: $0.end, segment: .busy)
        }
        // 提醒点画成窄段，宽度同样按窗口比例推导（约 2.4% 窗口）。
        let halfMark = span * 0.012
        for point in schedule.reminders
        where point >= schedule.windowStart && point < schedule.windowEnd {
            let start = max(schedule.windowStart, point.addingTimeInterval(-halfMark))
            let end = min(schedule.windowEnd, point.addingTimeInterval(halfMark))
            guard end > start else { continue }
            marks.append(MarkedInterval(start: start, end: end, segment: .reminder))
        }
        marks.sort { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            // 同起点时提醒优先，避免提醒点被整段蓝色盖住
            if lhs.segment != rhs.segment { return lhs.segment == .reminder }
            return lhs.end < rhs.end
        }

        var raw: [MarkedInterval] = []
        var cursor = schedule.windowStart
        for mark in marks {
            let start = max(schedule.windowStart, min(mark.start, schedule.windowEnd))
            let end = max(start, min(mark.end, schedule.windowEnd))
            guard end > cursor else { continue }
            if start > cursor {
                raw.append(MarkedInterval(start: cursor, end: start, segment: .free))
            }
            raw.append(MarkedInterval(start: max(cursor, start), end: end, segment: mark.segment))
            cursor = end
        }
        if cursor < schedule.windowEnd {
            raw.append(MarkedInterval(start: cursor, end: schedule.windowEnd, segment: .free))
        }

        var merged: [MarkedInterval] = []
        for interval in raw where interval.end > interval.start {
            if let last = merged.last, last.segment == interval.segment, last.end >= interval.start {
                merged[merged.count - 1] = MarkedInterval(
                    start: last.start,
                    end: max(last.end, interval.end),
                    segment: last.segment
                )
            } else {
                merged.append(interval)
            }
        }
        return merged.map {
            HomeTimelineSlice(
                segment: $0.segment,
                weight: $0.end.timeIntervalSince($0.start) / span
            )
        }
    }
}
