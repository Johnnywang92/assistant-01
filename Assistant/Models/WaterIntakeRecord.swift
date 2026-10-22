import AssistantCore
import Foundation
import SwiftData

/// 饮水与饮品摄入记录模型
///
/// 记录单次饮水或饮品信息（容量、折算后净水量、估算咖啡因与热量）。
@Model
public final class WaterIntakeRecord {
    public var id: UUID
    /// 饮用时间
    public var date: Date
    /// 饮品分类 rawValue（对应 `HydrationBeverageType`）
    public var beverageTypeRaw: String
    /// 实际饮用容积（毫升）
    public var volumeML: Double
    /// 水分有效折算系数（0.0 ~ 1.0）
    public var hydrationFactor: Double
    /// 折算后的生理有效补水量（毫升）= volumeML * hydrationFactor
    public var effectiveHydrationML: Double
    /// 估算咖啡因（毫克）
    public var caffeineMG: Double
    /// 估算热量（千卡）
    public var calories: Double
    /// 自定义名称（如特定饮品名）
    public var customName: String?
    /// 备注
    public var note: String?
    /// 是否已同步至 Apple 健康（HealthKit）
    public var syncedToHealthKit: Bool
    /// 创建时间
    public var createdAt: Date
    /// 关联的记账条目（`ExpenseRecord.id`）。由记账联动生成的饮水记录带此值，
    /// 用于账单编辑/删除时同步饮水记录；其它来源为 nil。
    public var linkedExpenseID: UUID?

    public var beverageType: HydrationBeverageType {
        get {
            HydrationBeverageType(rawValue: beverageTypeRaw) ?? .plainWater
        }
        set {
            beverageTypeRaw = newValue.rawValue
        }
    }

    public init(
        date: Date = .now,
        beverageType: HydrationBeverageType = .plainWater,
        volumeML: Double,
        hydrationFactor: Double? = nil,
        customName: String? = nil,
        note: String? = nil,
        syncedToHealthKit: Bool = false,
        linkedExpenseID: UUID? = nil
    ) {
        self.id = UUID()
        self.date = date
        self.beverageTypeRaw = beverageType.rawValue
        self.volumeML = volumeML

        let factor = hydrationFactor ?? beverageType.defaultHydrationFactor
        self.hydrationFactor = factor
        self.effectiveHydrationML = (volumeML * factor).rounded()
        self.caffeineMG = ((volumeML / 100.0) * beverageType.estimatedCaffeinePer100ml).rounded()
        self.calories = ((volumeML / 100.0) * beverageType.estimatedCaloriesPer100ml).rounded()
        self.customName = customName
        self.note = note
        self.syncedToHealthKit = syncedToHealthKit
        self.linkedExpenseID = linkedExpenseID
        self.createdAt = .now
    }

    public func toSnapshot() -> WaterIntakeSnapshot {
        WaterIntakeSnapshot(
            id: id.uuidString,
            date: date,
            beverageType: beverageType,
            volumeML: volumeML,
            hydrationFactor: hydrationFactor,
            customName: customName,
            note: note
        )
    }
}
