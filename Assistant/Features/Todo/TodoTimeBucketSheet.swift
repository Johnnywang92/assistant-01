import AssistantCore
import SwiftData
import SwiftUI

// MARK: - 时间桶详情弹层（首页时间聚合条的入口落点）
//
// 点「逾期 / 今天 / 本周」chip 后展开的清单。行复用 `TodoRow`，
// 与列表页同款交互（勾选完成、编辑、分享），保证聚合计数与详情同源同观感。
//
// 编辑走本弹层内部的 sheet 栈——若转发到列表页的 `itemToEdit`，
// 会形成「父视图 sheet 上再叠 sheet」的呈现冲突。

struct TodoTimeBucketSheet: View {
    let kind: TodoTimeBucketKind
    let items: [TodoItem]

    @Environment(\.dismiss) private var dismiss
    @State private var itemToEdit: TodoItem?
    @State private var itemToShare: TodoItem?

    private var title: String {
        switch kind {
        case .overdue: return "逾期事项"
        case .today: return "今天待办"
        case .thisWeek: return "本周安排"
        }
    }

    private var subtitle: String {
        switch kind {
        case .overdue: return "这些事项已经过了计划时间，点圆圈完成或进详情改期"
        case .today: return "今天该做的都在这里，做完点圆圈划掉"
        case .thisWeek: return "本周剩下的安排，提前看一眼好排时间"
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    emptyState
                } else {
                    List {
                        Section {
                            ForEach(items) { item in
                                TodoRow(
                                    item: item,
                                    onEdit: { itemToEdit = item },
                                    onShare: { itemToShare = item }
                                )
                            }
                        } footer: {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("\(title)（\(items.count)）")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(item: $itemToEdit) { item in
                EditTodoSheet(item: item)
            }
            .sheet(item: $itemToShare) { item in
                TodoShareSheet(
                    allTodos: [item],
                    initialCategory: (item.type == .parcel || item.type == .returnParcel) ? .parcel : .all,
                    initialSelectedIds: [item.id]
                )
            }
        }
        .presentationDetents([.large])
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: kind.systemImage)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text("这里已经空了")
                .font(.headline)
            Text("事项被完成后会从时间聚合里移出，去类型分类里还能找到历史")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
