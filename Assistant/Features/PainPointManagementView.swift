import AssistantCore
import SwiftData
import SwiftUI

/// 订阅防被扣费与物品证件临期管理面板（Apple Wallet 卡包风格）
struct PainPointManagementView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \SubscriptionItem.nextBillingDate) private var subscriptions: [SubscriptionItem]
    @Query(sort: \ItemExpiryItem.expireDate) private var expiries: [ItemExpiryItem]

    @State private var showingAddSub = false
    @State private var showingAddExp = false
    @State private var subToEdit: SubscriptionItem? = nil

    /// 选中的展开卡片 ID（Apple Wallet 堆叠展开交互）
    @State private var expandedSubID: UUID? = nil
    /// 卡片展示模式：堆叠 (Wallet Stack) 或 平铺 (Flow)
    @State private var isStackMode: Bool = true
    @State private var activeTab: PainPointTab = .subscriptions

    enum PainPointTab: String, CaseIterable, Identifiable {
        case subscriptions = "订阅卡包"
        case expiries = "临期卡券"

        var id: String { rawValue }
    }

    /// 预估年度总订阅开销
    private var totalAnnualCost: Double {
        subscriptions.reduce(0.0) { sum, sub in
            sum + (SubscriptionPriceHelper.annualCost(from: sub.priceString) ?? 0)
        }
    }

    /// 7 天内即将扣款的订阅数
    private var upcomingBillsCount: Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let end = calendar.date(byAdding: .day, value: 7, to: today) ?? today
        return subscriptions.filter { sub in
            let date = calendar.startOfDay(for: sub.nextBillingDate)
            return date >= today && date <= end
        }.count
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // MARK: - 顶部选项卡与统计横幅 (Apple Wallet 风格)
                walletHeaderView

                // 分段选择器
                Picker("分类", selection: $activeTab) {
                    ForEach(PainPointTab.allCases) { tab in
                        Text(L10n.tr(tab.rawValue)).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                if activeTab == .subscriptions {
                    subscriptionsSection
                } else {
                    expiriesSection
                }
            }
            .padding(.vertical)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("订阅与临期卡包")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showingAddSub = true
                        Haptic.light()
                    } label: {
                        Label("添加订阅卡片", systemImage: "creditcard")
                    }

                    Button {
                        showingAddExp = true
                        Haptic.light()
                    } label: {
                        Label("添加临期卡券", systemImage: "hourglass")
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAddSub) { AddSubscriptionSheet() }
        .sheet(isPresented: $showingAddExp) { AddExpirySheet() }
        .sheet(item: $subToEdit) { sub in
            EditSubscriptionSheet(subscription: sub)
        }
    }

    // MARK: - 顶部 Wallet 资产横幅
    private var walletHeaderView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("预估年度订阅支出")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(String(format: "¥%.0f", totalAnnualCost))
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                }

                Spacer()

                // 模式切换按钮 (堆叠/平铺)
                if activeTab == .subscriptions && !subscriptions.isEmpty {
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            isStackMode.toggle()
                            expandedSubID = nil
                        }
                        Haptic.selection()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isStackMode ? "square.stack.fill" : "list.bullet.rectangle.portrait.fill")
                            Text(isStackMode ? "堆叠" : "平铺")
                        }
                        .font(.caption.bold())
                        .foregroundStyle(.indigo)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(Color.indigo.opacity(0.12))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 16) {
                HStack(spacing: 6) {
                    Image(systemName: "creditcard.and.123")
                        .foregroundStyle(.indigo)
                    Text("已监控 \(subscriptions.count) 项")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }

                if upcomingBillsCount > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
                        Text("7天内 \(upcomingBillsCount) 项即将扣款")
                            .font(.caption.bold())
                            .foregroundStyle(.orange)
                    }
                }

                Spacer()
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.panel, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
                .shadow(color: Color.black.opacity(0.04), radius: 6, x: 0, y: 3)
        )
        .padding(.horizontal)
    }

    // MARK: - 订阅列表区
    @ViewBuilder
    private var subscriptionsSection: some View {
        if subscriptions.isEmpty {
            VStack(spacing: 14) {
                Image(systemName: "creditcard.trianglebadge.exclamationmark")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text("暂无订阅监控")
                    .font(.headline)
                Text("记录你的连续包月与试用服务，在扣款日前贴心预警，防扣费不踩坑。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Button {
                    showingAddSub = true
                    Haptic.light()
                } label: {
                    Label("添加首张订阅卡", systemImage: "plus")
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(
                            Capsule().fill(Color.indigo)
                        )
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        } else {
            if isStackMode {
                // MARK: 类似 Apple Wallet 卡片堆叠模式
                walletStackedSubscriptions
            } else {
                // MARK: 平铺卡片模式
                LazyVStack(spacing: 16) {
                    ForEach(subscriptions) { sub in
                        SubscriptionWalletCard(
                            sub: sub,
                            isExpanded: expandedSubID == sub.id,
                            onTap: {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                    if expandedSubID == sub.id {
                                        expandedSubID = nil
                                    } else {
                                        expandedSubID = sub.id
                                    }
                                }
                                Haptic.selection()
                            },
                            onEdit: {
                                subToEdit = sub
                            },
                            onDelete: {
                                deleteSingleSub(sub)
                            },
                            onAdvanceCycle: {
                                advanceNextMonth(for: sub)
                            }
                        )
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    // MARK: - Apple Wallet 经典堆叠交互
    private var walletStackedSubscriptions: some View {
        let count = subscriptions.count
        let cardPeek: CGFloat = 66 // 堆叠时每张卡露出的头部高度
        let baseHeight: CGFloat = 175

        return VStack(spacing: 0) {
            ZStack(alignment: .top) {
                ForEach(Array(subscriptions.enumerated()), id: \.element.id) { index, sub in
                    let isExpanded = expandedSubID == sub.id
                    let hasExpandedCard = expandedSubID != nil
                    let expandedIndex = subscriptions.firstIndex(where: { $0.id == expandedSubID }) ?? 0

                    // 堆叠计算位移
                    let yOffset: CGFloat = {
                        if !hasExpandedCard {
                            return CGFloat(index) * cardPeek
                        }
                        if isExpanded {
                            return CGFloat(index) * 24
                        } else if index < expandedIndex {
                            return CGFloat(index) * 24
                        } else {
                            // 下方卡片整体向下沉，给展开卡片留足空间
                            return CGFloat(index) * 24 + 140
                        }
                    }()

                    SubscriptionWalletCard(
                        sub: sub,
                        isExpanded: isExpanded,
                        onTap: {
                            withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
                                if expandedSubID == sub.id {
                                    expandedSubID = nil
                                } else {
                                    expandedSubID = sub.id
                                }
                            }
                            Haptic.selection()
                        },
                        onEdit: {
                            subToEdit = sub
                        },
                        onDelete: {
                            deleteSingleSub(sub)
                        },
                        onAdvanceCycle: {
                            advanceNextMonth(for: sub)
                        }
                    )
                    .offset(y: yOffset)
                    .zIndex(isExpanded ? 100 : Double(index))
                }
            }
            .frame(height: calculateTotalStackHeight(count: count, peek: cardPeek, baseHeight: baseHeight))
            .padding(.horizontal)
        }
    }

    private func calculateTotalStackHeight(count: Int, peek: CGFloat, baseHeight: CGFloat) -> CGFloat {
        if count == 0 { return 0 }
        if expandedSubID != nil {
            return CGFloat(count) * 24 + baseHeight + 160
        }
        return CGFloat(count - 1) * peek + baseHeight + 20
    }

    // MARK: - 临期卡券区
    @ViewBuilder
    private var expiriesSection: some View {
        if expiries.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "hourglass.badge.plus")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("暂无临期卡券")
                    .font(.headline)
                Text("记录护照/驾照、卡券优惠、开封药品或生鲜保质期，急用不抓瞎。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        } else {
            LazyVStack(spacing: 12) {
                ForEach(expiries) { item in
                    ExpiryWalletPassCard(item: item, onDelete: {
                        context.delete(item)
                        _ = context.saveReportingFailure({ SaveFailureCenter.shared.report($0, action: "删除临期项") })
                        Haptic.light()
                    })
                }
            }
            .padding(.horizontal)
        }
    }

    // MARK: - 操作辅助
    private func deleteSingleSub(_ sub: SubscriptionItem) {
        if expandedSubID == sub.id { expandedSubID = nil }
        context.delete(sub)
        _ = context.saveReportingFailure({ SaveFailureCenter.shared.report($0, action: "删除订阅") })
        Haptic.light()
    }

    private func advanceNextMonth(for sub: SubscriptionItem) {
        let calendar = Calendar.current
        let nextMonth = calendar.date(byAdding: .month, value: 1, to: sub.nextBillingDate) ?? sub.nextBillingDate
        sub.nextBillingDate = nextMonth
        _ = context.saveReportingFailure({ SaveFailureCenter.shared.report($0, action: "顺延扣费日") })
        Haptic.success()
    }
}

// MARK: - 临期卡券票据风格卡片 (Pass Style)
struct ExpiryWalletPassCard: View {
    let item: ItemExpiryItem
    var onDelete: (() -> Void)? = nil

    private var daysRemaining: Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let expire = calendar.startOfDay(for: item.expireDate)
        return calendar.dateComponents([.day], from: today, to: expire).day ?? 0
    }

    private var statusColor: Color {
        if daysRemaining < 0 { return Color(.systemRed) }
        if daysRemaining <= 7 { return Color(.systemOrange) }
        if daysRemaining <= 30 { return Color(.systemYellow) }
        return Color.indigo
    }

    var body: some View {
        HStack(spacing: 12) {
            // 左侧票券彩条
            RoundedRectangle(cornerRadius: AppRadius.badge, style: .continuous)
                .fill(statusColor)
                .frame(width: 4)
                .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(L10n.tr(item.title))
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Spacer()

                    Text(L10n.tr(item.category))
                        .font(.caption2.bold())
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(statusColor.opacity(0.14)))
                        .foregroundStyle(statusColor)
                }

                HStack {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar")
                            .font(.caption2)
                        Text(item.expireDate, format: .dateTime.year().month().day())
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)

                    Spacer()

                    Text(daysRemaining < 0 ? "已逾期 \(abs(daysRemaining)) 天" : "剩余 \(daysRemaining) 天")
                        .font(.caption.bold())
                        .foregroundStyle(statusColor)
                }
            }

            Button(role: .destructive) {
                onDelete?()
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("删除临期卡券")
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.panel, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
                .shadow(color: Color.black.opacity(0.04), radius: 4, x: 0, y: 2)
        )
    }
}

// MARK: - 订阅金额周期推断辅助
enum SubscriptionPriceHelper {
    static func annualCost(from priceString: String) -> Double? {
        let cleaned = priceString
            .replacingOccurrences(of: "¥", with: "")
            .replacingOccurrences(of: "￥", with: "")
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: "元", with: "")
            .trimmingCharacters(in: .whitespaces)

        let numbers = cleaned.filter { "0123456789.".contains($0) }
        guard let num = Double(numbers) else { return nil }

        if priceString.contains("年") {
            return num
        } else if priceString.contains("季") {
            return num * 4
        } else if priceString.contains("周") {
            return num * 52
        } else {
            // 默认月付 * 12
            return num * 12
        }
    }
}

// MARK: - 编辑订阅弹窗
struct EditSubscriptionSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let subscription: SubscriptionItem

    @State private var name: String = ""
    @State private var price: String = ""
    @State private var billingDate: Date = Date()
    @State private var remindDays: Int = 2
    @State private var isAutoRenew: Bool = true
    @State private var notes: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("服务信息") {
                    TextField("服务名称（如：视频VIP、iCloud）", text: $name)
                    TextField("费用周期（如：¥18/月、¥198/年）", text: $price)
                    DatePicker("下次扣费日期", selection: $billingDate, displayedComponents: .date)
                    Toggle("自动扣费续费", isOn: $isAutoRenew)
                    Stepper("提前 \(remindDays) 天预警提醒", value: $remindDays, in: 1...7)
                    TextField("备注（如：7天试用别忘退订）", text: $notes)
                }
            }
            .navigationTitle("编辑订阅")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        subscription.name = name
                        subscription.priceString = price
                        subscription.nextBillingDate = billingDate
                        subscription.remindDaysBefore = remindDays
                        subscription.isAutoRenew = isAutoRenew
                        subscription.notes = notes.isEmpty ? nil : notes
                        _ = context.saveReportingFailure({ SaveFailureCenter.shared.report($0, action: "更新订阅") })
                        dismiss()
                    }
                    .disabled(name.isEmpty)
                }
            }
            .onAppear {
                name = subscription.name
                price = subscription.priceString
                billingDate = subscription.nextBillingDate
                remindDays = subscription.remindDaysBefore
                isAutoRenew = subscription.isAutoRenew
                notes = subscription.notes ?? ""
            }
        }
    }
}

// MARK: - 添加订阅与临期表单
struct AddSubscriptionSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var price = "¥15/月"
    @State private var billingDate = Date.now.addingTimeInterval(30 * 24 * 3600)
    @State private var remindDays = 2
    @State private var isAutoRenew = true
    @State private var notes = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("服务信息") {
                    TextField("服务名称（如：视频VIP、iCloud、某工具免费试用）", text: $name)
                    TextField("费用周期（如：¥18/月、¥198/年）", text: $price)
                    DatePicker("下次扣费日期", selection: $billingDate, displayedComponents: .date)
                    Toggle("自动扣费续费", isOn: $isAutoRenew)
                    Stepper("提前 \(remindDays) 天预警提醒", value: $remindDays, in: 1...7)
                    TextField("备注（如：7天试用别忘第6天退订）", text: $notes)
                }
            }
            .navigationTitle("添加自动续费监控")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let item = SubscriptionItem(
                            name: name,
                            priceString: price,
                            nextBillingDate: billingDate,
                            remindDaysBefore: remindDays,
                            isAutoRenew: isAutoRenew,
                            notes: notes.isEmpty ? nil : notes
                        )
                        context.insert(item)
                        guard context.saveReportingFailure({ SaveFailureCenter.shared.report($0, action: "添加自动续费监控") }) else {
                            Haptic.error()
                            return
                        }
                        dismiss()
                    }
                    .disabled(name.isEmpty)
                }
            }
        }
    }
}

struct AddExpirySheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var category = "证件"
    @State private var expireDate = Date.now.addingTimeInterval(180 * 24 * 3600)
    @State private var remindDays = 14

    let categories = ["证件", "护照/港澳通行证", "卡券/优惠券", "开封药品", "生鲜食品", "其他"]

    var body: some View {
        NavigationStack {
            Form {
                Section("物品与有效期限") {
                    TextField("名称（如：身份证换证、眼药水开封后）", text: $title)
                    Picker("类别", selection: $category) {
                        ForEach(categories, id: \.self) { c in Text(L10n.tr(c)).tag(c) }
                    }
                    DatePicker("过期/失效日期", selection: $expireDate, displayedComponents: .date)
                    Stepper("提前 \(remindDays) 天预警", value: $remindDays, in: 1...30)
                }
            }
            .navigationTitle("添加临期预警")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let item = ItemExpiryItem(
                            title: title,
                            category: category,
                            expireDate: expireDate,
                            remindDaysBefore: remindDays
                        )
                        context.insert(item)
                        guard context.saveReportingFailure({ SaveFailureCenter.shared.report($0, action: "添加临期预警") }) else {
                            Haptic.error()
                            return
                        }
                        dismiss()
                    }
                    .disabled(title.isEmpty)
                }
            }
        }
    }
}
