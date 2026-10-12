import Foundation
import SwiftData

/// 车辆能源类型
public enum VehiclePowerType: String, Codable, CaseIterable, Identifiable {
    case gasoline = "燃油车"
    case electric = "纯电动车"
    case hybrid = "插电混动/增程"

    public var id: String { rawValue }

    public var displayName: String { L10n.tr(rawValue) }

    public var icon: String {
        switch self {
        case .gasoline: "fuelpump.fill"
        case .electric: "bolt.car.fill"
        case .hybrid: "leaf.arrow.triangle.circlepath"
        }
    }

    public var energyVerb: String {
        switch self {
        case .gasoline: L10n.tr("加油")
        case .electric: L10n.tr("充电")
        case .hybrid: L10n.tr("加油/充电")
        }
    }
}

/// 有车一族 · 爱车档案与周期管家模型
@Model
public final class VehicleProfile {
    public var id: UUID
    public var name: String                  // 车辆昵称，如 "极氪 001", "Model Y", "宝马 3 系"
    public var plateNumber: String           // 车牌号，如 "粤B·88888"
    public var powerTypeRaw: String          // 能源类型原始值

    // 1. 补能（加油/加电）周期与偏好设置
    public var energyCycleDays: Int          // 补能周期天数（如每 7 天 / 10 天提醒一次）
    public var lastEnergyRefillDate: Date?   // 上次加油/加电日期
    public var preferredEnergyHour: Int      // 提醒时段（例如 20:00 晚间波谷电价充电，或周五 17:30 下班前加油）
    public var preferredEnergyMinute: Int

    // 2. 定期保养
    public var maintenanceIntervalMonths: Int // 保养周期（月），默认 6 或 12 个月
    public var lastMaintenanceDate: Date?     // 上次保养日期
    public var nextMaintenanceDate: Date      // 下次预估保养日期

    // 3. 车险与年检合规防坑
    public var insuranceExpiryDate: Date?    // 车险到期日（提前 30 天比价续保预警）
    public var annualInspectionDate: Date?   // 年检到期日（提前 60 天申领年检标/上线检测）

    // 4. 行驶与辅助
    public var currentMileage: Double?       // 当前行驶里程（公里）
    public var isReminderEnabled: Bool       // 是否开启智能提醒
    public var notes: String?                // 备注（如车架号、保险单号、机油标号等）
    public var createdAt: Date

    public init(
        name: String,
        plateNumber: String,
        powerType: VehiclePowerType = .gasoline,
        energyCycleDays: Int = 7,
        preferredEnergyHour: Int = 19,
        preferredEnergyMinute: Int = 0,
        maintenanceIntervalMonths: Int = 6,
        insuranceExpiryDate: Date? = nil,
        annualInspectionDate: Date? = nil,
        currentMileage: Double? = nil,
        notes: String? = nil
    ) {
        self.id = UUID()
        self.name = name
        self.plateNumber = plateNumber
        self.powerTypeRaw = powerType.rawValue
        self.energyCycleDays = energyCycleDays
        self.lastEnergyRefillDate = .now
        self.preferredEnergyHour = preferredEnergyHour
        self.preferredEnergyMinute = preferredEnergyMinute
        self.maintenanceIntervalMonths = maintenanceIntervalMonths
        self.lastMaintenanceDate = .now
        self.insuranceExpiryDate = insuranceExpiryDate
        self.annualInspectionDate = annualInspectionDate
        self.currentMileage = currentMileage
        self.isReminderEnabled = true
        self.notes = notes
        self.createdAt = .now

        // 默认下次保养计算为指定月份后
        let cal = Calendar.current
        self.nextMaintenanceDate = cal.date(byAdding: .month, value: maintenanceIntervalMonths, to: .now) ?? .now
    }

    public var powerType: VehiclePowerType {
        get { VehiclePowerType(rawValue: powerTypeRaw) ?? .gasoline }
        set { powerTypeRaw = newValue.rawValue }
    }

    // MARK: - 智能推导倒数与状态指标

    /// 距离下次加油/加电的推导剩余天数
    public var daysUntilNextEnergyRefill: Int {
        guard let last = lastEnergyRefillDate else { return 0 }
        let cal = Calendar.current
        let nextDueDate = cal.date(byAdding: .day, value: energyCycleDays, to: last) ?? last
        let days = cal.dateComponents([.day], from: .now, to: nextDueDate).day ?? 0
        return days
    }

    /// 距离下次保养的剩余天数
    public var daysUntilNextMaintenance: Int {
        let cal = Calendar.current
        return cal.dateComponents([.day], from: .now, to: nextMaintenanceDate).day ?? 0
    }

    /// 距离车险到期的剩余天数
    public var daysUntilInsuranceExpiry: Int? {
        guard let exp = insuranceExpiryDate else { return nil }
        let cal = Calendar.current
        return cal.dateComponents([.day], from: .now, to: exp).day
    }

    /// 距离年检到期的剩余天数
    public var daysUntilAnnualInspection: Int? {
        guard let insp = annualInspectionDate else { return nil }
        let cal = Calendar.current
        return cal.dateComponents([.day], from: .now, to: insp).day
    }

    /// 是否亟需补能（逾期或当日需要）
    public var needsEnergySoon: Bool {
        daysUntilNextEnergyRefill <= 1
    }

    /// 是否亟需保养（15天内或已超期）
    public var needsMaintenanceSoon: Bool {
        daysUntilNextMaintenance <= 15
    }

    /// 是否需要车险关注（30天内或已脱保）
    public var needsInsuranceSoon: Bool {
        guard let days = daysUntilInsuranceExpiry else { return false }
        return days <= 30
    }

    /// 是否需要年检关注（60天内或已逾期）
    public var needsInspectionSoon: Bool {
        guard let days = daysUntilAnnualInspection else { return false }
        return days <= 60
    }

    /// 是否有任何事项需要车主关注
    public var needsAttention: Bool {
        needsEnergySoon || needsMaintenanceSoon || needsInsuranceSoon || needsInspectionSoon
    }

    // MARK: - 业务操作打卡

    /// 完成一次加油或充电打卡
    public func completeEnergyRefill() {
        self.lastEnergyRefillDate = .now
    }

    /// 完成一次常规保养打卡，自动推算下次到期日
    public func completeMaintenance() {
        self.lastMaintenanceDate = .now
        let cal = Calendar.current
        self.nextMaintenanceDate = cal.date(byAdding: .month, value: maintenanceIntervalMonths, to: .now) ?? .now
    }
}
