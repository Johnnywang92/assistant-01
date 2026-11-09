import AssistantCore
import SwiftUI
import WatchKit

struct WatchQuickCaptureView: View {
    @EnvironmentObject private var store: WatchStore
    @State private var mode: CaptureMode = .expense

    enum CaptureMode: String, CaseIterable {
        case expense = "记账"
        case todo = "待办"
    }

    private var expensePresets: [String] {
        ["咖啡 18元", "午饭 25元", "打车 20元", "晚饭 30元", "奶茶 16元", "买菜 40元"]
    }

    private var todoPresets: [String] {
        ["下午取快递", "买牛奶", "给家里打电话", "晚上跑步"]
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 6) {
                // 顶部自定义分段切换（记账 / 待办）
                HStack(spacing: 6) {
                    ForEach(CaptureMode.allCases, id: \.self) { item in
                        let selected = (mode == item)
                        let tint: Color = (item == .expense) ? .orange : .blue
                        Button {
                            mode = item
                        } label: {
                            Text(item.rawValue)
                                .font(.caption.bold())
                                .frame(maxWidth: .infinity, minHeight: 26)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(selected ? tint : tint.opacity(0.16))
                                )
                                .foregroundStyle(selected ? Color.white : tint)
                        }
                        .buttonStyle(.plain)
                    }
                }

                // 主操作：一键唤起语音听写或高频预设列表（说完直接自动入账，无需手打字）
                Button {
                    presentVoiceInput()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "mic.fill")
                            .font(.body.bold())
                        Text(mode == .expense ? "语音说一笔" : "语音记待办")
                            .font(.footnote.bold())
                    }
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(mode == .expense ? Color.orange : Color.blue)
                    )
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)

                // 下方 2×2 常用一键秒记网格（零打字，点一下立刻记）
                if mode == .expense {
                    Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                        GridRow {
                            presetButton("咖啡 18元", tint: .orange)
                            presetButton("午饭 25元", tint: .orange)
                        }
                        GridRow {
                            presetButton("打车 20元", tint: .orange)
                            presetButton("晚饭 30元", tint: .orange)
                        }
                    }
                } else {
                    Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                        GridRow {
                            presetButton("下午取快递", tint: .blue)
                            presetButton("买牛奶", tint: .blue)
                        }
                        GridRow {
                            presetButton("晚上运动", tint: .blue)
                            presetButton("充电提醒", tint: .blue)
                        }
                    }
                }
            }
            .padding(.horizontal, 4)
            .navigationTitle("快速记")
        }
    }

    private func presetButton(_ phrase: String, tint: Color) -> some View {
        Button {
            submit(phrase)
        } label: {
            Text(phrase)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(tint.opacity(0.2))
                )
                .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
    }

    private func presentVoiceInput() {
        let suggestions = (mode == .expense) ? expensePresets : todoPresets
        WKApplication.shared().visibleInterfaceController?.presentTextInputController(
            withSuggestions: suggestions,
            allowedInputMode: .plain
        ) { results in
            guard let text = results?.first as? String else { return }
            Task { @MainActor in
                self.submit(text)
            }
        }
    }

    private func submit(_ rawText: String) {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if mode == .expense {
            if let amt = ExpenseAmountExtractor.extractAmount(from: trimmed) {
                WidgetSnapshotStore.applyExpenseLocally(amount: amt)
            }
            store.sendCommand(.quickAddExpense(trimmed), feedbackToast: "已记：\(trimmed)")
        } else {
            store.sendCommand(.quickAddTodo(trimmed), feedbackToast: "已添：\(trimmed)")
        }
    }
}
