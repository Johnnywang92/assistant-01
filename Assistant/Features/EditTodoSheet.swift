import AssistantCore
import PhotosUI
import SwiftData
import SwiftUI
import UIKit

/// 待办事项全功能编辑面板
struct EditTodoSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Bindable var item: TodoItem

    /// 首页长按菜单收敛后，「拖拽排序」改由编辑页快捷动作区触发。
    /// 其余调用点（时间聚合页、已完成历史）不传，默认 nil，该行自动隐藏。
    var onEnterReorder: (() -> Void)? = nil

    @State private var title: String
    @State private var type: TodoType
    @State private var detail: String
    @State private var pickupCode: String
    @State private var station: String
    @State private var courier: String
    @State private var hasDueDate: Bool
    @State private var dueDate: Date
    @State private var remindBeforeMinutes: Int
    @State private var customRemindBeforeMinutes: Int
    @State private var recurrenceRule: TodoRecurrenceRule
    @State private var customIntervalDays: Int
    @State private var isDone: Bool
    @State private var syncToCalendar: Bool
    // 到站/落地前的随身物品清点提醒
    @State private var hasArrivalCheck: Bool
    @State private var arrivalDate: Date
    @State private var arrivalTransport: TripArrivalSchedule.TransportKind

    @State private var qrCodePayload: String?
    @State private var qrCodeImageData: Data?
    @State private var attachmentImageData: Data?
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var isRecognizingImage: Bool = false
    @State private var showingQRPreview: Bool = false
    @State private var recognizedTravelPickup: TravelPickupMetadata? = nil

    @State private var recognitionConfidence: Double? = nil
    @State private var recognitionConfidenceReason: String? = nil
    @State private var recognitionSuggestedTypes: [TodoType] = []
    @State private var showConfidenceNotice: Bool = true

    @State private var showingDeleteConfirmation: Bool = false
    /// 行程护航无法启动时的原因（如缺少出发时间），用于给出可执行的提示
    @State private var liveActivityErrorMessage: String? = nil

    // 结构化日程：与新建页同构，旧待办通过 TodoItem.schedule 的 legacy 解释无损回填。
    @State private var isTimeRange: Bool = false
    @State private var startDate: Date = .now
    @State private var isAllDay: Bool = false
    @State private var recurrenceMode: TodoRecurrenceMode = .afterCompletion
    @State private var selectedWeekdays: Set<Int> = []
    @State private var selectedMonthDays: Set<Int> = []
    @State private var hasRecurrenceEnd: Bool = false
    @State private var recurrenceEndDate: Date = .now

    init(item: TodoItem, onEnterReorder: (() -> Void)? = nil) {
        self.item = item
        self.onEnterReorder = onEnterReorder
        self._title = State(initialValue: item.title)
        self._type = State(initialValue: item.type)
        self._detail = State(initialValue: item.detail ?? "")
        self._pickupCode = State(initialValue: item.pickupCode ?? "")
        self._station = State(initialValue: item.displayLocationText ?? "")
        self._courier = State(initialValue: item.courier ?? "")
        let initialSchedule = item.schedule
        self._hasDueDate = State(initialValue: initialSchedule.mode != .none)
        self._dueDate = State(initialValue: initialSchedule.endAt)
        self._isTimeRange = State(initialValue: initialSchedule.mode == .range)
        self._startDate = State(initialValue: initialSchedule.startAt)
        self._isAllDay = State(initialValue: initialSchedule.isAllDay)
        self._recurrenceMode = State(initialValue: initialSchedule.recurrence.mode)
        self._selectedWeekdays = State(initialValue: Set(initialSchedule.recurrence.normalizedWeekdays))
        self._selectedMonthDays = State(initialValue: Set(initialSchedule.recurrence.normalizedMonthDays))
        self._hasRecurrenceEnd = State(initialValue: initialSchedule.recurrence.endAt != nil)
        self._recurrenceEndDate = State(initialValue: initialSchedule.recurrence.endAt
                                        ?? (Calendar.current.date(byAdding: .month, value: 3, to: .now) ?? .now))
        self._remindBeforeMinutes = State(initialValue: [0, 5, 60, 1440].contains(item.remindBeforeMinutes) ? item.remindBeforeMinutes : -1)
        self._customRemindBeforeMinutes = State(initialValue: max(1, item.remindBeforeMinutes))
        let rule = item.recurrenceRule
        self._recurrenceRule = State(initialValue: rule)
        self._customIntervalDays = State(initialValue: item.recurrenceIntervalDays > 0 ? item.recurrenceIntervalDays : (rule.dayInterval() > 0 ? rule.dayInterval() : 3))
        self._isDone = State(initialValue: item.status == .done)
        self._syncToCalendar = State(initialValue: item.calendarItemIdentifier != nil)
        self._hasArrivalCheck = State(initialValue: item.arrivalReminderAt != nil)
        self._arrivalDate = State(initialValue: item.arrivalReminderAt ?? (Calendar.current.date(byAdding: .hour, value: 2, to: .now) ?? .now))
        self._arrivalTransport = State(initialValue: item.arrivalTransportKind)
        self._qrCodePayload = State(initialValue: item.qrCodePayload)
        self._qrCodeImageData = State(initialValue: item.qrCodeImageData)
        self._attachmentImageData = State(initialValue: item.attachmentImageData)
        self._currentTags = State(initialValue: item.tags)
    }

    @State private var currentTags: [String] = []

    // MARK: - 结构化日程表单辅助（与 AddTodoSheet 同构）

    private var timeForm: Binding<TodoTimeMode> {
        Binding(
            get: { hasDueDate ? (isTimeRange ? .range : .point) : .none },
            set: { form in
                switch form {
                case .none:
                    hasDueDate = false
                    isTimeRange = false
                case .point:
                    hasDueDate = true
                    isTimeRange = false
                case .range:
                    hasDueDate = true
                    isTimeRange = true
                    if startDate >= dueDate {
                        startDate = Calendar.current.date(byAdding: .hour, value: -1, to: dueDate) ?? dueDate
                    }
                }
            }
        )
    }

    private var currentSchedule: TodoSchedule {
        TodoSchedule(
            mode: hasDueDate ? (isTimeRange ? .range : .point) : .none,
            startAt: isTimeRange ? startDate : dueDate,
            endAt: dueDate,
            isAllDay: isAllDay,
            recurrence: TodoRecurrenceConfig(
                rule: recurrenceRule,
                customDays: customIntervalDays,
                mode: recurrenceMode,
                weekdays: Array(selectedWeekdays),
                monthDays: Array(selectedMonthDays),
                endAt: hasRecurrenceEnd && recurrenceRule != .none ? recurrenceEndDate : nil
            )
        )
    }

    private var orderedWeekdays: [Int] { [2, 3, 4, 5, 6, 7, 1] }

    private func weekdayLabel(_ weekday: Int) -> String {
        let symbols = Calendar.current.veryShortWeekdaySymbols
        let index = weekday - 1
        return symbols.indices.contains(index) ? symbols[index] : "\(weekday)"
    }

    private func weekdayFullLabel(_ weekday: Int) -> String {
        let symbols = Calendar.current.weekdaySymbols
        let index = weekday - 1
        return symbols.indices.contains(index) ? symbols[index] : "\(weekday)"
    }

    private var quickMonthDays: [Int] { [1, 5, 10, 15, 20, 25, -1] }

    private func monthDayLabel(_ day: Int) -> String {
        day == -1 ? L10n.tr("月末") : "\(day)"
    }

    private var showsWeekdayAnchor: Bool {
        recurrenceMode == .calendarAnchor && (recurrenceRule == .weekly || recurrenceRule == .biweekly)
    }

    private var showsMonthDayAnchor: Bool {
        recurrenceMode == .calendarAnchor && recurrenceRule == .monthly
    }

    private func toggleWeekday(_ weekday: Int) {
        if selectedWeekdays.contains(weekday) { selectedWeekdays.remove(weekday) }
        else { selectedWeekdays.insert(weekday) }
    }

    private func toggleMonthDay(_ day: Int) {
        if selectedMonthDays.contains(day) { selectedMonthDays.remove(day) }
        else { selectedMonthDays.insert(day) }
    }

    private var recurrenceHint: String {
        guard recurrenceRule != .none else { return "" }
        if recurrenceMode == .calendarAnchor {
            if showsWeekdayAnchor && selectedWeekdays.isEmpty {
                return L10n.tr("还没选星期几，将按完成后顺延处理")
            }
            if showsMonthDayAnchor && selectedMonthDays.isEmpty {
                return L10n.tr("还没选日期，将按完成后顺延处理")
            }
            return L10n.tr("按日历固定日期重复，不随完成时间漂移")
        }
        return L10n.tr("完成此待办后，按间隔自动生成下一期")
    }

    var body: some View {
        NavigationStack {
            Form {
                // 1. 事项基本信息
                Section("事项内容") {
                    TextField("待办名称", text: $title)

                    if !currentTags.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(currentTags, id: \.self) { tag in
                                    HStack(spacing: 4) {
                                        Text("#\(tag)")
                                            .font(.caption.bold())
                                        Button {
                                            currentTags.removeAll { $0 == tag }
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.caption2)
                                        }
                                        .iconButton("移除标签")
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Capsule().fill(Color.indigo.opacity(0.12)))
                                    .foregroundStyle(Color.indigo)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }

                    Picker("分类类型", selection: $type) {
                        ForEach(TodoType.allCases.filter { $0 != .data }, id: \.self) { t in
                            Label(t.displayName, systemImage: t.icon).tag(t)
                        }
                    }

                    // 快递模式专属输入字段 vs 日程/出行地点字段
                    if type == .parcel {
                        TextField("取件码（如：3-2-104 或 5821）", text: $pickupCode)
                            .font(.body.monospaced())

                        TextField("存放驿站/自提柜（选填，如：东门菜鸟驿站、丰巢）", text: $station)

                        TextField("快递公司（选填，如：顺丰速运、京东快递）", text: $courier)
                    } else if type == .returnParcel {
                        TextField("寄件码 / 售后运单号（选填）", text: $pickupCode)
                            .font(.body.monospaced())

                        TextField("寄件方式/网点（选填，如：顺丰上门取件、驿站代寄）", text: $station)

                        TextField("寄件快递（选填，如：顺丰速运、京东生鲜）", text: $courier)
                    } else {
                        HStack(spacing: 8) {
                            Image(systemName: "mappin.and.ellipse")
                                .foregroundStyle(.secondary)
                            TextField("场馆 / 地点（选填，如：西岸国际会展中心）", text: $station)
                        }
                    }
                }

                // 1.5 快捷动作：首页长按菜单收敛后，条件性专属能力统一归到此处
                Section {
                    if canStartLiveActivity {
                        Button {
                            let started: Bool
                            if item.type == .travelBooking || item.type == .event {
                                started = LiveActivityService.startTravelActivity(for: item)
                            } else {
                                started = LiveActivityService.startPickupActivity(for: [item])
                            }
                            if started {
                                Haptic.success()
                            } else {
                                Haptic.warning()
                                // 行程护航卡的核心是倒计时：没有发车时间就没有倒计时可显示。
                                // 与其静默失败（用户以为功能坏了），不如说明缺什么。
                                if isTravelActivity && !hasDueDate {
                                    liveActivityErrorMessage = "请先设置出发时间，再开启行程倒计时。"
                                }
                            }
                        } label: {
                            Label("上灵动岛（同步手表）", systemImage: "platter.filled.top.iphone")
                        }
                    }

                    if hasVisualCredential {
                        Button {
                            showingQRPreview = true
                            Haptic.medium()
                        } label: {
                            Label("出示预约凭证", systemImage: "qrcode.viewfinder")
                        }
                    }

                    if item.status == .active,
                       WeChatCommunicationHelper.isWeChatCommunication(title: item.title, detail: item.detail) {
                        let kind = WeChatCommunicationHelper.communicationKind(title: item.title, detail: item.detail)
                        Button {
                            if let url = URL(string: WeChatCommunicationHelper.weChatURLScheme) {
                                UIApplication.shared.open(url)
                                Haptic.light()
                            }
                        } label: {
                            Label(kind.buttonTitle, systemImage: kind.iconName)
                        }
                    }

                    if let src = item.sourceText, !src.isEmpty {
                        Button {
                            UIPasteboard.general.string = src
                            Haptic.light()
                        } label: {
                            Label("复制原文", systemImage: "text.quote")
                        }
                    }

                    if let onEnterReorder {
                        Button {
                            dismiss()
                            onEnterReorder()
                        } label: {
                            Label("拖拽排序", systemImage: "arrow.up.arrow.down")
                        }
                    }
                } header: {
                    Text("快捷动作")
                } footer: {
                    Text("按事项类型出现，不占用首页长按菜单。")
                }

                // 2. 预约二维码与凭证截图
                Section("预约二维码与图片凭证") {
                    if qrCodeImageData != nil || (qrCodePayload != nil && !(qrCodePayload?.isEmpty ?? true)) || attachmentImageData != nil {
                        HStack(spacing: 14) {
                            if let qrData = qrCodeImageData, let uiImg = UIImage(data: qrData) {
                                Image(uiImage: uiImg)
                                    .interpolation(.none)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 68, height: 68)
                                    .padding(4)
                                    .background(Color.white)
                                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.chip))
                                    .overlay(RoundedRectangle(cornerRadius: AppRadius.chip).stroke(Color.secondary.opacity(0.2)))
                            } else if let payload = qrCodePayload, let genImg = QRCodeService.generateQRCode(from: payload, targetSize: 200) {
                                Image(uiImage: genImg)
                                    .interpolation(.none)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 68, height: 68)
                                    .padding(4)
                                    .background(Color.white)
                                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.chip))
                            } else if let attachData = attachmentImageData, let uiImg = UIImage(data: attachData) {
                                Image(uiImage: uiImg)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 68, height: 68)
                                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.chip))
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text(qrCodeImageData != nil || qrCodePayload != nil ? "已关联预约核销二维码" : "已关联订单截图凭证")
                                    .font(.subheadline.bold())
                                if let code = qrCodePayload, !code.isEmpty {
                                    Text("核销码：\(code)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                HStack(spacing: 10) {
                                    Button {
                                        showingQRPreview = true
                                        Haptic.medium()
                                    } label: {
                                        Label("全屏亮码", systemImage: "qrcode.viewfinder")
                                            .font(.caption.bold())
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)

                                    Button(role: .destructive) {
                                        qrCodePayload = nil
                                        qrCodeImageData = nil
                                        attachmentImageData = nil
                                        Haptic.light()
                                    } label: {
                                        Text("移除")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                        HStack {
                            if isRecognizingImage {
                                ProgressView()
                                    .padding(.trailing, 4)
                            }
                            Label(
                                qrCodeImageData != nil || attachmentImageData != nil ? "重新选择预约截图并提取" : "从相册选择预约截图 / 二维码",
                                systemImage: "photo.badge.plus"
                            )
                        }
                    }
                    .onChange(of: selectedPhotoItem) { _, newItem in
                        guard let newItem else { return }
                        Task { await loadAndRecognizePhoto(newItem) }
                    }
                }

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
                                .iconButton("关闭置信度提示")
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
                                                    type = sugType
                                                    Haptic.selection()
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

                // 2.5 火车票/机票接人提前量与汇合地点配置
                if recognizedTravelPickup != nil {
                    Section {
                        TravelTicketPickupConfigView(
                            pickup: Binding(
                                get: { recognizedTravelPickup! },
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
                        Label("火车票 / 机票接人与提前量", systemImage: "tram.fill.tunnel")
                    }
                }

                // 3. 详情与备注说明
                Section("详情与备注") {
                    TextField("补充备注/详情说明（选填）", text: $detail, axis: .vertical)
                        .lineLimit(2...5)
                }

                // 4. 什么时候：与新建页同一套时间形态，旧待办自动回填为「某个时间点」
                Section(L10n.tr("什么时候")) {
                    Picker(L10n.tr("时间形态"), selection: timeForm) {
                        Text(L10n.tr("不设时间")).tag(TodoTimeMode.none)
                        Text(L10n.tr("某个时间点")).tag(TodoTimeMode.point)
                        Text(L10n.tr("时间段")).tag(TodoTimeMode.range)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: hasDueDate) { _, enabled in
                        if enabled { Task { await NotificationService.requestAuthorization() } }
                    }

                    if hasDueDate {
                        Toggle(L10n.tr("全天"), isOn: $isAllDay)
                        let components: DatePickerComponents = isAllDay ? [.date] : [.date, .hourAndMinute]
                        if isTimeRange {
                            DatePicker(L10n.tr("开始"), selection: $startDate, displayedComponents: components)
                            DatePicker(L10n.tr("结束"), selection: $dueDate, displayedComponents: components)
                            if startDate >= dueDate {
                                Text(L10n.tr("开始需早于结束，保存时会自动调整"))
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        } else {
                            DatePicker(L10n.tr("截止"), selection: $dueDate, displayedComponents: components)
                        }
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

                        Toggle("写入系统日历", isOn: $syncToCalendar)
                            .onChange(of: syncToCalendar) { _, enabled in
                                if enabled {
                                    Task {
                                        _ = try? await CalendarAgendaService.shared.requestAccessIfNeeded()
                                    }
                                }
                            }
                    }
                }

                // 5. 重复吗：完成后顺延 / 按日历固定二选一，锚点真正驱动下一期
                Section(L10n.tr("重复吗")) {
                    Picker("重复周期", selection: $recurrenceRule) {
                        ForEach(TodoRecurrenceRule.allCases) { rule in
                            Label(L10n.tr(rule.rawValue), systemImage: rule.icon).tag(rule)
                        }
                    }

                    if recurrenceRule == .custom {
                        Stepper("每 \(customIntervalDays) 天重复一次", value: $customIntervalDays, in: 1...365)
                    }

                    if recurrenceRule != .none {
                        Picker(L10n.tr("重复方式"), selection: $recurrenceMode) {
                            Text(L10n.tr("完成后顺延")).tag(TodoRecurrenceMode.afterCompletion)
                            Text(L10n.tr("按日历固定")).tag(TodoRecurrenceMode.calendarAnchor)
                        }
                        .pickerStyle(.segmented)

                        if showsWeekdayAnchor {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(L10n.tr("选择星期几"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                HStack(spacing: 5) {
                                    ForEach(orderedWeekdays, id: \.self) { weekday in
                                        Button { toggleWeekday(weekday) } label: {
                                            Text(weekdayLabel(weekday))
                                                .font(.caption.bold())
                                                .frame(maxWidth: .infinity)
                                                .padding(.vertical, 7)
                                                .background(selectedWeekdays.contains(weekday)
                                                            ? Color.accentColor : Color(.tertiarySystemFill))
                                                .foregroundStyle(selectedWeekdays.contains(weekday) ? Color.white : Color.primary)
                                                .clipShape(RoundedRectangle(cornerRadius: AppRadius.chip))
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel(weekdayFullLabel(weekday))
                                        .accessibilityAddTraits(selectedWeekdays.contains(weekday) ? .isSelected : [])
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                        }

                        if showsMonthDayAnchor {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(L10n.tr("选择每月几号"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 7), spacing: 5) {
                                    ForEach(quickMonthDays, id: \.self) { day in
                                        Button { toggleMonthDay(day) } label: {
                                            Text(monthDayLabel(day))
                                                .font(.caption.bold())
                                                .frame(maxWidth: .infinity)
                                                .padding(.vertical, 7)
                                                .background(selectedMonthDays.contains(day)
                                                            ? Color.accentColor : Color(.tertiarySystemFill))
                                                .foregroundStyle(selectedMonthDays.contains(day) ? Color.white : Color.primary)
                                                .clipShape(RoundedRectangle(cornerRadius: AppRadius.chip))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                Menu(L10n.tr("更多日期")) {
                                    ForEach(1...31, id: \.self) { day in
                                        Button { toggleMonthDay(day) } label: {
                                            if selectedMonthDays.contains(day) {
                                                Label("\(day) 日", systemImage: "checkmark")
                                            } else {
                                                Text("\(day) 日")
                                            }
                                        }
                                    }
                                }
                                .font(.caption)
                            }
                            .padding(.vertical, 2)
                        }

                        Toggle(L10n.tr("设置结束日期"), isOn: $hasRecurrenceEnd)
                        if hasRecurrenceEnd {
                            DatePicker(L10n.tr("重复截止"), selection: $recurrenceEndDate, displayedComponents: [.date])
                        }

                        Text(recurrenceHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // 5. 到站/落地前清点随身物品
                Section("到站清点") {
                    Toggle("到站/落地时提醒我清点", isOn: $hasArrivalCheck)
                        .onChange(of: hasArrivalCheck) { _, enabled in
                            guard enabled else { return }
                            Task { await NotificationService.requestAuthorization() }
                            TripArrivalService.shared.requestMotionAuthorizationIfNeeded(for: arrivalTransport)
                        }
                    if hasArrivalCheck {
                        Picker("交通方式", selection: $arrivalTransport) {
                            ForEach(TripArrivalSchedule.TransportKind.allCases, id: \.self) { kind in
                                Label(kind.displayName, systemImage: kind.iconName).tag(kind)
                            }
                        }
                        .onChange(of: arrivalTransport) { _, kind in
                            TripArrivalService.shared.requestMotionAuthorizationIfNeeded(for: kind)
                        }
                        DatePicker("预计到达时间", selection: $arrivalDate, displayedComponents: [.date, .hourAndMinute])
                        Text(String(format: L10n.tr("到达前 %d 分钟提醒清点随身物品。开车与骑行会读取运动状态，刚停下就提醒；其余方式按预计到达时间兜底。"), arrivalTransport.advanceLeadMinutes))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // 6. 状态切换
                Section("完成状态") {
                    Toggle("标记为已完成", isOn: $isDone)
                }

                // 7. 危险操作区
                Section {
                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        HStack {
                            Spacer()
                            Label("删除此事项", systemImage: "trash")
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("编辑事项")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        saveChanges()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .fullScreenCover(isPresented: $showingQRPreview) {
                TodoQRCodeQuickSheet(
                    title: title,
                    locationText: station.isEmpty ? nil : station,
                    dueAt: hasDueDate ? dueDate : nil,
                    detail: detail.isEmpty ? nil : detail,
                    qrCodePayload: qrCodePayload,
                    qrCodeImageData: qrCodeImageData,
                    attachmentImageData: attachmentImageData
                )
            }
            .alert("确定删除该事项？", isPresented: $showingDeleteConfirmation) {
                Button("删除", role: .destructive) {
                    deleteItem()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("删除后将无法恢复。")
            }
            // 独立 alert：同层 SwiftUI 只允许一个 alert，
            // 行程护航的失败原因必须走另一个绑定，不能覆盖删除确认。
            .alert(
                "无法开启行程倒计时",
                isPresented: Binding(
                    get: { liveActivityErrorMessage != nil },
                    set: { if !$0 { liveActivityErrorMessage = nil } }
                )
            ) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(liveActivityErrorMessage ?? "")
            }
        }
    }

    private var canStartLiveActivity: Bool {
        item.status == .active &&
        (item.type == .parcel || item.type == .returnParcel || item.type == .travelBooking || item.type == .event)
    }

    /// 是否走行程护航（倒计时）路径。取件类不需要出发时间。
    private var isTravelActivity: Bool {
        item.type == .travelBooking || item.type == .event
    }

    private var hasVisualCredential: Bool {
        qrCodeImageData != nil || attachmentImageData != nil || !(qrCodePayload?.isEmpty ?? true)
    }

    private func loadAndRecognizePhoto(_ pickerItem: PhotosPickerItem) async {
        await MainActor.run { isRecognizingImage = true }
        defer { Task { @MainActor in isRecognizingImage = false } }
        guard let data = try? await pickerItem.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else { return }

        if let recognized = try? await OCRService.shared.recognizeTodo(from: image) {
            await MainActor.run {
                recognizedTravelPickup = recognized.travelPickup
                recognitionConfidence = recognized.confidence
                recognitionConfidenceReason = recognized.confidenceReason
                recognitionSuggestedTypes = recognized.suggestedTypes
                showConfidenceNotice = true
                if recognized.travelPickup != nil {
                    title = recognized.title
                    type = .event
                    if let loc = recognized.location ?? recognized.station {
                        station = loc
                    }
                    if let recognizedDue = recognized.dueAt {
                        hasDueDate = true
                        dueDate = recognizedDue
                    }
                    if let recDetail = recognized.detail {
                        detail = recDetail
                    }
                } else {
                    if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        title = recognized.title
                    }
                    type = recognized.type
                    if station.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       let loc = recognized.location ?? recognized.station {
                        station = loc
                    }
                    if let recognizedDue = recognized.dueAt, !hasDueDate {
                        hasDueDate = true
                        dueDate = recognizedDue
                    }
                    if detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       let recDetail = recognized.detail {
                        detail = recDetail
                    }
                    if let code = recognized.pickupCode, !code.isEmpty {
                        pickupCode = code
                    }
                }
                qrCodePayload = recognized.qrCodePayload
                qrCodeImageData = recognized.qrCodeImageData
                attachmentImageData = recognized.attachmentImageData
                Haptic.success()
            }
        }
    }

    /// 到站清点落库：改到达时间要清掉上一趟的已触发标记与残留横幅，
    /// 否则新行程会被判定为「本次已提醒过」而永远不再弹。
    private func applyArrivalCheck() {
        if hasArrivalCheck {
            let arrivalChanged = item.arrivalReminderAt != arrivalDate
            item.arrivalReminderAt = arrivalDate
            item.arrivalTransportKind = arrivalTransport
            if arrivalChanged {
                item.arrivalCheckFiredAt = nil
                TripArrivalService.shared.clearHistory(for: item.id)
            }
        } else {
            item.arrivalReminderAt = nil
            item.arrivalTransportRaw = nil
            item.arrivalCheckFiredAt = nil
        }
        TripArrivalService.shared.syncReminder(for: item)
    }

    private func saveChanges() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }
        if hasDueDate { Task { await NotificationService.requestAuthorization() } }

        let (extractedTitle, extractedTags) = TagExtractor.extractTags(from: trimmedTitle)
        let finalTitle = extractedTitle.isEmpty ? trimmedTitle : extractedTitle
        var mergedTags = currentTags
        for tag in extractedTags where !mergedTags.contains(tag) {
            mergedTags.append(tag)
        }

        item.title = finalTitle
        item.tags = mergedTags
        item.type = type
        item.detail = detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : detail.trimmingCharacters(in: .whitespacesAndNewlines)
        item.pickupCode = pickupCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : pickupCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedStation = station.trimmingCharacters(in: .whitespacesAndNewlines)
        item.station = trimmedStation.isEmpty ? nil : trimmedStation
        item.location = trimmedStation.isEmpty ? nil : trimmedStation
        item.courier = courier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : courier.trimmingCharacters(in: .whitespacesAndNewlines)
        // 唯一写入口：结构化日程与 dueAt / 重复规则散字段一次性同步，
        // 避免编辑页改了时间段却没更新通知读的截止时间。
        item.applySchedule(currentSchedule)
        item.remindBeforeMinutes = hasDueDate ? (remindBeforeMinutes == -1 ? customRemindBeforeMinutes : remindBeforeMinutes) : 0
        item.reminderOverrideAt = nil
        item.qrCodePayload = qrCodePayload
        item.qrCodeImageData = qrCodeImageData
        item.attachmentImageData = attachmentImageData

        let wasNotDone = (item.status != .done)
        if isDone && wasNotDone {
            item.markAsCompleted(in: context)
        } else {
            item.status = isDone ? .done : .active
            if !isDone {
                TodoNotificationManager.shared.scheduleNotification(for: item)
            } else {
                TodoNotificationManager.shared.cancelNotification(for: item.id)
            }
            LifeEventTodoLink.syncTask(for: item, in: context)
            if !isDone {
                // 撤销完成时回滚打卡计划（服药 / 运动），否则计划仍显示已打卡。
                CheckInPlanSync.undoPlan(for: item, in: context)
            }
        }

        applyArrivalCheck()

        if syncToCalendar && hasDueDate {
            let calTitle = title
            // 时间段事项写入系统日历时以「开始」为事件起点，而不是段末截止时间
            let calStart = isTimeRange ? startDate : dueDate
            let calDetail = detail.isEmpty ? nil : detail
            let calLoc = station.isEmpty ? nil : station
            let existingCalID = item.calendarItemIdentifier
            Task {
                if let newCalID = try? await CalendarAgendaService.shared.saveEvent(
                    title: calTitle,
                    startDate: calStart,
                    notes: calDetail,
                    location: calLoc,
                    existingIdentifier: existingCalID
                ) {
                    await MainActor.run {
                        item.calendarItemIdentifier = newCalID
                        context.saveReportingFailure { SaveFailureCenter.shared.report($0, action: "保存") }
                    }
                }
            }
        } else if !syncToCalendar, let oldCalID = item.calendarItemIdentifier {
            item.calendarItemIdentifier = nil
            Task {
                try? await CalendarAgendaService.shared.deleteEvent(identifier: oldCalID)
            }
        }

        guard context.saveReportingFailure({ SaveFailureCenter.shared.report($0, action: "保存待办") }) else {
            Haptic.error()
            return
        }
        Haptic.success()
        dismiss()
    }

    private func deleteItem() {
        item.cleanupExternalIntegrations()
        context.delete(item)
        guard context.saveReportingFailure({ SaveFailureCenter.shared.report($0, action: "删除待办") }) else {
            Haptic.error()
            return
        }
        Haptic.warning()
        dismiss()
    }
}

// MARK: - 预约二维码 / 门票凭证一键极速亮码弹窗

struct TodoQRCodeQuickSheet: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let locationText: String?
    let dueAt: Date?
    let detail: String?
    let qrCodePayload: String?
    let qrCodeImageData: Data?
    let attachmentImageData: Data?

    @State private var displayMode: Int = 0 // 0: 预约二维码, 1: 原图凭证
    @State private var previousBrightness: CGFloat = UIScreen.main.brightness
    @State private var isCopiedCode: Bool = false
    @State private var isCopiedLocation: Bool = false

    init(item: TodoItem) {
        self.title = item.displayConciseTitle
        self.locationText = item.displayLocationText
        self.dueAt = item.dueAt
        self.detail = item.displayConciseDetail
        self.qrCodePayload = item.qrCodePayload
        self.qrCodeImageData = item.qrCodeImageData
        self.attachmentImageData = item.attachmentImageData
        let hasQR = item.qrCodeImageData != nil || (item.qrCodePayload != nil && !(item.qrCodePayload?.isEmpty ?? true))
        self._displayMode = State(initialValue: hasQR ? 0 : 1)
    }

    init(
        title: String,
        locationText: String? = nil,
        dueAt: Date? = nil,
        detail: String? = nil,
        qrCodePayload: String? = nil,
        qrCodeImageData: Data? = nil,
        attachmentImageData: Data? = nil
    ) {
        self.title = title
        self.locationText = locationText
        self.dueAt = dueAt
        self.detail = detail
        self.qrCodePayload = qrCodePayload
        self.qrCodeImageData = qrCodeImageData
        self.attachmentImageData = attachmentImageData
        let hasQR = qrCodeImageData != nil || (qrCodePayload != nil && !(qrCodePayload?.isEmpty ?? true))
        self._displayMode = State(initialValue: hasQR ? 0 : 1)
    }

    private var hasBothQRAndOriginal: Bool {
        (qrCodeImageData != nil || (qrCodePayload != nil && !(qrCodePayload?.isEmpty ?? true))) && attachmentImageData != nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    // 1. 顶部模式切换（核销二维码 vs 完整原图）
                    if hasBothQRAndOriginal {
                        Picker("展示方式", selection: $displayMode) {
                            Text("预约核销二维码").tag(0)
                            Text("查看原图凭证").tag(1)
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal)
                    }

                    // 2. 票券式高对比度核销卡片
                    VStack(spacing: 16) {
                        // 事项标题与时间地点头部
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 6) {
                                Image(systemName: "ticket.fill")
                                    .foregroundStyle(.blue)
                                Text("预约 / 入场凭证")
                                    .font(.caption.bold())
                                    .foregroundStyle(.blue)
                                Spacer()
                                HStack(spacing: 4) {
                                    Image(systemName: "sun.max.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                    Text("已提亮屏幕")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Text(L10n.tr(title))
                                .font(.title3.bold())
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)

                            if let dueAt {
                                HStack(spacing: 6) {
                                    Image(systemName: "calendar.badge.clock")
                                        .foregroundStyle(.orange)
                                    Text(dueAt.formatted(date: .complete, time: .shortened))
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                }
                            }

                            if let loc = locationText, !loc.isEmpty {
                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: "mappin.and.ellipse")
                                        .foregroundStyle(.red)
                                        .padding(.top, 2)
                                    Text(loc)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    Spacer(minLength: 4)
                                    Button {
                                        UIPasteboard.general.string = loc
                                        Haptic.light()
                                        AppMotion.animate { isCopiedLocation = true }
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                                            AppMotion.animate { isCopiedLocation = false }
                                        }
                                    } label: {
                                        Text(isCopiedLocation ? "已复制" : "复制地址")
                                            .font(.caption2.bold())
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Capsule().fill(Color.blue.opacity(0.12)))
                                            .foregroundStyle(.blue)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Divider()

                        // 核心二维码 / 原图展示区
                        if displayMode == 0 {
                            VStack(spacing: 12) {
                                if let qrData = qrCodeImageData, let croppedUIImage = UIImage(data: qrData) {
                                    Image(uiImage: croppedUIImage)
                                        .interpolation(.none)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 250, height: 250)
                                        .padding(14)
                                        .background(Color.white)
                                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous))
                                        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
                                } else if let payload = qrCodePayload,
                                          let generatedImage = QRCodeService.generateQRCode(from: payload, targetSize: 520) {
                                    Image(uiImage: generatedImage)
                                        .interpolation(.none)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 250, height: 250)
                                        .padding(14)
                                        .background(Color.white)
                                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous))
                                        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
                                }

                                if let payload = qrCodePayload, !payload.isEmpty {
                                    HStack(spacing: 8) {
                                        Text(payload)
                                            .font(.callout.monospaced().bold())
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)

                                        Button {
                                            UIPasteboard.general.string = payload
                                            Haptic.light()
                                            AppMotion.animate { isCopiedCode = true }
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                                                AppMotion.animate { isCopiedCode = false }
                                            }
                                        } label: {
                                            HStack(spacing: 3) {
                                                Image(systemName: isCopiedCode ? "checkmark" : "doc.on.doc")
                                                Text(isCopiedCode ? "已复制" : "复制码号")
                                            }
                                            .font(.caption2.bold())
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            .padding(.vertical, 6)
                        } else if let attachData = attachmentImageData, let fullImage = UIImage(data: attachData) {
                            Image(uiImage: fullImage)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
                        }

                        // 底部附加信息（活动时间段、票种、实名信息等）
                        if let detail, !detail.isEmpty {
                            Divider()
                            VStack(alignment: .leading, spacing: 6) {
                                Text("预约详情")
                                    .font(.caption.bold())
                                    .foregroundStyle(.secondary)
                                Text(L10n.tr(detail))
                                    .font(.footnote)
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(20)
                    .background(
                        RoundedRectangle(cornerRadius: AppRadius.panel, style: .continuous)
                            .fill(Color(.secondarySystemGroupedBackground))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.panel, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                    .padding(.horizontal)
                }
                .padding(.vertical, 12)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("预约二维码凭证")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .onAppear {
                previousBrightness = UIScreen.main.brightness
                if UIScreen.main.brightness < 0.9 {
                    UIScreen.main.brightness = 0.95
                }
            }
            .onDisappear {
                UIScreen.main.brightness = previousBrightness
            }
        }
    }
}
