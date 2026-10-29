import AssistantCore
import SwiftData
import SwiftUI

/// 扫码导入预览与确认弹窗
struct TodoImportPreviewSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let payload: TodoSharePayload
    let onCompletion: (() -> Void)?

    @State private var selectedItemIndices: Set<Int>
    @State private var isImporting: Bool = false
    @State private var importSuccess: Bool = false

    init(payload: TodoSharePayload, onCompletion: (() -> Void)? = nil) {
        self.payload = payload
        self.onCompletion = onCompletion
        // 默认全选
        self._selectedItemIndices = State(initialValue: Set(payload.items.indices))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 顶部信息总览卡片
                VStack(spacing: 8) {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color.accentColor.opacity(0.15))
                                .frame(width: 48, height: 48)

                            Image(systemName: "square.and.arrow.down.fill")
                                .font(.title3)
                                .foregroundStyle(Color.accentColor)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text(payload.title.isEmpty ? "共享待办事项" : payload.title)
                                .font(.headline.bold())
                                .foregroundStyle(.primary)

                            Text("检测到 \(payload.items.count) 项待办 · 来自小助面对面扫码分享")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }
                    .padding()
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.banner, style: .continuous))
                    .padding(.horizontal)
                    .padding(.top, 12)

                    // 全选 / 反选便捷按钮
                    HStack {
                        Text("请勾选需要导入至本地的事项：")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer()

                        Button {
                            if selectedItemIndices.count == payload.items.count {
                                selectedItemIndices.removeAll()
                            } else {
                                selectedItemIndices = Set(payload.items.indices)
                            }
                            Haptic.light()
                        } label: {
                            Text(selectedItemIndices.count == payload.items.count ? "取消全选" : "全选全部")
                                .font(.caption.bold())
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                }

                // 待办条目清单
                List {
                    ForEach(payload.items.indices, id: \.self) { index in
                        let item = payload.items[index]
                        let isSelected = selectedItemIndices.contains(index)

                        Button {
                            if isSelected {
                                selectedItemIndices.remove(index)
                            } else {
                                selectedItemIndices.insert(index)
                            }
                            Haptic.light()
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.6))
                                    .padding(.top, 2)

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(item.t)
                                            .font(.body.weight(.medium))
                                            .foregroundStyle(.primary)
                                            .multilineTextAlignment(.leading)

                                        Spacer()

                                        tagBadge(for: item.ty)
                                    }

                                    if let code = item.pc {
                                        HStack(spacing: 4) {
                                            Text("取件码：\(code)")
                                                .font(.subheadline.monospaced().bold())
                                                .foregroundStyle(.orange)

                                            if let loc = item.loc {
                                                Text("(\(loc))")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color.orange.opacity(0.12))
                                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.small))
                                    }

                                    if let detail = item.d, !detail.isEmpty {
                                        Text(L10n.tr(detail))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    if let dueTime = item.due {
                                        let dueDate = Date(timeIntervalSince1970: dueTime)
                                        HStack(spacing: 4) {
                                            Image(systemName: "calendar")
                                            Text("截止：\(dueDate.formatted(date: .numeric, time: .shortened))")
                                        }
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.insetGrouped)

                // 底部导入确认按钮
                VStack(spacing: 8) {
                    Button {
                        importSelectedItems()
                    } label: {
                        HStack(spacing: 8) {
                            if isImporting {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: "plus.circle.fill")
                                Text(selectedItemIndices.isEmpty ? "请先勾选待办事宜" : "确认导入到我的待办 (共 \(selectedItemIndices.count) 项)")
                            }
                        }
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(selectedItemIndices.isEmpty ? Color.gray.opacity(0.6) : Color.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.banner, style: .continuous))
                    }
                    .disabled(selectedItemIndices.isEmpty || isImporting)
                    .padding(.horizontal)
                    .padding(.bottom, 16)
                }
                .background(Color(.systemGroupedBackground))
            }
            .navigationTitle("扫码导入清单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func tagBadge(for typeRaw: String) -> some View {
        let type = TodoType(rawValue: typeRaw) ?? .general
        Text(type.displayName)
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.12))
            .foregroundStyle(Color.accentColor)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.badge))
    }

    private func importSelectedItems() {
        guard !selectedItemIndices.isEmpty else { return }
        isImporting = true

        let itemsToImport = selectedItemIndices.sorted().map { payload.items[$0] }

        for dto in itemsToImport {
            let todoType = TodoType(rawValue: dto.ty) ?? .general
            let dueDate = dto.due != nil ? Date(timeIntervalSince1970: dto.due!) : nil

            let item = TodoItem(
                type: todoType,
                status: .active,
                title: dto.t,
                detail: dto.d,
                pickupCode: dto.pc,
                courier: dto.courier,
                station: dto.loc,
                location: dto.loc,
                dueAt: dueDate
            )
            context.insert(item)
            TodoNotificationManager.shared.scheduleNotification(for: item)
        }

        try? context.save()
        Haptic.success()
        isImporting = false

        onCompletion?()
        dismiss()
    }
}
