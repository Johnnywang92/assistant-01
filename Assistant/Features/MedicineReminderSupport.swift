import AssistantCore
import Foundation
import SwiftData
import SwiftUI
import UIKit
import UserNotifications

/// 每日频次选项
struct FrequencyChoice: Hashable, Identifiable {
    var id: String { title }
    let title: String
    let count: Int
    let special: String
}

/// 常用家庭药品预设库（点选后自动预填名称、类别、用法、时机、剂量、注意事项及存放建议）
struct CommonMedicinePreset: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let category: MedicineCategory
    let indications: String
    let frequencyCount: Int
    let frequencySpecial: String
    let dosageAmount: Double
    let dosageUnit: String
    let mealRelation: MedicationMealRelation
    let route: String
    let precautions: String
    let recommendedArea: String
    let recommendedLocation: String
    let afterOpenDays: Int?
}

/// 常用家庭常备药智能知识库
let commonMedicinePresets: [CommonMedicinePreset] = [
    CommonMedicinePreset(
        name: "布洛芬缓释胶囊",
        category: .otc,
        indications: "退烧止痛、缓解头痛关节痛与痛经",
        frequencyCount: 2,
        frequencySpecial: "",
        dosageAmount: 1,
        dosageUnit: "粒",
        mealRelation: .afterMeal(minutes: 30),
        route: "口服",
        precautions: "避免空腹服用以防胃刺激，胃溃疡患者慎用，服药期间严禁饮酒",
        recommendedArea: "储物间",
        recommendedLocation: "家庭药箱",
        afterOpenDays: nil
    ),
    CommonMedicinePreset(
        name: "对乙酰氨基酚片",
        category: .otc,
        indications: "感冒发热头痛、轻中度肌肉关节酸痛",
        frequencyCount: 3,
        frequencySpecial: "",
        dosageAmount: 1,
        dosageUnit: "片",
        mealRelation: .afterMeal(minutes: 30),
        route: "口服",
        precautions: "24小时内严禁超过4次，切勿与含同成分复方感冒药混服，严禁饮酒",
        recommendedArea: "储物间",
        recommendedLocation: "家庭药箱",
        afterOpenDays: nil
    ),
    CommonMedicinePreset(
        name: "维生素C泡腾片",
        category: .supplement,
        indications: "补充日常维生素C、抗氧化、增强免疫力",
        frequencyCount: 1,
        frequencySpecial: "",
        dosageAmount: 1,
        dosageUnit: "片",
        mealRelation: .afterMeal(minutes: 15),
        route: "温水冲服",
        precautions: "放入冷水或温水中完全溶解后饮用，严禁直接吞服或含服",
        recommendedArea: "客厅",
        recommendedLocation: "电视柜抽屉",
        afterOpenDays: 60
    ),
    CommonMedicinePreset(
        name: "氯雷他定片",
        category: .otc,
        indications: "过敏性鼻炎、慢性荨麻疹、皮肤瘙痒与过敏",
        frequencyCount: 1,
        frequencySpecial: "每晚睡前",
        dosageAmount: 1,
        dosageUnit: "片",
        mealRelation: .bedtime,
        route: "口服",
        precautions: "偶有嗜睡或口干反应，驾驶员或高空机械操作者慎用",
        recommendedArea: "主卧",
        recommendedLocation: "床头柜",
        afterOpenDays: nil
    ),
    CommonMedicinePreset(
        name: "蒙脱石散",
        category: .otc,
        indications: "急慢性腹泻、胃肠道黏膜保护与止泻",
        frequencyCount: 3,
        frequencySpecial: "",
        dosageAmount: 1,
        dosageUnit: "袋",
        mealRelation: .beforeMeal(minutes: 30),
        route: "温水冲服",
        precautions: "倒入半杯温水中搅匀服用，与其他药物服用必须间隔1~2小时",
        recommendedArea: "储物间",
        recommendedLocation: "家庭药箱",
        afterOpenDays: nil
    ),
    CommonMedicinePreset(
        name: "阿莫西林胶囊",
        category: .prescription,
        indications: "敏感菌引起的呼吸道、扁桃体或泌尿系统感染",
        frequencyCount: 3,
        frequencySpecial: "",
        dosageAmount: 1,
        dosageUnit: "粒",
        mealRelation: .afterMeal(minutes: 30),
        route: "口服",
        precautions: "青霉素过敏者禁用，处方药请遵医嘱按疗程服满，不可擅自停药",
        recommendedArea: "储物间",
        recommendedLocation: "家庭药箱",
        afterOpenDays: nil
    ),
    CommonMedicinePreset(
        name: "左氧氟沙星滴眼液",
        category: .topical,
        indications: "细菌性结膜炎、角膜炎、眼睑充血红肿",
        frequencyCount: 3,
        frequencySpecial: "",
        dosageAmount: 1,
        dosageUnit: "滴",
        mealRelation: .unrestricted,
        route: "滴眼",
        precautions: "滴眼时滴嘴切勿接触睫毛，开封后建议 28 天内使用完毕",
        recommendedArea: "书房",
        recommendedLocation: "办公桌",
        afterOpenDays: 28
    ),
    CommonMedicinePreset(
        name: "防水透气创可贴",
        category: .device,
        indications: "表皮浅表擦伤、小切口止血与保护创面",
        frequencyCount: 0,
        frequencySpecial: "按需外用",
        dosageAmount: 1,
        dosageUnit: "贴",
        mealRelation: .unrestricted,
        route: "外用涂抹",
        precautions: "贴敷前清洁消毒伤口，若潮湿渗血请及时更换",
        recommendedArea: "储物间",
        recommendedLocation: "家庭药箱第一层",
        afterOpenDays: nil
    ),
    CommonMedicinePreset(
        name: "连花清瘟胶囊",
        category: .tcm,
        indications: "清瘟解毒、宣肺泄热，缓解发热恶寒、肌肉酸痛与咽痛",
        frequencyCount: 3,
        frequencySpecial: "",
        dosageAmount: 4,
        dosageUnit: "粒",
        mealRelation: .afterMeal(minutes: 30),
        route: "口服",
        precautions: "服药期间忌烟酒、辛辣生冷油腻食物，风寒感冒者不适用",
        recommendedArea: "储物间",
        recommendedLocation: "家庭药箱",
        afterOpenDays: nil
    ),
    CommonMedicinePreset(
        name: "碳酸钙D3片",
        category: .supplement,
        indications: "补充日常钙质、预防骨质疏松、促进骨骼健康",
        frequencyCount: 1,
        frequencySpecial: "每晚睡前",
        dosageAmount: 1,
        dosageUnit: "片",
        mealRelation: .bedtime,
        route: "口服",
        precautions: "晚餐后或睡前咀嚼或温水送服，多饮水，高钙血症禁用",
        recommendedArea: "客厅",
        recommendedLocation: "电视柜抽屉",
        afterOpenDays: nil
    ),
    CommonMedicinePreset(
        name: "奥美拉唑肠溶胶囊",
        category: .otc,
        indications: "胃酸过多、反酸烧心、胃溃疡及十二指肠溃疡",
        frequencyCount: 1,
        frequencySpecial: "晨起空腹",
        dosageAmount: 1,
        dosageUnit: "粒",
        mealRelation: .beforeMeal(minutes: 30),
        route: "口服",
        precautions: "整粒吞服严禁嚼碎，晨起空腹服用效果最佳",
        recommendedArea: "储物间",
        recommendedLocation: "家庭药箱",
        afterOpenDays: nil
    )
]

/// 常备药用药方法配置（手滑动作业、标准语句合成、多频次提醒时刻智能推导）
struct MedicineUsageDraft: Equatable {
    var frequencyCount: Int = 3 // 0: 按需/必要时; 1..6: 一日N次
    var frequencySpecial: String = "" // "每晚睡前", "晨起空腹", "每隔8小时", "每隔12小时"
    var dosageAmount: Double = 1.0
    var dosageUnit: String = "片"
    var mealRelation: MedicationMealRelation = .afterMeal(minutes: 30)
    var route: String = "口服"
    var customNote: String = ""

    var formattedAmount: String {
        dosageAmount == dosageAmount.rounded() ? String(Int(dosageAmount)) : String(format: "%g", dosageAmount)
    }

    /// 格式化为用于展示和保存的标准说明
    var formattedUsage: String {
        var parts: [String] = []
        if !frequencySpecial.isEmpty {
            parts.append(frequencySpecial)
        } else if frequencyCount > 0 {
            parts.append("一日 \(frequencyCount) 次")
        } else {
            parts.append("必要时/按需")
        }

        parts.append("每次 \(formattedAmount) \(dosageUnit)")

        if mealRelation != .unrestricted {
            parts.append(mealRelation.displayName)
        }

        if !route.isEmpty && route != "口服" {
            parts.append(route)
        } else if route == "口服" {
            parts.append("口服温水送服")
        }

        let trimmedNote = customNote.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNote.isEmpty {
            parts.append("（\(trimmedNote)）")
        }

        return parts.joined(separator: "，")
    }

    /// 根据当前用法自动推断的一日多次服药提醒时刻
    var defaultTimePoints: [String] {
        if !frequencySpecial.isEmpty {
            if frequencySpecial == "每晚睡前" || frequencySpecial == "睡前" { return ["21:30"] }
            if frequencySpecial == "晨起空腹" { return ["07:30"] }
            if frequencySpecial == "每隔8小时" { return ["07:00", "15:00", "23:00"] }
            if frequencySpecial == "每隔12小时" { return ["08:00", "20:00"] }
        }
        switch frequencyCount {
        case 1:
            if mealRelation == .bedtime { return ["21:30"] }
            if case .beforeMeal = mealRelation { return ["07:30"] }
            return ["08:30"]
        case 2:
            return ["08:00", "20:00"]
        case 3:
            return ["08:00", "13:00", "19:00"]
        case 4:
            return ["08:00", "12:00", "16:00", "20:00"]
        case 5:
            return ["07:00", "10:30", "14:00", "17:30", "21:00"]
        case 6:
            return ["07:00", "10:00", "13:00", "16:00", "19:00", "22:00"]
        default:
            return ["09:00"]
        }
    }

    func matchesFrequency(_ choice: FrequencyChoice) -> Bool {
        if !choice.special.isEmpty {
            return frequencySpecial == choice.special
        }
        return frequencySpecial.isEmpty && frequencyCount == choice.count
    }

    mutating func applyFrequency(_ choice: FrequencyChoice) {
        if !choice.special.isEmpty {
            frequencySpecial = choice.special
            if choice.special == "每晚睡前" {
                frequencyCount = 1
                mealRelation = .bedtime
            } else if choice.special == "晨起空腹" {
                frequencyCount = 1
                mealRelation = .beforeMeal(minutes: 30)
            } else if choice.special == "每隔8小时" {
                frequencyCount = 3
            } else if choice.special == "每隔12小时" {
                frequencyCount = 2
            } else if choice.special.contains("按需") {
                frequencyCount = 0
            }
        } else {
            frequencySpecial = ""
            frequencyCount = choice.count
            if mealRelation == .bedtime {
                mealRelation = .afterMeal(minutes: 30)
            }
        }
    }

    /// 从历史存量自由文本中智能反向解析
    static func parse(from text: String) -> MedicineUsageDraft {
        var draft = MedicineUsageDraft()
        guard !text.isEmpty else { return draft }

        // 频次识别
        if text.contains("睡前") {
            draft.frequencySpecial = "每晚睡前"
            draft.frequencyCount = 1
            draft.mealRelation = .bedtime
        } else if text.contains("晨起") || text.contains("早晨") {
            draft.frequencySpecial = "晨起空腹"
            draft.frequencyCount = 1
            draft.mealRelation = .beforeMeal(minutes: 30)
        } else if text.contains("8小时") {
            draft.frequencySpecial = "每隔8小时"
            draft.frequencyCount = 3
        } else if text.contains("12小时") {
            draft.frequencySpecial = "每隔12小时"
            draft.frequencyCount = 2
        } else if text.contains("按需") || text.contains("必要时") {
            draft.frequencyCount = 0
            draft.frequencySpecial = "必要时/按需"
        } else if let match = text.range(of: #"[一日每天日]\s*([1-6一二三四五六])\s*次"#, options: .regularExpression) {
            let sub = String(text[match])
            if sub.contains("1") || sub.contains("一") { draft.frequencyCount = 1 }
            else if sub.contains("2") || sub.contains("二") { draft.frequencyCount = 2 }
            else if sub.contains("3") || sub.contains("三") { draft.frequencyCount = 3 }
            else if sub.contains("4") || sub.contains("四") { draft.frequencyCount = 4 }
            else if sub.contains("5") || sub.contains("五") { draft.frequencyCount = 5 }
            else if sub.contains("6") || sub.contains("六") { draft.frequencyCount = 6 }
        }

        // 单位与数值
        let units = ["毫升", "ml", "片", "粒", "颗", "袋", "支", "滴", "包", "丸", "贴", "喷", "勺"]
        for u in units {
            if text.contains(u) {
                draft.dosageUnit = (u == "ml") ? "毫升" : u
                break
            }
        }
        if let match = text.range(of: #"(?:每次|各|服)\s*([0-9]+(?:\.[0-9]+)?)"#, options: .regularExpression) {
            let numStr = String(text[match]).components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted).joined()
            if let val = Double(numStr), val > 0 {
                draft.dosageAmount = val
            }
        }

        // 时效
        if text.contains("饭后30") { draft.mealRelation = .afterMeal(minutes: 30) }
        else if text.contains("饭后15") { draft.mealRelation = .afterMeal(minutes: 15) }
        else if text.contains("饭后") { draft.mealRelation = .afterMeal(minutes: 30) }
        else if text.contains("饭前30") { draft.mealRelation = .beforeMeal(minutes: 30) }
        else if text.contains("饭前") { draft.mealRelation = .beforeMeal(minutes: 30) }
        else if text.contains("随餐") { draft.mealRelation = .withMeal }
        else if text.contains("睡前") { draft.mealRelation = .bedtime }
        else if text.contains("不限") { draft.mealRelation = .unrestricted }

        // 途径
        if text.contains("外用") || text.contains("涂抹") { draft.route = "外用涂抹" }
        else if text.contains("滴眼") { draft.route = "滴眼" }
        else if text.contains("滴鼻") { draft.route = "滴鼻" }
        else if text.contains("含服") { draft.route = "舌下含服" }
        else if text.contains("冲服") { draft.route = "温水冲服" }
        else if text.contains("喷") { draft.route = "喷雾吸入" }
        else { draft.route = "口服" }

        return draft
    }
}

/// 弹出设置用药提醒的目标包装
struct ReminderMedicineTarget: Identifiable {
    var id: UUID { medicine.id }
    let medicine: MedicineItem
    let usageDraft: MedicineUsageDraft
}

/// 添加完药品后弹出的设置用药提醒 Sheet（按照 一日N次 自动适配排期）
struct AddMedicationReminderPopupSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var allPlans: [MedicationPlan]

    let medicine: MedicineItem
    let usageDraft: MedicineUsageDraft
    var onComplete: () -> Void = {}

    @State private var timePoints: [Date] = []
    @State private var alsoCreateTodo: Bool = true
    @State private var enableNotifications: Bool = true

    private var activePlan: MedicationPlan? {
        allPlans.first { $0.medName == medicine.name && $0.isEnabled }
    }

    private var hasExistingPlan: Bool {
        allPlans.contains { $0.medName == medicine.name }
    }

    init(medicine: MedicineItem, usageDraft: MedicineUsageDraft, onComplete: @escaping () -> Void = {}) {
        self.medicine = medicine
        self.usageDraft = usageDraft
        self.onComplete = onComplete

        let cal = Calendar.current
        let defaultStrings = usageDraft.defaultTimePoints
        let dates = defaultStrings.compactMap { str -> Date? in
            let parts = str.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2 else { return nil }
            return cal.date(from: DateComponents(hour: parts[0], minute: parts[1]))
        }
        self._timePoints = State(initialValue: dates.isEmpty ? [cal.date(from: DateComponents(hour: 8, minute: 0)) ?? .now] : dates)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color.green.opacity(0.15))
                                .frame(width: 46, height: 46)
                            Image(systemName: "pills.fill")
                                .font(.title3)
                                .foregroundStyle(.green)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(medicine.name)
                                .font(.headline)
                            Text(usageDraft.formattedUsage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("常备药信息")
                } footer: {
                    Text("系统已根据用法（\(usageFrequencySummary)）自动匹配提醒时间，可在下方按个人作息微调时刻。")
                }

                // 若当前该药物已有进行中的提醒，显示一键停止按钮
                if activePlan != nil {
                    Section {
                        HStack(spacing: 10) {
                            Image(systemName: "bell.badge.fill")
                                .font(.title3)
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("用药提醒进行中")
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.orange)
                                Text("每日 \(activePlan?.dailyTimePoints.count ?? timePoints.count) 次定时提醒已启用")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 2)

                        Button(role: .destructive) {
                            _ = MedicineStockHelper.stopReminder(for: medicine.name, context: context)
                            dismiss()
                            onComplete()
                        } label: {
                            HStack {
                                Spacer()
                                Label("一键停止用药提醒（病愈停服）", systemImage: "bell.slash.fill")
                                    .font(.headline)
                                Spacer()
                            }
                            .padding(.vertical, 4)
                        }
                    } header: {
                        Text("当前提醒状态")
                    } footer: {
                        Text("病愈后一键停止提醒：常备药档案与保质期监控完整保留，立即撤销每日定时通知并清理今日未服待办。后续若需再次服药可随时重新开启。")
                    }
                }

                Section("每日服药时刻（已适配 \(timePoints.count) 次/天）") {
                    ForEach(timePoints.indices, id: \.self) { idx in
                        HStack {
                            Label(timeSlotTitle(for: idx, total: timePoints.count), systemImage: timeSlotIcon(for: idx, total: timePoints.count))
                                .font(.subheadline)
                            Spacer()
                            DatePicker(
                                "",
                                selection: Binding(
                                    get: { timePoints.indices.contains(idx) ? timePoints[idx] : .now },
                                    set: { if timePoints.indices.contains(idx) { timePoints[idx] = $0 } }
                                ),
                                displayedComponents: .hourAndMinute
                            )
                            .labelsHidden()

                            if timePoints.count > 1 {
                                Button(role: .destructive) {
                                    timePoints.remove(at: idx)
                                    Haptic.light()
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                                .padding(.leading, 4)
                            }
                        }
                    }

                    if timePoints.count < 6 {
                        Button {
                            let nextHour = defaultNextHour(currentCount: timePoints.count)
                            if let d = Calendar.current.date(from: DateComponents(hour: nextHour, minute: 0)) {
                                timePoints.append(d)
                                timePoints.sort()
                                Haptic.light()
                            }
                        } label: {
                            Label("增加一次提醒时刻", systemImage: "plus.circle")
                                .font(.subheadline)
                        }
                    }
                }

                Section {
                    Toggle(isOn: $enableNotifications) {
                        Label("系统定时推送提醒", systemImage: "bell.badge.fill")
                    }
                    Toggle(isOn: $alsoCreateTodo) {
                        Label("在待办中生成今日服药任务", systemImage: "checklist")
                    }
                } header: {
                    Text("联动选项")
                } footer: {
                    Text("开启后将在设定时间通过 iPhone 与 Apple Watch 发送服药提醒；待办列表中也将生成服药条目，方便打卡。")
                }

                Section {
                    Button {
                        saveRemindersAndFinish()
                    } label: {
                        HStack {
                            Spacer()
                            Text(activePlan != nil ? "更新用药提醒排期" : "开启每日用药提醒")
                                .font(.headline)
                                .foregroundStyle(.white)
                            Spacer()
                        }
                        .padding(.vertical, 6)
                    }
                    .listRowBackground(Color.green)
                }

                Section {
                    Button(activePlan != nil ? "完成返回" : "暂不设置提醒") {
                        dismiss()
                        onComplete()
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(activePlan != nil ? "管理用药提醒" : "添加用药提醒")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        dismiss()
                        onComplete()
                    }
                }
            }
            .onAppear {
                if let existing = allPlans.first(where: { $0.medName == medicine.name }), !existing.dailyTimePoints.isEmpty {
                    let cal = Calendar.current
                    let dates = existing.dailyTimePoints.compactMap { str -> Date? in
                        let parts = str.split(separator: ":").compactMap { Int($0) }
                        guard parts.count == 2 else { return nil }
                        return cal.date(from: DateComponents(hour: parts[0], minute: parts[1]))
                    }
                    if !dates.isEmpty {
                        timePoints = dates
                        enableNotifications = existing.isEnabled
                    }
                }
            }
        }
    }

    private var usageFrequencySummary: String {
        if usageDraft.frequencyCount > 0 {
            return "一日 \(usageDraft.frequencyCount) 次"
        }
        if !usageDraft.frequencySpecial.isEmpty {
            return usageDraft.frequencySpecial
        }
        return "按需/必要时"
    }

    private func timeSlotTitle(for index: Int, total: Int) -> String {
        if total == 1 {
            if usageDraft.mealRelation == .bedtime { return "睡前" }
            if case .beforeMeal = usageDraft.mealRelation { return "晨起空腹" }
            return "每日服药"
        }
        if total == 2 {
            return index == 0 ? "早晨 (第1次)" : "晚间 (第2次)"
        }
        if total == 3 {
            switch index {
            case 0: return "早晨 (早餐)"
            case 1: return "午间 (午餐)"
            default: return "晚间 (晚餐)"
            }
        }
        if total == 4 {
            switch index {
            case 0: return "早晨 (08:00)"
            case 1: return "午间 (12:00)"
            case 2: return "下午 (16:00)"
            default: return "晚间 (20:00)"
            }
        }
        return "第 \(index + 1) 次"
    }

    private func timeSlotIcon(for index: Int, total: Int) -> String {
        if total == 1 {
            if usageDraft.mealRelation == .bedtime { return "moon.stars.fill" }
            return "sun.horizon.fill"
        }
        if index == 0 { return "sunrise.fill" }
        if index == total - 1 { return "moon.stars.fill" }
        if index == 1 && total >= 3 { return "sun.max.fill" }
        return "clock.fill"
    }

    private func defaultNextHour(currentCount: Int) -> Int {
        let hours = [8, 13, 19, 21, 16, 11]
        return currentCount < hours.count ? hours[currentCount] : 12
    }

    private func saveRemindersAndFinish() {
        let sortedDates = timePoints.sorted()
        let timeStrings = sortedDates.map { date in
            let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
            return String(format: "%02d:%02d", comps.hour ?? 8, comps.minute ?? 0)
        }

        let amtStr = usageDraft.dosageAmount == usageDraft.dosageAmount.rounded()
            ? String(Int(usageDraft.dosageAmount))
            : String(format: "%g", usageDraft.dosageAmount)
        let dosageStr = "每次 \(amtStr) \(usageDraft.dosageUnit)"

        let targetName = medicine.name
        let descriptor = FetchDescriptor<MedicationPlan>(predicate: #Predicate { $0.medName == targetName })
        let existingPlans = (try? context.fetch(descriptor)) ?? []

        let targetPlan: MedicationPlan
        if let existing = existingPlans.first {
            existing.dosage = dosageStr
            existing.dailyTimePoints = timeStrings
            existing.mealRelation = usageDraft.mealRelation
            existing.isEnabled = enableNotifications
            existing.notes = medicine.indications
            targetPlan = existing
        } else {
            let plan = MedicationPlan(
                medName: medicine.name,
                dosage: dosageStr,
                dailyTimePoints: timeStrings,
                notes: medicine.indications,
                mealRelation: usageDraft.mealRelation
            )
            plan.isEnabled = enableNotifications
            context.insert(plan)
            targetPlan = plan
        }

        try? context.save()
        let scheduler = HabitAndMedicationScheduler(context: context)
        // 「今日服药任务」走统一物化规则：当天全部时点都落待办（漏服的以逾期形态供补打卡），
        // 同名未完成/今日已打卡的自动去重，不再只生成「尚未到点」的条目。
        if alsoCreateTodo {
            scheduler.ensureTodayMedicationTodos(for: targetPlan)
        }
        scheduler.scheduleMedicationReminders()
        Haptic.success()
        dismiss()
        onComplete()
    }
}

// MARK: - 按症状快速找药筛选

enum MedicineSymptomFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case feverPain = "退烧止痛"
    case coldCough = "感冒咽痛"
    case stomachDiarrhea = "肠胃腹泻"
    case allergy = "过敏止痒"
    case externalEye = "外用/滴眼"
    case supplement = "维C/保健"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .all: return "pills.fill"
        case .feverPain: return "thermometer.high"
        case .coldCough: return "facemask.fill"
        case .stomachDiarrhea: return "cross.vial.fill"
        case .allergy: return "allergens.fill"
        case .externalEye: return "eye.fill"
        case .supplement: return "leaf.fill"
        }
    }

    var keywords: [String] {
        switch self {
        case .all:
            return []
        case .feverPain:
            return ["退烧", "发热", "发烧", "止痛", "镇痛", "头痛", "关节痛", "痛经", "牙痛", "布洛芬", "对乙酰氨基酚", "洛索洛芬", "双氯芬酸"]
        case .coldCough:
            return ["感冒", "咽痛", "咳嗽", "化痰", "鼻塞", "流涕", "清瘟", "阿莫西林", "头孢", "阿奇霉素", "蓝芩", "蒲地蓝", "右美沙芬"]
        case .stomachDiarrhea:
            return ["腹泻", "止泻", "胃", "反酸", "烧心", "消化", "胀气", "便秘", "蒙脱石", "奥美拉唑", "雷贝拉唑", "益生菌", "健胃", "铝碳酸镁", "黄连素"]
        case .allergy:
            return ["过敏", "鼻炎", "荨麻疹", "瘙痒", "止痒", "氯雷他定", "西替利嗪", "孟鲁司特", "糠酸莫米松"]
        case .externalEye:
            return ["滴眼", "眼", "结膜", "外用", "擦伤", "创可贴", "伤口", "消毒", "碘伏", "软膏", "乳膏", "左氧氟沙星", "莫匹罗星", "红霉素"]
        case .supplement:
            return ["维生素", "维c", "钙", "免疫", "抗氧化", "鱼油", "叶酸", "铁", "锌", "辅酶", "骨质"]
        }
    }

    func matches(_ medicine: MedicineItem) -> Bool {
        if self == .all { return true }
        if self == .externalEye && (medicine.category == .topical || medicine.category == .device) {
            return true
        }
        if self == .supplement && medicine.category == .supplement {
            return true
        }
        let haystack = [
            medicine.name,
            medicine.indications ?? "",
            medicine.usageMethod ?? "",
            medicine.precautions ?? ""
        ].joined(separator: " ").lowercased()

        return keywords.contains { haystack.contains($0.lowercased()) }
    }
}

// MARK: - 药盒/说明书拍照智能 OCR 解析器

struct MedicineBoxOCRResult {
    var matchedPreset: CommonMedicinePreset? = nil
    var name: String? = nil
    var category: MedicineCategory? = nil
    var indications: String? = nil
    var usageDraft: MedicineUsageDraft? = nil
    var remainingQuantity: String? = nil
    var precautions: String? = nil
    var expiryDate: Date? = nil
    var afterOpenDays: Int? = nil

    var hasAnyField: Bool {
        matchedPreset != nil || name != nil || indications != nil || usageDraft != nil || expiryDate != nil || remainingQuantity != nil
    }

    var summaryText: String {
        var parts: [String] = []
        if let n = name ?? matchedPreset?.name {
            parts.append(n)
        }
        if let u = usageDraft {
            let freq = u.frequencyCount > 0 ? "一日\(u.frequencyCount)次" : (u.frequencySpecial.isEmpty ? "按需" : u.frequencySpecial)
            parts.append("\(freq) 每次\(u.formattedAmount)\(u.dosageUnit)")
        }
        if let exp = expiryDate {
            parts.append("有效至 \(exp.formatted(.dateTime.year().month()))")
        }
        if let q = remainingQuantity {
            parts.append(q)
        }
        return parts.isEmpty ? "已提取药盒信息" : parts.joined(separator: " · ")
    }
}

enum MedicineBoxOCRParser {
    static func parse(from rawText: String) -> MedicineBoxOCRResult {
        var result = MedicineBoxOCRResult()
        let cleanedText = rawText.replacingOccurrences(of: "：", with: ":")
        let lines = cleanedText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return result }

        // 1. 先匹配常见家庭药知识库（支持核心通用名命中）
        for preset in commonMedicinePresets {
            let coreName = preset.name
                .replacingOccurrences(of: "缓释胶囊", with: "")
                .replacingOccurrences(of: "肠溶胶囊", with: "")
                .replacingOccurrences(of: "胶囊", with: "")
                .replacingOccurrences(of: "泡腾片", with: "")
                .replacingOccurrences(of: "滴眼液", with: "")
                .replacingOccurrences(of: "防水透气", with: "")
                .replacingOccurrences(of: "片", with: "")
            if coreName.count >= 2 && cleanedText.contains(coreName) {
                result.matchedPreset = preset
                result.name = preset.name
                result.category = preset.category
                result.indications = preset.indications
                result.precautions = preset.precautions
                result.afterOpenDays = preset.afterOpenDays
                var draft = MedicineUsageDraft()
                draft.frequencyCount = preset.frequencyCount
                draft.frequencySpecial = preset.frequencySpecial
                draft.dosageAmount = preset.dosageAmount
                draft.dosageUnit = preset.dosageUnit
                draft.mealRelation = preset.mealRelation
                draft.route = preset.route
                result.usageDraft = draft
                break
            }
        }

        // 2. 若未命中预设药名，从 OCR 文本行提取药品通用名（带剂型后缀）
        if result.name == nil {
            let suffixPattern = #"([\u4e00-\u9fa5A-Za-z0-9]{2,16}(?:缓释胶囊|肠溶胶囊|软胶囊|胶囊|泡腾片|分散片|咀嚼片|薄膜衣片|肠溶片|含片|片|颗粒|滴眼液|眼膏|软膏|乳膏|凝胶|喷雾剂|气雾剂|口服液|糖浆|混悬液|散|丸|贴|滴丸|合剂|栓))"#
            let blacklist = ["说明书", "适应症", "用法用量", "不良反应", "注意事项", "有效期", "生产企业", "批准文号", "国药准字", "请仔细阅读", "医师指导", "运动员慎用"]
            for line in lines {
                if blacklist.contains(where: { line.contains($0) }) { continue }
                if let range = line.range(of: suffixPattern, options: .regularExpression) {
                    let candidate = String(line[range])
                    if candidate.count >= 3 && candidate.count <= 18 {
                        result.name = candidate
                        break
                    }
                }
            }
        }

        // 3. 识别药品类别
        if cleanedText.contains("处方药") && !cleanedText.contains("非处方药") {
            result.category = .prescription
        } else if cleanedText.contains("OTC") || cleanedText.contains("非处方") {
            result.category = .otc
        } else if cleanedText.contains("国药准字Z") || cleanedText.contains("中成药") || cleanedText.contains("清热") || cleanedText.contains("解毒") {
            result.category = .tcm
        } else if cleanedText.contains("滴眼") || cleanedText.contains("外用") || cleanedText.contains("乳膏") || cleanedText.contains("软膏") {
            result.category = .topical
        } else if cleanedText.contains("维生素") || cleanedText.contains("保健食品") || cleanedText.contains("膳食补充") {
            result.category = .supplement
        }

        // 4. 识别用法用量（频次、单次剂量、单位、服药时机、给药途径）
        let hasUsageHint = cleanedText.contains("一日") || cleanedText.contains("每日") || cleanedText.contains("一天") ||
            cleanedText.contains("一次") || cleanedText.contains("每次") || cleanedText.contains("口服") ||
            cleanedText.contains("冲服") || cleanedText.contains("外用") || cleanedText.contains("滴眼")
        if hasUsageHint {
            var draft = result.usageDraft ?? MedicineUsageDraft.parse(from: cleanedText)

            // 识别 "一日 2~3 次" / "每日3次" / "一日三次"
            if let freqRange = cleanedText.range(of: #"(?:一日|每日|一天)\s*(?:[1-6一二三四五六]\s*[-~至]\s*)?([1-6一二三四五六])\s*次"#, options: .regularExpression) {
                let matched = String(cleanedText[freqRange])
                if matched.contains("4") || matched.contains("四") { draft.frequencyCount = 4; draft.frequencySpecial = "" }
                else if matched.contains("3") || matched.contains("三") { draft.frequencyCount = 3; draft.frequencySpecial = "" }
                else if matched.contains("2") || matched.contains("二") { draft.frequencyCount = 2; draft.frequencySpecial = "" }
                else if matched.contains("1") || matched.contains("一") { draft.frequencyCount = 1; draft.frequencySpecial = "" }
            }

            // 识别 "一次 1~2 片" / "每次 2 粒" / "一次 10 毫升"
            if let doseRange = cleanedText.range(of: #"(?:一次|每次)\s*([0-9]+(?:\.[0-9]+)?)(?:\s*[-~至]\s*[0-9]+(?:\.[0-9]+)?)?\s*(片|粒|颗|袋|支|毫升|ml|mL|滴|包|丸|贴|喷|勺)"#, options: .regularExpression) {
                let matched = String(cleanedText[doseRange])
                let units = ["毫升", "ml", "mL", "片", "粒", "颗", "袋", "支", "滴", "包", "丸", "贴", "喷", "勺"]
                for u in units where matched.contains(u) {
                    draft.dosageUnit = (u.lowercased() == "ml") ? "毫升" : u
                    break
                }
                if let numRange = matched.range(of: #"[0-9]+(?:\.[0-9]+)?"#, options: .regularExpression),
                   let val = Double(matched[numRange]), val > 0, val <= 50 {
                    draft.dosageAmount = val
                }
            }

            result.usageDraft = draft
        }

        // 5. 识别适应症 / 功能主治
        if result.indications == nil {
            for line in lines {
                if let range = line.range(of: #"(?:适应症|功能主治|主治|用于)[:\s]*([^\n。；;]{4,45})"#, options: .regularExpression) {
                    let sub = String(line[range])
                        .replacingOccurrences(of: #"^(?:适应症|功能主治|主治|用于)[:\s]*"#, with: "", options: .regularExpression)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !sub.isEmpty {
                        result.indications = sub
                        break
                    }
                }
            }
        }

        // 6. 识别注意事项 / 禁忌
        if result.precautions == nil {
            for line in lines {
                if let range = line.range(of: #"(?:禁忌|注意事项|不良反应)[:\s]*([^\n。]{4,50})"#, options: .regularExpression) {
                    let sub = String(line[range])
                        .replacingOccurrences(of: #"^(?:禁忌|注意事项|不良反应)[:\s]*"#, with: "", options: .regularExpression)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !sub.isEmpty {
                        result.precautions = sub
                        break
                    }
                }
            }
        }

        // 7. 识别包装规格作为初始剩余数量（如 "12片/盒"、"24粒"）
        if let specRange = cleanedText.range(of: #"([0-9]{1,3})\s*(片|粒|袋|支|丸|贴|包)\s*(?:/\s*[盒瓶板袋]|装)"#, options: .regularExpression) {
            let matched = String(cleanedText[specRange])
            let num = matched.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
            let units = ["片", "粒", "袋", "支", "丸", "贴", "包"]
            if let unit = units.first(where: { matched.contains($0) }), !num.isEmpty {
                result.remainingQuantity = "剩 \(num) \(unit)"
            }
        }

        // 8. 识别有效期（如 "有效期至 2027.08" / "2027年08月15日" / "2027/08/31" / "2027-08"）
        result.expiryDate = parseExpiryDate(from: cleanedText)

        return result
    }

    private static func parseExpiryDate(from text: String) -> Date? {
        let cal = Calendar.current
        // 优先匹配带“有效期/失效期/保质期/EXP”前缀的日期
        let patterns = [
            #"(?:有效期至|有效期到|失效期|保质期至|EXP|Exp)[:\s]*?(20[2-3][0-9])[年\./\-]([0-1]?[0-9])(?:[月\./\-]([0-3]?[0-9])日?)?"#,
            #"(20[2-3][0-9])[年\./\-]([0-1]?[0-9])[月\./\-]([0-3]?[0-9])"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { continue }
            let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
            let matches = regex.matches(in: text, options: [], range: nsRange)
            var candidateDates: [Date] = []

            for match in matches {
                guard match.numberOfRanges >= 3,
                      let yRange = Range(match.range(at: 1), in: text),
                      let mRange = Range(match.range(at: 2), in: text),
                      let year = Int(text[yRange]),
                      let month = Int(text[mRange]),
                      (1...12).contains(month) else { continue }

                var day = 28
                if match.numberOfRanges >= 4,
                   let dRange = Range(match.range(at: 3), in: text),
                   let parsedDay = Int(text[dRange]),
                   (1...31).contains(parsedDay) {
                    day = parsedDay
                } else {
                    // 若只写到年月（如 2027.08），取该月最后一天
                    if let firstOfMonth = cal.date(from: DateComponents(year: year, month: month, day: 1)),
                       let range = cal.range(of: .day, in: .month, for: firstOfMonth) {
                        day = range.upperBound - 1
                    }
                }

                if let date = cal.date(from: DateComponents(year: year, month: month, day: day)) {
                    candidateDates.append(date)
                }
            }

            // 如果同一个药盒上既有生产日期又有有效期，取最晚的日期作为有效期
            if let latest = candidateDates.max() {
                return latest
            }
        }
        return nil
    }
}

// MARK: - 一键服药打卡与余量自动扣减助手

enum MedicineStockHelper {
    /// 服用一次药品：自动扣减数字库存、同步打卡用药计划、完成今日对应服药待办，并在库存不足时生成买药待办
    @MainActor
    static func takeOneDose(medicine: MedicineItem, context: ModelContext) -> String {
        let draft = MedicineUsageDraft.parse(from: medicine.usageMethod ?? "")
        let doseAmount = draft.dosageAmount > 0 ? draft.dosageAmount : 1.0
        let doseUnit = draft.dosageUnit

        var feedbackParts: [String] = ["已记录服用 \(draft.formattedAmount)\(doseUnit)"]

        // 1. 自动扣减剩余数量（如果包含数字，例如 "剩 10 片" -> "剩 9 片"）
        if let currentQty = medicine.remainingQuantity, !currentQty.isEmpty {
            let (updatedQty, remainingNum) = decrementQuantityString(currentQty, by: doseAmount, defaultUnit: doseUnit)
            if let updatedQty {
                medicine.remainingQuantity = updatedQty
                feedbackParts.append(updatedQty)
            }
            if let remainingNum, remainingNum <= 2 {
                ensureRestockTodo(for: medicine, reason: "余量仅剩 \(updatedQty ?? "不足")", context: context)
                feedbackParts.append("已加入买药待办")
            }
        }

        medicine.updatedAt = .now

        // 2. 联动更新同名的 MedicationPlan 打卡状态
        let targetName = medicine.name
        let planDescriptor = FetchDescriptor<MedicationPlan>(predicate: #Predicate { $0.medName == targetName })
        if let plans = try? context.fetch(planDescriptor) {
            for plan in plans {
                plan.markTaken()
            }
        }

        // 3. 联动完成今日待办列表中的同名服药任务（取最早一条未完成的）
        let activeRaw = TodoStatus.active.rawValue
        let medTypeRaw = TodoType.medication.rawValue
        let todoDescriptor = FetchDescriptor<TodoItem>(
            predicate: #Predicate { $0.typeRaw == medTypeRaw && $0.statusRaw == activeRaw }
        )
        if let activeMedTodos = try? context.fetch(todoDescriptor) {
            let matching = activeMedTodos
                .filter { $0.title.contains(targetName) }
                .sorted { ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture) }
            if let firstTodo = matching.first {
                firstTodo.status = .done
                firstTodo.completedAt = .now
            }
        }

        try? context.save()
        Haptic.success()
        return feedbackParts.joined(separator: " · ")
    }

    /// 一键清理过期/临期药品并加入补货购买待办
    @MainActor
    static func disposeAndCreateRestockTodo(medicines: [MedicineItem], context: ModelContext) -> Int {
        var count = 0
        for med in medicines where !med.isDisposed {
            med.isDisposed = true
            med.updatedAt = .now
            let reason = med.isExpired ? "原药品已过期处理" : "原药品临近到期更换"
            ensureRestockTodo(for: med, reason: reason, context: context)
            count += 1
        }
        try? context.save()
        Haptic.success()
        return count
    }

    @MainActor
    static func ensureRestockTodo(for medicine: MedicineItem, reason: String, context: ModelContext) {
        let title = "补充常备药：\(medicine.name)"
        let activeRaw = TodoStatus.active.rawValue
        let descriptor = FetchDescriptor<TodoItem>(
            predicate: #Predicate { $0.title == title && $0.statusRaw == activeRaw }
        )
        let existing = (try? context.fetch(descriptor)) ?? []
        guard existing.isEmpty else { return }

        var detailParts: [String] = [reason]
        if let ind = medicine.indications, !ind.isEmpty {
            detailParts.append("用途：\(ind)")
        }
        detailParts.append("常放位置：\(medicine.roomArea)·\(medicine.storageLocation)")

        let todo = TodoItem(
            type: .general,
            status: .active,
            title: title,
            detail: detailParts.joined(separator: " · "),
            dueAt: Calendar.current.date(byAdding: .day, value: 1, to: .now)
        )
        context.insert(todo)
    }

    /// 一键停止服药提醒（保留常备药档案，停用提醒计划、撤销推送并清理未完成待办）
    @MainActor
    @discardableResult
    static func stopReminder(for medicineName: String, context: ModelContext) -> Bool {
        let descriptor = FetchDescriptor<MedicationPlan>(
            predicate: #Predicate { $0.medName == medicineName }
        )
        guard let plans = try? context.fetch(descriptor), !plans.isEmpty else {
            return false
        }
        for plan in plans {
            plan.isEnabled = false
            HabitAndMedicationScheduler.cancelMedicationReminders(for: plan.id)
        }

        // 清理今日待办中关于该药品的未完成服药打卡任务
        let activeRaw = TodoStatus.active.rawValue
        let medTypeRaw = TodoType.medication.rawValue
        let todoDescriptor = FetchDescriptor<TodoItem>(
            predicate: #Predicate { $0.typeRaw == medTypeRaw && $0.statusRaw == activeRaw }
        )
        if let activeMedTodos = try? context.fetch(todoDescriptor) {
            let matching = activeMedTodos.filter { $0.title.contains(medicineName) }
            for todo in matching {
                context.delete(todo)
            }
        }

        try? context.save()
        let scheduler = HabitAndMedicationScheduler(context: context)
        scheduler.scheduleMedicationReminders()
        Haptic.success()
        return true
    }

    private static func decrementQuantityString(_ text: String, by amount: Double, defaultUnit: String) -> (String?, Double?) {
        guard let range = text.range(of: #"[0-9]+(?:\.[0-9]+)?"#, options: .regularExpression),
              let currentVal = Double(text[range]) else {
            return (nil, nil)
        }
        let nextVal = max(0, currentVal - amount)
        let formattedNext = nextVal == nextVal.rounded() ? String(Int(nextVal)) : String(format: "%g", nextVal)

        let units = ["毫升", "片", "粒", "颗", "袋", "支", "滴", "包", "丸", "贴", "喷", "勺"]
        let detectedUnit = units.first { text.contains($0) } ?? defaultUnit
        if nextVal <= 0 {
            return ("已用完 (0 \(detectedUnit))", 0)
        }
        return ("剩 \(formattedNext) \(detectedUnit)", nextVal)
    }
}

// MARK: - 通用相机拍照取景器

struct VaultCameraPicker: UIViewControllerRepresentable {
    var onImageCaptured: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: VaultCameraPicker
        init(_ parent: VaultCameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onImageCaptured(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
