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
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        name: String,
        location: String,
        roomArea: String = "主卧",
        notes: String? = nil,
        imageData: Data? = nil
    ) {
        self.id = UUID()
        self.name = name
        self.location = location
        self.roomArea = roomArea
        self.notes = notes
        self.imageData = imageData
        self.createdAt = .now
        self.updatedAt = .now
    }
}
