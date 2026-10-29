import AssistantCore
import PhotosUI
import SwiftData
import SwiftUI
import CoreLocation
import WeatherKit

// MARK: - 新建待办 / 智能导入弹窗

/// 常用高频待办预设胶囊数据模型
fileprivate struct QuickSuggestion: Hashable {
    let title: String
    let detail: String?
    let defaultHourOffset: Int?
}

struct AddTodoSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let initialCategory: TodoFilterCategory

    @State private var tab: Int = 0 // 0: 手动新建, 1: 短信/图片智能导入
    @State private var selectedCategory: TodoFilterCategory

    // 手动新建表单
    @State private var title: String = ""
    @State private var type: TodoType
    @State private var detail: String = ""
    @State private var hasDueDate: Bool
    @State private var dueDate: Date
    @State private var remindBeforeMinutes: Int = 0
    @State private var customRemindBeforeMinutes: Int = 120
    @State private var recurrenceRule: TodoRecurrenceRule = .none
    @State private var customIntervalDays: Int = 3
    @State private var pickupCode: String = ""
    @State private var station: String = ""

    // 图片/预约截图识别状态
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    @State private var isRecognizingImage: Bool = false
    @State private var imageRecognitionError: String? = nil
    @State private var qrCodePayload: String? = nil
    @State private var qrCodeImageData: Data? = nil
    @State private var attachmentImageData: Data? = nil
    @State private var showingQRPreviewInAdd: Bool = false
    @State private var recognizedTravelPickup: TravelPickupMetadata? = nil
    @State private var recognizedRawText: String? = nil

    // 识别置信度与推荐候选类型
    @State private var recognitionConfidence: Double? = nil
    @State private var recognitionConfidenceReason: String? = nil
    @State private var recognitionSuggestedTypes: [TodoType] = []
    @State private var showConfidenceNotice: Bool = true

    // 出行前购票与文博景区预约确认项
    @State private var addCompanionTickets: Bool = false
    @State private var includeTrainReminder: Bool = true
    @State private var includeFlightReminder: Bool = true
    @State private var includeScenicReminder: Bool = true
    @State private var customTrainDate: Date? = nil
    @State private var customScenicDate: Date? = nil

    // 智能剪贴板侦测
    @State private var detectedClipboardText: String?
    @State private var detectedClipboardType: TodoType?
    @State private var detectedPickupCode: String?
    @State private var detectedStation: String?

    // 智能识别文本
    @State private var importText: String = ""
    @State private var importResult: String?

    init(initialCategory: TodoFilterCategory = .all) {
        self.initialCategory = initialCategory
        self._selectedCategory = State(initialValue: initialCategory)

        // 根据首页当前选中的分类，自动匹配最合适的默认分类类型与提醒时间
        let defaultType: TodoType
        let defaultHasDueDate: Bool
        let defaultDue: Date

        switch initialCategory {
        case .all:
            defaultType = .general
            defaultHasDueDate = false
            defaultDue = Calendar.current.date(byAdding: .hour, value: 2, to: .now) ?? .now
        case .general:
            defaultType = .general
            defaultHasDueDate = true
            let calendar = Calendar.current
            let tonight = calendar.date(bySettingHour: 20, minute: 0, second: 0, of: .now) ?? .now
            defaultDue = tonight > .now ? tonight : (calendar.date(byAdding: .hour, value: 2, to: .now) ?? .now)
        case .work:
            defaultType = .work
            defaultHasDueDate = true
            let workEvening = Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: .now) ?? .now
            defaultDue = workEvening > .now ? workEvening : (Calendar.current.date(byAdding: .day, value: 1, to: workEvening) ?? .now)
        case .parcel:
            defaultType = .parcel
            defaultHasDueDate = false
            defaultDue = Calendar.current.date(byAdding: .hour, value: 3, to: .now) ?? .now
        case .life:
            defaultType = .medication
            defaultHasDueDate = true
            let calendar = Calendar.current
            let tonight = calendar.date(bySettingHour: 20, minute: 0, second: 0, of: .now) ?? .now
            defaultDue = tonight > .now ? tonight : (calendar.date(byAdding: .day, value: 1, to: tonight) ?? .now)
        case .alert:
            defaultType = .bill
            defaultHasDueDate = true
            defaultDue = Calendar.current.date(byAdding: .day, value: 3, to: .now) ?? .now
        case .recurring:
            defaultType = .general
            defaultHasDueDate = true
            defaultDue = Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now
        case .parenting:
            defaultType = .childVaccine
            defaultHasDueDate = true
            defaultDue = Calendar.current.date(byAdding: .day, value: 3, to: .now) ?? .now
        case .pet:
            defaultType = .pet
            defaultHasDueDate = true
            defaultDue = Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now
        case .other:
            defaultType = .other
            defaultHasDueDate = false
            defaultDue = Calendar.current.date(byAdding: .hour, value: 2, to: .now) ?? .now
        }

        self._type = State(initialValue: defaultType)
        self._hasDueDate = State(initialValue: defaultHasDueDate)
        self._dueDate = State(initialValue: defaultDue)
        if initialCategory == .recurring {
            self._recurrenceRule = State(initialValue: .weekly)
        }
    }

    // MARK: - 分类对应候选子类型集合

    /// 当前选中的大板块所涵盖的具体待办类型
    private var availableTypesForCategory: [TodoType] {
        switch selectedCategory {
        case .all:
            return [.general, .work, .travelBooking, .parcel, .medication, .housework, .exercise, .charging, .subscription, .vehicleCare, .bill, .itemExpiry, .anniversary, .hydration, .event, .childVaccine, .childGrowth, .childMilestone, .childHealth, .pet, .other]
        case .general:
            return [.general, .travelBooking, .event]
        case .work:
            return [.work, .event, .general]
        case .recurring:
            return [.general, .medication, .housework, .charging, .hydration, .bill, .event]
        case .parcel:
            return [.parcel, .returnParcel]
        case .life:
            return [.medication, .exercise, .charging, .hydration]
        case .alert:
            return [.bill, .travelBooking, .vehicleCare, .subscription, .itemExpiry, .anniversary, .passwordSecurity]
        case .parenting:
            return [.childVaccine, .childGrowth, .childMilestone, .childHealth]
        case .pet:
            return [.pet]
        case .other:
            return [.other]
        }
    }

    /// 切换大板块时自动适配子类型
    private func onCategoryChanged(_ newCat: TodoFilterCategory) {
        selectedCategory = newCat
        let candidates = availableTypesForCategory
        if !candidates.contains(type) {
            type = candidates.first ?? .general
        }
        if newCat == .general {
            hasDueDate = true
            let calendar = Calendar.current
            let tonight = calendar.date(bySettingHour: 20, minute: 0, second: 0, of: .now) ?? .now
            dueDate = tonight > .now ? tonight : (calendar.date(byAdding: .hour, value: 2, to: .now) ?? .now)
        } else if newCat == .life || newCat == .alert || newCat == .recurring || newCat == .parenting || newCat == .pet || newCat == .work {
            hasDueDate = true
            if newCat == .recurring && recurrenceRule == .none {
                recurrenceRule = .weekly
            }
        }
        Haptic.selection()
    }

    /// 根据 TodoType 计算归属的大板块分类
    private func categoryForType(_ t: TodoType) -> TodoFilterCategory {
        switch t {
        case .parcel, .returnParcel:
            return .parcel
        case .work:
            return .work
        case .medication, .exercise, .charging, .hydration:
            return .life
        case .bill, .vehicleCare, .subscription, .itemExpiry, .anniversary, .passwordSecurity:
            return .alert
        case .childVaccine, .childGrowth, .childMilestone, .childHealth:
            return .parenting
        case .pet:
            return .pet
        case .other:
            return .other
        default:
            return .general
        }
    }

    /// 点击低置信度候选分类一键切换
    private func applySuggestedType(_ sugType: TodoType) {
        type = sugType
        selectedCategory = categoryForType(sugType)
        Haptic.selection()
    }

    // MARK: - 动态情境占位符

    private var contextualPlaceholder: String {
        switch type {
        case .parcel:
            return "快递名称（如：顺丰快递、京东生鲜、天猫超市）"
        case .returnParcel:
            return "退货/售后事项（如：网购衣服7天退货、数码产品售后寄回）"
        case .medication:
            return "用药名称（如：按时吃降压药、早晚维生素、滴眼药水）"
        case .housework:
            return "家务项目（如：洗被罩床单、全屋扫地拖地、阳台浇花）"
        case .charging:
            return "设备名称（如：给蓝牙耳机充电、给备用手机充电）"
        case .hydration:
            return "喝水作息（如：下午喝一杯温水、起身走动拉伸）"
        case .bill:
            return "账单名称（如：信用卡账单还款、缴纳房租水电）"
        case .vehicleCare:
            return "爱车事项（如：汽车加油/加电、5000公里小保养、车险续约）"
        case .subscription:
            return "订阅服务（如：iCloud+ 自动续费、视频VIP续约防扣款）"
        case .itemExpiry:
            return "保质期预警（如：鲜牛奶到期、家庭常备药有效期、换驾照）"
        case .anniversary:
            return "重要纪念日（如：妈妈生日、结婚纪念日、好友聚会）"
        case .passwordSecurity:
            return "安全提醒（如：定期轮换平台密码、更新路由器管理密码）"
        case .event:
            return "日程事项（如：周五下午团队例会、拜访重要客户）"
        case .work:
            return "工作事项（如：准备项目周报、预约会议室并同步议题、提交评审材料）"
        case .travelBooking:
            return "出行与购票（如：国庆返乡高铁票、下周上海出差机票、假期旅行）"
        case .exercise:
            return "运动事项（如：晚间跑步、瑜伽训练、球类活动）"
        case .childVaccine:
            return "疫苗接种（如：宝宝 6 月龄疫苗预约）"
        case .childGrowth:
            return "成长测量（如：记录宝宝身高体重）"
        case .childMilestone:
            return "成长里程碑（如：记录宝宝第一次走路）"
        case .childHealth:
            return "健康随访（如：宝宝儿保复查）"
        case .pet:
            return "宠物事项（如：喂食、驱虫、洗护或宠物就医）"
        case .skillLearning:
            return "学习任务（如：练 20 分钟和弦切换、读完第 3 章并做笔记）"
        case .other:
            return "待办名称（其它待办事项）"
        case .general, .data:
            return "待办名称（如：去超市买牛奶、准备工作周报、下午开会）"
        }
    }

    // MARK: - 高频快捷预设胶囊（一键免手动打字）

    private var quickSuggestionsForType: [QuickSuggestion] {
        switch type {
        case .parcel:
            return [
                QuickSuggestion(title: "顺丰速运", detail: nil, defaultHourOffset: nil),
                QuickSuggestion(title: "京东快递", detail: nil, defaultHourOffset: nil),
                QuickSuggestion(title: "菜鸟驿站包裹", detail: nil, defaultHourOffset: nil),
                QuickSuggestion(title: "丰巢柜包裹", detail: nil, defaultHourOffset: nil),
                QuickSuggestion(title: "中通快递", detail: nil, defaultHourOffset: nil),
                QuickSuggestion(title: "天猫超市生鲜", detail: nil, defaultHourOffset: nil)
            ]
        case .returnParcel:
            return [
                QuickSuggestion(title: "七天无理由退货", detail: "保持包装吊牌完好，联系快递上门取件", defaultHourOffset: 168),
                QuickSuggestion(title: "衣服鞋帽尺码退换", detail: "商品完好，附退换货清单", defaultHourOffset: 72),
                QuickSuggestion(title: "网购数码售后返修寄件", detail: "原包装防震保护好寄回", defaultHourOffset: 120),
                QuickSuggestion(title: "快递员预约上门取件", detail: "提前打包好包裹", defaultHourOffset: 24)
            ]
        case .medication:
            return [
                QuickSuggestion(title: "按时吃降压药", detail: "温水送服，饭后半小时", defaultHourOffset: 2),
                QuickSuggestion(title: "早晚复合维生素", detail: "饭后随餐服用", defaultHourOffset: 4),
                QuickSuggestion(title: "睡前滴眼药水", detail: "两眼各一滴，闭目5分钟", defaultHourOffset: 6),
                QuickSuggestion(title: "补钙咀嚼片", detail: "睡前咀嚼服用", defaultHourOffset: 6)
            ]
        case .housework:
            return [
                QuickSuggestion(title: "全屋扫地拖地", detail: "客厅、卧室及走廊吸尘除灰", defaultHourOffset: 24),
                QuickSuggestion(title: "清洗更换床单被罩", detail: "高温洗烘除螨", defaultHourOffset: 48),
                QuickSuggestion(title: "阳台绿植浇水", detail: "浇透盆底见湿", defaultHourOffset: 24),
                QuickSuggestion(title: "清理冰箱过期食品", detail: "检查冷藏层保质期", defaultHourOffset: 72),
                QuickSuggestion(title: "清洗油烟机滤网", detail: "温水去油污浸泡", defaultHourOffset: 168)
            ]
        case .charging:
            return [
                QuickSuggestion(title: "给蓝牙耳机充电", detail: "放回充电盒充满", defaultHourOffset: 3),
                QuickSuggestion(title: "给备用手机/手表充电", detail: "保持电量充足", defaultHourOffset: 2),
                QuickSuggestion(title: "充电宝蓄电", detail: "为明日外出备电", defaultHourOffset: 4)
            ]
        case .hydration:
            return [
                QuickSuggestion(title: "下午喝一杯温水", detail: "补充水分 300ml", defaultHourOffset: 1),
                QuickSuggestion(title: "起身活动拉伸5分钟", detail: "放松肩颈腰椎", defaultHourOffset: 1)
            ]
        case .bill:
            return [
                QuickSuggestion(title: "信用卡账单还款", detail: "核对本期应还款额", defaultHourOffset: 72),
                QuickSuggestion(title: "房租水电费缴纳", detail: "按时缴费避免断供滞纳", defaultHourOffset: 48),
                QuickSuggestion(title: "宽带话费充值", detail: "检查剩余话费", defaultHourOffset: 48)
            ]
        case .vehicleCare:
            return [
                QuickSuggestion(title: "爱车加油/加电", detail: "关注续航里程与电量/油量", defaultHourOffset: 24),
                QuickSuggestion(title: "汽车常规小保养", detail: "更换机油机滤与胎压检查", defaultHourOffset: 168),
                QuickSuggestion(title: "车险到期续约", detail: "比对车险报价及商业险", defaultHourOffset: 720),
                QuickSuggestion(title: "车辆年检/违章核查", detail: "交管12123查验", defaultHourOffset: 360)
            ]
        case .subscription:
            return [
                QuickSuggestion(title: "iCloud+ 自动续费", detail: "检查当月账单扣款", defaultHourOffset: 72),
                QuickSuggestion(title: "视频VIP连续包月防扣款", detail: "如不继续使用请提前关闭", defaultHourOffset: 48),
                QuickSuggestion(title: "音乐平台会员续费", detail: "自动扣费确认", defaultHourOffset: 72)
            ]
        case .itemExpiry:
            return [
                QuickSuggestion(title: "鲜牛奶食品保质期", detail: "冷藏保鲜临期预警", defaultHourOffset: 48),
                QuickSuggestion(title: "常备药品有效期核对", detail: "清理家庭小药箱", defaultHourOffset: 720),
                QuickSuggestion(title: "身份证/驾照换证提醒", detail: "期满前90日内申请换证", defaultHourOffset: 2160)
            ]
        case .anniversary:
            return [
                QuickSuggestion(title: "家人长辈生日", detail: "提前准备生日礼物与祝福", defaultHourOffset: 168),
                QuickSuggestion(title: "结婚/恋爱纪念日", detail: "订餐厅与纪念礼物", defaultHourOffset: 168)
            ]
        case .passwordSecurity:
            return [
                QuickSuggestion(title: "重要平台密码定期轮换", detail: "更新核心账号强密码", defaultHourOffset: 720)
            ]
        case .general:
            return [
                QuickSuggestion(title: "下班去超市采买", detail: "购买生活必需品", defaultHourOffset: 4),
                QuickSuggestion(title: "整理本周工作周报", detail: "总结核心交付物与下周规划", defaultHourOffset: 24),
                QuickSuggestion(title: "给家里通电话问候", detail: "关心父母近况", defaultHourOffset: 6)
            ]
        case .event:
            return [
                QuickSuggestion(title: "团队项目进度例会", detail: "会议室对齐本周阻塞项", defaultHourOffset: 24),
                QuickSuggestion(title: "客户拜访洽谈", detail: "准备方案与演示文稿", defaultHourOffset: 48)
            ]
        case .work:
            return [
                QuickSuggestion(title: "整理本周工作周报", detail: "总结核心交付物与下周规划", defaultHourOffset: 24),
                QuickSuggestion(title: "准备团队例会材料", detail: "更新项目进展与阻塞清单", defaultHourOffset: 12),
                QuickSuggestion(title: "项目里程碑交付评审", detail: "核对交付清单与演示环境", defaultHourOffset: 72),
                QuickSuggestion(title: "出差/客户拜访行程安排", detail: "确认交通住宿与洽谈方案", defaultHourOffset: 120)
            ]
        case .travelBooking:
            return [
                QuickSuggestion(title: "抢购往返高铁票（提前15天）", detail: "12306 开售首日准点抢票并候补", defaultHourOffset: 360),
                QuickSuggestion(title: "预订假期往返机票（提前15-30天）", detail: "比对各大航司特惠早鸟票并锁定酒店", defaultHourOffset: 720),
                QuickSuggestion(title: "热门博物馆/特展预约（提前7天）", detail: "关注故宫、国博、省博等放票时间实名分时段预约", defaultHourOffset: 168),
                QuickSuggestion(title: "5A景区门票/游船预约（提前7-14天）", detail: "提前分时段锁定景区入场名额与索道特展票", defaultHourOffset: 168),
                QuickSuggestion(title: "出差往返机票预订", detail: "确认航班班次与行程报销凭证", defaultHourOffset: 120),
                QuickSuggestion(title: "长假节假日火车票抢票", detail: "提前设置开售提醒闹钟与候补", defaultHourOffset: 360)
            ]
        case .exercise:
            return [
                QuickSuggestion(title: "晚间跑步训练", detail: "热身后进行 30 分钟有氧运动", defaultHourOffset: 4),
                QuickSuggestion(title: "瑜伽或拉伸", detail: "放松肩颈和腰背，保持规律活动", defaultHourOffset: 24)
            ]
        case .childVaccine:
            return [QuickSuggestion(title: "预约宝宝疫苗接种", detail: "核对月龄和接种本，提前预约门诊", defaultHourOffset: 72)]
        case .childGrowth:
            return [QuickSuggestion(title: "记录宝宝身高体重", detail: "同步记录测量日期和月龄", defaultHourOffset: 168)]
        case .childMilestone:
            return [QuickSuggestion(title: "记录宝宝成长里程碑", detail: "记下发生日期、场景和当时的心情", defaultHourOffset: nil)]
        case .childHealth:
            return [QuickSuggestion(title: "宝宝儿保复查", detail: "带好既往测量记录和就诊资料", defaultHourOffset: 168)]
        case .pet:
            return [
                QuickSuggestion(title: "给宠物喂食", detail: "准备好每日粮食和饮水", defaultHourOffset: 8),
                QuickSuggestion(title: "宠物驱虫", detail: "按周期完成体内外驱虫", defaultHourOffset: 720),
                QuickSuggestion(title: "预约宠物洗护", detail: "确认时间并准备牵引绳或航空箱", defaultHourOffset: 72),
                QuickSuggestion(title: "宠物就医复查", detail: "带好病历、用药记录和检查结果", defaultHourOffset: 48)
            ]
        default:
            return []
        }
    }

    private func applyQuickSuggestion(_ s: QuickSuggestion) {
        title = s.title
        if detail.isEmpty, let d = s.detail {
            detail = d
        }
        if let offset = s.defaultHourOffset {
            hasDueDate = true
            dueDate = Calendar.current.date(byAdding: .hour, value: offset, to: .now) ?? dueDate
        }
        Haptic.light()
    }

    // MARK: - 剪贴板极速识别

    private func checkClipboard() {
        guard let clip = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !clip.isEmpty else { return }
        guard clip.count <= 350 else { return }

        let isReturn = clip.contains("退货") || clip.contains("寄件") || clip.contains("售后") || clip.contains("上门取件") || clip.contains("换货") || clip.contains("退款")
        let isParcel = clip.contains("取件") || clip.contains("驿站") || clip.contains("丰巢") || clip.contains("自提") || clip.contains("快递") || clip.contains("包裹")
        let isBill = clip.contains("账单") || clip.contains("还款") || clip.contains("扣款") || clip.contains("应还")

        if isReturn {
            detectedClipboardText = clip
            detectedClipboardType = .returnParcel
            if let regex = try? NSRegularExpression(pattern: "([0-9A-Za-z]{6,})", options: []) {
                if let match = regex.firstMatch(in: clip, options: [], range: NSRange(location: 0, length: clip.utf16.count)) {
                    if let range = Range(match.range(at: 1), in: clip) {
                        detectedPickupCode = String(clip[range])
                    }
                }
            }
            if clip.contains("顺丰") { detectedStation = "顺丰速运" }
            else if clip.contains("京东") { detectedStation = "京东快递" }
            else if clip.contains("菜鸟") { detectedStation = "菜鸟驿站" }
        } else if isParcel {
            detectedClipboardText = clip
            detectedClipboardType = .parcel
            if let regex = try? NSRegularExpression(pattern: "([0-9A-Za-z]+[-号][0-9A-Za-z]+[-号]?[0-9A-Za-z]*)", options: []) {
                if let match = regex.firstMatch(in: clip, options: [], range: NSRange(location: 0, length: clip.utf16.count)) {
                    if let range = Range(match.range(at: 1), in: clip) {
                        detectedPickupCode = String(clip[range])
                    }
                }
            }
            if clip.contains("菜鸟") { detectedStation = "菜鸟驿站" }
            else if clip.contains("丰巢") { detectedStation = "丰巢快递柜" }
        } else if isBill {
            detectedClipboardText = clip
            detectedClipboardType = .bill
        }
    }

    private func applyClipboardAutofill() {
        guard let clip = detectedClipboardText else { return }
        if detectedClipboardType == .returnParcel {
            onCategoryChanged(.parcel)
            type = .returnParcel
            if let code = detectedPickupCode {
                pickupCode = code
                title = "网购退货寄件"
            } else {
                title = "网购待退货"
            }
            if let st = detectedStation {
                station = st
            }
            detail = clip
            hasDueDate = true
            dueDate = Calendar.current.date(byAdding: .day, value: 7, to: .now) ?? .now
        } else if detectedClipboardType == .parcel {
            onCategoryChanged(.parcel)
            type = .parcel
            if let code = detectedPickupCode {
                pickupCode = code
                if clip.contains("顺丰") { title = "顺丰快递" }
                else if clip.contains("京东") { title = "京东快递" }
                else if clip.contains("中通") { title = "中通快递" }
                else if clip.contains("圆通") { title = "圆通快递" }
                else { title = "待取快递包裹" }
            } else {
                title = "待取快递"
            }
            if let st = detectedStation {
                station = st
            }
            detail = clip
        } else if detectedClipboardType == .bill {
            onCategoryChanged(.alert)
            type = .bill
            title = "信用卡账单还款"
            detail = clip
            hasDueDate = true
        } else {
            title = String(clip.prefix(25))
            detail = clip
        }
        detectedClipboardText = nil
        Haptic.success()
    }

    // MARK: - 主视图

    var body: some View {
        NavigationStack {
            Form {
                // 1. 添加模式分段选择
                Section {
                    Picker("添加模式", selection: $tab) {
                        Text("手动新建").tag(0)
                        Text("短信/图片智能导入").tag(1)
                    }
                    .pickerStyle(.segmented)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 2, leading: 2, bottom: 4, trailing: 2))

                // 图片/预约截图识别与二维码提取区（手动新建与智能导入均支持）
                Section {
                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                        HStack(spacing: 10) {
                            ZStack {
                                RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous)
                                    .fill(Color.blue.opacity(0.14))
                                    .frame(width: 36, height: 36)
                                if isRecognizingImage {
                                    ProgressView()
                                } else {
                                    Image(systemName: "photo.badge.plus")
                                        .font(.body.bold())
                                        .foregroundStyle(.blue)
                                }
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(isRecognizingImage ? "正在识别时间、地点与票务信息…" : "从相册选择电影票 / 门票 / 预约截图 / 取件图")
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.primary)
                                    Text("自动提取事件名称、活动时间、场馆地址与核销二维码")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 2)
                        }
                        .onChange(of: selectedPhotoItem) { _, newItem in
                            guard let newItem else { return }
                            Task { await loadAndRecognizePhoto(newItem) }
                        }

                        if UIPasteboard.general.hasImages {
                            Button {
                                if let clipImg = UIPasteboard.general.image {
                                    Task { await recognizeFromUIImage(clipImg) }
                                }
                            } label: {
                                Label("识别剪贴板中的截图", systemImage: "doc.on.clipboard.fill")
                                    .font(.subheadline)
                            }
                        }

                        if let err = imageRecognitionError {
                            Text(L10n.tr(err))
                                .font(.caption)
                                .foregroundStyle(.red)
                        }

                        // 已识别出的预约二维码与原图凭证预览卡片
                        if qrCodeImageData != nil || (qrCodePayload != nil && !(qrCodePayload?.isEmpty ?? true)) || attachmentImageData != nil {
                            HStack(spacing: 12) {
                                if let qrData = qrCodeImageData, let uiImg = UIImage(data: qrData) {
                                    Image(uiImage: uiImg)
                                        .interpolation(.none)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 64, height: 64)
                                        .padding(4)
                                        .background(Color.white)
                                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.chip))
                                        .overlay(RoundedRectangle(cornerRadius: AppRadius.chip).stroke(Color.secondary.opacity(0.2)))
                                } else if let payload = qrCodePayload, let genImg = QRCodeService.generateQRCode(from: payload, targetSize: 200) {
                                    Image(uiImage: genImg)
                                        .interpolation(.none)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 64, height: 64)
                                        .padding(4)
                                        .background(Color.white)
                                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.chip))
                                } else if let attachData = attachmentImageData, let uiImg = UIImage(data: attachData) {
                                    Image(uiImage: uiImg)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 64, height: 64)
                                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.chip))
                                }

                                VStack(alignment: .leading, spacing: 5) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "checkmark.seal.fill")
                                            .foregroundStyle(.green)
                                            .font(.caption)
                                        Text(qrCodeImageData != nil || qrCodePayload != nil ? "已提取预约二维码" : "已关联截图凭证")
                                            .font(.subheadline.bold())
                                    }
                                    if let payload = qrCodePayload, !payload.isEmpty {
                                        Text("码号：\(payload)")
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    HStack(spacing: 8) {
                                        Button {
                                            showingQRPreviewInAdd = true
                                            Haptic.light()
                                        } label: {
                                            Label("预览亮码", systemImage: "qrcode.viewfinder")
                                                .font(.caption2.bold())
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.mini)

                                        Button(role: .destructive) {
                                            qrCodePayload = nil
                                            qrCodeImageData = nil
                                            attachmentImageData = nil
                                            recognizedTravelPickup = nil
                                        } label: {
                                            Text("清除")
                                                .font(.caption2)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.mini)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    } header: {
                        Text(tab == 1 ? "图片 / 预约截图识别" : "快捷识图建待办")
                    }

                if let pickup = recognizedTravelPickup {
                    Section {
                        TravelTicketPickupConfigView(
                            pickup: Binding(
                                get: { pickup },
                                set: { updated in
                                    recognizedTravelPickup = updated
                                    title = updated.resolvedTitle
                                    station = updated.resolvedLocation
                                    hasDueDate = true
                                    dueDate = updated.plannedTargetTime
                                    detail = updated.resolvedDetail
                                }
                            )
                        )
                    } header: {
                        Text("火车票 / 机票接人时间与汇合地点")
                    } footer: {
                        Text("已根据票面到站时间（\(pickup.arrivalAt.formatted(date: .omitted, time: .shortened))）扣除提前量（\(pickup.advanceMinutes)分钟），将到达「\(pickup.resolvedLocation)」的目标时间设为 \(pickup.plannedTargetTime.formatted(date: .omitted, time: .shortened))。")
                    }
                }

                if tab == 0 {
                    // 智能剪贴板侦测卡片（极简一键填入）
                    if let clipSnippet = detectedClipboardText {
                        Section {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "sparkles")
                                    .foregroundStyle(.tint)
                                    .font(.title3)

                                VStack(alignment: .leading, spacing: 5) {
                                    Text("识别到剪贴板有相关通知")
                                        .font(.subheadline.bold())

                                    Text(clipSnippet)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)

                                    Button {
                                        applyClipboardAutofill()
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: "arrow.down.doc.fill")
                                            Text("一键识别填入表单")
                                        }
                                        .font(.caption.bold())
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(Color.accentColor)
                                        .clipShape(Capsule())
                                    }
                                    .padding(.top, 2)
                                }

                                Spacer()

                                Button {
                                    AppMotion.animate { detectedClipboardText = nil }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    // 识图置信度较低时的友好提示与候选分类一键切换
                    if showConfidenceNotice, let conf = recognitionConfidence, conf < 0.70 {
                        Section {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 6) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                    Text("智能识别置信度较低（\(Int(conf * 100))%）")
                                        .font(.subheadline.bold())
                                        .foregroundStyle(.orange)
                                    Spacer()
                                    Button {
                                        AppMotion.animate { showConfidenceNotice = false }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }

                                if let reason = recognitionConfidenceReason, !reason.isEmpty {
                                    Text(reason)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                if !recognitionSuggestedTypes.isEmpty {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text("推荐候选分类（点击一键修正）：")
                                            .font(.caption2.bold())
                                            .foregroundStyle(.secondary)

                                        ScrollView(.horizontal, showsIndicators: false) {
                                            HStack(spacing: 6) {
                                                ForEach(recognitionSuggestedTypes, id: \.self) { sugType in
                                                    Button {
                                                        applySuggestedType(sugType)
                                                    } label: {
                                                        HStack(spacing: 4) {
                                                            Image(systemName: sugType.icon)
                                                            Text(sugType.displayName)
                                                        }
                                                        .font(.caption.bold())
                                                        .padding(.horizontal, 10)
                                                        .padding(.vertical, 5)
                                                        .background(type == sugType ? Color.accentColor : Color.orange.opacity(0.14))
                                                        .foregroundStyle(type == sugType ? Color.white : Color.primary)
                                                        .clipShape(Capsule())
                                                    }
                                                    .buttonStyle(.plain)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }

                    // 2. 所属板块分段选择（自动对应首页当前分类）
                    Section("事项所属板块") {
                        Picker("所属板块", selection: Binding(
                            get: { selectedCategory },
                            set: { onCategoryChanged($0) }
                        )) {
                            ForEach(TodoFilterCategory.allCases) { cat in
                                Text(L10n.tr(cat.rawValue)).tag(cat)
                            }
                        }
                        .pickerStyle(.segmented)

                        // 具体类型选择（根据板块智能收敛选项）
                        if availableTypesForCategory.count > 1 {
                            Picker("具体类型", selection: $type) {
                                ForEach(availableTypesForCategory, id: \.self) { t in
                                    Label(t.displayName, systemImage: t.icon).tag(t)
                                }
                            }
                        } else if type == .parcel {
                            HStack {
                                Label("快递取件", systemImage: "shippingbox.fill")
                                Spacer()
                                Text("已自动匹配快递模式")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    // 3. 待办内容填写与高频快捷胶囊
                    Section("待办内容与地点") {
                        TextField(contextualPlaceholder, text: $title)

                        // 常用快捷预设横向滑动标签
                        let suggestions = quickSuggestionsForType
                        if !suggestions.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(suggestions, id: \.self) { s in
                                        Button {
                                            applyQuickSuggestion(s)
                                        } label: {
                                            HStack(spacing: 4) {
                                                Image(systemName: "plus.circle.fill")
                                                    .font(.system(size: 11))
                                                    .foregroundStyle(.tint)
                                                Text(L10n.tr(s.title))
                                                    .font(.caption)
                                                    .foregroundStyle(.primary)
                                            }
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 6)
                                            .background(Color(.tertiarySystemFill))
                                            .clipShape(Capsule())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.vertical, 3)
                            }
                        }

                        // 快递/退货模式专属快捷输入字段 vs 日程场馆地点
                        if type == .parcel {
                            TextField("取件码（如：3-2-104 或 5821）", text: $pickupCode)
                                .font(.body.monospaced())

                            TextField("存放驿站/自提柜（选填，如：菜鸟驿站、丰巢）", text: $station)
                        } else if type == .returnParcel {
                            TextField("寄件码 / 售后运单号（选填）", text: $pickupCode)
                                .font(.body.monospaced())

                            TextField("寄件方式/网点（选填，如：顺丰上门取件、驿站代寄）", text: $station)
                        } else {
                            HStack(spacing: 6) {
                                Image(systemName: "mappin.and.ellipse")
                                    .foregroundStyle(.red.opacity(0.8))
                                TextField("场馆 / 地点（选填，如：西岸国际会展中心）", text: $station)
                            }
                        }
                    }

                    // 4. 详情与提醒时间
                    Section("详情与提醒时间") {
                        TextField("补充备注/详情说明（选填）", text: $detail, axis: .vertical)
                            .lineLimit(2...4)

                        Toggle("设置提醒时间", isOn: $hasDueDate)
                            .onChange(of: hasDueDate) { _, enabled in
                                if enabled { Task { await NotificationService.requestAuthorization() } }
                            }
                        if hasDueDate {
                            DatePicker("截止时间", selection: $dueDate, displayedComponents: [.date, .hourAndMinute])
                            Picker("提前提醒", selection: $remindBeforeMinutes) {
                                Text("到期时").tag(0)
                                Text("提前 5 分钟").tag(5)
                                Text("提前 1 小时").tag(60)
                                Text("提前 1 天").tag(1440)
                                Text("自定义").tag(-1)
                            }
                            if remindBeforeMinutes == -1 {
                                Stepper("提前 \(customRemindBeforeMinutes) 分钟", value: $customRemindBeforeMinutes, in: 1...10080, step: 5)
                            }

                            if recognizedTravelPickup == nil && TravelTicketReminderManager.shouldSuggestCrossCityTickets(
                                title: title,
                                station: station,
                                location: station,
                                detail: detail,
                                hasQRCodeOrTicket: qrCodeImageData != nil || qrCodePayload != nil || attachmentImageData != nil,
                                type: type
                            ) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Toggle(isOn: $addCompanionTickets) {
                                        HStack(spacing: 5) {
                                            Image(systemName: "ticket.fill")
                                                .foregroundStyle(.indigo)
                                            Text("同时添加出行前购票与预约待办")
                                                .font(.subheadline.bold())
                                                .foregroundStyle(.indigo)
                                        }
                                    }

                                    let cal = Calendar.current
                                    let trainDate = cal.date(byAdding: .day, value: -15, to: dueDate) ?? dueDate
                                    let scenicDate = cal.date(byAdding: .day, value: -7, to: dueDate) ?? dueDate
                                    let f: DateFormatter = {
                                        let df = DateFormatter()
                                        df.dateFormat = "M月d日"
                                        return df
                                    }()

                                    if addCompanionTickets {
                                        VStack(alignment: .leading, spacing: 8) {
                                            HStack(alignment: .top, spacing: 6) {
                                                Image(systemName: "exclamationmark.triangle.fill")
                                                    .font(.caption2)
                                                    .foregroundStyle(.orange)
                                                Text("政策兜底提示：票务与场馆预约政策常变动，请以官方最新公告为准，可自主核对并微调提醒时间：")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                            .padding(.vertical, 2)

                                            VStack(alignment: .leading, spacing: 4) {
                                                Toggle(isOn: $includeTrainReminder) {
                                                    Label("🚄 火车票起售提醒（提前15天）", systemImage: "train.side.front.car")
                                                        .font(.caption.bold())
                                                }
                                                if includeTrainReminder {
                                                    DatePicker(
                                                        "确认放票提醒时间",
                                                        selection: Binding(
                                                            get: { customTrainDate ?? trainDate },
                                                            set: { customTrainDate = $0 }
                                                        ),
                                                        displayedComponents: [.date, .hourAndMinute]
                                                    )
                                                    .datePickerStyle(.compact)
                                                    .font(.caption2)
                                                }
                                            }

                                            VStack(alignment: .leading, spacing: 4) {
                                                Toggle(isOn: $includeScenicReminder) {
                                                    Label("🏛️ 场馆景区预约提醒（提前7天）", systemImage: "building.columns.fill")
                                                        .font(.caption.bold())
                                                }
                                                if includeScenicReminder {
                                                    DatePicker(
                                                        "确认预约提醒时间",
                                                        selection: Binding(
                                                            get: { customScenicDate ?? scenicDate },
                                                            set: { customScenicDate = $0 }
                                                        ),
                                                        displayedComponents: [.date, .hourAndMinute]
                                                    )
                                                    .datePickerStyle(.compact)
                                                    .font(.caption2)
                                                }
                                            }

                                            Toggle(isOn: $includeFlightReminder) {
                                                Label("✈️ 提前15-30天 机票酒店黄金预订期", systemImage: "airplane")
                                                    .font(.caption.bold())
                                            }
                                        }
                                        .padding(.leading, 6)
                                        .padding(.vertical, 4)
                                    } else {
                                        HStack(spacing: 4) {
                                            Label("🚄 火车票：\(f.string(from: trainDate))起售（提前15天）", systemImage: "train.side.front.car")
                                                .font(.caption2)
                                                .foregroundStyle(.blue)
                                        }
                                        HStack(spacing: 4) {
                                            Label("🏛️ 场馆景区：\(f.string(from: scenicDate))预约（提前7天）", systemImage: "building.columns.fill")
                                                .font(.caption2)
                                                .foregroundStyle(.purple)
                                        }
                                        HStack(spacing: 4) {
                                            Label("✈️ 机票预订：提前15-30天黄金期", systemImage: "airplane")
                                                .font(.caption2)
                                                .foregroundStyle(.teal)
                                        }
                                    }

                                    if let guide = TravelTicketReminderManager.detectDestinationGuide(for: title) {
                                        Text("【放票指南】\(guide)")
                                            .font(.caption2)
                                            .foregroundStyle(.purple)
                                            .padding(.top, 2)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }

                        Picker("重复周期", selection: $recurrenceRule) {
                            ForEach(TodoRecurrenceRule.allCases) { rule in
                                Label(L10n.tr(rule.rawValue), systemImage: rule.icon).tag(rule)
                            }
                        }

                        if recurrenceRule == .custom {
                            Stepper("每 \(customIntervalDays) 天重复一次", value: $customIntervalDays, in: 1...365)
                        }

                        if recurrenceRule != .none {
                            Text("完成此待办后，将自动按「\(recurrenceRule.displayLabel(customDays: customIntervalDays))」生成下一期事项。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Section {
                        TextEditor(text: $importText)
                            .frame(minHeight: 140)
                    } header: {
                        Text("或粘贴短信 / 聊天文本")
                    } footer: {
                        Text("系统将自动识别取件码、驿站、重要账单并自动建档。可一次粘贴多条，用换行隔开。")
                    }

                    if let importResult {
                        Section("解析结果") {
                            Text(importResult)
                        }
                    }
                }
            }
            .navigationTitle(tab == 0 ? "新建待办" : "智能导入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        if tab == 0 {
                            createTodo()
                        } else {
                            runImport()
                        }
                    }
                    .disabled(tab == 0 ? title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if tab == 1 {
                    ToolbarItem(placement: .bottomBar) {
                        Button("从剪贴板粘贴", systemImage: "doc.on.clipboard") {
                            importText = UIPasteboard.general.string ?? ""
                        }
                    }
                }
            }
            .sheet(isPresented: $showingQRPreviewInAdd) {
                TodoQRCodeQuickSheet(
                    title: title.isEmpty ? "预约凭证预览" : title,
                    locationText: station.isEmpty ? nil : station,
                    dueAt: hasDueDate ? dueDate : nil,
                    detail: detail.isEmpty ? nil : detail,
                    qrCodePayload: qrCodePayload,
                    qrCodeImageData: qrCodeImageData,
                    attachmentImageData: attachmentImageData
                )
            }
            .onAppear {
                checkClipboard()
            }
        }
    }

    private func loadAndRecognizePhoto(_ pickerItem: PhotosPickerItem) async {
        await MainActor.run {
            isRecognizingImage = true
            imageRecognitionError = nil
        }
        guard let data = try? await pickerItem.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            await MainActor.run {
                isRecognizingImage = false
                imageRecognitionError = "无法读取所选图片，请重试"
            }
            return
        }
        await recognizeFromUIImage(image)
    }

    private func recognizeFromUIImage(_ image: UIImage) async {
        await MainActor.run {
            isRecognizingImage = true
            imageRecognitionError = nil
        }
        do {
            let result = try await OCRService.shared.recognizeTodo(from: image)
            await MainActor.run {
                isRecognizingImage = false
                recognizedTravelPickup = result.travelPickup
                recognizedRawText = result.rawText.isEmpty ? nil : result.rawText
                title = result.title
                type = result.type
                selectedCategory = categoryForType(result.type)
                recognitionConfidence = result.confidence
                recognitionConfidenceReason = result.confidenceReason
                recognitionSuggestedTypes = result.suggestedTypes
                showConfidenceNotice = true
                if let code = result.pickupCode, !code.isEmpty {
                    pickupCode = code
                }
                if let loc = result.location ?? result.station, !loc.isEmpty {
                    station = loc
                }
                if let recognizedDue = result.dueAt {
                    hasDueDate = true
                    dueDate = recognizedDue
                    remindBeforeMinutes = result.travelPickup != nil ? 0 : 60
                }
                if let recDetail = result.detail, !recDetail.isEmpty {
                    detail = recDetail
                }
                qrCodePayload = result.qrCodePayload
                qrCodeImageData = result.qrCodeImageData
                attachmentImageData = result.attachmentImageData
                AppMotion.animate {
                    tab = 0
                }
                Haptic.success()
            }
        } catch {
            await MainActor.run {
                isRecognizingImage = false
                imageRecognitionError = "图片识别出错：\(error.localizedDescription)"
            }
        }
    }

    private func createTodo() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }
        if hasDueDate { Task { await NotificationService.requestAuthorization() } }

        let trimmedDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCode = pickupCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedStation = station.trimmingCharacters(in: .whitespacesAndNewlines)

        let minOrder = TodoItem.minimumSortOrder(in: context)

        let item = TodoItem(
            type: type,
            status: .active,
            title: trimmedTitle,
            detail: trimmedDetail.isEmpty ? nil : trimmedDetail,
            pickupCode: trimmedCode.isEmpty ? nil : trimmedCode,
            courier: (type == .parcel || type == .returnParcel) ? (trimmedTitle.contains("快递") || trimmedTitle.contains("速递") || trimmedTitle.contains("顺丰") ? trimmedTitle : nil) : nil,
            station: trimmedStation.isEmpty ? nil : trimmedStation,
            location: trimmedStation.isEmpty ? nil : trimmedStation,
            dueAt: hasDueDate ? dueDate : nil,
            sourceText: recognizedRawText,
            sortOrder: minOrder - 1,
            recurrenceRuleRaw: recurrenceRule == .none ? nil : recurrenceRule.rawValue,
            recurrenceIntervalDays: recurrenceRule == .custom ? customIntervalDays : recurrenceRule.dayInterval(customDays: customIntervalDays),
            remindBeforeMinutes: remindBeforeMinutes == -1 ? customRemindBeforeMinutes : remindBeforeMinutes,
            qrCodePayload: qrCodePayload,
            qrCodeImageData: qrCodeImageData,
            attachmentImageData: attachmentImageData
        )
        context.insert(item)
        TodoNotificationManager.shared.scheduleNotification(for: item)

        // 票面识别到到达时间就自动挂上到站清点提醒；取件模式没有行程，不挂
        if let pickup = recognizedTravelPickup, !pickup.isPickupMode, pickup.arrivalAt > .now {
            item.arrivalReminderAt = pickup.arrivalAt
            item.arrivalTransportKind = pickup.isFlight ? .flight : .train
            TripArrivalService.shared.syncReminder(for: item)
        }

        // 用户显式勾选并确认的出行配套购票与文博景区预约待办
        if addCompanionTickets && hasDueDate {
            let proposed = TravelTicketReminderManager.shared.generateProposedTicketTodos(
                title: trimmedTitle,
                departureDate: dueDate
            )
            var offset = 2
            for var p in proposed {
                var shouldAdd = false
                if p.categoryKey == "train" && includeTrainReminder {
                    shouldAdd = true
                    if let cDate = customTrainDate {
                        p.dueAt = cDate
                        p.isCustomized = true
                    }
                }
                else if p.categoryKey == "flight" && includeFlightReminder {
                    shouldAdd = true
                }
                else if p.categoryKey == "scenic" && includeScenicReminder {
                    shouldAdd = true
                    if let cDate = customScenicDate {
                        p.dueAt = cDate
                        p.isCustomized = true
                    }
                }

                if shouldAdd {
                    let noteSuffix = p.isCustomized ? "\n（注：预约时间已由用户核对并手动确认）" : ""
                    let compItem = TodoItem(
                        type: .travelBooking,
                        status: .active,
                        title: p.title,
                        detail: p.detail + noteSuffix,
                        dueAt: p.dueAt,
                        sortOrder: minOrder - offset,
                        remindBeforeMinutes: p.remindBeforeMinutes
                    )
                    context.insert(compItem)
                    TodoNotificationManager.shared.scheduleNotification(for: compItem)
                    offset += 1
                }
            }
        }

        try? context.save()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        dismiss()
    }

    private func runImport() {
        let service = ImportService(context: context)
        let chunks = importText.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var lines: [String] = []
        for chunk in chunks {
            do {
                lines.append(try service.ingest(chunk, source: "manual").summary)
            } catch {
                lines.append("失败：\(error.localizedDescription)")
            }
        }
        importResult = lines.joined(separator: "\n")
        importText = ""
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            dismiss()
        }
    }
}
