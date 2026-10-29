import AssistantCore
import SwiftUI
import UIKit

/// 健康双指数社交分享卡片 (Health & Dual-Index Share Card)
///
/// 专为小红书、朋友圈、即刻等社交媒体设计的竖版健康日报卡片，
/// 包含双指数（活力 + 愉悦）、压力与 HRV、核心生理指标、运动消耗、饮水与饮食、打卡协同，
/// 并按规范展示 App 图标与 JohnnyBoyStudio 品牌标识。
public struct HealthShareCardView: View {
    public let date: Date
    public let snapshot: HealthDaySnapshot?
    public let vitality: VitalityEvaluation?
    public let pleasure: PleasureIndexEvaluation?
    public let todayFoodCalories: Double?
    public let todayWaterML: Double?
    public let goals: [HealthGoal]

    public init(
        date: Date = .now,
        snapshot: HealthDaySnapshot?,
        vitality: VitalityEvaluation?,
        pleasure: PleasureIndexEvaluation? = nil,
        todayFoodCalories: Double? = nil,
        todayWaterML: Double? = nil,
        goals: [HealthGoal] = HealthGoal.defaults
    ) {
        self.date = date
        self.snapshot = snapshot
        self.vitality = vitality
        self.pleasure = pleasure
        self.todayFoodCalories = todayFoodCalories
        self.todayWaterML = todayWaterML
        self.goals = goals
    }

    private var steps: Double? { snapshot?.stepCount }
    private var sleep: Double? { snapshot?.sleepHours }
    private var heartRate: Double? { snapshot?.heartRate }
    private var restingHeartRate: Double? { snapshot?.restingHeartRate }
    private var hrv: Double? { snapshot?.heartRateVariability }
    private var bloodOxygen: Double? { snapshot?.bloodOxygen }
    private var totalBurned: Double? { snapshot?.totalEnergyBurned }

    // MARK: - 浅色清爽系配色
    // 底：薄荷白 → 淡紫白（呼应活力绿 / 愉悦紫双指数色相）；文字：深墨。
    // 双指数色相比页内加深一档——亮绿/亮紫在浅底上做文字对比度不够。
    private let vitalityTint = Color(red: 0.05, green: 0.55, blue: 0.38)
    private let pleasureTint = Color(red: 0.40, green: 0.33, blue: 0.86)
    private let ink = Color(red: 0.10, green: 0.15, blue: 0.14)
    private let warnTint = Color(red: 0.85, green: 0.42, blue: 0.10)
    private let cardFill = Color.white

    private var hasAnyVital: Bool {
        restingHeartRate != nil || heartRate != nil || bloodOxygen != nil
    }

    /// 步数副标：优先目标进度；无目标时才降级为运动次数说明
    private var stepBrief: String {
        guard let steps else { return "暂无数据" }
        if let target = goalTarget(.stepCount) {
            return "目标 \(Int(target)) 步 · \(Int((min(steps / target, 1) * 100).rounded()))%"
        }
        if let count = snapshot?.workoutSummary?.count, count > 0 {
            return "健身 \(count) 次"
        }
        return "日常行走"
    }

    /// 睡眠副标：无数据不许判成「睡得少」（旧版 `(sleep ?? 0) >= 7` 把没数据当 0 小时）
    private var sleepBrief: String {
        guard let sleep else { return "暂无数据" }
        if let target = goalTarget(.sleep) {
            return sleep >= target
                ? "已达 \(Int(target)) 小时目标"
                : String(format: "距 %.1f 小时目标还差 %.1f", target, target - sleep)
        }
        return sleep >= 7 ? "睡眠充足恢复好" : "建议稍早作息"
    }

    /// 饮水副标：目标进度
    private var waterBrief: String {
        guard let todayWaterML else { return "暂无数据" }
        if let target = goalTarget(.dietaryWater) {
            return "目标 \(Int(target)) ml · \(Int((min(todayWaterML / target, 1) * 100).rounded()))%"
        }
        return "有效补水折算"
    }

    private func goalTarget(_ kind: HealthMetricKind) -> Double? {
        goals.first { $0.kind == kind && $0.isValid }?.target
    }

    private var energyBalanceBrief: String {
        guard let net = vitality?.energyBalance.netDifference else {
            return "静息与活动消耗"
        }
        let netInt = Int(abs(net).rounded())
        if abs(net) <= 250 {
            return "能量收支平衡"
        } else if net > 250 {
            return "适度盈余 +\(netInt) kcal"
        } else {
            return "热量赤字 -\(netInt) kcal"
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 1. 顶部 Header（两行极简：短眉标 + 标题与紧凑日期同行）
            VStack(alignment: .leading, spacing: 4) {
                Text("DAILY HEALTH")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(vitalityTint)
                    .tracking(1.2)

                HStack(alignment: .firstTextBaseline) {
                    Text("今日健康双指数签")
                        .font(.system(size: 20, weight: .heavy, design: .rounded))
                        .foregroundStyle(ink)
                    Spacer(minLength: 8)
                    Text(Self.compactDateText(date))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(ink.opacity(0.5))
                }
            }

            // 2. 双指数分数卡（各带指数名称与图标，一眼可辨是哪个指数）
            HStack(spacing: 10) {
                if let vitality {
                    indexScoreCard(
                        name: "活力指数",
                        icon: "bolt.heart.fill",
                        score: vitality.score,
                        levelText: vitality.level.rawValue,
                        tint: vitalityTint
                    )
                }
                if let pleasure {
                    indexScoreCard(
                        name: "愉悦指数",
                        icon: "heart.text.square.fill",
                        score: pleasure.pleasureScore,
                        levelText: pleasure.state.rawValue,
                        tint: pleasureTint
                    )
                }
            }

            // 3. 双指数简评横幅（活力总结 + 愉悦状态；图标与分数卡同款）
            VStack(alignment: .leading, spacing: 6) {
                if let summary = vitality?.summary {
                    HStack(spacing: 8) {
                        Image(systemName: "bolt.heart.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(vitalityTint)
                        Text(summary)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(ink.opacity(0.85))
                            .lineLimit(2)
                    }
                }
                if let pleasure {
                    HStack(spacing: 8) {
                        Image(systemName: "heart.text.square.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(pleasureTint)
                        Text(pleasure.summary)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(ink.opacity(0.85))
                            .lineLimit(2)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardFill)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                    .strokeBorder(ink.opacity(0.06), lineWidth: 0.8)
            )

            // 4. 身心状态条：压力负荷 · HRV · 自主神经（愉悦指数的关键构成）
            if let pleasure {
                HStack(spacing: 6) {
                    statusChip(
                        text: "压力 \(pleasure.stressScore) · \(pleasure.stressLevel.rawValue)",
                        tint: pleasure.stressScore <= 50 ? vitalityTint : warnTint
                    )
                    if let hrv {
                        statusChip(text: "HRV \(Int(hrv.rounded()))ms", tint: pleasureTint)
                    }
                    statusChip(text: pleasure.autonomicBalance.rawValue, tint: pleasureTint)
                }
            }

            // 5. 核心指标网格 (2x3)：步数 / 耗能 / 睡眠 / 体征 / 饮水 / 饮食
            // 副标纪律：无数据一律「暂无数据」，不得渲染成「正常/平稳/建议」这类假结论。
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                // 步数与健身
                statTile(
                    icon: "figure.walk",
                    tint: vitalityTint,
                    title: "今日步数",
                    value: steps.map { "\(Int($0.rounded())) 步" } ?? "待同步",
                    subtitle: stepBrief
                )

                // 消耗总能
                statTile(
                    icon: "flame.fill",
                    tint: warnTint,
                    title: "身体总耗能",
                    value: totalBurned.map { "\(Int($0.rounded())) kcal" } ?? "待计算",
                    subtitle: energyBalanceBrief
                )

                // 睡眠恢复
                statTile(
                    icon: "bed.double.fill",
                    tint: Color(red: 0.35, green: 0.40, blue: 0.85),
                    title: "昨夜睡眠",
                    value: sleep.map { String(format: "%.1f 小时", $0) } ?? "待记录",
                    subtitle: sleepBrief
                )

                // 核心体征
                statTile(
                    icon: "heart.fill",
                    tint: Color(red: 0.85, green: 0.28, blue: 0.30),
                    title: "静息心率 / 血氧",
                    value: formatVitals(),
                    subtitle: hasAnyVital ? "体征已同步" : "暂无数据"
                )

                // 今日饮水
                statTile(
                    icon: "drop.fill",
                    tint: Color(red: 0.12, green: 0.52, blue: 0.72),
                    title: "今日饮水",
                    value: todayWaterML.map { "\(Int($0.rounded())) ml" } ?? "待记录",
                    subtitle: waterBrief
                )

                // 今日饮食摄入（琥珀色：纯黄在白底上不可读）
                statTile(
                    icon: "fork.knife",
                    tint: Color(red: 0.72, green: 0.48, blue: 0.08),
                    title: "饮食摄入",
                    value: todayFoodCalories.map { "\(Int($0.rounded())) kcal" } ?? "待记录",
                    subtitle: todayFoodCalories != nil ? "今日累计" : "暂无数据"
                )
            }

            // 6. 打卡目标协同清单
            VStack(alignment: .leading, spacing: 6) {
                Text("目标协同")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(ink.opacity(0.5))
                    .tracking(0.5)

                HStack(spacing: 8) {
                    ForEach(HealthRelatedTodoType.allCases, id: \.self) { todoType in
                        goalChip(todoType: todoType)
                    }
                }
            }

            // 7. 底部品牌与专属网站标识
            VStack(spacing: 12) {
                Rectangle()
                    .fill(ink.opacity(0.1))
                    .frame(height: 0.8)

                HStack(alignment: .center, spacing: 10) {
                    Image("AssistantAppIcon")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 34, height: 34)
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous))
                        .shadow(color: Color.black.opacity(0.12), radius: 3, y: 1)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("小助 · 个人智能生活助理")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)

                        Text("记所想，助所行")
                            .font(.system(size: 9))
                            .foregroundStyle(ink.opacity(0.55))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    // 专属网站标识胶囊
                    HStack(spacing: 4) {
                        Image(systemName: "globe")
                            .font(.system(size: 9))
                        Text("JohnnyBoyStudio")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4.5)
                    .background(vitalityTint.opacity(0.12))
                    .foregroundStyle(vitalityTint)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule().strokeBorder(vitalityTint.opacity(0.3), lineWidth: 0.6)
                    )
                    .fixedSize(horizontal: true, vertical: true)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: 350)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.93, green: 0.97, blue: 0.95), // 薄荷白（活力绿相）
                    Color(red: 0.98, green: 0.985, blue: 0.98),
                    Color(red: 0.95, green: 0.94, blue: 0.99) // 淡紫白（愉悦紫相）
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.hero, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.hero, style: .continuous)
                .strokeBorder(vitalityTint.opacity(0.22), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 16, y: 6)
    }

    /// 双指数分数卡（两行极简：名称行 + 分数与状态同行）
    private func indexScoreCard(name: String, icon: String, score: Int, levelText: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            // 第一行：指数名称（图标 + 名称），一眼可辨是哪个指数
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint)
                Text(name)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(tint)
            }

            // 第二行：分数 + 状态合并一行，不再单独占行
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(score)")
                    .font(.system(size: 24, weight: .black, design: .rounded))
                    .foregroundStyle(tint)
                Text("/100 · \(levelText)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(ink.opacity(0.55))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                .strokeBorder(tint.opacity(0.3), lineWidth: 0.8)
        )
    }

    /// 身心状态小胶囊（压力 / HRV / 自主神经）
    private func statusChip(text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.12))
            .clipShape(Capsule())
    }

    private func statTile(icon: String, tint: Color, title: String, value: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(ink.opacity(0.55))
            }
            Text(value)
                .font(.system(size: 17, weight: .heavy, design: .rounded))
                .foregroundStyle(ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text(subtitle)
                .font(.system(size: 9.5))
                .foregroundStyle(ink.opacity(0.45))
                .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardFill)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                .strokeBorder(ink.opacity(0.06), lineWidth: 0.8)
        )
    }

    /// 紧凑日期：「10月23日 周五」。卡片标题已写「今日」，年份是噪声，去掉。
    private static let compactDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 EEE"
        return f
    }()

    private static func compactDateText(_ date: Date) -> String {
        compactDateFormatter.string(from: date)
    }

    private func formatVitals() -> String {
        var parts: [String] = []
        // 静息心率优先（自律神经相关，与愉悦指数语义更近），无则回退瞬时心率
        if let rhr = restingHeartRate {
            parts.append("\(Int(rhr.rounded())) bpm")
        } else if let hr = heartRate {
            parts.append("\(Int(hr.rounded())) bpm")
        }
        if let ox = bloodOxygen {
            let pct = ox > 1.0 ? ox : ox * 100.0
            parts.append("\(Int(pct.rounded()))%")
        }
        // 无任何体征时不许写「指标正常」——没读到 ≠ 正常
        return parts.isEmpty ? "待同步" : parts.joined(separator: " · ")
    }

    private func goalChip(todoType: HealthRelatedTodoType) -> some View {
        let isAchieved: Bool = {
            guard let snapshot else { return false }
            return HealthMetrics.progress(for: todoType, snapshot: snapshot, goals: goals)?.isAchieved ?? false
        }()

        let title: String = switch todoType {
        case .exercise: "运动"
        case .hydration: "补水"
        case .sleep: "作息"
        }

        return HStack(spacing: 4) {
            Image(systemName: isAchieved ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 10))
                .foregroundStyle(isAchieved ? vitalityTint : ink.opacity(0.25))
            Text("\(title)\(isAchieved ? "达标" : "进行中")")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isAchieved ? vitalityTint : ink.opacity(0.55))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(isAchieved ? vitalityTint.opacity(0.12) : ink.opacity(0.05))
        .clipShape(Capsule())
    }
}

/// 健康数据社交分享弹窗
public struct HealthShareSheet: View {
    @Environment(\.dismiss) private var dismiss
    public let snapshot: HealthDaySnapshot?
    public let vitality: VitalityEvaluation?
    public let pleasure: PleasureIndexEvaluation?
    public let todayFoodCalories: Double?
    public let todayWaterML: Double?
    public let goals: [HealthGoal]

    @State private var toastMessage: String?
    @State private var showSystemShareSheet: Bool = false
    @State private var renderedImage: UIImage?

    public init(
        snapshot: HealthDaySnapshot?,
        vitality: VitalityEvaluation?,
        pleasure: PleasureIndexEvaluation? = nil,
        todayFoodCalories: Double? = nil,
        todayWaterML: Double? = nil,
        goals: [HealthGoal] = HealthGoal.defaults
    ) {
        self.snapshot = snapshot
        self.vitality = vitality
        self.pleasure = pleasure
        self.todayFoodCalories = todayFoodCalories
        self.todayWaterML = todayWaterML
        self.goals = goals
    }

    private var cardView: HealthShareCardView {
        HealthShareCardView(
            snapshot: snapshot,
            vitality: vitality,
            pleasure: pleasure,
            todayFoodCalories: todayFoodCalories,
            todayWaterML: todayWaterML,
            goals: goals
        )
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    cardView
                        .padding(.top, 10)

                    // 导出操作按钮组
                    VStack(spacing: 12) {
                        Button {
                            saveToPhotos()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "square.and.arrow.down.fill")
                                Text("保存到相册")
                            }
                            .font(.headline)
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color(red: 0.2, green: 0.85, blue: 0.55))
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.banner, style: .continuous))
                        }

                        Button {
                            shareViaSystem()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "photo.on.rectangle.angled")
                                Text("分享到社交平台")
                            }
                            .font(.subheadline.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color(.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.banner, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 24)
                }
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("分享健康双指数签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .overlay(alignment: .bottom) {
                if let msg = toastMessage {
                    Text(msg)
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.85), in: Capsule())
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: toastMessage)
        }
        .sheet(isPresented: $showSystemShareSheet, onDismiss: { renderedImage = nil }) {
            if let renderedImage {
                ShareActivityView(activityItems: [renderedImage])
            }
        }
    }

    @MainActor
    private func renderImage() -> UIImage? {
        ShareCardActions.render(cardView)
    }

    private func saveToPhotos() {
        guard let image = renderImage() else {
            showToast(ShareCardActions.renderFailureMessage)
            return
        }
        Task { @MainActor in
            showToast(await ShareCardActions.saveToPhotos(image, successMessage: "已保存高清健康卡片至相册 📸"))
        }
    }

    private func shareViaSystem() {
        guard let image = renderImage() else {
            showToast(ShareCardActions.renderFailureMessage)
            return
        }

        renderedImage = image
        showSystemShareSheet = true
    }

    private func showToast(_ msg: String) {
        toastMessage = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if toastMessage == msg { toastMessage = nil }
        }
    }
}
