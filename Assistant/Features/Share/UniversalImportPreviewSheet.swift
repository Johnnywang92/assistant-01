import AssistantCore
import SwiftData
import SwiftUI

/// 统一离线分享导入与确认交互面板
///
/// 支持待办清单、AA 账单分摊、快递代取、心情名片四种模式的原生预览与一键落库
struct UniversalImportPreviewSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let envelope: UniversalShareEnvelope
    let onCompletion: (() -> Void)?

    // 待办模式下的条目选中状态
    @State private var selectedTodoIndices: Set<Int> = []
    @State private var isProcessing: Bool = false
    @State private var showSuccessBanner: Bool = false

    init(envelope: UniversalShareEnvelope, onCompletion: (() -> Void)? = nil) {
        self.envelope = envelope
        self.onCompletion = onCompletion
        if let todos = envelope.todos {
            self._selectedTodoIndices = State(initialValue: Set(todos.indices))
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 顶部发送方身份标头
                headerView
                    .padding(.horizontal)
                    .padding(.top, 16)

                // 中间业务内容预览卡片
                ScrollView {
                    VStack(spacing: 16) {
                        switch envelope.type {
                        case .todos:
                            todosContent
                        case .expenseAA:
                            expenseAAContent
                        case .parcelTransfer:
                            parcelContent
                        case .emotionPulse:
                            emotionContent
                        case .storageItem:
                            storageContent
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 16)
                }

                // 底部确认操作栏
                bottomActionBar
                    .padding(.horizontal)
                    .padding(.vertical, 12)
                    .background(Color(.systemBackground).shadow(color: .black.opacity(0.06), radius: 6, y: -2))
            }
            .navigationTitle("面对面离线互联")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                        onCompletion?()
                    }
                }
            }
        }
    }

    // MARK: - 顶部标头

    private var headerView: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 50, height: 50)

                Image(systemName: envelope.type.systemIcon)
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(envelope.type.displayName)
                        .font(.headline.bold())
                        .foregroundStyle(.primary)

                    Text("· 离线直传")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(.systemGray6))
                        .clipShape(Capsule())
                }

                Text("来自 \(envelope.senderName) · \(envelope.createdAt.formatted(date: .omitted, time: .shortened))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.banner, style: .continuous))
    }

    // MARK: - 1. 待办清单内容

    @ViewBuilder
    private var todosContent: some View {
        if let items = envelope.todos, !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("共收到 \(items.count) 项待办，请勾选需要导入的内容：")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        if selectedTodoIndices.count == items.count {
                            selectedTodoIndices.removeAll()
                        } else {
                            selectedTodoIndices = Set(items.indices)
                        }
                    } label: {
                        Text(selectedTodoIndices.count == items.count ? "取消全选" : "全选")
                            .font(.caption.bold())
                    }
                }

                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(spacing: 12) {
                        Button {
                            if selectedTodoIndices.contains(index) {
                                selectedTodoIndices.remove(index)
                            } else {
                                selectedTodoIndices.insert(index)
                            }
                        } label: {
                            Image(systemName: selectedTodoIndices.contains(index) ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(selectedTodoIndices.contains(index) ? Color.accentColor : Color(.systemGray4))
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(item.t)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.primary)

                                if let type = TodoType(rawValue: item.ty) {
                                    Text(type.displayName)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1.5)
                                        .background(Color(.systemGray5))
                                        .clipShape(Capsule())
                                }
                            }

                            if let loc = item.loc, !loc.isEmpty {
                                Label(loc, systemImage: "mappin.circle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            if let pc = item.pc, !pc.isEmpty {
                                Text("取件码: \(pc)")
                                    .font(.caption.monospaced().bold())
                                    .foregroundStyle(Color.accentColor)
                            }
                        }

                        Spacer()
                    }
                    .padding()
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
                }
            }
        } else {
            Text("未检测到待办内容")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 2. AA 账单内容

    @ViewBuilder
    private var expenseAAContent: some View {
        if let aa = envelope.expenseAA {
            VStack(spacing: 18) {
                // 金额核心卡片
                VStack(spacing: 12) {
                    Text(aa.title)
                        .font(.headline)
                        .foregroundStyle(.secondary)

                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("¥")
                            .font(.title2.bold())
                            .foregroundStyle(Color.accentColor)
                        Text(String(format: "%.2f", aa.splitAmount))
                            .font(.system(size: 44, weight: .black, design: .rounded))
                            .foregroundStyle(.primary)
                    }

                    Text("你的分摊应付金额")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))

                // 明细信息表
                VStack(spacing: 12) {
                    detailRow(title: "账单原总额", value: String(format: "¥%.2f", aa.totalAmount))
                    Divider()
                    detailRow(title: "平摊人数", value: "\(aa.splitCount) 人")
                    Divider()
                    detailRow(title: "消费类别", value: aa.categoryRaw)
                    if let note = aa.note, !note.isEmpty {
                        Divider()
                        detailRow(title: "备注附言", value: note)
                    }
                    Divider()
                    detailRow(title: "消费时间", value: aa.date.formatted(date: .abbreviated, time: .shortened))
                }
                .padding()
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
            }
        }
    }

    // MARK: - 3. 快递代取转交内容

    @ViewBuilder
    private var parcelContent: some View {
        if let p = envelope.parcel {
            VStack(spacing: 16) {
                // 取件码核心大卡片
                VStack(spacing: 10) {
                    Text("待取包裹")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text(p.title)
                        .font(.title3.bold())
                        .foregroundStyle(.primary)

                    VStack(spacing: 4) {
                        Text(p.pickupCode)
                            .font(.system(size: 38, weight: .black, design: .monospaced))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                            .background(Color.accentColor.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))

                        Text("取件码已核验 · 导入后直登灵动岛与小组件")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))

                // 驿站及附言
                VStack(spacing: 12) {
                    if let station = p.station, !station.isEmpty {
                        detailRow(title: "自提驿站", value: station)
                    }
                    if let courier = p.courier, !courier.isEmpty {
                        Divider()
                        detailRow(title: "快递承运", value: courier)
                    }
                    if let note = p.urgentNote, !note.isEmpty {
                        Divider()
                        detailRow(title: "代取附言", value: note)
                    }
                }
                .padding()
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
            }
        }
    }

    // MARK: - 4. 情绪名片共振内容

    @ViewBuilder
    private var emotionContent: some View {
        if let emo = envelope.emotion {
            VStack(spacing: 16) {
                VStack(spacing: 12) {
                    Text("今日情绪状态名片")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)

                    Text(emo.moodTag.isEmpty ? "情绪记录" : emo.moodTag)
                        .font(.title2.bold())
                        .foregroundStyle(.primary)

                    HStack(spacing: 32) {
                        scoreBadge(title: "心情", score: emo.moodScore, color: .orange)
                        scoreBadge(title: "精力", score: emo.energyScore, color: .green)
                        scoreBadge(title: "压力", score: emo.stressScore, color: .purple)
                    }
                    .padding(.top, 6)

                    if let note = emo.note, !note.isEmpty {
                        Text("“\(note)”")
                            .font(.callout.italic())
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))

                Text("双方情绪名片已在本地安全握手，数据不上传云端。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: - 5. 物品收纳位置内容

    @ViewBuilder
    private var storageContent: some View {
        if let st = envelope.storage {
            VStack(spacing: 16) {
                VStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.indigo.opacity(0.12))
                            .frame(width: 60, height: 60)
                        Image(systemName: "archivebox.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(Color.indigo)
                    }

                    Text(st.name)
                        .font(.title2.bold())
                        .foregroundStyle(.primary)

                    HStack(spacing: 6) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.caption)
                            .foregroundStyle(Color.indigo)
                        Text("\(st.roomArea) · \(st.location)")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.indigo.opacity(0.08))
                    .clipShape(Capsule())
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.banner, style: .continuous))

                if let note = st.notes, !note.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("补充备注")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Text(note)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
                }
            }
        }
    }

    private func scoreBadge(title: String, score: Int, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("\(score)/5")
                .font(.headline.monospaced().bold())
                .foregroundStyle(color)
        }
    }

    private func detailRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
        }
    }

    // MARK: - 底部操作按钮

    private var bottomActionBar: some View {
        Button {
            executeImport()
        } label: {
            HStack(spacing: 8) {
                if isProcessing {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: "arrow.down.doc.fill")
                        .font(.headline)
                    Text(importButtonTitle)
                        .font(.headline.bold())
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(Color.accentColor)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
        }
        .disabled(isProcessing || isImportButtonDisabled)
    }

    private var importButtonTitle: String {
        switch envelope.type {
        case .todos:
            return "导入所选待办 (\(selectedTodoIndices.count) 项)"
        case .expenseAA:
            if let aa = envelope.expenseAA {
                return "记入本地账本 (¥\(String(format: "%.2f", aa.splitAmount)))"
            }
            return "记入本地账本"
        case .parcelTransfer:
            return "存入待取快递 (登灵动岛)"
        case .emotionPulse:
            return "收下心情名片并确认"
        case .storageItem:
            return "存入本地物品收纳库"
        }
    }

    private var isImportButtonDisabled: Bool {
        if envelope.type == .todos {
            return selectedTodoIndices.isEmpty
        }
        return false
    }

    // MARK: - 执行具体落库

    private func executeImport() {
        isProcessing = true

        Task { @MainActor in
            switch envelope.type {
            case .todos:
                if let items = envelope.todos {
                    let minOrder = TodoItem.minimumSortOrder(in: context)
                    var orderCounter = minOrder - 1

                    for (index, item) in items.enumerated() {
                        guard selectedTodoIndices.contains(index) else { continue }
                        let todoType = TodoType(rawValue: item.ty) ?? .general
                        let dueAt = item.due.map { Date(timeIntervalSince1970: $0) }
                        let newTodo = TodoItem(
                            type: todoType,
                            status: .active,
                            title: item.t,
                            detail: item.d,
                            pickupCode: item.pc,
                            courier: item.courier,
                            station: item.loc,
                            location: item.loc,
                            dueAt: dueAt,
                            sortOrder: orderCounter
                        )
                        orderCounter -= 1
                        context.insert(newTodo)
                        TodoNotificationManager.shared.scheduleNotification(for: newTodo)
                    }
                }

            case .expenseAA:
                if let aa = envelope.expenseAA {
                    let category = ExpenseCategory(rawValue: aa.categoryRaw) ?? .food
                    let record = ExpenseRecord(
                        amount: aa.splitAmount,
                        isIncome: false,
                        category: category,
                        title: "AA分摊: \(aa.title)",
                        rawText: "面对面AA记账分摊: \(aa.title)（原账单总额 ¥\(String(format: "%.2f", aa.totalAmount))，\(aa.splitCount)人平摊）",
                        date: aa.date
                    )
                    context.insert(record)
                }

            case .parcelTransfer:
                if let p = envelope.parcel {
                    let minOrder = TodoItem.minimumSortOrder(in: context)
                    let parcelTodo = TodoItem(
                        type: .parcel,
                        status: .active,
                        title: p.title.hasPrefix("代取") ? p.title : "代取: \(p.title)",
                        detail: p.urgentNote,
                        pickupCode: p.pickupCode,
                        courier: p.courier,
                        station: p.station,
                        location: p.station,
                        dueAt: p.dueAt,
                        sortOrder: minOrder - 1
                    )
                    context.insert(parcelTodo)
                    TodoNotificationManager.shared.scheduleNotification(for: parcelTodo)
                    _ = LiveActivityService.startPickupActivity(for: [parcelTodo])
                }

            case .emotionPulse:
                // 心情名片直接确认收下
                break

            case .storageItem:
                if let st = envelope.storage {
                    let storedItem = StoredItem(
                        name: st.name,
                        location: st.location,
                        roomArea: st.roomArea,
                        notes: st.notes
                    )
                    context.insert(storedItem)
                }
            }

            try? context.save()
            WidgetSnapshotSyncController.shared.refreshSnapshot(context: context)
            Haptic.success()
            isProcessing = false
            dismiss()
            onCompletion?()
        }
    }
}
