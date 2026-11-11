import AssistantCore
import SwiftData
import SwiftUI

// MARK: - 身体档案与体征记录

/// 手动记录身高 / 出生日期 / 体重 / 血压 / 心率 / 血糖 / 体温 / 血氧 / 体脂。
///
/// ## 两条产品口径
///
/// 1. **年龄不落库**：存一个数字，明年不打开 App 也不会自己变。
///    这里存出生日期，年龄由 `BodyMetricCalculator.age` 现算，备份里也只带出生日期。
/// 2. **不做医学分级**：血压/血糖等数值只记录与展示趋势，不给「正常/偏高」标签、
///    不给诊断结论。`BodyMetricField.plausibleRange` 只用于挡明显输错（多打一位），
///    绝不是「健康区间」。异常请就医的出口在页面底部常驻。
///
/// ## 数据纪律
/// - 所有写库走 `saveReportingFailure()`；成功副作用放到 save 之后。
/// - 视图 body 内不写库、不 fetch；档案创建只由用户点「编辑资料」触发。
/// - `@Query` 不加 `fetchLimit`：趋势必须基于**全量**历史，截断会让
///   「最近一次」和趋势方向悄悄说谎（与首页快照的截断谎报同类）。
///   体征记录每天最多几条，量级远小于待办表。
struct BodyMetricsView: View {
    @Environment(\.modelContext) private var context

    @Query(sort: \BodyVitalRecord.measuredAt, order: .reverse)
    private var records: [BodyVitalRecord]

    @Query(sort: \BodyMetricProfile.createdAt, order: .forward)
    private var profiles: [BodyMetricProfile]

    @State private var showingProfileEditor = false
    @State private var showingRecordEditor = false
    @State private var editingRecord: BodyVitalRecord?
    @State private var pendingDeletion: BodyVitalRecord?
    @State private var showingDeleteConfirmation = false

    private var profile: BodyMetricProfile? { profiles.first }

    var body: some View {
        let facts = makeFacts()

        List {
            Section {
                profileCard(facts: facts)
            } header: {
                Text("基础资料")
            }

            Section {
                latestMetricsCard(facts: facts)
            } header: {
                Text("最近一次记录")
            } footer: {
                Text("只展示你手动录入的数值，未录入的项目显示「暂无记录」。数据不会自动从 Apple 健康导入。")
            }

            if !facts.trends.isEmpty {
                Section {
                    ForEach(facts.trends, id: \.field) { trend in
                        trendRow(trend)
                    }
                } header: {
                    Text("趋势")
                } footer: {
                    Text("至少记录 3 次才显示趋势；只描述数值变化，不代表任何健康结论。")
                }
            }

            Section {
                if records.isEmpty {
                    Text("还没有体征记录，点右上角「+」记第一次。")
                        .font(.subheadline)
                        .foregroundStyle(AppColor.secondaryText)
                } else {
                    ForEach(records) { record in
                        Button {
                            editingRecord = record
                            showingRecordEditor = true
                        } label: {
                            recordRow(record)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                pendingDeletion = record
                                showingDeleteConfirmation = true
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
            } header: {
                Text("记录历史（\(records.count)）")
            }

            Section {
                disclaimer
            }
        }
        .themedAppBackground()
        .navigationTitle("身体档案")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editingRecord = nil
                    showingRecordEditor = true
                } label: {
                    Label("新增体征记录", systemImage: "plus")
                }
                .accessibilityLabel("新增体征记录")
                .accessibilityHint("记录体重、血压、心率等数值")
            }
        }
        .sheet(isPresented: $showingProfileEditor) {
            BodyProfileEditor(profile: profile)
        }
        .sheet(isPresented: $showingRecordEditor) {
            BodyVitalRecordEditor(record: editingRecord)
        }
        .alert("删除这条体征记录？", isPresented: $showingDeleteConfirmation) {
            Button("删除", role: .destructive) {
                deletePending()
            }
            Button("取消", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("删除后无法恢复。")
        }
    }

    // MARK: - 事实聚合（一次算完，body 内不重复遍历）

    private struct Facts {
        let samples: [BodyMetricSample]
        let latest: [BodyMetricField: (at: Date, value: Double)]
        let trends: [BodyMetricTrend]
        let bmi: Double?
        let age: Int?
    }

    private func makeFacts() -> Facts {
        let samples = records.map {
            BodyMetricSample(measuredAt: $0.measuredAt, values: $0.metricValues)
        }
        var latest: [BodyMetricField: (at: Date, value: Double)] = [:]
        var trends: [BodyMetricTrend] = []
        for field in BodyMetricField.allCases {
            if let pair = BodyMetricTrendBuilder.latest(field: field, samples: samples) {
                latest[field] = pair
            }
            if let trend = BodyMetricTrendBuilder.build(field: field, samples: samples) {
                trends.append(trend)
            }
        }
        let bmi = BodyMetricCalculator.bmi(
            weightKg: latest[.weightKg]?.value,
            heightCm: profile?.heightCm
        )
        let age = BodyMetricCalculator.age(
            birthDate: profile?.birthDate,
            now: .now,
            calendar: .current
        )
        return Facts(samples: samples, latest: latest, trends: trends, bmi: bmi, age: age)
    }

    // MARK: - 基础资料卡

    private func profileCard(facts: Facts) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack {
                Label("我的资料", systemImage: "person.text.rectangle.fill")
                    .font(.headline)
                    .foregroundStyle(AppColor.text)
                Spacer()
                Button("编辑") { showingProfileEditor = true }
                    .font(.caption.bold())
                    .accessibilityLabel("编辑基础资料")
            }

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: AppSpacing.sm),
                          GridItem(.flexible(), spacing: AppSpacing.sm)],
                spacing: AppSpacing.sm
            ) {
                profileTile(title: "身高", value: profile?.heightCm.map { "\(BodyMetricCalculator.displayHeight($0)) cm" } ?? "未填写")
                profileTile(title: "年龄", value: facts.age.map { "\($0) 岁" } ?? "未填写")
                profileTile(title: "BMI", value: facts.bmi.map { String(format: "%.1f", $0) } ?? "需身高+体重")
                profileTile(title: "性别", value: profile?.biologicalSexRaw ?? "未填写")
            }

            if let note = profile?.note, !note.isEmpty {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(AppColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("BMI 由最近一次体重与档案身高按公式计算；两项缺一就不显示，不会用猜测值补齐。")
                .font(.caption2)
                .foregroundStyle(AppColor.secondaryText)
        }
        .padding(.vertical, AppSpacing.xs)
    }

    private func profileTile(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(AppColor.secondaryText)
            Text(value)
                .font(.subheadline.bold())
                .foregroundStyle(AppColor.text)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(AppSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: AppRadius.medium))
    }

    // MARK: - 最近数值

    private func latestMetricsCard(facts: Facts) -> some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: AppSpacing.sm),
                      GridItem(.flexible(), spacing: AppSpacing.sm)],
            spacing: AppSpacing.sm
        ) {
            ForEach(BodyMetricField.allCases, id: \.self) { field in
                let pair = facts.latest[field]
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Image(systemName: BodyMetricDisplay.icon(field))
                            .font(.caption2)
                            .foregroundStyle(AppColor.primary)
                        Text(BodyMetricDisplay.name(field))
                            .font(.caption2)
                            .foregroundStyle(AppColor.secondaryText)
                    }
                    if let pair {
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text(BodyMetricCalculator.display(pair.value, field: field))
                                .font(.headline.bold())
                                .foregroundStyle(AppColor.text)
                            Text(field.unit)
                                .font(.caption2)
                                .foregroundStyle(AppColor.secondaryText)
                        }
                        Text(pair.at, format: .dateTime.month().day().hour().minute())
                            .font(.caption2)
                            .foregroundStyle(AppColor.secondaryText)
                    } else {
                        Text("暂无记录")
                            .font(.subheadline)
                            .foregroundStyle(AppColor.secondaryText)
                    }
                }
                .padding(AppSpacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: AppRadius.medium))
            }
        }
        .padding(.vertical, AppSpacing.xs)
    }

    // MARK: - 趋势

    private func trendRow(_ trend: BodyMetricTrend) -> some View {
        HStack(spacing: AppSpacing.sm) {
            Image(systemName: trendIcon(trend.direction))
                .font(.caption)
                .foregroundStyle(trendColor(trend.direction))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(BodyMetricDisplay.name(trend.field))
                    .font(.subheadline.bold())
                    .foregroundStyle(AppColor.text)
                Text("\(trend.sampleCount) 次记录 · \(BodyMetricCalculator.display(trend.earliest, field: trend.field)) → \(BodyMetricCalculator.display(trend.latest, field: trend.field)) \(trend.field.unit)")
                    .font(.caption2)
                    .foregroundStyle(AppColor.secondaryText)
            }
            Spacer(minLength: 0)
            Text(trendBadge(trend))
                .font(.caption2.bold())
                .foregroundStyle(trendColor(trend.direction))
        }
        .padding(.vertical, 2)
    }

    private func trendIcon(_ direction: BodyMetricTrendDirection) -> String {
        switch direction {
        case .rising: return "arrow.up.right"
        case .falling: return "arrow.down.right"
        case .steady: return "arrow.right"
        }
    }

    private func trendColor(_ direction: BodyMetricTrendDirection) -> Color {
        switch direction {
        case .rising: return AppColor.warning
        case .falling: return AppColor.info
        case .steady: return AppColor.secondaryText
        }
    }

    private func trendBadge(_ trend: BodyMetricTrend) -> String {
        let delta = BodyMetricCalculator.display(abs(trend.change), field: trend.field)
        switch trend.direction {
        case .rising: return "+\(delta)"
        case .falling: return "−\(delta)"
        case .steady: return "持平"
        }
    }

    // MARK: - 历史行

    private func recordRow(_ record: BodyVitalRecord) -> some View {
        let values = record.metricValues
        let fields = BodyMetricField.allCases.filter { values[$0] != nil }
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(record.measuredAt, format: .dateTime.year().month().day().hour().minute())
                    .font(.caption.bold())
                    .foregroundStyle(AppColor.text)
                Spacer()
                Text("\(fields.count) 项")
                    .font(.caption2)
                    .foregroundStyle(AppColor.secondaryText)
            }
            HStack(spacing: 6) {
                ForEach(Array(fields.prefix(4)), id: \.self) { field in
                    if let value = values[field] {
                        Text("\(BodyMetricDisplay.name(field)) \(BodyMetricCalculator.display(value, field: field))")
                            .font(.caption2)
                            .foregroundStyle(AppColor.secondaryText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(AppColor.softFill(AppColor.primary), in: Capsule())
                    }
                }
                if fields.count > 4 {
                    Text("+\(fields.count - 4)")
                        .font(.caption2)
                        .foregroundStyle(AppColor.secondaryText)
                }
            }
            if let note = record.note, !note.isEmpty {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(AppColor.secondaryText)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - 免责声明

    private var disclaimer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("仅用于个人记录", systemImage: "info.circle.fill")
                .font(.caption.bold())
                .foregroundStyle(AppColor.warning)
            Text("本页只保存你手动录入的数值并展示变化趋势，不提供诊断、不判定指标是否正常，也不构成医疗建议。数值异常或身体不适，请及时咨询医生或前往医疗机构。")
                .font(.caption)
                .foregroundStyle(AppColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, AppSpacing.xs)
    }

    // MARK: - 删除

    private func deletePending() {
        guard let record = pendingDeletion else { return }
        pendingDeletion = nil
        Haptic.warning()
        context.delete(record)
        guard context.saveReportingFailure({ SaveFailureCenter.shared.report($0, action: "删除体征记录") }) else {
            Haptic.error()
            return
        }
        // 成功副作用后置到 save 之后：档案变了，两个指数的缓存必须立刻失效。
        BodyProfileContextProvider.shared.invalidate()
    }
}

// MARK: - 基础资料编辑器

private struct BodyProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    let profile: BodyMetricProfile?

    @State private var heightText: String = ""
    @State private var hasBirthDate: Bool = false
    @State private var birthDate: Date = .now
    @State private var sexRaw: String = ""
    @State private var note: String = ""
    @State private var errorMessage: String?

    private static let sexOptions = ["未填写", "男", "女", "其他"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("身高")
                        Spacer()
                        TextField("未填写", text: $heightText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                        Text("cm")
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("用于计算 BMI。留空表示不记录，不会用默认身高凑数。")
                }

                Section {
                    Toggle("记录出生日期", isOn: $hasBirthDate)
                    if hasBirthDate {
                        DatePicker(
                            "出生日期",
                            selection: $birthDate,
                            in: ...Date.now,
                            displayedComponents: .date
                        )
                    }
                } footer: {
                    Text("存出生日期而不是年龄数字：年龄会随日期自动更新，备份换机后也不会停在导出那天。")
                }

                Section {
                    Picker("生理性别", selection: $sexRaw) {
                        ForEach(Self.sexOptions, id: \.self) { option in
                            Text(option).tag(option)
                        }
                    }
                } footer: {
                    Text("选填。仅作为个人资料保存，不参与任何数值判定。")
                }

                Section("备注") {
                    TextField("如：既往病史、过敏史（选填）", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .navigationTitle("基础资料")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                }
            }
            .alert("无法保存", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("好", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .onAppear(perform: load)
        }
        .presentationDetents([.medium, .large])
    }

    private func load() {
        heightText = profile?.heightCm.map { BodyMetricCalculator.displayHeight($0) } ?? ""
        hasBirthDate = profile?.birthDate != nil
        birthDate = profile?.birthDate ?? .now
        sexRaw = profile?.biologicalSexRaw ?? "未填写"
        note = profile?.note ?? ""
    }

    private func save() {
        let trimmed = heightText.trimmingCharacters(in: .whitespacesAndNewlines)
        let height: Double? = trimmed.isEmpty ? nil : Double(trimmed.replacingOccurrences(of: ",", with: "."))
        if let height, !BodyMetricValidator.isPlausibleHeight(height) {
            errorMessage = "身高需在 \(Int(BodyMetricValidator.heightRange.lowerBound))–\(Int(BodyMetricValidator.heightRange.upperBound)) cm 之间，请检查是否多输了一位。"
            return
        }
        if hasBirthDate, !BodyMetricValidator.isPlausibleBirthDate(birthDate, now: .now) {
            errorMessage = "出生日期不能晚于今天。"
            return
        }

        let target = BodyMetricProfile.ensureProfile(in: context)
        target.heightCm = height
        target.birthDate = hasBirthDate ? birthDate : nil
        target.biologicalSexRaw = (sexRaw == "未填写" || sexRaw.isEmpty) ? nil : sexRaw
        target.note = note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : note
        target.updatedAt = .now

        guard context.saveReportingFailure({ SaveFailureCenter.shared.report($0, action: "保存身体档案") }) else {
            errorMessage = "保存失败，改动已回滚，请稍后重试。"
            return
        }
        BodyProfileContextProvider.shared.invalidate()
        Haptic.success()
        dismiss()
    }
}

// MARK: - 体征记录编辑器

private struct BodyVitalRecordEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    let record: BodyVitalRecord?

    @State private var measuredAt: Date = .now
    @State private var draft: [BodyMetricField: String] = [:]
    @State private var note: String = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("测量时间", selection: $measuredAt, displayedComponents: [.date, .hourAndMinute])
                }

                Section {
                    ForEach(BodyMetricField.allCases, id: \.self) { field in
                        HStack {
                            Image(systemName: BodyMetricDisplay.icon(field))
                                .font(.caption)
                                .foregroundStyle(AppColor.primary)
                                .frame(width: 20)
                            Text(BodyMetricDisplay.name(field))
                            Spacer()
                            TextField(BodyMetricDisplay.hint(field), text: binding(for: field))
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 130)
                        }
                    }
                } header: {
                    Text("数值（留空表示本次没测）")
                } footer: {
                    Text("血压的高压与低压需同时填写，且高压应大于低压。可录入范围只用于挡住明显输错，不代表健康区间。")
                }

                Section("备注") {
                    TextField("如：晨起空腹、运动后（选填）", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .navigationTitle(record == nil ? "新增记录" : "编辑记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                }
            }
            .alert("无法保存", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("好", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .onAppear(perform: load)
        }
        .presentationDetents([.large])
    }

    private func binding(for field: BodyMetricField) -> Binding<String> {
        Binding(
            get: { draft[field] ?? "" },
            set: { draft[field] = $0 }
        )
    }

    private func load() {
        measuredAt = record?.measuredAt ?? .now
        note = record?.note ?? ""
        var initial: [BodyMetricField: String] = [:]
        if let record {
            for (field, value) in record.metricValues {
                initial[field] = BodyMetricCalculator.display(value, field: field)
            }
        }
        draft = initial
    }

    private func save() {
        var values: [BodyMetricField: Double] = [:]
        for field in BodyMetricField.allCases {
            let raw = (draft[field] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { continue }
            guard let parsed = Double(raw.replacingOccurrences(of: ",", with: ".")) else {
                errorMessage = "「\(BodyMetricDisplay.name(field))」不是有效数字，请检查输入。"
                return
            }
            values[field] = parsed
        }

        switch BodyMetricValidator.validate(values) {
        case .valid:
            break
        case .emptyRecord:
            errorMessage = "至少填写一项数值，空白记录会污染趋势与「最近一次」。"
            return
        case .outOfPlausibleRange(let field):
            let range = field.plausibleRange
            errorMessage = "「\(BodyMetricDisplay.name(field))」需在 \(Int(range.lowerBound))–\(Int(range.upperBound)) \(field.unit) 之间，请检查是否输错单位或多打一位。"
            return
        case .incompleteBloodPressure:
            errorMessage = "血压需同时填写收缩压（高压）与舒张压（低压）。"
            return
        case .systolicNotAboveDiastolic:
            errorMessage = "收缩压（高压）需要大于舒张压（低压）。"
            return
        }

        if measuredAt > .now {
            errorMessage = "测量时间不能晚于现在。"
            return
        }

        let target = record ?? BodyVitalRecord()
        if record == nil { context.insert(target) }
        target.measuredAt = measuredAt
        target.apply(values: values)
        target.note = note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : note

        guard context.saveReportingFailure({ SaveFailureCenter.shared.report($0, action: "保存体征记录") }) else {
            errorMessage = "保存失败，改动已回滚，请稍后重试。"
            return
        }
        BodyProfileContextProvider.shared.invalidate()
        Haptic.success()
        dismiss()
    }
}
