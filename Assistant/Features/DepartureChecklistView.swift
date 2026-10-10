import SwiftData
import SwiftUI

/// 随身防丢与出门防遗忘检查清单视图
struct DepartureChecklistView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \DepartureCheckItem.createdAt) private var items: [DepartureCheckItem]

    @State private var selectedScene: DepartureScene? = .commute
    @State private var showingAddSheet = false
    @State private var showingResetAlert = false

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
                // 场景横向滚动切换
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button {
                            selectedScene = nil
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

                        ForEach(DepartureScene.allCases) { scene in
                            let count = items.filter { $0.scene == scene }.count
                            Button {
                                selectedScene = scene
                                Haptic.light()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: scene.icon)
                                    Text("\(scene.rawValue) (\(count))")
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
                    }
                    .onDelete(perform: deleteItems)
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
        }
        .sheet(isPresented: $showingAddSheet) {
            AddDepartureCheckItemSheet(defaultScene: selectedScene ?? .commute)
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
        }
    }

    // MARK: - 辅助组件

    @ViewBuilder
    private func ritualButton(title: String, sub: String, isChecked: Binding<Bool>) -> some View {
        Button {
            isChecked.wrappedValue.toggle()
            Haptic.impact(style: isChecked.wrappedValue ? .heavy : .light)
        } label: {
            VStack(spacing: 4) {
                Text(title)
                    .font(.title3.bold())
                Text(sub)
                    .font(.system(size: 9))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(isChecked.wrappedValue ? Color.indigo : Color(.secondarySystemBackground))
            .foregroundStyle(isChecked.wrappedValue ? .white : .primary)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func resetChecklist() {
        for item in filteredItems {
            item.isChecked = false
        }
        checkedShen = false
        checkedShou = false
        checkedYao = false
        checkedEr = false
        try? context.save()
        Haptic.success()
    }

    private func deleteItems(at offsets: IndexSet) {
        for index in offsets {
            context.delete(filteredItems[index])
        }
        try? context.save()
    }

    private func seedDefaultsIfNeeded() {
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
            Haptic.impact(style: item.isChecked ? .medium : .light)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: item.isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.isChecked ? .green : .secondary)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(item.title)
                            .font(.body)
                            .strikethrough(item.isChecked, color: .secondary)
                            .foregroundStyle(item.isChecked ? .secondary : .primary)

                        if item.isEssential {
                            Text("核心必带")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(.red.opacity(0.15)))
                                .foregroundStyle(.red)
                        }
                    }

                    if let loc = item.storageLocationNote, !loc.isEmpty {
                        HStack(spacing: 3) {
                            Image(systemName: "mappin.and.ellipse")
                                .font(.system(size: 10))
                            Text("存放: \(loc)")
                                .font(.caption2)
                        }
                        .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Text(item.scene.rawValue)
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

/// 添加随身防丢物品弹窗
struct AddDepartureCheckItemSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    var defaultScene: DepartureScene

    @State private var title = ""
    @State private var scene: DepartureScene = .commute
    @State private var isEssential = false
    @State private var storageLocationNote = ""

    let quickPresets = [
        "笔记本电脑", "电脑充电器", "公司门禁卡", "家门钥匙", "折叠雨伞",
        "AirPods 耳机", "运动水杯", "移动电源", "常备药品", "纸巾/湿巾"
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("物品信息") {
                    TextField("物品名称（如：降噪耳机、雨伞、工卡）", text: $title)

                    Picker("适用出行场景", selection: $scene) {
                        ForEach(DepartureScene.allCases) { sc in
                            Label(sc.rawValue, systemImage: sc.icon).tag(sc)
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
                                    Text(preset)
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
            .navigationTitle("添加随身防丢装备")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") {
                        let item = DepartureCheckItem(
                            title: title,
                            scene: scene,
                            isEssential: isEssential,
                            storageLocationNote: storageLocationNote.isEmpty ? nil : storageLocationNote,
                            isChecked: false
                        )
                        context.insert(item)
                        try? context.save()
                        Haptic.success()
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                scene = defaultScene
            }
        }
    }
}
