import AssistantCore
import SwiftData
import SwiftUI

/// 出行前购票与文博景区预约新增事项确认弹窗（严格遵循用户显式确认原则，并提供政策变动兜底与自主确认时间能力）
struct TravelTicketConfirmationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    let ticketInfo: UpcomingTravelTicketInfo
    var onConfirm: ((Int) -> Void)? = nil

    @State private var proposedItems: [ProposedTicketTodo] = []
    @State private var hasInitialized: Bool = false

    private var selectedCount: Int {
        proposedItems.filter(\.isSelected).count
    }

    private var allSelected: Bool {
        !proposedItems.isEmpty && proposedItems.allSatisfy(\.isSelected)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // 1. 出行概览头部卡片
                    overviewCard

                    // 2. 预约政策变动兜底提示卡片（重点突出政策时常变动，提醒用户自主核对并确认）
                    policyFallbackNoticeCard

                    // 3. 目的地文博放票指南提示卡片（如北京、西安、成都等）
                    if let guide = ticketInfo.destinationGuide {
                        destinationGuideCard(guide)
                    }

                    // 4. 事项确认列表提示说明与全选开关
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("请勾选事项并核对预约时间：")
                                .font(.subheadline.bold())
                                .foregroundStyle(.primary)
                            Text("可展开或点击下方日期微调具体放票时段")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button(allSelected ? "全不选" : "全选") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                let target = !allSelected
                                for index in proposedItems.indices {
                                    proposedItems[index].isSelected = target
                                }
                            }
                        }
                        .font(.caption.bold())
                        .foregroundStyle(.indigo)
                    }
                    .padding(.horizontal)
                    .padding(.top, 4)

                    // 5. 待确认事项卡片列表（支持用户自主调整与确认预约时间）
                    VStack(spacing: 14) {
                        ForEach($proposedItems) { $item in
                            proposedItemRow(item: $item)
                        }
                    }
                    .padding(.horizontal)

                    // 6. 不再提醒按钮
                    Button {
                        withAnimation {
                            TravelTicketReminderManager.shared.dismiss(for: ticketInfo)
                            dismiss()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "bell.slash")
                            Text("本周期不再提醒该出行")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
                .padding(.vertical, 16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("出行待办与预约时间确认")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                bottomActionBar
            }
            .onAppear {
                if !hasInitialized {
                    proposedItems = TravelTicketReminderManager.shared.generateProposedTicketTodos(for: ticketInfo)
                    hasInitialized = true
                }
            }
        }
    }

    // MARK: - 头部出行概览卡片

    private var overviewCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.indigo.opacity(0.12))
                        .frame(width: 44, height: 44)
                    Image(systemName: ticketInfo.isHoliday ? "calendar.badge.clock" : "airplane.departure")
                        .font(.title3)
                        .foregroundStyle(.indigo)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(ticketInfo.title)
                            .font(.headline)
                            .foregroundStyle(.primary)

                        Text(ticketInfo.stageBadgeText)
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.indigo.opacity(0.15)))
                            .foregroundStyle(.indigo)
                    }

                    Text("出行日期：\(ticketInfo.departureFormatted)（距今 \(ticketInfo.daysUntilDeparture) 天）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            Text("系统根据出行日期为您初筛了购票与文博预约关键节点。所有事项需由您确认后方可加入待办。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .padding(.horizontal)
    }

    // MARK: - 预约政策变动兜底提示卡片

    private var policyFallbackNoticeCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(.orange)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("预约政策变动兜底提示")
                        .font(.subheadline.bold())
                        .foregroundStyle(.orange)

                    Text("需自行核对确认")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.18)))
                        .foregroundStyle(.orange)
                }

                Text("各文博场馆、5A景区、12306 及航司的放票政策（如提前预约天数、分时段放票整点）经常受旅游旺季或节假日临时调整。请以官方公众号、小程序或 12306 最新公告为准，并可在下方直接自定义确认您的提醒时间。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.25), lineWidth: 1)
        )
        .padding(.horizontal)
    }

    // MARK: - 目的地文博放票指南卡片

    private func destinationGuideCard(_ guide: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.title3)
                .foregroundStyle(.purple)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text("目的地文博/景区官方放票规则参考")
                    .font(.subheadline.bold())
                    .foregroundStyle(.purple)

                Text(guide)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineSpacing(2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.purple.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.purple.opacity(0.2), lineWidth: 1)
        )
        .padding(.horizontal)
    }

    // MARK: - 单个建议事项卡片（支持用户自主确认与微调预约时间）

    private func proposedItemRow(item: Binding<ProposedTicketTodo>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // 顶部选择状态与标题
            HStack(alignment: .top, spacing: 12) {
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        item.wrappedValue.isSelected.toggle()
                    }
                } label: {
                    Image(systemName: item.wrappedValue.isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(item.wrappedValue.isSelected ? Color.indigo : Color.secondary.opacity(0.6))
                        .padding(.top, 2)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(item.wrappedValue.title)
                            .font(.subheadline.bold())
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)

                        Spacer()

                        Text(item.wrappedValue.badge)
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.indigo.opacity(0.12)))
                            .foregroundStyle(.indigo)
                    }

                    Text(item.wrappedValue.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // 用户自主确认与微调预约时间区域
            if item.wrappedValue.isSelected {
                VStack(alignment: .leading, spacing: 8) {
                    Divider().opacity(0.4)

                    HStack {
                        Label("确认预约提醒时间：", systemImage: "clock.badge.checkmark")
                            .font(.caption.bold())
                            .foregroundStyle(.indigo)

                        if item.wrappedValue.isCustomized {
                            Text("已自主修改")
                                .font(.caption2.bold())
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.green.opacity(0.15)))
                                .foregroundStyle(.green)
                        }

                        Spacer()

                        DatePicker(
                            "",
                            selection: Binding(
                                get: { item.wrappedValue.dueAt },
                                set: { newDate in
                                    item.wrappedValue.dueAt = newDate
                                    item.wrappedValue.isCustomized = true
                                }
                            ),
                            displayedComponents: [.date, .hourAndMinute]
                        )
                        .datePickerStyle(.compact)
                        .labelsHidden()
                    }

                    // 快捷兜底预设标签（根据场馆/车票常见政策一键调整）
                    quickTimePresetsView(item: item)

                    Text(item.wrappedValue.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.top, 2)
                }
                .padding(.top, 2)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    item.wrappedValue.isSelected ? Color.indigo.opacity(0.4) : Color.clear,
                    lineWidth: 1.5
                )
        )
    }

    // MARK: - 针对政策变动的快捷时间调整预设（天数与放票整点）

    @ViewBuilder
    private func quickTimePresetsView(item: Binding<ProposedTicketTodo>) -> some View {
        let cal = Calendar.current
        let departure = cal.startOfDay(for: ticketInfo.departureDate)

        if item.wrappedValue.categoryKey == "scenic" {
            VStack(alignment: .leading, spacing: 6) {
                // 提前预约天数微调（应对3天、5天、7天、14天、30天变动）
                HStack(spacing: 5) {
                    Text("政策天数:")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    ForEach([3, 5, 7, 14, 30], id: \.self) { days in
                        Button {
                            if let newDay = cal.date(byAdding: .day, value: -days, to: departure) {
                                let hour = cal.component(.hour, from: item.wrappedValue.dueAt)
                                let minute = cal.component(.minute, from: item.wrappedValue.dueAt)
                                if let target = cal.date(bySettingHour: hour, minute: minute, second: 0, of: newDay) {
                                    item.wrappedValue.dueAt = target
                                    item.wrappedValue.badge = "提前\(days)天放票"
                                    item.wrappedValue.isCustomized = true
                                    Haptic.light()
                                }
                            }
                        } label: {
                            Text("提前\(days)天")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color(.tertiarySystemFill)))
                                .foregroundStyle(.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                // 热门场馆放票时段微调（08:00/12:00/17:00/20:00/22:00）
                HStack(spacing: 5) {
                    Text("放票时段:")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    ForEach([(8, "08:00 苏博"), (12, "12:00 上博"), (17, "17:00 国博"), (20, "20:00 故宫"), (22, "22:00 粤博")], id: \.0) { hour, label in
                        Button {
                            if let target = cal.date(bySettingHour: hour, minute: 0, second: 0, of: item.wrappedValue.dueAt) {
                                item.wrappedValue.dueAt = target
                                item.wrappedValue.isCustomized = true
                                Haptic.light()
                            }
                        } label: {
                            Text(L10n.tr(label))
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.purple.opacity(0.1)))
                                .foregroundStyle(.purple)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        } else if item.wrappedValue.categoryKey == "train" {
            // 火车票 12306 车站起售整点微调
            HStack(spacing: 5) {
                Text("车站起售点:")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                ForEach([(8, 0, "08:00"), (9, 30, "09:30"), (11, 0, "11:00"), (14, 0, "14:00"), (16, 0, "16:00")], id: \.2) { hour, min, label in
                    Button {
                        if let target = cal.date(bySettingHour: hour, minute: min, second: 0, of: item.wrappedValue.dueAt) {
                            item.wrappedValue.dueAt = target
                            item.wrappedValue.isCustomized = true
                            Haptic.light()
                        }
                    } label: {
                        Text(L10n.tr(label))
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.blue.opacity(0.1)))
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 底部确认操作条

    private var bottomActionBar: some View {
        VStack(spacing: 8) {
            Divider()

            HStack(spacing: 12) {
                Button {
                    dismiss()
                } label: {
                    Text("暂不添加")
                        .font(.subheadline.bold())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color(.tertiarySystemFill))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    confirmSelection()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                        Text(selectedCount > 0 ? "确认添加待办 (\(selectedCount)项已确认)" : "请勾选事项")
                    }
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        LinearGradient(
                            colors: selectedCount > 0 ? [Color.indigo, Color.blue] : [Color.gray, Color.gray.opacity(0.8)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: selectedCount > 0 ? Color.indigo.opacity(0.3) : Color.clear, radius: 4, y: 2)
                }
                .buttonStyle(.plain)
                .disabled(selectedCount == 0)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .background(Color(.systemGroupedBackground))
    }

    private func confirmSelection() {
        let count = TravelTicketReminderManager.shared.confirmAndInsertTicketTodos(
            proposedItems,
            for: ticketInfo,
            context: context
        )
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onConfirm?(count)
        dismiss()
    }
}
