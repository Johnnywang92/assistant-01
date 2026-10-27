import XCTest
@testable import AssistantCore

/// 分享清单规则测试。
///
/// 这些规则原先藏在一个千行视图文件里，靠肉眼维护：
/// 改一个分类时很容易漏掉另一个。现在规则在 Core，可以逐条钉死。
final class TodoShareContentTests: XCTestCase {

    private var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return cal
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h)) ?? .now
    }

    private func item(
        _ title: String,
        group: TodoShareTypeGroup? = nil,
        recurring: Bool = false,
        dueAt: Date? = nil,
        override: Date? = nil,
        createdAt: Date? = nil,
        pickupCode: String? = nil,
        done: Bool = false
    ) -> TodoShareItem {
        TodoShareItem(
            id: UUID(), title: title, pickupCode: pickupCode, isDone: done,
            group: group, isRecurring: recurring, dueAt: dueAt,
            reminderOverrideAt: override,
            createdAt: createdAt ?? date(2026, 10, 1)
        )
    }

    // MARK: - 标题与分组

    func testEveryCategoryHasTitle() {
        for category in TodoShareCategory.allCases {
            XCTAssertFalse(TodoShareContent.title(for: category).isEmpty, "\(category) 缺少标题")
        }
    }

    func testCategoryGroupMapping() {
        XCTAssertEqual(TodoShareContent.groups(for: .work), [.work])
        XCTAssertEqual(TodoShareContent.groups(for: .parcel), [.parcel, .returnParcel])
        XCTAssertEqual(TodoShareContent.groups(for: .life), [.life])
        XCTAssertEqual(TodoShareContent.groups(for: .alert), [.alert])
        XCTAssertEqual(TodoShareContent.groups(for: .parenting), [.parenting])
        XCTAssertEqual(TodoShareContent.groups(for: .pet), [.pet])
        XCTAssertEqual(TodoShareContent.groups(for: .other), [.other])
        // 这三类不按类型分组过滤，交给各自规则处理
        XCTAssertTrue(TodoShareContent.groups(for: .all).isEmpty)
        XCTAssertTrue(TodoShareContent.groups(for: .general).isEmpty)
        XCTAssertTrue(TodoShareContent.groups(for: .recurring).isEmpty)
    }

    // MARK: - 筛选

    func testAllCategoryKeepsEverything() {
        let items = [item("A", group: .work), item("B", group: nil)]
        XCTAssertEqual(TodoShareContent.items(in: items, category: .all, now: date(2026, 10, 5), calendar: calendar).count, 2)
    }

    /// 不属于任何分组的事项（如普通待办）只在「全部」里出现，
    /// 不能因为分组缺失就从清单里凭空消失
    func testUngroupedItemsOnlyAppearInAll() {
        let ungrouped = item("普通待办", group: nil)
        for category in [TodoShareCategory.work, .parcel, .life, .alert, .parenting, .pet, .other] {
            let filtered = TodoShareContent.items(in: [ungrouped], category: category, now: date(2026, 10, 5), calendar: calendar)
            XCTAssertTrue(filtered.isEmpty, "\(category) 不该收下未分组事项")
        }
    }

    func testParcelCategoryIncludesReturnParcels() {
        let items = [item("快递", group: .parcel), item("退货", group: .returnParcel), item("工作", group: .work)]
        let filtered = TodoShareContent.items(in: items, category: .parcel, now: date(2026, 10, 5), calendar: calendar)
        XCTAssertEqual(filtered.count, 2)
    }

    func testRecurringCategoryFiltersByRecurrence() {
        let items = [item("每周", recurring: true), item("一次性", recurring: false)]
        let filtered = TodoShareContent.items(in: items, category: .recurring, now: date(2026, 10, 5), calendar: calendar)
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.title, "每周")
    }

    // MARK: - 今日判定

    func testIsTodayUsesOverriddenDateFirst() {
        // 截止时间在下周，但改期到今天 → 算今天
        let today = TodoShareContent.isTodayItem(
            dueAt: date(2026, 10, 20),
            reminderOverrideAt: date(2026, 10, 5),
            createdAt: date(2026, 9, 1),
            now: date(2026, 10, 5),
            calendar: calendar
        )
        XCTAssertTrue(today)
    }

    func testIsTodayExcludesFutureItems() {
        let future = TodoShareContent.isTodayItem(
            dueAt: date(2026, 10, 20),
            reminderOverrideAt: nil,
            createdAt: date(2026, 9, 1),
            now: date(2026, 10, 5),
            calendar: calendar
        )
        XCTAssertFalse(future)
    }

    /// 今天零点之前到期的算「今天该做的」——不是早就该做的
    func testIsTodayIncludesOverdueItems() {
        let overdue = TodoShareContent.isTodayItem(
            dueAt: date(2026, 10, 2),
            reminderOverrideAt: nil,
            createdAt: date(2026, 9, 1),
            now: date(2026, 10, 5),
            calendar: calendar
        )
        XCTAssertTrue(overdue)
    }

    /// 没有任何日期时看创建日
    func testIsTodayFallsBackToCreatedAt() {
        let createdToday = TodoShareContent.isTodayItem(
            dueAt: nil, reminderOverrideAt: nil,
            createdAt: date(2026, 10, 5),
            now: date(2026, 10, 5),
            calendar: calendar
        )
        XCTAssertTrue(createdToday)

        let createdEarlier = TodoShareContent.isTodayItem(
            dueAt: nil, reminderOverrideAt: nil,
            createdAt: date(2026, 10, 1),
            now: date(2026, 10, 5),
            calendar: calendar
        )
        XCTAssertFalse(createdEarlier)
    }

    /// 「今天」必须以传入的 `now` 为准，不能偷偷用墙上时钟。
    /// 否则规则里那个 `now` 形参就是个摆设——这类规则会变得完全没法单测。
    func testTodayIsRelativeToPassedNowNotWallClock() {
        // 墙上时钟的今天肯定不是 2026-10-05，但相对传入的 now 它就是「今天」
        let sameDayAsNow = TodoShareContent.isTodayItem(
            dueAt: date(2026, 10, 5),
            reminderOverrideAt: nil,
            createdAt: date(2026, 9, 1),
            now: date(2026, 10, 5),
            calendar: calendar
        )
        XCTAssertTrue(sameDayAsNow)

        // 相对传入的 now 是昨天，但相对墙上时钟可能是「今天」——
        // 规则必须听 now 的，不能被墙上时钟带偏
        let beforeNow = TodoShareContent.isTodayItem(
            dueAt: date(2026, 10, 4),
            reminderOverrideAt: nil,
            createdAt: date(2026, 9, 1),
            now: date(2026, 10, 5),
            calendar: calendar
        )
        XCTAssertTrue(beforeNow, "今天之前到期的仍算今天该做的")
    }

    func testGeneralCategoryFiltersByTodayRule() {
        let items = [
            item("今天到期", dueAt: date(2026, 10, 5)),
            item("下月到期", dueAt: date(2026, 11, 5)),
            item("无日期", dueAt: nil, createdAt: date(2026, 10, 5))
        ]
        let filtered = TodoShareContent.items(in: items, category: .general, now: date(2026, 10, 5), calendar: calendar)
        XCTAssertEqual(filtered.count, 2)
    }

    // MARK: - 分享文案

    func testEmptyShareText() {
        XCTAssertEqual(
            TodoShareTextBuilder.friendShareText(title: "我的生活清单", items: [], importURL: "x://y"),
            "【小助清单】暂无选中的事项"
        )
    }

    func testShareTextIncludesNumberingStatusAndPickupCode() {
        let items = [
            item("取快递", pickupCode: "SF123"),
            item("已完成的事", done: true)
        ]
        let text = TodoShareTextBuilder.friendShareText(title: "快递与退货清单", items: items, importURL: "assistant://import?x=1")
        XCTAssertTrue(text.contains("【小助清单】快递与退货清单"))
        XCTAssertTrue(text.contains("1. ⏳ 取快递 (取件码: SF123)"))
        XCTAssertTrue(text.contains("2. ✅ 已完成的事"))
        XCTAssertTrue(text.contains("assistant://import?x=1"))
    }

    /// 没有取件码时不能留下空括号
    func testShareTextOmitsEmptyPickupCode() {
        let text = TodoShareTextBuilder.friendShareText(title: "T", items: [item("普通事项")], importURL: "u")
        XCTAssertTrue(text.contains("1. ⏳ 普通事项\n"))
        XCTAssertFalse(text.contains("取件码"))
    }
}
