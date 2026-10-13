import Foundation
import SwiftData

/// 物品收纳与存放位置备忘模型（解决“我的东西放哪了”翻箱倒柜的痛点）
@Model
public final class StoredItem {
    public var id: UUID
    public var name: String                // 物品名称（如：冬季长款羽绒服、备用钥匙、露营帐篷、五金工具箱）
    public var location: String            // 详细位置（如：主卧衣柜顶层收纳箱、玄关鞋柜抽屉小木盒）
    public var roomArea: String            // 所在房间/区域（如：玄关、主卧、次卧、客厅、书房、阳台、储物间）
    public var notes: String?              // 补充备注（如：装在透明真空袋、共2件）
    @Attribute(.externalStorage)
    public var imageData: Data?            // 现场照片或储物柜实拍
    public var purchasePrice: Double?      // 购入价格（选填，用于计算日均持有成本）
    public var purchaseDate: Date?         // 购入日期（选填，为空时按建档日期计算持有天数）
    public var isSecondHand: Bool          // 是否二手购入（二手价更低，日均成本起点也更低）
    public var resalePrice: Double?        // 转卖所得（闲置物品出二手回血，摊薄实际持有成本）
    public var resoldDate: Date?           // 转卖日期（非空表示已转卖）
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        name: String,
        location: String,
        roomArea: String = "主卧",
        notes: String? = nil,
        imageData: Data? = nil,
        purchasePrice: Double? = nil,
        purchaseDate: Date? = nil,
        isSecondHand: Bool = false,
        resalePrice: Double? = nil,
        resoldDate: Date? = nil
    ) {
        self.id = UUID()
        self.name = name
        self.location = location
        self.roomArea = roomArea
        self.notes = notes
        self.imageData = imageData
        self.purchasePrice = purchasePrice
        self.purchaseDate = purchaseDate
        self.isSecondHand = isSecondHand
        self.resalePrice = resalePrice
        self.resoldDate = resoldDate
        self.createdAt = .now
        self.updatedAt = .now
    }
}

/// 家庭常备药与健康储备分类
public enum MedicineCategory: String, Codable, CaseIterable, Sendable {
    case prescription = "处方药"
    case otc = "非处方药"
    case supplement = "保健品"
    case topical = "外用药"
    case tcm = "中药"
    case vaccine = "疫苗"
    case device = "医疗器械"
    case other = "其他"

    public var icon: String {
        switch self {
        case .prescription: return "cross.case.fill"
        case .otc: return "pills.fill"
        case .supplement: return "leaf.fill"
        case .topical: return "bandage.fill"
        case .tcm: return "cup.and.saucer.fill"
        case .vaccine: return "syringe.fill"
        case .device: return "bolt.heart.fill"
        case .other: return "questionmark.circle.fill"
        }
    }

    public var displayName: String { L10n.tr(rawValue) }
}

/// 家庭常备药与健康储备模型（解决“药品易过期、急用时才发现失效、用法记不清”的痛点）
/// 归入物品收纳域：既有存放位置，又额外记录有效期与用药方法等信息。
@Model
public final class MedicineItem {
    public var id: UUID
    public var name: String                 // 药品名称（如：布洛芬、维生素C、阿莫西林）
    public var categoryRaw: String          // MedicineCategory.rawValue
    public var indications: String?         // 用途/主治（如：退烧止痛、抗菌消炎）
    public var usageMethod: String?         // 用药方法（用法用量说明，如：每日3次，饭后各1片）
    public var storageLocation: String      // 存放位置（如：客厅药箱第二层、冰箱冷藏门）
    public var roomArea: String             // 所在房间/区域（与收纳页一致）
    public var purchaseDate: Date?          // 购买/获得日期（同种药多次购买时区分批次、按先进先出使用）
    public var expiryDate: Date?            // 有效期截止（未开封标注的失效日）
    public var isOpened: Bool               // 是否已开封（开封后使用期通常更短）
    public var openedDate: Date?            // 开封日期
    public var afterOpenValidDays: Int?     // 开封后有效天数（如眼药水开封后 28 天）
    public var remainingQuantity: String?   // 剩余数量（如：约8片、半盒、1支）
    public var precautions: String?         // 注意事项/禁忌/副作用（如：司机忌服、饭后服用、避光冷藏）
    @Attribute(.externalStorage)
    public var imageData: Data?             // 药盒/说明书实拍
    public var isDisposed: Bool             // 是否已处理（用完或丢弃，不再计入过期提醒）
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        name: String,
        category: MedicineCategory = .otc,
        indications: String? = nil,
        usageMethod: String? = nil,
        storageLocation: String,
        roomArea: String = "储物间",
        purchaseDate: Date? = nil,
        expiryDate: Date? = nil,
        isOpened: Bool = false,
        openedDate: Date? = nil,
        afterOpenValidDays: Int? = nil,
        remainingQuantity: String? = nil,
        precautions: String? = nil,
        imageData: Data? = nil,
        isDisposed: Bool = false
    ) {
        self.id = UUID()
        self.name = name
        self.categoryRaw = category.rawValue
        self.indications = indications
        self.usageMethod = usageMethod
        self.storageLocation = storageLocation
        self.roomArea = roomArea
        self.purchaseDate = purchaseDate
        self.expiryDate = expiryDate
        self.isOpened = isOpened
        self.openedDate = openedDate
        self.afterOpenValidDays = afterOpenValidDays
        self.remainingQuantity = remainingQuantity
        self.precautions = precautions
        self.imageData = imageData
        self.isDisposed = isDisposed
        self.createdAt = .now
        self.updatedAt = .now
    }

    public var category: MedicineCategory {
        get { MedicineCategory(rawValue: categoryRaw) ?? .other }
        set { categoryRaw = newValue.rawValue }
    }

    /// 同种药品分组键：名称（去空白、小写）+ 类别。同一药多次购买（不同批次/有效期）归为一组。
    public var batchKey: String {
        name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) + "::" + categoryRaw
    }

    /// 实际有效截止日：已开封且设置了开封后有效天数时，与原有效期取较早者
    public var effectiveExpiryDate: Date? {
        let cal = Calendar.current
        if isOpened, let openedDate, let days = afterOpenValidDays,
           let openedExpiry = cal.date(byAdding: .day, value: days, to: openedDate) {
            if let expiryDate { return min(expiryDate, openedExpiry) }
            return openedExpiry
        }
        return expiryDate
    }

    /// 距有效截止剩余天数（负数表示已过期；无有效期返回 nil）
    public var daysUntilExpiry: Int? {
        guard let date = effectiveExpiryDate else { return nil }
        let cal = Calendar.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: .now), to: cal.startOfDay(for: date)).day
    }

    public var isExpired: Bool { (daysUntilExpiry ?? 1) < 0 }
    public var isExpiringSoon: Bool {
        guard let d = daysUntilExpiry, !isDisposed else { return false }
        return d >= 0 && d <= 30
    }
}
