import Foundation

// MARK: - 睡眠夜样本与「夜」时间轴（纯规则，不碰 HealthKit / SwiftData）

/// 「夜」的归属：以 12:00 为界——`nightKey` 当日 12:00 → 次日 12:00。
/// 例：10-28 23:30 入睡、10-29 07:00 醒来，同属 `nightKey = 10-28` 这一夜。
/// 凌晨重算只覆盖本夜，identifier 归属才有唯一答案。
///
/// 时刻的内部表示 `offset` = 距该夜 12:00 的**墙上时钟**分钟数，范围 `[0, 1440)`：
/// `23:45 → 705`、`00:00 → 720`、`00:30 → 750`。
/// 跨 0 点的样本取中位数不会翻转到中午（23:50 与 00:10 的中位是 00:00，不是 12:00）。
///
/// offset ↔ Date 一律走**日历分量换算**（见 `date(nightKey:offset:)`），
/// 绝不用「12:00 + offset×60 秒」——后者在 DST 切换日或跨时区时会偏一小时。
public struct SleepNightSample: Equatable, Sendable {
    /// 夜归属日（该日 00:00，经日历归一）
    public let nightKey: Date
    /// 入睡时刻 offset：当夜**最长连续睡眠段**的 start。
    /// 傍晚沙发小睡、夜醒后的新片段都不会污染锚点。
    public let onsetOffset: Int
    /// 当夜**总** asleep 分钟（多源合并重叠区间后求和，沿用 `sleepHours` 口径，不含 `inBed`）。
    /// 睡眠债只用这个字段——用最长段时长会把夜醒多的人系统性判成欠债。
    public let asleepMinutes: Int

    public init(nightKey: Date, onsetOffset: Int, asleepMinutes: Int) {
        self.nightKey = nightKey
        self.onsetOffset = onsetOffset
        self.asleepMinutes = asleepMinutes
    }
}

/// 睡眠夜的归一化与时间轴换算纯规则。
public enum SleepNightNormalizer {

    // MARK: 时间轴

    /// 任意时刻 → 所属夜的 nightKey（当日 12:00 前归昨日，含 12:00 整归今日）。
    public static func nightKey(for date: Date, calendar: Calendar) -> Date {
        let dayStart = calendar.startOfDay(for: date)
        guard let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: dayStart) else {
            return dayStart
        }
        if date < noon,
           let yesterday = calendar.date(byAdding: .day, value: -1, to: dayStart) {
            return yesterday
        }
        return dayStart
    }

    /// 时刻 → 夜内 offset（距该夜 12:00 的墙上时钟分钟数，`[0, 1440)`）。
    /// 日期不属于该夜窗口时返回 nil。
    public static func offset(of date: Date, nightKey: Date, calendar: Calendar) -> Int? {
        let key = self.nightKey(for: date, calendar: calendar)
        guard key == calendar.startOfDay(for: nightKey) else { return nil }
        let wall = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        let dayShift = calendar.isDate(date, inSameDayAs: key) ? 0 : 1
        let value = dayShift * 1440 + wall - 720
        return (0..<1440).contains(value) ? value : nil
    }

    /// 夜内 offset → 墙上时钟 (hour, minute)。
    public static func wallClock(of offset: Int) -> (hour: Int, minute: Int) {
        let wall = (720 + offset) % 1440
        return (wall / 60, wall % 60)
    }

    /// offset → Date。经日历分量换算（nightKey 当日/次日 + hour/minute），DST 安全。
    public static func date(nightKey: Date, offset: Int, calendar: Calendar) -> Date? {
        guard (0..<1440).contains(offset) else { return nil }
        let dayShift = offset >= 720 ? 1 : 0
        let (hour, minute) = wallClock(of: offset)
        guard let base = calendar.date(byAdding: .day, value: dayShift, to: calendar.startOfDay(for: nightKey)) else {
            return nil
        }
        var comps = calendar.dateComponents([.year, .month, .day], from: base)
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        return calendar.date(from: comps)
    }

    /// "HH:mm" → offset（距当日 12:00 的分钟数）。供「期望就寝时间」等设置项持久化互转。
    /// 约定：HH:mm ≥ 12:00 视为当夜（23:00 → 660），HH:mm < 12:00 视为次日凌晨（00:30 → 750）。
    public static func offset(hourMinute: String) -> Int? {
        let parts = hourMinute.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) else { return nil }
        let wall = parts[0] * 60 + parts[1]
        return wall >= 720 ? wall - 720 : wall + 720
    }

    /// offset → "HH:mm"（设置项展示用）。
    public static func hourMinute(offset: Int) -> String {
        let (h, m) = wallClock(of: offset)
        return String(format: "%02d:%02d", h, m)
    }

    // MARK: 样本归一化

    /// 把一夜的原始 asleep 区间（可多来源、可重叠、可碎片）归一成 `SleepNightSample`。
    /// - 区间先裁剪到夜窗口（当日 12:00 → 次日 12:00），再合并重叠/相邻区间（多源去重）；
    /// - `asleepMinutes` = 合并后总时长（物理经过时间，沿用 `sleepHours` 口径）；
    /// - `onsetOffset` = **最长**连续段的 start（并列取更早者）；
    /// - 窗口内没有任何 asleep 区间 → nil（该夜无数据，不是 0 分钟）。
    public static func sample(
        nightKey: Date,
        segments: [(start: Date, end: Date)],
        calendar: Calendar
    ) -> SleepNightSample? {
        guard let windowStart = date(nightKey: nightKey, offset: 0, calendar: calendar),
              let lastMinute = date(nightKey: nightKey, offset: 1439, calendar: calendar),
              let windowEndExclusive = calendar.date(byAdding: .minute, value: 1, to: lastMinute) else {
            return nil
        }

        // 1. 裁剪到夜窗口
        var clipped: [(start: Date, end: Date)] = []
        for seg in segments {
            let start = max(seg.start, windowStart)
            let end = min(seg.end, windowEndExclusive)
            if end > start {
                clipped.append((start, end))
            }
        }
        guard !clipped.isEmpty else { return nil }

        // 2. 按 start 排序并合并重叠/相邻区间（多数据源重叠只算一次）
        clipped.sort { $0.start < $1.start }
        var merged: [(start: Date, end: Date)] = []
        for seg in clipped {
            if var last = merged.last, seg.start <= last.end {
                last.end = max(last.end, seg.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(seg)
            }
        }

        // 3. 总时长（物理经过时间）+ 最长段起点
        let totalMinutes = Int(merged.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) } / 60.0)
        guard totalMinutes > 0 else { return nil }
        let longest = merged.max { a, b in
            let da = a.end.timeIntervalSince(a.start)
            let db = b.end.timeIntervalSince(b.start)
            if da == db { return a.start > b.start } // 并列取更早者
            return da < db
        }
        guard let longest,
              let onset = offset(of: longest.start, nightKey: nightKey, calendar: calendar) else {
            return nil
        }
        return SleepNightSample(nightKey: calendar.startOfDay(for: nightKey), onsetOffset: onset, asleepMinutes: totalMinutes)
    }
}
