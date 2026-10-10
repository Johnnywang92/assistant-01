import SwiftData
import SwiftUI

/// 订阅防被扣费与物品证件临期管理面板
struct PainPointManagementView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \SubscriptionItem.nextBillingDate) private var subscriptions: [SubscriptionItem]
    @Query(sort: \ItemExpiryItem.expireDate) private var expiries: [ItemExpiryItem]

    @State private var showingAddSub = false
    @State private var showingAddExp = false

    var body: some View {
        List {
            Section {
                Text("专为生活高频痛点设计：\n1. 连续包月与免费试用常在不知不觉中扣款；\n2. 护照/驾照/开封药品常在急用时才发现过期。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            // MARK: - 订阅与连续包月防扣
            Section("自动续费与订阅（防扣款雷区）") {
                if subscriptions.isEmpty {
                    Text("暂无订阅监控，点击右上角 + 记录").foregroundStyle(.secondary)
                } else {
                    ForEach(subscriptions) { sub in
                        SubscriptionRow(sub: sub)
                    }
                    .onDelete(perform: deleteSubs)
                }
            }

            // MARK: - 证件/食品/药品保质期
            Section("证件、卡券与物品临期预警") {
                if expiries.isEmpty {
                    Text("暂无临期监控项").foregroundStyle(.secondary)
                } else {
                    ForEach(expiries) { item in
                        ExpiryRow(item: item)
                    }
                    .onDelete(perform: deleteExpiries)
                }
            }
        }
        .navigationTitle("防扣费与临期守护")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("添加订阅防扣费", systemImage: "creditcard") { showingAddSub = true }
                    Button("添加物品/证件临期", systemImage: "hourglass") { showingAddExp = true }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAddSub) { AddSubscriptionSheet() }
        .sheet(isPresented: $showingAddExp) { AddExpirySheet() }
    }

    private func deleteSubs(at offsets: IndexSet) {
        for idx in offsets { context.delete(subscriptions[idx]) }
        try? context.save()
    }

    private func deleteExpiries(at offsets: IndexSet) {
        for idx in offsets { context.delete(expiries[idx]) }
        try? context.save()
    }
}

struct SubscriptionRow: View {
    let sub: SubscriptionItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(sub.name, systemImage: "creditcard.and.123")
                    .font(.headline)
                Spacer()
                Text(sub.priceString)
                    .font(.subheadline)
                    .foregroundStyle(.tint)
            }
            HStack {
                Text("下次扣费: \(sub.nextBillingDate, format: .dateTime.month().day())")
                Text("· 提前 \(sub.remindDaysBefore) 天预警")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let notes = sub.notes, !notes.isEmpty {
                Text(notes).font(.caption2).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }
}

struct ExpiryRow: View {
    let item: ItemExpiryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(item.title, systemImage: "hourglass.bottomhalf.filled")
                    .font(.headline)
                Spacer()
                Text(item.category)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.secondary.opacity(0.15)))
            }
            Text("失效日期: \(item.expireDate, format: .dateTime.year().month().day())")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct AddSubscriptionSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var price = "¥15/月"
    @State private var billingDate = Date.now.addingTimeInterval(30 * 24 * 3600)
    @State private var remindDays = 2
    @State private var notes = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("服务信息") {
                    TextField("服务名称（如：视频VIP、iCloud、某工具免费试用）", text: $name)
                    TextField("费用周期（如：¥18/月、¥198/年）", text: $price)
                    DatePicker("下次扣费日期", selection: $billingDate, displayedComponents: .date)
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
                            notes: notes.isEmpty ? nil : notes
                        )
                        context.insert(item)
                        try? context.save()
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
                        ForEach(categories, id: \.self) { c in Text(c).tag(c) }
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
                        try? context.save()
                        dismiss()
                    }
                    .disabled(title.isEmpty)
                }
            }
        }
    }
}
