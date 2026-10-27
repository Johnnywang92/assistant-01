import XCTest
@testable import AssistantCore

/// 万条级规模实测。
///
/// 这些用例不是「跑得通」的断言，而是**性能闸门**：
/// 待办页与全景搜索都按「边操作边出结果」的量级设计，
/// 一旦某个派生环节退化成平方级，用户感知就是「卡一下再刷出来」。
/// 预算给得宽松（真正常见耗时在毫秒级），但足以拦住数量级的退化。
final class ScaleBenchmarkTests: XCTestCase {

    /// 造一批待办快照：混合逾期 / 今天 / 本周 / 无日期
    private func makeSnapshots(count: Int, now: Date) -> [TodoTimeSnapshot] {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        var snapshots: [TodoTimeSnapshot] = []
        snapshots.reserveCapacity(count)
        for index in 0..<count {
            let bucket = index % 5
            let dueAt: Date?
            switch bucket {
            case 0: dueAt = startOfToday.addingTimeInterval(-86_400 * 3)          // 逾期
            case 1: dueAt = startOfToday.addingTimeInterval(3_600 * 10)           // 今天
            case 2: dueAt = startOfToday.addingTimeInterval(86_400 * 3)           // 本周
            case 3: dueAt = nil                                                    // 无日期
            default: dueAt = startOfToday.addingTimeInterval(86_400 * 30)          // 很久以后
            }
            snapshots.append(TodoTimeSnapshot(
                dueAt: dueAt,
                createdAt: startOfToday.addingTimeInterval(-86_400 * Double(index % 30)),
                isDone: index % 17 == 0
            ))
        }
        return snapshots
    }

    /// 一万条待办的时间分桶耗时
    func testTimeBucketingTenThousandItemsIsFast() {
        let now = Date()
        let snapshots = makeSnapshots(count: 10_000, now: now)
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)

        let started = CFAbsoluteTimeGetCurrent()
        let buckets = TodoTimeAggregator.bucket(snapshots, now: now)
        let elapsed = CFAbsoluteTimeGetCurrent() - started

        XCTAssertLessThan(elapsed, 0.5, "1 万条分桶耗时 \(elapsed)s，超出可接受范围")

        // 分桶互斥：同一条待办不能同时落进两个桶，否则首页角标数会大于详情长度
        let allIDs = buckets.overdue + buckets.today + buckets.thisWeek
        XCTAssertEqual(Set(allIDs).count, allIDs.count, "分桶出现重复条目")
        // 已完成的事项不进任何桶
        let doneIDs = Set(snapshots.filter(\.isDone).map(\.id))
        XCTAssertTrue(allIDs.allSatisfy { !doneIDs.contains($0) })
        // 逾期桶的口径：生效时间早于今天零点的未完成事项
        let expectedOverdue = snapshots.filter {
            !$0.isDone && ($0.effectiveDate ?? .distantFuture) < startOfToday
        }
        XCTAssertEqual(buckets.overdue.count, expectedOverdue.count)
    }

    /// 一万条待办的搜索过滤耗时（不含排序，排序另有 SearchRelevance 用例覆盖）
    func testFilteringTenThousandItemsIsFast() {
        let now = Date()
        let snapshots = makeSnapshots(count: 10_000, now: now)
        let keyword = "2024"

        let started = CFAbsoluteTimeGetCurrent()
        let hits = snapshots.filter { snapshot in
            snapshot.id.uuidString.contains(keyword)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - started

        XCTAssertLessThan(elapsed, 0.5, "1 万条过滤耗时 \(elapsed)s，超出可接受范围")
        XCTAssertLessThanOrEqual(hits.count, snapshots.count)
    }

    /// 万条规模下的搜索排序（命中判定 + 排序）耗时
    func testRankingTenThousandItemsIsFast() {
        let now = Date()
        let candidates = makeSnapshots(count: 10_000, now: now).enumerated().map { index, snapshot in
            SearchCandidate(
                id: snapshot.id,
                title: index % 50 == 0 ? "取快递" : "日常事项 \(index)",
                detail: "详情 \(index)",
                date: now.addingTimeInterval(-Double(index))
            )
        }

        // 预热 ICU（一次性冷启动开销不计入稳态耗时）
        _ = SearchRelevance.rank([candidates[0]], query: "取快递", limit: 1)

        let started = CFAbsoluteTimeGetCurrent()
        let ranked = SearchRelevance.rank(candidates, query: "取快递", limit: 20)
        let elapsed = CFAbsoluteTimeGetCurrent() - started

        XCTAssertEqual(ranked.count, 20)
        XCTAssertLessThan(elapsed, 0.5, "1 万条排序耗时 \(elapsed)s，超出可接受范围")
    }
}
