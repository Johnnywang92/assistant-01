import AssistantCore
import SwiftData
import SwiftUI

/// 饮水记录与科学补水追踪页面
public struct WaterTrackerView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \WaterIntakeRecord.date, order: .reverse) private var allRecords: [WaterIntakeRecord]
    @ObservedObject private var health = HealthKitService.shared

    @State private var dailyGoalML: Double = AppSettings.dailyWaterGoalML
    @State private var selectedBeverage: HydrationBeverageType = .plainWater
    @State private var isShowingCustomSheet = false
    @State private var isShowingGoalSheet = false
    @State private var isFAQExpanded = false
    @State private var toastMessage: String?

    // 过滤出今天的记录
    private var todayRecords: [WaterIntakeRecord] {
        let cal = Calendar.current
        return allRecords.filter { cal.isDateInToday($0.date) }
    }

    // 汇总数据
    private var summary: DailyHydrationSummary {
        let snapshots = todayRecords.map { $0.toSnapshot() }
        return DailyHydrationSummary(targetML: dailyGoalML, snapshots: snapshots)
    }

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(spacing: AppSpacing.md) {
                // 1. 今日核心进度卡
                todayHydrationProgressCard

                // 2. 咖啡因警告（若超标）
                if let warning = summary.caffeineWarning {
                    caffeineWarningBanner(warning)
                }

                // 3. 科学补水指南与咖啡奶茶解析（折叠卡片）
                scienceFAQCard

                // 4. 快速打卡操作区
                quickLogSection

                // 5. 今日流水账记录
                todayRecordsSection
            }
            .padding(AppSpacing.lg)
        }
        .themedAppBackground()
        .navigationTitle("喝水记录")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isShowingCustomSheet = true
                } label: {
                    Label("详细记录", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $isShowingCustomSheet) {
            AddCustomWaterSheet(defaultBeverage: selectedBeverage)
        }
        .sheet(isPresented: $isShowingGoalSheet) {
            EditWaterGoalSheet(currentGoal: $dailyGoalML)
        }
        .overlay(alignment: .bottom) {
            if let toast = toastMessage {
                Text(toast)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, AppSpacing.lg)
                    .padding(.vertical, AppSpacing.sm)
                    .background(Capsule().fill(Color.black.opacity(0.8)))
                    .padding(.bottom, AppSpacing.xl)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: - 今日核心进度卡

    private var todayHydrationProgressCard: some View {
        VStack(spacing: AppSpacing.md) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("今日有效补水")
                        .font(.subheadline)
                        .foregroundStyle(AppColor.secondaryText)

                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(Int(summary.effectiveHydrationML))")
                            .font(.system(size: 38, weight: .bold, design: .rounded))
                            .foregroundStyle(AppColor.primary)
                        Text("/ \(Int(summary.targetML)) ml")
                            .font(.headline)
                            .foregroundStyle(AppColor.secondaryText)
                    }

                    Text("达标率 \(Int(summary.progressRatio * 100))%")
                        .font(.caption.bold())
                        .foregroundStyle(summary.isGoalAchieved ? AppColor.success : AppColor.info)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(
                                summary.isGoalAchieved
                                ? AppColor.softFill(AppColor.success)
                                : AppColor.softFill(AppColor.info)
                            )
                        )
                }

                Spacer()

                // 圆环进度展示
                ZStack {
                    Circle()
                        .stroke(AppColor.fillTertiary, lineWidth: 10)
                        .frame(width: 76, height: 76)

                    Circle()
                        .trim(from: 0, to: CGFloat(min(summary.progressRatio, 1.0)))
                        .stroke(
                            summary.isGoalAchieved ? AppColor.success : AppColor.info,
                            style: StrokeStyle(lineWidth: 10, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .frame(width: 76, height: 76)
                        .animation(.easeInOut, value: summary.progressRatio)

                    Image(systemName: summary.isGoalAchieved ? "checkmark" : "drop.fill")
                        .font(.title2)
                        .foregroundStyle(summary.isGoalAchieved ? AppColor.success : AppColor.info)
                }
            }

            Divider()

            // 底部三个辅助指标：物理总容积、咖啡因、热量
            HStack {
                metricSubItem(
                    title: "饮品总容积",
                    value: "\(Int(summary.totalVolumeML)) ml",
                    icon: "waterbottle",
                    color: AppColor.info
                )
                Spacer()
                metricSubItem(
                    title: "累计咖啡因",
                    value: "\(Int(summary.totalCaffeineMG)) mg",
                    icon: "cup.and.saucer",
                    color: summary.isCaffeineHigh ? AppColor.danger : AppColor.warning
                )
                Spacer()
                metricSubItem(
                    title: "饮品热量",
                    value: "\(Int(summary.totalBeverageCalories)) kcal",
                    icon: "flame",
                    color: AppColor.feature
                )
            }

            // 修改目标按钮
            Button {
                isShowingGoalSheet = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "slider.horizontal.3")
                    Text("调整每日饮水目标")
                }
                .font(.caption)
                .foregroundStyle(AppColor.secondaryText)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(AppSpacing.md)
        .appCard()
    }

    private func metricSubItem(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(AppColor.secondaryText)
            }
            Text(value)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AppColor.text)
        }
    }

    // MARK: - 咖啡因警告横幅

    private func caffeineWarningBanner(_ message: String) -> some View {
        HStack(spacing: AppSpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppColor.warning)
            Text(message)
                .font(.footnote)
                .foregroundStyle(AppColor.text)
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.card)
                .fill(AppColor.softFill(AppColor.warning))
        )
    }

    // MARK: - 科学补水指南与咖啡奶茶解析

    private var scienceFAQCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isFAQExpanded.toggle()
                }
            } label: {
                HStack(spacing: AppSpacing.sm) {
                    Image(systemName: "lightbulb.fill")
                        .foregroundStyle(.yellow)
                    Text("喝咖啡、奶茶算不算喝水？")
                        .font(.subheadline.bold())
                        .foregroundStyle(AppColor.text)
                    Spacer()
                    Image(systemName: isFAQExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(AppColor.secondaryText)
                }
            }
            .buttonStyle(.plain)

            if isFAQExpanded {
                VStack(alignment: .leading, spacing: AppSpacing.md) {
                    Divider()

                    ForEach(HydrationScienceFAQ.items) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.question)
                                .font(.footnote.bold())
                                .foregroundStyle(AppColor.text)
                            Text(item.shortAnswer)
                                .font(.caption.bold())
                                .foregroundStyle(AppColor.primary)
                            Text(item.detail)
                                .font(.caption)
                                .foregroundStyle(AppColor.secondaryText)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(AppSpacing.md)
        .appCard()
    }

    // MARK: - 快速打卡操作区

    private var quickLogSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("快速记一杯")
                .font(.headline)
                .foregroundStyle(AppColor.text)

            // 饮品类型横向选择
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppSpacing.sm) {
                    ForEach(HydrationBeverageType.allCases.filter { $0 != .custom }, id: \.self) { type in
                        beverageTypeChip(type)
                    }
                }
            }

            // 当前选中饮品的科学折算提示
            HStack(spacing: AppSpacing.xs) {
                Image(systemName: "info.circle")
                    .font(.caption2)
                Text("水分折算率: \(Int(selectedBeverage.defaultHydrationFactor * 100))% · \(selectedBeverage.healthAdvice)")
                    .font(.caption2)
            }
            .foregroundStyle(selectedBeverage.isRecommendedAsMainHydration ? AppColor.secondaryText : AppColor.warning)
            .padding(.vertical, 2)

            // 容量快捷键
            HStack(spacing: AppSpacing.sm) {
                quickAddVolumeButton(volumeML: 150, title: "150ml (小杯)")
                quickAddVolumeButton(volumeML: 250, title: "250ml (标杯)")
                quickAddVolumeButton(volumeML: 350, title: "350ml (大杯)")
                quickAddVolumeButton(volumeML: 500, title: "500ml (瓶装)")
            }
        }
        .padding(AppSpacing.md)
        .appCard()
    }

    private func beverageTypeChip(_ type: HydrationBeverageType) -> some View {
        let isSelected = selectedBeverage == type
        return Button {
            selectedBeverage = type
        } label: {
            HStack(spacing: 4) {
                Image(systemName: type.iconName)
                    .font(.caption)
                Text(type.displayName)
                    .font(.caption.weight(isSelected ? .bold : .regular))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(isSelected ? AppColor.primary : AppColor.fillTertiary)
            )
            .foregroundStyle(isSelected ? .white : AppColor.text)
        }
        .buttonStyle(.plain)
    }

    private func quickAddVolumeButton(volumeML: Double, title: String) -> some View {
        Button {
            logWater(beverage: selectedBeverage, volumeML: volumeML)
        } label: {
            VStack(spacing: 2) {
                Text("+\(Int(volumeML))")
                    .font(.subheadline.bold())
                Text("ml")
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.medium)
                    .fill(AppColor.softFill(AppColor.primary, opacity: 0.12))
            )
            .foregroundStyle(AppColor.primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 今日记录列表

    private var todayRecordsSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack {
                Text("今日记录 (\(todayRecords.count))")
                    .font(.headline)
                    .foregroundStyle(AppColor.text)
                Spacer()
            }

            if todayRecords.isEmpty {
                VStack(spacing: AppSpacing.sm) {
                    Image(systemName: "drop")
                        .font(.system(size: 32))
                        .foregroundStyle(AppColor.secondaryText)
                    Text("今天还没有记录喝水")
                        .font(.footnote)
                        .foregroundStyle(AppColor.secondaryText)
                    Text("点击上方容量快速记录第一杯水吧")
                        .font(.caption2)
                        .foregroundStyle(AppColor.secondaryText.opacity(0.8))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppSpacing.xl)
            } else {
                ForEach(todayRecords) { record in
                    recordRow(record)
                }
            }
        }
        .padding(AppSpacing.md)
        .appCard()
    }

    private func recordRow(_ record: WaterIntakeRecord) -> some View {
        HStack(spacing: AppSpacing.sm) {
            Image(systemName: record.beverageType.iconName)
                .font(.title3)
                .foregroundStyle(AppColor.primary)
                .frame(width: 36, height: 36)
                .background(Circle().fill(AppColor.softFill(AppColor.primary)))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(record.customName ?? record.beverageType.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppColor.text)

                    if record.hydrationFactor < 1.0 {
                        Text("\(Int(record.hydrationFactor * 100))%折算")
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(AppColor.softFill(AppColor.warning)))
                            .foregroundStyle(AppColor.warning)
                    }
                }

                HStack(spacing: 6) {
                    Text(record.date, format: .dateTime.hour().minute())
                        .font(.caption2)
                        .foregroundStyle(AppColor.secondaryText)

                    if record.caffeineMG > 0 {
                        Text("咖啡因 \(Int(record.caffeineMG))mg")
                            .font(.caption2)
                            .foregroundStyle(AppColor.warning)
                    }

                    if record.calories > 0 {
                        Text("\(Int(record.calories))kcal")
                            .font(.caption2)
                            .foregroundStyle(AppColor.secondaryText)
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("+\(Int(record.effectiveHydrationML)) ml")
                    .font(.subheadline.bold())
                    .foregroundStyle(AppColor.primary)

                if record.hydrationFactor < 1.0 {
                    Text("原容积 \(Int(record.volumeML))ml")
                        .font(.caption2)
                        .foregroundStyle(AppColor.secondaryText)
                }
            }

            Button {
                deleteRecord(record)
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(AppColor.secondaryText)
            }
            .buttonStyle(.plain)
            .padding(.leading, 4)
        }
        .padding(.vertical, 4)
    }

    // MARK: - 行为操作

    private func logWater(beverage: HydrationBeverageType, volumeML: Double) {
        let record = WaterIntakeRecord(
            date: .now,
            beverageType: beverage,
            volumeML: volumeML
        )
        context.insert(record)
        try? context.save()

        // 异步尝试同步到 Apple 健康（写入有效补水量）
        Task {
            let success = await health.recordWaterIntake(amountML: record.effectiveHydrationML, date: record.date)
            if success {
                await MainActor.run {
                    record.syncedToHealthKit = true
                    try? context.save()
                }
            }
        }

        showToast("已记录 \(beverage.displayName) \(Int(volumeML))ml (补水 +\(Int(record.effectiveHydrationML))ml)")
    }

    private func deleteRecord(_ record: WaterIntakeRecord) {
        context.delete(record)
        try? context.save()
        showToast("已删除记录")
    }

    private func showToast(_ msg: String) {
        withAnimation {
            toastMessage = msg
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                if toastMessage == msg {
                    toastMessage = nil
                }
            }
        }
    }
}

// MARK: - 自定义录入弹窗

struct AddCustomWaterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var beverageType: HydrationBeverageType
    @State private var customName: String = ""
    @State private var volumeText: String = "300"
    @State private var date: Date = .now
    @State private var note: String = ""

    init(defaultBeverage: HydrationBeverageType = .plainWater) {
        _beverageType = State(initialValue: defaultBeverage)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("饮品种类") {
                    Picker("种类", selection: $beverageType) {
                        ForEach(HydrationBeverageType.allCases, id: \.self) { type in
                            HStack {
                                Image(systemName: type.iconName)
                                Text(type.displayName)
                            }
                            .tag(type)
                        }
                    }

                    if beverageType == .custom {
                        TextField("自定义饮品名（如：薄荷茶、冰美式）", text: $customName)
                    }

                    HStack {
                        Text("水分折算率")
                        Spacer()
                        Text("\(Int(beverageType.defaultHydrationFactor * 100))%")
                            .foregroundStyle(AppColor.secondaryText)
                    }

                    Text(beverageType.healthAdvice)
                        .font(.caption)
                        .foregroundStyle(AppColor.secondaryText)
                }

                Section("摄入容量") {
                    HStack {
                        TextField("容量", text: $volumeText)
                            .keyboardType(.numberPad)
                        Text("毫升 (ml)")
                            .foregroundStyle(AppColor.secondaryText)
                    }

                    if let vol = Double(volumeText) {
                        let eff = (vol * beverageType.defaultHydrationFactor).rounded()
                        HStack {
                            Text("预计有效补水")
                            Spacer()
                            Text("\(Int(eff)) ml")
                                .font(.headline)
                                .foregroundStyle(AppColor.primary)
                        }
                    }
                }

                Section("时间与备注") {
                    DatePicker("饮用时间", selection: $date, displayedComponents: [.date, .hourAndMinute])
                    TextField("备注（可选）", text: $note)
                }
            }
            .navigationTitle("详细记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        save()
                    }
                    .disabled((Double(volumeText) ?? 0) <= 0)
                }
            }
        }
    }

    private func save() {
        guard let vol = Double(volumeText), vol > 0 else { return }
        let name = beverageType == .custom && !customName.trimmingCharacters(in: .whitespaces).isEmpty
            ? customName.trimmingCharacters(in: .whitespaces)
            : nil

        let record = WaterIntakeRecord(
            date: date,
            beverageType: beverageType,
            volumeML: vol,
            customName: name,
            note: note.isEmpty ? nil : note
        )
        context.insert(record)
        try? context.save()

        Task {
            _ = await HealthKitService.shared.recordWaterIntake(amountML: record.effectiveHydrationML, date: record.date)
        }

        dismiss()
    }
}

// MARK: - 目标调整弹窗

struct EditWaterGoalSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var currentGoal: Double
    @State private var goalText: String = ""

    private let presets: [Double] = [1500, 1700, 2000, 2500]

    var body: some View {
        NavigationStack {
            Form {
                Section("推荐目标参考") {
                    Text("《中国居民膳食指南》建议：成年女性每日纯水 1500ml，成年男性 1700ml；运动或炎热天气可增加至 2000~2500ml。")
                        .font(.caption)
                        .foregroundStyle(AppColor.secondaryText)

                    ForEach(presets, id: \.self) { preset in
                        Button {
                            currentGoal = preset
                            AppSettings.dailyWaterGoalML = preset
                            dismiss()
                        } label: {
                            HStack {
                                Text("\(Int(preset)) ml")
                                    .foregroundStyle(AppColor.text)
                                Spacer()
                                if Int(currentGoal) == Int(preset) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(AppColor.primary)
                                }
                            }
                        }
                    }
                }

                Section("自定义目标") {
                    HStack {
                        TextField("输入每日目标", text: $goalText)
                            .keyboardType(.numberPad)
                        Text("ml")
                            .foregroundStyle(AppColor.secondaryText)
                    }

                    Button("设为当前目标") {
                        if let val = Double(goalText), val > 0 {
                            currentGoal = val
                            AppSettings.dailyWaterGoalML = val
                            dismiss()
                        }
                    }
                    .disabled((Double(goalText) ?? 0) <= 0)
                }
            }
            .navigationTitle("每日饮水目标")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear {
                goalText = "\(Int(currentGoal))"
            }
        }
    }
}
