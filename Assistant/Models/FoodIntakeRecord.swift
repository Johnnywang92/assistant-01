import Foundation
import SwiftData

/// 一条饮食热量记录（由食物照片估算生成）。
///
/// ## 数据性质
/// 记录里的热量是**估算值**，不是精确值。三个主要误差来源：
/// 1. 照片识别本身可能认错（沙拉这类只认出泛类「food」的情况很常见）；
/// 2. 份量靠猜——同样的菜，不同盘子的量差一倍很常见；
/// 3. 做法差异（油盐用量）无法从照片判断。
///
/// 所以模型里同时保存了**原始估算**与**用户确认后的最终值**，
/// 并记录用户是否做过手动调整——这样以后回看时，
/// 不会把「用户确认过的数字」和「机器猜的数字」混为一谈。
@Model
public final class FoodIntakeRecord {
    public var id: UUID
    /// 用餐时间（用户可改）
    public var date: Date
    /// 食物名称（中文，如「披萨」）
    public var foodName: String
    /// 食物 id（对应 `FoodCatalog` 中的条目；手动输入的自定义食物为 nil）
    public var foodID: String?
    /// 份量档位 rawValue（`FoodPortion.rawValue`）
    public var portionRaw: String
    /// **整份**的估算热量（千卡）
    public var fullPortionCalories: Double
    /// 吃掉的比例 0...1
    public var consumedRatio: Double
    /// **实际摄入**热量（千卡）= 整份热量 × 吃掉比例
    public var consumedCalories: Double
    /// 识别置信度 0...1
    public var confidence: Double
    /// 用户是否手动调整过（份量/比例/食物）
    public var isManuallyAdjusted: Bool
    /// 估算来源：vision（照片识别）/ manual（手动录入）
    public var sourceRaw: String
    public var createdAt: Date
    /// 照片缩略图（压缩后存储，避免撑大数据库）
    @Attribute(.externalStorage)
    public var imageData: Data?

    public init(
        date: Date = .now,
        foodName: String,
        foodID: String? = nil,
        portion: FoodPortion = .regular,
        fullPortionCalories: Double,
        consumedRatio: Double = 1.0,
        confidence: Double = 0.5,
        isManuallyAdjusted: Bool = false,
        source: FoodIntakeSource = .vision,
        imageData: Data? = nil
    ) {
        self.id = UUID()
        self.date = date
        self.foodName = foodName
        self.foodID = foodID
        self.portionRaw = portion.rawValue
        self.fullPortionCalories = fullPortionCalories
        self.consumedRatio = consumedRatio
        self.consumedCalories = fullPortionCalories * consumedRatio
        self.confidence = confidence
        self.isManuallyAdjusted = isManuallyAdjusted
        self.sourceRaw = source.rawValue
        self.createdAt = .now
        self.imageData = imageData
    }

    public var portion: FoodPortion {
        get { FoodPortion(rawValue: portionRaw) ?? .regular }
        set { portionRaw = newValue.rawValue }
    }

    public var source: FoodIntakeSource {
        get { FoodIntakeSource(rawValue: sourceRaw) ?? .vision }
        set { sourceRaw = newValue.rawValue }
    }

    /// 是否为低置信度估算（认不准的记录在列表里需要额外标注）
    public var isLowConfidence: Bool {
        confidence < 0.35
    }
}

/// 饮食记录来源。
public enum FoodIntakeSource: String, Codable, CaseIterable, Sendable {
    /// 由照片估算
    case vision
    /// 用户手动录入
    case manual

    public var displayName: String {
        switch self {
        case .vision: return "照片估算"
        case .manual: return "手动录入"
        }
    }

    public var iconName: String {
        switch self {
        case .vision: return "camera.viewfinder"
        case .manual: return "hand.point.up.left"
        }
    }
}
