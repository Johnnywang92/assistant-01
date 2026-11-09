import AssistantCore
import SwiftUI

struct WatchQuickCaptureView: View {
    @EnvironmentObject private var store: WatchStore
    @State private var inputText: String = ""
    @State private var mode: CaptureMode = .expense

    enum CaptureMode: String, CaseIterable {
        case expense = "记账"
        case todo = "待办"
    }

    private var previewAmount: Double? {
        guard mode == .expense, !inputText.isEmpty else { return nil }
        return ExpenseAmountExtractor.extractAmount(from: inputText)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 6) {
                // 顶部自定义分段切换（替代 watchOS 默认全屏滚轮 Picker，杜绝与下方输入框重叠）
                HStack(spacing: 6) {
                    ForEach(CaptureMode.allCases, id: \.self) { item in
                        let selected = (mode == item)
                        let tint: Color = (item == .expense) ? .orange : .blue
                        Button {
                            mode = item
                        } label: {
                            Text(item.rawValue)
                                .font(.caption.bold())
                                .frame(maxWidth: .infinity, minHeight: 28)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(selected ? tint : tint.opacity(0.16))
                                )
                                .foregroundStyle(selected ? Color.white : tint)
                        }
                        .buttonStyle(.plain)
                    }
                }

                // 语音听写 / 涂写输入框
                TextField(
                    mode == .expense ? "说：咖啡 18 元" : "说：下午取快递",
                    text: $inputText
                )
                .font(.footnote)

                if let amount = previewAmount {
                    Text(String(format: "识别金额：¥%.2f", amount))
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                } else if mode == .expense {
                    // 未输入时展示两枚一键快记短语
                    HStack(spacing: 6) {
                        presetButton("咖啡 18元")
                        presetButton("午饭 25元")
                    }
                }

                // 提交按钮
                Button {
                    submit()
                } label: {
                    Label("发送给 iPhone", systemImage: "paperplane.fill")
                        .font(.footnote.bold())
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill((mode == .expense ? Color.orange : Color.blue).opacity(
                                    inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.3 : 0.9
                                ))
                        )
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 4)
            .navigationTitle("快速记")
        }
    }

    private func presetButton(_ phrase: String) -> some View {
        Button {
            inputText = phrase
            submit()
        } label: {
            Text(phrase)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 26)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.orange.opacity(0.18))
                )
                .foregroundStyle(.orange)
        }
        .buttonStyle(.plain)
    }

    private func submit() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if mode == .expense {
            if let amt = ExpenseAmountExtractor.extractAmount(from: trimmed) {
                WidgetSnapshotStore.applyExpenseLocally(amount: amt)
            }
            store.sendCommand(.quickAddExpense(trimmed), feedbackToast: "已发送记账")
        } else {
            store.sendCommand(.quickAddTodo(trimmed), feedbackToast: "已添加待办")
        }
        inputText = ""
    }
}
