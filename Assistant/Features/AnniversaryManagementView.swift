import SwiftData
import SwiftUI

/// 纪念日与重要日子管理视图
struct AnniversaryManagementView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \AnniversaryItem.targetDate) private var anniversaries: [AnniversaryItem]

    @State private var showingAddSheet = false

    var body: some View {
        List {
            Section {
                Text("记录恋爱纪念日、结婚纪念日、家人生日与人生里程碑。助手会自动计算累计天数、倒数天数，并提前预警以备惊喜礼物。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if anniversaries.isEmpty {
                ContentUnavailableView(
                    "暂无纪念日记录",
                    systemImage: "gift",
                    description: Text("点击右上角 + 记录属于你们的特殊日子")
                )
            } else {
                ForEach(anniversaries) { item in
                    AnniversaryCardRow(item: item)
                }
                .onDelete(perform: deleteItems)
            }
        }
        .navigationTitle("纪念日与重要日子")
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
            AddAnniversarySheet()
        }
    }

    private func deleteItems(at offsets: IndexSet) {
        for idx in offsets {
            context.delete(anniversaries[idx])
        }
        try? context.save()
    }
}

struct AnniversaryCardRow: View {
    let item: AnniversaryItem

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(L10n.tr(item.title))
                        .font(.headline)
                    Text(L10n.tr(item.category))
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.pink.opacity(0.15)))
                        .foregroundStyle(.pink)
                }

                Text("起始: \(item.targetDate, format: .dateTime.year().month().day())")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("已经走过 \(item.passedDays) 天")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // 倒数日天数徽标
            VStack {
                if item.daysUntilNext == 0 {
                    Text("今天!")
                        .font(.title2.bold())
                        .foregroundStyle(.pink)
                    Text("第 \(item.nextYearsCount) 年")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(item.daysUntilNext)")
                        .font(.title.monospacedDigit().bold())
                        .foregroundStyle(.tint)
                    Text("天后 · 第\(item.nextYearsCount)年")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 70)
        }
        .padding(.vertical, 4)
    }
}

struct AddAnniversarySheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var category = "恋爱相识"
    @State private var targetDate = Date.now
    @State private var notes = ""

    let categories = ["恋爱相识", "结婚纪念", "家人生日", "朋友生日", "人生里程碑", "其他"]

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("名称（如：在一起、结婚、妈妈生日）", text: $title)
                    Picker("分类", selection: $category) {
                        ForEach(categories, id: \.self) { c in Text(L10n.tr(c)).tag(c) }
                    }
                    DatePicker("发生/起始日期", selection: $targetDate, displayedComponents: .date)
                    TextField("备忘灵感（如：想送的礼物/心仪餐厅）", text: $notes)
                }

                Section("提醒策略") {
                    Text("系统默认会在：当天、提前 1 天、提前 3 天、提前 7 天 自动发出提醒。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("添加纪念日")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let item = AnniversaryItem(
                            title: title,
                            category: category,
                            targetDate: targetDate,
                            notes: notes.isEmpty ? nil : notes
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
