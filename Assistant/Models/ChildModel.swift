import Foundation
import SwiftData
import SwiftUI

/// 儿童性别
public enum ChildGender: String, Codable, CaseIterable, Identifiable {
    case boy = "男宝"
    case girl = "女宝"

    public var id: String { rawValue }

    public var displayName: String { L10n.tr(rawValue) }

    public var icon: String {
        switch self {
        case .boy: return "figure.child"
        case .girl: return "figure.child"
        }
    }
}

/// 成长里程碑分类
public enum MilestoneCategory: String, Codable, CaseIterable, Identifiable {
    case motor = "大动作"
    case fineMotor = "精细动作"
    case language = "语言表达"
    case teeth = "出牙生理"
    case lifeFirst = "人生初体验"
    case social = "社交情感"
    case special = "重要纪念"

    public var id: String { rawValue }

    public var displayName: String { L10n.tr(rawValue) }

    public var icon: String {
        switch self {
        case .motor: return "figure.walk"
        case .fineMotor: return "hand.point.up.left.fill"
        case .language: return "bubble.left.and.bubble.right.fill"
        case .teeth: return "sparkles"
        case .lifeFirst: return "flag.fill"
        case .social: return "heart.circle.fill"
        case .special: return "crown.fill"
        }
    }

    public var color: Color {
        switch self {
        case .motor: return .orange
        case .fineMotor: return .purple
        case .language: return .blue
        case .teeth: return .pink
        case .lifeFirst: return .green
        case .social: return .red
        case .special: return .indigo
        }
    }
}

/// 常用里程碑预设选项
public struct MilestonePreset: Identifiable, Hashable {
    public let id: String
    public let category: MilestoneCategory
    public let suggestedMonth: String
    public let title: String
    public let detail: String

    public static let standardPresets: [MilestonePreset] = [
        MilestonePreset(id: "smile", category: .social, suggestedMonth: "1~2月", title: "第一次对人露出甜甜微笑", detail: "不再是无意识的微笑，能对爸爸妈妈的声音和逗弄做出开心的回应。"),
        MilestonePreset(id: "laugh", category: .language, suggestedMonth: "3~4月", title: "第一次发出咯咯笑声", detail: "听到好玩的声音或被轻轻呵痒，第一次开心地笑出了清脆的声音。"),
        MilestonePreset(id: "head_up", category: .motor, suggestedMonth: "2~3月", title: "俯卧抬头稳稳坚持", detail: "趴着时小脑袋能抬高45°~90°，环顾四周，颈部力量明显增强。"),
        MilestonePreset(id: "roll_over", category: .motor, suggestedMonth: "4~5月", title: "第一次成功自主翻身", detail: "从仰卧一骨碌翻到俯卧，视野瞬间开阔，开启大动作探索新篇章。"),
        MilestonePreset(id: "sit_up", category: .motor, suggestedMonth: "6~7月", title: "能够稳稳当当独坐", detail: "无需大人支撑，双手可以自由抓握身前的玩具，后背挺拔。"),
        MilestonePreset(id: "first_tooth", category: .teeth, suggestedMonth: "6~8月", title: "萌出第一颗可爱小乳牙", detail: "下牙龈冒出了洁白的小米粒牙，开始进入辅食咀嚼与磨牙期。"),
        MilestonePreset(id: "crawl", category: .motor, suggestedMonth: "8~9月", title: "手膝协调快速爬行", detail: "离开原地满屋探索，手膝配合熟练，充满好奇心与活力。"),
        MilestonePreset(id: "call_parents", category: .language, suggestedMonth: "8~10月", title: "第一声清晰地喊出爸/妈", detail: "有意识地看着父母清晰地发出'爸爸'或'妈妈'，让人热泪盈眶。"),
        MilestonePreset(id: "stand_up", category: .motor, suggestedMonth: "9~11月", title: "扶着家具稳稳站立", detail: "扶着沙发或围栏自己站立起来，开始尝试左右挪步巡航。"),
        MilestonePreset(id: "first_steps", category: .motor, suggestedMonth: "11~14月", title: "迈出人生独立第一步", detail: "勇敢地松开大人的手，摇摇晃晃迈出自己的第一步，正式进入直立行走时代！"),
        MilestonePreset(id: "self_feed", category: .fineMotor, suggestedMonth: "12~15月", title: "第一次自主用小勺进食", detail: "虽然可能会弄脏小手和小脸，但能自己握住勺子准确送入口中。"),
        MilestonePreset(id: "night_sleep", category: .lifeFirst, suggestedMonth: "任意月龄", title: "第一次整夜安睡 (睡整觉)", detail: "连续安睡 6~8 小时以上，给全家人带来高质量睡眠的奇迹夜晚。"),
        MilestonePreset(id: "kindergarten", category: .lifeFirst, suggestedMonth: "2.5~3岁", title: "入托/入园第一天", detail: "背上小书包迈进集体生活，虽然有不舍，但勇敢结识了新伙伴与老师。"),
        MilestonePreset(id: "full_month", category: .special, suggestedMonth: "满月", title: "平安健康满月纪念", detail: "宝宝迎来满月之喜，母子平安，健康茁壮。"),
        MilestonePreset(id: "hundred_days", category: .special, suggestedMonth: "百天", title: "百天百岁如意纪念", detail: "百天留念，祝宝宝长命百岁、聪明伶俐、顺遂平安。"),
        MilestonePreset(id: "one_year_old", category: .special, suggestedMonth: "1周岁", title: "一周岁生日抓周礼", detail: "人生首个周岁生日，抓周宴上充满欢声笑语，开启探索世界新旅程。")
    ]
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

/// 亲子育儿 · 持续成长身体发育测量记录（身高、体重、头围）
@Model
public final class ChildGrowthRecord {
    public var id: UUID
    public var date: Date
    public var monthAge: Int
    public var heightCm: Double?
    public var weightKg: Double?
    public var headCircumferenceCm: Double?
    public var notes: String?
    public var createdAt: Date
    public var child: ChildProfile?

    public init(
        id: UUID = UUID(),
        date: Date = .now,
        monthAge: Int = 0,
        heightCm: Double? = nil,
        weightKg: Double? = nil,
        headCircumferenceCm: Double? = nil,
        notes: String? = nil,
        child: ChildProfile? = nil
    ) {
        self.id = id
        self.date = date
        self.monthAge = monthAge
        self.heightCm = heightCm
        self.weightKg = weightKg
        self.headCircumferenceCm = headCircumferenceCm
        self.notes = notes
        self.createdAt = .now
        self.child = child
    }

    /// BMI 计算（体重(kg) / 身高(m)^2）
    public var bmi: Double? {
        guard let h = heightCm, h > 20, let w = weightKg, w > 1 else { return nil }
        let hMeters = h / 100.0
        return w / (hMeters * hMeters)
    }
}

/// 亲子育儿 · 持续成长里程碑与美好足迹
@Model
public final class ChildMilestoneRecord {
    public var id: UUID
    public var date: Date
    public var monthAge: Int
    public var categoryRaw: String
    public var title: String
    public var notes: String?
    public var createdAt: Date
    public var child: ChildProfile?

    public init(
        id: UUID = UUID(),
        date: Date = .now,
        monthAge: Int = 0,
        category: MilestoneCategory = .motor,
        title: String,
        notes: String? = nil,
        child: ChildProfile? = nil
    ) {
        self.id = id
        self.date = date
        self.monthAge = monthAge
        self.categoryRaw = category.rawValue
        self.title = title
        self.notes = notes
        self.createdAt = .now
        self.child = child
    }

    public var category: MilestoneCategory {
        get { MilestoneCategory(rawValue: categoryRaw) ?? .motor }
        set { categoryRaw = newValue.rawValue }
    }
}

/// 亲子育儿 · 就医/生病随访与健康用药记录
@Model
public final class ChildHealthVisitRecord {
    public var id: UUID
    public var date: Date
    public var hospitalOrClinic: String?
    public var diagnosis: String
    public var doctorAdvice: String?
    public var followUpDate: Date?
    public var notes: String?
    public var createdAt: Date
    public var child: ChildProfile?

    public init(
        id: UUID = UUID(),
        date: Date = .now,
        hospitalOrClinic: String? = nil,
        diagnosis: String,
        doctorAdvice: String? = nil,
        followUpDate: Date? = nil,
        notes: String? = nil,
        child: ChildProfile? = nil
    ) {
        self.id = id
        self.date = date
        self.hospitalOrClinic = hospitalOrClinic
        self.diagnosis = diagnosis
        self.doctorAdvice = doctorAdvice
        self.followUpDate = followUpDate
        self.notes = notes
        self.createdAt = .now
        self.child = child
    }

    /// 是否处于待复查状态
    public var isPendingFollowUp: Bool {
        guard let f = followUpDate else { return false }
        return f >= Calendar.current.startOfDay(for: .now)
    }
}

/// 亲子育儿 · 疫苗接种档案明细（接种日期、门诊、批号、观察反应）
@Model
public final class ChildVaccinationRecord {
    public var id: UUID
    public var vaccineId: String
    public var vaccineName: String
    public var dateAdministered: Date
    public var clinicName: String?
    public var batchNumber: String?
    public var reaction: String?
    public var createdAt: Date
    public var child: ChildProfile?

    public init(
        id: UUID = UUID(),
        vaccineId: String,
        vaccineName: String,
        dateAdministered: Date = .now,
        clinicName: String? = nil,
        batchNumber: String? = nil,
        reaction: String? = nil,
        child: ChildProfile? = nil
    ) {
        self.id = id
        self.vaccineId = vaccineId
        self.vaccineName = vaccineName
        self.dateAdministered = dateAdministered
        self.clinicName = clinicName
        self.batchNumber = batchNumber
        self.reaction = reaction
        self.createdAt = .now
        self.child = child
    }
}

/// 亲子育儿 · 宝贝成长与健康档案主模型
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
    public var completedVaccineIds: [String] // 已接种完成的疫苗 ID 列表（兼容旧版打卡）
    public var heightCm: Double?             // 初始或当前身高 (cm)
    public var weightKg: Double?             // 初始或当前体重 (kg)
    public var notes: String?                // 成长备忘（如奶粉品牌、儿保医院等）
    public var createdAt: Date

    // 长期持续累积关系
    @Relationship(deleteRule: .cascade, inverse: \ChildGrowthRecord.child)
    public var growthRecords: [ChildGrowthRecord] = []

    @Relationship(deleteRule: .cascade, inverse: \ChildMilestoneRecord.child)
    public var milestones: [ChildMilestoneRecord] = []

    @Relationship(deleteRule: .cascade, inverse: \ChildHealthVisitRecord.child)
    public var healthVisits: [ChildHealthVisitRecord] = []

    @Relationship(deleteRule: .cascade, inverse: \ChildVaccinationRecord.child)
    public var vaccinationRecords: [ChildVaccinationRecord] = []

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

    /// 当前月龄（用于计算接种时间与成长发育）
    public var currentMonthAge: Int {
        monthAge(at: .now)
    }

    /// 指定日期的月龄
    public func monthAge(at date: Date) -> Int {
        let cal = Calendar.current
        let comps = cal.dateComponents([.month], from: birthday, to: date)
        return max(0, comps.month ?? 0)
    }

    /// 年龄详细描述（如 "2岁3个月" 或 "108天"）
    public var ageDescription: String {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: birthday, to: .now)
        let years = comps.year ?? 0
        let months = comps.month ?? 0
        if years > 0 {
            return L10n.tr(months > 0 ? "\(years)岁\(months)个月" : "\(years)岁整")
        } else if months > 0 {
            return L10n.tr("\(months)个月")
        } else {
            let days = cal.dateComponents([.day], from: birthday, to: .now).day ?? 0
            return L10n.tr("\(max(1, days))天")
        }
    }

    // MARK: - 动态最新指标与时间轴排序

    /// 按时间倒序的身体测量记录
    public var sortedGrowthRecords: [ChildGrowthRecord] {
        growthRecords.sorted { $0.date > $1.date }
    }

    /// 最新测量记录
    public var latestGrowthRecord: ChildGrowthRecord? {
        sortedGrowthRecords.first
    }

    /// 上一次测量记录（用于计算增量）
    public var previousGrowthRecord: ChildGrowthRecord? {
        let list = sortedGrowthRecords
        return list.count > 1 ? list[1] : nil
    }

    /// 有效展示身高（优先采用最新测量，未录入测量则采用初始值）
    public var effectiveHeightCm: Double? {
        latestGrowthRecord?.heightCm ?? heightCm
    }

    /// 有效展示体重（优先采用最新测量，未录入测量则采用初始值）
    public var effectiveWeightKg: Double? {
        latestGrowthRecord?.weightKg ?? weightKg
    }

    /// 最新头围
    public var effectiveHeadCircumferenceCm: Double? {
        latestGrowthRecord?.headCircumferenceCm
    }

    /// 按时间倒序的里程碑
    public var sortedMilestones: [ChildMilestoneRecord] {
        milestones.sorted { $0.date > $1.date }
    }

    /// 按时间倒序的就医与健康随访
    public var sortedHealthVisits: [ChildHealthVisitRecord] {
        healthVisits.sorted { $0.date > $1.date }
    }

    /// 待复查的就医随访
    public var pendingHealthVisits: [ChildHealthVisitRecord] {
        sortedHealthVisits.filter { $0.isPendingFollowUp }
    }

    // MARK: - 疫苗状态与计算

    /// 近期应接种的适龄疫苗（适龄月龄 <= 当前月龄+1 且尚未接种）
    public var pendingVaccines: [ChildVaccineTemplateItem] {
        let current = currentMonthAge
        return ChildVaccineTemplateItem.standardSchedule.filter { item in
            !isVaccineCompleted(id: item.id) && item.monthAge <= current + 1
        }
    }

    /// 判断疫苗是否已接种完成
    public func isVaccineCompleted(id: String) -> Bool {
        completedVaccineIds.contains(id) || vaccinationRecords.contains { $0.vaccineId == id }
    }

    /// 疫苗完成详情
    public func vaccinationRecord(for vaccineId: String) -> ChildVaccinationRecord? {
        vaccinationRecords.first { $0.vaccineId == vaccineId }
    }

    /// 已完成接种总数
    public var completedVaccineCount: Int {
        var set = Set(completedVaccineIds)
        for r in vaccinationRecords {
            set.insert(r.vaccineId)
        }
        return set.count
    }

    /// 快速打卡/取消打卡疫苗
    public func toggleVaccineCompletion(id: String, vaccineName: String? = nil) {
        if isVaccineCompleted(id: id) {
            completedVaccineIds.removeAll { $0 == id }
            vaccinationRecords.removeAll { $0.vaccineId == id }
        } else {
            if !completedVaccineIds.contains(id) {
                completedVaccineIds.append(id)
            }
            if let vName = vaccineName ?? ChildVaccineTemplateItem.standardSchedule.first(where: { $0.id == id })?.vaccineName {
                let rec = ChildVaccinationRecord(
                    vaccineId: id,
                    vaccineName: vName,
                    dateAdministered: .now,
                    child: self
                )
                vaccinationRecords.append(rec)
            }
        }
    }
}
