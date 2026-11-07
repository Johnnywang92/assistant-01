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
    @State private var showingBanquetSheet = false
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
    /// 个性化每日热量目标（千卡，默认 2000，用户可自定义）
    @AppStorage("daily_calorie_goal_kcal") private var dailyCalorieGoal: Double = 2000.0
    @State private var showingGoalSettingAlert = false
    @State private var goalInputText = ""
    /// 拍照后进入专门的 AI 识别与校正页面
    @State private var showingRecognitionDetailSheet = false
    /// 饮食记录展示周期筛选
    @State private var selectedRecordPeriod: FoodRecordPeriodFilter = .today
    /// 完成并保存饮食记录时的微动效反馈数据
    @State private var activeSavedMotion: FoodSavedMotionData? = nil

    /// 今日营养素摄入汇总（蛋白质、碳水、脂肪，单位克）
    private var todayMacroNutrients: (protein: Double, carbs: Double, fat: Double) {
        var p: Double = 0
        var c: Double = 0
        var f: Double = 0
        for r in todayRecords {
            if let foodID = r.foodID?.components(separatedBy: "+").first,
               let item = FoodCatalog.item(id: foodID) {
                let ratio = (r.consumedCalories / max(1, item.caloriesPer100g))
                p += ratio * item.proteinPer100g
                c += ratio * item.carbsPer100g
                f += ratio * item.fatPer100g
            } else {
                // 自定义或组合菜品按标准健康均衡宏量推算（碳水 50%、蛋白 20%、脂肪 30%）
                let cal = r.consumedCalories
                c += (cal * 0.50) / 4.0
                p += (cal * 0.20) / 4.0
                f += (cal * 0.30) / 9.0
            }
        }
        return (protein: p, carbs: c, fat: f)
    }

    /// 根据热量目标自动推算的参考营养配比目标（碳水 50%、蛋白 20%、脂肪 30%）
    private var targetMacros: (protein: Double, carbs: Double, fat: Double) {
        let cal = max(1000, dailyCalorieGoal)
        let c = (cal * 0.50) / 4.0
        let p = (cal * 0.20) / 4.0
        let f = (cal * 0.30) / 9.0
        return (protein: p, carbs: c, fat: f)
    }

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
            .padding(.bottom, 64)
        }
        .themedAppBackground()
        .navigationTitle("食物热量估算")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showingCamera) {
            FoodCameraPicker { image in
                photo = image
                showingCamera = false
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
            FoodDishDetailEditSheet(dish: dish) { newName, newGrams, newMethod, newOil, newPrepState, newCal in
                estimation.updateDishConfig(
                    dishID: dish.id,
                    name: newName,
                    grams: newGrams,
                    cookingMethod: newMethod,
                    oilSauceLevel: newOil,
                    preparationState: newPrepState,
                    calories: newCal
                )
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
        .sheet(isPresented: $showingBanquetSheet) {
            FoodBanquetQuickEstimateSheet(
                onApplyDraft: { scene, appetite, drink in
                    estimation.applyBanquetPreset(scene: scene, appetite: appetite, drinkAddon: drink)
                    didAdjust = true
                    Haptic.light()
                },
                onDirectSave: { scene, appetite, drink in
                    estimation.applyBanquetPreset(scene: scene, appetite: appetite, drinkAddon: drink)
                    didAdjust = true
                    saveRecord()
                }
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
        .alert("设置每日热量目标", isPresented: $showingGoalSettingAlert) {
            TextField("目标热量 (千卡)", text: $goalInputText)
                .keyboardType(.numberPad)
            Button("保存") {
                if let val = Double(goalInputText), val >= 500, val <= 10000 {
                    dailyCalorieGoal = val
                }
            }
            Button("恢复推荐 (2000)", role: .destructive) {
                dailyCalorieGoal = 2000
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("个性化设定每日热量消耗目标，用于计算剩余热量与宏量营养素推荐。")
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
        .overlay {
            FoodCalorieSavedOverlay(motion: $activeSavedMotion)
        }
    }

    // MARK: - 顶部今日营养仪表盘（摄入、剩余热量、宏量营养素与个性化目标）

    private var topSummaryAndRecommendationCard: some View {
        let recommendations = preferenceService.currentRecommendations
        let consumed = todayConsumedCalories
        let goal = max(500, dailyCalorieGoal)
        let remaining = goal - consumed
        let macros = todayMacroNutrients
        let targetM = targetMacros

        return VStack(spacing: 10) {
            // 1. 核心热量与剩余额度
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text("今日摄入")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(AppColor.secondaryText)
                        Button {
                            goalInputText = "\(Int(dailyCalorieGoal.rounded()))"
                            showingGoalSettingAlert = true
                        } label: {
                            HStack(spacing: 2) {
                                Text("/ \(Int(goal.rounded())) 千卡")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(AppColor.secondaryText)
                                Image(systemName: "pencil")
                                    .font(.system(size: 9))
                                    .foregroundStyle(AppColor.primary)
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(Int(consumed.rounded()))")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(AppColor.primary)
                            .contentTransition(.numericText())
                        Text("千卡")
                            .font(.caption2.bold())
                            .foregroundStyle(AppColor.secondaryText)
                    }
                }

                Spacer()

                // 剩余热量卡片
                VStack(alignment: .trailing, spacing: 3) {
                    Text("剩余可用")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(AppColor.secondaryText)
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(Int(remaining.rounded()))")
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundStyle(remaining >= 0 ? AppColor.success : AppColor.danger)
                            .contentTransition(.numericText())
                        Text("千卡")
                            .font(.caption2.bold())
                            .foregroundStyle(AppColor.secondaryText)
                    }
                }
            }

            // 2. 宏量营养素进度条（蛋白质、碳水、脂肪闭环管理）
            HStack(spacing: 8) {
                macroItemView(
                    title: "蛋白质",
                    current: macros.protein,
                    target: targetM.protein,
                    color: Color.blue
                )
                macroItemView(
                    title: "碳水",
                    current: macros.carbs,
                    target: targetM.carbs,
                    color: Color.orange
                )
                macroItemView(
                    title: "脂肪",
                    current: macros.fat,
                    target: targetM.fat,
                    color: Color.purple
                )
            }
            .padding(.vertical, 2)

            // 3. 饮食场景建议
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

    private func macroItemView(title: String, current: Double, target: Double, color: Color) -> some View {
        let ratio = target > 0 ? min(1.0, current / target) : 0
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(AppColor.secondaryText)
                Spacer()
                Text("\(Int(current.rounded()))/\(Int(target.rounded()))g")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(AppColor.text)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.12))
                    Capsule()
                        .fill(color)
                        .frame(width: max(3, geo.size.width * CGFloat(ratio)))
                }
            }
            .frame(height: 5)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(.tertiarySystemFill))
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous))
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

            // 2. 主视觉录入口：以拍照识别为主入口，相册与食物库作为辅助
            VStack(spacing: 8) {
                Button {
                    showingCamera = true
                } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.22))
                                .frame(width: 44, height: 44)
                            Image(systemName: "camera.fill")
                                .font(.title3)
                                .foregroundStyle(.white)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text("拍照识别食物与营养")
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(.white)
                            Text("AI 自动检测分量、分析烹饪方式并支持逐项校正")
                                .font(.caption2)
                                .foregroundStyle(Color.white.opacity(0.85))
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.bold())
                            .foregroundStyle(Color.white.opacity(0.7))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        LinearGradient(
                            colors: [AppColor.primary, AppColor.primary.opacity(0.82)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
                    .shadow(color: AppColor.primary.opacity(0.25), radius: 8, y: 3)
                }
                .buttonStyle(.plain)

                // 辅助快捷入口栏（相册导入、食物库快速挑选、宴席/聚餐多菜速记）
                HStack(spacing: 8) {
                    PhotosPicker(selection: $pickedItems, maxSelectionCount: 1, matching: .images) {
                        Label("相册导入", systemImage: "photo.on.rectangle")
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

                    Button {
                        showingBanquetSheet = true
                        Haptic.light()
                    } label: {
                        Label("宴席/聚餐", systemImage: "person.3.fill")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .foregroundStyle(Color.orange)
                            .background(Color.orange.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }

            // 3. 常驻文字与语音输入框（整合录音与手输，避免悬浮遮挡历史记录）
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

                // 输入框内集成的语音输入按钮
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

            // 热量可信度区间与误差源分析（诚实展示区间，打破对单点数字的怀疑）
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.caption2)
                        .foregroundStyle(AppColor.primary)
                    Text(estimate.calorieRangeDescription)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppColor.primary)
                    Spacer()
                    Text("80% 置信区间")
                        .font(.system(size: 10))
                        .foregroundStyle(AppColor.secondaryText)
                }
                Text(estimate.uncertaintyFactorsSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(AppColor.secondaryText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(AppColor.primary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous))

            Divider()

            // 2. 餐品明细（点击整行进入修改/换菜/改热量，去除杂乱的行内小步进器）
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("菜品明细 (点击任意菜品修改/校准)")
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
                                    HStack(spacing: 4) {
                                        Text(dish.food.name)
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(AppColor.text)
                                        if dish.food.hasBoneOrShell {
                                            Text("带骨壳")
                                                .font(.system(size: 9, weight: .medium))
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 1)
                                                .background(Color.orange.opacity(0.15))
                                                .foregroundStyle(.orange)
                                                .clipShape(Capsule())
                                        }
                                    }
                                    Text("\(Int(dish.currentGrams))g · \(dish.food.stateAndCookingLabel(overrideMethod: dish.cookingMethod)) · \(Int(dish.fullPortionCalories.rounded())) 卡")
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

                        // 单菜分量与烹饪快调
                        Menu {
                            Section("常见份量/容器") {
                                ForEach(dish.food.containerPresets) { preset in
                                    Button("\(preset.label) (\(preset.subtitle))") {
                                        estimation.updateDishGrams(dishID: dish.id, grams: preset.grams)
                                        didAdjust = true
                                        Haptic.light()
                                    }
                                }
                            }
                            Section("烹饪方式") {
                                ForEach(FoodCookingMethod.allCases) { method in
                                    Button(method.rawValue) {
                                        estimation.updateDishCookingMethod(dishID: dish.id, method: method)
                                        didAdjust = true
                                        Haptic.light()
                                    }
                                }
                            }
                            Section("用油档位") {
                                ForEach(FoodOilSauceLevel.allCases) { level in
                                    Button(level.rawValue) {
                                        estimation.updateDishOilSauceLevel(dishID: dish.id, level: level)
                                        didAdjust = true
                                        Haptic.light()
                                    }
                                }
                            }
                        } label: {
                            Text("\(Int(dish.currentGrams))g · \(dish.cookingMethod.rawValue)")
                                .font(.system(size: 11, weight: .medium))
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
                            .iconButton("删除这项食物")
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

                HStack(spacing: 6) {
                    ForEach([(1.0, "吃完 100%"), (0.75, "大半 75%"), (0.5, "一半 50%"), (0.25, "少许 25%"), (0.15, "尝几筷 15%")], id: \.0) { value, label in
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
        let savedName = estimate.displayName
        let savedCalories = estimate.consumedCalories
        let savedRatio = estimate.consumedRatio
        // 缩略图压到 480px 长边，避免撑大数据库
        let imageData = photo?.scaledDown(maxDimension: 480).jpegData(compressionQuality: 0.7)
        let record = FoodIntakeRecord(
            date: mealDate,
            foodName: savedName,
            foodID: estimate.dishes.count == 1 ? estimate.food.id : estimate.dishes.map(\.food.id).joined(separator: "+"),
            portion: estimate.portion,
            fullPortionCalories: estimate.fullPortionCalories,
            consumedRatio: savedRatio,
            confidence: estimate.confidence,
            isManuallyAdjusted: didAdjust,
            source: photo != nil ? .vision : .manual,
            imageData: imageData
        )
        context.insert(record)
        guard context.saveReportingFailure({ SaveFailureCenter.shared.report($0, action: "保存饮食记录") }) else {
            Haptic.error()
            return
        }
        Haptic.success()

        // 触发饮食记录入账微动效，并平滑收起当前估算草稿卡片
        AppMotion.animate(.spring(response: 0.38, dampingFraction: 0.82)) {
            activeSavedMotion = FoodSavedMotionData(
                foodName: savedName,
                consumedCalories: savedCalories,
                consumedRatio: savedRatio
            )
            photo = nil
            pickedItems = []
            hintText = ""
            estimation.clearDraft()
        }
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

// MARK: - 菜品多维校准弹窗（分量克数、容器预设、烹饪方式、用油量、称量状态、热量与宏量营养素校准）

struct FoodDishDetailEditSheet: View {
    let dish: FoodDishEstimate
    let onSave: (_ name: String, _ grams: Double, _ method: FoodCookingMethod, _ oilLevel: FoodOilSauceLevel, _ prepState: FoodPreparationState, _ calories: Double) -> Void
    let onReplaceRequest: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var nameText: String
    @State private var grams: Double
    @State private var cookingMethod: FoodCookingMethod
    @State private var oilSauceLevel: FoodOilSauceLevel
    @State private var preparationState: FoodPreparationState
    @State private var isCustomizingCalories: Bool = false
    @State private var customCaloriesText: String

    init(dish: FoodDishEstimate,
         onSave: @escaping (_ name: String, _ grams: Double, _ method: FoodCookingMethod, _ oilLevel: FoodOilSauceLevel, _ prepState: FoodPreparationState, _ calories: Double) -> Void,
         onReplaceRequest: @escaping () -> Void) {
        self.dish = dish
        self.onSave = onSave
        self.onReplaceRequest = onReplaceRequest
        _nameText = State(initialValue: dish.food.name)
        _grams = State(initialValue: dish.currentGrams)
        _cookingMethod = State(initialValue: dish.cookingMethod)
        _oilSauceLevel = State(initialValue: dish.oilSauceLevel)
        _preparationState = State(initialValue: dish.preparationState)
        _customCaloriesText = State(initialValue: "\(Int(dish.fullPortionCalories.rounded()))")
    }

    private var stateAdjustedGrams: Double {
        if preparationState == .raw && dish.food.defaultState == .cooked {
            return grams * dish.food.rawToCookedRatio
        } else if preparationState == .cooked && dish.food.defaultState == .raw {
            return grams / max(0.1, dish.food.rawToCookedRatio)
        }
        return grams
    }

    private var edibleGrams: Double {
        stateAdjustedGrams * dish.food.edibleRatio
    }

    private var computedCalories: Double {
        if isCustomizingCalories, let cal = Double(customCaloriesText), cal > 0 {
            return cal
        }
        let base = (edibleGrams / 100.0) * dish.food.caloriesPer100g
        let methodFactor = (cookingMethod == dish.food.defaultCookingMethod) ? 1.0 : (cookingMethod.calorieFactor / dish.food.defaultCookingMethod.calorieFactor)
        return (base * methodFactor * oilSauceLevel.multiplier).rounded()
    }

    private var computedProtein: Double {
        (edibleGrams / 100.0) * dish.food.proteinPer100g
    }

    private var computedCarbs: Double {
        let baseCarbs = (edibleGrams / 100.0) * dish.food.carbsPer100g
        if cookingMethod == .deepFriedOrBreaded && dish.food.defaultCookingMethod != .deepFriedOrBreaded {
            let baseCalories = (edibleGrams / 100.0) * dish.food.caloriesPer100g
            let extraCalories = max(0, computedCalories - baseCalories)
            return baseCarbs + (extraCalories * 0.25 / 4.0)
        }
        return baseCarbs
    }

    private var computedFat: Double {
        let baseFat = (edibleGrams / 100.0) * dish.food.fatPer100g
        let baseCalories = (edibleGrams / 100.0) * dish.food.caloriesPer100g
        let extraCalories = max(0, computedCalories - baseCalories)
        let oilCalories = (cookingMethod == .deepFriedOrBreaded && dish.food.defaultCookingMethod != .deepFriedOrBreaded)
            ? (extraCalories * 0.75)
            : extraCalories
        return baseFat + (oilCalories / 9.0)
    }

    private var calorieRange: (low: Double, high: Double) {
        let uncert = cookingMethod.relativeUncertainty + (dish.food.hasBoneOrShell ? 0.08 : 0.04)
        let delta = computedCalories * uncert
        return (low: max(0, (computedCalories - delta).rounded()), high: (computedCalories + delta).rounded())
    }

    var body: some View {
        NavigationStack {
            Form {
                // 1. 菜品名称与称量状态
                Section("菜品基本信息") {
                    TextField("输入菜名", text: $nameText)

                    Picker("称重状态", selection: $preparationState) {
                        Text("熟食/烹饪后称重").tag(FoodPreparationState.cooked)
                        Text("生食/原料称量").tag(FoodPreparationState.raw)
                    }
                    .pickerStyle(.segmented)

                    if preparationState == .raw && dish.food.defaultState == .cooked {
                        Text("已按生原料吸水膨胀系数（约 ×\(String(format: "%.1f", dish.food.rawToCookedRatio))）换算为等效熟食分量。")
                            .font(.caption2)
                            .foregroundStyle(AppColor.primary)
                    } else if preparationState == .cooked && dish.food.defaultState == .raw {
                        Text("已按原料熟化脱水系数（约 ÷\(String(format: "%.1f", dish.food.rawToCookedRatio))）换算为等效生重基准。")
                            .font(.caption2)
                            .foregroundStyle(AppColor.primary)
                    }

                    if dish.food.hasBoneOrShell {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "checkmark.shield.fill")
                                .font(.subheadline)
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("带骨/带壳食材提示")
                                    .font(.caption.bold())
                                    .foregroundStyle(.orange)
                                Text("已扣除骨壳重量（可食率约 \(Int(dish.food.edibleRatio * 100))%）。以当前称重 \(Int(grams))g 换算，纯可食净肉约 \(Int(edibleGrams.rounded()))g。")
                                    .font(.caption2)
                                    .foregroundStyle(Color.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                // 2. 份量估算与容器校准 (Container Calibration)
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("预估称重重量")
                                .font(.subheadline)
                            Spacer()
                            Text("\(Int(grams)) 克")
                                .font(.subheadline.bold().monospacedDigit())
                                .foregroundStyle(AppColor.primary)
                        }

                        Slider(value: $grams, in: 20...1000, step: 5)
                            .onChange(of: grams) { _, _ in
                                if isCustomizingCalories {
                                    isCustomizingCalories = false
                                }
                            }

                        // 常见容器快捷点选（如：小碗 100g、普通碗 150g、大碗 250g）
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(dish.food.containerPresets) { preset in
                                    let isSelected = abs(grams - preset.grams) < 2
                                    Button {
                                        grams = preset.grams
                                        isCustomizingCalories = false
                                        Haptic.light()
                                    } label: {
                                        VStack(spacing: 2) {
                                            Text(preset.label)
                                                .font(.caption.weight(isSelected ? .bold : .medium))
                                            Text(preset.subtitle)
                                                .font(.system(size: 9))
                                                .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(isSelected ? AppColor.primary : Color.secondary.opacity(0.12))
                                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("份量与容器校准")
                } footer: {
                    Text("分量是决定热量准确性的最关键因素。可通过预设容器（如家用中碗约150g）快速对齐。")
                }

                // 3. 烹饪方式与用油量 (Cooking & Oil)
                Section("烹饪方式与调味用油") {
                    Picker("烹饪方式", selection: $cookingMethod) {
                        ForEach(FoodCookingMethod.allCases) { method in
                            Text(method.rawValue).tag(method)
                        }
                    }

                    Picker("用油 / 酱汁量", selection: $oilSauceLevel) {
                        ForEach(FoodOilSauceLevel.allCases) { level in
                            Text(level.rawValue).tag(level)
                        }
                    }
                }

                // 4. 实时热量与三大宏量营养素
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("整份热量估算")
                                    .font(.caption)
                                    .foregroundStyle(Color.secondary)
                                HStack(alignment: .firstTextBaseline, spacing: 3) {
                                    Text("\(Int(computedCalories.rounded()))")
                                        .font(.system(size: 26, weight: .bold, design: .rounded))
                                        .foregroundStyle(AppColor.primary)
                                    Text("千卡")
                                        .font(.caption.bold())
                                        .foregroundStyle(Color.secondary)
                                }
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("置信区间")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color.secondary)
                                Text("\(Int(calorieRange.low))–\(Int(calorieRange.high)) 千卡")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(AppColor.primary)
                            }
                        }

                        Divider()

                        HStack(spacing: 8) {
                            VStack(spacing: 2) {
                                Text("蛋白质")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color.secondary)
                                Text("\(String(format: "%.1f", computedProtein))g")
                                    .font(.caption.bold())
                            }
                            .frame(maxWidth: .infinity)

                            VStack(spacing: 2) {
                                Text("碳水")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color.secondary)
                                Text("\(String(format: "%.1f", computedCarbs))g")
                                    .font(.caption.bold())
                            }
                            .frame(maxWidth: .infinity)

                            VStack(spacing: 2) {
                                Text("脂肪")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color.secondary)
                                Text("\(String(format: "%.1f", computedFat))g")
                                    .font(.caption.bold())
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .padding(.vertical, 4)

                        // 手动输入卡路里数值开关
                        Toggle("手动直接指定卡路里数值", isOn: $isCustomizingCalories)
                            .font(.caption)

                        if isCustomizingCalories {
                            HStack {
                                TextField("手动卡路里", text: $customCaloriesText)
                                    .keyboardType(.numberPad)
                                Text("千卡")
                                    .foregroundStyle(.secondary)
                            }
                            .font(.subheadline)
                        }
                    }
                    .padding(.vertical, 2)
                } header: {
                    Text("营养与热量分解")
                }

                // 5. 更换食物
                Section("食物替换") {
                    Button {
                        dismiss()
                        onReplaceRequest()
                    } label: {
                        Label("从食物库选择其他菜品替换", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
            }
            .navigationTitle("校准菜品与营养")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        let finalCal = computedCalories
                        onSave(
                            nameText.trimmingCharacters(in: .whitespacesAndNewlines),
                            grams,
                            cookingMethod,
                            oilSauceLevel,
                            preparationState,
                            finalCal
                        )
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
                        guard context.saveReportingFailure({ SaveFailureCenter.shared.report($0, action: "删除饮食记录") }) else {
                            Haptic.error()
                            return
                        }
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
                        guard context.saveReportingFailure({ SaveFailureCenter.shared.report($0, action: "保存饮食记录修改") }) else {
                            Haptic.error()
                            return
                        }
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

// MARK: - 饮食热量保存入账微动效覆盖层（轻量、非阻塞、60/120fps）

struct FoodSavedMotionData: Equatable {
    let id = UUID()
    let foodName: String
    let consumedCalories: Double
    let consumedRatio: Double
}

private struct FoodCalorieSavedOverlay: View {
    @Binding var motion: FoodSavedMotionData?

    var body: some View {
        ZStack {
            if let data = motion {
                FoodCalorieSavedBadge(data: data) {
                    AppMotion.animate(.easeOut(duration: 0.22)) {
                        if motion?.id == data.id {
                            motion = nil
                        }
                    }
                }
                .id(data.id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

private struct FoodCalorieSavedBadge: View {
    let data: FoodSavedMotionData
    let onFinished: () -> Void

    @State private var hubScale: CGFloat = 0.45
    @State private var hubOpacity: Double = 0.0
    @State private var ringScale: CGFloat = 0.65
    @State private var ringOpacity: Double = 0.75
    @State private var sparkleProgress: CGFloat = 0.0
    @State private var pillOffsetY: CGFloat = 24
    @State private var pillOpacity: Double = 0.0

    var body: some View {
        VStack(spacing: 12) {
            if !AppMotion.reduceMotion {
                ZStack {
                    // 扩散能量波纹环
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [Color.orange.opacity(0.65), AppColor.success.opacity(0.45)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 2.5
                        )
                        .frame(width: 76, height: 76)
                        .scaleEffect(ringScale)
                        .opacity(ringOpacity)

                    // 周围 6 颗轻盈星芒粒子
                    ForEach(0..<6, id: \.self) { index in
                        let angle = Double(index) * (.pi / 3.0)
                        let radius: CGFloat = 46 * sparkleProgress
                        Image(systemName: index.isMultiple(of: 2) ? "sparkle" : "flame.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(index.isMultiple(of: 2) ? Color.orange : AppColor.success)
                            .scaleEffect(max(0.1, 1.0 - sparkleProgress * 0.4))
                            .opacity(Double(1.0 - sparkleProgress))
                            .offset(
                                x: cos(angle) * radius,
                                y: sin(angle) * radius
                            )
                    }

                    // 中心餐盘打卡徽章
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color.orange, AppColor.primary],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 60, height: 60)

                        Image(systemName: "fork.knife.circle.fill")
                            .font(.system(size: 32, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .scaleEffect(hubScale)
                    .opacity(hubOpacity)
                }
            }

            // 底部悬浮入账胶囊
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(AppColor.success)

                VStack(alignment: .leading, spacing: 1) {
                    Text("已记入今日饮食 · \(data.foodName)")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        Text("+\(Int(data.consumedCalories.rounded())) 千卡")
                            .font(.caption2.bold().monospacedDigit())
                            .foregroundStyle(Color.orange)
                        if data.consumedRatio < 0.999 {
                            Text("(\(Int((data.consumedRatio * 100).rounded()))% 进食量)")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.8))
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Capsule().fill(Color.black.opacity(0.84)))
            .offset(y: pillOffsetY)
            .opacity(pillOpacity)
        }
        .onAppear {
            playAnimation()
        }
    }

    private func playAnimation() {
        if AppMotion.reduceMotion {
            pillOffsetY = 0
            pillOpacity = 1.0
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                onFinished()
            }
            return
        }

        withAnimation(.spring(response: 0.36, dampingFraction: 0.68)) {
            hubScale = 1.0
            hubOpacity = 1.0
            pillOffsetY = 0
            pillOpacity = 1.0
        }

        withAnimation(.easeOut(duration: 0.65)) {
            ringScale = 1.45
            ringOpacity = 0.0
            sparkleProgress = 1.0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.15) {
            withAnimation(.easeIn(duration: 0.22)) {
                hubScale = 0.85
                hubOpacity = 0.0
                pillOffsetY = -12
                pillOpacity = 0.0
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            onFinished()
        }
    }
}

// MARK: - 宴席 / 聚餐多菜品快捷估算弹窗

private struct FoodBanquetQuickEstimateSheet: View {
    let onApplyDraft: (FoodBanquetScene, FoodBanquetAppetiteLevel, FoodBanquetDrinkAddon) -> Void
    let onDirectSave: (FoodBanquetScene, FoodBanquetAppetiteLevel, FoodBanquetDrinkAddon) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedScene: FoodBanquetScene = .chineseBanquet
    @State private var selectedAppetite: FoodBanquetAppetiteLevel = .normal
    @State private var selectedDrink: FoodBanquetDrinkAddon = .none

    private var previewEstimate: FoodCalorieEstimate {
        FoodEstimationService.buildBanquetEstimate(
            scene: selectedScene,
            appetite: selectedAppetite,
            drinkAddon: selectedDrink
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.md) {
                    // 1. 顶部实时单人折算总览卡
                    VStack(spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(selectedScene.title) · 单人实际摄入估算")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(AppColor.secondaryText)
                                Text(selectedScene.subtitle)
                                    .font(.caption2)
                                    .foregroundStyle(AppColor.secondaryText.opacity(0.85))
                            }
                            Spacer()
                            HStack(alignment: .firstTextBaseline, spacing: 2) {
                                Text("\(Int(previewEstimate.consumedCalories.rounded()))")
                                    .font(.system(size: 32, weight: .bold, design: .rounded))
                                    .foregroundStyle(Color.orange)
                                    .contentTransition(.numericText())
                                Text("千卡")
                                    .font(.caption.bold())
                                    .foregroundStyle(AppColor.secondaryText)
                            }
                        }

                        HStack {
                            Text(previewEstimate.calorieRangeDescription)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(Color.orange)
                            Spacer()
                            Text("已按圆桌多人分食折算个人入肚量（共 \(previewEstimate.dishes.count) 类代表菜）")
                                .font(.caption2)
                                .foregroundStyle(AppColor.secondaryText)
                        }
                    }
                    .padding(AppSpacing.md)
                    .background(Color.orange.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))

                    // 2. 选择聚餐/宴席场景
                    VStack(alignment: .leading, spacing: 8) {
                        Text("1. 选择聚餐类型")
                            .font(.subheadline.bold())

                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                            ForEach(FoodBanquetScene.allCases) { scene in
                                let isSelected = selectedScene == scene
                                Button {
                                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                        selectedScene = scene
                                    }
                                    Haptic.selection()
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: scene.icon)
                                            .font(.subheadline.bold())
                                            .foregroundStyle(isSelected ? .white : Color.orange)
                                            .frame(width: 30, height: 30)
                                            .background(
                                                Circle().fill(isSelected ? Color.orange : Color.orange.opacity(0.14))
                                            )

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(scene.title)
                                                .font(.caption.bold())
                                                .foregroundStyle(isSelected ? Color.orange : AppColor.text)
                                                .lineLimit(1)
                                            Text("约 \(scene.dishSpecs.count) 类代表菜")
                                                .font(.system(size: 10))
                                                .foregroundStyle(AppColor.secondaryText)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .padding(10)
                                    .background(
                                        RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                                            .fill(isSelected ? Color.orange.opacity(0.14) : Color(.secondarySystemGroupedBackground))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                                            .stroke(isSelected ? Color.orange : Color.clear, lineWidth: 1.5)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    // 3. 选择个人进食程度
                    VStack(alignment: .leading, spacing: 8) {
                        Text("2. 今天吃了多少？")
                            .font(.subheadline.bold())

                        ForEach(FoodBanquetAppetiteLevel.allCases) { level in
                            let isSelected = selectedAppetite == level
                            Button {
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                    selectedAppetite = level
                                }
                                Haptic.selection()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(level.title)
                                                .font(.subheadline.bold())
                                                .foregroundStyle(isSelected ? AppColor.primary : AppColor.text)
                                            Text(level.shortTitle)
                                                .font(.system(size: 10, weight: .semibold))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Capsule().fill(isSelected ? AppColor.primary.opacity(0.15) : Color(.tertiarySystemFill)))
                                                .foregroundStyle(isSelected ? AppColor.primary : AppColor.secondaryText)
                                        }
                                        Text(level.subtitle)
                                            .font(.caption2)
                                            .foregroundStyle(AppColor.secondaryText)
                                    }
                                    Spacer()
                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(isSelected ? AppColor.primary : Color.secondary.opacity(0.4))
                                }
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                                        .fill(isSelected ? AppColor.primary.opacity(0.1) : Color(.secondarySystemGroupedBackground))
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // 4. 席间饮品/酒水
                    VStack(alignment: .leading, spacing: 8) {
                        Text("3. 席间酒水饮品")
                            .font(.subheadline.bold())

                        HStack(spacing: 8) {
                            ForEach(FoodBanquetDrinkAddon.allCases) { addon in
                                let isSelected = selectedDrink == addon
                                Button {
                                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                        selectedDrink = addon
                                    }
                                    Haptic.selection()
                                } label: {
                                    VStack(spacing: 3) {
                                        Text(addon.title)
                                            .font(.caption.bold())
                                            .foregroundStyle(isSelected ? AppColor.primary : AppColor.text)
                                        Text(addon.subtitle)
                                            .font(.system(size: 10))
                                            .foregroundStyle(AppColor.secondaryText)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 9)
                                    .background(
                                        RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                                            .fill(isSelected ? AppColor.primary.opacity(0.12) : Color(.secondarySystemGroupedBackground))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                                            .stroke(isSelected ? AppColor.primary : Color.clear, lineWidth: 1.2)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    // 5. 折算代表菜品明细预览
                    VStack(alignment: .leading, spacing: 6) {
                        Text("包含的单人代表菜品折算明细")
                            .font(.caption.bold())
                            .foregroundStyle(AppColor.secondaryText)

                        ForEach(previewEstimate.dishes) { dish in
                            HStack {
                                Text(dish.food.name)
                                    .font(.caption)
                                    .foregroundStyle(AppColor.text)
                                Spacer()
                                Text("约 \(Int(dish.currentGrams))g")
                                    .font(.caption2)
                                    .foregroundStyle(AppColor.secondaryText)
                                Text("\(Int(dish.consumedCalories.rounded())) 卡")
                                    .font(.caption.bold().monospacedDigit())
                                    .foregroundStyle(AppColor.primary)
                                    .frame(width: 56, alignment: .trailing)
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 10)
                            .background(Color(.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous))
                        }
                    }

                    // 6. 底部双操作按钮：直接保存 or 填入主页微调
                    VStack(spacing: 8) {
                        Button {
                            let s = selectedScene
                            let a = selectedAppetite
                            let d = selectedDrink
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                onDirectSave(s, a, d)
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                Text("一键完成并保存记录 (\(Int(previewEstimate.consumedCalories.rounded())) 千卡)")
                            }
                            .font(.subheadline.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(AppColor.primary)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
                        }
                        .buttonStyle(.plain)

                        Button {
                            onApplyDraft(selectedScene, selectedAppetite, selectedDrink)
                            dismiss()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "slider.horizontal.3")
                                Text("填入明细继续增删微调")
                            }
                            .font(.caption.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color(.secondarySystemGroupedBackground))
                            .foregroundStyle(AppColor.primary)
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 4)
                }
                .padding(AppSpacing.md)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("宴席 / 聚餐快捷估算")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
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
