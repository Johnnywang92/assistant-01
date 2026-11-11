import XCTest
@testable import AssistantCore

/// 出门清点快照的汇总口径与解码兼容测试。
///
/// 为什么要单独测：
/// 1. **计数口径**：`items` 最多只带 12 条（`buildDepartureSnapshot` 里 `prefix(12)`），
///    若用 `items.count` 当总数，会把「20 件里确认了 12 件」显示成「全部带齐」——
///    这是一个会让用户漏带东西的静默失败；
/// 2. **跨版本解码**：快照存在 App Group 里，新版本写入、老版本读取，
///    老快照缺新增字段时必须能正常解出而不是整体失败。
final class DepartureSnapshotTests: XCTestCase {

    private func item(
        _ title: String,
        checked: Bool = false,
        essential: Bool = false
    ) -> WatchDepartureItem {
        WatchDepartureItem(
            id: UUID(),
            title: title,
            isChecked: checked,
            isEssential: essential
        )
    }

    // MARK: - 汇总口径

    /// 显式给出汇总时按给定值走。
    func testExplicitCountsArePreserved() {
        let snapshot = WatchDepartureSnapshot(
            sceneName: "通勤",
            items: [item("钥匙"), item("手机")],
            checkedCount: 1,
            totalCount: 8
        )

        XCTAssertEqual(snapshot.checkedCount, 1)
        XCTAssertEqual(snapshot.totalCount, 8)
        XCTAssertEqual(snapshot.remainingCount, 7)
        XCTAssertFalse(snapshot.isAllChecked)
    }

    /// 未显式给出时按 items 现算，不返回 0。
    func testCountsFallBackToItems() {
        let snapshot = WatchDepartureSnapshot(
            sceneName: "通勤",
            items: [item("钥匙", checked: true), item("手机"), item("钱包")]
        )

        XCTAssertEqual(snapshot.checkedCount, 1)
        XCTAssertEqual(snapshot.totalCount, 3)
        XCTAssertEqual(snapshot.remainingCount, 2)
    }

    /// **关键**：items 被截断时，总数仍取全量计数，不能被截断子集带偏。
    func testTotalCountIsNotDistortedByTruncatedItems() {
        // 模拟：场景下共 20 件，快照只带了 12 条，其中 12 条都已勾
        let truncated = (0..<12).map { _ in item("物品", checked: true) }
        let snapshot = WatchDepartureSnapshot(
            sceneName: "出差",
            items: truncated,
            checkedCount: 12,
            totalCount: 20
        )

        XCTAssertEqual(snapshot.totalCount, 20)
        XCTAssertEqual(snapshot.checkedCount, 12)
        XCTAssertFalse(
            snapshot.isAllChecked,
            "20 件里只确认 12 件，不能显示成「全部带齐」"
        )
        XCTAssertEqual(snapshot.remainingCount, 8)
    }

    /// 全部勾完才算全部带齐。
    func testIsAllCheckedOnlyWhenComplete() {
        let all = WatchDepartureSnapshot(
            sceneName: "通勤",
            items: [item("钥匙", checked: true), item("手机", checked: true)],
            checkedCount: 2,
            totalCount: 2
        )
        XCTAssertTrue(all.isAllChecked)
        XCTAssertEqual(all.remainingCount, 0)

        let partial = WatchDepartureSnapshot(
            sceneName: "通勤",
            items: [item("钥匙", checked: true), item("手机")],
            checkedCount: 1,
            totalCount: 2
        )
        XCTAssertFalse(partial.isAllChecked)
    }

    /// 空清单不算「全部带齐」（否则会显示一个误导性的绿色对勾）。
    func testEmptyListIsNotAllChecked() {
        let snapshot = WatchDepartureSnapshot(sceneName: "通勤", items: [])

        XCTAssertFalse(snapshot.isAllChecked)
        XCTAssertEqual(snapshot.remainingCount, 0)
    }

    /// 计数不能为负（脏数据防御）。
    func testRemainingCountNeverNegative() {
        let snapshot = WatchDepartureSnapshot(
            sceneName: "通勤",
            items: [],
            checkedCount: 5,
            totalCount: 2
        )

        XCTAssertEqual(snapshot.remainingCount, 0)
        XCTAssertTrue(snapshot.isAllChecked)
    }

    // MARK: - 跨版本解码

    /// 老快照（缺 checkedCount / totalCount）必须能正常解出，且计数按 items 现算。
    func testLegacySnapshotWithoutCountsDecodes() throws {
        let json = """
        {
          "sceneName": "通勤",
          "items": [
            { "id": "11111111-1111-1111-1111-111111111111", "title": "钥匙", "isChecked": true, "isEssential": true },
            { "id": "22222222-2222-2222-2222-222222222222", "title": "手机", "isChecked": false, "isEssential": false }
          ]
        }
        """
        let data = Data(json.utf8)
        let snapshot = try JSONDecoder().decode(WatchDepartureSnapshot.self, from: data)

        XCTAssertEqual(snapshot.sceneName, "通勤")
        XCTAssertEqual(snapshot.items.count, 2)
        XCTAssertEqual(snapshot.checkedCount, 1)
        XCTAssertEqual(snapshot.totalCount, 2)
        XCTAssertFalse(snapshot.isAllChecked)
    }

    /// 新快照往返编解码后计数不变。
    func testFullSnapshotRoundTrip() throws {
        let snapshot = WatchDepartureSnapshot(
            sceneName: "出差",
            items: [item("身份证", checked: true, essential: true)],
            checkedCount: 1,
            totalCount: 3
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(WatchDepartureSnapshot.self, from: data)

        XCTAssertEqual(decoded.sceneName, "出差")
        XCTAssertEqual(decoded.checkedCount, 1)
        XCTAssertEqual(decoded.totalCount, 3)
        XCTAssertEqual(decoded.remainingCount, 2)
    }

    /// 嵌在 `WidgetSnapshot` 里的老快照（含 departureSnapshot 但无计数）也要能解出。
    func testWidgetSnapshotWithLegacyDepartureDecodes() throws {
        let json = """
        {
          "topTodos": [],
          "parcels": [],
          "todayExpense": 0,
          "departureSnapshot": {
            "sceneName": "通勤",
            "items": [
              { "id": "11111111-1111-1111-1111-111111111111", "title": "钥匙", "isChecked": true, "isEssential": false }
            ]
          },
          "generatedAt": 1700000000
        }
        """
        let data = Data(json.utf8)
        let snapshot = try JSONDecoder().decode(WidgetSnapshot.self, from: data)

        XCTAssertNotNil(snapshot.departureSnapshot)
        XCTAssertEqual(snapshot.departureSnapshot?.checkedCount, 1)
        XCTAssertEqual(snapshot.departureSnapshot?.totalCount, 1)
    }
}
