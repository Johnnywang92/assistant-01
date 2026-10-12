import Foundation
import SwiftData
import SwiftUI

/// 宠物类型
public enum PetType: String, Codable, CaseIterable, Identifiable {
    case cat = "猫咪"
    case dog = "狗狗"
    case rabbit = "兔子"
    case bird = "鸟类"
    case other = "其他萌宠"

    public var id: String { rawValue }

    public var displayName: String { L10n.tr(rawValue) }

    public var icon: String {
        switch self {
        case .cat: return "pawprint.fill"
        case .dog: return "pawprint.fill"
        case .rabbit: return "hare.fill"
        case .bird: return "bird.fill"
        case .other: return "heart.fill"
        }
    }
}

/// 毛孩子 · 宠物健康档案与周期养护模型
@Model
public final class PetProfile {
    public var id: UUID
    public var name: String                  // 宠物昵称，如 "布丁", "大黄"
    public var typeRaw: String               // 宠物种类原始值
    public var breed: String                 // 品种，如 "英短金渐层", "柯基犬"
    public var gender: String                // "弟弟" / "妹妹" / "绝育公" / "绝育母"
    public var birthday: Date?               // 出生日期
    public var adoptionDate: Date?           // 领养/到家纪念日
    public var weightKg: Double?             // 当前体重（kg）
    public var microchipId: String?          // 芯片号 / 电子犬证号

    // 1. 体外驱虫（跳蚤、蜱虫、螨虫，通常每 30 天一次）
    public var lastExternalDewormDate: Date?
    public var externalDewormCycleDays: Int  // 默认 30 天

    // 2. 体内驱虫（蛔虫、绦虫等，通常每 90 天一次）
    public var lastInternalDewormDate: Date?
    public var internalDewormCycleDays: Int  // 默认 90 天

    // 3. 疫苗接种（联苗与狂犬，通常每年 365 天一次）
    public var lastVaccineDate: Date?
    public var vaccineCycleDays: Int         // 默认 365 天

    // 4. 洗澡与清洁美容
    public var lastBathDate: Date?
    public var bathCycleDays: Int            // 默认 14 或 30 天

    public var isReminderEnabled: Bool       // 是否开启智能提醒
    public var notes: String?                // 特殊习惯/过敏/常去宠物医院
    public var createdAt: Date

    public init(
        name: String,
        type: PetType = .cat,
        breed: String = "中华田园猫",
        gender: String = "绝育公",
        birthday: Date? = nil,
        adoptionDate: Date? = nil,
        weightKg: Double? = nil,
        microchipId: String? = nil,
        lastExternalDewormDate: Date? = nil,
        externalDewormCycleDays: Int = 30,
        lastInternalDewormDate: Date? = nil,
        internalDewormCycleDays: Int = 90,
        lastVaccineDate: Date? = nil,
        vaccineCycleDays: Int = 365,
        lastBathDate: Date? = nil,
        bathCycleDays: Int = 14,
        isReminderEnabled: Bool = true,
        notes: String? = nil
    ) {
        self.id = UUID()
        self.name = name
        self.typeRaw = type.rawValue
        self.breed = breed
        self.gender = gender
        self.birthday = birthday
        self.adoptionDate = adoptionDate
        self.weightKg = weightKg
        self.microchipId = microchipId
        self.lastExternalDewormDate = lastExternalDewormDate
        self.externalDewormCycleDays = externalDewormCycleDays
        self.lastInternalDewormDate = lastInternalDewormDate
        self.internalDewormCycleDays = internalDewormCycleDays
        self.lastVaccineDate = lastVaccineDate
        self.vaccineCycleDays = vaccineCycleDays
        self.lastBathDate = lastBathDate
        self.bathCycleDays = bathCycleDays
        self.isReminderEnabled = isReminderEnabled
        self.notes = notes
        self.createdAt = .now
    }

    public var type: PetType {
        get { PetType(rawValue: typeRaw) ?? .cat }
        set { typeRaw = newValue.rawValue }
    }

    // MARK: - 智能周期推算

    /// 距下次体外驱虫剩余天数（负数表示已逾期）
    public var daysUntilNextExternalDeworm: Int? {
        guard let last = lastExternalDewormDate else { return nil }
        let cal = Calendar.current
        guard let next = cal.date(byAdding: .day, value: externalDewormCycleDays, to: last) else { return nil }
        return cal.dateComponents([.day], from: cal.startOfDay(for: .now), to: cal.startOfDay(for: next)).day
    }

    /// 距下次体内驱虫剩余天数
    public var daysUntilNextInternalDeworm: Int? {
        guard let last = lastInternalDewormDate else { return nil }
        let cal = Calendar.current
        guard let next = cal.date(byAdding: .day, value: internalDewormCycleDays, to: last) else { return nil }
        return cal.dateComponents([.day], from: cal.startOfDay(for: .now), to: cal.startOfDay(for: next)).day
    }

    /// 距下次疫苗接种剩余天数
    public var daysUntilNextVaccine: Int? {
        guard let last = lastVaccineDate else { return nil }
        let cal = Calendar.current
        guard let next = cal.date(byAdding: .day, value: vaccineCycleDays, to: last) else { return nil }
        return cal.dateComponents([.day], from: cal.startOfDay(for: .now), to: cal.startOfDay(for: next)).day
    }

    /// 是否有养护事项急需处理（已逾期或7天内到期）
    public var needsAttention: Bool {
        if let d = daysUntilNextExternalDeworm, d <= 3 { return true }
        if let d = daysUntilNextInternalDeworm, d <= 5 { return true }
        if let d = daysUntilNextVaccine, d <= 15 { return true }
        return false
    }

    /// 年龄描述（如 "2岁3个月" 或 "8个月"）
    public var ageDescription: String {
        guard let b = birthday else { return L10n.tr("未知年龄") }
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: b, to: .now)
        let years = comps.year ?? 0
        let months = comps.month ?? 0
        if years > 0 {
            return L10n.tr(months > 0 ? "\(years)岁\(months)个月" : "\(years)岁整")
        } else if months > 0 {
            return L10n.tr("\(months)个月大")
        } else {
            let days = cal.dateComponents([.day], from: b, to: .now).day ?? 0
            return L10n.tr("\(max(1, days))天幼宠")
        }
    }
}
