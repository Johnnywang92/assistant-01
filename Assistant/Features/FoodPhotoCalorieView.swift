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
                todaySummaryCard
                dietaryRecommendationCard
                photoSection
                if estimation.isEstimating {
                    estimatingIndicator
                }
                if let estimate = estimation.estimate {
                    resultSection(estimate)
                } else if estimation.needsManualSelection {
                    manualSelectionSection
                }
                if !estimation.candidates.isEmpty {
                    candidatesSection
                }
                if !records.isEmpty {
                    recordsHistorySection
                }
            }
            .padding(AppSpacing.lg)
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

    // MARK: - 今日热量汇总卡

    private var todaySummaryCard: some View {
        HStack(spacing: AppSpacing.md) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "flame.fill")
                        .foregroundStyle(.orange)
                    Text("今日已记录摄入")
                        .font(.subheadline.bold())
                }
                if todayRecords.isEmpty {
                    Text("今日尚未记录饮食，拍张照片或选菜名即可估算")
                        .font(.caption)
                        .foregroundStyle(AppColor.secondaryText)
                } else {
                    let savedDiff = max(0, todayFullCalories - todayConsumedCalories)
                    if savedDiff >= 5 {
                        Text("共 \(todayRecords.count) 餐 · 因未吃完少摄入约 \(Int(savedDiff.rounded())) 千卡")
                            .font(.caption)
                            .foregroundStyle(AppColor.secondaryText)
                    } else {
                        Text("共记录 \(todayRecords.count) 餐 · 点击下方记录可随时修改吃剩比例")
                            .font(.caption)
                            .foregroundStyle(AppColor.secondaryText)
                    }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(Int(todayConsumedCalories.rounded()))")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(AppColor.primary)
                Text("千卡")
                    .font(.caption2)
                    .foregroundStyle(AppColor.secondaryText)
            }
        }
        .padding(AppSpacing.md)
        .appCard()
    }

    // MARK: - 饮食偏好懂你推荐卡

    private var dietaryRecommendationCard: some View {
        let profile = preferenceService.profile
        let recommendations = preferenceService.currentRecommendations

        return VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack {
                Label("懂你饮食推荐", systemImage: "sparkles")
                    .font(.subheadline.bold())
                    .foregroundStyle(AppColor.primary)
                Spacer()
                Button {
                    showingPreferenceDetail = true
                } label: {
                    HStack(spacing: 2) {
                        Text(profile.sampleCount < 2 ? "饮食画像" : (profile.tags.first ?? "饮食画像"))
                            .font(.caption.weight(.medium))
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                    }
                    .foregroundStyle(AppColor.secondaryText)
                }
            }

            if let firstRec = recommendations.first {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(firstRec.slot.rawValue)
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(AppColor.primary.opacity(0.12))
                            .foregroundStyle(AppColor.primary)
                            .clipShape(Capsule())

                        Text(firstRec.title)
                            .font(.subheadline.weight(.semibold))
                    }

                    Text(firstRec.suggestionText)
                        .font(.footnote)
                        .foregroundStyle(AppColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    if let tip = firstRec.healthTip {
                        HStack(alignment: .top, spacing: 4) {
                            Image(systemName: firstRec.isHealthierAlternative ? "leaf.fill" : "info.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(firstRec.isHealthierAlternative ? .green : AppColor.primary)
                            Text(tip)
                                .font(.caption2)
                                .foregroundStyle(firstRec.isHealthierAlternative ? .green : AppColor.secondaryText)
                        }
                    }

                    if !firstRec.suggestedFoods.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(firstRec.suggestedFoods, id: \.self) { foodName in
                                    Button {
                                        selectSuggestedFood(foodName)
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: "plus.circle.fill")
                                                .font(.caption2)
                                            Text(foodName)
                                                .font(.caption.weight(.medium))
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(AppColor.surface)
                                        .clipShape(Capsule())
                                        .overlay(
                                            Capsule()
                                                .stroke(AppColor.primary.opacity(0.2), lineWidth: 1)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            } else {
                Text("记录 2 餐以上，App 即可自动洞察你的咖啡/奶茶习惯、主食偏好与加餐规律，在合适时机给出懂你的饮食建议。")
                    .font(.footnote)
                    .foregroundStyle(AppColor.secondaryText)
            }

            if !profile.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(profile.tags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption2)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.secondary.opacity(0.1))
                                .clipShape(Capsule())
                        }
                    }
                }
            }
        }
        .padding(AppSpacing.md)
        .appCard()
    }

    private func selectSuggestedFood(_ foodName: String) {
        let cleanName = foodName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let matched = FoodCatalog.items.first(where: {
            $0.name == cleanName || cleanName.contains($0.name) || $0.name.contains(cleanName)
        }) {
            estimation.selectManually(food: matched, portion: .regular, consumedRatio: 1.0)
            didAdjust = true
            Haptic.light()
        } else {
            hintText = cleanName
            showingFoodPicker = true
        }
    }

    // MARK: - 照片区

    private var photoSection: some View {
        VStack(spacing: AppSpacing.sm) {
            if let photo {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 220)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
                    .clipped()
            } else {
                RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                    .fill(AppColor.surface)
                    .frame(height: 220)
                    .overlay {
                        VStack(spacing: AppSpacing.sm) {
                            Image(systemName: "fork.knife.circle")
                                .font(.system(size: 44))
                                .foregroundStyle(AppColor.secondaryText)
                            Text("拍一张食物照片，自动估算热量")
                                .font(.footnote)
                                .foregroundStyle(AppColor.secondaryText)
                        }
                    }
            }

            HStack(spacing: AppSpacing.sm) {
                Button {
                    showingCamera = true
                } label: {
                    Label("拍照", systemImage: "camera.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                PhotosPicker(selection: $pickedItems, maxSelectionCount: 1, matching: .images) {
                    Label("从相册选择", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .font(.footnote)

            // 补充描述与语音输入：识别不准时，用户的说明比模型猜更准
            if photo != nil {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        TextField("补充描述（支持多菜，如：米饭、辣椒炒肉）", text: $hintText)
                            .textFieldStyle(.roundedBorder)
                            .font(.footnote)
                            .onSubmit { Task { await runEstimation() } }

                        // 离线语音一键输入按钮
                        Button {
                            toggleVoiceListening()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: isListeningVoice ? "waveform" : "mic.fill")
                                    .font(.subheadline)
                                    .foregroundStyle(isListeningVoice ? .red : AppColor.primary)
                                    .symbolEffect(.bounce, value: isListeningVoice)
                                if isListeningVoice {
                                    Text("说完了")
                                        .font(.caption2.bold())
                                        .foregroundStyle(.red)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(isListeningVoice ? Color.red.opacity(0.12) : AppColor.primary.opacity(0.12))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isListeningVoice ? "停止语音输入" : "语音输入菜名")
                    }

                    if isListeningVoice {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 6, height: 6)
                            Text("正在聆听中（纯本地离线识别），可直接说出菜名组合…")
                                .font(.caption2)
                                .foregroundStyle(Color.red)
                        }
                        .padding(.leading, 2)
                    } else if !hintText.isEmpty {
                        Button("按描述重新估算") {
                            Task { await runEstimation() }
                        }
                        .font(.caption)
                    }

                    // 快捷时段与常吃菜品气泡推荐
                    let suggestions = quickSuggestionFoods
                    if !suggestions.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("快捷补菜 / 搭配推荐：")
                                .font(.caption2)
                                .foregroundStyle(AppColor.secondaryText)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(suggestions) { food in
                                        Button {
                                            handleQuickSuggestionTap(food)
                                        } label: {
                                            HStack(spacing: 4) {
                                                Image(systemName: "plus.circle.fill")
                                                    .font(.caption2)
                                                Text(food.name)
                                                    .font(.caption.weight(.medium))
                                            }
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .background(AppColor.surface)
                                            .clipShape(Capsule())
                                            .overlay(
                                                Capsule()
                                                    .stroke(AppColor.primary.opacity(0.2), lineWidth: 1)
                                            )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                        .padding(.top, 2)
                    }
                }
            }
        }
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

    // MARK: - 结果区（支持整餐多菜明细 + 份量 + 吃剩比例）

    private func resultSection(_ estimate: FoodCalorieEstimate) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            // 整餐标题与总热量（支持轻触标题改名）
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        customMealNameInput = estimate.displayName
                        showingEditMealNameAlert = true
                    } label: {
                        HStack(spacing: 5) {
                            Text(estimate.displayName)
                                .font(.headline)
                                .foregroundStyle(AppColor.text)
                            Image(systemName: "pencil.line")
                                .font(.caption)
                                .foregroundStyle(AppColor.primary)
                        }
                    }
                    .buttonStyle(.plain)

                    HStack(spacing: AppSpacing.xs) {
                        if estimate.dishes.count > 1 {
                            Text("共 \(estimate.dishes.count) 道菜品")
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(AppColor.primary.opacity(0.14)))
                                .foregroundStyle(AppColor.primary)
                        }
                        Text(estimate.confidenceLevel.displayName)
                            .font(.caption2)
                            .foregroundStyle(confidenceColor(estimate.confidenceLevel))
                        if estimate.confidence < 1 {
                            Text("置信度 \(Int(estimate.confidence * 100))%")
                                .font(.caption2)
                                .foregroundStyle(AppColor.secondaryText)
                        }
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(Int(estimate.consumedCalories.rounded()))")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(AppColor.primary)
                        + Text(" 千卡")
                        .font(.footnote)
                        .foregroundStyle(AppColor.secondaryText)
                    if estimate.consumedRatio < 0.999 || estimate.dishes.count > 1 {
                        Text("整份合计约 \(Int(estimate.fullPortionCalories.rounded())) 千卡")
                            .font(.caption2)
                            .foregroundStyle(AppColor.secondaryText)
                    }
                }
            }

            Divider()

            // 本餐识别菜品明细（可点击单道菜修改菜名/换菜/直接改热量数值，或调整份量、吃剩百分比，增删配菜）
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                HStack {
                    Text("本餐菜品明细")
                        .font(.subheadline.bold())
                    Spacer()
                    Button {
                        showingAddDishPicker = true
                    } label: {
                        Label("添加配菜/主食", systemImage: "plus.circle.fill")
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
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text(dish.food.name)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(AppColor.text)
                                    Image(systemName: "pencil")
                                        .font(.caption2)
                                        .foregroundStyle(AppColor.primary)
                                }
                                Text("\(dish.portion.displayName)约 \(Int((dish.food.standardServingGrams * dish.portion.multiplier).rounded()))g · 整份 \(Int(dish.fullPortionCalories.rounded())) 千卡 · 实入 \(Int(dish.consumedCalories.rounded())) 千卡")
                                    .font(.caption2)
                                    .foregroundStyle(AppColor.secondaryText)
                            }
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        // 单道菜份量切换
                        Menu {
                            ForEach(FoodPortion.allCases, id: \.self) { p in
                                Button {
                                    estimation.updateDishPortion(dishID: dish.id, portion: p)
                                    didAdjust = true
                                    Haptic.light()
                                } label: {
                                    if dish.portion == p {
                                        Label(p.displayName, systemImage: "checkmark")
                                    } else {
                                        Text(p.displayName)
                                    }
                                }
                            }
                        } label: {
                            Text(dish.portion.displayName)
                                .font(.caption2)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.secondary.opacity(0.14)))
                        }

                        // 单道菜吃掉比例微调（如米饭只吃一半，菜吃完了）
                        HStack(spacing: 4) {
                            Button {
                                estimation.updateDishConsumedRatio(dishID: dish.id, ratio: max(0, dish.consumedRatio - 0.25))
                                didAdjust = true
                                Haptic.light()
                            } label: {
                                Image(systemName: "minus.circle")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)

                            Text("\(Int((dish.consumedRatio * 100).rounded()))%")
                                .font(.caption.bold().monospacedDigit())
                                .foregroundStyle(AppColor.primary)
                                .frame(minWidth: 36, alignment: .center)

                            Button {
                                estimation.updateDishConsumedRatio(dishID: dish.id, ratio: min(1, dish.consumedRatio + 0.25))
                                didAdjust = true
                                Haptic.light()
                            } label: {
                                Image(systemName: "plus.circle")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                        }

                        if estimate.dishes.count > 1 {
                            Button {
                                estimation.removeDish(dishID: dish.id)
                                didAdjust = true
                                Haptic.light()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(AppColor.secondaryText)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(
                        RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous)
                            .fill(Color.secondary.opacity(0.07))
                    )
                }
            }

            Divider()

            // 整餐份量选择
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text("整餐份量")
                    .font(.subheadline.bold())
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

            // 吃剩比例（核心需求：有时候没吃完，支持滑杆/步进/快捷比例实时调整）
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                HStack(spacing: 8) {
                    Text("整餐吃了多少")
                        .font(.subheadline.bold())
                    Spacer()
                    Button {
                        let current = estimation.estimate?.consumedRatio ?? 1.0
                        estimation.updateConsumedRatio(max(0, current - 0.05))
                        didAdjust = true
                        Haptic.light()
                    } label: {
                        Image(systemName: "minus.circle")
                            .font(.subheadline)
                    }
                    .buttonStyle(.plain)

                    Text("\(Int(((estimation.estimate?.consumedRatio ?? 1) * 100).rounded()))%")
                        .font(.subheadline.bold().monospacedDigit())
                        .foregroundStyle(AppColor.primary)
                        .frame(minWidth: 44, alignment: .center)

                    Button {
                        let current = estimation.estimate?.consumedRatio ?? 1.0
                        estimation.updateConsumedRatio(min(1, current + 0.05))
                        didAdjust = true
                        Haptic.light()
                    } label: {
                        Image(systemName: "plus.circle")
                            .font(.subheadline)
                    }
                    .buttonStyle(.plain)
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
                // 常用快捷值
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: AppSpacing.xs) {
                        ForEach([(1.0, "全部吃完 100%"), (0.75, "吃了大半 75%"), (0.5, "吃了一半 50%"), (0.33, "三分之一 33%"), (0.25, "只吃一点 25%")], id: \.0) { value, label in
                            Button(label) {
                                estimation.updateConsumedRatio(value)
                                didAdjust = true
                                Haptic.light()
                            }
                            .font(.caption2)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }

            if let message = estimation.statusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(AppColor.secondaryText)
            }

            HStack {
                // 改选食物
                Button {
                    showingFoodPicker = true
                } label: {
                    Label("重选主菜", systemImage: "list.bullet")
                        .font(.footnote)
                }
                .buttonStyle(.borderless)

                Spacer()

                Button {
                    saveRecord()
                } label: {
                    Label("保存本次记录", systemImage: "checkmark.circle.fill")
                        .font(.footnote.bold())
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(AppSpacing.md)
        .appCard()
    }

    // MARK: - 手动选择区

    private var manualSelectionSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Label("照片没能认出具体食物", systemImage: "questionmark.circle")
                .font(.subheadline.bold())
                .foregroundStyle(AppColor.warning)
            Text("这在沙拉、混合菜这类菜品上很常见——照片里看不出用了什么食材。手动选一个或添加多道菜品，热量依然只是参考值。")
                .font(.caption)
                .foregroundStyle(AppColor.secondaryText)
            Button {
                showingFoodPicker = true
            } label: {
                Label("手动选择食物", systemImage: "list.bullet")
            }
            .buttonStyle(.borderedProminent)
            .font(.footnote)
        }
        .padding(AppSpacing.md)
        .appCard()
    }

    // MARK: - 候选区（支持一键「+ 加入本餐」或替换）

    private var candidatesSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack {
                Text("识别到的可能食物")
                    .font(.subheadline.bold())
                Spacer()
                Text("可点击加入本餐累加热量")
                    .font(.caption2)
                    .foregroundStyle(AppColor.secondaryText)
            }
            ForEach(vision.candidates) { candidate in
                let isIncluded = estimation.estimate?.dishes.contains(where: { $0.food.id == candidate.food.id }) ?? false
                HStack(spacing: AppSpacing.sm) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(candidate.food.name)
                            .font(.subheadline)
                        Text("标准份约 \(Int(candidate.food.standardServingCalories.rounded())) 千卡 · 识别度 \(Int(candidate.confidence * 100))%")
                            .font(.caption2)
                            .foregroundStyle(AppColor.secondaryText)
                    }
                    Spacer()
                    if isIncluded {
                        Text("已计入本餐 ✓")
                            .font(.caption2.bold())
                            .foregroundStyle(AppColor.success)
                    } else {
                        Button {
                            estimation.addDish(
                                food: candidate.food,
                                portion: .regular,
                                consumedRatio: estimation.estimate?.consumedRatio ?? 1.0
                            )
                            didAdjust = true
                            Haptic.light()
                        } label: {
                            Label("加入本餐", systemImage: "plus.circle.fill")
                                .font(.caption.bold())
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(AppSpacing.md)
        .appCard()
    }

    // MARK: - 历史记录与吃剩比例二次调整

    private var recordsHistorySection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack {
                Text("近期饮食记录")
                    .font(.subheadline.bold())
                Spacer()
                Text("轻触查看详情与调整热量")
                    .font(.caption2)
                    .foregroundStyle(AppColor.secondaryText)
            }

            ForEach(records.prefix(20)) { record in
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

                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.foodName)
                                .font(.subheadline.bold())
                                .foregroundStyle(AppColor.text)
                                .lineLimit(1)
                                .truncationMode(.tail)

                            HStack(spacing: 6) {
                                Text(record.portion.displayName)
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                                    .foregroundStyle(AppColor.secondaryText)
                                    .fixedSize()

                                if record.consumedRatio < 0.999 {
                                    Text("吃了 \(Int((record.consumedRatio * 100).rounded()))%")
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(AppColor.primary.opacity(0.15)))
                                        .foregroundStyle(AppColor.primary)
                                        .fixedSize()
                                }

                                Text("· \(record.date.formatted(date: .abbreviated, time: .shortened))")
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
                            .font(.caption2.bold())
                            .foregroundStyle(AppColor.secondaryText.opacity(0.6))
                    }
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                if record.id != records.prefix(20).last?.id {
                    Divider()
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
            if hintText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                hintText = food.name
            } else {
                hintText += "、" + food.name
            }
            Haptic.light()
            Task {
                await runEstimation()
            }
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
        let clean = hintText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty {
            Task {
                await runEstimation()
            }
        }
    }

    private func stopVoiceListening() {
        isListeningVoice = false
        voiceService.stopListening()
    }

    // MARK: - 动作

    private func runEstimation() async {
        guard let photo else { return }
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
