import Foundation
import AssistantCore

/// 备份与迁移数据包协议版本
public struct BackupPackage: Codable {
    public struct Metadata: Codable {
        public var schemaVersion: Int
        public var appVersion: String
        public var exportedAt: Date
        public var deviceModel: String
    }

    public var metadata: Metadata
    public var todos: [TodoDTO]
    public var subscriptions: [SubscriptionDTO]
    public var itemExpiries: [ItemExpiryDTO]
    public var anniversaries: [AnniversaryDTO]
    public var habits: [PeriodicHabitDTO]
    public var medications: [MedicationDTO]
    public var learnedPlaces: [LearnedPlaceDTO]
    public var passwords: [PasswordVaultDTO]
    public var dataUsageRecords: [DataUsageRecordDTO]
    public var expenses: [ExpenseDTO]?
    public var documents: [IDDocumentDTO]?
    public var departureItems: [DepartureCheckItemDTO]?
    public var voiceMemos: [VoiceMemoDTO]?
    public var vehicles: [VehicleDTO]?
    public var storedItems: [StoredItemDTO]?
    /// 家庭常备药（物品收纳页；旧版备份为 nil）
    public var medicines: [MedicineItemDTO]?
    public var dialogueRecords: [DialogueRecordDTO]?
    public var rawMessages: [RawMessageDTO]?
    public var locationSamples: [LocationSampleDTO]?
    /// 技能学习路径（含阶段与打卡流水；旧版备份为 nil）
    public var skillPaths: [SkillPathDTO]?
    public var skillStages: [SkillStageDTO]?
    public var practiceLogs: [SkillPracticeLogDTO]?
    /// 宠物与育儿档案（含宝贝四类记录；旧版备份为 nil）
    public var pets: [PetProfileDTO]?
    public var children: [ChildProfileDTO]?
    public var childGrowthRecords: [ChildGrowthRecordDTO]?
    public var childMilestones: [ChildMilestoneRecordDTO]?
    public var childHealthVisits: [ChildHealthVisitRecordDTO]?
    public var childVaccinations: [ChildVaccinationRecordDTO]?
    /// 生活提醒的完成/推迟实例状态（旧版备份为 nil）
    public var reminderActions: [LifeReminderActionDTO]?
    /// 人生大事项目（含阶段/任务/人员/支出/宾客子表；旧版备份为 nil）
    public var lifeEventProjects: [LifeEventProjectDTO]?
    public var lifeEventStages: [LifeEventStageDTO]?
    public var lifeEventTasks: [LifeEventTaskDTO]?
    public var lifeEventPeople: [LifeEventPersonDTO]?
    public var lifeEventExpenses: [LifeEventExpenseDTO]?
    public var lifeEventGuests: [LifeEventGuestDTO]?
    /// 投喂事务审计流水（旧版备份为 nil）
    public var omniboxTransactions: [OmniboxTransactionDTO]?
    /// 饮食热量记录（Schema V4 新增；旧版备份为 nil）
    public var foodIntakeRecords: [FoodIntakeRecordDTO]?
    /// 饮水与饮品摄入记录（Schema V5 新增；旧版备份为 nil）
    public var waterIntakeRecords: [WaterIntakeRecordDTO]?
    /// 判别反馈语料（Schema V3 备份格式新增；旧版备份为 nil）
    public var judgmentFeedbacks: [JudgmentFeedbackDTO]?
    /// 每日健康快照（Schema V4 备份格式新增；旧版备份为 nil）
    public var healthSnapshots: [HealthDaySnapshotRecordDTO]?
    /// 用户偏好设置快照（旧版备份为 nil；收录原则见 AssistantCore 的 AssistantSettingsKeys）
    public var settings: SettingsSnapshotDTO?
}

// MARK: - DTO 模型定义

public struct TodoDTO: Codable {
    public var id: UUID
    public var typeRaw: String
    public var statusRaw: String
    public var title: String
    public var detail: String?
    public var pickupCode: String?
    public var courier: String?
    public var station: String?
    public var location: String?
    public var dueAt: Date?
    public var createdAt: Date
    public var completedAt: Date?
    public var sourceText: String?
    public var sortOrder: Int?
    public var recurrenceRuleRaw: String?
    public var recurrenceIntervalDays: Int?
    public var remindBeforeMinutes: Int?
    public var reminderOverrideAt: Date?
    public var qrCodePayload: String?
    public var qrCodeImageData: Data?
    public var attachmentImageData: Data?
    // 技能学习路径关联（旧备份为 nil）
    public var skillPathID: UUID?
    public var skillStageIndex: Int?
    public var isSkillPractice: Bool?
    public var skillPracticeMinutes: Int?
    // 人生大事镜像关联（旧备份为 nil）
    public var lifeEventTaskID: UUID?
    // 系统日历联动与到站/落地清点提醒（旧备份为 nil）
    public var calendarItemIdentifier: String?
    public var arrivalReminderAt: Date?
    public var arrivalTransportRaw: String?
    public var arrivalCheckFiredAt: Date?
}

public struct SubscriptionDTO: Codable {
    public var id: UUID
    public var name: String
    public var priceString: String
    public var nextBillingDate: Date
    public var remindDaysBefore: Int
    public var isAutoRenew: Bool
    public var notes: String?
}

public struct ItemExpiryDTO: Codable {
    public var id: UUID
    public var title: String
    public var category: String
    public var expireDate: Date
    public var remindDaysBefore: Int
    public var isResolved: Bool
}

public struct AnniversaryDTO: Codable {
    public var id: UUID
    public var title: String
    public var category: String
    public var targetDate: Date
    public var isLunar: Bool
    public var remindDaysBefore: [Int]
    public var notes: String?
}

public struct PeriodicHabitDTO: Codable {
    public var id: UUID
    public var title: String
    public var detail: String?
    public var recurrenceRaw: String
    public var preferredHour: Int
    public var preferredMinute: Int
    public var lastCompletedAt: Date?
    public var nextDueAt: Date
    public var isEnabled: Bool
    public var triggerHomeKitScene: String?
}

public struct MedicationDTO: Codable {
    public var id: UUID
    public var medName: String
    public var dosage: String
    public var dailyTimePoints: [String]
    public var isEnabled: Bool
    public var notes: String?
}

public struct LearnedPlaceDTO: Codable {
    public var id: UUID
    public var name: String
    public var categoryRaw: String
    public var latitude: Double
    public var longitude: Double
    public var radiusMeters: Double
    public var associatedWiFiSSIDs: [String]
    public var visitCount: Int
    public var nightStayProbability: Double
    public var workdayDayStayProbability: Double
    public var isUserConfirmed: Bool
    public var lastVisitedAt: Date
}

public struct PasswordVaultDTO: Codable {
    public var id: UUID
    public var title: String
    public var account: String
    public var passwordEncrypted: String // 明文仅存在于整个备份的 AES-GCM 加密负载内
    public var category: String
    public var notes: String?
    public var lastRotatedAt: Date
    public var rotateCycleDays: Int
}

public struct DataUsageRecordDTO: Codable {
    public var id: UUID
    public var operatorName: String?
    public var remainingMB: Double?
    public var usedMB: Double?
    public var usedPercent: Double?
    public var recordedAt: Date
}

public struct ExpenseDTO: Codable {
    public var id: UUID
    public var amount: Double
    public var isIncome: Bool
    public var categoryRaw: String
    public var title: String
    public var rawText: String
    public var date: Date
    public var createdAt: Date
    public var linkedItemID: UUID?
    public var currencyCode: String?
    public var foreignAmount: Double?
    public var exchangeRateToCNY: Double?
}

public struct IDDocumentDTO: Codable {
    public var id: UUID
    public var title: String
    public var typeRaw: String
    public var holderName: String?
    public var documentNumber: String?
    public var expiryDate: Date?
    public var isPermanent: Bool
    public var notes: String?
    public var frontImageData: Data?
    public var backImageData: Data?
    public var createdAt: Date
    public var updatedAt: Date
}

public struct DepartureCheckItemDTO: Codable {
    public var id: UUID
    public var title: String
    public var sceneRaw: String
    public var isChecked: Bool
    public var isEssential: Bool
    public var storageLocationNote: String?
    public var createdAt: Date
}

public struct VoiceMemoDTO: Codable {
    public var id: UUID
    public var title: String
    public var duration: Double
    public var audioFileName: String
    public var audioData: Data?
    public var transcription: String?
    public var summary: String?
    public var tagRaw: String
    public var isBookmarked: Bool
    public var createdAt: Date
}

public struct VehicleDTO: Codable {
    public var id: UUID
    public var name: String
    public var plateNumber: String
    public var powerTypeRaw: String
    public var energyCycleDays: Int
    public var lastEnergyRefillDate: Date?
    public var preferredEnergyHour: Int
    public var preferredEnergyMinute: Int
    public var maintenanceIntervalMonths: Int
    public var lastMaintenanceDate: Date?
    public var nextMaintenanceDate: Date
    public var insuranceExpiryDate: Date?
    public var annualInspectionDate: Date?
    public var currentMileage: Double?
    public var isReminderEnabled: Bool
    public var notes: String?
    public var createdAt: Date
}

public struct StoredItemDTO: Codable {
    public var id: UUID
    public var name: String
    public var location: String
    public var roomArea: String
    public var notes: String?
    public var imageData: Data?
    public var purchasePrice: Double?
    public var purchaseDate: Date?
    public var isSecondHand: Bool?
    public var resalePrice: Double?
    public var resoldDate: Date?
    public var createdAt: Date
    public var updatedAt: Date
}

public struct MedicineItemDTO: Codable {
    public var id: UUID
    public var name: String
    public var categoryRaw: String
    public var indications: String?
    public var usageMethod: String?
    public var storageLocation: String
    public var roomArea: String
    public var purchaseDate: Date?
    public var expiryDate: Date?
    public var isOpened: Bool?
    public var openedDate: Date?
    public var afterOpenValidDays: Int?
    public var remainingQuantity: String?
    public var precautions: String?
    public var imageData: Data?
    public var isDisposed: Bool?
    public var createdAt: Date
    public var updatedAt: Date
}

public struct DialogueRecordDTO: Codable {
    public var id: UUID
    public var roleRaw: String
    public var text: String
    public var timestamp: Date
    public var sessionID: UUID?
}

public struct RawMessageDTO: Codable {
    public var id: UUID
    public var source: String
    public var sender: String?
    public var content: String
    public var receivedAt: Date
    public var parseSummary: String?
}

public struct LocationSampleDTO: Codable {
    public var id: UUID
    public var latitude: Double
    public var longitude: Double
    public var wifiSSID: String?
    public var timestamp: Date
    public var hourOfDay: Int
    public var isWeekend: Bool
}

public struct SkillPathDTO: Codable {
    public var id: UUID
    public var title: String
    public var categoryRaw: String
    public var goal: String
    public var weeklyMinutes: Int
    public var totalWeeks: Int
    public var startedAt: Date
    public var statusRaw: String
    public var currentStageIndex: Int
    public var lastPracticedAt: Date?
    public var practiceStreakDays: Int
    public var practiceCount: Int
}

public struct SkillStageDTO: Codable {
    public var id: UUID
    public var pathID: UUID
    public var index: Int
    public var name: String
    public var acceptance: String
    public var plannedDays: Int
    public var isUnlocked: Bool
    public var isCompleted: Bool
    public var completedAt: Date?
    /// 未展开阶段的任务模板（base64 JSON，与模型端一致）
    public var tasksJSON: String
}

public struct SkillPracticeLogDTO: Codable {
    public var id: UUID
    public var pathID: UUID
    public var stageIndex: Int
    public var practicedAt: Date
    public var minutes: Int
}

public struct PetProfileDTO: Codable {
    public var id: UUID
    public var name: String
    public var typeRaw: String
    public var breed: String
    public var gender: String
    public var birthday: Date?
    public var adoptionDate: Date?
    public var weightKg: Double?
    public var microchipId: String?
    public var lastExternalDewormDate: Date?
    public var externalDewormCycleDays: Int
    public var lastInternalDewormDate: Date?
    public var internalDewormCycleDays: Int
    public var lastVaccineDate: Date?
    public var vaccineCycleDays: Int
    public var lastBathDate: Date?
    public var bathCycleDays: Int
    public var isReminderEnabled: Bool
    public var notes: String?
    public var createdAt: Date
}

public struct ChildProfileDTO: Codable {
    public var id: UUID
    public var name: String
    public var realName: String?
    public var genderRaw: String
    public var birthday: Date
    public var bloodType: String?
    public var idCardNumber: String?
    public var allergyInfo: String?
    public var completedVaccineIds: [String]
    public var heightCm: Double?
    public var weightKg: Double?
    public var notes: String?
    public var createdAt: Date
}

public struct ChildGrowthRecordDTO: Codable {
    public var id: UUID
    /// 归属宝贝的软引用；模型端是 ChildProfile.child 关系，导出时扁平化为 ID
    public var childID: UUID?
    public var date: Date
    public var monthAge: Int
    public var heightCm: Double?
    public var weightKg: Double?
    public var headCircumferenceCm: Double?
    public var notes: String?
    public var createdAt: Date
}

public struct ChildMilestoneRecordDTO: Codable {
    public var id: UUID
    public var childID: UUID?
    public var date: Date
    public var monthAge: Int
    public var categoryRaw: String
    public var title: String
    public var notes: String?
    public var createdAt: Date
}

public struct ChildHealthVisitRecordDTO: Codable {
    public var id: UUID
    public var childID: UUID?
    public var date: Date
    public var hospitalOrClinic: String?
    public var diagnosis: String
    public var doctorAdvice: String?
    public var followUpDate: Date?
    public var notes: String?
    public var createdAt: Date
}

public struct ChildVaccinationRecordDTO: Codable {
    public var id: UUID
    public var childID: UUID?
    public var vaccineId: String
    public var vaccineName: String
    public var dateAdministered: Date
    public var clinicName: String?
    public var batchNumber: String?
    public var reaction: String?
    public var createdAt: Date
}

public struct LifeReminderActionDTO: Codable {
    public var id: UUID
    public var sourceKindRaw: String
    /// 来源档案 ID 横跨六类提醒源，无法逐类做包内悬挂校验，仅校验自身 ID 唯一
    public var sourceID: UUID
    public var occurrenceDate: Date
    public var statusRaw: String
    public var snoozedUntil: Date?
    public var completedAt: Date?
}

public struct LifeEventProjectDTO: Codable {
    public var id: UUID
    public var title: String
    public var templateRaw: String
    public var targetDate: Date
    public var location: String?
    public var budgetLimit: Double
    public var statusRaw: String
    public var createdAt: Date
    /// 项目级 AI 决策摘要（可选，旧备份缺键解出 nil）。
    public var aiDecisionSummary: String?
    public var aiDecisionAt: Date?
}

public struct LifeEventStageDTO: Codable {
    public var id: UUID
    public var projectID: UUID
    public var title: String
    public var sortOrder: Int
    public var statusRaw: String
}

public struct LifeEventTaskDTO: Codable {
    public var id: UUID
    public var projectID: UUID
    public var stageID: UUID
    public var title: String
    public var detail: String?
    public var dueDate: Date?
    public var statusRaw: String
    public var ownerName: String?
    public var createdAt: Date
    /// 需求问答答案 / AI 决策摘要 / 导入行动项（均可选，旧备份缺键解出 nil）。
    public var answersJSON: String?
    public var aiDecisionSummary: String?
    public var aiActionItemsJSON: String?
    public var aiConsultedAt: Date?
}

public struct LifeEventPersonDTO: Codable {
    public var id: UUID
    public var projectID: UUID
    public var name: String
    public var role: String
    public var relationship: String
    public var phone: String
    public var responsibility: String
    public var side: String
}

public struct LifeEventExpenseDTO: Codable {
    public var id: UUID
    public var projectID: UUID
    public var title: String
    public var category: String
    public var amount: Double
    public var paidAmount: Double
    public var payee: String
    public var dueDate: Date?
    public var note: String
}

public struct LifeEventGuestDTO: Codable {
    public var id: UUID
    public var projectID: UUID
    public var name: String
    public var relationship: String
    public var side: String
    public var phone: String
    public var tableNumber: String
    public var attendanceRaw: String
}

/// 投喂事务：actionsJSON/undoJSON 是动作参数与撤销令牌快照，属用户行为数据而非密钥材料；
/// 明文口令类内容只可能出现在密码库 DTO，本 DTO 连同整包一起受 PIN 加密信封保护
public struct OmniboxTransactionDTO: Codable {
    public var id: UUID
    public var createdAt: Date
    public var sourceRaw: String
    public var inputText: String
    public var imageCount: Int
    public var actionsJSON: Data
    public var statusRaw: String
    public var executedAt: Date?
    public var engineRaw: String
    public var undoJSON: Data?
}


public struct FoodIntakeRecordDTO: Codable {
    public var id: UUID
    public var date: Date
    public var foodName: String
    public var foodID: String?
    public var portionRaw: String
    public var fullPortionCalories: Double
    public var consumedRatio: Double
    public var consumedCalories: Double
    public var confidence: Double
    public var isManuallyAdjusted: Bool
    public var sourceRaw: String
    public var createdAt: Date
    public var linkedExpenseID: UUID?
    public var imageData: Data?
}

public struct WaterIntakeRecordDTO: Codable {
    public var id: UUID
    public var date: Date
    public var beverageTypeRaw: String
    public var volumeML: Double
    public var hydrationFactor: Double
    public var effectiveHydrationML: Double
    public var caffeineMG: Double
    public var calories: Double
    public var customName: String?
    public var note: String?
    public var syncedToHealthKit: Bool
    public var createdAt: Date
    public var linkedExpenseID: UUID?
}

/// 判别反馈语料（点赞/点踩 + 概率快照 + 混淆对标签）。
/// 是阈值校准与识别质量统计的全部数据源，丢了就得从零攒。
public struct JudgmentFeedbackDTO: Codable {
    public var id: UUID
    public var createdAt: Date
    public var inputText: String
    public var labelRaw: String
    public var verdictRaw: String
    public var topProbability: Double
    public var margin: Double
    public var runnerUpLabelRaw: String?
    public var correctedLabelRaw: String?
}

/// 每日健康快照（睡眠/步数/体征等日粒度记录）。
/// 是睡眠与健康分数趋势的唯一数据源；HealthKit 不可回溯，丢了补不回来。
public struct HealthDaySnapshotRecordDTO: Codable {
    public var id: UUID
    /// 归属日（当天 00:00）
    public var day: Date
    public var stepCount: Double?
    public var activeEnergy: Double?
    public var restingEnergy: Double?
    public var dietaryWater: Double?
    public var sleepHours: Double?
    public var sleepREM: Double?
    public var sleepDeep: Double?
    public var heartRate: Double?
    public var restingHeartRate: Double?
    public var heartRateVariability: Double?
    public var bloodOxygen: Double?
    public var bodyTemperature: Double?
    public var walkingSpeed: Double?
    public var respiratoryRate: Double?
    public var workoutMinutes: Double?
    public var workoutCount: Int?
    public var updatedAt: Date
}
