import Foundation
import SwiftData
import SwiftUI

/// 儿童性别
public enum ChildGender: String, Codable, CaseIterable, Identifiable {
    case boy = "男宝"
    case girl = "女宝"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .boy: return "figure.child"
        case .girl: return "figure.child.and.lock"
        }
    }
}

/// 国家免疫规划标准儿童疫苗模板项
public struct ChildVaccineTemplateItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let monthAge: Int                 // 适龄月龄（0=出生, 1=1月龄...）
    public let monthLabel: String            // "出生时", "1月龄", "8月龄"
    public let vaccineName: String           // 疫苗名称
    public let targetDisease: String         // 预防疾病
    public let isFree: Bool                  // 是否一类免费规划疫苗

    public init(id: String, monthAge: Int, monthLabel: String, vaccineName: String, targetDisease: String, isFree: Bool = true) {
        self.id = id
        self.monthAge = monthAge
        self.monthLabel = monthLabel
        self.vaccineName = vaccineName
        self.targetDisease = targetDisease
        self.isFree = isFree
    }

    /// 中国国家免疫规划核心疫苗库
    public static let standardSchedule: [ChildVaccineTemplateItem] = [
        ChildVaccineTemplateItem(id: "bcg_1", monthAge: 0, monthLabel: "出生24小时", vaccineName: "卡介苗 (第1剂)", targetDisease: "结核性脑膜炎"),
        ChildVaccineTemplateItem(id: "hepb_1", monthAge: 0, monthLabel: "出生24小时", vaccineName: "乙肝疫苗 (第1剂)", targetDisease: "乙型肝炎"),
        ChildVaccineTemplateItem(id: "hepb_2", monthAge: 1, monthLabel: "1月龄", vaccineName: "乙肝疫苗 (第2剂)", targetDisease: "乙型肝炎"),
        ChildVaccineTemplateItem(id: "ipv_1", monthAge: 2, monthLabel: "2月龄", vaccineName: "脊灰灭活疫苗 IPV (第1剂)", targetDisease: "小儿麻痹症"),
        ChildVaccineTemplateItem(id: "dtap_1", monthAge: 3, monthLabel: "3月龄", vaccineName: "百白破疫苗 (第1剂)", targetDisease: "百日咳/白喉/破伤风"),
        ChildVaccineTemplateItem(id: "ipv_2", monthAge: 3, monthLabel: "3月龄", vaccineName: "脊灰减毒疫苗 OPV/IPV (第2剂)", targetDisease: "小儿麻痹症"),
        ChildVaccineTemplateItem(id: "dtap_2", monthAge: 4, monthLabel: "4月龄", vaccineName: "百白破疫苗 (第2剂)", targetDisease: "百日咳/白喉/破伤风"),
        ChildVaccineTemplateItem(id: "dtap_3", monthAge: 5, monthLabel: "5月龄", vaccineName: "百白破疫苗 (第3剂)", targetDisease: "百日咳/白喉/破伤风"),
        ChildVaccineTemplateItem(id: "hepb_3", monthAge: 6, monthLabel: "6月龄", vaccineName: "乙肝疫苗 (第3剂)", targetDisease: "乙型肝炎"),
        ChildVaccineTemplateItem(id: "men_a_1", monthAge: 6, monthLabel: "6月龄", vaccineName: "A群流脑多糖疫苗 (第1剂)", targetDisease: "流行性脑脊髓膜炎"),
        ChildVaccineTemplateItem(id: "mmr_1", monthAge: 8, monthLabel: "8月龄", vaccineName: "麻腮风联合疫苗 (第1剂)", targetDisease: "麻疹/腮腺炎/风疹"),
        ChildVaccineTemplateItem(id: "je_1", monthAge: 8, monthLabel: "8月龄", vaccineName: "乙脑减毒活疫苗 (第1剂)", targetDisease: "流行性乙型脑炎"),
        ChildVaccineTemplateItem(id: "men_a_2", monthAge: 9, monthLabel: "9月龄", vaccineName: "A群流脑多糖疫苗 (第2剂)", targetDisease: "流行性脑脊髓膜炎"),
        ChildVaccineTemplateItem(id: "varicella_1", monthAge: 12, monthLabel: "12月龄", vaccineName: "水痘疫苗 (自愿自费第1剂)", targetDisease: "水痘", isFree: false),
        ChildVaccineTemplateItem(id: "dtap_boost", monthAge: 18, monthLabel: "18月龄", vaccineName: "百白破疫苗 (加强剂)", targetDisease: "百日咳/白喉/破伤风"),
        ChildVaccineTemplateItem(id: "mmr_2", monthAge: 18, monthLabel: "18月龄", vaccineName: "麻腮风联合疫苗 (第2剂)", targetDisease: "麻疹/腮腺炎/风疹"),
        ChildVaccineTemplateItem(id: "je_2", monthAge: 24, monthLabel: "2周岁", vaccineName: "乙脑减毒活疫苗 (第2剂)", targetDisease: "流行性乙型脑炎")
    ]
}

/// 亲子育儿 · 宝贝成长与健康档案
@Model
public final class ChildProfile {
    public var id: UUID
    public var name: String                  // 宝宝小名/昵称，如 "安安", "小糯米"
    public var realName: String?             // 真实姓名（选填）
    public var genderRaw: String             // 性别原始值
    public var birthday: Date                // 出生日期
    public var bloodType: String?            // 血型（A/B/AB/O/Rh）
    public var idCardNumber: String?         // 身份证号 / 出生证明编号
    public var allergyInfo: String?          // 过敏源（牛奶蛋白、鸡蛋、青霉素、蚕豆病等）
    public var completedVaccineIds: [String] // 已接种完成的疫苗 ID 列表
    public var heightCm: Double?             // 当前身高 (cm)
    public var weightKg: Double?             // 当前体重 (kg)
    public var notes: String?                // 成长备忘（如奶粉品牌、儿保医院等）
    public var createdAt: Date

    public init(
        name: String,
        realName: String? = nil,
        gender: ChildGender = .boy,
        birthday: Date = .now,
        bloodType: String? = nil,
        idCardNumber: String? = nil,
        allergyInfo: String? = nil,
        completedVaccineIds: [String] = [],
        heightCm: Double? = nil,
        weightKg: Double? = nil,
        notes: String? = nil
    ) {
        self.id = UUID()
        self.name = name
        self.realName = realName
        self.genderRaw = gender.rawValue
        self.birthday = birthday
        self.bloodType = bloodType
        self.idCardNumber = idCardNumber
        self.allergyInfo = allergyInfo
        self.completedVaccineIds = completedVaccineIds
        self.heightCm = heightCm
        self.weightKg = weightKg
        self.notes = notes
        self.createdAt = .now
    }

    public var gender: ChildGender {
        get { ChildGender(rawValue: genderRaw) ?? .boy }
        set { genderRaw = newValue.rawValue }
    }

    /// 当前月龄（用于计算接种时间）
    public var currentMonthAge: Int {
        let cal = Calendar.current
        let comps = cal.dateComponents([.month], from: birthday, to: .now)
        return max(0, comps.month ?? 0)
    }

    /// 年龄详细描述（如 "2岁3个月" 或 "108天"）
    public var ageDescription: String {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: birthday, to: .now)
        let years = comps.year ?? 0
        let months = comps.month ?? 0
        if years > 0 {
            return months > 0 ? "\(years)岁\(months)个月" : "\(years)岁整"
        } else if months > 0 {
            return "\(months)个月"
        } else {
            let days = cal.dateComponents([.day], from: birthday, to: .now).day ?? 0
            return "\(max(1, days))天"
        }
    }

    /// 近期应接种的适龄疫苗（适龄月龄 <= 当前月龄+1 且尚未接种）
    public var pendingVaccines: [ChildVaccineTemplateItem] {
        let current = currentMonthAge
        return ChildVaccineTemplateItem.standardSchedule.filter { item in
            !completedVaccineIds.contains(item.id) && item.monthAge <= current + 1
        }
    }

    /// 已完成接种数量
    public var completedVaccineCount: Int {
        completedVaccineIds.count
    }

    /// 标记接种完成 / 取消标记
    public func toggleVaccineCompletion(id: String) {
        if let idx = completedVaccineIds.firstIndex(of: id) {
            completedVaccineIds.remove(at: idx)
        } else {
            completedVaccineIds.append(id)
        }
    }
}
