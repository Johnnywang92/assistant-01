import SwiftData
import SwiftUI

/// 随身防丢与出门防遗忘检查清单视图
struct DepartureChecklistView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \DepartureCheckItem.createdAt) private var items: [DepartureCheckItem]
    @AppStorage("departure_checklist_seeded") private var hasSeededDefaults = false
    @ObservedObject private var contextEngine = SituationalContextEngine.shared
    @ObservedObject private var bgManager = AppBackgroundManager.shared
    @Environment(\.colorScheme) private var colorScheme

    @State private var selectedScene: DepartureScene? = nil
    @State private var showingAddSheet = false
    @State private var editingItem: DepartureCheckItem?
    @State private var pendingDepartureRefresh = false
    @State private var showingResetAlert = false
    @State private var hasInitializedScene = false
    @State private var isAfterWorkSuggestionDismissed = false

    // 出门指差四字状态（身·手·钥·耳）
    @State private var checkedShen = false
    @State private var checkedShou = false
    @State private var checkedYao = false
    @State private var checkedEr = false

    // 当前场景过滤后的条目
    private var filteredItems: [DepartureCheckItem] {
        if let scene = selectedScene {
            return items.filter { $0.scene == scene }
        }
        return items
    }

    // 核心必带未完成数量
    private var uncheckedEssentialCount: Int {
        filteredItems.filter { $0.isEssential && !$0.isChecked }.count
    }

    // 已清点完成百分比
    private var completionProgress: Double {
        guard !filteredItems.isEmpty else { return 0 }
        let checked = filteredItems.filter { $0.isChecked }.count
        return Double(checked) / Double(filteredItems.count)
    }

    var body: some View {
        List {
            // MARK: - 1. 出门指差确认四字诀（指差防错法）
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "hand.point.up.left.fill")
                            .foregroundStyle(.indigo)
                        Text("出门 3 秒指差确认")
                            .font(.subheadline.bold())
                            .foregroundStyle(.indigo)
                        Spacer()
                        Text("口脑手合一 · 防丢四字诀")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 8) {
                        ritualButton(title: "身", sub: "证件/工卡", isChecked: $checkedShen)
                        ritualButton(title: "手", sub: "随身手机", isChecked: $checkedShou)
                        ritualButton(title: "钥", sub: "家门钥匙", isChecked: $checkedYao)
                        ritualButton(title: "耳/伞", sub: "耳机/雨具", isChecked: $checkedEr)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("物理防呆仪式")
            }

            // MARK: - 2. 场景选择与进度看板
            Section {
                // 智能情境感知徽标
                if let badge = contextEngine.departureContextBadge() {
                    HStack(spacing: 6) {
                        Image(systemName: badge.icon)
                            .font(.caption2.bold())
                            .foregroundStyle(badge.color)
                        Text(badge.text)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(badge.color)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(badge.color.opacity(0.12)))
                    .padding(.bottom, 2)
                }

                // 下班智能建议横幅（仅建议与重排，绝不强行自动覆盖用户选择）
                if contextEngine.shouldSuggestAfterWorkSwitch(currentScene: selectedScene) && !isAfterWorkSuggestionDismissed {
                    afterWorkSuggestionBanner
                }

                // 场景横向滚动切换（根据当前时空情景动态重排）
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button {
                            selectedScene = nil
                            contextEngine.saveUserSelectedScene(nil)
                            Haptic.light()
                        } label: {
                            Text("全部 (\(items.count))")
                                .font(.subheadline)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(selectedScene == nil ? Color.blue : Color(.secondarySystemBackground))
                                .foregroundStyle(selectedScene == nil ? .white : .primary)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)

                        ForEach(contextEngine.sortedDepartureScenes()) { scene in
                            let count = items.filter { $0.scene == scene }.count
                            Button {
                                selectedScene = scene
                                contextEngine.saveUserSelectedScene(scene)
                                Haptic.light()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: scene.icon)
                                    Text("\(L10n.tr(scene.rawValue)) (\(count))")
                                }
                                .font(.subheadline)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(selectedScene == scene ? Color.blue : Color(.secondarySystemBackground))
                                .foregroundStyle(selectedScene == scene ? .white : .primary)
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }

                // 进度与警示条
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        if uncheckedEssentialCount > 0 {
                            Label("还有 \(uncheckedEssentialCount) 件核心物品未确认！", systemImage: "exclamationmark.triangle.fill")
                                .font(.subheadline.bold())
                                .foregroundStyle(.red)
                        } else if completionProgress >= 1.0 && !filteredItems.isEmpty {
                            Label("物品全齐，可以安心出发！", systemImage: "checkmark.seal.fill")
                                .font(.subheadline.bold())
                                .foregroundStyle(.green)
                        } else {
                            Text("已确认携带 \(filteredItems.filter { $0.isChecked }.count)/\(filteredItems.count) 件")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(Int(completionProgress * 100))%")
                            .font(.subheadline.monospacedDigit().bold())
                            .foregroundStyle(.secondary)
                    }

                    ProgressView(value: completionProgress)
                        .tint(uncheckedEssentialCount > 0 ? .orange : .green)
                }
                .padding(.vertical, 4)
            } header: {
                Text("出行场景与装备清点")
            }

            // MARK: - 3. 物品清单列表
            Section {
                if filteredItems.isEmpty {
                    ContentUnavailableView(
                        "当前场景暂无装备",
                        systemImage: "bag.badge.plus",
                        description: Text("点击右上角 + 添加专属随身物品，或一键导入常用推荐")
                    )
                    .padding(.vertical, 12)
                } else {
                    ForEach(filteredItems) { item in
                        CheckItemRow(item: item)
                            .contextMenu {
                                Button {
                                    editingItem = item
                                } label: {
                                    Label("编辑", systemImage: "pencil")
                                }
                                Button(role: .destructive) {
                                    delete(items: [item])
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                    }
                    .onDelete { offsets in
                        delete(items: offsets.map { filteredItems[$0] })
                    }
                }
            } header: {
                HStack {
                    Text("随身装备清单")
                    Spacer()
                    if !filteredItems.isEmpty {
                        Button("重置勾选") {
                            showingResetAlert = true
                        }
                        .font(.caption)
                    }
                }
            }

            // MARK: - 4. 防丢核心习惯提示
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label("玄关发射台原则", systemImage: "tray.full.fill")
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)
                    Text("回家进门第一步，将钥匙、工卡、耳机等统一放入玄关托盘。不在床上、沙发上中途停泊，杜绝随手乱放。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider().padding(.vertical, 2)

                    Label("离席回头看 3 秒", systemImage: "eye.fill")
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)
                    Text("在出租车、餐厅、会议室起身时，强制停留 3 秒钟检查座位与桌面，可减少 80% 的物品遗落。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } header: {
                Text("防丢习惯心法")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(bgManager.isCustomBackgroundActive ? .hidden : .automatic)
        .themedAppBackground()
        .themedRow()
        .navigationTitle("出门防遗忘清单")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                // 把当前清点项推上灵动岛与 Apple Watch 智能叠放，抬腕逐项确认
                Button {
                    LiveActivityService.endDepartureActivities()
                    let sceneName = selectedScene.map { $0.displayName } ?? "全部物品"
                    if LiveActivityService.startDepartureChecklist(
                        sceneName: sceneName,
                        items: filteredItems
                    ) {
                        Haptic.success()
                    } else {
                        Haptic.warning()
                    }
                } label: {
                    Image(systemName: "platter.filled.top.iphone")
                }
                .accessibilityLabel("把出门清点推上灵动岛")
            }
        }
        .sheet(isPresented: $showingAddSheet, onDismiss: refreshDepartureActivityAfterEdit) {
            AddDepartureCheckItemSheet(defaultScene: selectedScene ?? .commute, onChanged: {
                pendingDepartureRefresh = true
            })
        }
        .sheet(item: $editingItem, onDismiss: refreshDepartureActivityAfterEdit) { item in
            AddDepartureCheckItemSheet(defaultScene: item.scene, editing: item, onChanged: {
                pendingDepartureRefresh = true
            })
        }
        .alert("重新出发", isPresented: $showingResetAlert) {
            Button("确认重置", role: .destructive) {
                resetChecklist()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将把当前清单所有物品恢复为未确认状态，方便开始下一次出发检查。")
        }
        .onAppear {
            seedDefaultsIfNeeded()
            if !hasInitializedScene {
                selectedScene = contextEngine.effectiveDepartureScene()
                hasInitializedScene = true
            }
        }
    }

    // MARK: - 辅助组件

    // 下班时段智能建议横幅（仅建议与重排，绝不强行覆盖用户选择）
    @ViewBuilder
    private var afterWorkSuggestionBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "moon.stars.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(.purple)
                Text("下班时段出行建议")
                    .font(.caption.bold())
                    .foregroundStyle(.purple)
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                        isAfterWorkSuggestionDismissed = true
                    }
                    Haptic.light()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Text("已到 \(contextEngine.offWorkTimeText) 下班时间，当前仍保留「工作通勤」。选项已按晚间出行概率重排，今晚若有健身或聚餐休闲安排，可一键切换：")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        selectedScene = .workout
                        contextEngine.saveUserSelectedScene(.workout)
                    }
                    Haptic.light()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "figure.run")
                        Text("切至运动健身")
                    }
                    .font(.caption2.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.orange.opacity(0.18)))
                    .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)

                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        selectedScene = .casual
                        contextEngine.saveUserSelectedScene(.casual)
                    }
                    Haptic.light()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "bag.fill")
                        Text("切至日常轻装")
                    }
                    .font(.caption2.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.green.opacity(0.18)))
                    .foregroundStyle(.green)
                }
                .buttonStyle(.plain)

                Spacer()
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.purple.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.purple.opacity(0.2), lineWidth: 1)
                )
        )
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func ritualButton(title: String, sub: String, isChecked: Binding<Bool>) -> some View {
        Button {
            isChecked.wrappedValue.toggle()
            if isChecked.wrappedValue {
                Haptic.heavy()
            } else {
                Haptic.light()
            }
        } label: {
            VStack(spacing: 4) {
                Text(L10n.tr(title))
                    .font(.title3.bold())
                Text(L10n.tr(sub))
                    .font(.caption2)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .background(
                isChecked.wrappedValue
                    ? Color.indigo
                    : (bgManager.isCustomBackgroundActive ? Color(.secondarySystemBackground).opacity(0.68) : Color(.secondarySystemBackground))
            )
            .foregroundStyle(isChecked.wrappedValue ? .white : .primary)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func resetChecklist() {
        for item in filteredItems {
            guard item.isChecked else { continue }
            item.isChecked = false
            // 同步到锁屏/灵动岛/Mac 镜像的实时活动，否则卡片继续显示全部已勾
            DepartureActivityHelper.setChecked(itemID: item.id, isChecked: false)
        }
        checkedShen = false
        checkedShou = false
        checkedYao = false
        checkedEr = false
        try? context.save()
        Haptic.success()
    }

    private func delete(items: [DepartureCheckItem]) {
        guard !items.isEmpty else { return }
        // 删除后 @Query 未必立刻刷新，先按当前可见列表算出重推给卡片用的剩余项
        let deletedIDs = Set(items.map(\.id))
        let remaining = filteredItems.filter { !deletedIDs.contains($0.id) }
        for item in items {
            context.delete(item)
        }
        try? context.save()
        refreshDepartureActivity(with: remaining)
    }

    /// 弹窗关闭后 @Query 才稳定包含新增项，所以重推时机放在 onDismiss，且只在本次真的改过时执行
    private func refreshDepartureActivityAfterEdit() {
        guard pendingDepartureRefresh else { return }
        pendingDepartureRefresh = false
        refreshDepartureActivity(with: filteredItems)
    }

    /// 清点卡的物品与必带标记固定在上岛那一刻的 attributes 里，改不了；
    /// 增删改后按当前视图重推一次，否则锁屏/手表上会留下已删除物品的幽灵行或过期名称。
    private func refreshDepartureActivity(with items: [DepartureCheckItem]) {
        guard LiveActivityService.hasDepartureActivity else { return }
        LiveActivityService.endDepartureActivities()
        let sceneName = selectedScene.map { $0.displayName } ?? "全部物品"
        if !LiveActivityService.startDepartureChecklist(sceneName: sceneName, items: items) {
            // 剩余项已全部勾完（或清单已空）时不再重推，顺带摘掉伴随通知，不留点不到的控制入口
            LiveActivityControlNotifications.dismissDeparture()
        }
    }

    private func seedDefaultsIfNeeded() {
        // 只铺一次：用户把清单删光后重进，不该把整份默认清单再塞回来
        guard !hasSeededDefaults else { return }
        hasSeededDefaults = true
        guard items.isEmpty else { return }
        for seed in DepartureChecklistDefaults.seeds {
            let item = DepartureCheckItem(
                title: seed.title,
                scene: seed.scene,
                isEssential: seed.isEssential,
                storageLocationNote: seed.location,
                isChecked: false
            )
            context.insert(item)
        }
        try? context.save()
    }
}

/// 清单单项展示行
struct CheckItemRow: View {
    @Bindable var item: DepartureCheckItem

    var body: some View {
        Button {
            item.isChecked.toggle()
            // App 内勾选同步到锁屏/灵动岛/Mac 镜像的实时活动；最后一项勾完自动收卡
            DepartureActivityHelper.setChecked(itemID: item.id, isChecked: item.isChecked)
            if item.isChecked {
                Haptic.medium()
            } else {
                Haptic.light()
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: item.isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.isChecked ? .green : .secondary)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(L10n.tr(item.title))
                            .font(.body)
                            .strikethrough(item.isChecked, color: .secondary)
                            .foregroundStyle(item.isChecked ? .secondary : .primary)

                        if item.isEssential {
                            Text("核心必带")
                                .font(.caption2.bold())
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(AppColor.softFill(AppColor.danger, opacity: 0.15)))
                                .foregroundStyle(AppColor.danger)
                        }
                    }

                    if let loc = item.storageLocationNote, !loc.isEmpty {
                        HStack(spacing: 3) {
                            Image(systemName: "mappin.and.ellipse")
                                .font(.caption2)
                            Text("存放: \(loc)")
                                .font(.caption2)
                        }
                        .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Text(L10n.tr(item.scene.rawValue))
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.secondary.opacity(0.12)))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 添加 / 编辑随身防丢物品弹窗
struct AddDepartureCheckItemSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    var defaultScene: DepartureScene
    var editing: DepartureCheckItem?
    var onChanged: () -> Void = {}

    @State private var title = ""
    @State private var scene: DepartureScene = .commute
    @State private var isEssential = false
    @State private var storageLocationNote = ""

    let quickPresets = [
        "笔记本电脑", "电脑充电器", "公司门禁卡", "家门钥匙", "折叠雨伞",
        "AirPods 耳机", "运动水杯", "移动电源", "常备药品", "纸巾/湿巾"
    ]

    private var isEditing: Bool { editing != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("物品信息") {
                    TextField("物品名称（如：降噪耳机、雨伞、工卡）", text: $title)

                    Picker("适用出行场景", selection: $scene) {
                        ForEach(DepartureScene.allCases) { sc in
                            Label(L10n.tr(sc.rawValue), systemImage: sc.icon).tag(sc)
                        }
                    }

                    Toggle("设为「核心必带」（漏带严重点）", isOn: $isEssential)
                }

                Section("存放与防丢备忘") {
                    TextField("平时习惯放在哪（如：玄关托盘、双肩包侧袋）", text: $storageLocationNote)
                }

                Section("快捷常用预设") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(quickPresets, id: \.self) { preset in
                                Button {
                                    title = preset
                                    Haptic.light()
                                } label: {
                                    Text(L10n.tr(preset))
                                        .font(.caption)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(Color(.secondarySystemBackground))
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .navigationTitle(isEditing ? "编辑随身防丢装备" : "添加随身防丢装备")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "保存" : "添加") {
                        save()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                scene = defaultScene
                if let editing {
                    title = editing.title
                    scene = editing.scene
                    isEssential = editing.isEssential
                    storageLocationNote = editing.storageLocationNote ?? ""
                }
            }
        }
    }

    private func save() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }
        let trimmedNote = storageLocationNote.trimmingCharacters(in: .whitespacesAndNewlines)
        if let editing {
            editing.title = trimmedTitle
            editing.scene = scene
            editing.isEssential = isEssential
            editing.storageLocationNote = trimmedNote.isEmpty ? nil : trimmedNote
        } else {
            context.insert(DepartureCheckItem(
                title: trimmedTitle,
                scene: scene,
                isEssential: isEssential,
                storageLocationNote: trimmedNote.isEmpty ? nil : trimmedNote,
                isChecked: false
            ))
        }
        try? context.save()
        Haptic.success()
        onChanged()
        dismiss()
    }
}
