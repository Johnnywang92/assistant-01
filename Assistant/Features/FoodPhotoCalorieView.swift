import AssistantCore
import PhotosUI
import SwiftData
import SwiftUI
import UIKit

/// 食物照片热量估算页。
///
/// ## 流程
/// 拍照/选图 → 端侧识别与估算 → **人工确认与调整**（份量 + 吃剩比例）→ 存为饮食记录
///
/// ## 设计要点
/// 1. **估算是草稿，不是结论**。用户必须经过确认页才能保存。
/// 2. **吃剩比例是一等公民**（用户明确需求）：照片里的菜往往吃不完，
///    所以比例滑杆与热量数字实时联动，而不是等到最后才生效。
/// 3. **识别不准时说清楚**，并提供改选入口，不硬撑一个看起来精确的数字。
struct FoodPhotoCalorieView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \FoodIntakeRecord.date, order: .reverse) private var records: [FoodIntakeRecord]

    @StateObject private var estimation = FoodEstimationService.shared
    @StateObject private var vision = FoodVisionService.shared

    @State private var photo: UIImage?
    @State private var pickedItems: [PhotosPickerItem] = []
    @State private var showingCamera = false
    @State private var hintText: String = ""
    @State private var showingFoodPicker = false
    @State private var showingAddDishPicker = false
    @State private var mealDate = Date.now
    /// 用户是否改动过任何参数（用于标记记录为「已手动调整」）
    @State private var didAdjust = false
    /// 选中要二次调整吃剩百分比的历史记录
    @State private var editingRecord: FoodIntakeRecord?
    /// 修改整餐自定义名称弹窗
    @State private var showingEditMealNameAlert = false
    @State private var customMealNameInput = ""
    /// 选中要修改名称/热量或换菜的菜品
    @State private var editingDish: FoodDishEstimate?
    /// 换菜触发的选择器
    @State private var dishToReplace: FoodDishEstimate?
    /// 饮食偏好服务与详情弹窗
    @StateObject private var preferenceService = DietaryPreferenceService.shared
    @State private var showingPreferenceDetail = false
    /// 离线语音听写服务
    @StateObject private var voiceService = VoiceDialogueService.shared
    @State private var isListeningVoice = false
    /// 历史记录时间周期筛选（本周 / 今天 / 本月 / 全部）
    @State private var selectedRecordPeriod: FoodRecordPeriodFilter = .thisWeek

    private var todayRecords: [FoodIntakeRecord] {
        let cal = Calendar.current
        return records.filter { cal.isDateInToday($0.date) }
    }

    private var todayConsumedCalories: Double {
        todayRecords.reduce(0) { $0 + $1.consumedCalories }
    }

    private var todayFullCalories: Double {
        todayRecords.reduce(0) { $0 + $1.fullPortionCalories }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: AppSpacing.md) {
                topSummaryAndRecommendationCard
                inputSection
                if estimation.isEstimating {
                    estimatingIndicator
                }
                if let estimate = estimation.estimate {
                    resultSection(estimate)
                } else if estimation.needsManualSelection {
                    manualSelectionSection
                }
                if !vision.candidates.isEmpty && estimation.estimate != nil {
                    candidatesSection
                }
                if !records.isEmpty {
                    recordsHistorySection
                }
            }
            .padding(AppSpacing.md)
        }
        .themedAppBackground()
        .navigationTitle("食物热量估算")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("保存") { saveRecord() }
                    .disabled(estimation.estimate == nil)
            }
        }
        .sheet(isPresented: $showingCamera) {
            FoodCameraPicker { image in
                photo = image
                Task { await runEstimation() }
            }
        }
        .sheet(isPresented: $showingFoodPicker) {
            FoodSelectionSheet { food in
                estimation.selectManually(food: food, portion: estimation.estimate?.portion ?? .regular,
                                          consumedRatio: estimation.estimate?.consumedRatio ?? 1.0)
                didAdjust = true
            }
        }
        .sheet(isPresented: $showingAddDishPicker) {
            FoodSelectionSheet { food in
                estimation.addDish(
                    food: food,
                    portion: .regular,
                    consumedRatio: estimation.estimate?.consumedRatio ?? 1.0
                )
                didAdjust = true
                Haptic.light()
            }
        }
        .sheet(item: $editingRecord) { record in
            FoodIntakeRecordAdjustmentSheet(record: record)
        }
        .sheet(item: $editingDish) { dish in
            FoodDishDetailEditSheet(dish: dish) { newName, newCal in
                estimation.updateDishDetails(dishID: dish.id, name: newName, calories: newCal)
                didAdjust = true
            } onReplaceRequest: {
                dishToReplace = dish
            }
        }
        .sheet(item: $dishToReplace) { dish in
            FoodSelectionSheet { newFood in
                estimation.replaceDish(dishID: dish.id, with: newFood)
                didAdjust = true
            }
        }
        .sheet(isPresented: $showingPreferenceDetail) {
            DietaryPreferenceDetailView(
                profile: preferenceService.profile,
                recommendations: preferenceService.currentRecommendations
            )
        }
        .alert("修改整餐名称", isPresented: $showingEditMealNameAlert) {
            TextField("输入整餐名称", text: $customMealNameInput)
            Button("保存") {
                estimation.updateMealDisplayName(customMealNameInput)
                didAdjust = true
            }
            Button("恢复默认", role: .destructive) {
                estimation.updateMealDisplayName("")
                didAdjust = true
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("可以为本餐自定义名称（如「工作日便当」「老妈炖排骨套餐」），保存时将作为饮食记录名称。")
        }
        .onAppear {
            preferenceService.refresh(with: context)
        }
        .onDisappear {
            stopVoiceListening()
        }
        .onChange(of: records) { _, _ in
            preferenceService.refresh(with: context)
        }
        .onChange(of: pickedItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await loadPickedImage(items) }
        }
        .onChange(of: voiceService.isListening) { _, listening in
            if !listening && isListeningVoice {
                stopVoiceListeningAndEstimate()
            }
        }
        .onChange(of: voiceService.recognizedText) { _, newText in
            if isListeningVoice && !newText.isEmpty {
                hintText = newText
            }
        }
    }

    // MARK: - 顶部今日数据与画像建议（紧凑合并卡片）

    private var topSummaryAndRecommendationCard: some View {
        let recommendations = preferenceService.currentRecommendations

        return VStack(spacing: 8) {
            HStack(alignment: .center) {
                HStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(Color.orange.opacity(0.14))
                            .frame(width: 32, height: 32)
                        Image(systemName: "flame.fill")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("今日已记录摄入")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(AppColor.secondaryText)
                        Text(todayRecords.isEmpty ? "今日尚未记录" : "共 \(todayRecords.count) 餐")
                            .font(.caption2)
                            .foregroundStyle(AppColor.secondaryText)
                    }
                }

                Spacer()

                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(Int(todayConsumedCalories.rounded()))")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(AppColor.primary)
                    Text("千卡")
                        .font(.caption2.bold())
                        .foregroundStyle(AppColor.secondaryText)
                }
            }

            if let firstRec = recommendations.first {
                Divider()
                Button {
                    showingPreferenceDetail = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.caption2)
                            .foregroundStyle(AppColor.primary)

                        Text(firstRec.slot.rawValue)
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(AppColor.primary.opacity(0.12))
                            .foregroundStyle(AppColor.primary)
                            .clipShape(Capsule())

                        Text(firstRec.title)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(AppColor.text)
                            .lineLimit(1)

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(AppColor.secondaryText)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(AppSpacing.md)
        .appCard()
    }

    // MARK: - 统一输入区（支持拍照识图、相册选图、直接文字手输与离线语音）

    private var inputSection: some View {
        VStack(spacing: AppSpacing.sm) {
            // 1. 照片预览卡片（当已拍摄或从相册选择照片时展示）
            if let photo {
                ZStack(alignment: .topTrailing) {
                    Image(uiImage: photo)
                        .resizable()
                        .scaledToFill()
                        .frame(height: 150)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
                        .clipped()

                    Button {
                        self.photo = nil
                        self.pickedItems = []
                        Haptic.light()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white, Color.black.opacity(0.6))
                            .padding(8)
                    }
                }
            }

            // 2. 常驻文字输入框与语音输入（无照片时手输，有照片时作为补充提示）
            HStack(spacing: 8) {
                Image(systemName: "fork.knife")
                    .font(.footnote)
                    .foregroundStyle(AppColor.secondaryText)

                TextField(
                    photo == nil ? "手输食物（如：牛肉面 / 米饭+炒青菜）" : "补充说明（如：少油、红烧肉）",
                    text: $hintText
                )
                .font(.subheadline)
                .submitLabel(.search)
                .onSubmit {
                    submitEstimation()
                }

                if !hintText.isEmpty {
                    Button {
                        hintText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                // 语音输入按钮
                Button {
                    toggleVoiceListening()
                } label: {
                    Image(systemName: isListeningVoice ? "waveform" : "mic.fill")
                        .font(.subheadline)
                        .foregroundStyle(isListeningVoice ? .red : AppColor.primary)
                        .symbolEffect(.bounce, value: isListeningVoice)
                        .frame(width: 32, height: 32)
                        .background(isListeningVoice ? Color.red.opacity(0.12) : AppColor.primary.opacity(0.1))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)

                // 估算按钮
                Button {
                    submitEstimation()
                } label: {
                    Text("估算")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            (hintText.isEmpty && photo == nil) ? Color.secondary.opacity(0.4) : AppColor.primary
                        )
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(hintText.isEmpty && photo == nil)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
            )

            // 语音正在录音提示
            if isListeningVoice {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 6, height: 6)
                    Text("正在本地识别语音，请说出菜名（如「西红柿鸡蛋面」）…")
                        .font(.caption2)
                        .foregroundStyle(Color.red)
                    Spacer()
                    Button("完成") {
                        stopVoiceListeningAndEstimate()
                    }
                    .font(.caption2.bold())
                    .foregroundStyle(.red)
                }
                .padding(.horizontal, 4)
            }

            // 3. 快捷入口按钮栏（拍照、相册、食物库）
            HStack(spacing: 10) {
                Button {
                    showingCamera = true
                } label: {
                    Label("拍照", systemImage: "camera")
                        .font(.caption.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous))
                }
                .buttonStyle(.plain)

                PhotosPicker(selection: $pickedItems, maxSelectionCount: 1, matching: .images) {
                    Label("相册", systemImage: "photo")
                        .font(.caption.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    showingFoodPicker = true
                } label: {
                    Label("食物库", systemImage: "book.pages")
                        .font(.caption.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            // 4. 时段快捷补菜（当尚未估算时，提供小巧的快速点选气泡）
            if estimation.estimate == nil {
                let suggestions = quickSuggestionFoods
                if !suggestions.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            Text("时段常吃：")
                                .font(.caption2)
                                .foregroundStyle(AppColor.secondaryText)
                            ForEach(suggestions.prefix(6)) { food in
                                Button {
                                    handleQuickSuggestionTap(food)
                                } label: {
                                    Text("+ \(food.name)")
                                        .font(.caption2.weight(.medium))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color(.tertiarySystemFill))
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .padding(AppSpacing.md)
        .appCard()
    }

    private var estimatingIndicator: some View {
        HStack(spacing: AppSpacing.sm) {
            ProgressView()
            Text("正在本机多区域识别菜品与估算热量…")
                .font(.footnote)
                .foregroundStyle(AppColor.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.md)
        .appCard()
    }

    // MARK: - 结果区（精简现代设计：突出总热量、收敛杂乱按钮、平滑滑杆）

    private func resultSection(_ estimate: FoodCalorieEstimate) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            // 1. 餐品标题与总摄入热量
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        customMealNameInput = estimate.displayName
                        showingEditMealNameAlert = true
                    } label: {
                        HStack(spacing: 5) {
                            Text(estimate.displayName)
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(AppColor.text)
                            Image(systemName: "pencil")
                                .font(.caption2)
                                .foregroundStyle(AppColor.primary)
                        }
                    }
                    .buttonStyle(.plain)

                    HStack(spacing: 6) {
                        if estimate.dishes.count > 1 {
                            Text("共 \(estimate.dishes.count) 道")
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(AppColor.primary.opacity(0.12)))
                                .foregroundStyle(AppColor.primary)
                        }
                        Text(estimate.confidenceLevel.displayName)
                            .font(.caption2)
                            .foregroundStyle(confidenceColor(estimate.confidenceLevel))
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(Int(estimate.consumedCalories.rounded()))")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .foregroundStyle(AppColor.primary)
                        Text("千卡")
                            .font(.caption.bold())
                            .foregroundStyle(AppColor.secondaryText)
                    }
                    if estimate.consumedRatio < 0.999 || estimate.dishes.count > 1 {
                        Text("整份约 \(Int(estimate.fullPortionCalories.rounded())) 千卡")
                            .font(.caption2)
                            .foregroundStyle(AppColor.secondaryText)
                    }
                }
            }

            Divider()

            // 2. 餐品明细（点击整行进入修改/换菜/改热量，去除杂乱的行内小步进器）
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("菜品明细")
                        .font(.caption.bold())
                        .foregroundStyle(AppColor.secondaryText)
                    Spacer()
                    Button {
                        showingAddDishPicker = true
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "plus.circle.fill")
                            Text("加菜")
                        }
                        .font(.caption.bold())
                    }
                    .buttonStyle(.borderless)
                }

                ForEach(estimate.dishes) { dish in
                    HStack(spacing: 8) {
                        Button {
                            editingDish = dish
                            Haptic.light()
                        } label: {
                            HStack(spacing: 6) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(dish.food.name)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(AppColor.text)
                                    Text("\(dish.portion.displayName) · 整份 \(Int(dish.fullPortionCalories.rounded())) 卡")
                                        .font(.caption2)
                                        .foregroundStyle(AppColor.secondaryText)
                                }
                                Image(systemName: "pencil")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        // 单菜份量切换
                        Menu {
                            ForEach(FoodPortion.allCases, id: \.self) { p in
                                Button(p.displayName) {
                                    estimation.updateDishPortion(dishID: dish.id, portion: p)
                                    didAdjust = true
                                    Haptic.light()
                                }
                            }
                        } label: {
                            Text(dish.portion.displayName)
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.secondary.opacity(0.12)))
                                .foregroundStyle(.primary)
                        }

                        Text("\(Int(dish.consumedCalories.rounded())) 卡")
                            .font(.subheadline.bold().monospacedDigit())
                            .foregroundStyle(AppColor.primary)
                            .frame(minWidth: 46, alignment: .trailing)

                        if estimate.dishes.count > 1 {
                            Button {
                                estimation.removeDish(dishID: dish.id)
                                didAdjust = true
                                Haptic.light()
                            } label: {
                                Image(systemName: "trash")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, 8)
                    .background(
                        RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                            .fill(Color.secondary.opacity(0.06))
                    )
                }
            }

            Divider()

            // 3. 整餐份量
            VStack(alignment: .leading, spacing: 6) {
                Text("整餐份量")
                    .font(.caption.bold())
                    .foregroundStyle(AppColor.secondaryText)
                Picker("份量", selection: Binding(
                    get: { estimation.estimate?.portion ?? .regular },
                    set: { newValue in
                        estimation.updatePortion(newValue)
                        didAdjust = true
                    }
                )) {
                    ForEach(FoodPortion.allCases, id: \.self) { portion in
                        Text(portion.displayName).tag(portion)
                    }
                }
                .pickerStyle(.segmented)
            }

            // 4. 吃了多少（平滑滑杆与 4 个直观快捷胶囊，删去多余的 - / + 步进器）
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("吃了多少")
                        .font(.caption.bold())
                        .foregroundStyle(AppColor.secondaryText)
                    Spacer()
                    Text("\(Int(((estimation.estimate?.consumedRatio ?? 1) * 100).rounded()))%")
                        .font(.subheadline.bold().monospacedDigit())
                        .foregroundStyle(AppColor.primary)
                }

                Slider(
                    value: Binding(
                        get: { estimation.estimate?.consumedRatio ?? 1 },
                        set: { newValue in
                            estimation.updateConsumedRatio(newValue)
                            didAdjust = true
                        }
                    ),
                    in: 0...1,
                    step: 0.05
                )

                HStack(spacing: 8) {
                    ForEach([(1.0, "全部吃完 100%"), (0.75, "吃了大半 75%"), (0.5, "吃了一半 50%"), (0.25, "只尝少许 25%")], id: \.0) { value, label in
                        let isSelected = abs((estimation.estimate?.consumedRatio ?? 1.0) - value) < 0.03
                        Button {
                            estimation.updateConsumedRatio(value)
                            didAdjust = true
                            Haptic.light()
                        } label: {
                            Text(label)
                                .font(.caption2.weight(isSelected ? .bold : .regular))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(isSelected ? AppColor.primary.opacity(0.15) : Color(.tertiarySystemFill))
                                .foregroundStyle(isSelected ? AppColor.primary : .secondary)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if let message = estimation.statusMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(AppColor.secondaryText)
            }

            // 5. 保存主操作按钮
            Button {
                saveRecord()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("完成并保存记录")
                }
                .font(.subheadline.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(AppColor.primary)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(AppSpacing.md)
        .appCard()
    }

    // MARK: - 手动选择引导（当无法直接匹配具体食物时）

    private var manualSelectionSection: some View {
        HStack(spacing: 12) {
            Image(systemName: "questionmark.circle.fill")
                .font(.title3)
                .foregroundStyle(AppColor.warning)

            VStack(alignment: .leading, spacing: 2) {
                Text("未能精准识别食物")
                    .font(.subheadline.bold())
                Text("沙拉或混合菜食材丰富，建议从食物库快速挑选。")
                    .font(.caption2)
                    .foregroundStyle(AppColor.secondaryText)
            }

            Spacer()

            Button {
                showingFoodPicker = true
            } label: {
                Text("食物库挑选")
                    .font(.caption.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(AppColor.primary.opacity(0.12))
                    .foregroundStyle(AppColor.primary)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(AppSpacing.md)
        .appCard()
    }

    // MARK: - 候选区（紧凑横向药丸胶囊）

    private var candidatesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("识别到的可能菜品")
                    .font(.caption.bold())
                    .foregroundStyle(AppColor.secondaryText)
                Spacer()
                Text("点击可加入本餐")
                    .font(.caption2)
                    .foregroundStyle(AppColor.secondaryText)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(vision.candidates) { candidate in
                        let isIncluded = estimation.estimate?.dishes.contains(where: { $0.food.id == candidate.food.id }) ?? false
                        Button {
                            if !isIncluded {
                                estimation.addDish(
                                    food: candidate.food,
                                    portion: .regular,
                                    consumedRatio: estimation.estimate?.consumedRatio ?? 1.0
                                )
                                didAdjust = true
                                Haptic.light()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: isIncluded ? "checkmark.circle.fill" : "plus.circle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(isIncluded ? AppColor.success : AppColor.primary)
                                Text(candidate.food.name)
                                    .font(.caption.weight(.medium))
                                Text("\(Int(candidate.food.standardServingCalories.rounded()))卡")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(isIncluded ? AppColor.success.opacity(0.1) : Color(.tertiarySystemFill))
                            .clipShape(Capsule())
                            .overlay(
                                Capsule().stroke(isIncluded ? AppColor.success.opacity(0.3) : Color.clear, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isIncluded)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(AppSpacing.md)
        .appCard()
    }

/// 饮食记录展示周期筛选
enum FoodRecordPeriodFilter: String, CaseIterable, Identifiable {
    case thisWeek = "本周"
    case today = "今天"
    case thisMonth = "本月"
    case all = "全部"

    var id: String { rawValue }
}

    // MARK: - 历史记录与吃剩比例二次调整

    private var filteredFoodRecords: [FoodIntakeRecord] {
        let cal = Calendar.current
        switch selectedRecordPeriod {
        case .today:
            return records.filter { cal.isDateInToday($0.date) }
        case .thisWeek:
            guard let weekInterval = cal.dateInterval(of: .weekOfYear, for: .now) else { return records }
            return records.filter { weekInterval.contains($0.date) }
        case .thisMonth:
            guard let monthInterval = cal.dateInterval(of: .month, for: .now) else { return records }
            return records.filter { monthInterval.contains($0.date) }
        case .all:
            return records
        }
    }

    private var groupedFoodRecords: [(key: String, totalCalories: Double, items: [FoodIntakeRecord])] {
        let cal = Calendar.current
        let items = filteredFoodRecords
        guard !items.isEmpty else { return [] }

        if selectedRecordPeriod == .today {
            let total = items.reduce(0.0) { $0 + $1.consumedCalories }
            return [("今天", total, items)]
        }

        let grouped = Dictionary(grouping: items) { item in
            if cal.isDateInToday(item.date) {
                return "今天"
            } else if cal.isDateInYesterday(item.date) {
                return "昨天"
            } else {
                return item.date.formatted(date: .abbreviated, time: .omitted)
            }
        }

        var result: [(key: String, totalCalories: Double, items: [FoodIntakeRecord])] = []

        if let todayItems = grouped["今天"], !todayItems.isEmpty {
            let total = todayItems.reduce(0.0) { $0 + $1.consumedCalories }
            result.append(("今天", total, todayItems))
        }

        if let yesterdayItems = grouped["昨天"], !yesterdayItems.isEmpty {
            let total = yesterdayItems.reduce(0.0) { $0 + $1.consumedCalories }
            result.append(("昨天", total, yesterdayItems))
        }

        let otherKeys = grouped.keys
            .filter { $0 != "今天" && $0 != "昨天" }
            .sorted { k1, k2 in
                guard let d1 = grouped[k1]?.first?.date, let d2 = grouped[k2]?.first?.date else { return false }
                return d1 > d2
            }

        for k in otherKeys {
            if let dateItems = grouped[k] {
                let total = dateItems.reduce(0.0) { $0 + $1.consumedCalories }
                result.append((k, total, dateItems))
            }
        }

        return result
    }

    private var recordsHistorySection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack {
                Text("饮食记录")
                    .font(.subheadline.bold())
                Spacer()
                Text("共 \(filteredFoodRecords.count) 餐 · 累计 \(Int(filteredFoodRecords.reduce(0) { $0 + $1.consumedCalories }.rounded())) 千卡")
                    .font(.caption2)
                    .foregroundStyle(AppColor.secondaryText)
            }

            Picker("记录周期", selection: $selectedRecordPeriod) {
                ForEach(FoodRecordPeriodFilter.allCases) { period in
                    Text(period.rawValue).tag(period)
                }
            }
            .pickerStyle(.segmented)
            .padding(.vertical, 2)

            if filteredFoodRecords.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "fork.knife")
                        .font(.title3)
                        .foregroundStyle(AppColor.secondaryText.opacity(0.6))
                        .padding(.top, 8)
                    Text(selectedRecordPeriod == .today ? "今日暂无记录，可在上方手输或拍照记录" : "\(selectedRecordPeriod.rawValue)暂无饮食记录")
                        .font(.caption)
                        .foregroundStyle(AppColor.secondaryText)
                        .padding(.bottom, 8)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            } else {
                ForEach(groupedFoodRecords, id: \.key) { group in
                    if selectedRecordPeriod != .today {
                        HStack {
                            Text(group.key)
                                .font(.caption.bold())
                                .foregroundStyle(AppColor.secondaryText)
                            Spacer()
                            Text("\(group.items.count) 餐 · \(Int(group.totalCalories.rounded())) 千卡")
                                .font(.caption2)
                                .foregroundStyle(AppColor.secondaryText)
                        }
                        .padding(.top, 4)
                    }

                    ForEach(group.items) { record in
                        Button {
                            editingRecord = record
                            Haptic.light()
                        } label: {
                            HStack(spacing: AppSpacing.sm) {
                                if let data = record.imageData, let uiImg = UIImage(data: data) {
                                    Image(uiImage: uiImg)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 44, height: 44)
                                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous))
                                } else {
                                    RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous)
                                        .fill(AppColor.surface)
                                        .frame(width: 44, height: 44)
                                        .overlay {
                                            Image(systemName: "fork.knife")
                                                .foregroundStyle(AppColor.secondaryText)
                                        }
                                }

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(record.foodName)
                                        .font(.subheadline.bold())
                                        .foregroundStyle(AppColor.text)
                                        .lineLimit(1)
                                        .truncationMode(.tail)

                                    HStack(spacing: 5) {
                                        Text(record.portion.displayName)
                                            .font(.caption2)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Capsule().fill(Color.secondary.opacity(0.12)))
                                            .foregroundStyle(AppColor.secondaryText)
                                            .fixedSize()

                                        if record.consumedRatio < 0.999 {
                                            Text("吃 \(Int((record.consumedRatio * 100).rounded()))%")
                                                .font(.caption2.bold())
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Capsule().fill(AppColor.primary.opacity(0.15)))
                                                .foregroundStyle(AppColor.primary)
                                                .fixedSize()
                                        }

                                        Text(record.date.formatted(date: .omitted, time: .shortened))
                                            .font(.caption2)
                                            .foregroundStyle(AppColor.secondaryText)
                                            .lineLimit(1)
                                    }
                                }

                                Spacer(minLength: 8)

                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("\(Int(record.consumedCalories.rounded())) 千卡")
                                        .font(.subheadline.bold().monospacedDigit())
                                        .foregroundStyle(AppColor.primary)
                                        .fixedSize()
                                    if record.consumedRatio < 0.999 {
                                        Text("整份 \(Int(record.fullPortionCalories.rounded()))")
                                            .font(.caption2)
                                            .foregroundStyle(AppColor.secondaryText)
                                            .fixedSize()
                                    }
                                }

                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(AppColor.secondaryText.opacity(0.5))
                            }
                            .padding(.vertical, 5)
                        }
                        .buttonStyle(.plain)

                        if record.id != group.items.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(AppSpacing.md)
        .appCard()
    }

    // MARK: - 快捷推荐与离线语音交互

    private var quickSuggestionFoods: [FoodItem] {
        let period = MealTimePeriod.from(date: mealDate)
        let currentDishIDs: Set<String> = {
            if let est = estimation.estimate {
                return Set(est.dishes.map(\.food.id))
            }
            return []
        }()

        // 统计历史记录中高频食用的菜品
        var countMap: [String: Int] = [:]
        for r in records {
            if let fID = r.foodID {
                for id in fID.components(separatedBy: "+") {
                    let clean = id.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !clean.isEmpty else { continue }
                    countMap[clean, default: 0] += 1
                }
            }
        }
        let userFrequentIDs = countMap.sorted(by: { $0.value > $1.value }).map(\.key)

        var result: [FoodItem] = []
        var addedIDs = Set<String>()

        // 优先级 1：用户常吃中匹配当前时段先验（乘数 >= 1.0）且不在当前餐中的菜品
        for fid in userFrequentIDs {
            guard !currentDishIDs.contains(fid), !addedIDs.contains(fid) else { continue }
            if let item = FoodCatalog.items.first(where: { $0.id == fid }) {
                if period.priorMultiplier(for: item) >= 1.0 {
                    result.append(item)
                    addedIDs.insert(item.id)
                }
            }
            if result.count >= 4 { break }
        }

        // 优先级 2：当前用餐时段的高频代表性菜品
        let timeBasedCandidates: [String] = {
            switch period {
            case .breakfast:
                return ["steamed_bun", "soy_milk", "egg", "youtiao", "pancake_roll", "congee", "coffee"]
            case .lunch:
                return ["rice", "vegetable_dish", "stir_fry_meat", "tomato_egg_soup", "tofu", "chicken_breast"]
            case .afternoonTea:
                return ["coffee", "latte", "fruit", "lemon_tea", "cake", "pure_milk"]
            case .dinner:
                return ["rice", "vegetable_dish", "soup", "fish", "stir_fry_cabbage", "sour_potato_shreds"]
            case .lateNight:
                return ["dumpling", "barbecue", "oden", "fruit", "soy_milk"]
            }
        }()

        for fid in timeBasedCandidates {
            guard !currentDishIDs.contains(fid), !addedIDs.contains(fid) else { continue }
            if let item = FoodCatalog.items.first(where: { $0.id == fid }) {
                result.append(item)
                addedIDs.insert(item.id)
            }
            if result.count >= 8 { break }
        }

        return result
    }

    private func handleQuickSuggestionTap(_ food: FoodItem) {
        if estimation.estimate != nil {
            estimation.addDish(food: food)
            didAdjust = true
            Haptic.light()
        } else {
            hintText = food.name
            submitEstimation()
            Haptic.light()
        }
    }

    private func toggleVoiceListening() {
        if isListeningVoice {
            stopVoiceListeningAndEstimate()
        } else {
            startVoiceListening()
        }
    }

    private func startVoiceListening() {
        Task {
            let granted = await voiceService.requestPermissions()
            guard granted else { return }
            do {
                try await voiceService.startListening()
                isListeningVoice = voiceService.isListening
                Haptic.medium()
            } catch {
                isListeningVoice = false
            }
        }
    }

    private func stopVoiceListeningAndEstimate() {
        guard isListeningVoice else { return }
        isListeningVoice = false
        voiceService.stopListening()
        Haptic.light()
        submitEstimation()
    }

    private func stopVoiceListening() {
        isListeningVoice = false
        voiceService.stopListening()
    }

    // MARK: - 动作

    private func submitEstimation() {
        let clean = hintText.trimmingCharacters(in: .whitespacesAndNewlines)
        if photo != nil {
            Task { await runEstimation() }
        } else if !clean.isEmpty {
            Task {
                didAdjust = false
                await estimation.estimateCalories(fromText: clean, mealDate: mealDate)
            }
        }
    }

    private func runEstimation() async {
        guard let photo else {
            submitEstimation()
            return
        }
        let historyPrior = FoodEstimationService.buildHistoryPrior(from: records)
        _ = await estimation.estimateCalories(
            for: photo,
            userHint: hintText,
            mealDate: mealDate,
            history: historyPrior
        )
        didAdjust = false
    }

    private func loadPickedImage(_ items: [PhotosPickerItem]) async {
        guard let item = items.first,
              let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else { return }
        photo = image
        await runEstimation()
    }

    private func saveRecord() {
        guard let estimate = estimation.estimate else { return }
        // 缩略图压到 480px 长边，避免撑大数据库
        let imageData = photo?.scaledDown(maxDimension: 480).jpegData(compressionQuality: 0.7)
        let record = FoodIntakeRecord(
            date: mealDate,
            foodName: estimate.displayName,
            foodID: estimate.dishes.count == 1 ? estimate.food.id : estimate.dishes.map(\.food.id).joined(separator: "+"),
            portion: estimate.portion,
            fullPortionCalories: estimate.fullPortionCalories,
            consumedRatio: estimate.consumedRatio,
            confidence: estimate.confidence,
            isManuallyAdjusted: didAdjust,
            source: photo != nil ? .vision : .manual,
            imageData: imageData
        )
        context.insert(record)
        try? context.save()
        Haptic.success()
        // 保存后清空当前草稿，留在页面可直接查看今日累计或继续二次调整百分比
        photo = nil
        pickedItems = []
        hintText = ""
        estimation.clearDraft()
    }

    private func confidenceColor(_ level: FoodConfidenceLevel) -> Color {
        switch level {
        case .high: return AppColor.success
        case .medium: return AppColor.warning
        case .low: return AppColor.danger
        }
    }
}

// MARK: - 相机取景

/// 相机取景控制器（复用小票扫描的同款实现）。
private struct FoodCameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        picker.allowsEditing = false
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: FoodCameraPicker
        init(_ parent: FoodCameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                 didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onImage(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

// MARK: - 菜品修改弹窗（修改名称、手动输入热量千卡、更换菜品）

struct FoodDishDetailEditSheet: View {
    let dish: FoodDishEstimate
    let onSave: (String, Double) -> Void
    let onReplaceRequest: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var nameText: String
    @State private var caloriesText: String

    init(dish: FoodDishEstimate, onSave: @escaping (String, Double) -> Void, onReplaceRequest: @escaping () -> Void) {
        self.dish = dish
        self.onSave = onSave
        self.onReplaceRequest = onReplaceRequest
        _nameText = State(initialValue: dish.food.name)
        _caloriesText = State(initialValue: "\(Int(dish.fullPortionCalories.rounded()))")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("菜品名称") {
                    TextField("输入菜名", text: $nameText)
                }

                Section {
                    HStack {
                        TextField("整份热量", text: $caloriesText)
                            .keyboardType(.numberPad)
                        Text("千卡")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("整份热量数值")
                } footer: {
                    Text("输入该道菜整份的标准热量数值，保存后将自动按当前吃掉比例换算实际摄入热量。")
                }

                Section("更换食物") {
                    Button {
                        dismiss()
                        onReplaceRequest()
                    } label: {
                        Label("从食物库选择其他菜品替换", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
            }
            .navigationTitle("修改菜品与热量")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        let parsedCal = Double(caloriesText) ?? dish.fullPortionCalories
                        onSave(nameText.trimmingCharacters(in: .whitespacesAndNewlines), parsedCal)
                        Haptic.success()
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - 食物选择器

/// 手动选择食物的列表页（支持按分类浏览、搜索、以及自定义手动添加食物）。
struct FoodSelectionSheet: View {
    let onSelect: (FoodItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var selectedCategory: FoodCategory? = nil
    @State private var showingAddCustom = false

    private var filtered: [FoodItem] {
        let key = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return FoodCatalog.items.filter { food in
            if let cat = selectedCategory, food.category != cat {
                return false
            }
            guard !key.isEmpty else { return true }
            return food.name.contains(key)
                || food.nameEn.lowercased().contains(key.lowercased())
                || food.aliases.contains { $0.contains(key) }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 分类切换胶囊栏
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button {
                            selectedCategory = nil
                            Haptic.light()
                        } label: {
                            Text("全部 (\(FoodCatalog.items.count))")
                                .font(.footnote.bold())
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(selectedCategory == nil ? AppColor.primary : Color.secondary.opacity(0.12))
                                .foregroundStyle(selectedCategory == nil ? .white : AppColor.text)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)

                        ForEach(FoodCategory.allCases) { cat in
                            let count = FoodCatalog.items.filter { $0.category == cat }.count
                            Button {
                                selectedCategory = cat
                                Haptic.light()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: cat.icon)
                                    Text("\(cat.rawValue) (\(count))")
                                }
                                .font(.footnote.bold())
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(selectedCategory == cat ? AppColor.primary : Color.secondary.opacity(0.12))
                                .foregroundStyle(selectedCategory == cat ? .white : AppColor.text)
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, AppSpacing.md)
                    .padding(.vertical, 8)
                }
                .background(AppColor.surface)

                Divider()

                List {
                    // 自定义添加入口
                    Section {
                        Button {
                            showingAddCustom = true
                        } label: {
                            HStack {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(AppColor.primary)
                                    .font(.title3)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("添加自定义食物与热量")
                                        .font(.subheadline.bold())
                                        .foregroundStyle(AppColor.primary)
                                    Text("输入任意自制菜品、外卖小吃或包装食品卡路里")
                                        .font(.caption2)
                                        .foregroundStyle(AppColor.secondaryText)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(AppColor.secondaryText)
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    Section(selectedCategory?.rawValue ?? "所有食物") {
                        ForEach(filtered) { food in
                            Button {
                                onSelect(food)
                                dismiss()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 6) {
                                            Text(food.name)
                                                .font(.body)
                                            Text(food.category.rawValue)
                                                .font(.caption2)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 1)
                                                .background(Capsule().fill(Color.secondary.opacity(0.12)))
                                                .foregroundStyle(AppColor.secondaryText)
                                        }
                                        Text("标准份约 \(Int(food.standardServingGrams.rounded()))g / \(Int(food.standardServingCalories.rounded())) 千卡 · 每100g \(Int(food.caloriesPer100g.rounded())) 千卡")
                                            .font(.caption)
                                            .foregroundStyle(AppColor.secondaryText)
                                        if let fdcID = food.fdcID {
                                            Text("USDA FDC \(fdcID)")
                                                .font(.caption2)
                                                .foregroundStyle(AppColor.secondaryText)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "plus.circle")
                                        .foregroundStyle(AppColor.primary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
            .searchable(text: $searchText, prompt: "搜索食物、别名（如螺蛳粉、糖醋里脊、东方树叶）")
            .navigationTitle("选择食物")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("自定义") { showingAddCustom = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") { dismiss() }
                }
            }
            .sheet(isPresented: $showingAddCustom) {
                AddCustomFoodSheet { customFood in
                    onSelect(customFood)
                    dismiss()
                }
            }
        }
    }
}

// MARK: - 添加自定义食物 Sheet

struct AddCustomFoodSheet: View {
    let onAdd: (FoodItem) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var caloriesText: String = ""
    @State private var category: FoodCategory = .staple

    var body: some View {
        NavigationStack {
            Form {
                Section("食物信息") {
                    TextField("食物名称（例如：自制牛肉面、外卖便当）", text: $name)
                    Picker("所属类别", selection: $category) {
                        ForEach(FoodCategory.allCases) { cat in
                            Text(cat.rawValue).tag(cat)
                        }
                    }
                }

                Section("热量数值") {
                    HStack {
                        TextField("整份热量（例如 450）", text: $caloriesText)
                            .keyboardType(.numberPad)
                        Text("千卡")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("添加自定义食物")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加并使用") {
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        let cal = Double(caloriesText) ?? 200.0
                        let customItem = FoodItem.custom(name: trimmed.isEmpty ? "自定义食物" : trimmed, calories: cal, category: category)
                        onAdd(customItem)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

// MARK: - 已保存记录的吃剩百分比与菜名热量调整 Sheet

struct FoodIntakeRecordAdjustmentSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var record: FoodIntakeRecord

    @State private var foodName: String
    @State private var portion: FoodPortion
    @State private var consumedRatio: Double
    @State private var fullPortionCalories: Double
    @State private var fullCaloriesText: String

    init(record: FoodIntakeRecord) {
        self.record = record
        _foodName = State(initialValue: record.foodName)
        _portion = State(initialValue: record.portion)
        _consumedRatio = State(initialValue: record.consumedRatio)
        _fullPortionCalories = State(initialValue: record.fullPortionCalories)
        _fullCaloriesText = State(initialValue: "\(Int(record.fullPortionCalories.rounded()))")
    }

    private var previewConsumedCalories: Double {
        fullPortionCalories * consumedRatio
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("食物全称与摄入热量") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(foodName.isEmpty ? record.foodName : foodName)
                            .font(.headline)
                            .foregroundStyle(Color.primary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack {
                            Text("整份约 \(Int(fullPortionCalories.rounded())) 千卡")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("实际摄入：")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("\(Int(previewConsumedCalories.rounded())) 千卡")
                                .font(.title3.bold().monospacedDigit())
                                .foregroundStyle(AppColor.primary)
                            if consumedRatio < 0.999 {
                                Text("(\(Int((consumedRatio * 100).rounded()))%)")
                                    .font(.caption.bold())
                                    .foregroundStyle(AppColor.primary)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }

                Section("修改菜品名称与整份热量") {
                    TextField("菜品名称", text: $foodName, axis: .vertical)
                        .lineLimit(1...4)
                    HStack {
                        Text("整份热量")
                        Spacer()
                        TextField("千卡", text: $fullCaloriesText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(minWidth: 60, idealWidth: 80, maxWidth: 80)
                            .onChange(of: fullCaloriesText) { _, newText in
                                if let val = Double(newText), val > 0 {
                                    fullPortionCalories = val
                                }
                            }
                        Text("千卡")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("调整吃掉的百分比（没吃完可下调）") {
                    HStack {
                        Text("摄入比例")
                        Spacer()
                        Button {
                            consumedRatio = max(0, consumedRatio - 0.05)
                            Haptic.light()
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)

                        Text("\(Int((consumedRatio * 100).rounded()))%")
                            .font(.subheadline.bold().monospacedDigit())
                            .foregroundStyle(AppColor.primary)
                            .frame(minWidth: 44, alignment: .center)

                        Button {
                            consumedRatio = min(1, consumedRatio + 0.05)
                            Haptic.light()
                        } label: {
                            Image(systemName: "plus.circle")
                        }
                        .buttonStyle(.plain)
                    }

                    Slider(value: $consumedRatio, in: 0...1, step: 0.05)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach([(1.0, "全部吃完 100%"), (0.75, "吃了大半 75%"), (0.5, "吃了一半 50%"), (0.33, "三分之一 33%"), (0.25, "只吃一点 25%")], id: \.0) { val, title in
                                Button(title) {
                                    consumedRatio = val
                                    Haptic.light()
                                }
                                .font(.caption2)
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                }

                Section("调整份量") {
                    Picker("份量", selection: $portion) {
                        ForEach(FoodPortion.allCases, id: \.self) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: portion) { oldPortion, newPortion in
                        if let foodID = record.foodID, let food = FoodCatalog.item(id: foodID) {
                            fullPortionCalories = food.standardServingCalories * newPortion.multiplier
                            fullCaloriesText = "\(Int(fullPortionCalories.rounded()))"
                        } else if oldPortion.multiplier > 0 {
                            fullPortionCalories = (fullPortionCalories / oldPortion.multiplier) * newPortion.multiplier
                            fullCaloriesText = "\(Int(fullPortionCalories.rounded()))"
                        }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        context.delete(record)
                        try? context.save()
                        Haptic.warning()
                        dismiss()
                    } label: {
                        Label("删除这条饮食记录", systemImage: "trash")
                    }
                }
            }
            .navigationTitle("饮食记录详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let trimmedName = foodName.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmedName.isEmpty {
                            record.foodName = trimmedName
                        }
                        record.portion = portion
                        record.fullPortionCalories = fullPortionCalories
                        record.consumedRatio = FoodCalorieEstimator.clampRatio(consumedRatio)
                        record.consumedCalories = fullPortionCalories * record.consumedRatio
                        record.isManuallyAdjusted = true
                        try? context.save()
                        Haptic.success()
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - 饮食偏好与习惯画像详情弹窗

struct DietaryPreferenceDetailView: View {
    let profile: DietaryPreferenceProfile
    let recommendations: [DietaryRecommendation]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Image(systemName: "sparkles")
                                .font(.title2)
                                .foregroundStyle(AppColor.primary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("智能饮食习惯画像")
                                    .font(.headline)
                                Text(profile.sampleCount < 2 ? "饮食记录较少，正在持续学习您的饮食偏好" : "基于近期 \(profile.sampleCount) 次饮食记录端侧提炼")
                                    .font(.caption)
                                    .foregroundStyle(AppColor.secondaryText)
                            }
                        }

                        if !profile.tags.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(profile.tags, id: \.self) { tag in
                                        Text(tag)
                                            .font(.caption.bold())
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .background(AppColor.primary.opacity(0.12))
                                            .foregroundStyle(AppColor.primary)
                                            .clipShape(Capsule())
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("☕️ 饮品偏好（咖啡 vs 奶茶 vs 纯茶）") {
                    HStack {
                        Label(profile.beverage.style.rawValue, systemImage: profile.beverage.style.icon)
                            .font(.subheadline.bold())
                        Spacer()
                        Text("饮品共 \(profile.beverage.totalDrinkCount) 次")
                            .font(.caption)
                            .foregroundStyle(AppColor.secondaryText)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("特征：\(profile.beverage.typicalTimeDescription)")
                            .font(.footnote)
                            .foregroundStyle(AppColor.secondaryText)

                        if !profile.beverage.topBeverages.isEmpty {
                            Text("常选饮品：\(profile.beverage.topBeverages.joined(separator: "、"))")
                                .font(.footnote)
                        }

                        HStack(spacing: 8) {
                            DrinkStatBadge(title: "咖啡", count: profile.beverage.coffeeCount, icon: "cup.and.saucer.fill", color: .brown)
                            DrinkStatBadge(title: "奶茶", count: profile.beverage.milkTeaCount, icon: "takeoutbag.and.cup.and.straw.fill", color: .orange)
                            DrinkStatBadge(title: "纯茶", count: profile.beverage.teaCount, icon: "leaf.fill", color: .green)
                            DrinkStatBadge(title: "其他", count: profile.beverage.otherDrinkCount, icon: "waterbottle.fill", color: .blue)
                        }
                        .padding(.top, 4)
                    }
                }

                Section("🍚 主食偏好（米饭党 vs 面食派）") {
                    HStack {
                        Label(profile.staple.style.rawValue, systemImage: profile.staple.style.icon)
                            .font(.subheadline.bold())
                        Spacer()
                        Text("主食共 \(profile.staple.totalStapleCount) 次")
                            .font(.caption)
                            .foregroundStyle(AppColor.secondaryText)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        if !profile.staple.topStaples.isEmpty {
                            Text("常吃主食：\(profile.staple.topStaples.joined(separator: "、"))")
                                .font(.footnote)
                        }

                        if profile.staple.totalStapleCount > 0 {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("面食 \(Int((profile.staple.noodleRatio * 100).rounded()))%")
                                        .font(.caption2.bold())
                                        .foregroundStyle(.orange)
                                    Spacer()
                                    Text("米饭 \(Int((profile.staple.riceRatio * 100).rounded()))%")
                                        .font(.caption2.bold())
                                        .foregroundStyle(.blue)
                                }
                                GeometryReader { geo in
                                    HStack(spacing: 2) {
                                        Rectangle()
                                            .fill(Color.orange)
                                            .frame(width: max(2, geo.size.width * CGFloat(profile.staple.noodleRatio)))
                                        Rectangle()
                                            .fill(Color.blue)
                                            .frame(width: max(2, geo.size.width * CGFloat(profile.staple.riceRatio)))
                                        Rectangle()
                                            .fill(Color.secondary.opacity(0.3))
                                    }
                                    .clipShape(Capsule())
                                }
                                .frame(height: 8)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                Section("🍰 零食与加餐习惯") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(profile.snack.summary)
                            .font(.footnote)
                        if !profile.snack.topSnacks.isEmpty {
                            Text("常选小吃：\(profile.snack.topSnacks.joined(separator: "、"))")
                                .font(.footnote)
                                .foregroundStyle(AppColor.secondaryText)
                        }
                        HStack(spacing: 8) {
                            HabitPill(
                                title: "下午茶",
                                isActive: profile.snack.hasAfternoonTeaHabit,
                                activeText: "有习惯 (14:00~17:00)",
                                inactiveText: "较少"
                            )
                            HabitPill(
                                title: "深夜宵夜",
                                isActive: profile.snack.hasLateNightHabit,
                                activeText: "有习惯 (21:00 以后)",
                                inactiveText: "极少"
                            )
                        }
                        .padding(.top, 4)
                    }
                }

                if !profile.topFoods.isEmpty {
                    Section("🏆 常吃食物 Top 5") {
                        ForEach(Array(profile.topFoods.enumerated()), id: \.offset) { index, item in
                            HStack {
                                Text("\(index + 1)")
                                    .font(.caption.bold())
                                    .frame(width: 20, height: 20)
                                    .background(index == 0 ? AppColor.primary : Color.secondary.opacity(0.15))
                                    .foregroundStyle(index == 0 ? .white : .primary)
                                    .clipShape(Circle())
                                Text(item.name)
                                    .font(.subheadline)
                                Spacer()
                                Text("\(item.count) 次")
                                    .font(.caption)
                                    .foregroundStyle(AppColor.secondaryText)
                            }
                        }
                    }
                }

                if !recommendations.isEmpty {
                    Section("💡 今日场景化饮食建议") {
                        ForEach(recommendations) { rec in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(rec.slot.rawValue)
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(AppColor.primary.opacity(0.12))
                                        .foregroundStyle(AppColor.primary)
                                        .clipShape(Capsule())
                                    Text(rec.title)
                                        .font(.subheadline.bold())
                                }
                                Text(rec.suggestionText)
                                    .font(.footnote)
                                    .foregroundStyle(AppColor.secondaryText)

                                if let tip = rec.healthTip {
                                    HStack(spacing: 4) {
                                        Image(systemName: rec.isHealthierAlternative ? "leaf.fill" : "info.circle.fill")
                                            .font(.caption2)
                                            .foregroundStyle(rec.isHealthierAlternative ? .green : AppColor.primary)
                                        Text(tip)
                                            .font(.caption2)
                                            .foregroundStyle(rec.isHealthierAlternative ? .green : AppColor.secondaryText)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.shield.fill")
                            .foregroundStyle(.green)
                        Text("饮食偏好与习惯完全在端侧本地提炼学习，不上传云端服务器，严格保护个人健康隐私。")
                            .font(.caption2)
                            .foregroundStyle(AppColor.secondaryText)
                    }
                }
            }
            .navigationTitle("饮食偏好画像")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

private struct DrinkStatBadge: View {
    let title: String
    let count: Int
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(color)
            Text(title)
                .font(.caption2)
                .foregroundStyle(AppColor.secondaryText)
            Text("\(count)次")
                .font(.caption.bold())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(AppColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous))
    }
}

private struct HabitPill: View {
    let title: String
    let isActive: Bool
    let activeText: String
    let inactiveText: String

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isActive ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 6, height: 6)
            Text("\(title): \(isActive ? activeText : inactiveText)")
                .font(.caption2)
                .foregroundStyle(isActive ? AppColor.primary : AppColor.secondaryText)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(AppColor.surface)
        .clipShape(Capsule())
    }
}

// MARK: - 图片缩放

extension UIImage {
    /// 等比缩放到指定长边，用于生成不撑大数据库的缩略图。
    func scaledDown(maxDimension: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxDimension, longest > 0 else { return self }
        let ratio = maxDimension / longest
        let newSize = CGSize(width: size.width * ratio, height: size.height * ratio)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
