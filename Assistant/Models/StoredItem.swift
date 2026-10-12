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
