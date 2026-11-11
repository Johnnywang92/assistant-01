import AssistantCore
import XCTest

@testable import AssistantCore

/// `WidgetSnapshot` 编解码的回归测试。
///
/// **为什么这个测试重要**：小组件快照存在 App Group 的 UserDefaults 里，
/// 是**跨版本**的数据 —— 老版本 App 写下的快照会被新版本小组件读，
/// 新版本写下的也会被老版本 App 读。
///
/// 而 `WidgetSnapshotStore.load()` 用 `try?` 吞掉解码错误 →
/// 解码失败时**整个小组件静默变成空白且没有任何日志**。
/// 所以新增字段必须满足：
/// 1. `init(from:)` 用 `decodeIfPresent` + 默认值，缺 key 不报错；
/// 2. 老快照（缺新字段）能正常解出。
final class WidgetSnapshotCodingTests: XCTestCase {

    private func legacyJSON() -> Data {
        // 老版本快照：只有最初的几个字段，没有 homeOverview / anniversaries
        let json = """
        {
          "topTodos": [],
          "parcels": [],
          "todayExpense": 42.5,
          "generatedAt": 1700000000
        }
        """
        return Data(json.utf8)
    }

    /// 老快照（缺新增字段）必须能正常解出，不能抛错。
    func testLegacySnapshotWithoutNewFieldsDecodes() throws {
        let snapshot = try JSONDecoder().decode(WidgetSnapshot.self, from: legacyJSON())

        XCTAssertEqual(snapshot.todayExpense, 42.5)
        XCTAssertNil(snapshot.homeOverview, "缺失字段应为 nil 而不是解码失败")
        XCTAssertTrue(snapshot.anniversaries.isEmpty)
    }

    /// 行程倒计时快照的往返编解码。
    ///
    /// 行程倒计时现在有专属小组件，快照里的 `travelSnapshot` 是它唯一的
    /// 数据来源 —— 编码/解码任一端出错，桌面组件就会静默变空白
    /// （`WidgetSnapshotStore.load()` 用 `try?` 吞掉错误）。
    func testTravelSnapshotRoundTrip() throws {
        let departure = Date(timeIntervalSince1970: 1_700_003_600)
        let snapshot = WidgetSnapshot(
            topTodos: [],
            parcels: [],
            todayExpense: 0,
            travelSnapshot: WatchTravelSnapshot(
                id: UUID(),
                title: "乘坐 G1234 前往北京",
                departureDate: departure,
                ticketSummary: "G1234 · 5车 12A",
                gate: "B12",
                place: "北京南站"
            ),
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: data)

        XCTAssertEqual(decoded.travelSnapshot?.title, "乘坐 G1234 前往北京")
        XCTAssertEqual(decoded.travelSnapshot?.departureDate, departure)
        XCTAssertEqual(decoded.travelSnapshot?.ticketSummary, "G1234 · 5车 12A")
        XCTAssertEqual(decoded.travelSnapshot?.gate, "B12")
        XCTAssertEqual(decoded.travelSnapshot?.place, "北京南站")
    }

    /// 老快照没有 travelSnapshot 字段时解出 nil，而不是解码失败。
    func testLegacySnapshotWithoutTravelSnapshotDecodes() throws {
        let snapshot = try JSONDecoder().decode(WidgetSnapshot.self, from: legacyJSON())

        XCTAssertNil(snapshot.travelSnapshot)
    }

    /// 完整快照往返编解码后字段不变。
    func testFullSnapshotRoundTrip() throws {
        let snapshot = WidgetSnapshot(
            topTodos: [],
            parcels: [],
            todayExpense: 88,
            homeOverview: WidgetHomeOverview(
                done: 2,
                total: 4,
                freeMinutes: 256,
                isAllDayFree: false,
                priorityTaskTitle: "换新电饭锅",
                freeRatio: 0.4,
                busyRatio: 0.6
            ),
            anniversaries: [
                WidgetAnniversaryEntry(
                    id: UUID(),
                    title: "结婚纪念日",
                    daysUntil: 12,
                    yearsCount: 3,
                    passedDays: 1095,
                    isLunar: false
                )
            ],
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: data)

        XCTAssertEqual(decoded.homeOverview?.done, 2)
        XCTAssertEqual(decoded.homeOverview?.total, 4)
        XCTAssertEqual(decoded.homeOverview?.freeMinutes, 256)
        XCTAssertEqual(decoded.homeOverview?.priorityTaskTitle, "换新电饭锅")
        XCTAssertEqual(decoded.homeOverview?.freeRatio, 0.4)
        XCTAssertEqual(decoded.anniversaries.count, 1)
        XCTAssertEqual(decoded.anniversaries.first?.title, "结婚纪念日")
        XCTAssertEqual(decoded.anniversaries.first?.daysUntil, 12)
    }

    /// `.empty` 必须能编解码（扩展的 placeholder 依赖它）。
    func testEmptySnapshotRoundTrip() throws {
        let data = try JSONEncoder().encode(WidgetSnapshot.empty)
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: data)

        XCTAssertNil(decoded.homeOverview)
        XCTAssertTrue(decoded.anniversaries.isEmpty)
        XCTAssertTrue(decoded.topTodos.isEmpty)
    }

    /// 首页概览的空闲文案口径：无日程写「全天空闲」，不写「0 分钟」。
    func testHomeOverviewFreeTimeTextInsideSnapshot() throws {
        let snapshot = WidgetSnapshot(
            topTodos: [],
            parcels: [],
            todayExpense: 0,
            homeOverview: WidgetHomeOverview(
                done: 0, total: 0, freeMinutes: 0,
                isAllDayFree: true, priorityTaskTitle: nil,
                freeRatio: 1, busyRatio: 0
            ),
            generatedAt: Date()
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: data)

        XCTAssertEqual(decoded.homeOverview?.freeTimeText, "全天空闲")
    }
}
