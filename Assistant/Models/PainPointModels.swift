import Foundation
import SwiftData

/// 订阅与自动续费模型（痛点：免费试用忘记取消、悄悄扣费）
@Model
public final class SubscriptionItem {
    public var id: UUID
    public var name: String                // 服务名称，如 "iCloud+", "视频会员"
    public var priceString: String         // 金额，如 "¥15/月"
    public var nextBillingDate: Date       // 下次扣费日期
    public var remindDaysBefore: Int       // 提前几天提醒（如提前 2 天）
    public var isAutoRenew: Bool           // 是否自动续费
    public var notes: String?              // 备注，如 "免费试用7天，记得第6天退订"

    public init(
        name: String,
        priceString: String,
        nextBillingDate: Date,
        remindDaysBefore: Int = 2,
        isAutoRenew: Bool = true,
        notes: String? = nil
    ) {
        self.id = UUID()
        self.name = name
        self.priceString = priceString
        self.nextBillingDate = nextBillingDate
        self.remindDaysBefore = remindDaysBefore
        self.isAutoRenew = isAutoRenew
        self.notes = notes
    }
}

/// 证件、卡券与物品保质期模型（痛点：身份证/护照/优惠券/食品药品过期才发现）
@Model
public final class ItemExpiryItem {
    public var id: UUID
    public var title: String               // 物品或证件名，如 "护照", "眼药水开封", "山姆牛奶"
    public var category: String            // 类别：证件/卡券/开封食品/药品
    public var expireDate: Date            // 过期/失效日期
    public var remindDaysBefore: Int       // 提前几天预警
    public var isResolved: Bool

    public init(
        title: String,
        category: String = "日常用品",
        expireDate: Date,
        remindDaysBefore: Int = 7
    ) {
        self.id = UUID()
        self.title = title
        self.category = category
        self.expireDate = expireDate
        self.remindDaysBefore = remindDaysBefore
        self.isResolved = false
    }
}
